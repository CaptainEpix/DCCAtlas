"""Offline behavioral tests for W2 source settings and managed IRC lifecycle."""

from __future__ import annotations

import asyncio
from contextlib import closing
import json
import os
from pathlib import Path
import select
import shutil
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from web_bridge_test import IRCFixture, NativeIrssi, WireClient, source_state
from webapp.engine_client import EngineClient, EngineRequestError
from webapp.sources import SourceConfigStore, SourceService, SourceValidationError, validate_source


def source_values(port: int, **overrides):
    values = dict(label="W2 test", provider="sysreset_find", host="127.0.0.1",
                  port=port, tls=False, nickname="W2Test", channel="#review")
    values.update(overrides)
    return values


async def wait_source(engine, states, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = await engine.status()
        source = status.get("source")
        if source and source["state"] in states:
            return source
        await asyncio.sleep(.05)
    raise AssertionError(f"source did not reach {states}: {status!r}")


def read_wire_response(wire, request_id):
    while True:
        response = wire.read()
        if response.get("type") != "event" and response.get("request_id") == request_id:
            return response


def queue_connect_then_disconnect(wire, source_id="primary"):
    """Place the managed source in the late-connected cancellation window."""
    connect = wire.frame("source.connect", {"source_id": source_id})
    disconnect = wire.frame("source.disconnect", {"source_id": source_id})
    wire.socket.sendall(b"".join(
        json.dumps(frame).encode() + b"\n" for frame in (connect, disconnect)))
    replies = {}
    leaving_events = 0
    deadline = time.monotonic() + 5
    while (len(replies) < 2 or leaving_events < 2) and time.monotonic() < deadline:
        response = wire.read()
        if response.get("type") == "event":
            source = response.get("payload", {}).get("source", {})
            if response.get("event") == "source.state" and source.get("state") == "leaving":
                leaving_events += 1
        else:
            replies[response["request_id"]] = response
    if len(replies) != 2 or leaving_events < 2:
        raise AssertionError(
            f"did not reach late-disconnect window: replies={replies!r}, "
            f"leaving_events={leaving_events}")
    assert replies[connect["request_id"]]["ok"], replies[connect["request_id"]]
    assert replies[disconnect["request_id"]]["ok"], replies[disconnect["request_id"]]


def start_closed_port_fixture():
    """Reserve an IRC fixture port, then leave it bound but not listening."""
    fixture = IRCFixture()
    port = fixture.port
    fixture.listener.close()
    fixture.listener = socket.socket()
    fixture.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    fixture.listener.bind(("127.0.0.1", port))
    fixture.port = port
    return fixture


class SourceStoreTests(unittest.TestCase):
    def test_migration_persistence_revision_permissions_and_one_source(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "private" / "source.sqlite3"
            store = SourceConfigStore(database)
            first, previous, changed = store.save(source_values(6667))
            self.assertIsNone(previous)
            self.assertTrue(changed)
            self.assertEqual(first.revision, 1)

            reloaded = SourceConfigStore(database)
            self.assertEqual(reloaded.get(), first)
            with closing(sqlite3.connect(database)) as connection, connection:
                self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 4)
                self.assertEqual(connection.execute(
                    "SELECT COUNT(*) FROM sources").fetchone()[0], 1)

            second, rollback_to, changed = reloaded.save(
                source_values(6667, label="W2 test edited"))
            self.assertTrue(changed)
            self.assertEqual(second.revision, 2)
            self.assertEqual(rollback_to, first)
            reloaded.restore(rollback_to, second.revision)
            self.assertEqual(reloaded.get(), first)
            with self.assertRaises(SourceValidationError):
                reloaded.save(source_values(6667, source_id="another"))

            if os.name != "nt":
                self.assertEqual(database.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual(database.stat().st_mode & 0o777, 0o600)

    def test_version_one_database_keeps_its_single_source(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "private" / "source.sqlite3"
            database.parent.mkdir(mode=0o700)
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.execute("""
                    CREATE TABLE source_configuration (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        source_id TEXT NOT NULL UNIQUE,
                        revision INTEGER NOT NULL CHECK (revision > 0),
                        label TEXT NOT NULL,
                        provider TEXT NOT NULL CHECK (provider = 'sysreset_find'),
                        host TEXT NOT NULL,
                        port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),
                        tls INTEGER NOT NULL CHECK (tls IN (0, 1)),
                        nickname TEXT NOT NULL,
                        channel TEXT NOT NULL,
                        updated_at REAL NOT NULL
                    )""")
                connection.execute(
                    "INSERT INTO source_configuration VALUES "
                    "(1, 'primary', 7, 'Old', 'sysreset_find', 'irc.example', 6697, 1, "
                    "'Nick', '#room', 1234.5)")
                connection.execute("PRAGMA user_version = 1")
            store = SourceConfigStore(database)
            kept = store.get()
            self.assertEqual(
                (kept.source_id, kept.revision, kept.label, kept.host, kept.port, kept.tls,
                 kept.nickname, kept.channel, kept.updated_at),
                ("primary", 7, "Old", "irc.example", 6697, True, "Nick", "#room", 1234.5))
            self.assertEqual(store.list(), [kept])
            with closing(sqlite3.connect(database)) as connection, connection:
                self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 4)
                self.assertIsNone(connection.execute(
                    "SELECT name FROM sqlite_master WHERE name='source_configuration'"
                ).fetchone())
            # Opening it again changes nothing.
            self.assertEqual(SourceConfigStore(database).list(), [kept])
            edited, previous, changed = store.save(source_values(6667))
            self.assertEqual((edited.revision, previous, changed), (8, kept, True))

    def test_every_source_has_a_category_kept_unless_changed(self):
        with tempfile.TemporaryDirectory() as directory:
            store = SourceConfigStore(Path(directory) / "private" / "source.sqlite3")
            first, _, _ = store.save(source_values(6667))
            self.assertEqual(first.category, 7000, "saved without one, a new source holds books")
            self.assertEqual(first.public()["category"], 7000)
            self.assertNotIn("category", first.engine_arguments(), "the engine is not told")
            tv, _, changed = store.save(source_values(6667, category=5000))
            self.assertTrue(changed)
            self.assertEqual((tv.category, tv.revision), (5000, 2))
            kept, _, changed = store.save(source_values(6667, label="Renamed"))
            self.assertEqual(kept.category, 5000, "an edit without one keeps it")
            for bad in (6500, "7000", 7000.0, True, None.__class__):
                with self.subTest(category=bad):
                    with self.assertRaises(SourceValidationError):
                        store.save(source_values(6667, category=bad))
            store.restore(tv, kept.revision)
            self.assertEqual(store.get().category, 5000, "a rollback restores it too")

    def test_version_three_database_gives_its_sources_books(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "private" / "source.sqlite3"
            store = SourceConfigStore(database)
            store.save(source_values(6667))
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.execute("ALTER TABLE sources DROP COLUMN category")
                connection.execute("PRAGMA user_version = 3")
            upgraded = SourceConfigStore(database)
            self.assertEqual(upgraded.get().category, 7000)
            with closing(sqlite3.connect(database)) as connection, connection:
                self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 4)

    def test_version_two_database_keeps_its_sources_and_gains_the_search_bot_kind(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "private" / "source.sqlite3"
            database.parent.mkdir(mode=0o700)
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.execute("""
                    CREATE TABLE sources (
                        source_id TEXT PRIMARY KEY,
                        revision INTEGER NOT NULL CHECK (revision > 0),
                        label TEXT NOT NULL,
                        provider TEXT NOT NULL CHECK (provider = 'sysreset_find'),
                        host TEXT NOT NULL,
                        port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),
                        tls INTEGER NOT NULL CHECK (tls IN (0, 1)),
                        nickname TEXT NOT NULL,
                        channel TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )""")
                connection.execute("""
                    CREATE TABLE removed_sources (
                        source_id TEXT PRIMARY KEY, last_revision INTEGER NOT NULL)""")
                connection.execute(
                    "INSERT INTO sources VALUES ('primary', 4, 'Old', 'sysreset_find', "
                    "'irc.example', 6697, 1, 'Nick', '#room', 10.0, 20.5)")
                connection.execute(
                    "INSERT INTO sources VALUES ('src-000000000001', 2, 'Second', "
                    "'sysreset_find', 'irc.other', 6667, 0, 'Nick', '#two', 11.0, 21.5)")
                connection.execute("INSERT INTO removed_sources VALUES ('src-gone', 9)")
                connection.execute("PRAGMA user_version = 2")
            store = SourceConfigStore(database)
            first, second = store.list()
            self.assertEqual(
                (first.source_id, first.revision, first.label, first.provider, first.host,
                 first.tls, first.channel, first.updated_at, first.search_bot),
                ("primary", 4, "Old", "sysreset_find", "irc.example", True, "#room", 20.5, ""))
            self.assertEqual((second.source_id, second.revision, second.search_bot),
                             ("src-000000000001", 2, ""))
            with closing(sqlite3.connect(database)) as connection, connection:
                self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 4)
                self.assertIsNone(connection.execute(
                    "SELECT name FROM sqlite_master WHERE name='sources_v2'").fetchone())
            self.assertEqual(SourceConfigStore(database).list(), [first, second])
            # The removed source's revision was kept, and the new kind is storable.
            back, _, _ = store.save(source_values(7000), "src-gone")
            self.assertEqual(back.revision, 10)
            bot, previous, _ = store.save(
                source_values(6667, host="irc.other", provider="searchbot",
                              search_bot="SearchBot"), "src-000000000001")
            self.assertEqual((bot.revision, bot.provider, bot.search_bot, previous),
                             (3, "searchbot", "SearchBot", second))
            self.assertEqual(bot.engine_arguments()["search_bot"], "SearchBot")
            self.assertEqual(bot.public()["search_bot"], "SearchBot")
            # A file-server source says nothing about a search bot to the engine.
            self.assertNotIn("search_bot", first.engine_arguments())
            self.assertEqual(first.public()["search_bot"], "")
            store.restore(previous, bot.revision, "src-000000000001")
            self.assertEqual(store.get("src-000000000001"), second)

    def test_several_sources_are_kept_apart_and_limited(self):
        with tempfile.TemporaryDirectory() as directory:
            store = SourceConfigStore(Path(directory) / "private" / "source.sqlite3")
            first, _, _ = store.save(source_values(6667))
            second_id = store.new_source_id()
            self.assertRegex(second_id, r"\Asrc-[0-9a-f]{12}\Z")
            second, previous, changed = store.save(
                source_values(6668, label="Second"), second_id)
            self.assertEqual((second.source_id, second.revision, previous, changed),
                             (second_id, 1, None, True))
            self.assertEqual(store.get(), first)
            self.assertEqual(store.get(second_id), second)
            self.assertEqual(store.list(), [first, second])

            # Editing one leaves the other alone.
            edited, _, _ = store.save(source_values(6668, label="Renamed"), second_id)
            self.assertEqual((edited.revision, store.get()), (2, first))

            # One source is one IRC connection: a server and nickname pair
            # cannot be claimed twice, whatever the letter case.
            store.save(source_values(6667, host="localhost"), "localhost-one")
            with self.assertRaisesRegex(SourceValidationError, "already uses"):
                store.save(source_values(6667, host="LOCALHOST", nickname="w2test",
                                         channel="#other"), store.new_source_id())
            store.save(source_values(6667, host="localhost", nickname="Other"),
                       store.new_source_id())
            with self.assertRaisesRegex(SourceValidationError, "already uses"):
                store.save(source_values(6667), second_id)
            with self.assertRaisesRegex(SourceValidationError, "invalid format"):
                store.save(source_values(7000), "bad id")

            # Removing remembers the revision, so an ID that returns never
            # reuses a revision the engine has already seen.
            self.assertEqual(store.delete(second_id), edited)
            self.assertIsNone(store.get(second_id))
            self.assertIsNone(store.delete(second_id))
            again, previous, _ = store.save(source_values(6668), second_id)
            self.assertEqual((again.revision, previous), (3, None))

            for number in range(len(store.list()), 8):
                store.save(source_values(7000 + number), store.new_source_id())
            self.assertEqual(len(store.list()), 8)
            with self.assertRaisesRegex(SourceValidationError, "at most 8"):
                store.save(source_values(7999), store.new_source_id())
            store.save(source_values(6667, label="Still editable"))

    def test_a_channel_is_not_given_to_two_sources_of_one_kind_outside_a_lab(self):
        public = {"host": "irc.example.test"}
        with tempfile.TemporaryDirectory() as directory:
            store = SourceConfigStore(Path(directory) / "private" / "source.sqlite3")
            store.save(source_values(6667, **public))
            # A second source of the same kind there would repeat every query
            # in that channel: whatever the nickname, the port, or the letter
            # case of the server or channel name.
            for change in ({}, {"port": 6697, "tls": True}, {"host": "IRC.Example.Test"},
                           {"channel": "#REVIEW"}):
                second = source_values(6667, **public, nickname="Second")
                second.update(change)
                with self.assertRaisesRegex(SourceValidationError, "same kind"):
                    store.save(second, store.new_source_id())
            self.assertEqual(len(store.list()), 1)

            # Another channel, or the other kind of source, asks something else.
            store.save(source_values(6667, **public, nickname="Second", channel="#other"),
                       "second")
            store.save(source_values(6667, **public, nickname="Third", provider="searchbot",
                                     search_bot="SearchBot"), "third")
            # Two search bots in one channel would both be sent the same line.
            with self.assertRaisesRegex(SourceValidationError, "same kind"):
                store.save(source_values(6667, **public, nickname="Fourth",
                                         provider="searchbot", search_bot="OtherBot"),
                           store.new_source_id())
            # Changing a source into a second one of its kind is refused too.
            with self.assertRaisesRegex(SourceValidationError, "same kind"):
                store.save(source_values(6667, **public, nickname="Second"), "second")
            with self.assertRaisesRegex(SourceValidationError, "same kind"):
                store.save(source_values(6667, **public, nickname="Third"), "third")
            # A source does not clash with itself.
            renamed, _, changed = store.save(source_values(6667, **public, label="Renamed"))
            self.assertEqual((renamed.label, changed), ("Renamed", True))

        # On a loopback or private-network address, a lab or test server, it
        # stays possible: there it is the only way to try several sources.
        with tempfile.TemporaryDirectory() as directory:
            store = SourceConfigStore(Path(directory) / "private" / "source.sqlite3")
            for number, host in enumerate(("127.0.0.1", "192.168.0.10", "localhost")):
                store.save(source_values(6667, host=host), f"lab-{number}-a")
                store.save(source_values(6667, host=host, nickname="Second"), f"lab-{number}-b")
            self.assertEqual(len(store.list()), 6)

    def test_validation_rejects_command_injection_and_invalid_endpoint_values(self):
        valid = source_values(6667)
        for patch in (
            {"label": "ok\rJOIN #else"},
            {"host": "irc.example.test\n"},
            {"host": "user@irc.example.test"},
            {"port": True},
            {"port": 65536},
            {"tls": 1},
            {"nickname": "Nick\rQUIT"},
            {"channel": "#ok\nPRIVMSG x :bad"},
            {"provider": "other"},
            # A search-bot source names its search bot; no other source does.
            {"provider": "searchbot"},
            {"provider": "searchbot", "search_bot": ""},
            {"provider": "searchbot", "search_bot": "Search Bot"},
            {"provider": "searchbot", "search_bot": "Bot\rQUIT"},
            {"search_bot": "SearchBot"},
            {"unknown": 1},
        ):
            with self.subTest(patch=patch), self.assertRaises(SourceValidationError):
                validate_source(dict(valid, **patch))
        self.assertEqual(validate_source(valid)["search_bot"], "")
        self.assertEqual(validate_source(dict(valid, search_bot=""))["search_bot"], "")
        self.assertEqual(
            validate_source(dict(valid, provider="searchbot", search_bot="Search|Bot"))
            ["search_bot"], "Search|Bot")


class SourceServiceNativeTests(unittest.TestCase):
    def test_retry_after_failure_cancels_previous_attempt_before_disconnect(self):
        fixture = start_closed_port_fixture()
        try:
            with NativeIrssi() as native:
                native.command("/set server_reconnect_time 2sec")
                native.wait_until("short reconnect interval",
                                  lambda: b"server_reconnect_time" in native.transcript)

                async def workflow():
                    engine = await EngineClient.open(str(native.path))
                    try:
                        with tempfile.TemporaryDirectory() as directory:
                            service = SourceService(Path(directory) / "source.db", engine)
                            await service.save(source_values(fixture.port))
                            first = await service.connect()
                            first_tag = first["source"]["server_tag"]
                            await wait_source(engine, {"failed"})
                            second = await service.connect()
                            second_tag = second["source"]["server_tag"]
                            self.assertNotEqual(first_tag, second_tag)
                            await wait_source(engine, {"failed"})
                            disconnected = await service.disconnect()
                            self.assertEqual(disconnected["source"]["state"], "disconnected")

                            fixture.listener.listen(2)
                            fixture.start()
                            deadline = time.monotonic() + 2.5
                            while time.monotonic() < deadline:
                                await asyncio.sleep(.05)
                            self.assertEqual(len(fixture.lines), 0,
                                             "a superseded retry connected after Disconnect")
                            self.assertIsNone(native.process.poll())
                            self.assertEqual((await engine.status())["source"]["state"],
                                             "disconnected")
                    finally:
                        await engine.close()

                asyncio.run(workflow())
        finally:
            if fixture.thread.ident is not None:
                fixture.stop()
            else:
                fixture.listener.close()

    def test_edit_after_failure_cancels_old_endpoint_retry_before_rebinding(self):
        old_endpoint = start_closed_port_fixture()
        new_endpoint = start_closed_port_fixture()
        try:
            with NativeIrssi() as native:
                native.command("/set server_reconnect_time 2sec")
                native.wait_until("short reconnect interval",
                                  lambda: b"server_reconnect_time" in native.transcript)

                async def workflow():
                    engine = await EngineClient.open(str(native.path))
                    try:
                        with tempfile.TemporaryDirectory() as directory:
                            service = SourceService(Path(directory) / "source.db", engine)
                            original = source_values(old_endpoint.port)
                            await service.save(original)
                            await service.connect()
                            await wait_source(engine, {"failed"})
                            edited = dict(original, port=new_endpoint.port)
                            saved = await service.save(edited)
                            self.assertEqual(saved["revision"], 2)
                            self.assertEqual(saved["port"], new_endpoint.port)
                            disconnected = await service.disconnect()
                            self.assertEqual(disconnected["source"]["state"], "disconnected")

                            old_endpoint.listener.listen(2)
                            old_endpoint.start()
                            deadline = time.monotonic() + 2.5
                            while time.monotonic() < deadline:
                                await asyncio.sleep(.05)
                            self.assertEqual(len(old_endpoint.lines), 0,
                                             "the old endpoint retried after configuration edit")
                            self.assertIsNone(native.process.poll())
                            status = await engine.status()
                            self.assertEqual(status["source"]["state"], "disconnected")
                            self.assertEqual(status["source"]["port"], new_endpoint.port)
                    finally:
                        await engine.close()

                asyncio.run(workflow())
        finally:
            for fixture in (old_endpoint, new_endpoint):
                if fixture.thread.ident is not None:
                    fixture.stop()
                else:
                    fixture.listener.close()

    def test_failed_endpoint_disconnect_stops_only_its_retry_and_explicit_connect_works(self):
        fixture = start_closed_port_fixture()
        unrelated = start_closed_port_fixture()
        try:
            with NativeIrssi() as native:
                native.command("/set server_reconnect_time 5sec")
                native.wait_until("reconnect interval applied",
                                  lambda: b"server_reconnect_time" in native.transcript)
                native.command(
                    f"/connect -! -noautosendcmd -network unrelated-test "
                    f"127.0.0.1 {unrelated.port} \"\" UnrelatedNick")
                native.wait_until("unrelated server connection refusal", lambda:
                                  b"Unable to connect server" in native.transcript and
                                  str(unrelated.port).encode() in native.transcript)

                async def workflow():
                    engine = await EngineClient.open(str(native.path))
                    try:
                        with tempfile.TemporaryDirectory() as directory:
                            service = SourceService(Path(directory) / "source.db", engine)
                            await service.save(source_values(fixture.port))
                            await service.connect()
                            failed = await wait_source(engine, {"failed"})
                            self.assertIn("connection failed", failed["reason"])
                            disconnected = await service.disconnect()
                            self.assertEqual(disconnected["source"]["state"], "disconnected")

                            fixture.listener.listen(1)
                            fixture.start()
                            unrelated.listener.listen(1)
                            unrelated.start()
                            native.wait_until("unrelated server reconnect remains intact",
                                              lambda: unrelated.registered, timeout=12)
                            self.assertFalse(fixture.registered,
                                             "disconnect did not cancel the saved endpoint reconnect")
                            self.assertIsNone(native.process.poll(),
                                              "Irssi exited while cancelling managed reconnect")
                            state = await engine.status()
                            self.assertEqual(state["source"]["state"], "disconnected")

                            await service.connect()
                            ready = await wait_source(engine, {"ready"})
                            self.assertTrue(ready["joined"])
                            self.assertEqual(fixture.nick, "W2Test")
                            self.assertFalse(fixture.errors, fixture.errors)
                            self.assertFalse(unrelated.errors, unrelated.errors)
                    finally:
                        await engine.close()

                asyncio.run(workflow())
        finally:
            if fixture.thread.ident is not None:
                fixture.stop()
            else:
                fixture.listener.close()
            if unrelated.thread.ident is not None:
                unrelated.stop()
            else:
                unrelated.listener.close()

    def test_edit_retry_and_startup_reconcile_cached_and_active_configuration(self):
        fixture = ReusableIRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                async def workflow():
                    engine = await EngineClient.open(str(native.path))
                    try:
                        with tempfile.TemporaryDirectory() as directory:
                            database = Path(directory) / "source.db"
                            service = SourceService(database, engine)
                            base = source_values(fixture.port)
                            await service.save(base)
                            await service.connect()
                            try:
                                await wait_source(engine, {"ready"})
                            except AssertionError as exc:
                                raise AssertionError(
                                    f"{exc}; fixture registered={fixture.registered}, "
                                    f"nick={fixture.nick}, lines={fixture.lines!r}, "
                                    f"accepts={fixture.accept_count}, errors={fixture.errors!r}; "
                                    f"irssi={native.transcript.decode(errors='replace')}") from exc
                            edited = dict(base, label="Retry same values")
                            with self.assertRaises(EngineRequestError) as busy:
                                await service.save(edited)
                            self.assertEqual(busy.exception.code, "source_busy")
                            await service.disconnect()
                            self.assertEqual((await wait_source(engine, {"disconnected"}))["revision"], 1)
                            try:
                                native.wait_until("loopback peer observes source disconnect",
                                                  fixture.client_closed)
                            except AssertionError as exc:
                                raise AssertionError(
                                    f"{exc}; status={await engine.status()!r}; "
                                    f"lines={fixture.lines!r}; "
                                    f"irssi={native.transcript.decode(errors='replace')}") from exc
                            applied = await service.save(edited)
                            self.assertEqual(applied["revision"], 2)
                            self.assertTrue(SourceService._matches(
                                (await engine.status())["source"], service.store.get()))

                            await service.connect()
                            try:
                                await wait_source(engine, {"ready"})
                            except AssertionError as exc:
                                raise AssertionError(
                                    f"{exc}; fixture registered={fixture.registered}, "
                                    f"nick={fixture.nick}, lines={fixture.lines!r}, "
                                    f"accepts={fixture.accept_count}, errors={fixture.errors!r}; "
                                    f"irssi={native.transcript.decode(errors='replace')}") from exc
                            different = dict(edited, label="Retry different values")
                            with self.assertRaises(EngineRequestError) as busy:
                                await service.save(different)
                            self.assertEqual(busy.exception.code, "source_busy")
                            await service.disconnect()
                            applied = await service.save(different)
                            self.assertEqual(applied["revision"], 3)

                            await service.connect()
                            await wait_source(engine, {"ready"})
                            # Normal status traffic ages the original configure
                            # acknowledgement out of the 256-entry cache.
                            for _ in range(270):
                                await engine.status()
                            restarted = SourceService(database, engine)
                            restored = await restarted.startup()
                            self.assertEqual(restored["revision"], 3)
                            same = await engine.request(
                                "source.configure", restarted.store.get().engine_arguments(),
                                operation_id="w2-fresh-idempotent-configure",
                            )
                            self.assertEqual(same["source"]["state"], "ready")
                            status = await engine.status()
                            self.assertEqual(status["source"]["state"], "ready")
                            self.assertFalse(fixture.errors, fixture.errors)
                    finally:
                        await engine.close()

                asyncio.run(workflow())
        finally:
            fixture.stop()

    def test_disconnect_queued_behind_connect_safely_cancels_late_connection(self):
        fixture = ReusableIRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                wire = WireClient(native.path)
                try:
                    config = dict(source_id="primary", revision=1, label="W2 queued",
                                  provider="sysreset_find", host="127.0.0.1",
                                  port=fixture.port, tls=False, nickname="W2Queued",
                                  channel="#review")
                    self.assertTrue(wire.request("source.configure", config)["ok"])
                    connect = wire.frame("source.connect", {"source_id": "primary"})
                    disconnect = wire.frame("source.disconnect", {"source_id": "primary"})
                    wire.socket.sendall(b"".join(
                        json.dumps(frame).encode() + b"\n"
                        for frame in (connect, disconnect)))
                    replies = {}
                    while len(replies) < 2:
                        response = wire.read()
                        if response.get("type") == "event":
                            continue
                        replies[response["request_id"]] = response
                    self.assertTrue(replies[connect["request_id"]]["ok"])
                    self.assertTrue(replies[disconnect["request_id"]]["ok"])
                    native.wait_until("loopback accepts the pending connection",
                                      lambda: fixture.accept_count >= 1)
                    native.wait_until("settled cancellation of pending connect",
                                      lambda: source_state(wire, "disconnected"))
                    native.wait_until("cancelled peer observes socket closure",
                                      fixture.client_closed)
                    time.sleep(.25)
                    self.assertIsNone(native.process.poll())
                    state = wire.request("status")["result"]["source"]
                    self.assertEqual(state["state"], "disconnected", state)
                    self.assertFalse(state["connected"], state)
                    self.assertFalse(state["joined"])

                    first_generation_accepts = fixture.accept_count
                    self.assertTrue(wire.request(
                        "source.connect", {"source_id": "primary"})["ok"])
                    native.wait_until("fresh explicit connection after cancellation",
                                      lambda: source_state(wire, "ready"))
                    self.assertEqual(fixture.accept_count, first_generation_accepts + 1)
                    self.assertFalse(fixture.client_closed())

                    # A newer explicit Connect queued behind Connect/Disconnect
                    # wins the source generation and must remain connected.
                    again_disconnect = wire.frame(
                        "source.disconnect", {"source_id": "primary"})
                    wire.socket.sendall(json.dumps(again_disconnect).encode() + b"\n")
                    self.assertTrue(read_wire_response(
                        wire, again_disconnect["request_id"])["ok"])
                    native.wait_until("explicit disconnect closes its peer",
                                      lambda: source_state(wire, "disconnected") and
                                      fixture.client_closed())
                    base_accepts = fixture.accept_count
                    generation_frames = [wire.frame(operation, {"source_id": "primary"})
                                         for operation in ("source.connect",
                                                           "source.disconnect",
                                                           "source.connect")]
                    wire.socket.sendall(b"".join(
                        json.dumps(frame).encode() + b"\n"
                        for frame in generation_frames))
                    seen = set()
                    while len(seen) < len(generation_frames):
                        response = wire.read()
                        if response.get("type") != "event":
                            seen.add(response["request_id"])
                    try:
                        native.wait_until("newer connect generation reaches ready",
                                          lambda: source_state(wire, "ready"))
                    except AssertionError as exc:
                        raise AssertionError(
                            f"{exc}; status={wire.request('status')['result']['source']!r}; "
                            f"accepts={fixture.accept_count}; errors={fixture.errors!r}; "
                            f"lines={fixture.lines!r}") from exc
                    time.sleep(.25)
                    current = wire.request("status")["result"]["source"]
                    self.assertEqual(current["state"], "ready", current)
                    self.assertTrue(current["connected"], current)
                    self.assertIn(fixture.accept_count,
                                  {base_accepts + 1, base_accepts + 2})
                    self.assertFalse(fixture.client_closed())
                    self.assertFalse(fixture.errors, fixture.errors)
                finally:
                    wire.close()
        finally:
            fixture.stop()

    def test_connect_during_late_disconnect_preserves_connection_ownership(self):
        fixture = ReusableIRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                wire = WireClient(native.path)
                try:
                    config = dict(source_id="primary", revision=1, label="W2 late connect",
                                  provider="sysreset_find", host="127.0.0.1",
                                  port=fixture.port, tls=False, nickname="W2Late",
                                  channel="#review")
                    self.assertTrue(wire.request("source.configure", config)["ok"])
                    queue_connect_then_disconnect(wire)

                    reconnect = wire.request("source.connect", {"source_id": "primary"})
                    self.assertTrue(reconnect["ok"], reconnect)
                    native.wait_until("reconnect adopts the pending native connection",
                                      lambda: source_state(wire, "ready"))
                    status = wire.request("status")["result"]
                    self.assertTrue(status["source"]["connected"], status["source"])
                    self.assertEqual(status["source"]["state"], "ready", status["source"])
                    self.assertIn(fixture.accept_count, {1, 2},
                                  "Connect did not reuse or wait for closure of the old socket")
                    self.assertEqual(
                        [s["tag"] for s in status["servers"] if s["connected"]],
                        [status["source"]["server_tag"]], status["servers"])
                    self.assertFalse(fixture.client_closed())

                    disconnect = wire.request("source.disconnect", {"source_id": "primary"})
                    self.assertTrue(disconnect["ok"], disconnect)
                    native.wait_until("adopted connection closes on Disconnect",
                                      lambda: source_state(wire, "disconnected") and
                                      fixture.client_closed())
                    status = wire.request("status")["result"]
                    self.assertFalse(any(s["connected"] for s in status["servers"]), status)
                    self.assertFalse(fixture.errors, fixture.errors)
                finally:
                    wire.close()
        finally:
            fixture.stop()

    def test_repeated_disconnect_keeps_deferred_cleanup_until_peer_closes(self):
        fixture = ReusableIRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                wire = WireClient(native.path)
                try:
                    config = dict(source_id="primary", revision=1,
                                  label="W2 repeated disconnect",
                                  provider="sysreset_find", host="127.0.0.1",
                                  port=fixture.port, tls=False, nickname="W2Repeat",
                                  channel="#review")
                    self.assertTrue(wire.request("source.configure", config)["ok"])
                    queue_connect_then_disconnect(wire)
                    before = wire.request("status")["result"]["source"]
                    self.assertEqual(before["state"], "leaving", before)
                    original_tag = before["server_tag"]

                    repeated = wire.request(
                        "source.disconnect", {"source_id": "primary"})
                    self.assertTrue(repeated["ok"], repeated)
                    repeated_source = repeated["result"]["source"]
                    if repeated_source["state"] == "disconnected":
                        self.assertTrue(
                            fixture.client_closed(),
                            "Disconnect reported completion while its peer stayed open")
                    else:
                        self.assertEqual(repeated_source["state"], "leaving",
                                         repeated_source)
                    self.assertEqual(repeated_source["server_tag"], original_tag)

                    native.wait_until(
                        "repeated Disconnect closes the original connection",
                        lambda: fixture.client_closed() and
                        source_state(wire, "disconnected"))
                    status = wire.request("status")["result"]
                    self.assertFalse(any(server["connected"]
                                         for server in status["servers"]), status)
                    self.assertEqual(fixture.accept_count, 1)
                    self.assertFalse(fixture.errors, fixture.errors)
                finally:
                    wire.close()
        finally:
            fixture.stop()

    def test_repeated_disconnect_then_connect_preserves_native_ownership(self):
        fixture = ReusableIRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                wire = WireClient(native.path)
                try:
                    config = dict(source_id="primary", revision=1,
                                  label="W2 repeated disconnect reconnect",
                                  provider="sysreset_find", host="127.0.0.1",
                                  port=fixture.port, tls=False, nickname="W2Repeat",
                                  channel="#review")
                    self.assertTrue(wire.request("source.configure", config)["ok"])
                    queue_connect_then_disconnect(wire)
                    before = wire.request("status")["result"]["source"]
                    self.assertEqual(before["state"], "leaving", before)
                    original_tag = before["server_tag"]

                    disconnect = wire.frame(
                        "source.disconnect", {"source_id": "primary"})
                    connect = wire.frame(
                        "source.connect", {"source_id": "primary"})
                    wire.socket.sendall(b"".join(
                        json.dumps(frame).encode() + b"\n"
                        for frame in (disconnect, connect)))
                    replies = {}
                    while len(replies) < 2:
                        response = wire.read()
                        if response.get("type") != "event":
                            replies[response["request_id"]] = response
                    self.assertTrue(replies[disconnect["request_id"]]["ok"],
                                    replies[disconnect["request_id"]])
                    self.assertTrue(replies[connect["request_id"]]["ok"],
                                    replies[connect["request_id"]])

                    try:
                        native.wait_until("latest Connect reaches ready",
                                          lambda: source_state(wire, "ready"))
                    except AssertionError as exc:
                        raise AssertionError(
                            f"{exc}; status={wire.request('status')['result']!r}; "
                            f"accepts={fixture.accept_count}; "
                            f"fixture_errors={fixture.errors!r}") from exc
                    status = wire.request("status")["result"]
                    self.assertTrue(status["source"]["connected"], status["source"])
                    self.assertEqual(
                        [server["tag"] for server in status["servers"]
                         if server["connected"]],
                        [status["source"]["server_tag"]], status["servers"])
                    self.assertIn(fixture.accept_count, {1, 2})
                    if fixture.accept_count == 1:
                        self.assertEqual(status["source"]["server_tag"], original_tag)
                    self.assertFalse(fixture.client_closed())

                    final_disconnect = wire.request(
                        "source.disconnect", {"source_id": "primary"})
                    self.assertTrue(final_disconnect["ok"], final_disconnect)
                    native.wait_until(
                        "final Disconnect closes the owned connection",
                        lambda: fixture.client_closed() and
                        source_state(wire, "disconnected"))
                    status = wire.request("status")["result"]
                    self.assertFalse(any(server["connected"]
                                         for server in status["servers"]), status)
                    self.assertFalse(fixture.errors, fixture.errors)
                finally:
                    wire.close()
        finally:
            fixture.stop()

    def test_connect_during_disconnect_callback_waits_for_owned_close(self):
        fixture = ReusableIRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                wire = WireClient(native.path)
                try:
                    native.command("/script load /project/t/hold_disconnect_signal.pl")
                    native.wait_until("disconnect signal test hook",
                                      lambda: b"W2_TEST_DISCONNECT_HOOK_READY" in
                                      native.transcript)
                    config = dict(source_id="primary", revision=1,
                                  label="W2 disconnect in flight",
                                  provider="sysreset_find", host="127.0.0.1",
                                  port=fixture.port, tls=False, nickname="W2Flight",
                                  channel="#review")
                    self.assertTrue(wire.request("source.configure", config)["ok"])
                    queue_connect_then_disconnect(wire)

                    native.wait_until("native disconnect callback is held",
                                      lambda: b"W2_TEST_DISCONNECT_PAUSED" in
                                      native.transcript)
                    before = wire.request("status")["result"]
                    self.assertEqual(before["source"]["state"], "leaving", before["source"])
                    self.assertEqual(before["source"]["server_tag"].rsplit("-", 1)[-1], "1")
                    self.assertEqual(fixture.accept_count, 1)
                    self.assertTrue(fixture.client_closed())
                    reconnect = wire.request("source.connect", {"source_id": "primary"})
                    self.assertTrue(reconnect["ok"], reconnect)
                    self.assertEqual(reconnect["result"]["source"]["state"], "leaving")
                    self.assertEqual(reconnect["result"]["source"]["server_tag"],
                                     before["source"]["server_tag"])
                    native.command("/w2_release_disconnect")
                    try:
                        native.wait_until("test releases native disconnect callback",
                                          lambda: b"W2_TEST_DISCONNECT_RELEASED" in
                                          native.transcript)
                    except AssertionError as exc:
                        raise AssertionError(
                            f"{exc}; engine_exit={native.process.poll()}; "
                            f"transcript={native.transcript[-5000:]!r}; "
                            f"fixture_lines={fixture.lines!r}; "
                            f"fixture_errors={fixture.errors!r}") from exc
                    native.wait_until("deferred fresh connection reaches ready",
                                      lambda: source_state(wire, "ready"))

                    status = wire.request("status")["result"]
                    self.assertTrue(status["source"]["connected"], status["source"])
                    self.assertEqual(status["source"]["state"], "ready", status["source"])
                    self.assertNotEqual(status["source"]["server_tag"],
                                        before["source"]["server_tag"])
                    self.assertEqual(fixture.accept_count, 2)
                    connected = [server["tag"] for server in status["servers"]
                                 if server["connected"]]
                    self.assertEqual(connected, [status["source"]["server_tag"]], status)
                    self.assertIn(fixture.accept_count, {1, 2})
                    self.assertFalse(fixture.client_closed())

                    disconnect = wire.request("source.disconnect", {"source_id": "primary"})
                    self.assertTrue(disconnect["ok"], disconnect)
                    native.wait_until("post-cancellation connection closes",
                                      lambda: source_state(wire, "disconnected") and
                                      fixture.client_closed())
                    status = wire.request("status")["result"]
                    self.assertFalse(any(server["connected"]
                                         for server in status["servers"]), status)
                    self.assertFalse(fixture.errors, fixture.errors)
                finally:
                    wire.close()
        finally:
            fixture.stop()

    def test_source_edit_is_refused_during_late_disconnect_then_can_retry(self):
        fixture = ReusableIRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                wire = WireClient(native.path)
                try:
                    config = dict(source_id="primary", revision=1, label="W2 late edit",
                                  provider="sysreset_find", host="127.0.0.1",
                                  port=fixture.port, tls=False, nickname="W2Edit",
                                  channel="#review")
                    self.assertTrue(wire.request("source.configure", config)["ok"])
                    queue_connect_then_disconnect(wire)

                    edit = dict(config, revision=2, label="W2 edited")
                    refused = wire.request("source.configure", edit)
                    self.assertFalse(refused["ok"], refused)
                    self.assertEqual(refused["error"]["code"], "source_busy", refused)
                    state = wire.request("status")["result"]["source"]
                    self.assertEqual(state["revision"], 1, state)
                    self.assertEqual(state["label"], config["label"], state)
                    self.assertIsNotNone(state["server_tag"], state)

                    native.wait_until("original connection closes after deferred cleanup",
                                      lambda: fixture.client_closed() and
                                      source_state(wire, "disconnected"))
                    accepted = wire.request("source.configure", edit)
                    self.assertTrue(accepted["ok"], accepted)
                    self.assertEqual(accepted["result"]["source"]["revision"], 2)
                    self.assertEqual(accepted["result"]["source"]["label"], "W2 edited")
                    status = wire.request("status")["result"]
                    self.assertFalse(any(s["connected"] for s in status["servers"]), status)
                    self.assertFalse(fixture.errors, fixture.errors)
                finally:
                    wire.close()
        finally:
            fixture.stop()

    def test_managed_reconnect_invalidates_old_search_selection(self):
        fixture = ReusableIRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                native.command("/set fscrawl_find_quiet_ms 250")
                native.wait_until("short local Find quiet interval",
                                  lambda: b"fscrawl_find_quiet_ms" in native.transcript)

                async def workflow():
                    engine = await EngineClient.open(str(native.path))
                    try:
                        with tempfile.TemporaryDirectory() as directory:
                            service = SourceService(Path(directory) / "source.db", engine)
                            await service.save(source_values(fixture.port))
                            await service.connect()
                            await wait_source(engine, {"ready"})

                            first_search = await engine.request(
                                "search.find", {"source_id": "primary", "terms": "fixture"},
                                operation_id="w2-managed-find-before-disconnect",
                            )
                            native.wait_until("initial loopback @find dispatch",
                                              lambda: fixture.find_count == 1)
                            deadline = time.monotonic() + 12
                            while time.monotonic() < deadline:
                                first_page = await engine.request(
                                    "search.status", {
                                        "source_id": "primary",
                                        "search_id": first_search["search_id"],
                                    },
                                )
                                if first_page["state"] == "complete":
                                    break
                                await asyncio.sleep(.1)
                            self.assertEqual(first_page["state"], "complete")
                            self.assertEqual(len(first_page["results"]), 1)
                            old_row = first_page["results"][0]
                            self.assertTrue(old_row["selection_id"])

                            await service.disconnect()
                            await wait_source(engine, {"disconnected"})
                            with self.assertRaises(EngineRequestError) as refused:
                                await engine.request(
                                    "search.download", {
                                        "source_id": "primary",
                                        "search_id": first_search["search_id"],
                                        "selection_id": old_row["selection_id"],
                                    },
                                    operation_id="web-download-" + "2" * 64,
                                )
                            self.assertEqual(refused.exception.code, "stale_search")
                            self.assertEqual(fixture.trigger_count, 0)

                            await service.connect()
                            await wait_source(engine, {"ready"})
                            with self.assertRaises(EngineRequestError) as refused:
                                await engine.request(
                                    "search.download", {
                                        "source_id": "primary",
                                        "search_id": first_search["search_id"],
                                        "selection_id": old_row["selection_id"],
                                    },
                                    operation_id="web-download-" + "3" * 64,
                                )
                            self.assertEqual(refused.exception.code, "stale_search")
                            self.assertEqual(fixture.trigger_count, 0)

                            self.assertEqual(fixture.find_count, 1)
                            self.assertEqual(fixture.trigger_count, 0)
                            await service.disconnect()
                            await wait_source(engine, {"disconnected"})
                    finally:
                        await engine.close()

                asyncio.run(workflow())
        finally:
            fixture.stop()

    def test_tls_refuses_untrusted_server_certificate(self):
        openssl = shutil.which("openssl")
        if openssl is None:
            self.skipTest("openssl is required to generate a local self-signed fixture")
        with tempfile.TemporaryDirectory() as directory:
            cert = Path(directory) / "server.pem"
            key = Path(directory) / "server.key"
            subprocess.run([
                openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(key), "-out", str(cert), "-days", "1",
                "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            fixture = TLSIRCFixture(cert, key)
            fixture.start()
            try:
                with NativeIrssi() as native:
                    async def workflow():
                        engine = await EngineClient.open(str(native.path))
                        try:
                            with tempfile.TemporaryDirectory() as config_directory:
                                service = SourceService(
                                    Path(config_directory) / "source.db", engine)
                                await service.save(source_values(fixture.port, tls=True))
                                await service.connect()
                                failed = await wait_source(engine, {"failed"})
                                self.assertIn("failed", failed["reason"].lower())
                                self.assertFalse(fixture.registered,
                                                 "TLS accepted a self-signed certificate")
                        finally:
                            await engine.close()

                    asyncio.run(workflow())
            finally:
                fixture.stop()


class TLSIRCFixture(IRCFixture):
    def __init__(self, cert: Path, key: Path):
        super().__init__()
        self.tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.tls_context.load_cert_chain(certfile=cert, keyfile=key)

    def run(self):
        try:
            raw, _ = self.listener.accept()
            self.client = self.tls_context.wrap_socket(raw, server_side=True)
            self.client.settimeout(.1)
            pending = bytearray()
            while not self.stopped.is_set():
                try:
                    chunk = self.client.recv(4096)
                except (socket.timeout, ssl.SSLWantReadError):
                    continue
                if not chunk:
                    break
                pending.extend(chunk)
                while b"\r\n" in pending:
                    line, _, remainder = pending.partition(b"\r\n")
                    pending = bytearray(remainder)
                    self.lines.append(line)
                    self.handle_line(line)
        except (OSError, ssl.SSLError):
            if not self.stopped.is_set():
                self.errors.append("TLS fixture connection ended during handshake")
        except Exception as exc:
            self.errors.append(f"TLS fixture responder failed: {exc!r}")


class ReusableIRCFixture(IRCFixture):
    """Loopback IRC server that permits explicit reconnects on one port."""

    def __init__(self):
        super().__init__()
        self.accept_count = 0

    def client_closed(self):
        client = self.client
        if client is None:
            return True
        try:
            readable, _, _ = select.select([client], [], [], 0)
            return bool(readable and client.recv(1, socket.MSG_PEEK) == b"")
        except OSError:
            return True

    def handle_line(self, raw: bytes):
        if raw.startswith(b"QUIT"):
            client = self.client
            if client is not None:
                try:
                    client.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            return
        super().handle_line(raw)

    def run(self):
        self.listener.settimeout(.1)
        while not self.stopped.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.accept_count += 1
            self.client = client
            self.client.settimeout(.1)
            self.nick = ""
            self.user_seen = False
            self.registered = False
            pending = bytearray()
            try:
                while not self.stopped.is_set():
                    try:
                        chunk = client.recv(4096)
                    except socket.timeout:
                        continue
                    if not chunk:
                        break
                    pending.extend(chunk)
                    while b"\r\n" in pending:
                        line, _, remainder = pending.partition(b"\r\n")
                        pending = bytearray(remainder)
                        self.lines.append(line)
                        self.handle_line(line)
            except OSError:
                # Client-initiated IRC Disconnect closes this loopback socket;
                # a racing server write can therefore raise BrokenPipeError.
                pass
            finally:
                try:
                    client.close()
                except OSError:
                    pass
                if self.client is client:
                    self.client = None


class RefusingIRCServer:
    """Accepts a client, turns it away as a password-protected server does, and counts."""

    def __init__(self):
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(5)
        self.listener.settimeout(.2)
        self.port = self.listener.getsockname()[1]
        self.accept_count = 0
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stopped.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.accept_count += 1
            try:
                client.settimeout(1)
                try:
                    client.recv(4096)
                except socket.timeout:
                    pass
                client.sendall(
                    b":irc.fixture 464 W2Test :A password is required and one was not provided.\r\n"
                    b"ERROR :Closing link: (user@127.0.0.1) [You are not allowed to connect]\r\n")
            except OSError:
                pass
            finally:
                client.close()

    def stop(self):
        self.stopped.set()
        self.listener.close()


class SingleAttemptNativeTests(unittest.TestCase):
    """One explicit Connect is one connection attempt; Irssi must not retry by itself."""

    def run_with_short_reconnect(self, workflow):
        with NativeIrssi() as native:
            native.command("/set server_reconnect_time 2sec")
            native.wait_until("short reconnect interval",
                              lambda: b"server_reconnect_time" in native.transcript)

            async def run():
                engine = await EngineClient.open(str(native.path))
                try:
                    with tempfile.TemporaryDirectory() as directory:
                        await workflow(SourceService(Path(directory) / "source.db", engine), engine)
                    self.assertIsNone(native.process.poll())
                finally:
                    await engine.close()

            asyncio.run(run())

    def test_refused_registration_is_not_retried_and_reports_what_the_server_said(self):
        server = RefusingIRCServer()

        async def workflow(service, engine):
            await service.save(source_values(server.port))
            await service.connect()
            source = await wait_source(engine, {"disconnected", "failed"})
            self.assertIn("A password is required", source["reason"] or "", source)
            await asyncio.sleep(7)   # more than three reconnect intervals
            self.assertEqual(server.accept_count, 1, "Irssi reconnected on its own")
            self.assertIn((await engine.status())["source"]["state"], {"disconnected", "failed"})

        try:
            self.run_with_short_reconnect(workflow)
        finally:
            server.stop()

    def test_connection_dropped_by_the_server_is_not_reopened(self):
        fixture = ReusableIRCFixture()
        fixture.start()

        async def workflow(service, engine):
            await service.save(source_values(fixture.port))
            await service.connect()
            await wait_source(engine, {"ready"})
            fixture.client.shutdown(socket.SHUT_RDWR)
            await wait_source(engine, {"disconnected", "failed"})
            await asyncio.sleep(7)
            self.assertEqual(fixture.accept_count, 1, "Irssi reconnected on its own")
            self.assertNotEqual((await engine.status())["source"]["state"], "ready")

        try:
            self.run_with_short_reconnect(workflow)
        finally:
            fixture.stop()


class StartTLSTakenNickFixture(IRCFixture):
    """Offers STARTTLS, as one real network did, and already has a user on the nick asked for."""

    def __init__(self):
        super().__init__()
        self.starttls_requests = 0
        self.nicks_asked: list[str] = []

    def handle_line(self, raw: bytes):
        if raw.startswith(b"CAP LS"):
            # The IRCv3 capability for STARTTLS is called "tls".
            self.send(b":loopback CAP * LS :tls")
            return
        if raw == b"STARTTLS":
            self.starttls_requests += 1
            return   # never answered: the connection would stall here
        if raw.startswith(b"NICK ") and not self.registered:
            nick = raw[5:].strip().decode()
            self.nicks_asked.append(nick)
            if len(self.nicks_asked) == 1:
                self.send(f":loopback 433 * {nick} :Nickname is already in use".encode())
                return
        super().handle_line(raw)


class ConnectionFactsNativeTests(unittest.TestCase):
    """What the 2026-10-14 search-bot test showed: TLS off and a nick in use."""

    def test_tls_off_stays_plain_text_and_the_nick_in_use_is_reported(self):
        fixture = StartTLSTakenNickFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                async def workflow():
                    engine = await EngineClient.open(str(native.path))
                    try:
                        with tempfile.TemporaryDirectory() as directory:
                            service = SourceService(Path(directory) / "source.db", engine)
                            await service.save(source_values(fixture.port))
                            await service.connect()
                            native.wait_until(
                                "registration or a STARTTLS request",
                                lambda: fixture.registered or fixture.starttls_requests)
                            self.assertEqual(fixture.starttls_requests, 0,
                                             "Irssi asked for STARTTLS with TLS off")
                            ready = await wait_source(engine, {"ready"})
                            self.assertEqual(fixture.nicks_asked, ["W2Test", "W2Test_"])
                            self.assertEqual((ready["nickname"], ready["current_nick"]),
                                             ("W2Test", "W2Test_"))
                            # The web service still treats the source as the
                            # one configured: the nickname setting is unchanged.
                            view = service.engine_source(await engine.status(), "primary")
                            self.assertTrue(service._matches(view, service.store.get()))
                            await service.disconnect()
                            gone = await wait_source(engine, {"disconnected"})
                            self.assertIsNone(gone["current_nick"])
                    finally:
                        await engine.close()

                asyncio.run(workflow())
            self.assertFalse(fixture.errors, fixture.errors)
        finally:
            fixture.stop()
