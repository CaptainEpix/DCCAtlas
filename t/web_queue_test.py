"""The download queue (web M3, Y3)."""

from __future__ import annotations

import asyncio
from contextlib import closing
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from webapp.download_queue import (MAX_BUSY_RETRIES, MAX_WAITING, RETRY_MAX_SECONDS,
                                   RETRY_SECONDS, QueueError, QueueService)
from webapp.downloads import DownloadService
from webapp.engine_client import EngineRequestError
from webapp.sources import SourceService


def source_values(**overrides):
    values = dict(label="Lab", provider="sysreset_find", host="127.0.0.1", port=6667,
                  tls=False, nickname="QueueTest", channel="#review")
    values.update(overrides)
    return values


class QueueEngine:
    """Answers what the source, download and queue services ask of the engine."""

    engine_instance_id = "queue-engine"

    def __init__(self):
        self.calls: list[tuple[str, dict, str | None]] = []
        self.jobs: dict[str, dict] = {}
        self.view: dict = {}
        self.state = "ready"
        self.refusal: str | None = None
        self.epoch = 1                       # the source's connection
        self.search_state: str | None = None  # a search the engine is running
        self.holds: dict[str, dict] = {}      # rows kept for the queue, by hold ID
        self.held_refusal: str | None = None
        self._next = 0

    async def status(self, *, timeout=10.0):
        return {"engine_instance_id": self.engine_instance_id,
                "search": {"state": self.search_state} if self.search_state else None,
                "sources": [{**self.view, "state": self.state, "connection_epoch": self.epoch}]
                if self.view else []}

    async def request(self, operation, arguments=None, *, operation_id=None, timeout=10.0):
        arguments = dict(arguments or {})
        self.calls.append((operation, arguments, operation_id))
        if operation == "source.configure":
            self.view = dict(arguments)
            return {"source": self.view}
        if operation in ("source.login", "source.connect"):
            return {}
        if operation == "manifest.download":
            if self.refusal:
                raise EngineRequestError(self.refusal, "fixture refusal")
            self._next += 1
            job = {"job_id": f"job-{self._next:032x}", "web_operation_id": operation_id,
                   "state": "preparing", "transition_sequence": 2, "outcome": None,
                   "reason": None, "sender": arguments["sender"],
                   "name": arguments["path"].rsplit("/", 1)[-1],
                   "remote_path": arguments["path"], "download_path": None,
                   "bytes_received": 0, "total_bytes": None}
            self.jobs[operation_id] = job
            return {"job": dict(job)}
        if operation == "list.request":
            self._next += 1
            job = {"job_id": f"job-{self._next:032x}", "web_operation_id": operation_id,
                   "state": "awaiting_offer", "transition_sequence": 2, "outcome": None,
                   "reason": None, "sender": arguments["sender"],
                   "name": arguments["sender"] + "'s list",
                   "remote_path": arguments["sender"] + "'s list", "download_path": None,
                   "bytes_received": 0, "total_bytes": None}
            self.jobs[operation_id] = job
            return {"job": dict(job)}
        if operation == "searchbot.hold":
            hold_id = "hold-" + f"{len(self.holds) + 1:032x}"
            self.holds[hold_id] = dict(arguments)
            return {"hold_id": hold_id, "source_id": arguments["source_id"]}
        if operation == "searchbot.held_download":
            if self.held_refusal:
                raise EngineRequestError(self.held_refusal, "fixture refusal")
            hold = self.holds.pop(arguments["hold_id"])
            self._next += 1
            job = {"job_id": f"job-{self._next:032x}", "web_operation_id": operation_id,
                   "state": "preparing", "transition_sequence": 2, "outcome": None,
                   "reason": None, "sender": "Bot", "name": hold["selection_id"],
                   "remote_path": hold["selection_id"], "download_path": None,
                   "bytes_received": 0, "total_bytes": None}
            self.jobs[operation_id] = job
            return {"job": dict(job)}
        if operation == "job.find_by_operation":
            job = self.jobs.get(arguments["web_operation_id"])
            return {"job": dict(job) if job else None}
        if operation == "job.status":
            job = next((job for job in self.jobs.values() if job["job_id"] == arguments["job_id"]), None)
            return {"job": dict(job) if job else None}
        raise AssertionError(f"unexpected engine operation {operation}")

    def dispatched(self):
        return [(arguments["sender"], arguments["path"]) for operation, arguments, _ in self.calls
                if operation == "manifest.download"]

    def lists_asked(self):
        return [(arguments["sender"], arguments.get("advertised", False))
                for operation, arguments, _ in self.calls if operation == "list.request"]

    def posted(self):
        return [arguments["hold_id"] for operation, arguments, _ in self.calls
                if operation == "searchbot.held_download"]

    def settle(self, path, state, outcome=None):
        job = next(job for job in self.jobs.values() if job["remote_path"] == path)
        job.update(state=state, outcome=outcome, transition_sequence=job["transition_sequence"] + 1)


