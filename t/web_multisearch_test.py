"""Offline tests for one search across sources and stored file lists (M2 gate X5).

Stand-ins replace the engine-backed search service and the catalog-backed
file-list service, so these check only what the combined search itself
decides: who is asked and in what order, how file-list matches are copied
and capped, how the combined list is paged, and when a row stops being
downloadable.
"""

from __future__ import annotations

import asyncio
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from webapp.manifests import ManifestError
from webapp.multisearch import MAX_LISTS_PER_SEARCH, MultiSearchService
from webapp.searches import MAX_RESULTS, SearchError


ROUTE_A = "a" * 64
ROUTE_B = "b" * 64


def token(number: int) -> str:
    return f"{number:064x}"


class FakeSearches:
    """Per-source searches that complete at once with a fixed number of rows."""

    def __init__(self, database: Path, sources: dict[str, str], rows: dict[str, int]):
        database.touch()
        configs = {source_id: SimpleNamespace(source_id=source_id, label=label,
                                              channel="#" + source_id)
                   for source_id, label in sources.items()}
        self.sources = SimpleNamespace(store=SimpleNamespace(get=configs.get))
        self.store = SimpleNamespace(path=database)
        self.rows = rows
        self.calls: list[tuple[str, str]] = []
        self.found: dict[str, str] = {}      # search_id -> source_id
        self.historical: set[str] = set()
        self.broken: set[str] = set()        # sources whose search fails unexpectedly

    async def search(self, terms, source_id):
        self.calls.append((terms, source_id))
        if source_id in self.broken:
            raise RuntimeError("database is locked")
        if self.rows.get(source_id) is None:
            raise SearchError("source_not_ready", "connect that source first")
        search_id = "search-" + f"{len(self.found) + 1:032x}"
        self.found[search_id] = source_id
        return self.snapshot(search_id)

    async def status(self, search_id):
        return self.snapshot(search_id)

    def snapshot(self, search_id):
        source_id = self.found.get(search_id)
        if source_id is None:
            return None
        return {"search_id": search_id, "state": "complete", "engine_state": "complete",
                "provider": "searchbot" if source_id == "bot" else "sysreset_find",
                "result_count": self.rows[source_id], "note": None,
                "historical": search_id in self.historical}

    async def page(self, search_id, *, offset, limit):
        source_id = self.found[search_id]
        usable = search_id not in self.historical
        results = [{"row_key": f"{source_id}-{number}", "path": f"/{source_id}/{number}",
                    "result_id": f"row-{source_id}-{number}" if usable else None,
                    "selection_available": usable}
                   for number in range(offset, min(offset + limit, self.rows[source_id]))]
        return {"results": results}


class FakeLists:
    """Stored file lists whose matches are served 50 at a time, as the catalog does."""

    def __init__(self, matches: dict[str, int]):
        self.matches = matches
        self.listed_at = {key: "2026-10-13T10:00:00Z" for key in matches}
        self.source_label = {key: "Lab" for key in matches}
        self.searches: list[tuple[str, str, object]] = []
        self.fail: dict[str, ManifestError] = {}

    async def lists(self):
        return {"lists": [
            {"route_key": key, "source_id": "primary", "source_label": self.source_label[key],
             "sender": "Fixture", "trigger": "!" + key[:1], "files": count,
             "listed_at": self.listed_at[key]}
            for key, count in self.matches.items()]}

    async def search(self, query, route_key=None, cursor=None):
        self.searches.append((query, route_key, cursor))
        if route_key in self.fail:
            raise self.fail[route_key]
        first = int(cursor or 0)
        last = min(first + 50, self.matches[route_key])
        results = [{"result_id": "mrow-" + token(number), "selection_available": True,
                    "path": f"/list/{number:04}.txt", "sender": "Fixture",
                    "trigger": "!" + route_key[:1], "size_text": "1.2M",
                    "size_bytes": 1258291, "size_precision": "estimated"}
                   for number in range(first, last)]
        more = last < self.matches[route_key]
        return {"results": results, "has_more": more,
                "next_cursor": str(last) if more else None}


async def finished(service: MultiSearchService, group_id: str) -> dict:
    for _ in range(400):
        summary = await service.status(group_id)
        if summary["state"] != "running":
            return summary
        await asyncio.sleep(.01)
    raise AssertionError("the combined search did not finish")


