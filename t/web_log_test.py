"""The connection log (2026-10-20): the engine's lines kept for the page."""

from __future__ import annotations

import asyncio
import io
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from webapp.engine_client import EngineRequestError
from webapp.engine_log import LogBook, LogCopier

try:
    import uvicorn
    from webapp.__main__ import server_config
except ImportError:   # pragma: no cover - the product image has it
    uvicorn = None


def engine_line(seq, text, kind="received", source_ids=("lab",), at=100.0):
    return {"seq": seq, "time": at + seq, "kind": kind, "server_tag": "net",
            "source_ids": list(source_ids), "text": text}


class FakeEngine:
    """Answers log.list from a list of lines, a page at a time."""

    def __init__(self, lines=(), page=200):
        self.lines = list(lines)
        self.page = page
        self.first_seq = 1
        self.refusal = None
        self.requests = []
        self.engine_instance_id = "engine-1"
        self.closed = False

    async def request(self, operation, arguments=None, *, operation_id=None, timeout=10.0):
        self.requests.append((operation, dict(arguments or {})))
        if operation != "log.list":
            raise AssertionError(f"only log.list may be asked for, not {operation}")
        if self.refusal:
            raise EngineRequestError(self.refusal, "refused")
        after, limit = arguments["after"], min(arguments["limit"], self.page)
        # Malformed lines are passed on as they are: the copier must skip them.
        newer = [line for line in self.lines
                 if not (isinstance(line, dict) and isinstance(line.get("seq"), int))
                 or line["seq"] > after]
        seqs = [line["seq"] for line in self.lines
                if isinstance(line, dict) and isinstance(line.get("seq"), int)]
        return {"now": 200.0, "first_seq": self.first_seq,
                "last_seq": max(seqs, default=0),
                "more": len(newer) > limit, "lines": newer[:limit]}


def run(coroutine):
    return asyncio.run(coroutine)


class LogBookTests(unittest.TestCase):
    def test_lines_are_kept_in_order_and_printed(self):
        out = io.StringIO()
        book = LogBook(out=out)
        book.add("received", "Notice from Server1: hello", source_ids=["lab"],
                 labels={"lab": "Lab"}, at=0.0)
        book.add("error", "TLS failed\r\nsecond\x07 line")
        page = book.page()
        self.assertEqual([line["id"] for line in page["lines"]], [1, 2])
        self.assertEqual(page["lines"][0]["labels"], ["Lab"])
        self.assertEqual(page["lines"][1]["text"], "TLS failed second  line",
                         "control characters never reach the page or the output")
        printed = out.getvalue().splitlines()
        self.assertEqual(len(printed), 2)
        self.assertTrue(printed[0].startswith("[log] "))
        self.assertTrue(printed[0].endswith("received [Lab]: Notice from Server1: hello"))
        self.assertTrue(printed[1].endswith("error: TLS failed second  line"))

    def test_unknown_kinds_and_empty_text_are_dropped(self):
        book = LogBook(out=io.StringIO())
        book.add("shout", "x")
        book.add("received", "  \x01 ")
        self.assertEqual(book.page()["lines"], [])

    def test_paging_after_an_id_and_by_source(self):
        book = LogBook(out=io.StringIO())
        book.add("received", "one", source_ids=["a"])
        book.add("received", "two", source_ids=["b"])
        book.add("error", "for nobody")
        book.add("state", "three", source_ids=["a", "b"])
        self.assertEqual([line["text"] for line in book.page(after=1)["lines"]],
                         ["two", "for nobody", "three"])
        self.assertEqual([line["text"] for line in book.page(source_id="a")["lines"]],
                         ["one", "for nobody", "three"],
                         "one source's view keeps lines tied to no source")
        limited = book.page(limit=2)
        self.assertEqual(len(limited["lines"]), 2)
        self.assertTrue(limited["more"])
        self.assertEqual(limited["last_id"], 4)

    def test_only_the_newest_lines_are_kept(self):
        book = LogBook(keep=3, out=io.StringIO())
        for number in range(5):
            book.add("received", f"line {number}")
        page = book.page()
        self.assertEqual([line["text"] for line in page["lines"]], ["line 2", "line 3", "line 4"])
        self.assertEqual(page["first_id"], 3)

    def test_a_closed_output_does_not_stop_the_log(self):
        out = io.StringIO()
        out.close()
        book = LogBook(out=out)
        book.add("received", "kept anyway")
        self.assertEqual(len(book.page()["lines"]), 1)


class SavedLogTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "connection-log.jsonl"

    def tearDown(self):
        self.directory.cleanup()

    def test_lines_are_read_back_after_a_restart_and_ids_go_on(self):
        book = LogBook(out=io.StringIO(), path=self.path)
        book.add("received", "before", source_ids=["lab"], labels={"lab": "Lab"}, at=5.0)
        book.add("error", "also before")
        if os.name == "posix":
            self.assertEqual(self.path.stat().st_mode & 0o777, 0o600, "only the service reads it")
        again = LogBook(out=io.StringIO(), path=self.path)
        lines = again.page()["lines"]
        self.assertEqual([(line["id"], line["text"]) for line in lines],
                         [(1, "before"), (2, "also before"),
                          (3, "DCCAtlas started again; the lines above are from before")])
        self.assertEqual((lines[0]["labels"], lines[0]["time"]), (["Lab"], 5.0))
        again.add("web", "after")
        self.assertEqual(again.page(after=3)["lines"][0]["id"], 4,
                         "ids never repeat, so the page's place in the log holds")

    def test_an_engine_that_kept_running_is_not_copied_twice(self):
        engine = FakeEngine([engine_line(seq, f"line {seq}") for seq in range(1, 4)])
        book = LogBook(out=io.StringIO(), path=self.path)
        run(LogCopier(book, engine, dict).copy_once("engine-1"))
        again = LogBook(out=io.StringIO(), path=self.path)
        self.assertEqual(again.copied, {"engine-1": 3})
        engine.lines.append(engine_line(4, "line 4"))
        run(LogCopier(again, engine, dict).copy_once("engine-1"))
        self.assertEqual([line["text"] for line in again.page()["lines"] if line["kind"] != "web"],
                         ["line 1", "line 2", "line 3", "line 4"])

    def test_the_file_is_capped_at_two_parts_and_bad_lines_are_skipped(self):
        from webapp import engine_log
        book = LogBook(out=io.StringIO(), path=self.path)
        original = engine_log.FILE_PART_BYTES
        engine_log.FILE_PART_BYTES = 300
        try:
            for number in range(20):
                book.add("received", f"line {number:02} " + "x" * 40)
        finally:
            engine_log.FILE_PART_BYTES = original
        older = self.path.with_name(self.path.name + ".1")
        self.assertTrue(older.exists())
        self.assertEqual(sorted(item.name for item in self.path.parent.iterdir()),
                         ["connection-log.jsonl", "connection-log.jsonl.1"])
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write("not json\n{\"id\": \"x\"}\n")
        texts = [line["text"] for line in LogBook(out=io.StringIO(), path=self.path).page()["lines"]]
        self.assertEqual(texts[-2], "line 19 " + "x" * 40)
        self.assertLess(len(texts), 21, "the oldest part was dropped")

    def test_an_unwritable_file_does_not_stop_the_log(self):
        book = LogBook(out=io.StringIO(), path=Path(self.directory.name) / "missing" / "log.jsonl")
        book.add("received", "kept anyway")
        self.assertEqual(len(book.page()["lines"]), 1)