class FakeSearches:
    """Results of the current search, as the search service resolves them."""

    def __init__(self, database: Path, sources: SourceService):
        self.sources = sources
        self.rows: dict[str, dict] = {}
        self.store = SimpleNamespace(path=database, find_result=self.rows.get)

    def add(self, number: int, path: str, *, sender="Fixture", provider="sysreset_find",
            mode="channel_text"):
        result_id = "row-" + f"{number:032x}"
        if provider == "searchbot":
            mode = "searchbot"
        self.rows[result_id] = {"sender": sender, "trigger_text": "!" + sender,
                                "trigger_mode": mode, "remote_path": path,
                                "size_bytes": 10, "provider": provider}
        return result_id

    async def resolve_result(self, result_id):
        config = self.sources.store.get("primary")
        return {"search_id": "search-" + "f" * 32, "source_id": "primary",
                "source_revision": config.revision, "engine_instance_id": "queue-engine",
                "engine_search_id": "find-1", "engine_selection_id": "sel-" + result_id[-8:]}


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.database = Path(self.directory.name) / "fserve.sqlite3"
        self.engine = QueueEngine()
        self.sources = SourceService(self.database, self.engine)
        asyncio.run(self.sources.save(source_values()))
        self.searches = FakeSearches(self.database, self.sources)
        self.downloads = DownloadService(self.sources, self.searches)
        self.queue = QueueService(self.downloads)

    def tearDown(self):
        self.directory.cleanup()

    def add(self, number, path, **extra):
        return asyncio.run(self.queue.add(self.searches.add(number, path, **extra)))

    def tick(self, times=1):
        for _ in range(times):
            asyncio.run(self.queue.tick())
        return self.queue.view()

    def states(self):
        return [(item["name"], item["state"]) for item in self.queue.view()["items"]]

    def test_files_are_fetched_one_at_a_time_in_order_once_started(self):
        for number, name in enumerate(("a.txt", "b.txt", "c.txt"), 1):
            self.add(number, f"/books/{name}")
        self.tick(3)
        self.assertEqual(self.engine.dispatched(), [], "nothing is fetched before Start")
        asyncio.run(self.queue.start())
        self.tick(3)
        self.assertEqual(self.engine.dispatched(), [("Fixture", "/books/a.txt")],
                         "one file at a time")
        self.engine.settle("/books/a.txt", "complete")
        self.tick()
        self.assertEqual(self.engine.dispatched()[-1], ("Fixture", "/books/b.txt"))
        self.engine.settle("/books/b.txt", "complete")
        self.tick()
        self.engine.settle("/books/c.txt", "complete")
        view = self.tick(2)
        self.assertEqual(self.states(), [("c.txt", "done"), ("b.txt", "done"), ("a.txt", "done")])
        self.assertFalse(view["running"], "an emptied queue stops")
        self.assertIsNone(view["paused_reason"])
        operations = [operation_id for operation, _, operation_id in self.engine.calls
                      if operation == "manifest.download"]
        self.assertEqual(len(set(operations)), 3, "each file is its own operation")

    def test_get_list_waits_its_turn_while_a_file_is_fetched(self):
        # 2026-10-29: a second Get list was refused until the first was done.
        self.add(1, "/books/a.txt")
        asyncio.run(self.queue.start())
        self.tick()
        self.assertTrue(asyncio.run(self.queue.list_should_wait()), "a file is being fetched")
        asyncio.run(self.queue.add_list("primary", "Shelf"))
        with self.assertRaises(QueueError) as twice:
            asyncio.run(self.queue.add_list("primary", "shelf"))
        self.assertEqual(twice.exception.code, "already_queued")
        self.tick()
        self.assertEqual(self.engine.lists_asked(), [], "it waits for the file")
        self.engine.settle("/books/a.txt", "complete")
        self.tick(2)
        self.assertEqual(self.engine.lists_asked(), [("Shelf", False)])
        self.assertEqual(self.states()[0], ("Shelf's list", "running"))
        self.engine.settle("Shelf's list", "complete")
        view = self.tick(2)
        self.assertEqual(self.states()[0], ("Shelf's list", "done"))
        self.assertFalse(view["running"])

    def test_get_list_starts_a_paused_queue_of_lists_only(self):
        self.engine.search_state = "collecting"
        self.assertTrue(asyncio.run(self.queue.list_should_wait()), "a search is running")
        view = asyncio.run(self.queue.add_list("primary", "Shelf"))
        self.assertTrue(view["running"], "the press of Get list starts it")
        self.queue.store.set_retry_after(0)
        self.engine.search_state = None
        self.tick()
        self.assertEqual(self.engine.lists_asked(), [("Shelf", False)])
        # Files queued and not started still wait for Start.
        self.queue.store.set_state(running=False)
        self.engine.settle("Shelf's list", "complete")
        self.tick()
        self.add(2, "/books/b.txt")
        view = asyncio.run(self.queue.add_list("primary", "Pile"))
        self.assertFalse(view["running"], "not with another file waiting")
        self.tick()
        self.assertEqual(self.engine.lists_asked(), [("Shelf", False)])

    def test_the_page_vouches_for_a_queued_list_server(self):
        self.queue.adverts = SimpleNamespace(offers_list=lambda source_id, nick: nick == "Shelf",
                                             typed=lambda source_id, nick: nick == "Shelf")
        self.engine.search_state = "collecting"
        asyncio.run(self.queue.add_list("primary", "Shelf"))
        self.queue.store.set_retry_after(0)
        self.engine.search_state = None
        self.tick()
        self.assertEqual(self.engine.lists_asked(), [("Shelf", True)])
        # A typed nick's list may come from another nick (2026-11-02).
        self.assertEqual([arguments.get("typed") for operation, arguments, _ in self.engine.calls
                          if operation == "list.request"], [True])

    def test_a_file_that_has_gone_is_not_requested_and_the_queue_goes_on(self):
        self.add(1, "/books/gone.txt")
        self.add(2, "/books/here.txt")
        asyncio.run(self.queue.start())
        self.tick()
        self.engine.settle("/books/gone.txt", "stale", "live_parent_file_missing")
        self.tick()
        self.assertEqual(self.engine.dispatched()[-1], ("Fixture", "/books/here.txt"))
        self.assertIn(("gone.txt", "not_requested"), self.states())
        self.assertTrue(self.queue.view()["running"])

    def test_anything_else_pauses_the_queue(self):
        for outcome_state, outcome in (("refused_without_queue", "remote_refused"),
                                       ("failed", "session_not_opened"),
                                       ("cancelled", None), ("expired", "remote_queue_deadline")):
            with self.subTest(state=outcome_state):
                self.tearDown()   # each case starts from a fresh database
                self.setUp()
                self.add(1, "/books/one.txt")
                self.add(2, "/books/two.txt")
                asyncio.run(self.queue.start())
                self.tick()
                self.engine.settle("/books/one.txt", outcome_state, outcome)
                view = self.tick(3)
                self.assertFalse(view["running"])
                self.assertIn("one.txt did not arrive", view["paused_reason"])
                self.assertEqual(self.engine.dispatched(), [("Fixture", "/books/one.txt")],
                                 "the next file is not requested")
                self.assertIn(("one.txt", "stopped"), self.states())
                asyncio.run(self.queue.start())
                self.assertEqual(self.engine.dispatched()[-1], ("Fixture", "/books/two.txt"),
                                 "Start goes on with the next file")

    def test_a_file_waiting_on_the_server_holds_the_queue(self):
        self.add(1, "/books/one.txt")
        self.add(2, "/books/two.txt")
        asyncio.run(self.queue.start())
        self.tick()
        self.engine.settle("/books/one.txt", "remote_queued")
        self.tick(5)
        self.assertEqual(len(self.engine.dispatched()), 1)
        self.assertTrue(self.queue.view()["running"])
        self.engine.settle("/books/one.txt", "interrupted")
        view = self.tick()
        self.assertFalse(view["running"], "a stuck transfer pauses the queue")
        self.assertIn("needs attention", view["paused_reason"])

    def test_after_a_restart_the_queue_is_paused_and_nothing_is_sent_twice(self):
        self.add(1, "/books/one.txt")
        self.add(2, "/books/two.txt")
        asyncio.run(self.queue.start())
        self.tick()
        restarted = QueueService(DownloadService(self.sources, self.searches))
        view = restarted.view()
        self.assertFalse(view["running"])
        self.assertIn("restarted", view["paused_reason"])
        self.engine.settle("/books/one.txt", "complete")
        asyncio.run(restarted.tick())
        asyncio.run(restarted.tick())
        self.assertEqual(self.engine.dispatched(), [("Fixture", "/books/one.txt")],
                         "the file being fetched is followed, not sent again, and nothing new starts")
        self.assertIn(("one.txt", "done"), [(item["name"], item["state"]) for item in restarted.view()["items"]])

    def test_a_busy_engine_is_waited_for_and_nothing_is_paused(self):
        self.add(1, "/books/one.txt")
        self.engine.refusal = "search_active"
        asyncio.run(self.queue.start())
        view = self.queue.view()
        self.assertTrue(view["running"])
        self.assertEqual(self.states(), [("one.txt", "queued")])
        self.engine.refusal = None
        self.queue.store.set_retry_after(0)
        self.tick()
        self.assertEqual(self.states(), [("one.txt", "running")])
        keys = [operation_id for operation, _, operation_id in self.engine.calls
                if operation == "manifest.download"]
        self.assertEqual(len(set(keys)), 2, "the second try is a new operation")

    def test_busy_retries_wait_longer_each_time_then_pause(self):
        self.add(1, "/books/one.txt")
        self.engine.refusal = "transfer_busy"
        asyncio.run(self.queue.start())
        waits = []
        for _ in range(MAX_BUSY_RETRIES):
            state = self.queue.store.state()
            self.assertTrue(state["running"])
            waits.append(round(state["retry_after"] - time.time()))
            self.queue.store.set_retry_after(0)
            self.tick()
        self.assertEqual(waits, [min(RETRY_SECONDS * 2 ** n, RETRY_MAX_SECONDS)
                                 for n in range(MAX_BUSY_RETRIES)])
        view = self.queue.view()
        self.assertFalse(view["running"], "an engine that stays busy pauses the queue")
        self.assertIn("stayed busy", view["paused_reason"])
        self.assertEqual(self.states(), [("one.txt", "queued")], "the file was never requested")
        self.assertEqual(len(self.engine.dispatched()), MAX_BUSY_RETRIES + 1)
        self.engine.refusal = None
        asyncio.run(self.queue.start())
        self.assertEqual(self.states(), [("one.txt", "running")], "Start tries again")

    def test_a_running_search_is_waited_for_without_asking(self):
        self.add(1, "/books/one.txt")
        self.engine.search_state = "collecting"
        asyncio.run(self.queue.start())
        for _ in range(3):
            self.queue.store.set_retry_after(0)
            self.tick()
        self.assertTrue(self.queue.view()["running"])
        self.assertEqual(self.engine.dispatched(), [], "nothing is asked while a search runs")
        self.assertEqual(self.downloads.store.recent(50), [], "so no refused download is recorded")
        self.engine.search_state = "complete"
        self.queue.store.set_retry_after(0)
        self.tick()
        self.assertEqual(self.engine.dispatched(), [("Fixture", "/books/one.txt")])

    def test_a_reconnect_since_start_pauses(self):
        self.add(1, "/books/one.txt")
        self.add(2, "/books/two.txt")
        asyncio.run(self.queue.start())
        self.engine.epoch = 2   # the source dropped and came back
        self.engine.settle("/books/one.txt", "complete")
        self.tick()
        view = self.queue.view()
        self.assertFalse(view["running"])
        self.assertIn("reconnected since Start", view["paused_reason"])
        self.assertEqual(self.engine.dispatched(), [("Fixture", "/books/one.txt")])
        asyncio.run(self.queue.start())
        self.assertEqual(self.engine.dispatched()[-1], ("Fixture", "/books/two.txt"),
                         "after Start, the new connection is the queue's")

    def test_two_at_once_from_different_file_servers_once_the_first_is_received(self):
        self.add(1, "/books/one.txt", sender="First")
        self.add(2, "/books/two.txt", sender="First")
        self.add(3, "/books/three.txt", sender="Second")
        asyncio.run(self.queue.start())
        self.tick(2)
        self.assertEqual(self.engine.dispatched(), [("First", "/books/one.txt")],
                         "nothing beside a file still starting")
        self.engine.settle("/books/one.txt", "receiving")
        self.tick(2)
        self.assertEqual(len(self.engine.dispatched()), 1,
                         "the next in order is from the same file server, so it waits")
        self.engine.settle("/books/one.txt", "complete")
        self.tick()
        self.assertEqual(self.engine.dispatched()[-1], ("First", "/books/two.txt"))
        self.engine.settle("/books/two.txt", "receiving")
        self.tick(2)
        self.assertEqual(self.engine.dispatched()[-1], ("Second", "/books/three.txt"),
                         "another file server's file starts beside it")
        self.assertEqual(
            [arguments["at_once"] for operation, arguments, _ in self.engine.calls
             if operation == "manifest.download"], [2, 2, 2])
        self.engine.settle("/books/two.txt", "complete")
        self.engine.settle("/books/three.txt", "complete")
        self.tick(3)
        self.assertEqual(sorted(self.states()), [("one.txt", "done"), ("three.txt", "done"),
                                                 ("two.txt", "done")])

    def test_one_at_a_time_when_set_so(self):
        self.downloads.settings.update({"downloads_at_once": 1})
        self.add(1, "/books/one.txt", sender="First")
        self.add(2, "/books/two.txt", sender="Second")
        asyncio.run(self.queue.start())
        self.tick()
        self.engine.settle("/books/one.txt", "receiving")
        self.tick(3)
        self.assertEqual(self.engine.dispatched(), [("First", "/books/one.txt")])
        self.assertEqual(self.engine.calls[-1][1].get("at_once") if self.engine.calls else None,
                         None if self.engine.calls[-1][0] != "manifest.download" else 1)

    def test_a_stopped_file_can_be_queued_again_and_waits_for_start(self):
        self.add(1, "/books/one.txt")
        self.engine.refusal = "source_not_ready"
        asyncio.run(self.queue.start())
        self.assertEqual(self.states(), [("one.txt", "stopped")])
        self.engine.refusal = None
        stopped = self.queue.view()["items"][0]["item_id"]
        view = asyncio.run(self.queue.requeue(stopped))
        self.assertEqual(self.states(), [("one.txt", "queued")], "the stopped entry is replaced")
        self.assertNotEqual(view["items"][0]["item_id"], stopped)
        self.tick(2)
        dispatched = len(self.engine.dispatched())
        asyncio.run(self.queue.start())
        self.tick()
        self.assertEqual(len(self.engine.dispatched()), dispatched + 1, "asked for after Start")
        self.assertEqual(self.engine.dispatched()[-1], ("Fixture", "/books/one.txt"))

    def test_what_cannot_be_queued_again(self):
        self.add(1, "/books/one.txt")
        waiting = self.queue.view()["items"][0]["item_id"]
        for item_id, code in ((waiting, "not_requeueable"), ("queue-" + "0" * 32, "unknown_item"),
                              (None, "unknown_item")):
            with self.assertRaises(QueueError) as caught:
                asyncio.run(self.queue.requeue(item_id))
            self.assertEqual(caught.exception.code, code)
        self.engine.refusal = "source_not_ready"
        asyncio.run(self.queue.start())
        self.engine.refusal = None
        asyncio.run(self.sources.save(source_values(host="127.0.0.2")))
        with self.assertRaises(QueueError) as moved:
            asyncio.run(self.queue.requeue(waiting))
        self.assertEqual(moved.exception.code, "not_requeueable", "its source changed")

    def test_a_refusal_pauses(self):
        self.add(1, "/books/one.txt")
        self.engine.refusal = "source_not_ready"
        asyncio.run(self.queue.start())
        view = self.queue.view()
        self.assertFalse(view["running"])
        self.assertEqual(self.states(), [("one.txt", "stopped")])

    def test_a_changed_or_disconnected_source_pauses(self):
        self.add(1, "/books/one.txt")
        self.engine.state = "disconnected"
        asyncio.run(self.queue.start())
        view = self.tick()
        self.assertFalse(view["running"])
        self.assertIn("Connect Lab", view["paused_reason"])
        self.assertEqual(self.engine.dispatched(), [])
        self.engine.state = "ready"
        asyncio.run(self.sources.save(source_values(label="Renamed")))
        asyncio.run(self.queue.start())
        view = self.tick()
        self.assertIn("changed or removed", view["paused_reason"])
        self.assertEqual(self.states(), [("one.txt", "stopped")])
        self.assertEqual(self.engine.dispatched(), [])

    def test_a_download_started_by_hand_is_waited_for(self):
        self.add(1, "/books/one.txt")
        self.downloads.store.create_pending(
            operation_id=self.downloads._operation_id("by-hand-0000000000"),
            idempotency_key="by-hand-0000000000", result_id="row-" + "e" * 32,
            selection={"search_id": "s", "source_id": "primary", "source_revision": 1,
                       "engine_instance_id": "queue-engine", "engine_search_id": "x"})
        asyncio.run(self.queue.start())
        view = self.tick(3)
        self.assertTrue(view["running"])
        self.assertEqual(self.engine.dispatched(), [])

    def test_pause_lets_the_current_file_finish_and_starts_nothing_more(self):
        self.add(1, "/books/one.txt")
        self.add(2, "/books/two.txt")
        asyncio.run(self.queue.start())
        self.tick()
        asyncio.run(self.queue.pause())
        self.engine.settle("/books/one.txt", "complete")
        self.tick(3)
        self.assertEqual(self.states()[0], ("two.txt", "queued"))
        self.assertIn(("one.txt", "done"), self.states())
        self.assertEqual(len(self.engine.dispatched()), 1)

    def test_rows_to_post_back_are_kept_by_the_engine_and_fetched_from_that(self):
        bot = self.add(90, "bot one.epub", sender="Bot", provider="searchbot")
        direct = self.add(91, "Direct two.pdf", sender="Shelf", mode="direct")
        self.add(92, "/books/three.txt")
        holds = [arguments for operation, arguments, _ in self.engine.calls
                 if operation == "searchbot.hold"]
        self.assertEqual([hold["selection_id"] for hold in holds],
                         ["sel-0000005a", "sel-0000005b"],
                         "each posted row is kept when added; nothing is sent")
        self.assertEqual(holds[0]["search_id"], "find-1")
        self.assertEqual([item["trigger"] for item in bot["items"]], ["!Bot"])
        asyncio.run(self.queue.start())
        self.tick()
        self.assertEqual(self.engine.posted(), ["hold-" + f"{1:032x}"])
        self.engine.settle("sel-0000005a", "complete")
        self.tick(2)
        self.assertEqual(self.engine.posted(), ["hold-" + f"{1:032x}", "hold-" + f"{2:032x}"])
        self.engine.settle("sel-0000005b", "complete")
        self.tick(2)
        self.assertEqual(self.engine.dispatched(), [("Fixture", "/books/three.txt")],
                         "a file server's file is still fetched through its session")
        self.assertEqual(self.states()[:1], [("three.txt", "running")])
        self.assertEqual(len(direct["items"]), 2)

    def test_a_posted_row_whose_copy_is_gone_is_not_requested_and_the_queue_goes_on(self):
        self.add(90, "bot one.epub", sender="Bot", provider="searchbot")
        self.add(1, "/books/one.txt")
        self.engine.held_refusal = "stale_hold"
        asyncio.run(self.queue.start())
        view = self.tick(2)
        self.assertTrue(view["running"])
        self.assertEqual([(item["name"], item["state"], item["outcome"]) for item in view["items"]],
                         [("one.txt", "running", None),
                          ("bot one.epub", "not_requested", "stale_hold")])
        self.assertEqual(self.engine.dispatched(), [("Fixture", "/books/one.txt")])

    def test_a_queue_from_before_posted_rows_is_carried_over(self):
        self.add(1, "/books/one.txt")
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("ALTER TABLE download_queue RENAME TO new_queue")
            connection.execute("""CREATE TABLE download_queue (
                item_id TEXT PRIMARY KEY, position INTEGER NOT NULL,
                state TEXT NOT NULL CHECK (state IN
                    ('queued', 'running', 'done', 'not_requested', 'stopped')),
                source_id TEXT NOT NULL, source_revision INTEGER NOT NULL,
                result_id TEXT NOT NULL,
                origin TEXT NOT NULL CHECK (origin IN ('search', 'file_list')),
                sender TEXT NOT NULL, trigger_text TEXT NOT NULL,
                trigger_mode TEXT NOT NULL CHECK (trigger_mode IN ('channel_text', 'ctcp')),
                remote_path TEXT NOT NULL, size_bytes INTEGER,
                attempt INTEGER NOT NULL DEFAULT 0, operation_key TEXT, outcome TEXT,
                added_at REAL NOT NULL, updated_at REAL NOT NULL)""")
            connection.execute("INSERT INTO download_queue SELECT item_id, position, state, "
                               "source_id, source_revision, result_id, origin, sender, "
                               "trigger_text, trigger_mode, remote_path, size_bytes, attempt, "
                               "operation_key, outcome, added_at, updated_at FROM new_queue")
            connection.execute("DROP TABLE new_queue")
        self.queue = QueueService(self.downloads)
        self.assertEqual(self.states(), [("one.txt", "queued")])
        self.add(90, "bot one.epub", sender="Bot", provider="searchbot")
        self.assertEqual(self.states(), [("one.txt", "queued"), ("bot one.epub", "queued")])

    def test_a_queue_from_before_browsed_files_keeps_its_held_rows(self):
        self.add(90, "bot one.epub", sender="Bot", provider="searchbot")
        with closing(sqlite3.connect(self.database)) as connection, connection:
            (sql,) = connection.execute(
                "SELECT sql FROM sqlite_master WHERE name='download_queue'").fetchone()
            connection.execute("ALTER TABLE download_queue RENAME TO new_queue")
            connection.execute(sql.replace(", 'browse'", ""))
            connection.execute("INSERT INTO download_queue SELECT * FROM new_queue")
            connection.execute("DROP TABLE new_queue")
        self.queue = QueueService(self.downloads)
        asyncio.run(self.queue.start())
        self.tick()
        self.assertEqual(self.engine.posted(), ["hold-" + f"{1:032x}"],
                         "the held row kept its hold through the rebuild")

    def test_what_cannot_be_queued(self):
        self.engine.state = "ready"
        self.add(1, "/books/one.txt")
        with self.assertRaises(QueueError) as raised:
            asyncio.run(self.queue.add(self.searches.add(2, "/books/one.txt", sender="fixture")))
        self.assertEqual(raised.exception.code, "already_queued")
        for number in range(3, MAX_WAITING + 2):
            self.add(number, f"/books/{number}.txt")
        with self.assertRaises(QueueError) as raised:
            self.add(99, "/books/too-many.txt")
        self.assertEqual(raised.exception.code, "queue_full")
        with self.assertRaises(QueueError) as raised:
            asyncio.run(self.queue.add("not-a-result"))
        self.assertEqual(raised.exception.code, "invalid_result")

    def test_remove_and_clear(self):
        self.add(1, "/books/one.txt")
        self.add(2, "/books/two.txt")
        asyncio.run(self.queue.start())
        self.tick()
        running, waiting = self.queue.view()["items"]
        with self.assertRaises(QueueError):
            asyncio.run(self.queue.remove(running["item_id"]))
        asyncio.run(self.queue.remove(waiting["item_id"]))
        self.engine.settle("/books/one.txt", "complete")
        self.tick()
        self.assertEqual(self.states(), [("one.txt", "done")])
        asyncio.run(self.queue.clear_finished())
        self.assertEqual(self.states(), [])


