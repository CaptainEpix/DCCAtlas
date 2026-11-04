"""A source's login against real services: Ergo's NickServ and SASL (2026-10-27).

The other login tests use a loopback stand-in. This one needs a running Ergo
IRC server (https://github.com/ergochat/ergo, which has NickServ and SASL
built in) and is skipped without it: tools/ergo_check.sh starts one on an
internal Docker network and runs this test beside it, so nothing reaches any
other network. An account is registered with NickServ first; then the app
logs in to it by NickServ IDENTIFY and by SASL, and with a wrong password
each way, and a second client asks the server who is logged in.

Since 2026-10-27 the app also logs in with a client certificate it made
(SASL EXTERNAL), over TLS to Ergo's port 6697, once the account has the
certificate's SHA-256 fingerprint (NickServ CERT ADD); and a certificate on no
account is refused. The server's own certificate is signed by a CA made for
the run, which the check script makes Irssi trust (SSL_CERT_FILE), so the app
verifies the server as it always does.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
import secrets
import socket
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from webapp.engine_client import EngineClient
from webapp.sources import SourceService

try:
    from web_bridge_test import NativeIrssi
    from web_login_test import leaks
except ImportError:   # the native helpers need a POSIX pty
    NativeIrssi = leaks = None

HOST = os.environ.get("FSERVE_ERGO_HOST")
# The name Ergo's TLS certificate is for; set when the check script made one.
TLS_HOST = os.environ.get("FSERVE_ERGO_TLS_HOST")
ACCOUNT = "AtlasLogin"
# Made for this run only; never stored outside the test's own database.
PASSWORD = "pw-" + secrets.token_hex(12)
CHANNEL = "#logintest"


class RawClient:
    """A plain IRC client, to register the account and ask who is logged in."""

    def __init__(self, nick: str):
        self.sock = socket.create_connection((HOST, 6667), timeout=10)
        self.buffer = b""
        self.seen: list[str] = []
        self.nick = nick
        self.send(f"NICK {nick}")
        self.send(f"USER {nick.lower()} 0 * :login test")
        self.wait(lambda line: f" 001 {nick} " in line)

    def send(self, line: str):
        self.sock.sendall(line.encode() + b"\r\n")

    def wait(self, predicate, timeout: float = 15) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\r\n" in self.buffer:
                raw, self.buffer = self.buffer.split(b"\r\n", 1)
                line = raw.decode(errors="replace")
                self.seen.append(line)
                if line.startswith("PING "):
                    self.send("PONG " + line[5:])
                    continue
                if predicate(line):
                    return line
            self.sock.settimeout(max(.1, deadline - time.monotonic()))
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            self.buffer += chunk
        raise AssertionError(f"{self.nick}: timed out; last lines: {self.seen[-8:]!r}")

    def account_of(self, nick: str) -> str | None:
        """The account the server says nick is logged in to, from WHOIS (330)."""
        self.send(f"WHOIS {nick}")
        found = None
        while True:
            line = self.wait(lambda line: f" 330 {self.nick} {nick} " in line
                             or f" 318 {self.nick} {nick} " in line)
            if " 330 " in line:
                found = line.split()[4]
            else:
                return found

    def close(self):
        try:
            self.send("QUIT :done")
        finally:
            self.sock.close()


def register_account():
    client = RawClient(ACCOUNT)
    try:
        client.send(f"PRIVMSG NickServ :REGISTER {PASSWORD}")
        client.wait(lambda line: "NickServ" in line and "Account created" in line)
    finally:
        client.close()


def add_certificate(fingerprint: str) -> str:
    """Add a fingerprint to the account, as its owner would; NickServ's answer."""
    client = RawClient("AtlasOwner")
    try:
        client.send(f"PRIVMSG NickServ :IDENTIFY {ACCOUNT} {PASSWORD}")
        client.wait(lambda line: line.startswith(":NickServ!") and "now logged in" in line)
        client.send(f"PRIVMSG NickServ :CERT ADD {fingerprint}")
        return client.wait(lambda line: line.startswith(":NickServ!"))
    finally:
        client.close()


def leaks_outside_engine_certificates(native, directory, database, secret, replies):
    """As leaks(), except the engine's certificate file, which Irssi must read."""
    return [place for place in leaks(native, directory, database, secret, replies)
            if "fserve-poc/certificates/" not in place.replace("\\", "/")]


def setUpModule():
    if HOST is not None and NativeIrssi is not None:
        register_account()


