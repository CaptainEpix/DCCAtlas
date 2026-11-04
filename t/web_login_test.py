"""A source's login (web M3, Y2): a server password, a SASL PLAIN account, a
NickServ password, or a client certificate the app makes (SASL EXTERNAL)."""

from __future__ import annotations

import asyncio
import base64
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from webapp.engine_client import EngineClient, EngineRequestError
from webapp.logins import LoginStore, fingerprints_of, login_view, validate_login
from webapp.sources import SourceConfig, SourceService, SourceValidationError, is_local_server


def source_values(port: int = 6697, **overrides):
    values = dict(label="Net", provider="sysreset_find", host="irc.example.net",
                  port=port, tls=True, nickname="LoginTest", channel="#review")
    values.update(overrides)
    return values


def config(**overrides) -> SourceConfig:
    values = dict(source_id="primary", revision=1, label="Net", provider="sysreset_find",
                  host="irc.example.net", port=6697, tls=True, nickname="LoginTest",
                  channel="#review", updated_at=0.0)
    values.update(overrides)
    return SourceConfig(**values)


class LoginValidationTests(unittest.TestCase):
    def test_what_is_accepted(self):
        self.assertEqual(validate_login(config(), {"kind": "server_password", "password": "a$b\\c\"d"}),
                         {"kind": "server_password", "password": "a$b\\c\"d"})
        self.assertEqual(validate_login(config(), {"kind": "sasl_plain", "username": "me",
                                                   "password": "with spaces"}),
                         {"kind": "sasl_plain", "username": "me", "password": "with spaces"})
        # A private-network server without TLS, such as a lab's.
        self.assertTrue(validate_login(config(host="10.20.30.40", tls=False),
                                       {"kind": "server_password", "password": "x"}))
        # NickServ, with or without an account name other than the nick.
        self.assertEqual(validate_login(config(), {"kind": "nickserv", "password": "p@ss"}),
                         {"kind": "nickserv", "password": "p@ss"})
        self.assertEqual(validate_login(config(), {"kind": "nickserv", "username": "Acct",
                                                   "password": "p@ss"}),
                         {"kind": "nickserv", "username": "Acct", "password": "p@ss"})

    def test_what_is_refused(self):
        refused = [
            (config(tls=False), {"kind": "server_password", "password": "x"}, "plain text"),
            (config(), {"kind": "other", "password": "x"}, "kind"),
            (config(), {"kind": "server_password"}, "takes only"),
            (config(), {"kind": "server_password", "password": "x", "username": "u"}, "takes only"),
            (config(), {"kind": "sasl_plain", "password": "x"}, "takes only"),
            (config(), {"kind": "server_password", "password": ""}, "1 to 128"),
            (config(), {"kind": "server_password", "password": "x" * 129}, "1 to 128"),
            (config(), {"kind": "server_password", "password": "café"}, "ASCII"),
            (config(), {"kind": "server_password", "password": "a\tb"}, "ASCII"),
            (config(), {"kind": "server_password", "password": "two words"}, "space"),
            (config(), {"kind": "server_password", "password": ":x"}, "colon"),
            # Irssi's CONNECT reads "-" as no password at all.
            (config(), {"kind": "server_password", "password": "-"}, '"-"'),
            (config(), {"kind": "sasl_plain", "username": "a b", "password": "x"}, "account name"),
            (config(), {"kind": "sasl_plain", "username": "", "password": "x"}, "account name"),
            (config(tls=False), {"kind": "nickserv", "password": "x"}, "plain text"),
            (config(), {"kind": "nickserv", "password": "two words"}, "space"),
            (config(), {"kind": "nickserv", "username": "a b", "password": "x"}, "account name"),
            (config(), "not an object", "object"),
            # Only inside TLS is a certificate presented, on a lab's network too.
            (config(tls=False), {"kind": "certificate"}, "only presented over TLS"),
            (config(host="10.20.30.40", tls=False), {"kind": "certificate"},
             "only presented over TLS"),
            # The app makes it; none is taken from outside.
            (config(), {"kind": "certificate", "password": "x"}, "nothing but its kind"),
        ]
        for source, values, words in refused:
            with self.subTest(values=values):
                with self.assertRaises(SourceValidationError) as raised:
                    validate_login(source, values)
                self.assertIn(words, str(raised.exception))

    def test_only_private_network_addresses_count_as_local(self):
        local = ["localhost", "lab.localhost", "127.0.0.1", "10.20.30.40", "172.16.0.9",
                 "192.168.7.7", "169.254.1.1", "::1", "fd12:3456::1", "fe80::1",
                 "::ffff:10.20.30.40"]
        public = ["irc.example.net", "203.0.113.9", "100.64.0.1", "172.32.0.1",
                  # Teredo, 6to4, NAT64 and the documentation range: Python
                  # 3.13's is_private counts them, but none is a local server.
                  "2001:0:4136:e378:8000:63bf:3fff:fdd2", "2002:cb00:7109::1",
                  "64:ff9b:1::cb00:7109", "::ffff:203.0.113.9", "2001:db8::1"]
        for host in local:
            with self.subTest(host=host):
                self.assertTrue(is_local_server(host))
        for host in public:
            with self.subTest(host=host):
                self.assertFalse(is_local_server(host))
                with self.assertRaises(SourceValidationError):
                    validate_login(config(host=host, tls=False),
                                   {"kind": "server_password", "password": "x"})

    def test_the_view_never_has_the_password(self):
        self.assertEqual(login_view({"kind": "sasl_plain", "username": "me", "password": "p"}),
                         {"kind": "sasl_plain", "username": "me"})
        self.assertEqual(login_view({"kind": "server_password", "password": "p"}),
                         {"kind": "server_password"})
        self.assertIsNone(login_view(None))
        self.assertEqual(login_view({"kind": "certificate", "certificate": "PEM",
                                     "sha256": "ab", "sha512": "cd"}),
                         {"kind": "certificate", "sha256": "ab", "sha512": "cd"})