class LogCopierTests(unittest.TestCase):
    def copier(self, engine, book=None):
        book = book or LogBook(out=io.StringIO())
        return book, LogCopier(book, engine, lambda: {"lab": "Lab"})

    def test_copies_every_page_and_only_new_lines(self):
        engine = FakeEngine([engine_line(seq, f"line {seq}") for seq in range(1, 6)], page=2)
        book, copier = self.copier(engine)
        run(copier.copy_once("engine-1"))
        self.assertEqual([line["text"] for line in book.page()["lines"]],
                         [f"line {seq}" for seq in range(1, 6)])
        self.assertEqual(book.page()["lines"][0]["labels"], ["Lab"])
        self.assertEqual([args["after"] for _, args in engine.requests], [0, 2, 4])
        engine.lines.append(engine_line(6, "line 6"))
        run(copier.copy_once("engine-1"))
        self.assertEqual(book.page(after=5)["lines"][0]["text"], "line 6")
        self.assertEqual(len(book.page()["lines"]), 6, "nothing is copied twice")

    def test_times_follow_the_engine_clock(self):
        engine = FakeEngine([engine_line(1, "x", at=99.0)])
        book, copier = self.copier(engine)
        before = time.time()
        run(copier.copy_once("engine-1"))
        # The line is 100 seconds older than the engine's "now" of 200.
        self.assertAlmostEqual(book.page()["lines"][0]["time"], before - 100.0, delta=2.0)

    def test_lines_the_engine_dropped_before_copying_are_counted(self):
        engine = FakeEngine([engine_line(seq, f"line {seq}") for seq in range(1, 3)])
        book, copier = self.copier(engine)
        run(copier.copy_once("engine-1"))
        engine.lines = [engine_line(seq, f"line {seq}") for seq in range(10, 12)]
        engine.first_seq = 10
        run(copier.copy_once("engine-1"))
        texts = [line["text"] for line in book.page()["lines"]]
        self.assertIn("7 engine log lines were dropped before they could be copied", texts)
        self.assertEqual(texts[-2:], ["line 10", "line 11"])

    def test_bad_lines_are_skipped_and_odd_kinds_become_engine(self):
        engine = FakeEngine([engine_line(1, "odd", kind="mystery"), {"seq": "2"}, "x",
                             engine_line(3, "fine", source_ids=["lab", 5])])
        book, copier = self.copier(engine)
        run(copier.copy_once("engine-1"))
        lines = book.page()["lines"]
        self.assertEqual([(line["kind"], line["text"]) for line in lines],
                         [("engine", "odd"), ("received", "fine")])
        self.assertEqual(lines[1]["source_ids"], ["lab"])

    def test_an_engine_without_the_log_stops_the_copier_quietly(self):
        engine = FakeEngine()
        engine.refusal = "unsupported_operation"
        book, copier = self.copier(engine)
        run(asyncio.wait_for(copier.run(), 5))
        self.assertEqual(book.page()["lines"], [])

    def test_another_engine_instance_is_copied_from_its_start(self):
        engine = FakeEngine([engine_line(1, "first engine")])
        book, copier = self.copier(engine)
        run(copier.copy_once("engine-1"))
        engine.lines = [engine_line(1, "second engine")]
        run(copier.copy_once("engine-2"))
        self.assertEqual([line["text"] for line in book.page()["lines"]],
                         ["first engine", "second engine"])


@unittest.skipIf(uvicorn is None, "the web framework is not installed in this image")
class LogApiTests(unittest.TestCase):
    def test_the_log_needs_a_session_and_pages_by_source(self):
        from web_api_test import PASSWORD, Client
        from webapp.runtime import Runtime, Settings

        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        secret = root / "password"
        secret.write_text(PASSWORD + "\n", encoding="utf-8")
        runtime = Runtime(Settings(
            database=root / "config" / "fserve.sqlite3", socket_path=str(root / "absent.sock"),
            password_file=str(secret), cookie_secure=False,
            allowed_hosts=("127.0.0.1", "localhost"),
        ))

        async def no_engine():
            return None

        runtime.start = runtime.stop = no_engine
        runtime.log = LogBook(out=io.StringIO())
        runtime.log.add("received", "for a", source_ids=["src-a"])
        runtime.log.add("received", "for b", source_ids=["src-b"])
        server = uvicorn.Server(server_config(runtime, "127.0.0.1", 0))
        thread = threading.Thread(target=server.run, daemon=True)
        thread.start()

        def stop():
            server.should_exit = True
            thread.join(timeout=10)

        self.addCleanup(stop)
        deadline = time.monotonic() + 10
        while not server.started:
            if time.monotonic() > deadline:
                raise AssertionError("the test HTTP server did not start")
            time.sleep(.02)
        client = Client(server.servers[0].sockets[0].getsockname()[1])

        response, body = client.request("GET", "/api/log")
        self.assertEqual(response.status, 401)
        client.login()
        response, body = client.request("GET", "/api/log")
        self.assertEqual(response.status, 200, body)
        self.assertEqual([line["text"] for line in body["lines"]], ["for a", "for b"])
        response, body = client.request("GET", "/api/log?after=1")
        self.assertEqual([line["text"] for line in body["lines"]], ["for b"])
        response, body = client.request("GET", "/api/log?source=src-a")
        self.assertEqual([line["text"] for line in body["lines"]], ["for a"])
        for bad in ("after=-1", "after=x", "after=" + "9" * 16, "source=bad%20id"):
            response, body = client.request("GET", "/api/log?" + bad)
            self.assertEqual(response.status, 400, bad)


if __name__ == "__main__":
    unittest.main()