class ErgoLogins:
    """Connects a source with a login, and asks a watching client about it."""

    watcher_nick = "Watcher"

    @classmethod
    def setUpClass(cls):
        cls.watcher = RawClient(cls.watcher_nick)

    @classmethod
    def tearDownClass(cls):
        cls.watcher.close()

    def log_in(self, nickname: str, login: dict, secret: str | None, *, tls: bool = False,
               before_connect=None):
        """Connect a source with the login; return its state, view, leaks and account.

        before_connect, if given, is called with the reply to the login.
        With no secret, the private key of the certificate made is one.
        """
        with NativeIrssi() as native:
            async def workflow():
                engine = await EngineClient.open(str(native.path))
                try:
                    with tempfile.TemporaryDirectory() as name:
                        directory = Path(name)
                        database = directory / "fserve.sqlite3"
                        sources = SourceService(database, engine)
                        await sources.save(dict(label="Ergo", provider="sysreset_find",
                                                host=TLS_HOST if tls else HOST,
                                                port=6697 if tls else 6667, tls=tls,
                                                nickname=nickname, channel=CHANNEL))
                        replies = [await sources.set_login("primary", login)]
                        found_in, needle = leaks, secret
                        if secret is None:
                            # A line from the middle of the key made for the source.
                            pem = sources.logins.get(sources.store.get("primary"))["certificate"]
                            needle = pem.split("PRIVATE KEY-----\n")[1].split("\n")[5]
                            found_in = leaks_outside_engine_certificates
                        if before_connect:
                            before_connect(replies[0])
                        await sources.connect()
                        state = view = None
                        deadline = time.monotonic() + 30
                        while time.monotonic() < deadline:
                            status = await engine.status()
                            replies.append(status)
                            view = sources.engine_source(status, "primary")
                            state = view and view["state"]
                            if state in ("ready", "failed", "disconnected"):
                                break
                            await asyncio.sleep(.1)
                        account = (self.watcher.account_of(view["current_nick"] or nickname)
                                   if state == "ready" else None)
                        log = await engine.request("log.list", {"after": 0, "limit": 200})
                        replies.append(log)
                        found = found_in(native, directory, database, needle, replies)
                        if state == "ready":
                            await sources.disconnect()
                        return state, view, found, account, log
                finally:
                    await engine.close()

            return asyncio.run(workflow())

    def log_text(self, log) -> str:
        return "\n".join(str(line.get("text", "")) for line in log.get("lines", []))


@unittest.skipIf(HOST is None or NativeIrssi is None,
                 "needs a running Ergo server (tools/ergo_check.sh)")
class ErgoLoginTests(ErgoLogins, unittest.TestCase):
    def test_1_nickserv_identify_logs_in(self):
        state, view, found, account, log = self.log_in(
            ACCOUNT, {"kind": "nickserv", "username": ACCOUNT, "password": PASSWORD}, PASSWORD)
        self.assertEqual(state, "ready", view)
        self.assertEqual(account, ACCOUNT, "Ergo says the nick is logged in to the account")
        self.assertEqual(found, [], "the password was found outside its own table")

    def test_2_a_wrong_nickserv_password_is_said_and_not_tried_again(self):
        wrong = "wrong-" + secrets.token_hex(6)
        state, view, found, account, log = self.log_in(
            "AtlasWrong", {"kind": "nickserv", "username": ACCOUNT, "password": wrong}, wrong)
        self.assertEqual(state, "ready", "a refused IDENTIFY leaves the connection up")
        self.assertIsNone(account, "and not logged in")
        text = self.log_text(log)
        self.assertEqual(text.count("Identifying to NickServ"), 1, text)
        self.assertRegex(text, r"(?i)nickserv.*(invalid|incorrect|failed)", text)
        self.assertEqual(found, [])

    def test_3_sasl_logs_in_before_the_join(self):
        state, view, found, account, log = self.log_in(
            "AtlasSasl", {"kind": "sasl_plain", "username": ACCOUNT, "password": PASSWORD},
            PASSWORD)
        self.assertEqual(state, "ready", view)
        self.assertEqual(account, ACCOUNT)
        self.assertEqual(found, [])

    def test_4_a_wrong_sasl_password_ends_the_connection(self):
        wrong = "wrong-" + secrets.token_hex(6)
        state, view, found, account, log = self.log_in(
            "AtlasSaslWrong", {"kind": "sasl_plain", "username": ACCOUNT, "password": wrong},
            wrong)
        self.assertNotEqual(state, "ready", view)
        self.assertIn("login refused", view["reason"] or "", view)
        self.assertEqual(found, [])


@unittest.skipIf(HOST is None or TLS_HOST is None or NativeIrssi is None,
                 "needs a running Ergo server with a test certificate (tools/ergo_check.sh)")
class ErgoCertificateLoginTests(ErgoLogins, unittest.TestCase):
    watcher_nick = "CertWatcher"

    def test_certificate_1_logs_in_once_the_account_has_it(self):
        answers = []

        def add(reply):
            answers.append(add_certificate(reply["login"]["sha256"]))

        state, view, found, account, log = self.log_in(
            "AtlasCert", {"kind": "certificate"}, None, tls=True, before_connect=add)
        self.assertRegex(answers[0], r"(?i)added", answers)
        self.assertEqual(state, "ready", view)
        self.assertEqual(account, ACCOUNT, "Ergo says the nick is logged in to the account")
        self.assertIn("with a client certificate (SASL EXTERNAL)", self.log_text(log))
        self.assertEqual(found, [], "the key was found outside its own table and file")

    def test_certificate_2_one_on_no_account_is_refused(self):
        state, view, found, account, log = self.log_in(
            "AtlasCertNone", {"kind": "certificate"}, None, tls=True)
        self.assertNotEqual(state, "ready", view)
        self.assertIn("login refused", view["reason"] or "", view)
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
