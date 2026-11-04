"""Offline W3 search-history, pagination and selection tests."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from web_bridge_test import IRCFixture, NativeIrssi
from web_source_test import ReusableIRCFixture, source_values, wait_source
from webapp.engine_client import EngineClient, EngineEvent, EngineRequestError
from webapp.searches import (MAX_PAGE_SIZE, MAX_RESULTS, MIN_PAGE_INTERVAL,
                             MIN_POLL_INTERVAL, SearchError, SearchService,
                             validate_terms)
from webapp.sources import SourceService


class SearchFixture(ReusableIRCFixture):
    def __init__(self):
        super().__init__()
        self.find_lines = []

    def handle_line(self, raw: bytes):
        if raw.startswith(b"PRIVMSG #review :@find "):
            self.find_lines.append(raw)
        super().handle_line(raw)


class SearchServiceNativeTests(unittest.TestCase):
    def test_exact_unquoted_query_persistence_pages_and_stale_selection(self):
        fixture = SearchFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                native.command("/set fscrawl_find_quiet_ms 250")

                async def workflow():
                    engine = await EngineClient.open(str(native.path))
                    searches = None
                    try:
                        with tempfile.TemporaryDirectory() as directory:
                            try:
                                sources = SourceService(Path(directory) / "fserve.sqlite3", engine)
                                await sources.save(source_values(fixture.port))
                                await sources.connect()
                                await wait_source(engine, {"ready"})
                                searches = SearchService(sources)
                                await searches.startup()

                                first = await searches.search("Jane Example!")
                                first = await wait_search(searches, first["search_id"])
                                self.assertEqual(first["state"], "complete")
                                self.assertEqual(fixture.find_count, 1)
                                self.assertEqual(fixture.find_lines,
                                                 [b"PRIVMSG #review :@find Jane Example!"])

                                first_page = await searches.page(first["search_id"], offset=0, limit=10)
                                self.assertEqual(len(first_page["results"]), 1)
                                result = first_page["results"][0]
                                self.assertEqual(result["sender"], "Fixture")
                                self.assertEqual(result["trigger"], "!Fixture")
                                self.assertEqual(result["trigger_mode"], "channel_text")
                                self.assertEqual(result["path"], "/books/fixture.txt")
                                self.assertEqual(result["size_text"], "4 B")
                                self.assertEqual(result["size_precision"], "exact")
                                self.assertEqual(result["size_bytes_exact"], 4)
                                self.assertIsNone(result["size_bytes_estimate"])
                                self.assertTrue(result["selection_available"])
                                internal = await searches.resolve_result(result["result_id"])
                                self.assertEqual(internal["engine_instance_id"], engine.engine_instance_id)
                                self.assertEqual(internal["remote_path"], "/books/fixture.txt")
                                self.assertEqual(internal["trigger"], "!Fixture")
                                self.assertNotIn("engine_selection_id", result)

                                await sources.disconnect()
                                await sources.connect()
                                await wait_source(engine, {"ready"})
                                with self.assertRaises(SearchError) as reconnected:
                                    await searches.resolve_result(result["result_id"])
                                self.assertEqual(reconnected.exception.code, "stale_result")

                                history = await searches.history(limit=20)
                                self.assertEqual(len(history), 1)
                                self.assertTrue(history[0]["historical"])
                            finally:
                                if searches is not None:
                                    await searches.close()
                    finally:
                        await engine.close()

                asyncio.run(workflow())
        finally:
            fixture.stop()


async def wait_search(searches: SearchService, search_id: str, timeout: float = 12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = await searches.status(search_id)
        if status["state"] != "collecting":
            return status
        await asyncio.sleep(.1)
    raise AssertionError(f"search did not finish: {await searches.status(search_id)!r}")


class SearchHistoryTests(unittest.TestCase):
    def test_query_validation_preserves_text_and_rejects_controls_and_oversize(self):
        self.assertEqual(validate_terms("Jane Example!"), "Jane Example!")
        # A search bot's reply is recognised by a file name built from the
        # text, so only text with a known file name is accepted for one.
        self.assertEqual(validate_terms("Jane Example 2", "searchbot"), "Jane Example 2")
        for value in ("it's", "a+b", "a.b", "caf\u00e9", "!", "  "):
            with self.subTest(searchbot=value), self.assertRaises(SearchError):
                validate_terms(value, "searchbot")
        self.assertEqual(validate_terms('two "words"'), 'two "words"')
        for value in ("", "  ", "line\nbreak", "x" * 351):
            with self.subTest(value=value), self.assertRaises(SearchError):
                validate_terms(value)

    def test_store_retention_cap_and_restart_never_recover_engine_tokens(self):
        with tempfile.TemporaryDirectory() as directory:
            sources = SourceService(Path(directory) / "fserve.sqlite3", object())
            config, _, _ = sources.store.save(source_values(6667))
            store = SearchService(sources).store
            first = store.create(
                search_id="search-" + "a" * 32, source=config,
                engine_instance_id="engine-one", operation_id="operation-one",
                terms="exact query", started_at=10.0,
            )
            store.update(first["search_id"], engine_search_id="find-engine-one-1",
                         state="complete", engine_state="complete", result_count=MAX_RESULTS + 7,
                         completed_at=11.0)
            self.assertEqual(store.get(first["search_id"])["capped"], 1)
            self.assertEqual(store.count_results(first["search_id"]), 0)

            for index in range(1, 33):
                store.create(
                    search_id="search-" + f"{index:032x}", source=config,
                    engine_instance_id="engine-one", operation_id=f"operation-{index}",
                    terms=f"query {index}", started_at=20.0 + index,
                )
            self.assertEqual(len(store.recent(100)), 30)
            self.assertIsNone(store.get(first["search_id"]))

            active = store.create(
                search_id="search-" + "f" * 32, source=config,
                engine_instance_id="engine-one", operation_id="operation-active",
                terms="active query", started_at=99.0,
            )
            store.update(active["search_id"], engine_search_id="find-engine-one-99",
                         state="collecting", engine_state="collecting")
            # Reconstructing a service is the app-restart boundary: only its
            # persistent display row survives; its in-memory bridge token map does not.
            restarted = SearchService(sources)
            restarted.store.mark_open_interrupted("restart")
            restored = restarted.store.get(active["search_id"])
            self.assertEqual(restored["state"], "interrupted")
            self.assertIsNone(restarted._selection_tokens.get(active["search_id"]))

    def test_fake_engine_pagination_duplicate_names_and_visible_result_cap(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = FakeSearchEngine()
            sources = SourceService(Path(directory) / "fserve.sqlite3", engine)
            config, _, _ = sources.store.save(source_values(6667))
            engine.source = dict(config.engine_arguments(), state="ready")

            async def workflow():
                service = SearchService(sources)
                await service.startup()
                first = await service.search("Jane Example!")
                self.assertEqual(engine.find_calls, 1)
                self.assertEqual(engine.find_terms, ["Jane Example!"])
                with self.assertRaises(SearchError) as active:
                    await service.search("must not dispatch")
                self.assertEqual(active.exception.code, "search_active")
                self.assertEqual(engine.find_calls, 1)
                engine.current_search["state"] = "complete"
                # Exercise the cap projection independently of result-page
                # reconciliation; the fake provider only has two rows.
                service.store.update(first["search_id"], result_count=1001)
                summary = service._public_summary(
                    service.store.get(first["search_id"]), historical=False
                )
                self.assertTrue(summary["capped"])
                self.assertIn("first 1,000", summary["cap_notice"])
                service.store.update(first["search_id"], result_count=2)

                # Fetch the later ordinal first: database pagination must not
                # depend on earlier rows already being present or visited.
                page_b = await service.page(first["search_id"], offset=1, limit=1)
                # Pin the limiter's clock so a slow first fetch cannot
                # carry this request past the minimum interval.
                service._last_page_fetch[first["search_id"]] = time.monotonic()
                with self.assertRaises(SearchError) as rate_limited:
                    await service.page(first["search_id"], offset=1, limit=1)
                self.assertEqual(rate_limited.exception.code, "poll_too_fast")
                await asyncio.sleep(MIN_PAGE_INTERVAL)
                page_a = await service.page(first["search_id"], offset=0, limit=1)
                self.assertEqual(page_a["results"][0]["path"], "/A/Duplicate.txt")
                self.assertEqual(page_b["results"][0]["path"], "/B/Duplicate.txt")
                self.assertNotEqual(page_a["results"][0]["row_key"],
                                    page_b["results"][0]["row_key"])
                self.assertEqual(page_a["results"][0]["size_precision"], "estimated")
                self.assertIsNone(page_a["results"][0]["size_bytes_exact"])
                self.assertEqual(page_a["results"][0]["size_bytes_estimate"], 1229)
                self.assertEqual(page_b["results"][0]["size_bytes_exact"], 4)
                with self.assertRaises(SearchError):
                    await service.page(first["search_id"], offset=0, limit=MAX_PAGE_SIZE + 1)

                first_id = page_a["results"][0]["result_id"]
                self.assertEqual((await service.resolve_result(first_id))[
                    "engine_selection_id"], "sel-" + "1" * 40)
                second = await service.search("second query")
                self.assertEqual(engine.find_calls, 2)
                self.assertEqual(engine.find_terms, ["Jane Example!", "second query"])
                with self.assertRaises(SearchError) as replaced:
                    await service.resolve_result(first_id)
                self.assertEqual(replaced.exception.code, "stale_result")
                engine.current_search["state"] = "complete"
                second_status = await service.status(second["search_id"])
                self.assertEqual(second_status["state"], "complete")

                saved = service.store.get(first["search_id"])
                self.assertEqual(saved["terms"], "Jane Example!")
                self.assertEqual(saved["source_revision"], 1)
                self.assertGreater(saved["started_at"], 0)
                second_saved = service.store.get(second["search_id"])
                self.assertEqual(second_saved["terms"], "second query")
                second_page = await service.page(second["search_id"], offset=0, limit=1)
                second_result_id = second_page["results"][0]["result_id"]
                restarted = SearchService(sources)
                await restarted.startup()
                with self.assertRaises(SearchError) as after_restart:
                    await restarted.resolve_result(second_result_id)
                self.assertEqual(after_restart.exception.code, "stale_result")
                self.assertTrue((await restarted.history(limit=20))[0]["historical"])
                # A source edit retires only the selection authority; old rows remain history.
                sources.store.save(source_values(6667, label="edited"))
                with self.assertRaises(SearchError) as stale:
                    await service.resolve_result(second_result_id)
                self.assertEqual(stale.exception.code, "stale_result")
                await restarted.close()
                await service.close()

            asyncio.run(workflow())


class SearchEventRaceTests(unittest.TestCase):
    def test_events_racing_find_ack_are_reconciled_into_restart_history(self):
        async def workflow():
            with tempfile.TemporaryDirectory() as directory:
                reader = asyncio.StreamReader()
                writer = InMemoryBridgeWriter(reader)
                engine = EngineClient(reader, writer, "race-engine", 0)
                engine._reader_task = asyncio.create_task(engine._read_loop())
                sources = SourceService(Path(directory) / "fserve.sqlite3", engine)
                config, _, _ = sources.store.save(source_values(6667))
                writer.source = dict(config.engine_arguments(), state="ready")
                service = SearchService(sources)
                try:
                    search = await service.search("racing events")
                    self.assertEqual(search["state"], "collecting")
                    status = await service.status(search["search_id"])
                    self.assertEqual(status["state"], "complete")
                    self.assertEqual(status["result_count"], 2)
                    self.assertEqual(service.store.count_results(search["search_id"]), 2)

                    result_id = service.store.page(search["search_id"], 0, 1)[0]["row_id"]
                    await service.close()
                    restarted = SearchService(sources)
                    await restarted.startup()
                    historical = await restarted.page(search["search_id"], offset=0, limit=2)
                    self.assertTrue(historical["historical"])
                    self.assertEqual([row["ordinal"] for row in historical["results"]], [1, 2])
                    self.assertTrue(all(row["result_id"] is None for row in historical["results"]))
                    with self.assertRaises(SearchError) as unavailable:
                        await restarted.resolve_result(result_id)
                    self.assertEqual(unavailable.exception.code, "stale_result")
                    await restarted.close()
                finally:
                    if service._started:
                        await service.close()
                    await engine.close()

        asyncio.run(workflow())

    def test_new_completion_event_wins_over_status_waiting_behind_recovery(self):
        async def workflow():
            with tempfile.TemporaryDirectory() as directory:
                engine = HeldStatusSearchEngine()
                sources = SourceService(Path(directory) / "fserve.sqlite3", engine)
                config, _, _ = sources.store.save(source_values(6667))
                engine.source = dict(config.engine_arguments(), state="ready")
                service = SearchService(sources)
                polls = []
                try:
                    search = await service.search("poll ordering")
                    search_id = search["search_id"]
                    polls.append(asyncio.create_task(service.status(search_id)))
                    await asyncio.wait_for(engine.page_started.wait(), 2)
                    await asyncio.sleep(MIN_POLL_INTERVAL + 0.01)
                    polls.append(asyncio.create_task(service.status(search_id)))
                    await asyncio.wait_for(engine.second_poll.wait(), 2)

                    engine.current_search["state"] = "complete"
                    engine.last_event_sequence = 1
                    await engine.events.put(EngineEvent(
                        1, "search.state", dict(engine.current_search)
                    ))
                    async def wait_for_completion():
                        while service.store.get(search_id)["state"] != "complete":
                            await asyncio.sleep(0)
                    await asyncio.wait_for(wait_for_completion(), 2)

                    engine.release_page.set()
                    await asyncio.wait_for(asyncio.gather(*polls), 2)
                    saved = service.store.get(search_id)
                    self.assertEqual(saved["state"], "complete")
                    self.assertEqual(saved["result_count"], 2)
                    first_result = service.store.page(search_id, 0, 1)[0]
                    await service.resolve_result(first_result["row_id"])

                    await service.close()
                    restarted = SearchService(sources)
                    try:
                        await restarted.startup()
                        historical = await restarted.history(limit=1)
                        self.assertEqual(historical[0]["state"], "complete")
                        self.assertTrue(historical[0]["historical"])
                        with self.assertRaises(SearchError) as stale:
                            await restarted.resolve_result(first_result["row_id"])
                        self.assertEqual(stale.exception.code, "stale_result")
                    finally:
                        await restarted.close()
                finally:
                    engine.release_page.set()
                    for task in polls:
                        if not task.done():
                            task.cancel()
                    await asyncio.gather(*polls, return_exceptions=True)
                    if service._started:
                        await service.close()

        asyncio.run(workflow())


class InMemoryBridgeWriter:
    """Feed coalesced bridge events and replies through EngineClient's reader."""

    def __init__(self, reader):
        self.reader = reader
        self.source = None
        self.search = None
        self.sequence = 0

    def _event(self, name, payload):
        self.sequence += 1
        return {
            "protocol_version": 1, "type": "event", "event_sequence": self.sequence,
            "engine_instance_id": "race-engine", "event": name, "payload": payload,
        }

    def write(self, data):
        request = json.loads(data)
        response = {
            "protocol_version": 1, "request_id": request["request_id"], "ok": True,
        }
        operation = request["operation"]
        if operation == "status":
            response["result"] = {
                "engine_instance_id": "race-engine", "event_sequence": self.sequence,
                "source": self.source, "search": self.search,
            }
            records = [response]
        elif operation == "search.find":
            self.search = {
                "search_id": "find-race-engine-1", "source_id": "primary",
                "state": "collecting", "result_count": 0, "results": [],
            }
            records = [self._event("search.state", dict(self.search))]
            response["result"] = dict(self.search)
            records.append(response)
            for result in FAKE_RESULTS:
                records.append(self._event("search.result", {
                    "search_id": self.search["search_id"], "result": result,
                }))
            self.search = dict(self.search, state="complete", result_count=len(FAKE_RESULTS))
            records.append(self._event("search.state", dict(self.search)))
        elif operation == "search.status":
            arguments = request["arguments"]
            offset, limit = arguments.get("offset", 0), arguments.get("limit", MAX_PAGE_SIZE)
            response["result"] = dict(
                self.search, results=FAKE_RESULTS[offset:offset + limit]
            )
            records = [response]
        else:
            raise AssertionError(f"unexpected bridge operation: {operation}")
        self.reader.feed_data(b"".join(
            json.dumps(record).encode("utf-8") + b"\n" for record in records
        ))

    async def drain(self):
        return None

    def close(self):
        return None

    async def wait_closed(self):
        return None


