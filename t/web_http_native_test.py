"""Native W5 check: the HTTP API drives one search and download end to end.

Real web service, real bridge, native Irssi, and the generated loopback
IRC/Find/FServe/DCC fixture. Nothing leaves the container's loopback.
"""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from web_api_test import PASSWORD, Client, uvicorn
from web_download_native_test import CONTENT, FILENAME, DownloadFixture, RestartableIrssi
from web_source_test import source_values


def poll(label, action, accept, timeout=30):
    deadline = time.monotonic() + timeout
    value = None
    while time.monotonic() < deadline:
        value = action()
        if accept(value):
            return value
        time.sleep(.3)
    raise AssertionError(f"timed out waiting for {label}: {value!r}")


@unittest.skipIf(uvicorn is None, "the web framework is not installed in this image")
class WebHttpNativeTests(unittest.TestCase):
    def test_http_api_runs_one_search_and_download_then_survives_a_service_restart(self):
        from webapp.__main__ import server_config
        from webapp.runtime import Runtime, Settings

        fixture = DownloadFixture()
        fixture.start()
        self.addCleanup(fixture.stop)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "password").write_text(PASSWORD + "\n", encoding="utf-8")

        def serve(native):
            runtime = Runtime(Settings(
                database=root / "config" / "fserve.sqlite3", socket_path=str(native.path),
                password_file=str(root / "password"), cookie_secure=False,
                allowed_hosts=("127.0.0.1",),
            ))
            server = uvicorn.Server(server_config(runtime, "127.0.0.1", 0))
            thread = threading.Thread(target=server.run, daemon=True)
            thread.start()
            poll("HTTP server start", lambda: server.started, bool, timeout=10)

            def stop():
                server.should_exit = True
                thread.join(timeout=10)

            client = Client(server.servers[0].sockets[0].getsockname()[1])
            self.assertEqual(client.login()[0].status, 200)
            poll("engine connection", lambda: client.request("GET", "/api/status")[1],
                 lambda status: status.get("engine_available"))
            return client, stop

        def get(client, path):
            response, body = client.request("GET", path)
            self.assertEqual(response.status, 200, body)
            return body

        with RestartableIrssi() as native:
            native.command("/set fscrawl_find_quiet_ms 250")
            native.command("/set dcc_autoget OFF")
            client, stop = serve(native)
            try:
                values = source_values(fixture.port)
                values.pop("provider")
                response, saved = client.request("PUT", "/api/source", values)
                self.assertEqual(response.status, 200, saved)
                self.assertEqual(saved["configuration"]["channel"], "#review")
                self.assertIn(saved["source"]["state"], ("configured", "disconnected"))
                self.assertEqual(fixture.accept_count, 0, "saving settings must not connect")

                response, body = client.request("POST", "/api/source/connect")
                self.assertEqual(response.status, 200, body)
                poll("ready source", lambda: get(client, "/api/status"),
                     lambda status: status["source"]["state"] == "ready")

                response, search = client.request("POST", "/api/searches", {"terms": "fixture"})
                self.assertEqual(response.status, 200, search)
                search_path = "/api/searches/" + search["search_id"]
                poll("complete search", lambda: get(client, search_path),
                     lambda summary: summary["state"] == "complete")
                page = poll("selectable result", lambda: get(client, search_path + "/results"),
                            lambda data: data["results"] and data["results"][0]["result_id"])
                result = page["results"][0]
                self.assertEqual((result["sender"], result["path"], result["size_bytes_exact"]),
                                 ("Fixture", "/books/" + FILENAME, len(CONTENT)))
                self.assertNotIn("sel-", str(page), "engine selection tokens stay private")

                request = {"idempotency_key": "http-native-key-0001",
                           "result_id": result["result_id"]}
                response, started = client.request("POST", "/api/downloads", request)
                self.assertEqual(response.status, 200, started)
                response, repeated = client.request("POST", "/api/downloads", request)
                self.assertEqual(response.status, 200, repeated)
                self.assertEqual(repeated["operation_id"], started["operation_id"])
                self.assertEqual(repeated["job_id"], started["job_id"])
                response, busy = client.request("POST", "/api/downloads", {
                    "idempotency_key": "http-native-key-0002", "result_id": result["result_id"]})
                self.assertEqual((response.status, busy["error"]["code"]), (409, "download_busy"))

                operation_path = "/api/downloads/" + started["operation_id"]
                complete = poll("complete download", lambda: get(client, operation_path),
                                lambda row: row["state"] == "complete")
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertIsNone(complete["abandon_confirmation"])
                history = get(client, "/api/downloads")["downloads"]
                self.assertEqual([row["operation_id"] for row in history],
                                 [started["operation_id"]])
            finally:
                stop()

            # A restarted web service keeps settings and history, signs the
            # operator out, and sends nothing to IRC on its own.
            client, stop = serve(native)
            try:
                status = get(client, "/api/status")
                self.assertEqual(status["configuration"]["channel"], "#review")
                history = get(client, "/api/downloads")["downloads"]
                self.assertEqual((history[0]["state"], history[0]["operation_id"]),
                                 ("complete", started["operation_id"]))
                searches = get(client, "/api/searches")["searches"]
                self.assertEqual(len(searches), 1)
                self.assertTrue(searches[0]["historical"])
                old_page = get(client, search_path + "/results")
                self.assertIsNone(old_page["results"][0]["result_id"])
                response, stale = client.request("POST", "/api/downloads", {
                    "idempotency_key": "http-native-key-0003", "result_id": result["result_id"]})
                self.assertEqual((response.status, stale["error"]["code"]), (409, "stale_result"))

                response, body = client.request("POST", "/api/source/disconnect")
                self.assertEqual(response.status, 200, body)
                poll("disconnected source", lambda: get(client, "/api/status"),
                     lambda status: status["source"]["state"] == "disconnected")
            finally:
                stop()

        self.assertEqual(
            (fixture.find_count, fixture.trigger_count,
             fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))
        self.assertFalse(fixture.errors, fixture.errors)


if __name__ == "__main__":
    unittest.main()
