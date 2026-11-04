"""Maintained native tests for the W1 bridge; run in cached Irssi Docker."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import pty
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from webapp.engine_client import EngineClient, EngineRequestError
from loopback_irc import LoopbackIRC


class IRCFixture(LoopbackIRC):
    """Generated loopback server with controllable JOIN/PART outcomes."""

    def __init__(self):
        super().__init__(archive=b"")
        self.refusal = None
        self.delay_join = False
        self.pending_channel = None
        self.hold_part = False
        self.pending_part = None
        self.denied_join_count = 0
        self.find_count = 0
        self.trigger_count = 0

    def handle_line(self, raw: bytes):
        if raw.startswith(b"JOIN #review") and self.refusal:
            self.denied_join_count += 1
            self.send(f":loopback {self.refusal} {self.nick} #review :fixture refusal".encode())
            return
        if raw.startswith(b"JOIN ") and self.delay_join:
            self.pending_channel = raw[5:].split()[0].decode()
            return
        if raw.startswith(b"PART "):
            if self.hold_part:
                self.pending_part = raw
            else:
                channel = raw[5:].split()[0].decode()
                self.send(f":{self.nick}!probe@127.0.0.1 PART {channel} :fixture departure".encode())
            return
        if raw.startswith(b"PRIVMSG #review :@find "):
            self.find_count += 1
            for line in (
                "[@Find Results] -= SysReset 2.55 =-",
                "Found [1] files on Trigger:[!Fixture] - Sends:[0/1] - Queues:[0/5]",
                "File: [\\books\\fixture.txt] - Size [4 B]",
                "End of @Find.",
            ):
                self.send(f":Fixture!fixture@127.0.0.1 PRIVMSG {self.nick} :{line}".encode())
            return
        if raw.startswith(b"PRIVMSG #review :!Fixture"):
            self.trigger_count += 1
            return
        super().handle_line(raw)

    def confirm_join(self):
        if not self.pending_channel:
            raise AssertionError("there is no delayed JOIN to confirm")
        channel, self.pending_channel = self.pending_channel, None
        super().handle_line(f"JOIN {channel}".encode())

    def confirm_part(self):
        if not self.pending_part:
            raise AssertionError("there is no delayed PART to confirm")
        raw, self.pending_part = self.pending_part, None
        channel = raw[5:].split()[0].decode()
        self.send(f":{self.nick}!probe@127.0.0.1 PART {channel} :fixture departure".encode())

    def kick_client(self):
        self.send(f":operator!fixture@127.0.0.1 KICK #review {self.nick} :fixture".encode())


class NativeIrssi:
    def __enter__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fserve-w1-test-")
        self.home = Path(self.temporary.name) / "home"
        (self.home / "scripts").mkdir(parents=True)
        (self.home / "scripts/lib").symlink_to(ROOT / "lib", target_is_directory=True)
        self.master, slave = pty.openpty()
        self.transcript = bytearray()
        self.stopped = threading.Event()
        self.process = subprocess.Popen(
            ["irssi", "--noconnect", "--home=" + str(self.home)],
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
            env=dict(os.environ, TERM="xterm", LC_ALL="C", PERL5LIB=str(ROOT / "lib")),
        )
        os.close(slave)
        self.reader = threading.Thread(target=self._pump, daemon=True)
        self.reader.start()
        time.sleep(.35)
        self.load_adapter()
        try:
            self.wait_until("bridge socket startup", lambda: self.path.exists())
        except BaseException:
            print(self.transcript.decode(errors="replace"), flush=True)
            raise
        return self

    def _pump(self):
        while not self.stopped.is_set():
            try:
                if select.select([self.master], [], [], .1)[0]:
                    self.transcript.extend(os.read(self.master, 65536))
            except OSError:
                return

    def command(self, value: str):
        os.write(self.master, value.encode() + b"\n")

    def load_adapter(self):
        self.path = self.home / "fserve-poc/engine.sock"
        self.command("/script load " + str(ROOT / "engine/dccatlas.pl"))

    # Long enough for a busy host: only a failure waits this long.
    @staticmethod
    def wait_until(label, predicate, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(.05)
        raise AssertionError("timed out waiting for " + label)

    def __exit__(self, *exc):
        exited_before_cleanup = self.process.poll() is not None
        if self.process.poll() is None:
            self.command("/quit")
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        if exited_before_cleanup and self.process.returncode not in (0, None):
            print("Irssi exited unexpectedly: " + str(self.process.returncode), flush=True)
            print(self.transcript[-12000:].decode(errors="replace"), flush=True)
        self.stopped.set()
        self.reader.join(timeout=1)
        os.close(self.master)
        self.temporary.cleanup()


class WireClient:
    def __init__(self, path: Path, *, handshake=True):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(3)
        self.buffer = b""
        self.sequence = 0
        try:
            self.socket.connect(str(path))
            if handshake:
                reply = self.request("hello")
                self.engine_instance_id = reply["result"]["engine_instance_id"]
        except BaseException:
            self.socket.close()
            raise

    def frame(self, operation, arguments=None):
        self.sequence += 1
        frame = dict(protocol_version=1, request_id=f"w{self.sequence}",
                     operation=operation, arguments=arguments or {})
        if operation not in ("hello", "status", "search.status", "job.status"):
            frame["operation_id"] = f"op{self.sequence}"
        return frame

    def read(self):
        while b"\n" not in self.buffer:
            chunk = self.socket.recv(65536)
            if not chunk:
                raise EOFError("bridge closed the controller connection")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def request(self, operation, arguments=None):
        frame = self.frame(operation, arguments)
        self.socket.sendall(json.dumps(frame).encode() + b"\n")
        while True:
            reply = self.read()
            if reply.get("type") == "event":
                continue
            if reply.get("request_id") != frame["request_id"]:
                raise AssertionError(reply)
            return reply

    def close(self):
        self.socket.close()


def wait_for_wire(path, timeout=5):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            return WireClient(path)
        except (OSError, EOFError, TimeoutError) as exc:
            last_error = exc
            time.sleep(.05)
    raise AssertionError(f"bridge did not accept a controller after disconnect: {last_error!r}")


def expect_peer_close(peer):
    try:
        return peer.recv(1) == b""
    except ConnectionResetError:
        return True


def source_state(wire, state):
    view = wire.request("status")["result"]["source"]
    return view if view["state"] == state else None


def join_count(fixture):
    return sum(line == b"JOIN #review" for line in fixture.lines)


def configure_connected_source(native, fixture, wire):
    native.command("/network add W1Test")
    native.command(f"/connect -network W1Test 127.0.0.1 {fixture.port}")
    native.wait_until("IRC registration", lambda: fixture.registered)
    servers = native.wait_until("connected server", lambda: wire.request("status")["result"]["servers"])
    args = dict(source_id="test", server_tag=servers[0]["tag"], channel="#review")
    assert wire.request("source.configure", args)["ok"]
    return args


class WebBridgeNativeTests(unittest.TestCase):
    def test_client_event_loss_watermark_requires_covering_snapshot(self):
        client = EngineClient(None, None, "fixture-engine", 0)
        from webapp.engine_client import EVENT_QUEUE_SIZE

        for sequence in range(1, EVENT_QUEUE_SIZE + 2):
            client._receive_event(dict(engine_instance_id="fixture-engine",
                                       event_sequence=sequence,
                                       event="job.state", payload={}))
        client.mark_reconciled(dict(engine_instance_id="fixture-engine",
                                    event_sequence=EVENT_QUEUE_SIZE))
        self.assertTrue(client.needs_reconciliation)
        client.mark_reconciled(dict(engine_instance_id="fixture-engine",
                                    event_sequence=EVENT_QUEUE_SIZE + 1))
        self.assertFalse(client.needs_reconciliation)

        client._receive_event(dict(engine_instance_id="fixture-engine",
                                   event_sequence=260,
                                   event="job.state", payload={"state": "complete"}))
        client.mark_reconciled(dict(engine_instance_id="fixture-engine",
                                    event_sequence=258))
        self.assertTrue(client.needs_reconciliation)
        self.assertEqual(client.events.qsize(), 1)
        client.mark_reconciled(dict(engine_instance_id="fixture-engine",
                                    event_sequence=260))
        self.assertFalse(client.needs_reconciliation)
        self.assertTrue(client.events.empty())

    def test_production_client_handshake_find_and_adapter_reload(self):
        fixture = IRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                native.command("/network add W1Test")
                native.command(f"/connect -network W1Test 127.0.0.1 {fixture.port}")
                native.command("/set fscrawl_find_quiet_ms 250")

                async def workflow():
                    client = await EngineClient.open(str(native.path))
                    first_identity = client.engine_instance_id
                    self.assertTrue(first_identity)
                    try:
                        status = await client.status()
                        self.assertEqual(status["event_sequence"], 0)
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            status = await client.status()
                            if fixture.registered and status["servers"]:
                                break
                            await asyncio.sleep(.05)
                        self.assertTrue(status["servers"])
                        await client.request("source.configure", dict(
                            source_id="test", server_tag=status["servers"][0]["tag"],
                            channel="#review"), operation_id="maintained-configure")
                        state_event = await asyncio.wait_for(client.events.get(), 2)
                        self.assertEqual(state_event.name, "source.state")
                        self.assertEqual(state_event.sequence, 1)
                        await client.request("source.connect", {"source_id": "test"},
                                             operation_id="maintained-connect")
                        deadline = time.monotonic() + 12
                        while time.monotonic() < deadline:
                            if (await client.status())["source"]["state"] == "ready":
                                break
                            await asyncio.sleep(.1)
                        self.assertEqual((await client.status())["source"]["state"], "ready")
                        search = await client.request("search.find", {
                            "source_id": "test", "terms": "fixture",
                        }, operation_id="maintained-find")
                        deadline = time.monotonic() + 12
                        while time.monotonic() < deadline:
                            page = await client.request("search.status", {
                                "source_id": "test", "search_id": search["search_id"],
                            })
                            if page["state"] == "complete":
                                break
                            await asyncio.sleep(.1)
                        self.assertEqual(page["state"], "complete")
                        self.assertEqual(len(page["results"]), 1)
                        row = page["results"][0]
                        self.assertTrue(row["selection_id"])
                        self.assertEqual(row["path"], "/books/fixture.txt")
                        self.assertEqual(row["sender"], "Fixture")
                        self.assertEqual(row["size_precision"], "exact")
                        self.assertEqual(fixture.find_count, 1)
                        await client.request("source.disconnect", {"source_id": "test"},
                                             operation_id="maintained-disconnect")
                        deadline = time.monotonic() + 12
                        while time.monotonic() < deadline:
                            if (await client.status())["source"]["state"] == "configured":
                                break
                            await asyncio.sleep(.1)
                        self.assertEqual((await client.status())["source"]["state"], "configured")
                        with self.assertRaises(EngineRequestError) as refused:
                            await client.request("search.download", {
                                "source_id": "test", "search_id": search["search_id"],
                                "selection_id": row["selection_id"],
                            }, operation_id="web-download-" + "1" * 64)
                        self.assertEqual(refused.exception.code, "stale_search")
                        self.assertEqual(fixture.trigger_count, 0,
                                         "stale selection emitted an IRC fetch trigger")
                        return first_identity
                    finally:
                        await client.close()

                first_identity = asyncio.run(workflow())

                native.command("/script unload dccatlas")
                native.wait_until("socket removal on unload", lambda: not native.path.exists())
                native.load_adapter()
                native.wait_until("socket after reload", lambda: native.path.exists())
                async def verify_reloaded_client():
                    replacement = await EngineClient.open(str(native.path))
                    try:
                        self.assertNotEqual(replacement.engine_instance_id, first_identity)
                        status = await replacement.status()
                        self.assertEqual(status["event_sequence"], 0)
                        self.assertIsNone(status["source"])
                    finally:
                        await replacement.close()

                asyncio.run(verify_reloaded_client())
        finally:
            fixture.stop()

    def test_refused_join_has_one_attempt_per_explicit_connect(self):
        for numeric in (473, 475, 471, 474):
            with self.subTest(numeric=numeric):
                fixture = IRCFixture()
                fixture.refusal = numeric
                fixture.start()
                try:
                    with NativeIrssi() as native:
                        wire = WireClient(native.path)
                        args = configure_connected_source(native, fixture, wire)
                        self.assertTrue(wire.request("source.connect", {"source_id": "test"})["ok"])
                        failed = native.wait_until("failed JOIN state", lambda: source_state(wire, "failed"))
                        self.assertTrue(failed["reason"])
                        self.assertFalse(failed["joined"])
                        time.sleep(3)
                        self.assertEqual(join_count(fixture), 1)
                        self.assertTrue(wire.request("source.connect", {"source_id": "test"})["ok"])
                        native.wait_until("one explicit retry", lambda: join_count(fixture) == 2)
                        failed = native.wait_until("retry refusal", lambda: source_state(wire, "failed"))
                        self.assertTrue(failed["reason"])
                        time.sleep(3)
                        self.assertEqual(join_count(fixture), 2)
                        self.assertTrue(wire.request("source.disconnect", {"source_id": "test"})["ok"])
                        self.assertTrue(wire.request("source.configure", dict(args, channel="#other"))["ok"])
                        self.assertFalse(fixture.errors, fixture.errors)
                        wire.close()
                finally:
                    fixture.stop()

    def test_delayed_join_cancel_pending_part_reconnect_and_kick(self):
        fixture = IRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                wire = WireClient(native.path)
                configure_connected_source(native, fixture, wire)
                fixture.delay_join = True
                self.assertTrue(wire.request("source.connect", {"source_id": "test"})["ok"])
                native.wait_until("delayed JOIN command", lambda: fixture.pending_channel)
                self.assertTrue(wire.request("source.disconnect", {"source_id": "test"})["ok"])
                fixture.confirm_join()
                native.wait_until("compensating PART", lambda: b"PART #review" in fixture.lines)
                native.wait_until("departed after cancelled JOIN", lambda: source_state(wire, "configured"))

                fixture.delay_join = False
                self.assertTrue(wire.request("source.connect", {"source_id": "test"})["ok"])
                native.wait_until("initial ready state", lambda: source_state(wire, "ready"))
                fixture.hold_part = True
                self.assertTrue(wire.request("source.disconnect", {"source_id": "test"})["ok"])
                native.wait_until("pending PART", lambda: fixture.pending_part)
                before = join_count(fixture)
                reconnect = wire.request("source.connect", {"source_id": "test"})
                self.assertEqual(reconnect["result"]["source"]["state"], "leaving")
                time.sleep(.5)
                self.assertEqual(join_count(fixture), before)
                fixture.confirm_part()
                native.wait_until("ready after explicit reconnect", lambda: source_state(wire, "ready"))
                self.assertEqual(join_count(fixture), before + 1)

                fixture.kick_client()
                failed = native.wait_until("failed after unexpected departure",
                                           lambda: source_state(wire, "failed"))
                self.assertIn("membership ended", failed["reason"])
                time.sleep(3)
                self.assertEqual(join_count(fixture), before + 1)
                self.assertFalse(fixture.errors, fixture.errors)
                wire.close()
        finally:
            fixture.stop()

    def test_fragmented_coalesced_malformed_oversized_and_second_controller(self):
        fixture = IRCFixture()
        fixture.start()
        try:
            with NativeIrssi() as native:
                wire = WireClient(native.path, handshake=False)
                hello = json.dumps(wire.frame("hello")).encode() + b"\n"
                for byte in hello:
                    wire.socket.sendall(bytes([byte]))
                    time.sleep(.001)
                reply = wire.read()
                self.assertTrue(reply["ok"])
                wire.engine_instance_id = reply["result"]["engine_instance_id"]
                self.assertTrue(wire.engine_instance_id)

                frames = [wire.frame("status") for _ in range(20)]
                wire.socket.sendall(b"".join(json.dumps(frame).encode() + b"\n" for frame in frames))
                replies = [wire.read() for _ in frames]
                self.assertEqual([r["request_id"] for r in replies], [f["request_id"] for f in frames])
                self.assertTrue(all(r["ok"] for r in replies))

                configure_connected_source(native, fixture, wire)
                self.assertTrue(wire.request("source.connect", {"source_id": "test"})["ok"])
                native.wait_until("ready before bounded burst",
                                  lambda: source_state(wire, "ready"))

                # Keep the controller from reading while a bounded burst drains.
                # An IRC KICK must still be processed and its source event must
                # interleave with the queued status replies.
                burst = [wire.frame("status") for _ in range(400)]
                wire.socket.sendall(b"".join(json.dumps(frame).encode() + b"\n" for frame in burst))
                started = time.monotonic()
                fixture.kick_client()
                burst_replies = []
                departure_event = False
                while (len(burst_replies) < len(burst) or not departure_event):
                    reply = wire.read()
                    if reply.get("type") == "event":
                        source = reply.get("payload", {}).get("source", {})
                        departure_event = departure_event or (
                            reply.get("event") == "source.state" and
                            source.get("state") == "failed")
                    else:
                        burst_replies.append(reply)
                self.assertLess(time.monotonic() - started, 2.0,
                                "bridge request processing starved the IRC event loop")
                self.assertEqual([r["request_id"] for r in burst_replies],
                                 [f["request_id"] for f in burst])
                self.assertTrue(all(r["ok"] for r in burst_replies))

                second = socket.socket(socket.AF_UNIX)
                second.settimeout(3)
                second.connect(str(native.path))
                self.assertTrue(expect_peer_close(second))
                second.close()
                self.assertTrue(wire.request("status")["ok"])
                wire.close()

                invalid_json = wait_for_wire(native.path)
                invalid_json.socket.sendall(b"{not-json}\n")
                self.assertTrue(expect_peer_close(invalid_json.socket))
                invalid_json.close()

                malformed = wait_for_wire(native.path)
                malformed.socket.sendall(b'{"protocol_version":1,"request_id":"bad","operation":"status","arguments":{},"extra":true}\n')
                self.assertTrue(expect_peer_close(malformed.socket))
                malformed.close()

                oversized = wait_for_wire(native.path)
                oversized.socket.sendall(b"x" * (64 * 1024 + 1))
                self.assertTrue(expect_peer_close(oversized.socket))
                oversized.close()

                recovered = wait_for_wire(native.path)
                self.assertTrue(recovered.request("status")["ok"])
                recovered.close()

                invalid_schema = wait_for_wire(native.path)
                refusal = invalid_schema.request("source.configure", {
                    "source_id": "test", "server_tag": "fixture", "channel": "invalid",
                })
                self.assertFalse(refusal["ok"])
                self.assertEqual(refusal["error"]["code"], "invalid_arguments")
                self.assertTrue(invalid_schema.request("status")["ok"])
                invalid_schema.close()

                # An unresponsive client can disconnect with queued requests;
                # the listener must accept a new controller afterward.
                slow = wait_for_wire(native.path)
                abandoned = [slow.frame("status") for _ in range(200)]
                slow.socket.sendall(b"".join(json.dumps(frame).encode() + b"\n"
                                                     for frame in abandoned))
                slow.close()
                replacement = None
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        replacement = wait_for_wire(native.path)
                        if replacement.request("status")["ok"]:
                            break
                        replacement.close()
                        replacement = None
                    except (EOFError, OSError, TimeoutError):
                        if replacement:
                            replacement.close()
                        replacement = None
                    time.sleep(.05)
                self.assertIsNotNone(replacement, "listener failed to recover after controller disconnect")
                replacement.close()
                self.assertFalse(fixture.errors, fixture.errors)
        finally:
            fixture.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
