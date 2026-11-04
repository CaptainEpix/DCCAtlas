"""Container-level checks for the DCCAtlas product image.

Run on the host, with Docker available and the image already built:

    python tools/container_check.py [--image dccatlas:dev]

Every container runs with networking disabled; HTTP requests are made from
inside the container. Nothing connects to IRC.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import secrets
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

IMAGE = "dccatlas:dev"
ROOT = Path(__file__).resolve().parents[1]
FIXTURE_CONTENT = b"web m1 native download fixture\x00bytes\n"
PREFIX = "dccatlas-check-"
PYTHON = "/opt/venv/bin/python"

# Runs inside the container: one JSON document of steps in, one of results out.
PROBE = r"""
import http.client, json, sys
request = json.load(sys.stdin)
cookie, csrf = request.get("cookie"), request.get("csrf")
results = []
for step in request["steps"]:
    connection = http.client.HTTPConnection("127.0.0.1", 8080, timeout=10)
    headers = {}
    body = None
    if step["method"] != "GET":
        headers["Content-Type"] = "application/json"
        body = json.dumps(step.get("body", {}))
        if csrf:
            headers["X-CSRF-Token"] = csrf
    if cookie:
        headers["Cookie"] = cookie
    try:
        connection.request(step["method"], step["path"], body=body, headers=headers)
        response = connection.getresponse()
        raw = response.read()
    except OSError as error:
        results.append({"status": 0, "body": repr(error)})
        continue
    finally:
        connection.close()
    for value in response.headers.get_all("set-cookie") or []:
        cookie = value.split(";", 1)[0]
    try:
        data = json.loads(raw)
    except ValueError:
        data = raw.decode("utf-8", "replace")[:200]
    if isinstance(data, dict) and data.get("csrf_token"):
        csrf = data["csrf_token"]
    results.append({"status": response.status, "body": data})
