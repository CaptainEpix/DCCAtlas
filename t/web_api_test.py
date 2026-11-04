"""W5 HTTP API tests: authentication, CSRF, origin checks and error mapping.

The real ASGI application is served by uvicorn on a loopback port and driven
with the standard-library HTTP client. Services are replaced by small fakes;
`web_http_native_test.py` covers the same API against the native engine.
"""

from __future__ import annotations

from contextlib import closing
import hashlib
import http.client
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

try:
    import uvicorn
    from webapp.__main__ import server_config
    from webapp.api import MAX_BODY_BYTES, SESSION_COOKIE
except ImportError:  # the engine-only test image has no web framework
    uvicorn = None

from webapp.auth import (AuthError, Authenticator, CredentialStore, FAILURES_BEFORE_DELAY,
                         RESET_CODE_INTERVAL_SECONDS, RESET_CODE_SECONDS, read_password_file)
from webapp.downloads import DownloadError, DownloadService
from webapp.manifests import ManifestError
from webapp.engine_client import EngineRequestError
from webapp.searches import SearchError
from webapp.sources import SourceConfigStore, SourceService, UnknownSource

PASSWORD = "fixture-operator-password"
OPERATION = "web-download-" + "a" * 64


class FakeSources:
    engine_source = staticmethod(SourceService.engine_source)

    def __init__(self):
        self.saved = None
        self.connected = 0
        self.further = {}     # source_id -> configuration, for the several-source routes
        self.calls = []

    async def status(self):
        configurations = ([self.saved] if self.saved else []) + list(self.further.values())
        return {"configuration": self.saved, "configurations": configurations,
                "engine": {"source": {"state": "configured", "source_id": "primary"},
                           "journal_ready": True,
                           "servers": [{"tag": "must-not-leak"}]}}

    async def save(self, values, source_id="primary"):
        self.saved = dict(values, revision=1, source_id=source_id)
        return self.saved

    async def create(self, values):
        source_id = f"src-{len(self.further) + 1:012d}"
        self.further[source_id] = dict(values, revision=1, source_id=source_id)
        return self.further[source_id]

    async def update(self, values, source_id):
        if source_id not in self.further:
            raise UnknownSource("no such source is configured")
        self.further[source_id] = dict(values, revision=2, source_id=source_id)
        return self.further[source_id]

    async def remove(self, source_id):
        if source_id not in self.further:
            raise UnknownSource("no such source is configured")
        return self.further.pop(source_id)

    async def connect(self, source_id="primary"):
        self.calls.append(("connect", source_id))
        if source_id != "primary":
            if source_id not in self.further:
                raise UnknownSource("no such source is configured")
            return {}
        self.connected += 1
        raise EngineRequestError("source_busy", "fixture\x07 busy")

    async def disconnect(self, source_id="primary"):
        self.calls.append(("disconnect", source_id))
        if source_id != "primary":
            return {}
        raise TimeoutError("fixture engine silence")


class FakeSearches:
    broken = False

    def __init__(self):
        self.searched = []

    async def search(self, terms, source_id="primary"):
        self.searched.append((terms, source_id))
        if terms == "fast":
            raise SearchError("poll_too_fast", "slow down")
        return {"search_id": "search-" + "1" * 32, "terms": terms, "state": "collecting"}

    async def history(self, *, limit):
        if self.broken:
            raise RuntimeError("fixture defect")
        return []

    async def status(self, search_id):
        raise SearchError("unknown_search", "search history entry was not found")

    async def page(self, search_id, *, offset, limit):
        return {"search_id": search_id, "offset": offset, "page_size": limit, "results": []}


class FakeDownloads:
    uncertain_resolution_phrase = staticmethod(DownloadService.uncertain_resolution_phrase)

    def __init__(self):
        self.abandonable = False
        self.requests = []

    def row(self):
        return {"operation_id": OPERATION, "state": "needs_attention",
                "abandonable": self.abandonable}

    async def download(self, idempotency_key, result_id):
        self.requests.append((idempotency_key, result_id))
        raise DownloadError("download_busy", "another download operation is still active")

    async def history(self, *, limit):
        return [self.row()]

    async def status(self, operation_id):
        if operation_id != OPERATION:
            raise DownloadError("unknown_operation", "download operation was not found")
        return self.row()

    async def cancel(self, operation_id):
        return self.row()

    async def resolve_uncertain(self, operation_id, *, confirmation):
        raise DownloadError("confirmation_required", "confirm the exact phrase")


class FakeMulti:
    def __init__(self):
        self.started = []

    async def start(self, terms, source_ids, list_keys=None):
        self.started.append((terms, source_ids) if list_keys is None
                            else (terms, source_ids, list_keys))
        if not source_ids and not list_keys:
            raise SearchError("invalid_request", "choose the sources to search")
        return {"group_id": "multi-" + "3" * 32, "terms": terms, "state": "running",
                "members": [{"source_id": item} for item in source_ids or []]}

    async def status(self, group_id):
        return self.summary(group_id)

    async def history(self, *, limit):
        return [self.summary("multi-" + "3" * 32)][:limit]

    def summary(self, group_id):
        if group_id != "multi-" + "3" * 32:
            raise SearchError("unknown_search", "search was not found")
        return {"group_id": group_id, "state": "complete", "members": []}

    async def page(self, group_id, *, offset, limit):
        return {**self.summary(group_id), "offset": offset, "page_size": limit, "results": []}


