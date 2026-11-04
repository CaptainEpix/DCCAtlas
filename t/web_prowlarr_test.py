"""Prowlarr on its own (2026-10-26): the Newznab indexer and SABnzbd client.

The real application is served on a loopback port and asked as Prowlarr asks
it (the requests its Newznab indexer and SABnzbd client build). Stand-ins
replace the combined search and the downloads, so these check what the
Prowlarr side decides: who may ask, what is searched and when nothing is,
what is answered, and that a release handed over starts once and is never
asked for again by itself. `web_prowlarr_native_test.py` runs it against the
engine and the fixture file server.
"""

from __future__ import annotations

import http.client
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlencode, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))

try:
    import uvicorn
    from webapp.__main__ import server_config
    from web_api_test import PASSWORD, Client
except ImportError:  # the engine-only test image has no web framework
    uvicorn = None

from webapp.downloads import DownloadError
from webapp.searches import SearchError

NEWZNAB = "{http://www.newznab.com/DTD/2010/feeds/attributes/}"
ROW = "row-" + "1" * 32
LIST_ROW = "mrow-" + "2" * 64


class FakeEngine:
    def __init__(self):
        self.states = {"primary": "ready"}

    @property
    def ready(self):
        return self.states["primary"] == "ready"

    @ready.setter
    def ready(self, value):
        self.states["primary"] = "ready" if value else "disconnected"

    async def status(self):
        return {"sources": [{"source_id": source_id, "state": state}
                            for source_id, state in self.states.items()]}


class FakeSources:
    """Sources with categories; connecting one makes it ready, unless refused."""

    def __init__(self):
        self.engine = FakeEngine()
        self.configs = {"primary": self.config("primary", "Lab", 7000)}
        self.store = SimpleNamespace(list=lambda: list(self.configs.values()),
                                     get=self.configs.get)
        self.connected: list[str] = []
        self.disconnected: list[str] = []
        self.refuse_connect = False

    def add(self, source_id, label, category, state="disconnected"):
        self.configs[source_id] = self.config(source_id, label, category)
        self.engine.states[source_id] = state

    @staticmethod
    def config(source_id, label, category):
        return SimpleNamespace(source_id=source_id, label=label, channel="#books",
                               category=category, engine_arguments=lambda: {})

    async def connect(self, source_id):
        if self.refuse_connect:
            raise RuntimeError("refused by the fixture")
        self.connected.append(source_id)
        self.engine.states[source_id] = "ready"
        return {}

    async def disconnect(self, source_id):
        self.disconnected.append(source_id)
        self.engine.states[source_id] = "disconnected"
        return {}


class FakeManifests:
    async def lists(self):
        return {"lists": [{"route_key": "a" * 64, "source_label": "Lab", "source_id": "primary"},
                          {"route_key": "b" * 64, "source_label": None, "source_id": "gone"}]}


class FakeMulti:
    """Combined searches that finish when told to, with fixed rows."""

    def __init__(self):
        self.groups: dict[str, dict] = {}
        self.order: list[str] = []
        self.started: list[tuple] = []
        self.finish_at_once = True
        self.rows = [
            {"result_id": ROW, "selection_available": True, "path": "/Books/Some Author - A Book.epub",
             "sender": "Fixture", "trigger": "!Fixture", "source_label": "Lab",
             "source_id": "primary", "size_bytes_exact": None, "size_bytes_estimate": 1200},
            {"result_id": LIST_ROW, "selection_available": True, "path": "/Comics/Strip 01.cbz",
             "sender": "Fixture", "trigger": "!Fixture", "source_label": "Lab",
             "source_id": "primary", "size_bytes_exact": 5000, "size_bytes_estimate": None},
            {"result_id": None, "selection_available": False, "path": "/old.txt",
             "sender": "Fixture", "trigger": "!Fixture", "source_label": "Lab"},
        ]
        self.store = SimpleNamespace(
            recent=lambda limit: list(reversed(self.order))[:limit],
            running=lambda: [group for group in self.order
                             if self.groups[group]["state"] == "running"])

    def summary(self, group_id):
        group = self.groups[group_id]
        return {"group_id": group_id, "terms": group["terms"], "state": group["state"],
                "started_at": group["started_at"], "result_count": len(self.rows),
                "members": [*({"kind": "source", "position": 0, "label": "Lab",
                               "source_id": source_id,
                               "state": "collecting" if group["state"] == "running"
                               else "complete", "note": None}
                              for source_id in group["sources"]),
                            *({"kind": "list", "position": 1, "label": "Fixture !Fixture",
                               "route_key": key, "state": "complete", "note": None}
                              for key in group["lists"])]}

    async def status(self, group_id):
        return self.summary(group_id)

    async def start(self, terms, source_ids, list_keys):
        if self.store.running():
            raise SearchError("search_active", "wait for the current search to finish")
        self.started.append((terms, source_ids, list_keys))
        group_id = f"multi-{len(self.order):032x}"
        self.groups[group_id] = {"terms": terms, "started_at": time.time(),
                                 "sources": list(source_ids), "lists": list(list_keys),
                                 "state": "complete" if self.finish_at_once else "running"}
        self.order.append(group_id)
        return self.summary(group_id)

    async def page(self, group_id, *, offset, limit):
        return {"results": self.rows[offset:offset + limit]}