print(json.dumps({"cookie": cookie, "csrf": csrf, "results": results}))
"""


def docker(*arguments, check=True, input_text=None, timeout=120):
    result = subprocess.run(
        ["docker", *arguments], capture_output=True, text=True, encoding="utf-8",
        errors="replace", input=input_text, timeout=timeout)
    if check and result.returncode:
        raise AssertionError(
            f"docker {' '.join(arguments[:3])} failed: {result.stderr.strip()[-600:]}")
    return result


class ContainerChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        cls.password = secrets.token_urlsafe(18)
        cls.secret = Path(cls.scratch.name) / "password.txt"
        cls.secret.write_text(cls.password + "\n", encoding="utf-8", newline="\n")
        cls.suffix = secrets.token_hex(4)
        cls.created: list[str] = []
        cls.volumes: list[str] = []

    @classmethod
    def tearDownClass(cls):
        for name in cls.created:
            docker("rm", "-f", name, check=False)
        for name in cls.volumes:
            docker("volume", "rm", "-f", name, check=False)
        cls.scratch.cleanup()

    def start(self, label, *extra, secret=True, volumes=None):
        name = f"{PREFIX}{label}-{self.suffix}"
        docker("rm", "-f", name, check=False)
        arguments = ["run", "-d", "--name", name, "--network", "none", "--init",
                     "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true"]
        # As the compose file starts it, unless a test starts it otherwise.
        if "--user" not in extra:
            arguments += ["--user", "1000:1000"]
        if secret:
            arguments += ["--mount", f"type=bind,source={self.secret},"
                                     "target=/run/secrets/dccatlas_password,readonly"]
        for volume, target in (volumes or {}).items():
            arguments += ["--mount", f"type=volume,source={volume},target={target}"]
        docker(*arguments, *extra, IMAGE)
        if name not in self.created:
            self.created.append(name)
        return name

    def state(self, name):
        return json.loads(docker("inspect", name, "--format", "{{json .State}}").stdout)

    def probe(self, name, steps, session=None):
        """Run HTTP steps inside the container; `session` carries a login across calls."""
        session = session if session is not None else {}
        result = docker("exec", "-i", name, PYTHON, "-c", PROBE,
                        input_text=json.dumps({**session, "steps": steps}))
        answer = json.loads(result.stdout)
        session.update(cookie=answer["cookie"], csrf=answer["csrf"])
        return answer["results"]

    def poll(self, label, name, session, path, accept, timeout=60):
        deadline = time.monotonic() + timeout
        answer = None
        while time.monotonic() < deadline:
            answer = self.probe(name, [{"method": "GET", "path": path}], session)[0]
            if answer["status"] == 200 and accept(answer["body"]):
                return answer["body"]
            time.sleep(1)
        raise AssertionError(f"timed out waiting for {label}: {answer!r}")

    def start_fixture(self, name):
        docker("exec", "-d", name, PYTHON, "/project/tools/demo_fixture.py",
               "--port", "6667", "--status-file", "/tmp/fixture.json")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if docker("exec", name, "test", "-f", "/tmp/fixture.json", check=False).returncode == 0:
                return
            time.sleep(.5)
        raise AssertionError("the loopback fixture did not start")

    def fixture_status(self, name):
        return json.loads(docker("exec", name, "cat", "/tmp/fixture.json").stdout)

    def wait_serving(self, name, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not self.state(name)["Running"]:
                raise AssertionError(f"{name} exited early: {docker('logs', name).stdout[-600:]}")
            answer = self.probe(name, [{"method": "GET", "path": "/healthz"}])[0]
            if answer["status"] == 200:
                return
            time.sleep(1)
        raise AssertionError(f"{name} did not start serving")

    def wait_exit(self, name, timeout=40):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = self.state(name)
            if not state["Running"]:
                return state
            time.sleep(.5)
        raise AssertionError(f"{name} did not exit")

    def login_steps(self):
        return [{"method": "POST", "path": "/api/login", "body": {"password": self.password}}]

    def test_non_root_private_files_persistence_and_graceful_stop(self):
        volumes = {f"{PREFIX}config-{self.suffix}": "/config",
                   f"{PREFIX}downloads-{self.suffix}": "/downloads"}
        self.volumes.extend(volumes)
        name = self.start("main", volumes=volumes)
        self.wait_serving(name)

        self.assertEqual(docker("exec", name, "id", "-u").stdout.strip(), "1000")
        owners = docker("exec", name, "sh", "-c",
                        "for p in /proc/[0-9]*; do stat -c %u $p; done | sort -u").stdout.split()
        self.assertEqual(owners, ["1000"], "no process in the container runs as root")
        modes = docker(
            "exec", name, "stat", "-c", "%a %n", "/config/fserve", "/config/fserve/fserve.sqlite3",
            "/config/irssi", "/config/irssi/config", "/config/irssi/fserve-poc/engine.sock",
        ).stdout.split("\n")
        self.assertEqual([line.split()[0] for line in modes if line],
                         ["700", "600", "700", "600", "600"], modes)

        source = {"label": "Persisted", "host": "127.0.0.1", "port": 6667, "tls": False,
                  "nickname": "Keeper", "channel": "#kept"}
        unauthenticated, wrong = self.probe(name, [
            {"method": "GET", "path": "/api/status"},
            {"method": "POST", "path": "/api/login", "body": {"password": "not-the-password"}},
        ])
        self.assertEqual((unauthenticated["status"], wrong["status"]), (401, 401))
        login, saved, status = self.probe(name, self.login_steps() + [
            {"method": "PUT", "path": "/api/source", "body": source},
            {"method": "GET", "path": "/api/status"},
        ])
        self.assertEqual((login["status"], saved["status"], status["status"]), (200, 200, 200))
        self.assertTrue(status["body"]["engine_available"])
        self.assertTrue(status["body"]["journal_ready"])
        self.assertIn(status["body"]["source"]["state"], ("configured", "disconnected"))
        self.assertNotIn(self.password, docker("logs", name).stdout + docker("logs", name).stderr)
        leak = docker(
            "exec", name, "sh", "-c",
            "grep -q -a -r -F -f /run/secrets/dccatlas_password /config && echo leak || echo clean")
        self.assertEqual(leak.stdout.strip(), "clean", "the password is not stored anywhere")

        started = time.monotonic()
        docker("stop", "-t", "30", name)
        self.assertLess(time.monotonic() - started, 20, "SIGTERM stops both processes promptly")
        self.assertEqual(self.state(name)["ExitCode"], 0)
        docker("rm", name)

        name = self.start("main", volumes=volumes)
        self.wait_serving(name)
        login, status = self.probe(name, self.login_steps() + [
            {"method": "GET", "path": "/api/status"}])
        self.assertEqual(status["status"], 200)
        configuration = status["body"]["configuration"]
        self.assertEqual({key: configuration[key] for key in source}, source)
        self.assertEqual(configuration["revision"], 1)
        self.assertIn(status["body"]["source"]["state"], ("configured", "disconnected"),
                      "a recreated container restores settings but never connects")
        self.assertFalse(status["body"]["source"]["connected"])

    def test_browser_api_flow_in_the_container_survives_recreation(self):
        """The W6 demonstration, driven over HTTP inside the product container."""
        volumes = {f"{PREFIX}flow-config-{self.suffix}": "/config",
                   f"{PREFIX}flow-downloads-{self.suffix}": "/downloads"}
        self.volumes.extend(volumes)
        project = ["--mount", f"type=bind,source={ROOT},target=/project,readonly"]
        name = self.start("flow", *project, volumes=volumes)
        self.wait_serving(name)
        self.start_fixture(name)

        session = {}
        source = {"label": "Loopback", "host": "127.0.0.1", "port": 6667, "tls": False,
                  "nickname": "FlowNick", "channel": "#review"}
        login, saved, connected = self.probe(name, self.login_steps() + [
            {"method": "PUT", "path": "/api/source", "body": source},
            {"method": "POST", "path": "/api/source/connect"},
        ], session)
        self.assertEqual((login["status"], saved["status"], connected["status"]),
                         (200, 200, 200), connected)
        self.poll("ready source", name, session, "/api/status",
                  lambda body: body["source"] and body["source"]["state"] == "ready")

        search = self.probe(name, [
            {"method": "POST", "path": "/api/searches", "body": {"terms": "fixture"}}],
            session)[0]
        self.assertEqual(search["status"], 200, search)
        search_path = "/api/searches/" + search["body"]["search_id"]
        self.poll("complete search", name, session, search_path,
                  lambda body: body["state"] == "complete")
        page = self.poll("selectable result", name, session, search_path + "/results",
                         lambda body: body["results"] and body["results"][0]["result_id"])
        result = page["results"][0]
        self.assertEqual((result["sender"], result["path"], result["size_bytes_exact"]),
                         ("Fixture", "/books/fixture.txt", len(FIXTURE_CONTENT)))
        self.assertEqual(result["provenance"]["channel"], "#review")

        order = {"idempotency_key": "container-flow-key-0001", "result_id": result["result_id"]}
        first, repeated = self.probe(name, [
            {"method": "POST", "path": "/api/downloads", "body": order},
            {"method": "POST", "path": "/api/downloads", "body": order},
        ], session)
        self.assertEqual((first["status"], repeated["status"]), (200, 200), repeated)
        self.assertEqual(first["body"]["operation_id"], repeated["body"]["operation_id"])
        operation_path = "/api/downloads/" + first["body"]["operation_id"]
        complete = self.poll("complete download", name, session, operation_path,
                             lambda body: body["state"] == "complete")
        self.assertTrue(complete["download_path"].startswith("127.0.0.1/"), complete)
        digest = docker("exec", name, "sha256sum",
                        "/downloads/" + complete["download_path"]).stdout.split()[0]
        self.assertEqual(digest, hashlib.sha256(FIXTURE_CONTENT).hexdigest())
        # The folder is the operator's to share (2026-10-28): with the usual
        # umask, the file is 644 and every folder on its way 755.
        modes = docker("exec", name, "sh", "-c",
                       "f=/downloads/" + shlex.quote(complete["download_path"]) + "; "
                       "while [ \"$f\" != /downloads ]; do stat -c '%a %F' \"$f\"; "
                       "f=$(dirname \"$f\"); done").stdout.split("\n")
        self.assertEqual(sorted({line for line in modes if line}),
                         ["644 regular file", "755 directory"], modes)
        counters = self.fixture_status(name)
        self.assertEqual(
            (counters["find"], counters["trigger"], counters["chat"], counters["get"]),
            (1, 1, 1, 1), counters)
        self.assertEqual([command.lower() for command in counters["chat_commands"][:3]],
                         ["cd books", "dir", "get fixture.txt"])
        self.assertFalse(counters["errors"], counters)

        docker("stop", "-t", "30", name)
        self.assertEqual(self.state(name)["ExitCode"], 0)
        docker("rm", name)
        name = self.start("flow", *project, volumes=volumes)
        self.wait_serving(name)
        self.start_fixture(name)

        session = {}
        login, status, downloads, searches, old_page, stale = self.probe(
            name, self.login_steps() + [
                {"method": "GET", "path": "/api/status"},
                {"method": "GET", "path": "/api/downloads"},
                {"method": "GET", "path": "/api/searches"},
                {"method": "GET", "path": search_path + "/results"},
                {"method": "POST", "path": "/api/downloads", "body": {
                    "idempotency_key": "container-flow-key-0002",
                    "result_id": result["result_id"]}},
            ], session)
        self.assertEqual(status["body"]["configuration"]["nickname"], "FlowNick")
        self.assertFalse(status["body"]["source"]["connected"])
        history = downloads["body"]["downloads"]
        self.assertEqual([(row["operation_id"], row["state"]) for row in history],
                         [(first["body"]["operation_id"], "complete")])
        self.assertTrue(searches["body"]["searches"][0]["historical"])
        self.assertIsNone(old_page["body"]["results"][0]["result_id"])
        self.assertEqual((stale["status"], stale["body"]["error"]["code"]),
                         (409, "stale_result"))
        digest = docker("exec", name, "sha256sum",
                        "/downloads/" + complete["download_path"]).stdout.split()[0]
        self.assertEqual(digest, hashlib.sha256(FIXTURE_CONTENT).hexdigest())
        time.sleep(5)
        counters = self.fixture_status(name)
        self.assertEqual(
            (counters["connections"], counters["find"], counters["trigger"], counters["get"]),
            (0, 0, 0, 0), "a recreated container sends nothing to IRC on its own")

    def test_either_process_dying_stops_the_whole_container(self):
        for label, pattern in (("engine-loss", "irssi"), ("web-loss", "webapp")):
            name = self.start(label)
            self.wait_serving(name)
            docker("exec", name, "sh", "-c",
                   f"for p in /proc/[0-9]*; do if tr '\\0' ' ' < $p/cmdline | "
                   f"grep -q -- '{pattern}' && [ ${{p#/proc/}} != $$ ]; "
                   f"then kill -9 ${{p#/proc/}}; fi; done; true")
            state = self.wait_exit(name)
            self.assertNotEqual(state["ExitCode"], 0, label)
            self.assertIn("exited with status", docker("logs", name).stdout)

    def test_missing_password_reports_setup_and_stays_alive(self):
        name = self.start("no-secret", secret=False)
        self.wait_serving(name)
        session, login = self.probe(name, [
            {"method": "GET", "path": "/api/session"},
            {"method": "POST", "path": "/api/login", "body": {"password": "anything-at-all"}},
        ])
        self.assertTrue(session["body"]["setup_required"])
        self.assertEqual((login["status"], login["body"]["error"]["code"]),
                         (503, "setup_required"))
        self.assertTrue(self.state(name)["Running"])

    def test_health_check_follows_the_port_and_a_lan_only_host_list(self):
        # The image's own health command, run sooner than its 30 s default.
        name = self.start(
            "health", "-e", "FSERVE_HTTP_PORT=9090", "-e", "FSERVE_ALLOWED_HOSTS=atlas.lan",
            "--health-interval", "2s", "--health-start-period", "1s", "--health-retries", "2")
        deadline = time.monotonic() + 90
        status = None
        while time.monotonic() < deadline:
            status = (self.state(name).get("Health") or {}).get("Status")
            if status == "healthy":
                break
            time.sleep(1)
        self.assertEqual(status, "healthy", docker("logs", name).stdout[-600:])

    def test_started_as_root_it_hands_its_volumes_to_puid_and_drops_to_it(self):
        """As unRAID starts it: root, PUID 99 and PGID 100 (nobody:users)."""
        volumes = {f"{PREFIX}root-config-{self.suffix}": "/config",
                   f"{PREFIX}root-downloads-{self.suffix}": "/downloads"}
        self.volumes.extend(volumes)
        # Docker's default capabilities include these four; the other tests
        # drop them all.
        name = self.start("root", "--user", "0:0", "-e", "PUID=99", "-e", "PGID=100",
                          "--cap-add", "CHOWN", "--cap-add", "DAC_OVERRIDE",
                          "--cap-add", "SETUID", "--cap-add", "SETGID", volumes=volumes)
        self.wait_serving(name)
        # Every process but the init (PID 1, which only reaps) is nobody:users.
        owners = docker("exec", "--user", "99:100", name, "sh", "-c",
                        "for p in /proc/[0-9]*; do [ ${p#/proc/} = 1 ] || "
                        "stat -c '%u:%g' $p; done | sort -u").stdout.split()
        self.assertEqual(owners, ["99:100"], owners)
        files = docker("exec", "--user", "99:100", name, "sh", "-c",
                       "find /config /downloads -maxdepth 3 ! -user 99 | head").stdout.strip()
        self.assertEqual(files, "", "everything in the volumes belongs to PUID")
        self.assertIn("running as user 99, group 100", docker("logs", name).stdout)

    def test_puid_zero_is_refused(self):
        name = self.start("puid-zero", "--user", "0:0", "-e", "PUID=0",
                          "--cap-add", "CHOWN", "--cap-add", "SETUID", "--cap-add", "SETGID")
        state = self.wait_exit(name)
        self.assertNotEqual(state["ExitCode"], 0)
        logs = docker("logs", name)
        self.assertIn("does not run as root", logs.stdout + logs.stderr)

    def test_unwritable_config_volume_fails_with_a_clear_message(self):
        name = self.start("read-only", "--tmpfs", "/config:uid=0,gid=0,mode=755")
        state = self.wait_exit(name)
        self.assertNotEqual(state["ExitCode"], 0)
        logs = docker("logs", name)
        self.assertIn("/config must be a directory writable by uid 1000",
                      logs.stdout + logs.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default=IMAGE)
    options, remaining = parser.parse_known_args()
    IMAGE = options.image
    unittest.main(argv=[sys.argv[0], *remaining])