class FakeEngine:
    def __init__(self):
        self.requests: list[tuple[str, dict]] = []
        self.refuse_configure = None   # run, then refuse, the next source.configure

    async def request(self, operation, arguments=None, *, operation_id=None, timeout=10.0):
        self.requests.append((operation, dict(arguments or {})))
        if operation == "source.configure" and self.refuse_configure:
            during, self.refuse_configure = self.refuse_configure, None
            await during()
            raise EngineRequestError("invalid_arguments", "fixture refusal")
        return {"source": {}}

    async def status(self):
        return {"sources": []}


class LoginServiceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.database = Path(self.directory.name) / "fserve.sqlite3"
        self.engine = FakeEngine()
        self.sources = SourceService(self.database, self.engine)
        asyncio.run(self.sources.save(source_values()))

    def tearDown(self):
        self.directory.cleanup()

    def shown(self):
        return asyncio.run(self.sources.status())["configurations"][0]["login"]

    def logins_sent(self):
        return [args for operation, args in self.engine.requests if operation == "source.login"]

    def test_set_shown_given_at_connect_and_cleared(self):
        reply = asyncio.run(self.sources.set_login(
            "primary", {"kind": "sasl_plain", "username": "me", "password": "secret pw"}))
        self.assertEqual(reply["login"], {"kind": "sasl_plain", "username": "me"})
        self.assertEqual(self.shown(), {"kind": "sasl_plain", "username": "me"})
        self.assertEqual(self.logins_sent(), [], "nothing is sent until Connect")
        asyncio.run(self.sources.connect())
        operations = [operation for operation, _ in self.engine.requests]
        self.assertLess(operations.index("source.login"), operations.index("source.connect"),
                        "the login is given to the engine before Connect")
        self.assertEqual(self.logins_sent()[-1], {"source_id": "primary", "kind": "sasl_plain",
                                                  "username": "me", "password": "secret pw"})
        asyncio.run(self.sources.clear_login("primary"))
        self.assertIsNone(self.shown())
        self.assertEqual(self.logins_sent()[-1], {"source_id": "primary", "kind": "none"})
        asyncio.run(self.sources.connect())
        self.assertEqual(self.logins_sent()[-1], {"source_id": "primary", "kind": "none"},
                         "without a login, Connect tells the engine there is none")

    def test_a_nickserv_login_is_shown_by_its_account_and_given_at_connect(self):
        reply = asyncio.run(self.sources.set_login(
            "primary", {"kind": "nickserv", "password": "ns-secret"}))
        self.assertEqual(reply["login"], {"kind": "nickserv"})
        asyncio.run(self.sources.set_login(
            "primary", {"kind": "nickserv", "username": "Acct", "password": "ns-secret"}))
        self.assertEqual(self.shown(), {"kind": "nickserv", "username": "Acct"})
        asyncio.run(self.sources.connect())
        self.assertEqual(self.logins_sent()[-1], {"source_id": "primary", "kind": "nickserv",
                                                  "username": "Acct", "password": "ns-secret"})

    def test_a_login_table_from_before_nickserv_is_carried_over(self):
        asyncio.run(self.sources.set_login("primary", {"kind": "server_password", "password": "old"}))
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("ALTER TABLE source_login RENAME TO new_login")
            connection.execute("""CREATE TABLE source_login (
                source_id TEXT PRIMARY KEY, endpoint TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('server_password', 'sasl_plain')),
                username TEXT, password TEXT NOT NULL, updated_at REAL NOT NULL)""")
            connection.execute("INSERT INTO source_login SELECT source_id, endpoint, kind, "
                               "username, password, updated_at FROM new_login")
            connection.execute("DROP TABLE new_login")
        self.sources = SourceService(self.database, self.engine)
        self.assertEqual(self.shown(), {"kind": "server_password"})
        asyncio.run(self.sources.set_login("primary", {"kind": "nickserv", "password": "new"}))
        self.assertEqual(self.shown(), {"kind": "nickserv"})

    def test_a_certificate_is_made_shown_by_fingerprint_and_kept_until_cleared(self):
        reply = asyncio.run(self.sources.set_login("primary", {"kind": "certificate"}))
        view = reply["login"]
        self.assertEqual(set(view), {"kind", "sha256", "sha512"})
        self.assertRegex(view["sha256"], r"\A[0-9a-f]{64}\Z")
        self.assertRegex(view["sha512"], r"\A[0-9a-f]{128}\Z")
        self.assertEqual(self.shown(), view)
        self.assertEqual(self.logins_sent(), [], "nothing is sent until Connect")
        asyncio.run(self.sources.connect())
        sent = self.logins_sent()[-1]
        self.assertEqual(set(sent), {"source_id", "kind", "certificate"},
                         "the engine gets the certificate, not the fingerprints")
        self.assertEqual(fingerprints_of(sent["certificate"]),
                         {"sha256": view["sha256"], "sha512": view["sha512"]})
        self.assertIn("-----BEGIN PRIVATE KEY-----", sent["certificate"])
        key = sent["certificate"].split("-----BEGIN PRIVATE KEY-----")[1]
        self.assertNotIn(key, json.dumps(asyncio.run(self.sources.status())))
        # Saved again, it is the same certificate: it may be on an account.
        again = asyncio.run(self.sources.set_login("primary", {"kind": "certificate"}))
        self.assertEqual(again["login"], view)
        # Another kind of login replaces it, and the key is overwritten.
        asyncio.run(self.sources.set_login("primary", {"kind": "nickserv", "password": "x"}))
        self.assertNotIn(key.split()[3].encode(), self.database.read_bytes())
        fresh = asyncio.run(self.sources.set_login("primary", {"kind": "certificate"}))
        self.assertNotEqual(fresh["login"]["sha256"], view["sha256"], "a new one is made")

    def test_a_certificate_is_dropped_when_the_source_points_elsewhere(self):
        asyncio.run(self.sources.set_login("primary", {"kind": "certificate"}))
        asyncio.run(self.sources.save(source_values(port=7000)))
        self.assertIsNone(self.shown())
        with closing(sqlite3.connect(self.database)) as connection, connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM source_login").fetchone()[0], 0)

    def test_a_login_table_from_before_certificates_is_carried_over(self):
        asyncio.run(self.sources.set_login("primary", {"kind": "nickserv", "password": "old"}))
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("ALTER TABLE source_login RENAME TO new_login")
            connection.execute("""CREATE TABLE source_login (
                source_id TEXT PRIMARY KEY, endpoint TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('server_password', 'sasl_plain', 'nickserv')),
                username TEXT, password TEXT NOT NULL, updated_at REAL NOT NULL)""")
            connection.execute("INSERT INTO source_login SELECT source_id, endpoint, kind, "
                               "username, password, updated_at FROM new_login")
            connection.execute("DROP TABLE new_login")
        self.sources = SourceService(self.database, self.engine)
        self.assertEqual(self.shown(), {"kind": "nickserv"})
        asyncio.run(self.sources.set_login("primary", {"kind": "certificate"}))
        self.assertEqual(self.shown()["kind"], "certificate")

    def test_pointing_the_source_elsewhere_drops_it(self):
        for change in ({"port": 7000}, {"host": "irc.other.example"}):
            asyncio.run(self.sources.save(source_values()))
            asyncio.run(self.sources.set_login("primary", {"kind": "server_password", "password": "x"}))
            asyncio.run(self.sources.save(source_values(**change)))
            with self.subTest(change=change):
                self.assertIsNone(self.shown())
                asyncio.run(self.sources.save(source_values()))
                self.assertIsNone(self.shown(), "going back does not bring it back")
        asyncio.run(self.sources.set_login("primary", {"kind": "server_password", "password": "x"}))
        asyncio.run(self.sources.save(source_values(label="Renamed", channel="#elsewhere")))
        self.assertEqual(self.shown(), {"kind": "server_password"},
                         "a new label or channel keeps it: the server is the same")

    def test_a_refused_edit_keeps_it_even_when_the_page_looks_meanwhile(self):
        asyncio.run(self.sources.set_login("primary", {"kind": "server_password", "password": "kept"}))
        seen = []

        async def page_polls():
            # The new port is saved while the engine is asked; the page's
            # status poll can run then, as it does not wait for the lock.
            seen.append((await self.sources.status())["configurations"][0]["login"])

        self.engine.refuse_configure = page_polls
        with self.assertRaises(EngineRequestError):
            asyncio.run(self.sources.save(source_values(port=7000)))
        self.assertEqual(seen, [None], "the edit being tried was shown without the login")
        self.assertEqual(self.shown(), {"kind": "server_password"}, "the refused edit kept it")
        asyncio.run(self.sources.connect())
        self.assertEqual(self.logins_sent()[-1],
                         {"source_id": "primary", "kind": "server_password", "password": "kept"})

    def test_a_cleared_password_is_not_left_in_the_file(self):
        asyncio.run(self.sources.set_login("primary", {"kind": "server_password", "password": "wiped-4f1c"}))
        self.assertIn(b"wiped-4f1c", self.database.read_bytes())
        asyncio.run(self.sources.set_login("primary", {"kind": "server_password", "password": "next-77ad"}))
        self.assertNotIn(b"wiped-4f1c", self.database.read_bytes(), "a replaced one is overwritten")
        asyncio.run(self.sources.clear_login("primary"))
        self.assertNotIn(b"next-77ad", self.database.read_bytes(), "a cleared one is overwritten")

    def test_turning_tls_off_drops_it(self):
        asyncio.run(self.sources.set_login("primary", {"kind": "server_password", "password": "x"}))
        asyncio.run(self.sources.save(source_values(tls=False)))
        self.assertIsNone(self.shown())
        with self.assertRaises(SourceValidationError):
            asyncio.run(self.sources.set_login(
                "primary", {"kind": "server_password", "password": "x"}))

    def test_removing_the_source_deletes_it(self):
        asyncio.run(self.sources.set_login("primary", {"kind": "server_password", "password": "gone"}))
        asyncio.run(self.sources.remove("primary"))
        with closing(sqlite3.connect(self.database)) as connection, connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM source_login").fetchone()[0], 0)

    def test_the_password_is_only_in_its_own_table(self):
        asyncio.run(self.sources.set_login(
            "primary", {"kind": "sasl_plain", "username": "me", "password": "hunter2-unique"}))
        with closing(sqlite3.connect(self.database)) as connection, connection:
            tables = [row[0] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")]
            for table in tables:
                rows = json.dumps(connection.execute(f"SELECT * FROM {table}").fetchall())
                if table == "source_login":
                    self.assertIn("hunter2-unique", rows)
                else:
                    self.assertNotIn("hunter2-unique", rows, table)
        self.assertNotIn("hunter2-unique", json.dumps(asyncio.run(self.sources.status())))


try:
    from web_bridge_test import IRCFixture, NativeIrssi
except ImportError:   # the native helpers need a POSIX pty
    IRCFixture = NativeIrssi = None

SERVER_PASSWORD = 'Pass\\w"rd$1;%n'
SASL_ACCOUNT = "loginaccount"
SASL_PASSWORD = 'pa ss"wo\\rd $x;y %z'
NICKSERV_PASSWORD = 'ns"Pass\\w$1;%n'


if IRCFixture is not None:
    class PasswordFixture(IRCFixture):
        """Needs a server password; refuses registration without the right one."""

        def __init__(self, password: str):
            super().__init__()
            self.password = password
            self.passes: list[str] = []
            self.refused = False

        def handle_line(self, raw: bytes):
            if raw.startswith(b"PASS "):
                self.passes.append(raw[5:].decode("latin-1"))
                return
            if raw.startswith(b"USER ") and self.passes[-1:] != [self.password]:
                self.refused = True
                self.send(b":loopback 464 * :Password incorrect")
                self.send(b"ERROR :Closing link: bad password")
                self.disconnect_client()
                return
            super().handle_line(raw)

    class SaslFixture(IRCFixture):
        """Offers SASL PLAIN and checks the account, as an IRCv3 server does."""

        def __init__(self, username: str, password: str):
            super().__init__()
            self.expected = (username, password)
            self.received: list[tuple[str, str, str]] = []
            self.outcome = None

        def handle_line(self, raw: bytes):
            if raw.startswith(b"CAP LS"):
                self.send(b":loopback CAP * LS :sasl")
                return
            if raw.startswith(b"CAP REQ"):
                self.send(b":loopback CAP * ACK :sasl")
                return
            if raw == b"AUTHENTICATE PLAIN":
                self.send(b"AUTHENTICATE +")
                return
            if raw.startswith(b"AUTHENTICATE "):
                fields = base64.b64decode(raw[13:]).decode("latin-1").split("\0")
                self.received.append(tuple(fields))
                if len(fields) == 3 and (fields[1], fields[2]) == self.expected:
                    self.outcome = "success"
                    self.send(f":loopback 900 * * {fields[1]} :You are now logged in".encode())
                    self.send(b":loopback 903 * :SASL authentication successful")
                else:
                    self.outcome = "failure"
                    self.send(b":loopback 904 * :SASL authentication failed")
                return
            super().handle_line(raw)


    class NickServFixture(IRCFixture):
        """Answers IDENTIFY as NickServ does, after a moment."""

        def __init__(self):
            super().__init__()
            self.identified: list[str] = []

        def handle_line(self, raw: bytes):
            if raw.startswith(b"PRIVMSG NickServ :IDENTIFY "):
                self.identified.append(raw[len(b"PRIVMSG NickServ :IDENTIFY "):].decode("latin-1"))
                time.sleep(.5)
                self.send(b":NickServ!services@services.example NOTICE " + self.nick.encode() +
                          b" :You are now identified.")
                return
            super().handle_line(raw)


def leaks(native, directory: Path, database: Path, secret: str, replies: list) -> list[str]:
    """Every place outside the login's own table where the secret can be read."""
    found = []
    needle = secret.encode()
    if needle in bytes(native.transcript):
        found.append("Irssi's window output")
    for path in list(native.home.rglob("*")) + list(directory.rglob("*")):
        if path.is_file() and not path.is_symlink() and path != database \
                and not path.name.startswith(database.name):
            if needle in path.read_bytes():
                found.append(str(path))
    with closing(sqlite3.connect(database)) as connection, connection:
        for (table,) in connection.execute("SELECT name FROM sqlite_master WHERE type='table'"):
            if table != "source_login" and secret in json.dumps(
                    connection.execute(f"SELECT * FROM {table}").fetchall()):
                found.append(f"table {table}")
    if secret in json.dumps(replies):
        found.append("a reply")
    return found


@unittest.skipIf(NativeIrssi is None, "needs the native Irssi helpers")
class LoginNativeTests(unittest.TestCase):
    def run_login(self, fixture, values, login, secret):
        fixture.start()
        try:
            with NativeIrssi() as native:
                async def workflow():
                    engine = await EngineClient.open(str(native.path))
                    try:
                        with tempfile.TemporaryDirectory() as name:
                            directory = Path(name)
                            database = directory / "fserve.sqlite3"
                            sources = SourceService(database, engine)
                            await sources.save(values)
                            replies = [await sources.set_login("primary", login)]
                            await sources.connect()
                            state = None
                            deadline = time.monotonic() + 15
                            while time.monotonic() < deadline:
                                status = await engine.status()
                                replies.append(status)
                                view = sources.engine_source(status, "primary")
                                state = view and view["state"]
                                if state in ("ready", "failed"):
                                    break
                                await asyncio.sleep(.05)
                            replies.append(await sources.status())
                            replies.append(await engine.request(
                                "log.list", {"after": 0, "limit": 200}))
                            found = leaks(native, directory, database, secret, replies)
                            if state == "ready":
                                await sources.disconnect()
                            return state, view, found
                    finally:
                        await engine.close()

                return asyncio.run(workflow())
        finally:
            fixture.stop()

    def test_a_server_password_is_sent_as_typed_and_kept_out_of_every_record(self):
        fixture = PasswordFixture(SERVER_PASSWORD)
        state, view, found = self.run_login(
            fixture, source_values(fixture_port := fixture.port, host="127.0.0.1", tls=False),
            {"kind": "server_password", "password": SERVER_PASSWORD}, SERVER_PASSWORD)
        self.assertEqual(fixture.passes, [SERVER_PASSWORD], "Irssi sent PASS exactly as typed")
        self.assertEqual(state, "ready")
        self.assertEqual(view["login"], {"kind": "server_password"})
        self.assertEqual(found, [], "the password was found outside its own table")
        self.assertTrue(fixture_port)

    def test_a_wrong_server_password_is_refused_with_the_servers_words(self):
        fixture = PasswordFixture("the-right-one")
        state, view, found = self.run_login(
            fixture, source_values(fixture.port, host="127.0.0.1", tls=False),
            {"kind": "server_password", "password": "a-wrong-one"}, "a-wrong-one")
        self.assertTrue(fixture.refused)
        # As for any connection the server closes: the server's own words.
        self.assertEqual(state, "disconnected")
        self.assertIn("Password incorrect", view["reason"] or "")
        self.assertEqual(found, [])

    def test_a_sasl_account_logs_in_and_is_kept_out_of_every_record(self):
        fixture = SaslFixture(SASL_ACCOUNT, SASL_PASSWORD)
        state, view, found = self.run_login(
            fixture, source_values(fixture.port, host="127.0.0.1", tls=False),
            {"kind": "sasl_plain", "username": SASL_ACCOUNT, "password": SASL_PASSWORD},
            SASL_PASSWORD)
        self.assertEqual(fixture.received, [(SASL_ACCOUNT, SASL_ACCOUNT, SASL_PASSWORD)],
                         "Irssi sent the account exactly as typed")
        self.assertEqual(fixture.outcome, "success")
        self.assertEqual(state, "ready")
        self.assertEqual(view["login"], {"kind": "sasl_plain", "username": SASL_ACCOUNT})
        self.assertEqual(found, [], "the password was found outside its own table")

    def test_a_nickserv_login_identifies_before_the_join_and_is_kept_out_of_every_record(self):
        fixture = NickServFixture()
        state, view, found = self.run_login(
            fixture, source_values(fixture.port, host="127.0.0.1", tls=False),
            {"kind": "nickserv", "username": "Acct", "password": NICKSERV_PASSWORD},
            NICKSERV_PASSWORD)
        self.assertEqual(fixture.identified, ["Acct " + NICKSERV_PASSWORD],
                         "IDENTIFY went once, exactly as typed")
        identify = next(i for i, line in enumerate(fixture.lines)
                        if line.startswith(b"PRIVMSG NickServ"))
        join = next(i for i, line in enumerate(fixture.lines) if line.startswith(b"JOIN #"))
        self.assertLess(identify, join, "the JOIN waited for IDENTIFY")
        self.assertEqual(state, "ready")
        self.assertEqual(view["login"], {"kind": "nickserv", "username": "Acct"})
        self.assertEqual(found, [], "the password was found outside its own table")

    def test_a_refused_sasl_login_ends_the_connection(self):
        fixture = SaslFixture(SASL_ACCOUNT, "the-right-one")
        state, view, found = self.run_login(
            fixture, source_values(fixture.port, host="127.0.0.1", tls=False),
            {"kind": "sasl_plain", "username": SASL_ACCOUNT, "password": "a-wrong-one"},
            "a-wrong-one")
        self.assertEqual(fixture.outcome, "failure")
        self.assertEqual(state, "disconnected", "Irssi does not carry on without the account")
        self.assertIn("login refused: SASL authentication failed", view["reason"] or "")
        self.assertFalse(any(line.startswith(b"JOIN #review") for line in fixture.lines),
                         "the channel was not joined")
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