class CombinedSearchTests(unittest.TestCase):
    def run_with(self, workflow, *, rows, matches):
        async def body():
            with tempfile.TemporaryDirectory() as directory:
                searches = FakeSearches(
                    Path(directory) / "fserve.sqlite3",
                    {"primary": "Servers", "bot": "Books", "idle": "Idle"}, rows)
                lists = FakeLists(matches)
                service = MultiSearchService(searches, lists)
                await service.startup()
                try:
                    await workflow(service, searches, lists)
                finally:
                    await service.close()
        asyncio.run(body())

    def test_sources_and_lists_make_one_list_and_each_row_says_how_it_was_found(self):
        async def workflow(service, searches, lists):
            for sources, chosen in ((None, None), ([], []), (["primary"], "x"),
                                    (["primary"], [ROUTE_A, ROUTE_A]),
                                    (["primary"], ["c" * 64]),
                                    ([], [f"{n:064d}" for n in range(MAX_LISTS_PER_SEARCH + 1)])):
                with self.subTest(sources=sources, chosen=str(chosen)[:40]), self.assertRaises(SearchError):
                    await service.start("fixture", sources, chosen)
            self.assertEqual((searches.calls, lists.searches), ([], []))

            started = await service.start("fixture", ["primary", "bot", "idle"], [ROUTE_A])
            summary = await finished(service, started["group_id"])
            self.assertEqual(
                [(member["kind"], member["label"], member["provider"] if "provider" in member
                  else None, member["state"], member["result_count"], member["historical"])
                 for member in summary["members"]],
                [("source", "Servers", "sysreset_find", "complete", 3, False),
                 ("source", "Books", "searchbot", "complete", 2, False),
                 ("source", "Idle", None, "failed", 0, True),
                 ("list", "Fixture !a", "file_list", "complete", 4, False)])
            self.assertEqual(summary["members"][2]["note"], "connect that source first")
            self.assertEqual(summary["result_count"], 9)
            # One query per source, in the order ticked; the list was read once.
            self.assertEqual(searches.calls, [("fixture", "primary"), ("fixture", "bot"),
                                              ("fixture", "idle")])
            self.assertEqual(lists.searches, [("fixture", ROUTE_A, None)])

            page = await service.page(started["group_id"], offset=0, limit=10)
            self.assertEqual(
                [(row["source_label"], row["provider"], row["path"]) for row in page["results"]],
                [("Servers", "sysreset_find", "/primary/0"),
                 ("Servers", "sysreset_find", "/primary/1"),
                 ("Servers", "sysreset_find", "/primary/2"),
                 ("Books", "searchbot", "/bot/0"), ("Books", "searchbot", "/bot/1"),
                 ("Fixture !a", "file_list", "/list/0000.txt"),
                 ("Fixture !a", "file_list", "/list/0001.txt"),
                 ("Fixture !a", "file_list", "/list/0002.txt"),
                 ("Fixture !a", "file_list", "/list/0003.txt")])
            listed = page["results"][5]
            self.assertEqual(
                (listed["result_id"], listed["selection_available"], listed["trigger_mode"],
                 listed["listed_at"], listed["size_bytes_estimate"], listed["size_bytes_exact"],
                 listed["sender"], listed["trigger"]),
                ("mrow-" + token(0), True, "file_list", "2026-10-13T10:00:00Z", 1258291, None,
                 "Fixture", "!a"))
            # A page may start inside one place and end inside another.
            middle = await service.page(started["group_id"], offset=4, limit=3)
            self.assertEqual([row["path"] for row in middle["results"]],
                             ["/bot/1", "/list/0000.txt", "/list/0001.txt"])
            for offset, limit in ((-1, 5), (0, 0), (0, 11), (10 ** 8, 5)):
                with self.assertRaises(SearchError):
                    await service.page(started["group_id"], offset=offset, limit=limit)

            # History shows the combined search once, with what it searched.
            (entry,) = await service.history()
            self.assertEqual((entry["group_id"], entry["terms"], len(entry["members"]),
                              entry["result_count"]), (started["group_id"], "fixture", 4, 9))

        self.run_with(workflow, rows={"primary": 3, "bot": 2, "idle": None},
                      matches={ROUTE_A: 4, ROUTE_B: 0})

    def test_a_file_list_alone_sends_nothing_and_is_capped_at_a_thousand(self):
        async def workflow(service, searches, lists):
            started = await service.start("fixture", [], [ROUTE_A, ROUTE_B])
            summary = await finished(service, started["group_id"])
            self.assertEqual(
                [(member["state"], member["result_count"], member["capped"])
                 for member in summary["members"]],
                [("complete", MAX_RESULTS, True), ("complete", 70, False)])
            self.assertEqual(searches.calls, [], "no source was asked")
            # Twenty pages of fifty from the first list, two from the second.
            self.assertEqual(len(lists.searches), 22)
            last = await service.page(started["group_id"], offset=MAX_RESULTS - 1, limit=3)
            self.assertEqual(
                [(row["source_label"], row["path"]) for row in last["results"]],
                [("Fixture !a", "/list/0999.txt"), ("Fixture !b", "/list/0000.txt"),
                 ("Fixture !b", "/list/0001.txt")])

        self.run_with(workflow, rows={}, matches={ROUTE_A: 1200, ROUTE_B: 70})

    def test_one_search_looks_in_every_stored_list(self):
        # No cap of eight lists since 2026-10-29; they are looked in a few at a
        # time, and each keeps its own place in the combined list.
        keys = [f"{number:064x}" for number in range(1, 21)]

        async def workflow(service, searches, lists):
            started = await service.start("fixture", [], keys)
            summary = await finished(service, started["group_id"])
            self.assertEqual([(member["route_key"], member["state"], member["result_count"])
                              for member in summary["members"]],
                             [(key, "complete", 3) for key in keys])
            self.assertEqual(sorted(route for _query, route, _cursor in lists.searches),
                             sorted(keys))
            page = await service.page(started["group_id"], offset=57, limit=3)
            self.assertEqual([row["path"] for row in page["results"]],
                             ["/list/0000.txt", "/list/0001.txt", "/list/0002.txt"],
                             "the last list's rows come last")

        self.run_with(workflow, rows={}, matches={key: 3 for key in keys})

    def test_rows_stop_being_downloadable_when_their_list_or_search_is_replaced(self):
        async def workflow(service, searches, lists):
            lists.fail[ROUTE_B] = ManifestError(
                "invalid_query", "type at least three characters of a file name")
            started = await service.start("fi", ["primary"], [ROUTE_A, ROUTE_B])
            summary = await finished(service, started["group_id"])
            self.assertEqual(
                [(member["kind"], member["state"], member["result_count"], member["note"])
                 for member in summary["members"]],
                [("source", "complete", 1, None), ("list", "complete", 2, None),
                 ("list", "failed", 0, "type at least three characters of a file name")])
            page = await service.page(started["group_id"], offset=0, limit=10)
            self.assertEqual([row["selection_available"] for row in page["results"]],
                             [True, True, True])

            # The same file server's list is added again: the old rows are history.
            lists.listed_at[ROUTE_A] = "2026-10-14T09:00:00Z"
            await service.refresh(force=True)
            page = await service.page(started["group_id"], offset=0, limit=10)
            self.assertEqual(
                [(row["selection_available"], row["result_id"]) for row in page["results"]],
                [(True, "row-primary-0"), (False, None), (False, None)])
            self.assertTrue(page["members"][1]["historical"])

            # The source searched again elsewhere: its rows here are history too.
            searches.historical.update(searches.found)
            page = await service.page(started["group_id"], offset=0, limit=10)
            self.assertEqual([row["selection_available"] for row in page["results"]],
                             [False, False, False])

            # A list whose source was removed is not downloadable either.
            again = await service.start("fixture", [], [ROUTE_A])
            await finished(service, again["group_id"])
            lists.source_label[ROUTE_A] = None
            await service.refresh(force=True)
            page = await service.page(again["group_id"], offset=0, limit=10)
            self.assertEqual([row["selection_available"] for row in page["results"]],
                             [False, False])
            self.assertEqual(len(await service.history()), 2)

        self.run_with(workflow, rows={"primary": 1}, matches={ROUTE_A: 2, ROUTE_B: 5})

    def test_an_unexpected_failure_ends_the_search_and_asks_nothing_more(self):
        async def workflow(service, searches, lists):
            searches.broken.add("primary")
            with self.assertLogs("dccatlas.web", level="ERROR"):
                started = await service.start("fixture", ["primary", "bot"])
                summary = await finished(service, started["group_id"])
            # It is over, not left showing as running, and the source after
            # the failure was not asked.
            self.assertEqual(summary["state"], "interrupted")
            self.assertEqual(searches.calls, [("fixture", "primary")])
            self.assertEqual([member["state"] for member in summary["members"]],
                             ["interrupted", "interrupted"])
            # The next search starts normally.
            searches.broken.clear()
            again = await service.start("fixture", ["bot"])
            self.assertEqual((await finished(service, again["group_id"]))["state"], "complete")

        self.run_with(workflow, rows={"primary": 1, "bot": 2}, matches={})

    def test_a_restart_ends_a_running_combined_search(self):
        async def body():
            with tempfile.TemporaryDirectory() as directory:
                database = Path(directory) / "fserve.sqlite3"
                searches = FakeSearches(database, {"primary": "Servers"}, {"primary": 1})
                lists = FakeLists({ROUTE_A: 1})
                first = MultiSearchService(searches, lists)
                # Recorded as running, as if the application stopped mid-search.
                first.store.create("multi-" + "1" * 32, "fixture", [
                    {"kind": "source", "source_id": "primary", "label": "Servers",
                     "channel": "#primary"},
                    {"kind": "list", "route_key": ROUTE_A, "source_id": "primary",
                     "label": "Fixture !a", "channel": "Lab",
                     "listed_at": "2026-10-13T10:00:00Z"}])
                second = MultiSearchService(searches, lists)
                await second.startup()
                summary = await second.status("multi-" + "1" * 32)
                self.assertEqual(
                    (summary["state"], [member["state"] for member in summary["members"]]),
                    ("interrupted", ["interrupted", "interrupted"]))
                self.assertEqual((searches.calls, lists.searches), ([], []))
        asyncio.run(body())


if __name__ == "__main__":
    unittest.main()
