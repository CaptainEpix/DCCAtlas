"""Native check: Prowlarr's requests search IRC and fetch a file end to end.

Real web service, real bridge, native Irssi and the generated loopback file
server; the requests are the ones Prowlarr's Generic Newznab indexer and
SABnzbd client build. Nothing leaves the container's loopback.
"""

from __future__ import annotations

import http.client
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlencode, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from web_api_test import PASSWORD, Client, uvicorn
from web_download_native_test import CONTENT, FILENAME, DownloadFixture, RestartableIrssi
from web_http_native_test import poll
from web_prowlarr_test import multipart
from web_source_test import source_values


@unittest.skipIf(uvicorn is None, "the web framework is not installed in this image")
class ProwlarrNativeTests(unittest.TestCase):
    def test_a_prowlarr_search_and_grab_fetch_the_file_once(self):
        fixture = DownloadFixture()
        self.serve(fixture, self.walk_through)

    def test_rows_still_arriving_at_the_first_answer_are_there_at_the_next(self):
        """As on a real network, 2026-10-28: Prowlarr was answered before the @find
        replies had all come, and the same search a few minutes later must
        then show them all, sending nothing again."""
        fixture = DownloadFixture()
        fixture.find_replies = [
            ("Shelf", "PRIVMSG", "I have found 2 file(s) for your query: fixture. Displaying 2:"),
            ("Shelf", "NOTICE", f"!Shelf Fixture companion.pdf ::INFO:: {len(CONTENT)}B"),
            ("Shelf", "NOTICE", "!Shelf Fixture maps.zip ::INFO:: 156.49 KiB"),
        ]
        self.serve(fixture, self.answered_early_then_again)

    def test_with_a_search_bot_searched_after_the_find_all_rows_are_there_at_the_next(self):
        """As on 2026-10-28 with three sources: the search bots are searched
        after the @find sources, so the search runs on after the first answer."""
        fixture = DownloadFixture()
        fixture.find_replies = [
            ("Shelf", "NOTICE", f"!Shelf Fixture companion.pdf ::INFO:: {len(CONTENT)}B")]
        bot = DownloadFixture()
        bot.search_rows = ["!BookBot Fixture bot book.epub  ::INFO:: 1KB"]
        bot.start()
        self.addCleanup(bot.stop)

        def walk(page, port, fixture, native):
            key = self.connect(page, port, fixture)
            response, added = page.request("POST", "/api/sources", source_values(
                bot.port, label="Bot net", provider="searchbot", search_bot="SearchBot",
                nickname="W2Bot"))
            self.assertEqual(response.status, 200, added)
            bot_id = added["source_id"]
            self.assertEqual(page.request("POST", f"/api/sources/{bot_id}/connect")[0].status,
                             200)
            poll("both ready", lambda: page.request("GET", "/api/status")[1],
                 lambda status: all(entry["source"] and entry["source"]["state"] == "ready"
                                    for entry in status["sources"]))

            def titles():
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=90)
                try:
                    connection.request("GET", "/newznab/api?" + urlencode(
                        {"t": "search", "q": "fixture", "cat": "7000", "apikey": key}))
                    feed = ET.fromstring(connection.getresponse().read())
                finally:
                    connection.close()
                return [item.findtext("title") for item in feed.findall("./channel/item")]

            with mock.patch("webapp.prowlarr.ANSWER_SECONDS", 0.0):
                first = titles()
            # Only files go to the apps (2026-10-29): still searching, the
            # first answer has what had arrived and no note.
            wanted = sorted([FILENAME, "Fixture companion.pdf", "Fixture bot book.epub"])
            self.assertLess(len(first), len(wanted), first)
            self.assertFalse([title for title in first if title.startswith("[DCCAtlas]")], first)
            deadline = time.monotonic() + 60
            again = []
            while time.monotonic() < deadline:
                again = titles()
                if sorted(again) == wanted:
                    break
                time.sleep(2)
            self.assertEqual(sorted(again), wanted, again)
            self.assertEqual((fixture.find_count, bot.search_count), (1, 1))

        self.serve(fixture, walk)

    def serve(self, fixture, walk):
        from webapp.__main__ import server_config
        from webapp.runtime import Runtime, Settings

        fixture.start()
        self.addCleanup(fixture.stop)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "password").write_text(PASSWORD + "\n", encoding="utf-8")

        with RestartableIrssi() as native:
            native.command("/set fscrawl_find_quiet_ms 250")
            native.command("/set dcc_autoget OFF")
            runtime = Runtime(Settings(
                database=root / "config" / "fserve.sqlite3", socket_path=str(native.path),
                password_file=str(root / "password"), cookie_secure=False,
                allowed_hosts=("127.0.0.1",)))
            server = uvicorn.Server(server_config(runtime, "127.0.0.1", 0))
            thread = threading.Thread(target=server.run, daemon=True)
            thread.start()
            try:
                poll("HTTP server start", lambda: server.started, bool, timeout=10)
                port = server.servers[0].sockets[0].getsockname()[1]
                walk(Client(port), port, fixture, native)
            except BaseException:
                print(f"fixture lines={fixture.lines[-12:]!r} errors={fixture.errors!r}",
                      flush=True)
                print(native.transcript[-4000:].decode(errors="replace"), flush=True)
                raise
            finally:
                server.should_exit = True
                thread.join(timeout=10)
        self.assertFalse(fixture.errors, fixture.errors)

    def connect(self, page, port, fixture):
        """Sign in, connect the fixture's source, and let Prowlarr in; its key."""
        def get(path):
            response, body = page.request("GET", path)
            self.assertEqual(response.status, 200, body)
            return body

        self.assertEqual(page.login()[0].status, 200)
        poll("engine connection", lambda: page.request("GET", "/api/status")[1],
             lambda status: status.get("engine_available"))
        values = source_values(fixture.port)
        values.pop("provider")
        self.assertEqual(page.request("PUT", "/api/source", values)[0].status, 200)
        self.assertEqual(page.request("POST", "/api/source/connect")[0].status, 200)
        poll("ready source", lambda: get("/api/status"),
             lambda status: status["source"]["state"] == "ready")
        return page.request("PUT", "/api/prowlarr", {"enabled": True})[1]["api_key"]

    def answered_early_then_again(self, page, port, fixture, native):
        def titles(params):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=90)
            try:
                connection.request("GET", f"/newznab/api?{urlencode(params)}")
                feed = ET.fromstring(connection.getresponse().read())
            finally:
                connection.close()
            return [item.findtext("title") for item in feed.findall("./channel/item")]

        key = self.connect(page, port, fixture)
        search = {"t": "search", "q": "fixture", "cat": "7000", "apikey": key}
        with mock.patch("webapp.prowlarr.ANSWER_SECONDS", 0.0):
            first = titles(search)
        # Still searching: what had arrived, and no note (2026-10-29).
        self.assertLess(len(first), 3, first)
        self.assertFalse([title for title in first if title.startswith("[DCCAtlas]")], first)
        # The search ends here meanwhile; asked again, Prowlarr gets every row.
        time.sleep(4)
        again = titles(search)
        self.assertEqual(sorted(again), sorted([FILENAME, "Fixture companion.pdf",
                                                "Fixture maps.zip"]), again)
        self.assertEqual(fixture.find_count, 1, "asked again, nothing is sent")

    def walk_through(self, page, port, fixture, native):
        def ask(path, params, body=None, content_type=None):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=90)
            try:
                headers = {"Content-Type": content_type} if content_type else {}
                connection.request("POST" if body is not None else "GET",
                                   f"{path}?{urlencode(params)}", body=body, headers=headers)
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                return response.read()
            finally:
                connection.close()

        def get(path):
            response, body = page.request("GET", path)
            self.assertEqual(response.status, 200, body)
            return body

        self.assertEqual(page.login()[0].status, 200)
        poll("engine connection", lambda: page.request("GET", "/api/status")[1],
             lambda status: status.get("engine_available"))
        values = source_values(fixture.port)
        values.pop("provider")
        self.assertEqual(page.request("PUT", "/api/source", values)[0].status, 200)
        self.assertEqual(page.request("POST", "/api/source/connect")[0].status, 200)
        poll("ready source", lambda: get("/api/status"),
             lambda status: status["source"]["state"] == "ready")
        key = page.request("PUT", "/api/prowlarr", {"enabled": True})[1]["api_key"]

        # Prowlarr's Test: no words, so nothing is sent to IRC.
        test = ET.fromstring(ask("/newznab/api", {"t": "search", "extended": "1",
                                                  "apikey": key}))
        self.assertIn("Ready", test.findtext("./channel/item/title"))
        self.assertEqual(fixture.find_count, 0)

        feed = ET.fromstring(ask("/newznab/api", {"t": "search", "q": "fixture", "cat": "7000",
                                                  "extended": "1", "apikey": key}))
        items = feed.findall("./channel/item")
        self.assertEqual([item.findtext("title") for item in items], [FILENAME], feed)
        self.assertEqual(fixture.find_count, 1)
        link = items[0].findtext("link")
        nzb = ask("/newznab/api", {name: values[0] for name, values
                                   in parse_qs(urlsplit(link).query).items()})

        content_type, body = multipart(nzb)
        added = json.loads(ask("/sabnzbd/api", {"mode": "addfile", "cat": "prowlarr",
                                                "apikey": key, "output": "json"},
                               body, content_type))
        self.assertTrue(added["status"], added)
        nzo_id = added["nzo_ids"][0]

        def history():
            return json.loads(ask("/sabnzbd/api", {"mode": "history", "apikey": key,
                                                   "output": "json"}))["history"]["slots"]

        done = poll("completed job", history,
                    lambda slots: slots and slots[0]["status"] in ("Completed", "Failed"),
                    timeout=60)
        self.assertEqual((done[0]["nzo_id"], done[0]["status"]), (nzo_id, "Completed"), done)
        downloads = get("/api/downloads")["downloads"]
        published = native.home / "fserve-poc" / "downloads" / downloads[0]["download_path"]
        self.assertEqual(published.read_bytes(), CONTENT)

        # The same search again is answered from the first, and the file sent
        # again is a new press: refused on this connection, nothing sent.
        again = ET.fromstring(ask("/newznab/api", {"t": "search", "q": "Fixture", "apikey": key}))
        self.assertEqual(len(again.findall("./channel/item")), 1)
        second = json.loads(ask("/sabnzbd/api", {"mode": "addurl", "name": link,
                                                 "apikey": key, "output": "json"}))
        self.assertTrue(second["status"], second)
        refused = poll("the second job ends", history,
                       lambda slots: len(slots) == 2 and slots[0]["status"] == "Failed")
        self.assertTrue(refused[0]["fail_message"], refused)
        retry = json.loads(ask("/sabnzbd/api", {"mode": "retry", "value": nzo_id,
                                                "apikey": key, "output": "json"}))
        self.assertFalse(retry["status"])
        self.assertEqual((fixture.find_count, fixture.trigger_count, fixture.get_count),
                         (1, 1, 1), "one search, one trigger, one request")


if __name__ == "__main__":
    unittest.main()