class FakeManifests:
    def __init__(self):
        self.calls = []

    async def lists(self):
        return {"lists": []}

    async def import_download(self, operation_id):
        self.calls.append(("import", operation_id))
        if operation_id != OPERATION:
            raise ManifestError("unknown_operation", "download operation was not found")
        return {"route_key": "a" * 64, "files": 2, "lists": []}

    async def placed_files(self):
        return {"files": [{"path": "lists/one.txt", "bytes": 10, "modified_at": 1}],
                "complete": True}

    async def import_upload(self, chunks, name, source_id, sender, trigger):
        size = 0
        async for chunk in chunks:
            size += len(chunk)
        self.calls.append(("import_upload", name, size, source_id, sender, trigger))
        return {"route_key": "c" * 64, "files": 3, "lists": []}

    async def import_file(self, path, source_id, sender, trigger):
        self.calls.append(("import_file", path, source_id, sender, trigger))
        if path != "lists/one.txt":
            raise ManifestError("invalid_file", "that is not a file in the downloads folder")
        return {"route_key": "b" * 64, "files": 1, "lists": []}

    async def search(self, query, route_key=None, cursor=None):
        self.calls.append(("search", query, route_key, cursor))
        if not isinstance(query, str) or len(query) < 3:
            raise ManifestError("invalid_query", "type at least three characters of a file name")
        return {"query": query, "results": [], "has_more": False, "next_cursor": None}