class FakeSearchEngine:
    engine_instance_id = "fake-engine-instance"

    def __init__(self):
        self.events = asyncio.Queue()
        self.find_calls = 0
        self.find_terms = []
        self.source = None
        self.current_search = None

    async def status(self):
        return {
            "engine_instance_id": self.engine_instance_id,
            "event_sequence": 0,
            "source": self.source,
            "search": self.current_search,
        }

    async def request(self, operation, arguments=None, *, operation_id=None, timeout=10):
        arguments = arguments or {}
        if operation == "search.find":
            self.find_calls += 1
            self.find_terms.append(arguments["terms"])
            self.current_search = {
                "search_id": f"find-fake-engine-{self.find_calls}", "source_id": arguments["source_id"],
                "state": "collecting", "terms": arguments["terms"],
                "channel": self.source["channel"], "started_at": time.time(),
                "result_count": 2, "results": [],
            }
            return dict(self.current_search)
        if operation == "search.status":
            if self.current_search is None or arguments["search_id"] != self.current_search["search_id"]:
                raise EngineRequestError("stale_search", "search is no longer current")
            offset, limit = arguments.get("offset", 0), arguments.get("limit", 10)
            return dict(self.current_search, results=FAKE_RESULTS[offset:offset + limit])
        if operation == "source.configure":
            self.source = dict(arguments, state="ready")
            return {"source": self.source}
        raise AssertionError(f"unexpected bridge operation: {operation}")


