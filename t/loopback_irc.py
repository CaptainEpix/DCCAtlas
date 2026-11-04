"""A loopback IRC server for the engine tests: it answers a client as the
fixtures need, offers files by DCC, and records what it was sent. Offline only."""

from __future__ import annotations

import queue
import socket
import struct
import threading
import time


ROW = '!FixtureBot Sample.epub ::INFO:: 17B; "quoted" \\ $x'
CANCEL_ROW = '!FixtureBot Cancel.epub ::INFO:: 14B'
DISCONNECT_ROW = '!FixtureBot Disconnect.epub ::INFO:: 19B'
PENDING_DISCONNECT_ROW = '!FixtureBot Pending.epub ::INFO:: 20B'
QUEUE_ROW = '!QueueFixtureBot Queued.epub ::INFO:: 19B'
NATIVE_PROBE_ROW = 'NativeProbe ; "quoted" \\ $x'
CONTENT = b"offline generated DCC fixture\x00bytes\n"
QUEUED_CONTENT = b"native queued DCC fixture\x00bytes\n"


class LoopbackIRC:
    def __init__(self, archive: bytes):
        self.archive = archive
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.events: queue.Queue[tuple[str, str]] = queue.Queue()
        self.lines: list[bytes] = []
        self.outbound_to_client: list[bytes] = []
        self.client = None
        self.send_lock = threading.Lock()
        self.nick = ""
        self.user_seen = False
        self.registered = False
        self.stopped = threading.Event()
        self.disconnect_requested = False
        self.errors: list[str] = []
        self.query_count = 0
        self.row_count = 0
        self.native_probe_count = 0
        self.cancel_query_count = 0
        self.disconnect_query_count = 0
        self.pending_disconnect_query_count = 0
        self.queue_query_count = 0
        self.cancel_row_count = 0
        self.disconnect_row_count = 0
        self.pending_disconnect_row_count = 0
        self.queue_row_count = 0
        self.offer_records: list[dict[str, object]] = []
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stopped.set()
        try:
            self.listener.close()
        except OSError:
            pass
        # The responder thread can clear self.client as it exits. Snapshot the
        # socket once so teardown never dereferences a value that became None
        # between the condition and the shutdown/close calls.
        client = self.client
        if client is not None:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                client.close()
            except OSError:
                pass
        self.thread.join(timeout=1)

    def disconnect_client(self):
        self.disconnect_requested = True
        # The responder thread may clear self.client immediately after
        # shutdown wakes it. Keep one stable reference for both operations.
        client = self.client
        if client is not None:
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                client.close()
            except OSError:
                pass

    def send(self, line: bytes):
        if self.client:
            with self.send_lock:
                self.outbound_to_client.append(line + b"\r\n")
                self.client.sendall(line + b"\r\n")

    def run(self):
        try:
            self.client, _ = self.listener.accept()
            self.client.settimeout(0.1)
            pending = bytearray()
            while not self.stopped.is_set():
                try:
                    chunk = self.client.recv(4096)
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
        except (OSError, BrokenPipeError):
            if not self.stopped.is_set() and not self.disconnect_requested:
                self.errors.append("loopback IRC socket failed")
        except Exception as exc:  # report worker failures to the controlling test
            self.errors.append(f"loopback responder failed: {exc!r}")

    def handle_line(self, raw: bytes):
        text = raw.decode("ascii", errors="replace")
        if text.startswith("NICK "):
            self.nick = text[5:].strip()
            self.register_if_ready()
        elif text.startswith("USER "):
            self.user_seen = True
            self.register_if_ready()
        elif text.startswith("CAP "):
            fields = text.split()
            sub = fields[1] if len(fields) > 1 else ""
            if sub == "LS":
                self.send(f":loopback CAP {self.nick or '*'} LS :".encode())
            elif sub == "REQ":
                self.send(f":loopback CAP {self.nick or '*'} ACK :".encode())
        elif text.startswith("PING "):
            self.send(b"PONG " + raw[5:])
        elif text.startswith("JOIN ") and self.nick:
            channel = text[5:].split()[0]
            self.send(f":{self.nick}!probe@127.0.0.1 JOIN :{channel}".encode())
            self.send(f":loopback 353 {self.nick} = {channel} :{self.nick}".encode())
            self.send(f":loopback 366 {self.nick} {channel} :End of NAMES list".encode())
            self.events.put(("join", channel))
        elif text.startswith("PRIVMSG ") or " PRIVMSG " in text:
            message = text.split(" PRIVMSG ", 1)[1] if " PRIVMSG " in text else text[len("PRIVMSG "):]
            target, separator, trailing = message.partition(" :")
            if not separator:
                return
            body = trailing
            self.events.put(("privmsg", body))
            if target == "#phase5" and body == "@search Loopback":
                self.query_count += 1
                threading.Thread(target=self.send_result_archive, args=(ROW,), daemon=True).start()
            elif target == "#phase5" and body == "@search Cancel":
                self.cancel_query_count += 1
                threading.Thread(target=self.send_result_archive, args=(CANCEL_ROW,), daemon=True).start()
            elif target == "#phase5" and body == "@search Disconnect":
                self.disconnect_query_count = getattr(self, "disconnect_query_count", 0) + 1
                threading.Thread(target=self.send_result_archive, args=(DISCONNECT_ROW,), daemon=True).start()
            elif target == "#phase5" and body == "@search PendingDisconnect":
                self.pending_disconnect_query_count += 1
                threading.Thread(target=self.send_result_archive,
                                 args=(PENDING_DISCONNECT_ROW,), daemon=True).start()
            elif target == "#phase5" and body == "@search Queue":
                self.queue_query_count += 1
                threading.Thread(target=self.send_result_archive, args=(QUEUE_ROW,), daemon=True).start()
            elif target == "#phase5" and body == NATIVE_PROBE_ROW:
                self.native_probe_count += 1
            elif target == "#phase5" and body == ROW:
                self.row_count += 1
                threading.Thread(target=self.send_content, daemon=True).start()
            elif target == "#phase5" and body == CANCEL_ROW:
                self.cancel_row_count += 1
            elif target == "#phase5" and body == DISCONNECT_ROW:
                self.disconnect_row_count += 1
            elif target == "#phase5" and body == PENDING_DISCONNECT_ROW:
                self.pending_disconnect_row_count += 1
            elif target == "#phase5" and body == QUEUE_ROW:
                self.queue_row_count += 1
                threading.Thread(target=self.send_queued_content, daemon=True).start()

    def register_if_ready(self):
        if self.registered or not self.nick or not self.user_seen:
            return
        self.registered = True
        self.send(f":loopback 001 {self.nick} :offline fixture server ready".encode())
        self.send(f":loopback 005 {self.nick} CASEMAPPING=rfc1459 CHANTYPES=#&+! PREFIX=(ov)@+ :supported".encode())
        self.send(f":loopback 376 {self.nick} :End of MOTD".encode())
        self.events.put(("registered", self.nick))

    def offer(self, sender: str, filename: str, content: bytes, accept: bool):
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(0.6 if not accept else 5.0)
        port = listener.getsockname()[1]
        ip_number = struct.unpack("!I", socket.inet_aton("127.0.0.1"))[0]
        ctcp = f"\x01DCC SEND {filename} {ip_number} {port} {len(content)}\x01"
        self.send(f":{sender}!fixture@127.0.0.1 PRIVMSG {self.nick} :{ctcp}".encode("ascii"))
        self.events.put(("dcc_offer", sender + ":" + filename + ":" + repr(ctcp)))
        accepted = False
        try:
            connection, _ = listener.accept()
            accepted = True
            if not accept:
                self.errors.append(f"wrong-peer DCC offer was unexpectedly accepted: {sender}")
                connection.close()
                return
            with connection:
                connection.settimeout(2.0)
                connection.sendall(content)
                try:
                    connection.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
        except socket.timeout:
            if accept:
                self.errors.append(f"expected DCC sender {sender} was not accepted")
        finally:
            self.offer_records.append({"sender": sender, "filename": filename,
                                       "accepted": accepted, "expected_accept": accept})
            listener.close()

    def send_result_archive(self, row: str):
        self.send(b":ResultBot!fixture@127.0.0.1 JOIN :#phase5")
        time.sleep(0.1)
        basename = "SearchBot_results_for__Loopback.txt.zip"
        if row == CANCEL_ROW:
            basename = "SearchBot_results_for__Cancel.txt.zip"
        elif row == DISCONNECT_ROW:
            basename = "SearchBot_results_for__Disconnect.txt.zip"
        elif row == PENDING_DISCONNECT_ROW:
            basename = "SearchBot_results_for__PendingDisconnect.txt.zip"
        elif row == QUEUE_ROW:
            basename = "SearchBot_results_for__Queue.txt.zip"
        self.offer("ResultBot", basename, archive_bytes(row), True)

    def send_content(self):
        self.offer("FixtureBot", "Sample.epub", CONTENT, True)

    def send_queued_content(self):
        self.offer("QueueFixtureBot", "Queued.epub", QUEUED_CONTENT, True)
