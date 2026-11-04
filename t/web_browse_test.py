"""Browsing a file server from the page (2026-10-21), against a stand-in engine."""

from __future__ import annotations

import asyncio
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from webapp.browse import MAX_KEPT, SHOWN_FOUND, BrowseError, BrowseService, parent_of
from webapp.downloads import DownloadService
from webapp.engine_client import EngineRequestError
from webapp.sources import SourceService


def source_values(**overrides):
    values = dict(label="Lab", provider="sysreset_find", host="127.0.0.1", port=6667,
                  tls=False, nickname="BrowseTest", channel="#review")
    values.update(overrides)
    return values


ENTRIES = [
    {"type": "dir", "path": "/BOOKS", "read": True},
    {"type": "file", "path": "/readme.txt", "size_raw": "10B", "size_bytes": 10},
    {"type": "dir", "path": "/BOOKS/OLD", "read": False},
    {"type": "file", "path": "/BOOKS/one.epub", "size_raw": "2KB", "size_bytes": 2048},
    {"type": "file", "path": "/BOOKS/OLD/older.txt", "size_raw": "5B", "size_bytes": 5},
    {"type": "file", "path": "relative/is/refused"},
    {"type": "file", "path": "/bad\x07name"},
]


class BrowseEngine:
    engine_instance_id = "browse-engine"

    def __init__(self):
        self.calls = []
        self.view = {}
        self.state = "browsing"
        self.started = 0
        self.refusal = None

    async def status(self, *, timeout=10.0):
        return {"engine_instance_id": self.engine_instance_id,
                "sources": [{**self.view, "state": "ready", "connection_epoch": 1}]
                if self.view else []}

    async def request(self, operation, arguments=None, *, operation_id=None, timeout=10.0):
        arguments = dict(arguments or {})
        self.calls.append((operation, arguments, operation_id))
        if operation == "source.configure":
            self.view = dict(arguments)
            return {"source": self.view}
        if operation == "browse.start":
            if self.refusal:
                raise EngineRequestError(self.refusal, "fixture refusal")
            self.started += 1
            return {"browse_id": "browse-" + f"{self.started:032x}", "state": "browsing"}
        if operation == "browse.status":
            entries = ENTRIES if self.state != "browsing" else []
            offset, limit = arguments.get("offset", 0), arguments.get("limit", 0)
            return {"browse_id": arguments["browse_id"], "state": self.state,
                    "total": len(entries), "folders_read": 3, "truncated": True,
                    "note": "Only the first 3 folders were read.",
                    "entries": entries[offset:offset + limit]}
        raise AssertionError(operation)


class FakeSearches:
    def __init__(self, database, sources):
        self.sources = sources
        self.rows = {}
        self.store = SimpleNamespace(path=database, find_result=self.rows.get,
                                     get=lambda search_id: {"source_id": "primary"})

    def add(self, number, mode="channel_text"):
        result_id = "row-" + f"{number:032x}"
        self.rows[result_id] = {"search_id": "search-" + "a" * 32, "sender": "Fixture",
                                "trigger_text": "!Fixture", "trigger_mode": mode,
                                "remote_path": "/x", "size_bytes": 1, "provider": "sysreset_find"}
        return result_id


class BrowseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        database = Path(self.directory.name) / "fserve.sqlite3"
        self.engine = BrowseEngine()
        self.sources = SourceService(database, self.engine)
        asyncio.run(self.sources.save(source_values()))
        self.searches = FakeSearches(database, self.sources)
        self.downloads = DownloadService(self.sources, self.searches)
        self.browses = self.downloads.browses = BrowseService(self.downloads)

    def tearDown(self):
        self.directory.cleanup()

    def started(self):
        return asyncio.run(self.browses.start(self.searches.add(1)))

    def test_a_browse_is_followed_until_it_ends_then_kept(self):
        view = self.started()
        start = [call for call in self.engine.calls if call[0] == "browse.start"][0]
        self.assertEqual(start[1], {"source_id": "primary", "sender": "Fixture",
                                    "trigger": "!Fixture", "trigger_mode": "channel_text"})
        self.assertTrue(start[2].startswith("browse-op-"), "browsing carries an operation ID")
        self.assertEqual((view["state"], view["folders"], view["files"]), ("browsing", [], []))
        self.engine.state = "complete"
        root = asyncio.run(self.browses.view(view["browse_id"]))
        self.assertEqual(([f["name"] for f in root["folders"]], [f["name"] for f in root["files"]]),
                         (["BOOKS"], ["readme.txt"]))
        self.assertEqual((root["parent"], root["truncated"], root["note"]),
                         (None, True, "Only the first 3 folders were read."))
        books = asyncio.run(self.browses.view(view["browse_id"], "/BOOKS/"))
        self.assertEqual((books["path"], books["parent"]), ("/BOOKS", "/"))
        self.assertEqual([(f["name"], f["size_bytes"]) for f in books["files"]], [("one.epub", 2048)])
        self.engine.state = "browsing"   # the engine is not asked again once kept
        again = asyncio.run(self.browses.view(view["browse_id"], "/BOOKS/OLD"))
        self.assertEqual([f["path"] for f in again["files"]], ["/BOOKS/OLD/older.txt"])
        self.assertEqual(asyncio.run(self.browses.history())[0]["files"], 3,
                         "unusable entries are left out")

    def test_a_browsed_file_resolves_to_a_checked_fetch_of_its_server(self):
        view = self.started()
        self.engine.state = "complete"
        books = asyncio.run(self.browses.view(view["browse_id"], "/BOOKS"))
        selection = asyncio.run(self.browses.resolve_result(books["files"][0]["result_id"]))
        self.assertEqual(selection["engine_operation"], "manifest.download")
        self.assertEqual(selection["engine_arguments"], {
            "source_id": "primary", "sender": "Fixture", "trigger": "!Fixture",
            "trigger_mode": "channel_text", "path": "/BOOKS/one.epub"})
        asyncio.run(self.sources.save(source_values(host="127.0.0.2")))
        with self.assertRaises(BrowseError) as moved:
            asyncio.run(self.browses.resolve_result(books["files"][0]["result_id"]))
        self.assertEqual(moved.exception.code, "stale_result")

    def test_what_cannot_be_browsed(self):
        with self.assertRaises(BrowseError) as posted:
            asyncio.run(self.browses.start(self.searches.add(2, mode="direct")))
        self.assertEqual(posted.exception.code, "not_browsable")
        self.engine.refusal = "transfer_busy"
        with self.assertRaises(BrowseError) as busy:
            asyncio.run(self.browses.start(self.searches.add(3)))
        self.assertEqual(busy.exception.code, "transfer_busy")
        self.engine.refusal = None
        view = self.started()
        for path in ("relative", "/a\x01b", 5):
            with self.assertRaises(BrowseError):
                asyncio.run(self.browses.view(view["browse_id"], path))
        with self.assertRaises(BrowseError):
            asyncio.run(self.browses.view("browse-nope"))

    def seen(self, nick, triggers, **extra):
        """An advert as the advert service keeps it, for the configured source."""
        from webapp.adverts import endpoint_of
        config = self.sources.store.get("primary")
        advert = {"nick": nick, "triggers": triggers, **extra}
        self.browses.adverts.merge("primary", endpoint_of(config), [(advert, 1.0, 2.0, 1)])

    def test_a_file_server_seen_announcing_is_browsed_by_its_own_trigger(self):
        self.seen("Irssiserve", [{"trigger": "!irssi", "kind": "ctcp", "ctcp_nick": "Irssiserve",
                                  "ctcp_nick_is_sender": True, "voice_only": False}],
                  script="fserve.pl")
        self.seen("Lab", [{"trigger": "!fserve", "kind": "channel", "voice_only": False}])
        view = asyncio.run(self.browses.start_from_advert("primary", "irssiSERVE", "!irssi"))
        self.assertEqual(view["state"], "browsing")
        asyncio.run(self.browses.start_from_advert("primary", "Lab", "!fserve"))
        starts = [call[1] for call in self.engine.calls if call[0] == "browse.start"]
        self.assertEqual(starts, [
            {"source_id": "primary", "sender": "Irssiserve", "trigger": "!irssi",
             "trigger_mode": "ctcp"},
            {"source_id": "primary", "sender": "Lab", "trigger": "!fserve",
             "trigger_mode": "channel_text"},
        ], "the announced nick and trigger, sent as announced")

    def test_an_advert_trigger_that_should_not_be_sent_is_refused(self):
        self.seen("Voiced", [{"trigger": "!v", "kind": "channel", "voice_only": True}])
        self.seen("Ops", [{"trigger": "!o", "kind": "channel", "voice_only": False}],
                  restricted="OP")
        self.seen("Mallory", [{"trigger": "!x", "kind": "ctcp", "ctcp_nick": "Other",
                               "ctcp_nick_is_sender": False, "voice_only": False}])
        self.seen("Plain", [{"trigger": "!plain", "kind": "channel", "voice_only": False}])
        cases = (
            (("primary", "Voiced", "!v"), "not_browsable"),
            (("primary", "Ops", "!o"), "not_browsable"),
            (("primary", "Mallory", "!x"), "not_browsable"),
            (("primary", "Plain", "!other"), "unknown_advert"),
            (("primary", "Nobody", "!plain"), "unknown_advert"),
            (("nowhere", "Plain", "!plain"), "unknown_source"),
            (("primary", "", "!plain"), "invalid_advert"),
            (("primary", "Plain", None), "invalid_advert"),
        )
        for arguments, code in cases:
            with self.assertRaises(BrowseError) as caught:
                asyncio.run(self.browses.start_from_advert(*arguments))
            self.assertEqual(caught.exception.code, code, arguments)
        self.assertNotIn("browse.start", [call[0] for call in self.engine.calls],
                         "nothing was sent for any of them")
        asyncio.run(self.sources.save(source_values(host="127.0.0.2")))
        with self.assertRaises(BrowseError) as moved:
            asyncio.run(self.browses.start_from_advert("primary", "Plain", "!plain"))
        self.assertEqual(moved.exception.code, "unknown_advert",
                         "a server seen on the source's old network is not browsed")

    def test_an_engine_restart_ends_a_running_browse_and_old_ones_are_dropped(self):
        view = self.started()
        self.engine.engine_instance_id = "another-engine"
        ended = asyncio.run(self.browses.view(view["browse_id"]))
        self.assertEqual(ended["state"], "failed")
        self.assertIn("restarted", ended["note"])
        for _ in range(MAX_KEPT + 2):
            self.started()
        self.assertEqual(len(asyncio.run(self.browses.history())), MAX_KEPT)

    def test_a_folder_not_read_says_so_and_can_be_browsed_from(self):
        view = self.started()
        self.engine.state = "complete"
        self.assertTrue(asyncio.run(self.browses.view(view["browse_id"]))["read"], "the start")
        books = asyncio.run(self.browses.view(view["browse_id"], "/BOOKS"))
        self.assertTrue(books["read"])
        self.assertEqual(books["folders"], [{"name": "OLD", "path": "/BOOKS/OLD", "read": False}])
        old = asyncio.run(self.browses.view(view["browse_id"], "/BOOKS/OLD"))
        self.assertFalse(old["read"], "only what /BOOKS named of it is known")
        self.engine.state = "browsing"
        again = asyncio.run(self.browses.start_from(view["browse_id"], "/BOOKS/OLD"))
        start = [call for call in self.engine.calls if call[0] == "browse.start"][-1]
        self.assertEqual((start[1]["path"], start[1]["sender"]), ("/BOOKS/OLD", "Fixture"))
        self.assertEqual((again["start_path"], again["path"]), ("/BOOKS/OLD", "/BOOKS/OLD"))

    def test_a_big_folder_says_how_much_is_not_shown(self):
        from webapp import browse
        view = self.started()
        self.engine.state = "complete"
        original, browse.SHOWN_PER_FOLDER = browse.SHOWN_PER_FOLDER, 0
        try:
            root = asyncio.run(self.browses.view(view["browse_id"]))
        finally:
            browse.SHOWN_PER_FOLDER = original
        self.assertEqual((root["folders"], root["files"], root["more_folders"], root["more_files"]),
                         ([], [], 1, 1))

    def test_a_browse_table_from_before_read_marks_is_carried_over(self):
        import sqlite3
        from contextlib import closing
        database = self.browses.store.path
        with closing(sqlite3.connect(database)) as connection, connection:
            connection.execute("DROP TABLE browse_entry")
            connection.execute("DROP TABLE browse")
            connection.execute("""CREATE TABLE browse (browse_id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL, source_revision INTEGER NOT NULL, host TEXT NOT NULL,
                port INTEGER NOT NULL, channel TEXT NOT NULL, sender TEXT NOT NULL,
                trigger_text TEXT NOT NULL, trigger_mode TEXT NOT NULL,
                engine_instance_id TEXT NOT NULL, state TEXT NOT NULL, note TEXT,
                truncated INTEGER NOT NULL DEFAULT 0, folders_read INTEGER NOT NULL DEFAULT 0,
                started_at REAL NOT NULL, finished_at REAL)""")
            connection.execute("""CREATE TABLE browse_entry (browse_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL, kind TEXT NOT NULL, path TEXT NOT NULL,
                parent TEXT NOT NULL, size_raw TEXT, size_bytes INTEGER,
                PRIMARY KEY (browse_id, ordinal))""")
        self.browses = self.downloads.browses = BrowseService(self.downloads)
        view = self.started()
        self.assertEqual(view["start_path"], "/")

    def test_files_are_found_anywhere_in_what_was_read_without_asking_the_engine(self):
        view = self.started()
        with self.assertRaises(BrowseError) as early:
            asyncio.run(self.browses.find(view["browse_id"], "one"))
        self.assertEqual(early.exception.code, "still_browsing")
        self.engine.state = "complete"
        asyncio.run(self.browses.view(view["browse_id"]))
        asked = len(self.engine.calls)
        found = asyncio.run(self.browses.find(view["browse_id"], "OLD  txt"))
        self.assertEqual([(f["path"], f["folder"]) for f in found["files"]],
                         [("/BOOKS/OLD/older.txt", "/BOOKS/OLD")],
                         "every word, in any case, anywhere in the path")
        self.assertEqual((found["total"], found["more_files"], found["terms"]), (1, 0, "OLD  txt"))
        books = asyncio.run(self.browses.find(view["browse_id"], "books"))
        self.assertEqual([f["name"] for f in books["files"]], ["older.txt", "one.epub"],
                         "a folder's name finds the files under it, in path order")
        selection = asyncio.run(self.browses.resolve_result(books["files"][1]["result_id"]))
        self.assertEqual(selection["engine_arguments"]["path"], "/BOOKS/one.epub",
                         "a file found is fetched as a browsed one is")
        self.assertEqual(asyncio.run(self.browses.find(view["browse_id"], "100%_"))["files"], [],
                         "the words are not patterns")
        calls = [call[0] for call in self.engine.calls[asked:]]
        self.assertNotIn("browse.start", calls)
        self.assertNotIn("browse.status", calls, "finding reads only what is kept")
        for bad in ("", "   ", "x" * 101, "a\x07b", 7, None):
            with self.assertRaises(BrowseError) as caught:
                asyncio.run(self.browses.find(view["browse_id"], bad))
            self.assertEqual(caught.exception.code, "invalid_find", repr(bad))

    def test_a_find_shows_a_bounded_number_of_files(self):
        view = self.started()
        many = [{"type": "file", "path": f"/BIG/book{n:04}.pdf", "size_bytes": n}
                for n in range(SHOWN_FOUND + 25)]
        ENTRIES_BEFORE = list(ENTRIES)
        ENTRIES[:] = many
        try:
            self.engine.state = "complete"
            found = asyncio.run(self.browses.find(view["browse_id"], "book"))
        finally:
            ENTRIES[:] = ENTRIES_BEFORE
        self.assertEqual((len(found["files"]), found["total"], found["more_files"]),
                         (SHOWN_FOUND, SHOWN_FOUND + 25, 25))

    def test_parent_of(self):
        self.assertEqual([parent_of(p) for p in ("/a", "/a/b", "/a/b/")], ["/", "/a", "/a"])


if __name__ == "__main__":
    unittest.main()