class HeldStatusSearchEngine(FakeSearchEngine):
    def __init__(self):
        super().__init__()
        self.last_event_sequence = 0
        self.page_started = asyncio.Event()
        self.release_page = asyncio.Event()
        self.second_poll = asyncio.Event()
        self.poll_count = 0

    async def status(self):
        status = await super().status()
        if self.current_search is not None:
            status["search"] = dict(self.current_search)
            self.poll_count += 1
            if self.poll_count == 2:
                self.second_poll.set()
        return status

    async def request(self, operation, arguments=None, **kwargs):
        if operation == "search.status" and not self.page_started.is_set():
            self.page_started.set()
            await self.release_page.wait()
        return await super().request(operation, arguments, **kwargs)


FAKE_RESULTS = [
    {
        "selection_id": "sel-" + "1" * 40, "ordinal": 1,
        "source_id": "primary", "source_revision": 1, "sender": "FileBot",
        "trigger": "!files", "trigger_mode": "ctcp", "path": "/A/Duplicate.txt",
        "size_text": "1.2 KB", "size_bytes": 1229, "size_precision": "estimated",
    },
    {
        "selection_id": "sel-" + "2" * 40, "ordinal": 2,
        "source_id": "primary", "source_revision": 1, "sender": "FileBot",
        "trigger": "!files", "trigger_mode": "ctcp", "path": "/B/Duplicate.txt",
        "size_text": "4 B", "size_bytes": 4, "size_precision": "exact",
    },
]


if __name__ == "__main__":
    unittest.main()