class FakeDownloads:
    def __init__(self):
        self.calls: list[tuple[str, str]] = []
        self.rows: dict[str, dict] = {}
        self.cancelled: list[str] = []
        self.refuse: DownloadError | None = None
        self.store = SimpleNamespace(get=self.rows.get, active=lambda: [
            row for row in self.rows.values()
            if row["state"] not in ("complete", "failed", "cancelled")])

    async def download(self, key, result_id):
        if self.refuse is not None:
            raise self.refuse
        self.calls.append((key, result_id))
        operation_id = f"web-download-{len(self.calls):064x}"
        self.rows[operation_id] = {
            "operation_id": operation_id, "source_id": "primary", "state": "preparing",
            "outcome": None,
            "reason": None, "download_path": None, "bytes_received": None,
            "total_bytes": None, "created_at": time.time(), "updated_at": time.time()}
        return self.rows[operation_id]

    async def status(self, operation_id):
        return self.rows[operation_id]

    async def cancel(self, operation_id):
        self.cancelled.append(operation_id)
        self.rows[operation_id]["state"] = "cancelled"
        return self.rows[operation_id]


def multipart(nzb: bytes) -> tuple[str, bytes]:
    boundary = "----prowlarr-test-boundary"
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"name\"; "
            f"filename=\"A Book.nzb\"\r\nContent-Type: application/x-nzb\r\n\r\n"
            ).encode() + nzb + f"\r\n--{boundary}--\r\n".encode()
    return f"multipart/form-data; boundary={boundary}", body


