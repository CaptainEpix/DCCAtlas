"""A real Prowlarr searches and grabs through the app (2026-10-26), offline.

Prowlarr runs in its own container; this test, in the product image, runs
native Irssi with the engine, the generated file server and the web service,
which listens as "dccatlas" on an internal Docker network with no way out.
The test adds the app to Prowlarr as a Generic Newznab indexer and a SABnzbd
download client through Prowlarr's own API (each is tested by Prowlarr when
saved), searches in Prowlarr, and grabs the result there. Run it with
tools/prowlarr_check.sh; without FSERVE_PROWLARR_URL it is skipped.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
import io
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from web_api_test import PASSWORD, Client, uvicorn
from web_download_native_test import CONTENT, FILENAME, DownloadFixture, RestartableIrssi
from web_http_native_test import poll
from web_source_test import source_values

PROWLARR = os.environ.get("FSERVE_PROWLARR_URL", "")
PROWLARR_KEY = os.environ.get("FSERVE_PROWLARR_KEY", "")
OUR_NAME = "dccatlas"


LIST_ROW = f"!ListBot Alpha One.epub  ::INFO:: {len(CONTENT)}B"


def prowlarr(method: str, path: str, body=None, timeout: float = 120):
    request = Request(PROWLARR.rstrip("/") + path, method=method,
                      data=None if body is None else json.dumps(body).encode(),
                      headers={"X-Api-Key": PROWLARR_KEY, "Content-Type": "application/json"})
    try:
        with urlopen(request, timeout=timeout) as response:
            data = response.read()
    except HTTPError as exc:
        raise AssertionError(f"Prowlarr {method} {path}: {exc.code} {exc.read()[:2000]!r}")
    return json.loads(data) if data else None


def filled(schema: dict, values: dict) -> dict:
    fields = []
    for field in schema["fields"]:
        if field["name"] in values:
            field = {**field, "value": values[field["name"]]}
        fields.append(field)
    return {**schema, "fields": fields}


@unittest.skipUnless(PROWLARR and PROWLARR_KEY and uvicorn is not None,
                     "needs a Prowlarr container (tools/prowlarr_check.sh)")
class RealProwlarrTests(unittest.TestCase):
    def test_prowlarr_adds_tests_searches_and_grabs(self):
        from webapp.__main__ import server_config
        from webapp.runtime import Runtime, Settings

        fixture = DownloadFixture()
        # A list server too (2026-10-27): Get list keeps its list, and
        # Prowlarr finds and grabs a file from it.
        memory = io.BytesIO()
        with zipfile.ZipFile(memory, "w") as archive:
            archive.writestr("ListBot.txt", "D:\\Books\\\r\n" + LIST_ROW + "\r\n")
        fixture.list_servers["ListBot"] = ("ListBot-list.zip", memory.getvalue())
        fixture.row_files[LIST_ROW] = ("Alpha One.epub", CONTENT)
        fixture.start()
        self.addCleanup(fixture.stop)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "password").write_text(PASSWORD + "\n", encoding="utf-8")
        with RestartableIrssi() as native:
            native.command("/set fscrawl_find_quiet_ms 250")
            native.command("/set dcc_autoget OFF")
            # Where this engine files downloads, and where file lists are kept.
            environment = mock.patch.dict(os.environ, {
                "FSERVE_DOWNLOAD_DIR": str(native.home / "fserve-poc" / "downloads"),
                "FSERVE_CONFIG_DIR": str(root / "config")})
            environment.start()
            self.addCleanup(environment.stop)
            runtime = Runtime(Settings(
                database=root / "config" / "fserve.sqlite3", socket_path=str(native.path),
                password_file=str(root / "password"), cookie_secure=False,
                allowed_hosts=("127.0.0.1", OUR_NAME)))
            server = uvicorn.Server(server_config(runtime, "0.0.0.0", 8080))
            thread = threading.Thread(target=server.run, daemon=True)
            thread.start()
            try:
                poll("HTTP server start", lambda: server.started, bool, timeout=10)
                self.walk_through(Client(8080), fixture, native)
            except BaseException:
                print(f"fixture lines={fixture.lines[-12:]!r} errors={fixture.errors!r} "
                      f"chat={fixture.chat_commands!r} offers={fixture.chat_offer_count}",
                      flush=True)
                for record in sorted((native.home / "fserve-poc").glob("transcript-*.tsv")):
                    print(record.name, record.read_text(errors="replace")[-3000:],
                          sep="\n", flush=True)
                raise
            finally:
                server.should_exit = True
                thread.join(timeout=10)
        self.assertFalse(fixture.errors, fixture.errors)

    def walk_through(self, page, fixture, native):
        self.assertEqual(page.login()[0].status, 200)
        poll("engine connection", lambda: page.request("GET", "/api/status")[1],
             lambda status: status.get("engine_available"))
        values = source_values(fixture.port)
        values.pop("provider")
        self.assertEqual(page.request("PUT", "/api/source", values)[0].status, 200)
        self.assertEqual(page.request("POST", "/api/source/connect")[0].status, 200)
        poll("ready source", lambda: page.request("GET", "/api/status")[1],
             lambda status: status["source"]["state"] == "ready")
        key = page.request("PUT", "/api/prowlarr", {"enabled": True})[1]["api_key"]
        poll("Prowlarr to answer", lambda: _alive(), bool, timeout=180)

        # The indexer, as the guide says to add it. Prowlarr tests it when
        # saving: caps, then a search with no words, which sends nothing.
        schemas = prowlarr("GET", "/api/v1/indexer/schema")
        generic = next(schema for schema in schemas if schema["implementation"] == "Newznab"
                       and "generic" in schema["name"].lower())
        indexer = prowlarr("POST", "/api/v1/indexer", filled(generic, {
            "baseUrl": f"http://{OUR_NAME}:8080/newznab", "apiPath": "/api", "apiKey": key,
        }) | {"name": "DCCAtlas", "enable": True, "appProfileId": 1, "priority": 25})
        self.assertEqual(fixture.find_count, 0, "adding and testing it sent nothing to IRC")

        clients = prowlarr("GET", "/api/v1/downloadclient/schema")
        sab = next(schema for schema in clients if schema["implementation"] == "Sabnzbd")
        prowlarr("POST", "/api/v1/downloadclient", filled(sab, {
            "host": OUR_NAME, "port": 8080, "urlBase": "sabnzbd", "apiKey": key,
            "category": "prowlarr",
        }) | {"name": "DCCAtlas", "enable": True, "priority": 1})

        # Without a category Prowlarr sends none, and no source is searched
        # (2026-10-28): nothing is sent, and since 2026-10-29 the Log, not a
        # row, says why.
        bare = prowlarr("GET", "/api/v1/search?" + urlencode(
            {"query": "fixture", "indexerIds": indexer["id"], "type": "search"}))
        self.assertEqual([release["title"] for release in bare], [])
        self.assertEqual(fixture.find_count, 0)
        # With Books, the source's category, it is searched.
        found = prowlarr("GET", "/api/v1/search?" + urlencode(
            {"query": "fixture", "indexerIds": indexer["id"], "type": "search", "limit": 100,
             "categories": 7000}))
        titles = [release["title"] for release in found]
        self.assertIn(FILENAME, titles, found)
        self.assertEqual(fixture.find_count, 1)
        release = next(release for release in found if release["title"] == FILENAME)
        self.assertEqual(release["protocol"], "usenet")

        prowlarr("POST", "/api/v1/search", {"guid": release["guid"],
                                            "indexerId": indexer["id"]})
        started = poll("the download to start", lambda: page.request("GET", "/api/downloads")[1],
                       lambda body: body["downloads"], timeout=60)["downloads"][0]
        # As the page does: one download is brought up to date by asking for it.
        done = poll("the file", lambda: page.request(
            "GET", "/api/downloads/" + started["operation_id"])[1],
            lambda row: row["state"] == "complete", timeout=90)
        published = native.home / "fserve-poc" / "downloads" / done["download_path"]
        self.assertEqual(published.read_bytes(), CONTENT)

        # The same search again in Prowlarr sends nothing.
        again = prowlarr("GET", "/api/v1/search?" + urlencode(
            {"query": "Fixture", "indexerIds": indexer["id"], "type": "search",
             "categories": 7000}))
        self.assertIn(FILENAME, [release["title"] for release in again])
        self.assertEqual((fixture.find_count, fixture.trigger_count, fixture.get_count),
                         (1, 1, 1), "one search, one trigger, one request")

        # A list server's list, kept by Get list, is searched by Prowlarr,
        # and a file from it grabbed: its row is posted once.
        fixture.advertise("ListBot", "Type: @ListBot For My List Of: 1 Files")
        poll("the list server's advert", lambda: page.request(
            "GET", "/api/sources/primary/adverts")[1],
            lambda body: any(advert["nick"] == "ListBot" for advert in body["adverts"]))
        asked = page.request("POST", "/api/sources/primary/list",
                             {"idempotency_key": "prowlarr-real-list-0001", "sender": "ListBot"})
        self.assertEqual(asked[0].status, 200, asked)
        poll("the list to be read", lambda: page.request("GET", "/api/file-lists")[1],
             lambda body: any(entry["state"] == "done" for entry in body["imports"]), timeout=90)
        listed = prowlarr("GET", "/api/v1/search?" + urlencode(
            {"query": "Alpha One", "indexerIds": indexer["id"], "type": "search"}))
        release = next(release for release in listed if release["title"] == "Alpha One.epub")
        prowlarr("POST", "/api/v1/search", {"guid": release["guid"], "indexerId": indexer["id"]})
        fetched = poll("the listed file", lambda: page.request("GET", "/api/downloads")[1],
                       lambda body: any(row["name"] == "Alpha One.epub"
                                        for row in body["downloads"]), timeout=60)
        operation = next(row for row in fetched["downloads"] if row["name"] == "Alpha One.epub")
        done = poll("the listed file to arrive", lambda: page.request(
            "GET", "/api/downloads/" + operation["operation_id"])[1],
            lambda row: row["state"] == "complete", timeout=90)
        self.assertTrue(done["download_path"].endswith("/ListBot/@list/Alpha One.epub"), done)
        self.assertEqual(fixture.list_requests, ["ListBot"])
        self.assertEqual(fixture.row_requests, [LIST_ROW])


def _alive() -> bool:
    try:
        prowlarr("GET", "/api/v1/system/status", timeout=5)
        return True
    except Exception:
        time.sleep(2)
        return False


if __name__ == "__main__":
    unittest.main()