try:
    from web_download_native_test import (DownloadFixture, NativeIrssi, open_engine,
                                          ready_services, wait_search)
except ImportError:   # the native helpers need a POSIX pty
    NativeIrssi = None


@unittest.skipIf(NativeIrssi is None, "needs the native Irssi helpers")
class QueueNativeTests(unittest.TestCase):
    def test_three_queued_files_are_fetched_in_turn_one_of_them_gone(self):
        fixture = DownloadFixture()
        fixture.extra_files["second.txt"] = b"the second file\n"
        fixture.extra_results = 1          # absent-01.txt is listed but not there
        fixture.start()
        try:
            with NativeIrssi() as native, tempfile.TemporaryDirectory() as name:
                # A search ends soon after the fixture's reply, as in the
                # other native tests, not after the engine's 30 quiet seconds.
                native.command("/set fscrawl_find_quiet_ms 250")

                async def workflow():
                    engine = await open_engine(native)
                    searches = None
                    queue = None
                    try:
                        sources, searches, downloads = await ready_services(
                            Path(name) / "fserve.sqlite3", engine, fixture)
                        queue = QueueService(downloads)
                        search = await searches.search("fixture")
                        search = await wait_search(searches, search["search_id"])
                        page = await searches.page(search["search_id"], offset=0, limit=10)
                        for result in page["results"]:
                            await queue.add(result["result_id"])
                        self.assertEqual(len(queue.view()["items"]), 3)
                        self.assertEqual(fixture.trigger_count, 0, "adding sends nothing")
                        await queue.start()
                        deadline = time.monotonic() + 120
                        while time.monotonic() < deadline:
                            await queue.tick()
                            view = queue.view()
                            if not view["running"]:
                                break
                            await asyncio.sleep(.5)
                        else:
                            self.fail(f"the queue did not finish: {queue.view()}")
                        states = {item["name"]: item["state"] for item in view["items"]}
                        self.assertEqual(states, {"fixture.txt": "done", "second.txt": "done",
                                                  "absent-01.txt": "not_requested"}, view)
                        self.assertIsNone(view["paused_reason"])
                        self.assertEqual((fixture.find_count, fixture.trigger_count,
                                          fixture.get_count), (1, 3, 2),
                                         "one trigger per file, and no GET for the absent one")
                        gets = [command for command in fixture.chat_commands
                                if command.lower().startswith("get ")]
                        self.assertEqual(gets, ["get fixture.txt", "get second.txt"])
                        await sources.disconnect()
                    finally:
                        if queue is not None:
                            await queue.close()
                        if searches is not None:
                            await searches.close()
                        await engine.close()

                asyncio.run(workflow())
            self.assertFalse(fixture.errors, fixture.errors)
        finally:
            fixture.stop()


if __name__ == "__main__":
    unittest.main()