@unittest.skipIf(uvicorn is None, "the web framework is not installed in this image")
class ProwlarrTests(unittest.TestCase):
    def setUp(self):
        from webapp.runtime import Runtime, Services, Settings

        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        secret = root / "password"
        secret.write_text(PASSWORD + "\n", encoding="utf-8")
        runtime = Runtime(Settings(
            database=root / "config" / "fserve.sqlite3", socket_path=str(root / "absent.sock"),
            password_file=str(secret), cookie_secure=False,
            allowed_hosts=("127.0.0.1", "localhost")))

        async def no_engine():
            return None

        runtime.start = runtime.stop = no_engine
        self.sources, self.multi = FakeSources(), FakeMulti()
        self.downloads = FakeDownloads()
        runtime.services = Services(self.sources, SimpleNamespace(), self.downloads,
                                    self.multi, FakeManifests())
        self.runtime = runtime
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
        self.port = server.servers[0].sockets[0].getsockname()[1]
        self.page = Client(self.port)

    # -- helpers ----------------------------------------------------------------

    def logged(self) -> str:
        return "\n".join(line["text"] for line in self.runtime.log.page(0, None)["lines"])

    def get(self, path: str, params: dict, *, body: bytes | None = None,
            content_type: str | None = None) -> tuple[int, bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        try:
            headers = {"Host": f"127.0.0.1:{self.port}"}
            if content_type:
                headers["Content-Type"] = content_type
            connection.request("POST" if body is not None else "GET",
                               f"{path}?{urlencode(params)}", body=body, headers=headers)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def newznab(self, **params) -> ET.Element:
        status, body = self.get("/newznab/api", params)
        self.assertEqual(status, 200, body)
        return ET.fromstring(body)

    def sab(self, **params) -> dict:
        status, body = self.get("/sabnzbd/api", {**params, "output": "json"})
        self.assertEqual(status, 200, body)
        return json.loads(body)

    def turn_on(self) -> str:
        self.page.login()
        response, view = self.page.request("PUT", "/api/prowlarr", {"enabled": True})
        self.assertEqual(response.status, 200, view)
        self.assertTrue(view["enabled"])
        return view["api_key"]

    @staticmethod
    def items(feed: ET.Element) -> list[ET.Element]:
        return feed.findall("./channel/item")

    # -- tests ------------------------------------------------------------------

    def test_off_until_turned_on_and_only_with_the_key(self):
        error = self.newznab(t="caps", apikey="anything")
        self.assertEqual(error.tag, "error")
        self.assertEqual(error.get("code"), "100")
        self.assertIn("turned off", error.get("description"))
        self.assertEqual(self.sab(mode="version"), {"version": "4.0.0"})
        self.assertIn("API Key Incorrect", self.sab(mode="get_config", apikey="x")["error"])
        self.assertEqual(self.sab(mode="get_config")["error"], "API Key Required")

        response, view = self.page.request("GET", "/api/prowlarr")
        self.assertEqual(response.status, 401, "the page's settings need a session")
        key = self.turn_on()
        self.assertRegex(key, r"\A[0-9a-f]{32}\Z")
        self.assertEqual(self.newznab(t="caps", apikey="wrong").get("code"), "100")
        self.assertEqual(self.sab(mode="get_config", apikey="wrong")["error"], "API Key Incorrect")

        caps = self.newznab(t="caps", apikey=key)
        self.assertEqual(caps.tag, "caps")
        self.assertEqual(caps.find("./searching/search").get("available"), "yes")
        self.assertEqual(caps.find("./searching/book-search").get("supportedParams"),
                         "q,author,title")
        self.assertEqual(caps.find("./searching/tv-search").get("supportedParams"),
                         "q,season,ep")
        self.assertEqual([(element.get("id"), element.get("name"))
                          for element in caps.findall("./categories/category")],
                         [("1000", "Console"), ("2000", "Movies"), ("3000", "Audio"),
                          ("4000", "PC"), ("5000", "TV"), ("7000", "Books"), ("8000", "Other")])
        self.assertEqual([(element.get("id"), element.get("name"))
                          for element in caps.iter("subcat")],
                         [("3030", "Audio/Audiobook"), ("7020", "Books/EBook"),
                          ("7030", "Books/Comics")])
        config = self.sab(mode="get_config", apikey=key)["config"]
        self.assertFalse(config["misc"]["pre_check"])
        self.assertEqual(config["misc"]["complete_dir"], "/downloads")
        self.assertIn("prowlarr", [category["name"] for category in config["categories"]])
        self.assertEqual(self.sab(mode="fullstatus", apikey=key),
                         {"status": {"completedir": "/downloads"}})

        response, view = self.page.request("PUT", "/api/prowlarr", {"enabled": False})
        self.assertFalse(view["enabled"])
        self.assertEqual(view["api_key"], key, "turning it off keeps the key")
        self.assertIn("turned off", self.newznab(t="caps", apikey=key).get("description"))

    def test_a_search_asks_every_connected_place_once_and_answers_from_it_again(self):
        key = self.turn_on()
        feed = self.newznab(t="search", q="Some  Author", apikey=key, extended="1",
                            offset="0", limit="100", cat="7000")
        self.assertEqual(self.multi.started, [("Some  Author", ["primary"], ["a" * 64])],
                         "the Books source, and each file list whose source is kept")
        items = self.items(feed)
        self.assertEqual([item.findtext("title") for item in items],
                         ["Some Author - A Book.epub", "Strip 01.cbz"],
                         "a row that cannot be downloaded is left out")
        first = items[0]
        attributes = {element.get("name"): element.get("value")
                      for element in first.findall(NEWZNAB + "attr")}
        self.assertEqual(attributes, {"category": "7020", "size": "1200"})
        self.assertEqual(first.find("enclosure").get("type"), "application/x-nzb")
        self.assertEqual(first.findtext("guid"), "dccatlas-" + ROW)
        self.assertIn("from Fixture (!Fixture) on Lab", first.findtext("description"))
        link = urlsplit(first.findtext("link"))
        self.assertEqual(link.path, "/newznab/api")
        self.assertNotIn(key, link.query, "the key is not put into links")
        self.assertEqual(feed.find(f"./channel/{NEWZNAB}response").get("total"), "2")

        again = self.newznab(t="search", q="some author", apikey=key)
        self.assertEqual(len(self.multi.started), 1,
                         "the same words are not searched again where they were")
        self.assertEqual(len(self.items(again)), 2)
        book = self.newznab(t="book", author="Some", title="Author", apikey=key)
        self.assertEqual(len(self.multi.started), 1, "nor are they as a book search")
        self.assertEqual(len(self.items(book)), 2)

        comics = self.newznab(t="search", q="some author", cat="7030", apikey=key)
        self.assertEqual([item.findtext("title") for item in self.items(comics)], ["Strip 01.cbz"])
        paged = self.newznab(t="search", q="some author", apikey=key, offset="1", limit="1")
        self.assertEqual([item.findtext("title") for item in self.items(paged)], ["Strip 01.cbz"])

    def test_nothing_is_searched_for_other_categories_or_no_words(self):
        key = self.turn_on()
        for params in ({"t": "search", "q": "a film", "cat": "2000,5000"},
                       {"t": "movie", "q": "a film", "cat": "2000"},
                       {"t": "tvsearch", "q": "a show", "season": "1", "ep": "2", "cat": "5000"},
                       {"t": "music", "q": "a song", "cat": "3000"}):
            self.assertEqual(self.items(self.newznab(apikey=key, **params)), [], params)
            self.assertIn("No source of the categories asked for", self.logged())
        self.assertEqual(self.multi.started, [], "no Movies, TV or Audio source: nothing sent")
        self.assertEqual(self.sources.connected, [])

        # Asked for no category, only stored lists are searched: nothing reaches IRC.
        self.newznab(t="search", q="a film", apikey=key)
        self.assertEqual(self.multi.started, [("a film", [], ["a" * 64])])
        self.multi.started.clear()
        self.multi.order.clear()

        # Prowlarr's Test: no words. Nothing searched yet, so a note says so.
        test = self.items(self.newznab(t="search", apikey=key, extended="1"))
        self.assertEqual(len(test), 1)
        self.assertIn("Ready", test[0].findtext("title"))
        self.assertEqual(self.multi.started, [], "no words send nothing")
        self.newznab(t="search", q="some author", apikey=key)
        recent = self.items(self.newznab(t="search", apikey=key))
        self.assertEqual(len(recent), 2, "later it shows what was found")
        self.assertEqual(len(self.multi.started), 1)
        # Readarr's Test asks in its own categories; with rows in none of
        # them, the note answers it still (2026-10-29).
        other = self.items(self.newznab(t="search", apikey=key, cat="5000"))
        self.assertEqual([item.findtext("title")[:16] for item in other], ["[DCCAtlas] Ready"])

    def test_a_search_still_running_is_answered_early_and_said_so(self):
        key = self.turn_on()
        self.multi.finish_at_once = False
        with mock.patch("webapp.prowlarr.ANSWER_SECONDS", 0.5):
            started = time.monotonic()
            feed = self.newznab(t="search", q="slow words", apikey=key, cat="7000")
            self.assertLess(time.monotonic() - started, 5)
        titles = [item.findtext("title") for item in self.items(feed)]
        # Only files go to the apps (2026-10-29); what a note said is in the
        # Log.
        self.assertFalse([title for title in titles if title.startswith("[DCCAtlas]")])
        self.assertIn("Still searching: 1 of 2 places have answered", self.logged())
        self.assertIn("nothing is sent again", self.logged())

        # Busy, and nothing to search: answers with no rows, never errors,
        # which Prowlarr would count against DCCAtlas.
        other = self.newznab(t="search", q="other words", apikey=key, cat="7000")
        self.assertEqual(other.tag, "rss")
        self.assertEqual(self.items(other), [])
        self.assertIn("Busy with another search for “slow words”; nothing was sent",
                      self.logged())
        self.assertEqual(len(self.multi.started), 1)

        self.sources.engine.ready = False
        self.sources.refuse_connect = True
        self.multi.groups[self.multi.order[0]]["state"] = "complete"
        with mock.patch.object(FakeManifests, "lists",
                               new=mock.AsyncMock(return_value={"lists": []})):
            none = self.newznab(t="search", q="fourth words", apikey=key, cat="7000")
        self.assertEqual(none.tag, "rss")
        self.assertEqual(self.items(none), [])
        self.assertIn("No source of the categories asked for is connected", self.logged())

    def test_a_release_is_started_once_and_never_asked_for_again_by_itself(self):
        key = self.turn_on()
        item = self.items(self.newznab(t="search", q="some author", apikey=key))[0]
        link = item.findtext("link")
        status, nzb = self.get("/newznab/api", dict(
            (name, values[0]) for name, values in parse_qs(urlsplit(link).query).items()))
        self.assertEqual(status, 200)
        self.assertIn(b"<file ", nzb)
        self.assertIn(ROW.encode(), nzb)

        tampered = parse_qs(urlsplit(link).query)
        tampered["id"] = ["row-" + "9" * 32]
        status, body = self.get("/newznab/api", {name: values[0] for name, values in tampered.items()})
        self.assertEqual(ET.fromstring(body).get("code"), "300")

        content_type, body = multipart(nzb)
        status, raw = self.get("/sabnzbd/api", {"mode": "addfile", "cat": "prowlarr",
                                                "priority": "-100", "apikey": key,
                                                "output": "json"},
                               body=body, content_type=content_type)
        added = json.loads(raw)
        self.assertTrue(added["status"], added)
        nzo_id = added["nzo_ids"][0]
        self.assertRegex(nzo_id, r"\ASABnzbd_nzo_[0-9a-f]{16}\Z")
        self.assertEqual([result for _key, result in self.downloads.calls], [ROW])

        # Sent again while it is on its way: the same job, nothing new.
        status, raw = self.get("/sabnzbd/api", {"mode": "addfile", "apikey": key},
                               body=body, content_type=content_type)
        self.assertEqual(json.loads(raw)["nzo_ids"], [nzo_id])
        again = self.sab(mode="addurl", name=link, apikey=key)
        self.assertEqual(again["nzo_ids"], [nzo_id])
        self.assertEqual(len(self.downloads.calls), 1)

        queue = self.sab(mode="queue", start="0", limit="60", apikey=key)["queue"]
        self.assertEqual([(slot["nzo_id"], slot["filename"], slot["cat"], slot["status"])
                          for slot in queue["slots"]],
                         [(nzo_id, "Some Author - A Book.epub", "prowlarr", "Queued")])
        operation_id = next(iter(self.downloads.rows))
        self.downloads.rows[operation_id].update(
            state="receiving", bytes_received=600, total_bytes=1200)
        slot = self.sab(mode="queue", apikey=key)["queue"]["slots"][0]
        self.assertEqual((slot["status"], slot["percentage"]), ("Downloading", "50"))

        self.downloads.rows[operation_id].update(
            state="complete", download_path="127.0.0.1/Fixture/A Book.epub")
        self.assertEqual(self.sab(mode="queue", apikey=key)["queue"]["slots"], [])
        done = self.sab(mode="history", apikey=key)["history"]["slots"]
        self.assertEqual([(slot["status"], slot["storage"]) for slot in done],
                         [("Completed", "/downloads/127.0.0.1/Fixture/A Book.epub")])

        refused = self.sab(mode="retry", value=nzo_id, apikey=key)
        self.assertFalse(refused["status"])
        self.assertIn("never asks for a file again by itself", refused["error"])
        self.assertEqual(len(self.downloads.calls), 1)

        # After it ended, sending it again is a new press, as Download is.
        self.sab(mode="addurl", name=link, apikey=key)
        self.assertEqual(len(self.downloads.calls), 2)
        self.assertTrue(self.sab(mode="history", name="delete", value=nzo_id, apikey=key)["status"])
        self.assertEqual([slot["nzo_id"] for slot in
                          self.sab(mode="history", apikey=key)["history"]["slots"]], [])

    def test_a_refusal_a_foreign_link_a_note_and_a_new_key_are_said_plainly(self):
        key = self.turn_on()
        link = self.items(self.newznab(t="search", q="some author", apikey=key))[0].findtext("link")
        self.downloads.refuse = DownloadError("download_busy", "two downloads are running")
        refused = self.sab(mode="addurl", name=link, apikey=key)
        self.assertEqual(refused, {"status": False,
                                   "error": "DCCAtlas did not start it: two downloads are running"})
        self.downloads.refuse = None
        foreign = self.sab(mode="addurl", name="http://203.0.113.9/getnzb?id=1", apikey=key)
        self.assertIn("only its own links", foreign["error"])
        self.assertEqual(self.downloads.calls, [])

        status, body = self.get("/newznab/api", {"t": "get", "id": "note-" + "0" * 16})
        self.assertIn("a note from DCCAtlas", ET.fromstring(body).get("description"))

        self.page.request("POST", "/api/prowlarr/key", {})
        stale = self.sab(mode="addurl", name=link, apikey=self.page.request(
            "GET", "/api/prowlarr")[1]["api_key"])
        self.assertIn("key has changed", stale["error"])
        self.assertEqual(self.downloads.calls, [])

    def test_a_search_reaches_only_sources_of_the_categories_asked_for(self):
        key = self.turn_on()
        self.sources.add("films", "Films", 2000, state="ready")
        self.sources.add("comics", "Comics", 7030, state="ready")
        self.newznab(t="search", q="first words", apikey=key, cat="7000")
        self.assertEqual(self.multi.started[-1][1], ["primary", "comics"],
                         "Books reaches Books and its subcategories, not Movies")
        self.newznab(t="search", q="second words", apikey=key, cat="7020")
        self.assertEqual(self.multi.started[-1][1], ["primary"],
                         "EBook reaches EBook and Books sources, not Comics")
        self.newznab(t="movie", q="third words", apikey=key, cat="2000")
        self.assertEqual(self.multi.started[-1][1:], (["films"], []),
                         "Movies reaches the Movies source; the Books list is not searched")
        self.newznab(t="tvsearch", q="A Show", season="2", ep="5", apikey=key, cat="5000,2000")
        self.assertEqual(self.multi.started[-1][:2], ("A Show S02E05", ["films"]),
                         "a TV episode is searched by its name and number")

        # A Comics search after a Books one for the same words was covered by
        # it: answered from it, with nothing sent.
        count = len(self.multi.started)
        comics = self.newznab(t="search", q="first words", apikey=key, cat="7030")
        self.assertEqual(len(self.multi.started), count)
        self.assertEqual([item.findtext("title") for item in self.items(comics)],
                         ["Strip 01.cbz"])

    def test_a_source_of_the_category_is_connected_for_a_search_and_later_disconnected(self):
        key = self.turn_on()
        self.sources.add("films", "Films", 2000)          # disconnected
        now = [1000.0]
        with mock.patch("webapp.prowlarr._clock", lambda: now[0]), \
                mock.patch("webapp.prowlarr.IDLE_CHECK_SECONDS", 0.05):
            self.newznab(t="movie", q="a film", apikey=key, cat="2000")
            self.assertEqual(self.sources.connected, ["films"])
            self.assertEqual(self.multi.started[-1][1], ["films"])
            # Unused for less than the idle time: kept.
            now[0] += 29 * 60
            time.sleep(.3)
            self.assertEqual(self.sources.disconnected, [])
            # A search using it again restarts the wait.
            self.newznab(t="movie", q="another film", apikey=key, cat="2000")
            self.assertEqual(self.sources.connected, ["films"], "already connected")
            now[0] += 29 * 60
            time.sleep(.3)
            self.assertEqual(self.sources.disconnected, [])
            now[0] += 2 * 60
            deadline = time.monotonic() + 5
            while not self.sources.disconnected and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertEqual(self.sources.disconnected, ["films"])

            # One the owner connects is theirs: never disconnected for idling.
            self.page.request("POST", "/api/sources/primary/disconnect")
            self.sources.engine.states["primary"] = "disconnected"
            self.newznab(t="search", q="a book", apikey=key, cat="7000")
            self.assertEqual(self.sources.connected[-1], "primary")
            self.page.request("POST", "/api/sources/primary/connect")
            before = len(self.sources.disconnected)
            now[0] += 60 * 60
            time.sleep(.3)
            self.assertEqual(len(self.sources.disconnected), before)

    def test_a_source_still_downloading_is_not_disconnected(self):
        key = self.turn_on()
        self.sources.engine.ready = False
        now = [1000.0]
        with mock.patch("webapp.prowlarr._clock", lambda: now[0]), \
                mock.patch("webapp.prowlarr.IDLE_CHECK_SECONDS", 0.05):
            item = self.items(self.newznab(t="search", q="a book", apikey=key, cat="7000"))[0]
            self.assertEqual(self.sources.connected, ["primary"])
            self.sab(mode="addurl", name=item.findtext("link"), apikey=key)
            now[0] += 2 * 60 * 60
            time.sleep(.3)
            self.assertEqual(self.sources.disconnected, [], "its download is still running")
            operation_id = next(iter(self.downloads.rows))
            self.downloads.rows[operation_id]["state"] = "complete"
            deadline = time.monotonic() + 5
            while not self.sources.disconnected and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertEqual(self.sources.disconnected, ["primary"])

    def test_a_refused_connection_is_not_tried_again_for_ten_minutes(self):
        key = self.turn_on()
        self.sources.engine.ready = False
        self.sources.refuse_connect = True
        now = [1000.0]
        attempts = []
        original = self.sources.connect

        async def counting(source_id):
            attempts.append(source_id)
            return await original(source_id)

        self.sources.connect = counting
        with mock.patch("webapp.prowlarr._clock", lambda: now[0]):
            self.newznab(t="search", q="one", apikey=key, cat="7000")
            self.newznab(t="search", q="two", apikey=key, cat="7000")
            self.assertEqual(attempts, ["primary"])
            now[0] += 11 * 60
            self.newznab(t="search", q="three", apikey=key, cat="7000")
            self.assertEqual(attempts, ["primary", "primary"])

    def test_past_the_hourly_limit_prowlarr_is_told_and_nothing_is_sent(self):
        key = self.turn_on()
        response, view = self.page.request("PUT", "/api/prowlarr", {"searches_per_hour": 2})
        self.assertEqual((response.status, view["searches_per_hour"]), (200, 2))
        response, body = self.page.request("PUT", "/api/prowlarr", {"searches_per_hour": 0})
        self.assertEqual(response.status, 400)
        now = [1000.0]
        with mock.patch("webapp.prowlarr._clock", lambda: now[0]):
            self.newznab(t="search", q="one", apikey=key, cat="7000")
            self.newznab(t="search", q="two", apikey=key, cat="7000")
            refused = self.newznab(t="search", q="three", apikey=key, cat="7000")
            # The exact words Prowlarr reads as a rate limit (NewznabRssParser.cs).
            self.assertEqual((refused.tag, refused.get("description")),
                             ("error", "Request limit reached"))
            self.assertEqual(len(self.multi.started), 2)
            # Answered from an earlier search, or from stored lists only: not counted.
            self.assertEqual(self.newznab(t="search", q="one", apikey=key, cat="7000").tag, "rss")
            self.assertEqual(self.newznab(t="search", q="lists", apikey=key).tag, "rss")
            now[0] += 3601
            self.assertEqual(self.newznab(t="search", q="four", apikey=key, cat="7000").tag,
                             "rss")
        self.assertEqual([terms for terms, *_ in self.multi.started],
                         ["one", "two", "lists", "four"])

    def test_with_lists_only_a_search_asks_the_stored_lists_and_sends_nothing(self):
        # 2026-10-29: an answer at once, with nothing sent to IRC.
        key = self.turn_on()
        response, view = self.page.request("PUT", "/api/prowlarr", {"lists_only": True})
        self.assertEqual((response.status, view["lists_only"]), (200, True))
        response, body = self.page.request("PUT", "/api/prowlarr", {"lists_only": "yes"})
        self.assertEqual(response.status, 400)
        now = [1000.0]
        with mock.patch("webapp.prowlarr._clock", lambda: now[0]):
            for number in range(15):
                self.assertEqual(self.newznab(t="search", q=f"words {number}", apikey=key,
                                              cat="7000").tag, "rss")
        self.assertEqual({(tuple(sources), tuple(lists)) for _, sources, lists in self.multi.started},
                         {((), ("a" * 64,))}, "the stored list alone, never the source")
        self.assertEqual(len(self.multi.started), 15, "and no hourly limit is reached")
        self.page.request("PUT", "/api/prowlarr", {"lists_only": False})
        self.newznab(t="search", q="words again", apikey=key, cat="7000")
        self.assertEqual(self.multi.started[-1][1], ["primary"], "off again, sources are asked")

    def test_with_category_folders_a_finished_file_moves_into_its_category(self):
        key = self.turn_on()
        with tempfile.TemporaryDirectory() as downloads:
            with mock.patch("webapp.prowlarr.DOWNLOAD_DIR", downloads):
                item = self.items(self.newznab(t="search", q="a book", apikey=key,
                                               cat="7000"))[0]
                link = item.findtext("link")
                nzo = self.sab(mode="addurl", name=link, cat="books", apikey=key)["nzo_ids"][0]
                operation_id = next(iter(self.downloads.rows))
                found = Path(downloads) / "Net" / "Fixture" / "A Book.epub"
                found.parent.mkdir(parents=True)
                found.write_bytes(b"book")
                self.downloads.rows[operation_id].update(
                    state="complete", download_path="Net/Fixture/A Book.epub")
                # Off: the file stays where it was fetched to.
                storage = self.sab(mode="history", apikey=key)["history"]["slots"][0]["storage"]
                self.assertEqual(storage, str(Path(downloads, "Net/Fixture/A Book.epub"))
                                 .replace("\\", "/"))
                self.page.request("PUT", "/api/prowlarr", {"category_folders": True})
                (Path(downloads) / "books").mkdir()
                (Path(downloads) / "books" / "A Book.epub").write_bytes(b"other")
                slots = self.sab(mode="history", apikey=key)["history"]["slots"]
                self.assertTrue(slots[0]["storage"].endswith("/books/A Book-1.epub"),
                                "a file already there is never replaced")
                self.assertFalse(found.exists())
                self.assertEqual((Path(downloads) / "books" / "A Book-1.epub").read_bytes(),
                                 b"book")
                again = self.sab(mode="history", apikey=key)["history"]["slots"]
                self.assertEqual(again[0]["storage"], slots[0]["storage"], "moved once")
                self.assertEqual(again[0]["nzo_id"], nzo)

    def test_on_a_share_that_refuses_hard_links_the_file_is_copied_instead(self):
        key = self.turn_on()
        self.page.request("PUT", "/api/prowlarr", {"category_folders": True})
        with tempfile.TemporaryDirectory() as downloads, \
                mock.patch("webapp.prowlarr.DOWNLOAD_DIR", downloads), \
                mock.patch("webapp.prowlarr.os.link", side_effect=PermissionError(1, "refused")):
            item = self.items(self.newznab(t="search", q="a book", apikey=key, cat="7000"))[0]
            self.sab(mode="addurl", name=item.findtext("link"), cat="books", apikey=key)
            found = Path(downloads) / "Net" / "A Book.epub"
            found.parent.mkdir(parents=True)
            found.write_bytes(b"book")
            operation_id = next(iter(self.downloads.rows))
            self.downloads.rows[operation_id].update(state="complete",
                                                     download_path="Net/A Book.epub")
            slots = self.sab(mode="history", apikey=key)["history"]["slots"]
            self.assertTrue(slots[0]["storage"].endswith("/books/A Book.epub"), slots)
            self.assertEqual((Path(downloads) / "books" / "A Book.epub").read_bytes(), b"book")
            self.assertFalse(found.exists())

    def test_what_a_place_says_is_logged_and_never_sent_as_a_row(self):
        key = self.turn_on()
        summary = self.multi.summary

        def with_notes(group_id):
            view = summary(group_id)
            view["members"] = [
                {**view["members"][0], "note": "The search bot said: returned 11 matches",
                 "result_count": 11},
                {**view["members"][0], "position": 2, "label": "Empty",
                 "note": "The search bot sent no result list in time", "result_count": 0}]
            return view

        with mock.patch.object(self.multi, "summary", with_notes):
            titles = [item.findtext("title") for item in self.items(
                self.newznab(t="search", q="noted words", apikey=key, cat="7000"))]
        self.assertEqual([title for title in titles if title.startswith("[DCCAtlas]")], [])
        self.assertIn("Prowlarr: Empty: The search bot sent no result list in time",
                      self.logged())
        self.assertNotIn("returned 11 matches", self.logged(),
                         "a place that found rows needs no note")

    def test_a_failure_is_an_answer_never_a_server_error(self):
        key = self.turn_on()

        async def broken(*_args, **_kwargs):
            raise RuntimeError("database is locked")

        with mock.patch.object(self.multi, "start", broken):
            status, body = self.get("/newznab/api", {"t": "search", "q": "words", "apikey": key})
        self.assertEqual(status, 200)
        self.assertEqual(ET.fromstring(body).get("code"), "900")
        status, body = self.get("/sabnzbd/api", {"mode": "addfile", "apikey": key},
                                body=b"not a form", content_type="text/plain")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"status": False, "error": "no NZB file was sent"})


if __name__ == "__main__":
    unittest.main()