class Client:
    def __init__(self, port: int):
        self.port = port
        self.cookie = None
        self.csrf = None

    def request(self, method, path, body=None, *, headers=None, raw=None, send_csrf=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            sent = {"Host": f"127.0.0.1:{self.port}"}
            payload = raw
            if method not in ("GET", "HEAD"):
                sent["Content-Type"] = "application/json"
                if payload is None:
                    payload = json.dumps(body if body is not None else {}).encode()
                if self.csrf and send_csrf:
                    sent["X-CSRF-Token"] = self.csrf
            if self.cookie:
                sent["Cookie"] = f"{SESSION_COOKIE}={self.cookie}"
            sent.update(headers or {})
            connection.request(method, path, body=payload, headers=sent)
            response = connection.getresponse()
            data = response.read()
            for value in response.headers.get_all("set-cookie") or []:
                if value.startswith(SESSION_COOKIE + "="):
                    token = value.split(";", 1)[0].split("=", 1)[1].strip('"')
                    self.cookie = token or None
            try:
                parsed = json.loads(data)
            except ValueError:
                parsed = data
            return response, parsed
        finally:
            connection.close()

    def login(self, password=PASSWORD):
        response, body = self.request("POST", "/api/login", {"password": password})
        if response.status == 200:
            self.csrf = body["csrf_token"]
        return response, body


@unittest.skipIf(uvicorn is None, "the web framework is not installed in this image")
class WebApiTests(unittest.TestCase):
    def serve(self, *, password_file=True, services=True):
        from webapp.runtime import Runtime, Services, Settings

        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        secret = root / "password"
        if password_file:
            secret.write_text(PASSWORD + "\n", encoding="utf-8")
        runtime = Runtime(Settings(
            database=root / "config" / "fserve.sqlite3", socket_path=str(root / "absent.sock"),
            password_file=str(secret), cookie_secure=False,
            allowed_hosts=("127.0.0.1", "localhost"),
        ))

        async def no_engine():
            return None

        runtime.start = runtime.stop = no_engine
        self.sources, self.searches, self.downloads = FakeSources(), FakeSearches(), FakeDownloads()
        self.multi = FakeMulti()
        self.manifests = FakeManifests()
        if services:
            runtime.services = Services(self.sources, self.searches, self.downloads,
                                        self.multi, self.manifests)
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
        self.runtime = runtime
        return Client(server.servers[0].sockets[0].getsockname()[1])

    def test_everything_but_health_session_and_assets_requires_a_session(self):
        client = self.serve()
        response, body = client.request("GET", "/healthz")
        self.assertEqual((response.status, body), (200, {"status": "ok"}))
        response, body = client.request("GET", "/api/session")
        self.assertEqual(body, {"authenticated": False, "setup_required": False,
                                "setup_problem": None, "csrf_token": None})
        self.assertEqual(response.headers["cache-control"], "no-store")
        for method, path in (("GET", "/api/status"), ("GET", "/api/searches"),
                             ("GET", "/api/downloads"), ("POST", "/api/searches"),
                             ("PUT", "/api/source"), ("POST", "/api/source/connect"),
                             ("POST", "/api/downloads"),
                             ("POST", f"/api/downloads/{OPERATION}/cancel"),
                             ("GET", "/api/file-lists/placed"), ("POST", "/api/file-lists"),
                             ("POST", "/api/file-lists/upload"),
                             ("GET", "/api/saved-searches"), ("POST", "/api/saved-searches"),
                             ("DELETE", "/api/saved-searches/saved-" + "0" * 32),
                             ("GET", "/api/settings"), ("PUT", "/api/settings"),
                             ("GET", "/api/prowlarr"), ("PUT", "/api/prowlarr"),
                             ("POST", "/api/prowlarr/key"),
                             ("POST", "/api/sources/primary/list"),
                             ("POST", "/api/password")):
            response, body = client.request(method, path)
            self.assertEqual((response.status, body["error"]["code"]),
                             (401, "not_authenticated"), (method, path))
        response, page = client.request("GET", "/")
        self.assertEqual(response.status, 200)
        self.assertIn(b"<title>DCCAtlas</title>", page)
        self.assertIn("default-src 'self'", response.headers["content-security-policy"])
        self.assertEqual(response.headers["x-content-type-options"], "nosniff")
        self.assertEqual(response.headers["x-frame-options"], "DENY")
        self.assertIsNone(response.headers.get("server"))
        self.assertIsNone(response.headers.get("access-control-allow-origin"))

    def test_login_cookie_logout_and_csrf_token(self):
        client = self.serve()
        response, body = client.login("wrong-password-value")
        self.assertEqual((response.status, body["error"]["code"]), (401, "invalid_credentials"))
        self.assertIsNone(client.cookie)

        response, body = client.login()
        self.assertEqual(response.status, 200)
        self.assertTrue(body["authenticated"])
        cookie = next(value for value in response.headers.get_all("set-cookie")
                      if value.startswith(SESSION_COOKIE + "="))
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=strict", cookie)
        self.assertIn("Path=/", cookie)
        self.assertNotIn(PASSWORD, json.dumps(body))

        response, status = client.request("GET", "/api/status")
        self.assertEqual(response.status, 200)
        self.assertTrue(status["engine_available"])
        self.assertNotIn("must-not-leak", json.dumps(status))

        response, body = client.request("POST", "/api/searches", {"terms": "x"}, send_csrf=False)
        self.assertEqual((response.status, body["error"]["code"]), (403, "csrf_failed"))
        response, body = client.request(
            "POST", "/api/searches", {"terms": "x"}, headers={"X-CSRF-Token": "guess"},
            send_csrf=False)
        self.assertEqual(response.status, 403)
        response, body = client.request("POST", "/api/searches", {"terms": "x"})
        self.assertEqual((response.status, body["terms"]), (200, "x"))

        token = client.cookie
        response, body = client.request("POST", "/api/logout")
        self.assertEqual(response.status, 200)
        self.assertFalse(body["authenticated"])
        client.cookie = token
        response, body = client.request("GET", "/api/status")
        self.assertEqual(response.status, 401, "a signed-out session token must be dead")

    def test_cross_origin_and_malformed_mutations_are_refused(self):
        client = self.serve()
        client.login()
        host = f"127.0.0.1:{client.port}"
        for headers in ({"Origin": "http://evil.example"},
                        {"Origin": f"http://localhost.evil.example:{client.port}"},
                        {"Origin": "null"},
                        {"Sec-Fetch-Site": "cross-site"},
                        {"Sec-Fetch-Site": "same-site"}):
            response, body = client.request(
                "POST", "/api/searches", {"terms": "x"}, headers=headers)
            self.assertEqual((response.status, body["error"]["code"]),
                             (403, "cross_origin"), headers)
        response, body = client.request(
            "POST", "/api/login", {"password": PASSWORD}, headers={"Origin": "http://evil.example"})
        self.assertEqual(response.status, 403, "login must not be drivable from another site")
        for headers in ({"Origin": f"http://{host}"}, {"Origin": f"https://{host}"},
                        {"Sec-Fetch-Site": "same-origin"}):
            response, body = client.request(
                "POST", "/api/searches", {"terms": "x"}, headers=headers)
            self.assertEqual(response.status, 200, headers)

        response, body = client.request(
            "POST", "/api/searches", {"terms": "x"}, headers={"Content-Type": "text/plain"})
        self.assertEqual((response.status, body["error"]["code"]), (415, "unsupported_media_type"))
        response, body = client.request("POST", "/api/searches", raw=b"{not json")
        self.assertEqual((response.status, body["error"]["code"]), (400, "invalid_request"))
        response, body = client.request("POST", "/api/searches", {"terms": "x", "extra": 1})
        self.assertEqual(response.status, 400)
        response, body = client.request("POST", "/api/searches", raw=b"[1]")
        self.assertEqual(response.status, 400)
        response, body = client.request(
            "POST", "/api/searches", raw=b'{"terms":"' + b"x" * MAX_BODY_BYTES + b'"}')
        self.assertEqual(response.status, 413)
        response, body = client.request("GET", "/api/status", headers={"Host": "evil.example"})
        self.assertEqual(response.status, 400, "an unexpected Host header is refused")
        response, body = client.request("GET", "/api/searches/x/results?offset=-1")
        self.assertEqual((response.status, body["error"]["code"]), (400, "invalid_page"))

    def test_service_errors_map_to_stable_statuses_without_leaking_detail(self):
        client = self.serve()
        client.login()
        cases = (
            ("POST", "/api/downloads", {"idempotency_key": "k" * 16, "result_id": "r"},
             409, "download_busy"),
            ("GET", "/api/downloads/" + "web-download-" + "b" * 64, None, 404, "unknown_operation"),
            ("GET", "/api/searches/search-" + "2" * 32, None, 404, "unknown_search"),
            ("POST", "/api/searches", {"terms": "fast"}, 429, "poll_too_fast"),
            ("POST", "/api/source/connect", {}, 409, "source_busy"),
            ("POST", "/api/source/disconnect", {}, 503, "engine_unavailable"),
            ("POST", f"/api/downloads/{OPERATION}/abandon", {"confirmation": "no"},
             400, "confirmation_required"),
        )
        for method, path, body, status, code in cases:
            response, data = client.request(method, path, body)
            self.assertEqual((response.status, data["error"]["code"]), (status, code), path)
        response, data = client.request("POST", "/api/source/connect", {})
        self.assertEqual(data["error"]["message"], "fixture busy", "control characters are removed")

        response, saved = client.request("PUT", "/api/source", {
            "label": "Lab", "host": "127.0.0.1", "port": 6667, "tls": False,
            "nickname": "Nick", "channel": "#lab"})
        self.assertEqual(response.status, 200)
        self.assertEqual(self.sources.saved["provider"], "sysreset_find")
        response, data = client.request("PUT", "/api/source", {"server_tag": "other"})
        self.assertEqual(response.status, 400, "only the fields of a source are accepted")

        response, data = client.request("GET", "/api/downloads")
        self.assertIsNone(data["downloads"][0]["abandon_confirmation"])
        self.downloads.abandonable = True
        response, data = client.request("GET", "/api/downloads/" + OPERATION)
        self.assertEqual(data["abandon_confirmation"], "ABANDON-UNCERTAIN " + OPERATION)

        self.runtime.services = None
        response, data = client.request("GET", "/api/searches")
        self.assertEqual((response.status, data["error"]["code"]), (503, "engine_unavailable"))
        response, data = client.request("GET", "/api/status")
        self.assertEqual((response.status, data["engine_available"]), (200, False))

    def test_clear_all_hides_earlier_searches_but_not_a_running_one(self):
        # Clear all under Earlier searches (2026-10-29).
        class Store(dict):
            def value(self, name):
                return self.get(name)

            def put(self, changes):
                self.update(changes)

        client = self.serve()
        client.login()
        self.downloads.settings = SimpleNamespace(store=Store())
        ended = {"group_id": "multi-" + "3" * 32, "state": "complete", "members": [],
                 "started_at": time.time() - 60}
        running = {**ended, "group_id": "multi-" + "4" * 32, "state": "running"}

        async def history(*, limit):
            return [running, ended]

        self.multi.history = history
        response, body = client.request("GET", "/api/search-groups")
        self.assertEqual(len(body["groups"]), 2)
        response, body = client.request("POST", "/api/searches/history/clear", {})
        self.assertEqual((response.status, body), (200, {"cleared": True}))
        response, body = client.request("GET", "/api/search-groups")
        self.assertEqual([group["state"] for group in body["groups"]], ["running"],
                         "the running one stays; the ended one is hidden, not deleted")

    def test_several_sources_are_listed_added_changed_removed_and_searched_by_id(self):
        client = self.serve()
        client.login()
        fields = {"label": "Lab", "host": "127.0.0.1", "port": 6667, "tls": False,
                  "nickname": "Nick", "channel": "#lab"}
        response, data = client.request("PUT", "/api/source", fields)
        self.assertEqual(response.status, 200)
        self.assertEqual([entry["configuration"]["source_id"] for entry in data["sources"]],
                         ["primary"])
        self.assertEqual(data["sources"][0]["source"]["state"], "configured")

        second = dict(fields, label="Second", port=6668)
        response, data = client.request("POST", "/api/sources", second)
        self.assertEqual(response.status, 200)
        second_id = data["source_id"]
        self.assertEqual(self.sources.further[second_id]["provider"], "sysreset_find",
                         "a source is a file-server source unless it says otherwise")
        self.assertNotIn("search_bot", self.sources.further[second_id])
        self.assertEqual([entry["configuration"]["label"] for entry in data["sources"]],
                         ["Lab", "Second"])
        self.assertIsNone(data["sources"][1]["source"], "the engine has not been told yet")
        # The first source is still what the single-source keys describe.
        self.assertEqual(data["configuration"]["source_id"], "primary")

        response, data = client.request("GET", "/api/sources")
        self.assertEqual((response.status, len(data["sources"])), (200, 2))
        response, data = client.request("GET", "/api/status")
        self.assertEqual(len(data["sources"]), 2)
        self.assertNotIn("servers", json.dumps(data))

        response, data = client.request(
            "PUT", f"/api/sources/{second_id}", dict(second, label="Renamed"))
        self.assertEqual(response.status, 200)
        self.assertEqual(self.sources.further[second_id]["label"], "Renamed")
        response, data = client.request(
            "PUT", f"/api/sources/{second_id}", dict(second, unknown="field"))
        self.assertEqual(response.status, 400)
        # The other kind of source: a channel with a search bot.
        response, data = client.request(
            "PUT", f"/api/sources/{second_id}",
            dict(second, provider="searchbot", search_bot="SearchBot"))
        self.assertEqual(response.status, 200)
        self.assertEqual(
            (self.sources.further[second_id]["provider"],
             self.sources.further[second_id]["search_bot"]), ("searchbot", "SearchBot"))
        # The page sends an empty nickname for a file-server source.
        response, data = client.request(
            "PUT", f"/api/sources/{second_id}",
            dict(second, provider="sysreset_find", search_bot=""))
        self.assertEqual(response.status, 200)
        self.assertNotIn("search_bot", self.sources.further[second_id])

        for method, path, body in (
                ("PUT", "/api/sources/src-missing", second),
                ("DELETE", "/api/sources/src-missing", None),
                ("POST", "/api/sources/src-missing/connect", {})):
            response, data = client.request(method, path, body)
            self.assertEqual((response.status, data["error"]["code"]),
                             (404, "unknown_source"), path)

        response, data = client.request("POST", f"/api/sources/{second_id}/connect", {})
        self.assertEqual(response.status, 200)
        response, data = client.request("POST", f"/api/sources/{second_id}/disconnect", {})
        self.assertEqual(response.status, 200)
        self.assertEqual(self.sources.calls, [("connect", "src-missing"),
                                              ("connect", second_id), ("disconnect", second_id)])

        response, data = client.request(
            "POST", "/api/searches", {"terms": "one", "source_id": second_id})
        self.assertEqual(response.status, 200)
        response, data = client.request("POST", "/api/searches", {"terms": "two"})
        self.assertEqual(response.status, 200)
        self.assertEqual(self.searches.searched, [("one", second_id), ("two", "primary")])
        response, data = client.request("POST", "/api/searches", {"terms": "x", "source_id": 7})
        self.assertEqual(response.status, 400)

        response, data = client.request("DELETE", f"/api/sources/{second_id}")
        self.assertEqual(response.status, 200)
        self.assertEqual(len(data["sources"]), 1)
        # Mutations still need the session's request token.
        response, data = client.request("POST", "/api/sources", second, send_csrf=False)
        self.assertEqual((response.status, data["error"]["code"]), (403, "csrf_failed"))

    def test_a_search_across_sources_names_its_sources(self):
        client = self.serve()
        response, body = client.request(
            "POST", "/api/search-groups", {"terms": "x", "source_ids": ["primary"]})
        self.assertEqual(response.status, 401, "it needs a session like everything else")
        client.login()
        response, body = client.request(
            "POST", "/api/search-groups", {"terms": "x", "source_ids": ["primary", "src-2"]})
        self.assertEqual((response.status, body["state"]), (200, "running"))
        self.assertEqual(self.multi.started, [("x", ["primary", "src-2"])])
        group = body["group_id"]
        response, body = client.request("POST", "/api/search-groups", {"terms": "x"})
        self.assertEqual((response.status, body["error"]["code"]), (400, "invalid_request"))
        response, body = client.request(
            "POST", "/api/search-groups", {"terms": "x", "source_ids": ["a"], "extra": 1})
        self.assertEqual(response.status, 400)
        response, body = client.request("GET", f"/api/search-groups/{group}")
        self.assertEqual((response.status, body["state"]), (200, "complete"))
        response, body = client.request(
            "GET", f"/api/search-groups/{group}/results?offset=10&limit=5")
        self.assertEqual((response.status, body["offset"], body["page_size"]), (200, 10, 5))
        response, body = client.request("GET", "/api/search-groups/multi-" + "4" * 32)
        self.assertEqual((response.status, body["error"]["code"]), (404, "unknown_search"))
        # Stored file lists may be searched with the sources, or alone.
        response, body = client.request(
            "POST", "/api/search-groups",
            {"terms": "x", "source_ids": ["primary"], "list_keys": ["a" * 64]})
        self.assertEqual(response.status, 200)
        response, body = client.request(
            "POST", "/api/search-groups", {"terms": "x", "list_keys": ["a" * 64]})
        self.assertEqual(response.status, 200)
        self.assertEqual(self.multi.started[-2:],
                         [("x", ["primary"], ["a" * 64]), ("x", None, ["a" * 64])])
        # Combined searches are listed for the history.
        response, body = client.request("GET", "/api/search-groups")
        self.assertEqual((response.status, [group["group_id"] for group in body["groups"]]),
                         (200, [group]))
        response, body = client.request(
            "POST", "/api/search-groups", {"terms": "x", "source_ids": ["a"]}, send_csrf=False)
        self.assertEqual((response.status, body["error"]["code"]), (403, "csrf_failed"))

    def test_file_lists_are_added_from_a_download_and_searched(self):
        client = self.serve()
        response, body = client.request("GET", "/api/file-lists")
        self.assertEqual(response.status, 401)
        client.login()
        response, body = client.request("GET", "/api/file-lists")
        self.assertEqual((response.status, body), (200, {"lists": []}))
        response, body = client.request("POST", "/api/file-lists", {"operation_id": OPERATION})
        self.assertEqual((response.status, body["files"]), (200, 2))
        response, body = client.request(
            "POST", "/api/file-lists", {"operation_id": "web-download-" + "b" * 64})
        self.assertEqual((response.status, body["error"]["code"]), (404, "unknown_operation"))
        response, body = client.request(
            "POST", "/api/file-lists", {"operation_id": OPERATION, "path": "/etc/passwd"})
        self.assertEqual((response.status, body["error"]["code"]), (400, "invalid_request"),
                         "a list is either a download or a placed file, never both")
        response, body = client.request(
            "POST", "/api/file-lists", {"operation_id": OPERATION, "extra": 1})
        self.assertEqual(response.status, 400)

        # A file placed in the downloads folder by hand, with whose list it is.
        response, body = client.request("GET", "/api/file-lists/placed")
        self.assertEqual((response.status, [item["path"] for item in body["files"]]),
                         (200, ["lists/one.txt"]))
        placed = {"path": "lists/one.txt", "source_id": "primary", "sender": "Fixture",
                  "trigger": "!Fixture"}
        response, body = client.request("POST", "/api/file-lists", placed)
        self.assertEqual((response.status, body["files"]), (200, 1))
        self.assertEqual(self.manifests.calls[-1],
                         ("import_file", "lists/one.txt", "primary", "Fixture", "!Fixture"))
        response, body = client.request(
            "POST", "/api/file-lists", {**placed, "path": "/etc/passwd"})
        self.assertEqual((response.status, body["error"]["code"]), (400, "invalid_file"))
        response, body = client.request("POST", "/api/file-lists", placed, send_csrf=False)
        self.assertEqual((response.status, body["error"]["code"]), (403, "csrf_failed"))
        response, body = client.request(
            "POST", "/api/file-lists/search", {"query": "abc", "route_key": "a" * 64})
        self.assertEqual((response.status, body["query"]), (200, "abc"))
        response, body = client.request("POST", "/api/file-lists/search", {"query": "ab"})
        self.assertEqual((response.status, body["error"]["code"]), (400, "invalid_query"))
        response, body = client.request(
            "POST", "/api/file-lists/search", {"query": "abc"}, send_csrf=False)
        self.assertEqual((response.status, body["error"]["code"]), (403, "csrf_failed"))
        self.assertEqual(self.manifests.calls[-1], ("search", "ab", None, None))

        # A list sent from the page (2026-10-28): the file is the body, so
        # this one route takes more than the small JSON bodies the rest do.
        listed = b"!Shelf Book.epub  ::INFO:: 1MB\r\n" * 4096
        self.assertGreater(len(listed), MAX_BODY_BYTES)
        upload = "/api/file-lists/upload?name=shelf.txt&source_id=primary&sender=Shelf&trigger="
        octets = {"Content-Type": "application/octet-stream"}
        response, body = client.request("POST", upload, raw=listed, headers=octets)
        self.assertEqual((response.status, body["files"]), (200, 3), body)
        self.assertEqual(self.manifests.calls[-1],
                         ("import_upload", "shelf.txt", len(listed), "primary", "Shelf", ""))
        response, body = client.request("POST", upload, raw=listed)
        self.assertEqual((response.status, body["error"]["code"]), (415, "unsupported_media_type"))
        response, body = client.request("POST", upload + "&extra=1", raw=listed, headers=octets)
        self.assertEqual((response.status, body["error"]["code"]), (400, "invalid_request"))
        response, body = client.request("POST", upload, raw=listed, headers=octets,
                                        send_csrf=False)
        self.assertEqual((response.status, body["error"]["code"]), (403, "csrf_failed"))
        response, body = client.request("POST", "/api/file-lists", raw=listed)
        self.assertEqual(response.status, 413, "other routes keep the small limit")

    def test_missing_password_blocks_login_and_repeated_failures_are_delayed(self):
        client = self.serve(password_file=False)
        response, body = client.request("GET", "/api/session")
        self.assertTrue(body["setup_required"])
        response, body = client.login()
        self.assertEqual((response.status, body["error"]["code"]), (503, "setup_required"))

        client = self.serve()
        for _ in range(FAILURES_BEFORE_DELAY):
            response, body = client.login("wrong-password-value")
            self.assertEqual(response.status, 401)
        response, body = client.login()
        self.assertEqual((response.status, body["error"]["code"]), (429, "login_delayed"))
        self.assertGreaterEqual(int(response.headers["retry-after"]), 1)

    def test_parallel_wrong_passwords_cannot_outrun_the_delay(self):
        client = self.serve()
        for _ in range(FAILURES_BEFORE_DELAY - 1):
            self.assertEqual(client.login("wrong-password-value")[0].status, 401)
        statuses = []
        barrier = threading.Barrier(12)

        def guess():
            barrier.wait()
            statuses.append(Client(client.port).login("wrong-password-value")[0].status)

        threads = [threading.Thread(target=guess) for _ in range(12)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=60)
        self.assertEqual(sorted(statuses), [401] + [429] * 11,
                         "only the attempt that reaches the limit is checked")

    def test_rejected_password_file_is_reported_while_the_old_password_applies(self):
        client = self.serve()
        response, body = client.request("GET", "/api/session")
        self.assertIsNone(body["setup_problem"])
        self.runtime.password_problem = "fixture problem"
        response, body = client.request("GET", "/api/session")
        self.assertEqual((body["setup_required"], body["setup_problem"]),
                         (False, "fixture problem"))
        self.assertEqual(client.login()[0].status, 200)

    def test_the_page_opens_by_private_address_or_listed_name_only(self):
        client = self.serve()
        cases = {
            "127.0.0.1:8080": 200, "localhost:8080": 200, "192.168.1.50:8080": 200,
            "10.0.0.7": 200, "172.20.1.1:8080": 200, "[fd12:3456::1]:8080": 200,
            "[::1]": 200,
            # Names other than the listed ones, public addresses, and the
            # malformed, are refused: a name can be made to point here.
            "tower:8080": 400, "attacker.example": 400, "192.168.1.50.nip.io": 400,
            "203.0.113.9:8080": 400, "fd12:3456::1": 400, "[192.168.1.50]": 400,
            "": 400,
        }
        for host, status in cases.items():
            with self.subTest(host=host):
                response, _ = client.request("GET", "/healthz", headers={"Host": host})
                self.assertEqual(response.status, status)

    def test_a_listed_name_is_accepted(self):
        from webapp.api import host_allowed

        allowed = frozenset({"localhost", "127.0.0.1", "tower", "tower.local"})
        self.assertTrue(host_allowed("Tower:8080", allowed))
        self.assertTrue(host_allowed("tower.local", allowed))
        self.assertFalse(host_allowed("tower.example", allowed))
        self.assertFalse(host_allowed("[tower]:8080", allowed))

    def code_from(self, logs, words):
        line = next(line for line in logs.output if words in line)
        return line.split(words + ": ", 1)[1].split(" ", 1)[0]

    def test_the_first_password_is_set_with_the_code_from_the_log(self):
        with self.assertLogs("dccatlas.web", level="WARNING") as logs:
            client = self.serve(password_file=False)
        code = self.code_from(logs, "Setup code")
        self.assertRegex(code, r"^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$")
        self.assertTrue(client.request("GET", "/api/session")[1]["setup_required"])
        new = "first-page-password"
        response, body = client.request("POST", "/api/setup", {"code": "AAAA-BBBB-CCCC",
                                                               "password": new})
        self.assertEqual((response.status, body["error"]["code"]), (401, "invalid_code"))
        response, body = client.request("POST", "/api/setup", {"code": code, "password": "short"})
        self.assertEqual((response.status, body["error"]["code"]), (400, "invalid_password"))
        # As typed: any case, spaces for dashes.
        response, body = client.request("POST", "/api/setup", {
            "code": code.lower().replace("-", " "), "password": new})
        self.assertEqual(response.status, 200, body)
        self.assertTrue(body["authenticated"])
        client.csrf = body["csrf_token"]
        self.assertEqual(client.request("GET", "/api/status")[0].status, 200, "signed in")
        response, body = client.request("POST", "/api/setup", {"code": code, "password": new})
        self.assertEqual((response.status, body["error"]["code"]), (409, "already_set_up"))
        other = Client(client.port)
        self.assertEqual(other.login(new)[0].status, 200)
        self.assertNotIn(code, json.dumps(self.runtime.log.page()),
                         "the code is in the container's output, not the page's Log")

    def test_a_forgotten_password_is_reset_with_a_code_from_the_log(self):
        client = self.serve()
        self.assertEqual(client.login()[0].status, 200)
        stranger = Client(client.port)
        with self.assertLogs("dccatlas.web", level="WARNING") as logs:
            response, body = stranger.request("POST", "/api/password/reset-code")
        self.assertEqual((response.status, body), (200, {"written": True, "minutes": 15}))
        code = self.code_from(logs, "Password reset code")
        self.assertNotIn(code, json.dumps(body))
        response, body = stranger.request("POST", "/api/password/reset-code")
        self.assertEqual((response.status, body["error"]["code"]),
                         (429, "code_requested_recently"), "at most one a minute")
        self.assertGreaterEqual(int(response.headers["retry-after"]), 1)
        new = "reset-page-password"
        response, body = stranger.request("POST", "/api/password/reset",
                                          {"code": "AAAA-BBBB-CCCC", "password": new})
        self.assertEqual((response.status, body["error"]["code"]), (401, "invalid_code"))
        response, body = stranger.request("POST", "/api/password/reset",
                                          {"code": code, "password": new})
        self.assertEqual(response.status, 200, body)
        self.assertTrue(body["authenticated"])
        self.assertEqual(client.request("GET", "/api/status")[0].status, 401,
                         "whoever was signed in is signed out")
        self.assertEqual(Client(client.port).login()[0].status, 401, "the old password is gone")
        self.assertEqual(Client(client.port).login(new)[0].status, 200)
        response, body = Client(client.port).request("POST", "/api/password/reset",
                                                     {"code": code, "password": PASSWORD})
        self.assertEqual((response.status, body["error"]["code"]), (401, "invalid_code"),
                         "a code works once")

    def test_the_password_is_changed_with_the_current_one(self):
        client = self.serve()
        client.login()
        elsewhere = Client(client.port)
        elsewhere.login()
        new = "changed-page-password"
        response, body = client.request("POST", "/api/password",
                                        {"current_password": PASSWORD, "password": new},
                                        send_csrf=False)
        self.assertEqual((response.status, body["error"]["code"]), (403, "csrf_failed"))
        response, body = client.request("POST", "/api/password",
                                        {"current_password": "wrong-password-value",
                                         "password": new})
        self.assertEqual((response.status, body["error"]["code"]), (401, "invalid_credentials"))
        response, body = client.request("POST", "/api/password",
                                        {"current_password": PASSWORD, "password": "short"})
        self.assertEqual((response.status, body["error"]["code"]), (400, "invalid_password"))
        response, body = client.request("POST", "/api/password",
                                        {"current_password": PASSWORD, "password": new})
        self.assertEqual(response.status, 200, body)
        client.csrf = body["csrf_token"]
        self.assertEqual(client.request("GET", "/api/status")[0].status, 200,
                         "this browser stays signed in")
        self.assertEqual(elsewhere.request("GET", "/api/status")[0].status, 401,
                         "another is signed out")
        self.assertEqual(Client(client.port).login()[0].status, 401)
        self.assertEqual(Client(client.port).login(new)[0].status, 200)

    def test_unexpected_failures_are_logged_but_not_described_to_the_client(self):
        client = self.serve()
        client.login()
        self.searches.broken = True
        with self.assertLogs("dccatlas.web", level="ERROR") as logs:
            response, body = client.request("GET", "/api/searches")
        self.assertEqual((response.status, body["error"]["code"]), (500, "internal_error"))
        self.assertNotIn("fixture defect", json.dumps(body))
        self.assertIn("GET /api/searches", logs.output[0])
        self.assertIn("fixture defect", logs.output[0])


@unittest.skipIf(uvicorn is None, "the web framework is not installed in this image")
class RuntimeTests(unittest.TestCase):
    def settings(self, password_file):
        from webapp.runtime import Settings

        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        return root, Settings(
            database=root / "config" / "fserve.sqlite3", socket_path=str(root / "absent.sock"),
            password_file=password_file and str(root / password_file), cookie_secure=False,
            allowed_hosts=("127.0.0.1",))

    def test_loopback_names_stay_allowed_for_the_health_check(self):
        from webapp.runtime import Settings

        with mock.patch.dict(os.environ, {"FSERVE_ALLOWED_HOSTS": " atlas.lan ,127.0.0.1,"}):
            hosts = Settings.from_environment().allowed_hosts
        self.assertEqual(hosts, ("localhost", "127.0.0.1", "atlas.lan"))
        with mock.patch.dict(os.environ):
            os.environ.pop("FSERVE_ALLOWED_HOSTS", None)
            self.assertEqual(Settings.from_environment().allowed_hosts,
                             ("localhost", "127.0.0.1"))

    def test_a_bad_replacement_password_keeps_the_old_one_and_says_so(self):
        from webapp.runtime import Runtime

        root, settings = self.settings("password")
        secret = root / "password"
        secret.write_text(PASSWORD + "\n", encoding="utf-8")
        self.assertIsNone(Runtime(settings).password_problem)
        secret.write_text("too-short\n", encoding="utf-8")
        restarted = Runtime(settings)
        self.assertIn("at least 12 characters", restarted.password_problem)
        self.assertTrue(restarted.auth.configured)
        restarted.auth.login(PASSWORD)
        secret.unlink()
        without_file = Runtime(settings)
        self.assertIsNone(without_file.password_problem)
        without_file.auth.login(PASSWORD)

    def test_a_repeating_engine_failure_is_logged_once_per_interval(self):
        from webapp.runtime import Runtime, UNREACHABLE_GRACE_SECONDS

        _root, settings = self.settings(None)
        runtime = Runtime(settings)
        with self.assertLogs("dccatlas.web", level="ERROR") as logs:
            runtime._report("the engine bridge is not reachable", OSError("refused"),
                            grace=UNREACHABLE_GRACE_SECONDS)
            for _ in range(3):
                runtime._report("the engine services could not start", RuntimeError("fixture"))
        self.assertEqual(len(logs.output), 1, logs.output)
        self.assertIn("could not start; retrying: RuntimeError: fixture", logs.output[0])


class AuthenticatorTests(unittest.TestCase):
    def make(self, clock):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        database = Path(directory.name) / "config" / "fserve.sqlite3"
        SourceConfigStore(database)
        return Authenticator(CredentialStore(database), clock=clock), Path(directory.name)

    def test_password_file_rotation_sessions_expiry_and_stored_verifier(self):
        now = [1000.0]
        auth, root = self.make(lambda: now[0])
        secret = root / "password"
        self.assertFalse(auth.apply_password_file(secret))
        self.assertFalse(auth.configured)
        for bad in (b"short\n", b"\xff" * 20, b"has\x07control-char\n", b"x" * 5000):
            secret.write_bytes(bad)
            with self.assertRaises(AuthError):
                read_password_file(secret)
        secret.write_bytes(b"\xef\xbb\xbf" + PASSWORD.encode() + b"\r\n")
        self.assertEqual(read_password_file(secret), PASSWORD,
                         "a byte-order mark is not part of the password")
        secret.write_text(PASSWORD + "\r\n", encoding="utf-8")
        self.assertTrue(auth.apply_password_file(secret))
        self.assertNotIn(PASSWORD.encode(), auth.store.path.read_bytes())

        token, session = auth.login(PASSWORD)
        self.assertIsNotNone(auth.session(token))
        self.assertTrue(auth.csrf_matches(session, session.csrf_token))
        self.assertFalse(auth.csrf_matches(session, None))
        self.assertFalse(auth.csrf_matches(session, session.csrf_token + "x"))
        self.assertIsNone(auth.session(token + "x"))
        self.assertIsNone(auth.session("x" * 500))

        auth.apply_password_file(secret)
        self.assertIsNotNone(auth.session(token), "an unchanged password keeps sessions")
        # A verifier stored with a lower scrypt cost is upgraded in place.
        with closing(sqlite3.connect(auth.store.path)) as connection, connection:
            salt = connection.execute("SELECT salt FROM auth_credential").fetchone()[0]
            weaker = hashlib.scrypt(PASSWORD.encode(), salt=salt, n=2 ** 15, r=8, p=1,
                                    maxmem=64 * 1024 * 1024, dklen=32)
            connection.execute("UPDATE auth_credential SET verifier=?, scrypt_p=1", (weaker,))
        self.assertTrue(auth.store.verify(PASSWORD))
        self.assertTrue(auth.store.outdated())
        auth.apply_password_file(secret)
        self.assertFalse(auth.store.outdated())
        self.assertIsNotNone(auth.session(token), "upgrading the verifier keeps sessions")
        secret.write_text("a-different-operator-password\n", encoding="utf-8")
        auth.apply_password_file(secret)
        self.assertIsNone(auth.session(token), "a rotated password signs everyone out")
        with self.assertRaises(AuthError):
            auth.login(PASSWORD)
        token, _ = auth.login("a-different-operator-password")

        now[0] += 11 * 60 * 60
        self.assertIsNotNone(auth.session(token))
        now[0] += 13 * 60 * 60
        self.assertIsNone(auth.session(token), "an idle session expires")
        token, _ = auth.login("a-different-operator-password")
        for _ in range(16):
            now[0] += 11 * 60 * 60
            auth.session(token)
        self.assertIsNone(auth.session(token), "a session has an absolute lifetime")

    def test_failed_logins_back_off_and_success_resets(self):
        now = [0.0]
        auth, root = self.make(lambda: now[0])
        auth.store.set_password(PASSWORD)
        for _ in range(FAILURES_BEFORE_DELAY):
            with self.assertRaises(AuthError) as failed:
                auth.login("wrong-password-value")
            self.assertEqual(failed.exception.code, "invalid_credentials")
        with self.assertRaises(AuthError) as delayed:
            auth.login(PASSWORD)
        self.assertEqual(delayed.exception.code, "login_delayed")
        now[0] += delayed.exception.retry_after + 1
        auth.login(PASSWORD)
        with self.assertRaises(AuthError) as failed:
            auth.login("wrong-password-value")
        self.assertEqual(failed.exception.code, "invalid_credentials")
        auth.login(PASSWORD)

    def test_setup_and_reset_codes(self):
        now = [0.0]
        auth, _root = self.make(lambda: now[0])
        with self.assertRaises(AuthError) as refused:
            auth.reset_code()
        self.assertEqual(refused.exception.code, "setup_required")
        code = auth.setup_code()
        self.assertIsNotNone(code)
        with self.assertRaises(AuthError) as wrong:
            auth.set_up("AAAA-BBBB-CCCC", PASSWORD)
        self.assertEqual(wrong.exception.code, "invalid_code")
        auth.set_up(code, PASSWORD)
        self.assertTrue(auth.configured)
        self.assertIsNone(auth.setup_code(), "no setup code once a password is set")
        with self.assertRaises(AuthError) as again:
            auth.set_up(code, "another-operator-password")
        self.assertEqual(again.exception.code, "already_set_up")

        token, _ = auth.login(PASSWORD)
        first = auth.reset_code()
        now[0] += RESET_CODE_INTERVAL_SECONDS + 1
        second = auth.reset_code()
        with self.assertRaises(AuthError):
            auth.reset(first, "replaced-operator-password")
        self.assertIsNotNone(auth.session(token), "a wrong code changes nothing")
        now[0] += RESET_CODE_SECONDS + 1
        with self.assertRaises(AuthError) as expired:
            auth.reset(second, "replaced-operator-password")
        self.assertEqual(expired.exception.code, "invalid_code", "a reset code expires")
        now[0] += 60 * 60   # past the delay the wrong codes earned
        third = auth.reset_code()
        auth.reset(third, "replaced-operator-password")
        self.assertIsNone(auth.session(token), "a reset signs everyone else out")
        with self.assertRaises(AuthError):
            auth.login(PASSWORD)
        auth.login("replaced-operator-password")

    def test_wrong_codes_share_the_login_delay(self):
        now = [0.0]
        auth, _root = self.make(lambda: now[0])
        auth.store.set_password(PASSWORD)
        auth.reset_code()
        for _ in range(FAILURES_BEFORE_DELAY):
            with self.assertRaises(AuthError):
                auth.reset("AAAA-BBBB-CCCC", "replaced-operator-password")
        with self.assertRaises(AuthError) as delayed:
            auth.login(PASSWORD)
        self.assertEqual(delayed.exception.code, "login_delayed")

    def test_a_password_file_is_adopted_only_when_new_or_changed(self):
        auth, root = self.make(time.monotonic)
        secret = root / "password"
        secret.write_text(PASSWORD + "\n", encoding="utf-8")
        auth.apply_password_file(secret)
        token, _ = auth.login(PASSWORD)
        # Changed on the page since; the same file at the next start keeps it.
        auth.store.set_password("changed-on-the-page")
        auth.apply_password_file(secret)
        self.assertTrue(auth.store.verify("changed-on-the-page"))
        self.assertIsNotNone(auth.session(token))
        secret.write_text("a-new-file-password\n", encoding="utf-8")
        auth.apply_password_file(secret)
        self.assertTrue(auth.store.verify("a-new-file-password"), "a changed file is adopted")
        self.assertIsNone(auth.session(token))

    def test_a_database_from_before_keeps_its_sessions_with_the_same_file(self):
        auth, root = self.make(time.monotonic)
        secret = root / "password"
        secret.write_text(PASSWORD + "\n", encoding="utf-8")
        auth.store.set_password(PASSWORD)   # set by the file, before files were remembered
        token, _ = auth.login(PASSWORD)
        auth.apply_password_file(secret)
        self.assertIsNotNone(auth.session(token))
        auth.store.set_password("changed-on-the-page")
        auth.apply_password_file(secret)
        self.assertTrue(auth.store.verify("changed-on-the-page"),
                        "the file is remembered from then on")


if __name__ == "__main__":
    unittest.main()
