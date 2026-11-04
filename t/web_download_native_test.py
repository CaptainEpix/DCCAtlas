"""Native W4 acceptance: one web download through real Irssi on loopback only.

Run in the cached Irssi container with networking disabled. The generated
fixture plays the IRC server, the SysReset Find responder, the FServe DCC CHAT
session and the DCC SEND sender.
"""

from __future__ import annotations

import asyncio
import io
import os
from pathlib import Path
import pty
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from web_advert_test import sysreset_advert
from web_bridge_test import NativeIrssi
from web_search_test import wait_search
from web_source_test import ReusableIRCFixture, source_values, wait_source
from webapp.adverts import AdvertService
from webapp.browse import BrowseError, BrowseService
from webapp.download_queue import QueueError, QueueService
from webapp.downloads import DownloadError, DownloadService
from webapp.engine_client import EngineClient, EngineRequestError
from webapp.manifests import ManifestError, ManifestService
from webapp.multisearch import MultiSearchService
from webapp.searches import SearchError, SearchService
from webapp.servers import ServersService
from webapp.sources import SourceService, SourceValidationError


CONTENT = b"web m1 native download fixture\x00bytes\n"
FILENAME = "fixture.txt"
KEY_ONE = "native-download-key-0001"
KEY_TWO = "native-download-key-0002"
KEY_THREE = "native-download-key-0003"
# The engine sends at most one Find per channel every 30 seconds, and that
# spacing can carry over a reconnect, so a second search may wait that long.
PACED_SEARCH_SECONDS = 50
STALL_BYTES = 16
# Engine log events printed when a native test fails.
KEY_EVENTS = re.compile(r"\t(?:DCC_\w+|CHAT_\w+|NAV_ERROR|DOWNLOAD_\w+|JOB_\w+|STATE)\t")
ACTIVE_JOB_STATES = {
    "held", "ready", "preparing", "backoff", "dispatch_intent",
    "awaiting_offer", "remote_queued", "receiving", "finalizing",
}


class DownloadFixture(ReusableIRCFixture):
    """Find responder plus one FServe session that serves a single file."""

    def __init__(self):
        super().__init__()
        self.find_times: list[float] = []   # when each @find arrived
        self.chat_offer_count = 0
        self.chat_commands: list[str] = []
        self.get_count = 0
        self.hold_file_offer = False
        self.release_file_offer = threading.Event()
        # Send only this many bytes, then wait, so a test can act mid-receipt.
        self.stall_after_bytes: int | None = None
        self.drop_after_stall = False   # close the transfer instead of waiting
        self.partial_sent = threading.Event()
        self.resume_transfer = threading.Event()
        # Further Find rows for files this server does not have (for paging).
        self.extra_results = 0
        # What the file server says in the CHAT when it gets the GET, and
        # whether it then sends nothing at all.
        self.get_reply: str | None = None
        self.refuse_get = False
        self.expect_offer_accepted = True
        # Further files in the same folder, by name.
        self.extra_files: dict[str, bytes] = {}
        # Answer the trigger with this notice and no session ("" = say nothing).
        self.trigger_notice: str | None = None
        # Send this many random bytes down the CHAT instead of a prompt: at
        # most this many a second (0 = as fast as they are taken), as text
        # lines instead, or only once a file is being received.
        self.chat_flood_bytes = 0
        self.chat_flood_rate = 0
        self.chat_flood_text = False
        self.chat_flood_during_transfer = False
        # The text line that is repeated, without its line break; and whether
        # the text comes after the prompt instead, as a listing without end.
        self.chat_flood_line = b"A line of ordinary text, as a plain text file would have many of."
        self.chat_flood_after_prompt = False
        self.chat_flood_seconds = 5.0    # how long one block may take to send
        self.chat_flood_sent = 0         # what was taken before the CHAT closed
        # Further files in the listing of the folder, ahead of the others,
        # all sent at once. They are not in the Find reply.
        self.listing_padding = 0
        # Change the file server's nick this many seconds after its CHAT
        # connects, as some away scripts do (None: never).
        self.rename_after_chat: float | None = None
        # Offer the file on the port the CHAT is on, as a one-port sender does.
        self.one_port = False
        self.chat_listener: socket.socket | None = None
        # A listener on which an untaken file offer is still waiting; the
        # CHAT is then offered on the same port, as a one-port sender does.
        self.stray_listener: socket.socket | None = None
        self.stray_connections = 0
        self.chat_closed = threading.Event()
        self.transfer_finished = threading.Event()
        # A search bot. It answers "@search" with a ZIP holding these rows;
        # the nick a row names sends that row's file when the row is posted.
        self.search_rows: list[str] = []
        self.search_count = 0
        self.search_reply_from = "SearchBot"   # who offers the result list
        self.search_reply_accepted = True
        self.row_files: dict[str, tuple[str, bytes]] = {}   # row -> (file name, content)
        self.row_requests: list[str] = []
        # Who sends a row's file, by the word the row starts with, where that
        # is not a nick: OmenServe's "!Nick-Ebooks2" rows (2026-11-02).
        self.row_sender: dict[str, str] = {}
        # Notices: what the search bot says to a search, and what a row's
        # nick says to a row it has no file for.
        self.search_notice: str | None = None
        self.row_notice: str | None = None
        # Other file servers' answers to "@find": (nick, PRIVMSG or NOTICE,
        # text), sent after the SysReset reply. A "!Nick file ::INFO:: size"
        # row is fetched by posting it, as a search bot's row is.
        self.find_replies: list[tuple[str, str, str]] = []
        # What a row's nick says before it offers the row's file, and how
        # long it then waits, as a file server that queues the request does.
        self.row_queue_notice: str | None = None
        self.row_offer_delay = 0.0
        # Speak as FServe.pl 2.0.0 for Irssi does (seen 2026-10-20): its
        # "@find" reply, a CTCP trigger, and its session's prompts, listing
        # frame and "name/" folders, with its colours.
        self.fservepl = False
        # Folders to walk, as {path: (folders, {file: content})}, with
        # SysReset's prompts and its upper-case folder names; a "get" is
        # answered as usual.
        self.tree: dict[str, tuple[list[str], dict[str, bytes]]] | None = None
        self.cwd = "/"
        # Close the session at its next "dir" this many times, before any
        # "get": a session lost before the request.
        self.drop_chat_on_dir = 0
        # A second file server, (nick, file name, content): it answers
        # "@find" with that one file under its own trigger "!<nick>", and
        # its session serves it from its books folder.
        self.second: tuple[str, str, bytes] | None = None
        self.second_trigger_count = 0
        self.second_get_count = 0
        self.chat_nick = "Fixture"
        # Offer the session at an address that refuses the connection, as
        # one server's did on 2026-10-20.
        self.chat_unreachable = False
        # List servers, as in ebook channels (2026-10-27): "@Nick" is
        # answered with the list file (name, content), after these offers,
        # (name, content), which must not be taken. Who was asked, in order.
        self.list_servers: dict[str, tuple[str, bytes]] = {}
        self.list_decoys: list[tuple[str, bytes]] = []
        # What servers answer "!list" with (2026-10-28): notices to us, and
        # lists some send unasked, with how long each waits to be taken.
        self.list_answers: list[tuple[str, str]] = []
        self.unasked_lists: dict[str, tuple[str, bytes, float]] = {}
        self.list_command_count = 0
        self.list_requests: list[str] = []
        # How many times a list server's list is cut short (2026-10-29): half
        # of it is sent, then the connection closes.
        self.list_cut: dict[str, int] = {}
        # A list asked of one nick and sent by another (2026-11-02), as an
        # advert names "@Name" and its file server's own nick sends it.
        self.list_sent_by: dict[str, str] = {}

    def _send_result_list(self, terms: str):
        name = "SearchBot_results_for__" + terms.strip().replace(" ", "_") + ".txt.zip"
        memory = io.BytesIO()
        with zipfile.ZipFile(memory, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(
                "SearchBot_results_for_ " + terms.strip() + ".txt",
                "Search results from SearchBot\r\n\r\n"
                + "".join(row + "\r\n" for row in self.search_rows))
        self.offer(self.search_reply_from, name, memory.getvalue(),
                   self.search_reply_accepted)

    def advertise(self, nick: str, text: str):
        """Say something in the channel as nick, as an advert is said."""
        self.send(f":{nick}!fixture@127.0.0.1 PRIVMSG #review :{text}".encode("latin-1"))

    def _offer_unasked(self, nick: str, name: str, content: bytes, wait: float):
        """A list offered by DCC that nothing asked for, waiting wait seconds."""
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(wait)
        port = listener.getsockname()[1]
        ip_number = struct.unpack("!I", socket.inet_aton("127.0.0.1"))[0]
        self.send(f":{nick}!fixture@127.0.0.1 PRIVMSG {self.nick} :\x01DCC SEND {name} "
                  f"{ip_number} {port} {len(content)}\x01".encode("ascii"))
        accepted = False
        try:
            connection, _ = listener.accept()
            accepted = True
            with connection:
                connection.settimeout(2.0)
                connection.sendall(content)
                try:
                    connection.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
        except socket.timeout:
            pass
        finally:
            self.offer_records.append({"sender": nick, "filename": name, "accepted": accepted,
                                       "expected_accept": None})
            listener.close()

    def _send_list(self, nick: str):
        sender = self.list_sent_by.get(nick, nick)
        for name, content in self.list_decoys:
            self.offer(sender, name, content, False)
        if self.list_cut.get(nick):
            self.list_cut[nick] -= 1
            self._offer_cut(sender, *self.list_servers[nick])
            return
        self.offer(sender, *self.list_servers[nick], True)

    def _offer_cut(self, nick: str, name: str, content: bytes):
        """Offer the whole list, send half of it and hang up."""
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(5.0)
        port = listener.getsockname()[1]
        ip_number = struct.unpack("!I", socket.inet_aton("127.0.0.1"))[0]
        self.send(f":{nick}!fixture@127.0.0.1 PRIVMSG {self.nick} :\x01DCC SEND {name} "
                  f"{ip_number} {port} {len(content)}\x01".encode("ascii"))
        accepted = False
        try:
            connection, _ = listener.accept()
            accepted = True
            with connection:
                connection.sendall(content[:len(content) // 2])
        except socket.timeout:
            pass
        finally:
            self.offer_records.append({"sender": nick, "filename": name, "accepted": accepted,
                                       "expected_accept": True})
            listener.close()

    def handle_line(self, raw: bytes):
        said = raw[len(b"PRIVMSG #review :"):]
        if raw.startswith(b"PRIVMSG #review :@") and b" " not in said:
            nick = said[1:].decode("latin-1")
            self.list_requests.append(nick)
            if nick in self.list_servers:
                threading.Thread(target=self._send_list, args=(nick,), daemon=True).start()
            return
        if raw.startswith(b"PRIVMSG #review :@search "):
            self.search_count += 1
            terms = raw[len(b"PRIVMSG #review :@search "):].decode("ascii", errors="replace")
            if self.search_notice:
                self.send(f":SearchBot!fixture@127.0.0.1 NOTICE {self.nick} "
                          f":{self.search_notice}".encode())
            if self.search_rows:
                threading.Thread(target=self._send_result_list, args=(terms,),
                                 daemon=True).start()
            return
        if raw == b"PRIVMSG #review :!list":
            self.list_command_count += 1
            for nick, said in self.list_answers:
                self.send(f":{nick}!fixture@127.0.0.1 NOTICE {self.nick} :{said}".encode("latin-1"))
            for nick, (name, content, wait) in self.unasked_lists.items():
                threading.Thread(target=self._offer_unasked, args=(nick, name, content, wait),
                                 daemon=True).start()
            return
        if self.second and raw == f"PRIVMSG #review :!{self.second[0]}".encode():
            self.second_trigger_count += 1
            self._offer_chat(self.second[0])
            return
        if (raw.startswith(b"PRIVMSG #review :!")
                and not raw.startswith(b"PRIVMSG #review :!Fixture")):
            row = raw[len(b"PRIVMSG #review :"):].decode("latin-1")
            self.row_requests.append(row)
            if row in self.row_files:
                name, content = self.row_files[row]
                word = row.split()[0][1:]
                threading.Thread(target=self._answer_row, daemon=True,
                                 args=(self.row_sender.get(word, word), name, content)).start()
            elif self.row_notice:
                self.send(f":{row.split()[0][1:]}!fixture@127.0.0.1 NOTICE {self.nick} "
                          f":{self.row_notice}".encode())
            return
        if raw.startswith(b"PRIVMSG #review :@find ") and self.fservepl:
            self.find_count += 1
            self.find_times.append(time.monotonic())
            for line in (
                "Find Results for (fixture) - [FServe.pl 2.0.0]",
                "Found 1 file(s) on trigger:(/ctcp Fixture !Fixture) Sends:(0/2000) Queues:(0/2000)",
                f"1. File: (books/{FILENAME}) Size:({len(CONTENT)} B)",
                "End of Find.",
            ):
                self.send(f":Fixture!fixture@127.0.0.1 PRIVMSG {self.nick} :{line}".encode())
            return
        # FServe.pl compares the trigger without case (uc), and Irssi's CTCP
        # command sends it in capitals.
        if raw.upper().startswith(b"PRIVMSG FIXTURE :\x01!FIXTURE") and self.fservepl:
            self.trigger_count += 1
            self._offer_chat()
            return
        if raw.startswith(b"PRIVMSG #review :@find "):
            self.find_count += 1
            self.find_times.append(time.monotonic())
            for line in (
                "[@Find Results] -= SysReset 2.55 =-",
                f"Found [{1 + len(self.extra_files) + self.extra_results}] files"
                " on Trigger:[!Fixture] - Sends:[0/1] - Queues:[0/5]",
                f"File: [\\books\\{FILENAME}] - Size [{len(CONTENT)} B]",
                *(f"File: [\\books\\{name}] - Size [{len(content)} B]"
                  for name, content in self.extra_files.items()),
                *(f"File: [\\books\\absent-{number:02}.txt] - Size [1 B]"
                  for number in range(1, self.extra_results + 1)),
                "End of @Find.",
            ):
                self.send(f":Fixture!fixture@127.0.0.1 PRIVMSG {self.nick} :{line}".encode())
            for nick, command, text in self.find_replies:
                self.send(f":{nick}!fixture@127.0.0.1 {command} {self.nick} :{text}".encode())
            if self.second:
                nick, name, content = self.second
                for line in ("[@Find Results] -= SysReset 2.55 =-",
                             f"Found [1] files on Trigger:[!{nick}] - Sends:[0/1] - Queues:[0/5]",
                             f"File: [\\books\\{name}] - Size [{len(content)} B]",
                             "End of @Find."):
                    self.send(f":{nick}!fixture@127.0.0.1 PRIVMSG {self.nick} :{line}".encode())
            return
        if raw.startswith(b"PRIVMSG #review :!Fixture"):
            self.trigger_count += 1
            if self.trigger_notice is not None:
                if self.trigger_notice:
                    self.send(f":Fixture!fixture@127.0.0.1 NOTICE {self.nick} "
                              f":{self.trigger_notice}".encode("latin-1"))
                return
            self._offer_chat()
            return
        super().handle_line(raw)

    def _answer_row(self, nick, name, content):
        if self.row_queue_notice:
            self.send(f":{nick}!fixture@127.0.0.1 NOTICE {self.nick} "
                      f":{self.row_queue_notice}".encode())
        if self.row_offer_delay:
            time.sleep(self.row_offer_delay)
        self.offer(nick, name, content, True)

    def offer_stray_file(self):
        """Offer a file nobody asked for and leave the offer waiting."""
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(4)
        self.stray_listener = listener
        ip_number = struct.unpack("!I", socket.inet_aton("127.0.0.1"))[0]
        ctcp = f"\x01DCC SEND stray.bin {ip_number} {listener.getsockname()[1]} 1000\x01"
        self.send(f":Fixture!fixture@127.0.0.1 PRIVMSG {self.nick} :{ctcp}".encode())

    def _watch_stray_port(self, listener):
        try:
            connection, _ = listener.accept()
            self.stray_connections += 1
            connection.close()
        except (socket.timeout, OSError):
            pass
        finally:
            self.chat_closed.set()

    def _offer_chat(self, nick: str = "Fixture"):
        self.chat_offer_count += 1
        self.chat_nick = nick
        if self.chat_unreachable:
            closed = socket.socket()
            closed.bind(("127.0.0.1", 0))
            port = closed.getsockname()[1]
            closed.close()      # nothing listens there any more
            ip_number = struct.unpack("!I", socket.inet_aton("127.0.0.1"))[0]
            ctcp = f"\x01DCC CHAT chat {ip_number} {port}\x01"
            self.send(f":{nick}!fixture@127.0.0.1 PRIVMSG {self.nick} :{ctcp}".encode())
            return
        if self.stray_listener is not None:
            listener = self.stray_listener
            ip_number = struct.unpack("!I", socket.inet_aton("127.0.0.1"))[0]
            ctcp = f"\x01DCC CHAT chat {ip_number} {listener.getsockname()[1]}\x01"
            self.send(f":Fixture!fixture@127.0.0.1 PRIVMSG {self.nick} :{ctcp}".encode())
            threading.Thread(target=self._watch_stray_port, args=(listener,), daemon=True).start()
            return
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(8)
        ip_number = struct.unpack("!I", socket.inet_aton("127.0.0.1"))[0]
        ctcp = f"\x01DCC CHAT chat {ip_number} {listener.getsockname()[1]}\x01"
        self.chat_listener = listener
        self.send(f":{nick}!fixture@127.0.0.1 PRIVMSG {self.nick} :{ctcp}".encode())
        threading.Thread(target=self._serve_chat, args=(listener,), daemon=True).start()

    def _flood(self, connection):
        """What the lab's file server did: the file, down the CHAT."""
        connection.settimeout(self.chat_flood_seconds)
        rate = self.chat_flood_rate
        most = max(1, min(65536, rate // 50)) if rate else 65536
        line = self.chat_flood_line + b"\r\n"
        left = self.chat_flood_bytes
        if self.chat_flood_text:    # whole lines only
            most = max(1, most // len(line)) * len(line)
            left = -(-left // len(line)) * len(line)
        text = line * (most // len(line) + 1)
        started = time.monotonic()
        while left > 0 and not self.stopped.is_set():
            size = min(left, most)
            connection.sendall(text[:size] if self.chat_flood_text else os.urandom(size))
            left -= size
            self.chat_flood_sent += size
            if rate:
                ahead = self.chat_flood_sent / rate - (time.monotonic() - started)
                if ahead > 0:
                    time.sleep(ahead)
        connection.settimeout(.15)

    def _serve_chat(self, listener):
        connection = None
        flooded = False
        try:
            connection, _ = listener.accept()
            connection.settimeout(.15)
            if self.rename_after_chat is not None:
                time.sleep(self.rename_after_chat)
                self.send(b":Fixture!fixture@127.0.0.1 NICK :Fixture|away")
                time.sleep(.5)      # Irssi takes the change before what follows
            if self.chat_flood_after_prompt:
                flooded = True      # by the reply to "dir"
                connection.sendall(b"[\\]\r\n")
            elif self.chat_flood_bytes and not self.chat_flood_during_transfer:
                flooded = True
                self._flood(connection)
            elif self.fservepl:
                connection.sendall(
                    b"\x0312FServe 2.0.0 for Irssi\r\n\x0312-\r\n"
                    b"\x0312Commands: ls dir cd get read dequeue clr_queue queue sends\r\n"
                    b"\x0312Current/Free/Max Sends: 0/2000/2000\r\n\x0312-\r\n"
                    b"\x0312[\\]\r\n")
            else:
                self.cwd = "/"
                connection.sendall(b"[\\]\r\n")
            pending = bytearray()
            while not self.stopped.is_set():
                if self.chat_flood_bytes and not flooded and self.partial_sent.is_set():
                    flooded = True
                    self._flood(connection)
                try:
                    chunk = connection.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                pending.extend(chunk)
                while b"\n" in pending:
                    line, _, tail = pending.partition(b"\n")
                    pending = bytearray(tail)
                    command = line.rstrip(b"\r").decode("ascii", errors="replace").strip()
                    if command:
                        self._chat_command(connection, command)
        except socket.timeout:
            self.errors.append("Irssi did not connect to the offered FServe CHAT")
        except OSError:
            pass
        finally:
            self.chat_closed.set()
            # A one-port sender's listener goes on to take the file transfer.
            for item in (connection, None if self.one_port else listener):
                try:
                    if item is not None:
                        item.close()
                except OSError:
                    pass

    @staticmethod
    def _prompt(path: str, tail: str = "") -> bytes:
        parts = [part for part in path.split("/") if part]
        return ("[\\" + "".join(part + "\\" for part in parts) + tail + "]\r\n").encode()

    def _tree_command(self, connection, command: str) -> bool:
        """A command of a session over self.tree; False for one it does not answer."""
        lowered = command.lower()
        if lowered == "cd..":
            self.cwd = self.cwd.rsplit("/", 1)[0] or "/"
            connection.sendall(self._prompt(self.cwd))
        elif lowered.startswith("cd "):
            target = self.cwd.rstrip("/") + "/" + command[3:]
            if target not in self.tree:
                connection.sendall(b"Invalid directory\r\n")
                return True
            self.cwd = target
            connection.sendall(self._prompt(self.cwd))
        elif lowered == "dir":
            folders, files = self.tree[self.cwd]
            connection.sendall(self._prompt(self.cwd, "*.*") + "".join(
                [folder + "\r\n" for folder in folders] +
                [f"{name} {len(content)}B\r\n" for name, content in files.items()] +
                ["End of list\r\n"]).encode())
        else:
            return False
        return True

    def _chat_command(self, connection, command: str):
        self.chat_commands.append(command)
        lowered = command.lower()
        if self.second and self.chat_nick == self.second[0]:
            nick, name, content = self.second
            if lowered == "cd books":
                connection.sendall(b"[\\books\\]\r\n")
            elif lowered == "dir":
                connection.sendall(f"[\\books\\*.*]\r\n{name} {len(content)}B\r\n"
                                   "End of list\r\n".encode())
            elif lowered == "get " + name.lower():
                self.second_get_count += 1
                threading.Thread(target=self.offer, daemon=True,
                                 args=(nick, name, content, True)).start()
            return
        if lowered == "dir" and self.drop_chat_on_dir > 0:
            self.drop_chat_on_dir -= 1
            raise ConnectionAbortedError("the fixture drops the session")
        if self.tree is not None and self._tree_command(connection, command):
            return
        if self.fservepl and command == "cd books":
            connection.sendall(b"\x0312[\x0303/books\x0312]\r\n")
            return
        if self.fservepl and lowered == "dir":
            connection.sendall(
                b"\x0312Listing [\x0303/books/*.*\x0312]\r\n\x0312\x0304..\r\n"
                b"\x0312\x0304Older editions\x0312/\r\n"
                + f"\x0312\x0305{FILENAME}  {len(CONTENT)} B\r\n".encode()
                + b"\x0312End [\x0303/books\x0312]\r\n")
            return
        if lowered == "cd books":
            connection.sendall(b"[\\books\\]\r\n")
        elif lowered == "dir":
            connection.sendall(b"[\\books\\*.*]\r\n")
            if self.chat_flood_after_prompt and self.chat_flood_bytes:
                self._flood(connection)
            padding = "".join(f"another-file-in-the-folder-{number:06}.bin 1048576B\r\n"
                              for number in range(1, self.listing_padding + 1))
            listing = "".join(f"{name} {len(content)}B\r\n"
                              for name, content in self.extra_files.items())
            connection.settimeout(self.chat_flood_seconds)   # a long listing takes a while
            connection.sendall(
                f"{padding}{FILENAME} {len(CONTENT)}B\r\n{listing}End of list\r\n".encode())
            connection.settimeout(.15)
        elif lowered == "get " + FILENAME:
            self.get_count += 1
            if self.get_reply is not None:
                connection.sendall(self.get_reply.encode("latin-1") + b"\r\n")
            if not self.refuse_get:
                threading.Thread(target=self._send_file, daemon=True).start()
        elif lowered.startswith("get ") and command[4:] in self.extra_files:
            self.get_count += 1
            name = command[4:]
            threading.Thread(target=self.offer, daemon=True,
                             args=("Fixture", name, self.extra_files[name], True)).start()

    def declines(self) -> int:
        """How many times the client declined a file offer (DCC REJECT)."""
        return sum(1 for line in self.lines if b"\x01DCC REJECT SEND " in bytes(line))

    def _send_file(self):
        if self.hold_file_offer and not self.release_file_offer.wait(120):
            return
        if self.stopped.is_set():
            return
        if self.stall_after_bytes is None:
            self.offer("Fixture", FILENAME, CONTENT, self.expect_offer_accepted)
        else:
            self._offer_stalling(self.stall_after_bytes)
        self.transfer_finished.set()

    def _offer_stalling(self, first_bytes: int):
        """DCC SEND that pauses after its first bytes until told to resume."""
        if self.one_port and self.chat_listener is not None:
            listener = self.chat_listener
        else:
            listener = socket.socket()
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
        listener.settimeout(8)
        ip_number = struct.unpack("!I", socket.inet_aton("127.0.0.1"))[0]
        ctcp = f"\x01DCC SEND {FILENAME} {ip_number} {listener.getsockname()[1]} {len(CONTENT)}\x01"
        self.send(f":Fixture!fixture@127.0.0.1 PRIVMSG {self.nick} :{ctcp}".encode())
        try:
            connection, _ = listener.accept()
            with connection:
                connection.sendall(CONTENT[:first_bytes])
                self.partial_sent.set()
                if self.drop_after_stall:
                    time.sleep(.5)   # let the receiver take the bytes first
                elif self.resume_transfer.wait(120) and not self.stopped.is_set():
                    connection.sendall(CONTENT[first_bytes:])
        except socket.timeout:
            self.errors.append("Irssi did not accept the stalling DCC offer")
        except OSError:
            pass  # the receiver closed first, as a cancelled transfer does
        finally:
            listener.close()


class RestartableIrssi(NativeIrssi):
    """Native Irssi whose process can be killed and restarted on one home."""

    def restart(self):
        self.process.kill()
        self.process.wait(timeout=5)
        self.stopped.set()
        self.reader.join(timeout=1)
        os.close(self.master)
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


class ReplyDroppingEngine:
    """Forward every request, then lose the reply of the named operations."""

    def __init__(self, engine):
        self._engine = engine
        self.drop_reply_once: set[str] = set()

    def __getattr__(self, name):
        return getattr(self._engine, name)

    async def request(self, operation, arguments=None, **options):
        result = await self._engine.request(operation, arguments, **options)
        if operation in self.drop_reply_once:
            self.drop_reply_once.discard(operation)
            raise TimeoutError("fixture lost the engine reply")
        return result


# Irssi's own traffic: it asks for a channel's modes some time after
# joining, and sends and answers keepalives. A check that nothing was sent
# leaves these out, or it races with Irssi.
IRSSI_OWN_LINES = (b"MODE ", b"WHO ", b"PING ", b"PONG ")


def lines_sent(fixture) -> int:
    """Lines the client sent, other than Irssi's own channel queries and keepalives."""
    return sum(1 for line in fixture.lines if not bytes(line).startswith(IRSSI_OWN_LINES))


async def open_engine(native, timeout=10):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return await EngineClient.open(str(native.path))
        except (OSError, asyncio.TimeoutError):
            if time.monotonic() >= deadline:
                raise
            await asyncio.sleep(.1)


async def ready_services(database: Path, engine, fixture):
    sources = SourceService(database, engine)
    await sources.save(source_values(fixture.port))
    await sources.connect()
    await wait_source(engine, {"ready"})
    searches = SearchService(sources)
    await searches.startup()
    return sources, searches, DownloadService(sources, searches)


async def selectable_result(searches: SearchService, timeout: float = 12) -> str:
    search = await searches.search("fixture")
    search = await wait_search(searches, search["search_id"], timeout=timeout)
    assert search["state"] == "complete", search
    page = await searches.page(search["search_id"], offset=0, limit=10)
    result_id = page["results"][0]["result_id"]
    assert result_id, page
    return result_id


async def result_on_new_connection(sources, searches, engine) -> str:
    """Reconnect, then search again: the engine allows one request per server
    and file name on a connection, so a repeat needs a fresh one."""
    await sources.disconnect()
    await wait_source(engine, {"disconnected"})
    await sources.connect()
    await wait_source(engine, {"ready"})
    return await selectable_result(searches, timeout=PACED_SEARCH_SECONDS)


async def wait_source_by_id(engine, source_id: str, states: set, timeout: float = 15):
    deadline = time.monotonic() + timeout
    source = None
    while time.monotonic() < deadline:
        source = SourceService.engine_source(await engine.status(), source_id)
        if source and source["state"] in states:
            return source
        await asyncio.sleep(.05)
    raise AssertionError(f"source {source_id} did not reach {states}: {source!r}")


async def wait_download(downloads: DownloadService, operation_id: str, predicate,
                        label: str, timeout: float = 30):
    deadline = time.monotonic() + timeout
    status = None
    while time.monotonic() < deadline:
        status = await downloads.status(operation_id)
        if predicate(status):
            return status
        await asyncio.sleep(.2)
    raise AssertionError(f"timed out waiting for {label}: {status!r}")


async def wait_true(predicate, label: str, timeout: float = 20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        await asyncio.sleep(.1)
    raise AssertionError("timed out waiting for " + label)


class StatusWatch:
    """Asks the engine for its status all the while; keeps the longest wait.

    A busy host holds up every process, not only the engine. So the watch
    also runs a sleeper thread of its own, and how late it woke at worst is
    the host's own delay: a bound is that much longer (twice it), so a test
    fails on an engine that stopped answering, not on a busy machine. A
    container held to a share of a CPU is paused in slices too short for the
    sleeper to notice; the time it was held back, as its cgroup counts it, is
    added as well.
    """

    PROBE_SECONDS = 0.02
    CPU_STAT = Path("/sys/fs/cgroup/cpu.stat")

    def __init__(self, engine, limit: float = 60):
        self.engine = engine
        self.limit = limit
        self.longest = 0.0
        self.host_delay = 0.0
        self.held_back = 0.0
        self._held_at_start = self._throttled()
        self._leaving = False
        self._asking = None
        self._probe = threading.Thread(target=self._sleep_and_time, daemon=True)

    def _sleep_and_time(self):
        while not self._leaving:
            began = time.monotonic()
            time.sleep(self.PROBE_SECONDS)
            self.host_delay = max(self.host_delay,
                                  time.monotonic() - began - self.PROBE_SECONDS)

    @classmethod
    def _throttled(cls) -> float:
        """Seconds this container's CPU quota has held it back, or 0."""
        try:
            for line in cls.CPU_STAT.read_text().splitlines():
                name, _, value = line.partition(" ")
                if name == "throttled_usec":
                    return int(value) / 1e6
        except (OSError, ValueError):
            pass
        return 0.0

    def bound(self, seconds: float) -> float:
        return seconds + 2 * self.host_delay + self.held_back

    def check(self, case, seconds: float, message: str) -> None:
        case.assertLess(self.longest, self.bound(seconds),
                        f"{message} (longest wait {self.longest:.2f} s; "
                        f"the host itself ran up to {self.host_delay:.2f} s late, "
                        f"and held the container back {self.held_back:.2f} s)")

    async def _ask(self):
        while not self._leaving:
            began = time.monotonic()
            await self.engine.status(timeout=self.limit)
            self.longest = max(self.longest, time.monotonic() - began)
            await asyncio.sleep(.05)

    async def __aenter__(self):
        self._probe.start()
        self._asking = asyncio.create_task(self._ask())
        return self

    async def __aexit__(self, kind, error, trace):
        self._leaving = True
        if kind is None:
            await self._asking     # a wait still running is counted too
        else:
            self._asking.cancel()
        self._probe.join(1)
        self.held_back = self._throttled() - self._held_at_start


def published_files(native) -> list[str]:
    """Finished files under the download root, relative to it; staging is excluded."""
    root = native.home / "fserve-poc" / "downloads"
    return [path.relative_to(root).as_posix() for path in root.rglob("*")
            if path.is_file() and not any(part.startswith(".") for part in
                                          path.relative_to(root).parts)]


def kept_lists(native) -> list[str]:
    """Lists and result lists kept in the lists folder (2026-10-28)."""
    root = native.home / "fserve-poc" / "lists"
    return [path.relative_to(root).as_posix() for path in root.rglob("*")
            if path.is_file() and not any(part.startswith(".") for part in
                                          path.relative_to(root).parts)]


def staged_files(native) -> list[tuple[str, int]]:
    """Unfinished data in the staging area: (name, size) of each file."""
    root = native.home / "fserve-poc" / "downloads" / ".incoming"
    return sorted((path.name, path.stat().st_size) for path in root.rglob("*") if path.is_file())


def journal_text(native) -> str:
    state = native.home / "fserve-poc" / "phase6"
    return "\n".join(path.read_text(encoding="utf-8", errors="replace")
                     for path in sorted(state.rglob("*")) if path.is_file())


class WebDownloadNativeTests(unittest.TestCase):
    def run_native(self, workflow, *, fixture: DownloadFixture, settings=()):
        fixture.start()
        try:
            with RestartableIrssi() as native:
                native.command("/set fscrawl_find_quiet_ms 250")
                for setting in settings:
                    native.command("/set " + setting)
                native.command("/set dcc_autoget OFF")
                native.command("/set dcc_autochat OFF")
                with tempfile.TemporaryDirectory() as directory:
                    try:
                        asyncio.run(workflow(native, Path(directory) / "fserve.sqlite3"))
                    except BaseException:
                        print(f"fixture lines={fixture.lines[-12:]!r} "
                              f"chat={fixture.chat_commands!r} errors={fixture.errors!r}",
                              flush=True)
                        print(native.transcript[-6000:].decode(errors="replace"), flush=True)
                        for record in sorted((native.home / "fserve-poc").glob("transcript-*.tsv")):
                            text = record.read_text(errors="replace")
                            print(record.name, text[-3000:], sep="\n", flush=True)
                            # A long listing fills the tail; what the engine
                            # decided about offers and sessions is kept here.
                            events = [line for line in text.splitlines()
                                      if KEY_EVENTS.search(line)]
                            print(f"{record.name}, key events:", *events[-60:],
                                  sep="\n", flush=True)
                        raise
            self.assertFalse(fixture.errors, fixture.errors)
        finally:
            fixture.release_file_offer.set()
            fixture.resume_transfer.set()
            fixture.stop()

    def test_one_download_completes_once_and_closes_its_chat(self):
        fixture = DownloadFixture()

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                started = await downloads.download(KEY_ONE, result_id)
                operation_id = started["operation_id"]
                self.assertRegex(started["job_id"] or "", r"\Ajob-[0-9a-f]{32}\Z", started)
                self.assertIn(started["state"], ACTIVE_JOB_STATES, started)

                with self.assertRaises(DownloadError) as busy:
                    await downloads.download(KEY_TWO, result_id)
                self.assertEqual(busy.exception.code, "download_busy")
                with self.assertRaises(DownloadError) as conflict:
                    await downloads.download(KEY_ONE, "row-" + "0" * 32)
                self.assertEqual(conflict.exception.code, "idempotency_conflict")

                complete = await wait_download(
                    downloads, operation_id, lambda row: row["state"] == "complete",
                    "completed download")
                self.assertEqual(complete["job_id"], started["job_id"])
                self.assertEqual(complete["sender"], "Fixture")
                self.assertEqual(complete["name"], FILENAME)
                self.assertEqual((complete["bytes_received"], complete["total_bytes"]),
                                 (len(CONTENT), len(CONTENT)), "a finished file shows its size")
                self.assertFalse(complete["abandonable"])

                # The fresh live-parent listing precedes exactly one GET.
                self.assertEqual(
                    [command.lower() for command in fixture.chat_commands[:3]],
                    ["cd books", "dir", "get " + FILENAME], fixture.chat_commands)
                self.assertEqual((fixture.trigger_count, fixture.get_count), (1, 1))

                relative = complete["download_path"]
                self.assertTrue(relative, complete)
                self.assertFalse(Path(relative).is_absolute(), relative)
                self.assertNotIn("..", Path(relative).parts)
                self.assertEqual(Path(relative).parts[0], "127.0.0.1",
                                 "the directory is the configured host, not a connection tag")
                published = native.home / "fserve-poc" / "downloads" / relative
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual(complete["total_bytes"], len(CONTENT))

                replay = await downloads.download(KEY_ONE, result_id)
                self.assertEqual(
                    (replay["operation_id"], replay["job_id"], replay["state"]),
                    (operation_id, started["job_id"], "complete"))
                self.assertEqual((await downloads.cancel(operation_id))["state"], "complete")

                # The browser owns one fetch, not an interactive session.
                await wait_true(fixture.chat_closed.is_set, "adapter closes the idle FServe CHAT")
                found = await engine.request(
                    "job.find_by_operation", {"web_operation_id": operation_id})
                self.assertEqual(found["job"]["job_id"], started["job_id"])
                self.assertEqual(found["job"]["state"], "complete")
                self.assertIn(operation_id, journal_text(native))
                # The web's retry before the request is on by default (2026-10-22).
                self.assertIn('"pre_dispatch_recovery_enabled":1', journal_text(native))

                # The engine allows one request per server and file name on a
                # connection, so asking again is refused before anything is sent.
                refused = await downloads.download(KEY_TWO, result_id)
                self.assertEqual((refused["state"], refused["outcome"]),
                                 ("stale", "tuple_preflight_refused"), refused)
                self.assertEqual(downloads.store.active(), [], "a refusal does not take the slot")
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))

                # On a new connection the same file can be fetched again. The
                # second copy gets a numbered name; the first is left untouched.
                fixture.chat_closed.clear()
                fresh = await result_on_new_connection(sources, searches, engine)
                again = await downloads.download(KEY_THREE, fresh)
                second = await wait_download(
                    downloads, again["operation_id"],
                    lambda row: row["state"] == "complete", "a repeat download")
                self.assertEqual(Path(second["download_path"]).name, "fixture-1.txt")
                self.assertEqual(Path(second["download_path"]).parent, Path(relative).parent)
                for copy in (relative, second["download_path"]):
                    self.assertEqual(
                        (native.home / "fserve-poc" / "downloads" / copy).read_bytes(), CONTENT)
                self.assertEqual(sorted(published_files(native)),
                                 sorted([relative, second["download_path"]]))
                await wait_true(fixture.chat_closed.is_set, "adapter closes the idle FServe CHAT")

                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (2, 2, 2, 2))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_lost_dispatch_reply_reconciles_without_replay_then_cancels(self):
        fixture = DownloadFixture()
        fixture.hold_file_offer = True

        async def workflow(native, database):
            client = await open_engine(native)
            engine = ReplyDroppingEngine(client)
            searches = restarted_searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                engine.drop_reply_once.add("search.download")
                uncertain = await downloads.download(KEY_ONE, result_id)
                operation_id = uncertain["operation_id"]
                self.assertEqual(
                    (uncertain["state"], uncertain["outcome"], uncertain["job_id"]),
                    ("needs_attention", "dispatch_outcome_unknown", None))
                with self.assertRaises(DownloadError) as busy:
                    await downloads.download(KEY_TWO, result_id)
                self.assertEqual(busy.exception.code, "download_busy")

                found = await downloads.status(operation_id)
                self.assertRegex(found["job_id"] or "", r"\Ajob-[0-9a-f]{32}\Z", found)
                self.assertIn(found["state"], ACTIVE_JOB_STATES, found)
                self.assertFalse(found["abandonable"])
                with self.assertRaises(DownloadError) as retire:
                    await downloads.resolve_uncertain(
                        operation_id,
                        confirmation=downloads.uncertain_resolution_phrase(operation_id))
                self.assertEqual(retire.exception.code, "not_resolvable")
                repeated = await downloads.download(KEY_ONE, result_id)
                self.assertEqual(repeated["job_id"], found["job_id"])

                await wait_true(lambda: fixture.get_count == 1, "single GET reaches the server")

                # Application restart: new service objects over the same ledger.
                await searches.close()
                searches = None
                restarted_sources = SourceService(database, engine)
                await restarted_sources.startup()
                restarted_searches = SearchService(restarted_sources)
                await restarted_searches.startup()
                restarted = DownloadService(restarted_sources, restarted_searches)
                reconciled = await restarted.startup()
                self.assertEqual([row["job_id"] for row in reconciled], [found["job_id"]])
                self.assertIn(reconciled[0]["state"], ACTIVE_JOB_STATES, reconciled)

                engine.drop_reply_once.add("job.cancel")
                lost_cancel = await restarted.cancel(operation_id)
                self.assertEqual(lost_cancel["outcome"], "cancel_outcome_unknown", lost_cancel)
                cancelled = await restarted.status(operation_id)
                self.assertEqual(cancelled["state"], "cancelled", cancelled)
                self.assertEqual((await restarted.cancel(operation_id))["state"], "cancelled")
                self.assertEqual(restarted.store.active(), [])

                await wait_true(fixture.chat_closed.is_set, "cancelled session closes its CHAT")
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))
                downloads_root = native.home / "fserve-poc" / "downloads"
                self.assertFalse([path for path in downloads_root.rglob(FILENAME)
                                  if path.is_file()])
            finally:
                for service in (searches, restarted_searches):
                    if service is not None:
                        await service.close()
                await client.close()

        self.run_native(workflow, fixture=fixture)

    def test_engine_restart_keeps_operation_lookup_and_never_resends(self):
        fixture = DownloadFixture()
        fixture.hold_file_offer = True

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)
                started = await downloads.download(KEY_ONE, result_id)
                operation_id = started["operation_id"]
                first_instance = engine.engine_instance_id
                await wait_true(lambda: fixture.get_count == 1, "single GET reaches the server")
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

            native.restart()
            engine = await open_engine(native)
            searches = None
            try:
                self.assertNotEqual(engine.engine_instance_id, first_instance)
                sources = SourceService(database, engine)
                await sources.startup()
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)

                found = await engine.request(
                    "job.find_by_operation", {"web_operation_id": operation_id})
                self.assertEqual(found["job"]["job_id"], started["job_id"], found)
                duplicate = await engine.request(
                    "search.download",
                    {"source_id": "primary", "search_id": "find-gone-1",
                     "selection_id": "sel-" + "0" * 40},
                    operation_id=operation_id)
                self.assertEqual(duplicate["job"]["job_id"], started["job_id"], duplicate)

                reconciled = await downloads.startup()
                self.assertEqual([row["job_id"] for row in reconciled], [started["job_id"]])
                self.assertNotEqual(reconciled[0]["state"], "complete", reconciled)
                with self.assertRaises(DownloadError) as stale:
                    await downloads.download(KEY_TWO, result_id)
                self.assertIn(stale.exception.code, {"stale_result", "download_busy"})

                if reconciled[0]["state"] not in ("cancelled", "failed", "stale", "expired"):
                    settled = await downloads.cancel(operation_id)
                    self.assertEqual(settled["state"], "cancelled", settled)
                self.assertEqual(downloads.store.active(), [])
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_engine_failure_during_receipt_is_never_shown_as_complete(self):
        fixture = DownloadFixture()
        fixture.stall_after_bytes = STALL_BYTES

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)
                started = await downloads.download(KEY_ONE, result_id)
                operation_id = started["operation_id"]
                await wait_true(fixture.partial_sent.is_set, "the first bytes are sent")
                receiving = await wait_download(
                    downloads, operation_id,
                    lambda row: row["state"] == "receiving" and row["bytes_received"],
                    "a receipt in progress with its byte count")
                self.assertEqual(
                    (receiving["bytes_received"], receiving["total_bytes"]),
                    (STALL_BYTES, len(CONTENT)), "progress is what has reached the disk")
                self.assertIsNone(receiving["download_path"], receiving)
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

            native.restart()
            engine = await open_engine(native)
            searches = None
            try:
                sources = SourceService(database, engine)
                await sources.startup()
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                await downloads.startup()
                reconciled = await downloads.status(operation_id)
                self.assertEqual(reconciled["job_id"], started["job_id"], reconciled)
                self.assertEqual(
                    (reconciled["state"], reconciled["outcome"]),
                    ("interrupted", "restart_recovery"), reconciled)
                self.assertIsNone(reconciled["download_path"], reconciled)
                self.assertFalse(reconciled["abandonable"],
                                 "the engine still knows the job, so it is cancelled, not retired")
                self.assertEqual(published_files(native), [], "nothing is published")
                self.assertEqual(staged_files(native), [(FILENAME, STALL_BYTES)],
                                 "the received bytes stay in the staging area")
                with self.assertRaises(DownloadError) as refused:
                    await downloads.download(KEY_TWO, result_id)
                self.assertIn(refused.exception.code, {"stale_result", "download_busy"})

                settled = await downloads.cancel(operation_id)
                self.assertEqual(settled["state"], "cancelled", settled)
                self.assertIsNone(settled["download_path"], settled)
                self.assertEqual(downloads.store.active(), [])
                self.assertEqual(published_files(native), [])
                self.assertEqual(staged_files(native), [(FILENAME, STALL_BYTES)],
                                 "cancelling deletes nothing")
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_selection_absent_from_the_live_listing_is_refused_and_settles(self):
        fixture = DownloadFixture()
        fixture.extra_results = 1   # a Find row for a file the server does not have

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                search = await searches.search("fixture")
                search = await wait_search(searches, search["search_id"])
                page = await searches.page(search["search_id"], offset=0, limit=10)
                present, absent = (row["result_id"] for row in page["results"])
                self.assertEqual(page["results"][1]["path"], "/books/absent-01.txt")

                started = await downloads.download(KEY_ONE, absent)
                refused = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] == "stale", "the refused selection")
                self.assertEqual(refused["outcome"], "live_parent_file_missing", refused)
                self.assertIsNone(refused["download_path"], refused)
                # The fresh listing was read and no GET followed it.
                self.assertEqual(
                    [command.lower() for command in fixture.chat_commands], ["cd books", "dir"])
                self.assertEqual(fixture.get_count, 0)
                self.assertEqual(downloads.store.active(), [], "a refusal frees the slot")
                # The engine closes the browser-owned session by itself, so the
                # next request is not refused as busy.
                await wait_true(fixture.chat_closed.is_set, "refused session closes its CHAT")
                fixture.chat_closed.clear()

                again = await downloads.download(KEY_TWO, present)
                complete = await wait_download(
                    downloads, again["operation_id"],
                    lambda row: row["state"] == "complete", "the next download", timeout=75)
                self.assertEqual(Path(complete["download_path"]).name, FILENAME)
                self.assertEqual(published_files(native), [complete["download_path"]])
                await wait_true(fixture.chat_closed.is_set, "adapter closes the idle FServe CHAT")
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 2, 2, 1))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_dropped_and_cancelled_receipts_leave_the_engine_usable(self):
        fixture = DownloadFixture()
        fixture.stall_after_bytes = STALL_BYTES
        fixture.drop_after_stall = True

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                # The sender closes the transfer part-way: interrupted, and
                # the slot stays taken until the operator cancels the job.
                dropped = await downloads.download(KEY_ONE, result_id)
                interrupted = await wait_download(
                    downloads, dropped["operation_id"],
                    lambda row: row["state"] == "interrupted", "the interrupted receipt")
                self.assertEqual(
                    (interrupted["bytes_received"], interrupted["total_bytes"]),
                    (STALL_BYTES, len(CONTENT)), interrupted)
                self.assertIsNone(interrupted["download_path"], interrupted)
                self.assertFalse(interrupted["abandonable"])
                self.assertEqual(published_files(native), [])
                self.assertEqual(staged_files(native), [(FILENAME, STALL_BYTES)])
                await wait_true(fixture.chat_closed.is_set, "interrupted session closes its CHAT")
                with self.assertRaises(DownloadError) as busy:
                    await downloads.download(KEY_TWO, result_id)
                self.assertEqual(busy.exception.code, "download_busy")
                retired = await downloads.cancel(dropped["operation_id"])
                self.assertEqual(retired["state"], "cancelled", retired)
                self.assertEqual(downloads.store.active(), [])

                # Retrying on the same connection is refused, also after a cancel.
                refused = await downloads.download(KEY_TWO, result_id)
                self.assertEqual((refused["state"], refused["outcome"]),
                                 ("stale", "tuple_preflight_refused"), refused)
                self.assertEqual((fixture.trigger_count, fixture.get_count), (1, 1))

                # On a new connection, the operator cancels while bytes arrive.
                fixture.drop_after_stall = False
                fixture.partial_sent.clear()
                fixture.chat_closed.clear()
                result_id = await result_on_new_connection(sources, searches, engine)
                started = await downloads.download(KEY_THREE, result_id)
                operation_id = started["operation_id"]
                await wait_true(fixture.partial_sent.is_set, "the first bytes are sent")
                await wait_download(
                    downloads, operation_id, lambda row: row["state"] == "receiving",
                    "a receipt in progress")
                await downloads.cancel(operation_id)
                cancelled = await wait_download(
                    downloads, operation_id, lambda row: row["state"] == "cancelled",
                    "the cancelled receipt")
                self.assertIsNone(cancelled["download_path"], cancelled)
                self.assertEqual(published_files(native), [], "a cancelled receipt publishes nothing")
                self.assertEqual(downloads.store.active(), [])
                self.assertEqual(
                    [name for name, _size in staged_files(native)], [FILENAME, FILENAME],
                    "both unfinished receipts stay in the staging area")

                # The cancel also ends the browser-owned FServe session. Left
                # open, it would refuse the next search, download and
                # disconnect until the server closed the CHAT.
                fixture.resume_transfer.set()
                await wait_true(fixture.chat_closed.is_set, "cancelled session closes its CHAT")

                # A file server may offer a cancelled file again. With no
                # session open the offer is declined, which frees the server's
                # slot at once, and never taken. An offer for anything else
                # is left alone as before, and one job is answered three
                # times at most.
                self.assertEqual(fixture.declines(), 0)
                await asyncio.to_thread(fixture.offer, "Fixture", FILENAME, CONTENT, False)
                await wait_true(lambda: fixture.declines() == 1, "the re-offer is declined")
                await asyncio.to_thread(fixture.offer, "Fixture", "never-asked.txt", b"x", False)
                await asyncio.to_thread(fixture.offer, "Stranger", FILENAME, CONTENT, False)
                await asyncio.sleep(.5)
                self.assertEqual(fixture.declines(), 1)
                # One at a time: Irssi replaces a waiting offer by a newer one
                # of the same name from the same nick, so offers sent at once
                # are not each answered.
                for declined in (2, 3):
                    await asyncio.to_thread(fixture.offer, "Fixture", FILENAME, CONTENT, False)
                    await wait_true(lambda: fixture.declines() >= declined,
                                    f"{declined} declines in all")
                await asyncio.to_thread(fixture.offer, "Fixture", FILENAME, CONTENT, False)
                await asyncio.sleep(1)
                self.assertEqual(fixture.declines(), 3)
                self.assertEqual(published_files(native), [])
                self.assertEqual(
                    [name for name, _size in staged_files(native)], [FILENAME, FILENAME])

                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (2, 2, 2, 2))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_two_sources_are_connected_searched_and_removed_independently(self):
        first, second = DownloadFixture(), DownloadFixture()
        second.start()

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(first.port))
                added = await sources.create(source_values(second.port, label="Second"))
                second_id = added["source_id"]
                self.assertEqual(
                    [source["source_id"] for source in (await engine.status())["sources"]],
                    sorted(["primary", second_id]))
                with self.assertRaises(SourceValidationError):
                    await sources.create(source_values(second.port, label="Same endpoint"))

                await sources.connect()
                await sources.connect(second_id)
                await wait_source_by_id(engine, "primary", {"ready"})
                connected = await wait_source_by_id(engine, second_id, {"ready"})
                self.assertNotEqual(
                    connected["server_tag"],
                    SourceService.engine_source(await engine.status(), "primary")["server_tag"])
                self.assertEqual((first.accept_count, second.accept_count), (1, 1))

                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                search = await searches.search("fixture", second_id)
                search = await wait_search(searches, search["search_id"])
                self.assertEqual((search["state"], search["source_id"]), ("complete", second_id))
                page = await searches.page(search["search_id"], offset=0, limit=10)
                result_id = page["results"][0]["result_id"]
                self.assertEqual((first.find_count, second.find_count), (0, 1),
                                 "only the named source was asked")

                # The first source leaving does not disturb the second one's
                # connection, its finished search, or a download from it.
                await sources.disconnect()
                await wait_source_by_id(engine, "primary", {"disconnected"})
                self.assertEqual(
                    SourceService.engine_source(await engine.status(), second_id)["state"],
                    "ready")
                started = await downloads.download(KEY_ONE, result_id)
                complete = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] == "complete", "the second source's file")
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                await wait_true(second.chat_closed.is_set, "adapter closes the idle FServe CHAT")
                self.assertEqual((first.trigger_count, first.get_count), (0, 0))
                self.assertEqual((second.trigger_count, second.get_count), (1, 1))

                # A connected source cannot be removed; a disconnected one can.
                with self.assertRaises(EngineRequestError) as busy:
                    await sources.remove(second_id)
                self.assertEqual(busy.exception.code, "source_busy")
                self.assertIsNotNone(sources.store.get(second_id))
                await sources.remove("primary")
                self.assertEqual(
                    [source["source_id"] for source in (await engine.status())["sources"]],
                    [second_id])
                self.assertEqual([config.source_id for config in sources.store.list()],
                                 [second_id])
                self.assertEqual(
                    SourceService.engine_source(await engine.status(), second_id)["state"],
                    "ready")

                await sources.disconnect(second_id)
                await wait_source_by_id(engine, second_id, {"disconnected"})
                await sources.remove(second_id)
                self.assertEqual((await engine.status())["sources"], [])
                self.assertEqual((first.accept_count, second.accept_count), (1, 1),
                                 "nothing reconnected by itself")
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        try:
            self.run_native(workflow, fixture=first)
            self.assertFalse(second.errors, second.errors)
        finally:
            second.release_file_offer.set()
            second.resume_transfer.set()
            second.stop()

    def test_each_source_lists_the_servers_seen_in_its_own_channel(self):
        # Every source, not only the first, is listened to (2026-10-28),
        # and still after reconnecting, when its connection's tag is new.
        first, second = DownloadFixture(), DownloadFixture()
        second.start()

        async def workflow(native, database):
            engine = await open_engine(native)
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(first.port))
                second_id = (await sources.create(
                    source_values(second.port, label="Second")))["source_id"]
                adverts = AdvertService(sources)
                await sources.connect()
                await sources.connect(second_id)
                await wait_source_by_id(engine, "primary", {"ready"})
                await wait_source_by_id(engine, second_id, {"ready"})

                async def seen(source_id, nicks):
                    deadline = time.monotonic() + 15
                    listed = None
                    while time.monotonic() < deadline:
                        adverts._refreshed.clear()
                        listed = sorted(advert["nick"] for advert in
                                        (await adverts.list(source_id))["adverts"])
                        if listed == nicks:
                            return
                        await asyncio.sleep(.2)
                    self.fail(f"{source_id} lists {listed}, not {nicks}")

                first.advertise("Alpha", sysreset_advert("!alpha"))
                second.advertise("Beta", sysreset_advert("!beta"))
                second.advertise("Shelf", "Type: @Shelf For My List Of: 3 Files")
                await seen("primary", ["Alpha"])
                await seen(second_id, ["Beta", "Shelf"])

                await sources.disconnect(second_id)
                await wait_source_by_id(engine, second_id, {"disconnected"})
                await sources.connect(second_id)
                await wait_source_by_id(engine, second_id, {"ready"})
                second.advertise("Gamma", sysreset_advert("!gamma"))
                first.advertise("Delta", sysreset_advert("!delta"))
                await seen(second_id, ["Beta", "Gamma", "Shelf"])
                await seen("primary", ["Alpha", "Delta"])

                await sources.disconnect()
                await sources.disconnect(second_id)
                await wait_source_by_id(engine, "primary", {"disconnected"})
                await wait_source_by_id(engine, second_id, {"disconnected"})
            finally:
                await engine.close()

        try:
            self.run_native(workflow, fixture=first)
            self.assertFalse(second.errors, second.errors)
        finally:
            second.release_file_offer.set()
            second.resume_transfer.set()
            second.stop()

    def test_a_search_bot_sources_channel_has_servers_seen_browsed_and_lists_got(self):
        # An ebooks channel is searched through its search bot and also has
        # list and file servers announcing themselves (2026-10-28).
        fixture = DownloadFixture()
        fixture.tree = {"/": (["BOOKS"], {}), "/BOOKS": ([], {FILENAME: CONTENT})}
        listed = io.BytesIO()
        with zipfile.ZipFile(listed, "w") as archive:
            archive.writestr("Shelf.txt", "[ Contents of D:\\Books\\ ]\r\n"
                                          "!Shelf One.epub  ::INFO:: 1.2MB\r\n")
        fixture.list_servers["Shelf"] = ("Shelf-list.zip", listed.getvalue())

        async def workflow(native, database):
            engine = await open_engine(native)
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(fixture.port, provider="searchbot",
                                                 search_bot="SearchBot"))
                await sources.connect()
                await wait_source(engine, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                adverts = AdvertService(sources)
                browses = downloads.browses = BrowseService(downloads)
                lists = downloads.manifests = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                fixture.advertise("Fixture", sysreset_advert("!Fixture"))
                fixture.advertise("Shelf", "Type: @Shelf For My List Of: 1 Files")
                deadline = time.monotonic() + 15
                seen = []
                while time.monotonic() < deadline and len(seen) < 2:
                    adverts._refreshed.clear()
                    seen = sorted(advert["nick"] for advert in
                                  (await adverts.list("primary"))["adverts"])
                    await asyncio.sleep(.2)
                self.assertEqual(seen, ["Fixture", "Shelf"])

                view = await browses.start_from_advert("primary", "Fixture", "!Fixture")
                deadline = time.monotonic() + 60
                while view["state"] == "browsing":
                    self.assertLess(time.monotonic(), deadline, view)
                    await asyncio.sleep(.5)
                    view = await browses.view(view["browse_id"])
                self.assertEqual(view["state"], "complete", view)
                self.assertEqual([folder["name"] for folder in view["folders"]], ["BOOKS"])
                await wait_true(fixture.chat_closed.is_set, "the browse session is closed")

                asked = await downloads.request_list(KEY_ONE, "primary", "Shelf")
                lists.follow_list(asked)
                got = await wait_download(
                    downloads, asked["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "expired"),
                    "the list", timeout=60)
                self.assertEqual(got["state"], "complete", got)
                await wait_true(lambda: lists.list_imports[asked["operation_id"]]["state"]
                                in ("done", "failed"), "the list to be read", timeout=60)
                state = lists.list_imports[asked["operation_id"]]
                self.assertEqual((state["state"], state["files"]), ("done", 1), state)

                # A file server's stored list keeps a Browse of its own, by
                # the trigger it was kept with (2026-10-28).
                async def tree():
                    yield b"[  4]  BOOKS\\" + FILENAME.encode() + b"\n"
                kept = await lists.import_upload(tree(), "fixture-list.txt", "primary",
                                                 "Fixture", "!Fixture")
                fixture.chat_closed.clear()
                view = await browses.start_from_list(kept["route_key"])
                deadline = time.monotonic() + 90
                while view["state"] == "browsing":
                    self.assertLess(time.monotonic(), deadline, view)
                    await asyncio.sleep(.5)
                    view = await browses.view(view["browse_id"])
                self.assertEqual(view["state"], "complete", view)
                await wait_true(fixture.chat_closed.is_set, "the second browse is closed")
                (shelf,) = [item for item in (await lists.lists())["lists"]
                            if item["sender"] == "Shelf"]
                with self.assertRaises(BrowseError) as posted:
                    await browses.start_from_list(shelf["route_key"])
                self.assertEqual(posted.exception.code, "not_browsable")
                self.assertEqual(fixture.trigger_count, 2, "one trigger for each browse")
                self.assertEqual(fixture.search_count, 0, "nothing was searched")
                await searches.close()
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
            finally:
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_a_second_get_list_waits_in_the_queue_and_both_lists_are_read(self):
        # 2026-10-29: Get list on a second server while the first list was
        # coming was refused; now it waits its turn.
        fixture = DownloadFixture()
        for nick in ("PackBot", "ListBot"):
            listed = io.BytesIO()
            with zipfile.ZipFile(listed, "w") as archive:
                archive.writestr(f"{nick}.txt", "[ Contents of D:\\Books\\ ]\r\n"
                                                f"!{nick} One.epub  ::INFO:: 1.2MB\r\n")
            fixture.list_servers[nick] = (f"{nick}-list.zip", listed.getvalue())

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = queue = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                lists = downloads.manifests = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                queue = QueueService(downloads)
                queue.start_runner()
                for nick in ("PackBot", "ListBot"):
                    fixture.advertise(nick, f"Type: @{nick} For My List Of: 1 Files")
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    reply = await engine.request("adverts.list", {"source_id": "primary"})
                    if len(reply["adverts"]) == 2:
                        break
                    await asyncio.sleep(.2)
                self.assertFalse(await queue.list_should_wait())
                first = await downloads.request_list(KEY_ONE, "primary", "PackBot")
                lists.follow_list(first)
                self.assertTrue(await queue.list_should_wait(), "the first list is coming")
                view = await queue.add_list("primary", "ListBot")
                self.assertTrue(view["running"], "a queue of lists only starts at once")
                await wait_true(lambda: any(
                    item["sender"] == "ListBot" and item["state"] == "done"
                    for item in queue.view()["items"]), "the queued list to arrive", timeout=120)
                await wait_true(lambda: sum(1 for entry in lists.list_imports.values()
                                            if entry["state"] == "done") == 2,
                                "both lists to be read", timeout=60)
                self.assertEqual(sorted(item["sender"] for item in (await lists.lists())["lists"]),
                                 ["ListBot", "PackBot"])
                self.assertEqual(fixture.list_requests, ["PackBot", "ListBot"], "each asked once")
            finally:
                if queue is not None:
                    await queue.close()
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_a_nick_typed_by_the_operator_is_asked_for_its_list(self):
        # 2026-10-29: one server's notice names another nick for its list;
        # that nick announces nothing, so Get list could not ask it.
        fixture = DownloadFixture()
        listed = io.BytesIO()
        with zipfile.ZipFile(listed, "w") as archive:
            archive.writestr("Quill.txt", "[ Contents of D:\\Books\\ ]\r\n"
                                          "!Quill One.epub  ::INFO:: 1.2MB\r\n")
        fixture.list_servers["Quill"] = ("Quill-list.zip", listed.getvalue())

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                adverts = AdvertService(sources)
                with self.assertRaises(DownloadError) as unseen:
                    await downloads.request_list(KEY_ONE, "primary", "Quill",
                                                 advertised=adverts.offers_list("primary", "Quill"))
                self.assertEqual(unseen.exception.code, "not_a_list_server")
                self.assertEqual(fixture.list_requests, [])
                adverts.vouch("primary", "Quill")
                asked = await downloads.request_list(
                    KEY_TWO, "primary", "Quill",
                    advertised=adverts.offers_list("primary", "Quill"))
                got = await wait_download(
                    downloads, asked["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "expired", "interrupted"),
                    "the list", timeout=60)
                self.assertEqual(got["state"], "complete", got)
                self.assertEqual(fixture.list_requests, ["Quill"])
                with self.assertRaises(DownloadError) as again:
                    await downloads.request_list(KEY_THREE, "primary", "Quill", advertised=True)
                self.assertEqual(again.exception.code, "repeat_refused", "still once a connection")
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_a_typed_nicks_list_sent_by_another_nick_is_taken(self):
        # 2026-11-02: one nick's advert names "@Musing" and its own nick,
        # Emberline, sends the list; the offer was turned down as not from
        # the nick asked. A nick the operator typed may have its list sent
        # by another; it is filed as the typed nick's.
        fixture = DownloadFixture()
        listed = io.BytesIO()
        with zipfile.ZipFile(listed, "w") as archive:
            archive.writestr("Musing.txt", "[ Contents of D:\\Books\\ ]\r\n"
                                           "!Musing One.epub  ::INFO:: 1.2MB\r\n")
        fixture.list_servers["Musing"] = ("Musing-index.zip", listed.getvalue())
        fixture.list_sent_by["Musing"] = "Emberline"

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                adverts = downloads.adverts = AdvertService(sources)
                adverts.vouch("primary", "Musing")
                asked = await downloads.request_list(
                    KEY_ONE, "primary", "Musing",
                    advertised=adverts.offers_list("primary", "Musing"),
                    typed=adverts.typed("primary", "Musing"))
                got = await wait_download(
                    downloads, asked["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "expired", "interrupted"),
                    "the list", timeout=60)
                self.assertEqual(got["state"], "complete", got)
                self.assertEqual(fixture.list_requests, ["Musing"])
                self.assertEqual([(record["sender"], record["accepted"])
                                  for record in fixture.offer_records],
                                 [("Emberline", True)])
                self.assertTrue(got["download_path"].endswith("/Musing/@list/Musing-index.zip"),
                                got)
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_a_list_cut_short_may_be_asked_for_again_on_the_same_connection(self):
        # 2026-10-29: a list whose transfer failed could not be asked for
        # again until a reconnect. The sender answered, so a second ask is
        # allowed once; one that arrived whole is not asked again.
        fixture = DownloadFixture()
        listed = io.BytesIO()
        with zipfile.ZipFile(listed, "w") as archive:
            archive.writestr("ListBot.txt", "[ Contents of D:\\Books\\ ]\r\n"
                                            + "".join(f"!ListBot Book {number:04}.epub  ::INFO:: 1.2MB\r\n"
                                                      for number in range(400)))
        fixture.list_servers["ListBot"] = ("ListBot-list.zip", listed.getvalue())
        fixture.list_cut["ListBot"] = 1

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                lists = downloads.manifests = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                fixture.advertise("ListBot", "Type: @ListBot For My List Of: 400 Files")
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    reply = await engine.request("adverts.list", {"source_id": "primary"})
                    if reply["adverts"]:
                        break
                    await asyncio.sleep(.2)
                first = await downloads.request_list(KEY_ONE, "primary", "ListBot")
                cut = await wait_download(
                    downloads, first["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "expired", "interrupted"),
                    "the cut list", timeout=60)
                self.assertNotEqual(cut["state"], "complete", cut)
                second = await downloads.request_list(KEY_TWO, "primary", "ListBot")
                lists.follow_list(second)
                got = await wait_download(
                    downloads, second["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "expired", "interrupted"),
                    "the list asked again", timeout=60)
                self.assertEqual(got["state"], "complete", got)
                self.assertEqual(fixture.list_requests, ["ListBot", "ListBot"])
                with self.assertRaises(DownloadError) as again:
                    await downloads.request_list(KEY_THREE, "primary", "ListBot")
                self.assertEqual(again.exception.code, "repeat_refused")
                self.assertEqual(fixture.list_requests, ["ListBot", "ListBot"])
                await wait_true(lambda: any(entry["state"] == "done"
                                            for entry in lists.list_imports.values()),
                                "the list to be read", timeout=60)
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_list_is_asked_once_a_minute_answers_read_and_an_unasked_list_taken(self):
        # As servers answered "!list" in a real ebook channel (2026-10-28),
        # nicks changed: notices naming their lists, "-New" ones among them,
        # and one server sending its list unasked.
        fixture = DownloadFixture()
        fixture.list_answers = [
            ("Quill", " List trigger(s): @Quill,@Quill-new  OmenServe 2.74 "),
            ("Emberline", "I have the following lists: @EMBERLINE, @EMBERLINE-New, "
                          "@EMBERLINE-NEW ARRIVALS"),
            ("Sprout", "I have the following File List(s): @Sprout, @Sprout, @Sprout-New"),
            ("Talker", "hello, nothing to see here"),
        ]
        listed = io.BytesIO()
        with zipfile.ZipFile(listed, "w") as archive:
            archive.writestr("Quill.txt", "[ Contents of D:\\Books\\ ]\r\n"
                                        "!Quill One.epub  ::INFO:: 1.2MB\r\n"
                                        "!Quill Two.epub  ::INFO:: 2.0MB\r\n")
        fixture.unasked_lists = {
            "Quill": ("Quill-list.zip", listed.getvalue(), 30.0),
            # Neither answered nor in the channel: never taken.
            "Stranger": ("Stranger-list.zip", listed.getvalue(), 12.0),
        }

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                adverts = AdvertService(sources)
                lists = downloads.manifests = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                servers = ServersService(downloads, lists)
                asked = await servers.ask("primary")
                self.assertIn(asked["state"], ("pending", "sending", "listening"), asked)
                with self.assertRaises(EngineRequestError) as again:
                    await servers.ask("primary")
                self.assertEqual(again.exception.code, "too_soon")

                deadline = time.monotonic() + 20
                seen = []
                while time.monotonic() < deadline and len(seen) < 3:
                    adverts._refreshed.clear()
                    seen = sorted(advert["nick"] for advert in
                                  (await adverts.list("primary"))["adverts"])
                    await asyncio.sleep(.2)
                self.assertEqual(seen, ["Emberline", "Quill", "Sprout"], "Talker named no list")
                answers = await servers.answers("primary")
                self.assertEqual(answers["answered"], ["Emberline", "Quill", "Sprout"])

                await wait_true(lambda: bool(servers.taken.get("primary")),
                                "the unasked list to be taken", timeout=30)
                (taken,) = servers.taken["primary"]
                self.assertEqual((taken["sender"], taken["name"]), ("Quill", "Quill-list.zip"))
                await wait_true(lambda: lists.list_imports.get(taken["operation_id"], {})
                                .get("state") in ("done", "failed"), "the list to be read",
                                timeout=60)
                state = lists.list_imports[taken["operation_id"]]
                self.assertEqual((state["state"], state["files"]), ("done", 2), state)
                got = await downloads.status(taken["operation_id"])
                self.assertTrue(
                    (native.home / "fserve-poc" / "lists" / got["download_path"]).is_file())
                await wait_true(lambda: len(fixture.offer_records) == 2,
                                "the stranger's offer to lapse", timeout=30)
                self.assertEqual(
                    sorted((record["sender"], record["accepted"])
                           for record in fixture.offer_records),
                    [("Quill", True), ("Stranger", False)])
                self.assertEqual(fixture.list_command_count, 1, "asked once")
                self.assertEqual(fixture.list_requests, [], "no @Nick was sent")
                await servers.close()
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_one_search_across_two_sources_keeps_both_downloadable(self):
        first, second = DownloadFixture(), DownloadFixture()
        second.start()

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = multi = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(first.port, label="First"))
                added = await sources.create(source_values(second.port, label="Second"))
                second_id = added["source_id"]
                await sources.connect()
                await sources.connect(second_id)
                await wait_source_by_id(engine, "primary", {"ready"})
                await wait_source_by_id(engine, second_id, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                multi = MultiSearchService(searches)
                await multi.startup()

                # Which sources are asked is always spelled out, five at most.
                for chosen in ([], "primary", ["primary", "primary"],
                               ["primary", "src-missing"], ["a", "b", "c", "d", "e", "f"]):
                    with self.assertRaises(SearchError):
                        await multi.start("fixture", chosen)
                self.assertEqual((first.find_count, second.find_count), (0, 0))

                started = await multi.start("fixture", ["primary", second_id])
                group_id = started["group_id"]
                with self.assertRaises(SearchError) as busy:
                    await multi.start("fixture", ["primary"])
                self.assertEqual(busy.exception.code, "search_active")
                deadline = time.monotonic() + 60
                while True:
                    summary = multi.summary(group_id)
                    if summary["state"] == "complete":
                        break
                    self.assertLess(time.monotonic(), deadline, summary)
                    await asyncio.sleep(.3)
                self.assertEqual(
                    [(member["label"], member["state"], member["result_count"],
                      member["historical"]) for member in summary["members"]],
                    [("First", "complete", 1, False), ("Second", "complete", 1, False)])
                self.assertEqual(summary["result_count"], 2)
                # One query per source, and no more.
                self.assertEqual((first.find_count, second.find_count), (1, 1))

                page = await multi.page(group_id, offset=0, limit=10)
                self.assertEqual(
                    [(row["source_label"], row["path"], row["selection_available"])
                     for row in page["results"]],
                    [("First", "/books/fixture.txt", True),
                     ("Second", "/books/fixture.txt", True)])
                await asyncio.sleep(.2)
                tail = await multi.page(group_id, offset=1, limit=1)
                self.assertEqual([row["source_label"] for row in tail["results"]], ["Second"])

                # The first source was asked before the second, yet its row
                # still downloads: each source keeps its own finished search.
                one = await downloads.download(KEY_ONE, page["results"][0]["result_id"])
                await wait_download(
                    downloads, one["operation_id"],
                    lambda row: row["state"] == "complete", "the first source's file")
                await wait_true(first.chat_closed.is_set, "the first session is closed")
                self.assertEqual((first.get_count, second.get_count), (1, 0))

                await asyncio.sleep(.2)
                again = await multi.page(group_id, offset=0, limit=10)
                self.assertEqual(
                    [row["selection_available"] for row in again["results"]], [True, True])
                two = await downloads.download(KEY_TWO, again["results"][1]["result_id"])
                await wait_download(
                    downloads, two["operation_id"],
                    lambda row: row["state"] == "complete", "the second source's file")
                await wait_true(second.chat_closed.is_set, "the second session is closed")
                self.assertEqual((first.get_count, second.get_count), (1, 1))
                self.assertEqual((first.trigger_count, second.trigger_count), (1, 1))
                self.assertEqual(len(published_files(native)), 2)

                # One source leaving ends only its own rows.
                await sources.disconnect(second_id)
                await wait_source_by_id(engine, second_id, {"disconnected"})
                await asyncio.sleep(.5)
                after = await multi.page(group_id, offset=0, limit=10)
                self.assertEqual(
                    [row["selection_available"] for row in after["results"]], [True, False])
                await sources.disconnect()
                await wait_source_by_id(engine, "primary", {"disconnected"})
                self.assertEqual((first.find_count, second.find_count), (1, 1))
            finally:
                if multi is not None:
                    await multi.close()
                if searches is not None:
                    await searches.close()
                await engine.close()

        try:
            self.run_native(workflow, fixture=first)
            self.assertFalse(second.errors, second.errors)
        finally:
            second.release_file_offer.set()
            second.resume_transfer.set()
            second.stop()

    def test_file_list_is_added_searched_offline_and_downloaded_after_a_live_check(self):
        fixture = DownloadFixture()
        # The file server's own list of what it holds: one file that is
        # there, and one that has since gone.
        fixture.extra_files["list.txt"] = (
            f"[  {len(CONTENT)}]  books\\{FILENAME}\n[ 1.2M]  books\\gone.bin\n".encode())

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                lists = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                downloads.manifests = lists
                self.assertEqual(await lists.lists(), {"lists": [], "imports": []})
                with self.assertRaises(ManifestError) as none:
                    await lists.search("fixture")
                self.assertEqual(none.exception.code, "no_lists")

                # The list arrives as an ordinary download.
                search = await searches.search("fixture")
                search = await wait_search(searches, search["search_id"])
                page = await searches.page(search["search_id"], offset=0, limit=10)
                listed = next(row for row in page["results"] if row["path"] == "/books/list.txt")
                fetched = await downloads.download(KEY_ONE, listed["result_id"])
                await wait_download(
                    downloads, fetched["operation_id"],
                    lambda row: row["state"] == "complete", "the file list itself")
                await wait_true(fixture.chat_closed.is_set, "the first session is closed")
                fixture.chat_closed.clear()

                with self.assertRaises(ManifestError):
                    await lists.import_download("web-download-" + "0" * 64)
                added = await lists.import_download(fetched["operation_id"])
                self.assertEqual(added["files"], 2)
                (entry,) = added["lists"]
                self.assertEqual(
                    (entry["source_id"], entry["source_label"], entry["sender"],
                     entry["trigger"], entry["files"]),
                    ("primary", "W2 test", "Fixture", "!Fixture", 2))
                self.assertRegex(entry["listed_at"], r"\A20\d\d-\d\d-\d\dT")

                # Searching the list sends nothing at all.
                before = (fixture.find_count, fixture.trigger_count, fixture.chat_offer_count,
                          lines_sent(fixture))
                with self.assertRaises(ManifestError) as short:
                    await lists.search("fi")
                self.assertEqual(short.exception.code, "invalid_query")
                hits = await lists.search("fixture", entry["route_key"])
                self.assertEqual(
                    [(row["path"], row["sender"], row["trigger"], row["source_label"],
                      row["selection_available"]) for row in hits["results"]],
                    [("/books/" + FILENAME, "Fixture", "!Fixture", "W2 test", True)])
                gone = (await lists.search("gone", entry["route_key"]))["results"][0]
                self.assertEqual((gone["path"], gone["size_precision"]),
                                 ("/books/gone.bin", "estimated"))
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count, fixture.chat_offer_count,
                     lines_sent(fixture)), before)

                # A hit downloads through the usual live check: a fresh
                # listing of its folder, then one GET.
                fixture.chat_commands.clear()
                wanted = await downloads.download(KEY_TWO, hits["results"][0]["result_id"])
                complete = await wait_download(
                    downloads, wanted["operation_id"],
                    lambda row: row["state"] == "complete", "the listed file", timeout=75)
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual([command.lower() for command in fixture.chat_commands],
                                 ["cd books", "dir", "get " + FILENAME.lower()])
                await wait_true(fixture.chat_closed.is_set, "the second session is closed")
                fixture.chat_closed.clear()

                # A listed file the server no longer has is not requested.
                gets = fixture.get_count
                missing = await downloads.download(KEY_THREE, gone["result_id"])
                refused = await wait_download(
                    downloads, missing["operation_id"],
                    lambda row: row["state"] == "stale", "the file that has gone", timeout=75)
                self.assertEqual(refused["outcome"], "live_parent_file_missing", refused)
                self.assertEqual(fixture.get_count, gets)
                await wait_true(fixture.chat_closed.is_set, "the third session is closed")

                # With the source disconnected, a hit is refused before anything is sent.
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                triggers = fixture.trigger_count
                with self.assertRaises(DownloadError) as offline:
                    await downloads.download("native-download-key-0004",
                                             hits["results"][0]["result_id"])
                self.assertEqual(offline.exception.code, "source_not_ready")
                self.assertEqual(fixture.trigger_count, triggers)
                self.assertEqual(fixture.find_count, 1)

                # Text that starts with a dash is searched for, not misread.
                self.assertEqual(
                    (await lists.search("-fixture", entry["route_key"]))["results"], [])

                # The source is pointed at another server. The list says
                # nothing about that one, so nothing in it can be requested.
                await sources.save(source_values(fixture.port, host="localhost"))
                (moved,) = (await lists.lists())["lists"]
                self.assertEqual((moved["route_key"], moved["source_label"]),
                                 (entry["route_key"], None))
                again = await lists.search("fixture", entry["route_key"])
                self.assertEqual(
                    [(row["path"], row["selection_available"]) for row in again["results"]],
                    [("/books/" + FILENAME, False)])
                with self.assertRaises(DownloadError) as elsewhere:
                    await downloads.download("native-download-key-0005",
                                             hits["results"][0]["result_id"])
                self.assertEqual(elsewhere.exception.code, "stale_result")
                # Nor can a file fetched through the source as it was be
                # added as a list of the server it names now.
                with self.assertRaises(ManifestError) as uncertain:
                    await lists.import_download(fetched["operation_id"])
                self.assertEqual(uncertain.exception.code, "invalid_file")
                self.assertEqual(fixture.trigger_count, triggers)
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_list_placed_by_hand_is_added_and_a_hit_downloaded_after_a_live_check(self):
        fixture = DownloadFixture()

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                root = native.home / "fserve-poc" / "downloads"
                lists = ManifestService(downloads, catalog_root=database.parent / "file-lists",
                                        download_root=root,
                                        lists_root=native.home / "fserve-poc" / "lists")
                downloads.manifests = lists
                # The operator copies a list into the downloads folder. It
                # never came through IRC, so only what is typed in says whose
                # list it is.
                placed = root / "lists" / "from-a-friend.txt"
                placed.parent.mkdir(parents=True)
                placed.write_bytes(
                    f"[  {len(CONTENT)}]  books\\{FILENAME}\n[ 1.2M]  books\\gone.bin\n".encode())
                sent = lines_sent(fixture)
                offered = await lists.placed_files()
                self.assertEqual([item["path"] for item in offered["files"]],
                                 ["lists/from-a-friend.txt"])
                added = await lists.import_file(
                    "lists/from-a-friend.txt", "primary", "Fixture", "!Fixture")
                (entry,) = added["lists"]
                self.assertEqual(
                    (entry["source_label"], entry["sender"], entry["trigger"], entry["files"]),
                    ("W2 test", "Fixture", "!Fixture", 2))
                hits = await lists.search("fixture", entry["route_key"])
                (hit,) = hits["results"]
                self.assertEqual((hit["path"], hit["selection_available"]),
                                 ("/books/" + FILENAME, True))
                # Adding and searching it sent nothing.
                self.assertEqual((fixture.find_count, fixture.trigger_count), (0, 0))
                self.assertEqual(lines_sent(fixture), sent)

                # A hit is fetched as from any list: a fresh listing of its
                # folder, then one GET.
                wanted = await downloads.download(KEY_ONE, hit["result_id"])
                complete = await wait_download(
                    downloads, wanted["operation_id"],
                    lambda row: row["state"] == "complete", "the listed file", timeout=75)
                self.assertEqual((root / complete["download_path"]).read_bytes(), CONTENT)
                self.assertEqual([command.lower() for command in fixture.chat_commands],
                                 ["cd books", "dir", "get " + FILENAME.lower()])
                self.assertEqual((fixture.find_count, fixture.trigger_count), (0, 1))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_one_search_across_a_source_and_its_stored_file_list(self):
        fixture = DownloadFixture()
        fixture.extra_files["list.txt"] = (
            f"[  {len(CONTENT)}]  books\\{FILENAME}\n[ 1.2M]  books\\gone.bin\n".encode())

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = multi = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                lists = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                downloads.manifests = lists
                multi = MultiSearchService(searches, lists)
                await multi.startup()

                # Get the file server's list and store it.
                search = await searches.search("fixture")
                search = await wait_search(searches, search["search_id"])
                page = await searches.page(search["search_id"], offset=0, limit=10)
                listed = next(row for row in page["results"] if row["path"] == "/books/list.txt")
                fetched = await downloads.download(KEY_ONE, listed["result_id"])
                await wait_download(
                    downloads, fetched["operation_id"],
                    lambda row: row["state"] == "complete", "the file list itself")
                await wait_true(fixture.chat_closed.is_set, "the first session is closed")
                fixture.chat_closed.clear()
                (entry,) = (await lists.import_download(fetched["operation_id"]))["lists"]

                async def complete(group_id):
                    deadline = time.monotonic() + 90
                    while True:
                        summary = await multi.status(group_id)
                        if summary["state"] == "complete":
                            return summary
                        self.assertLess(time.monotonic(), deadline, summary)
                        await asyncio.sleep(.3)

                # The stored list alone: one search box, and nothing is sent.
                before = (fixture.find_count, fixture.trigger_count, lines_sent(fixture))
                alone = await multi.start("fixture", [], [entry["route_key"]])
                summary = await complete(alone["group_id"])
                self.assertEqual(
                    [(member["kind"], member["label"], member["state"], member["result_count"],
                      member["historical"]) for member in summary["members"]],
                    [("list", "Fixture !Fixture", "complete", 1, False)])
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count, lines_sent(fixture)), before)
                with self.assertRaises(SearchError) as unknown:
                    await multi.start("fixture", ["primary"], ["f" * 64])
                self.assertEqual(unknown.exception.code, "unknown_list")

                # The source and its stored list together: one query to the
                # source, and every row says how it was found.
                both = await multi.start("fixture", ["primary"], [entry["route_key"]])
                summary = await complete(both["group_id"])
                self.assertEqual(
                    [(member["kind"], member["provider"], member["state"],
                      member["result_count"]) for member in summary["members"]],
                    [("source", "sysreset_find", "complete", 2),
                     ("list", "file_list", "complete", 1)])
                self.assertEqual(fixture.find_count, 2)
                rows = (await multi.page(both["group_id"], offset=0, limit=10))["results"]
                self.assertEqual(
                    [(row["source_label"], row["provider"], row["path"],
                      row["selection_available"]) for row in rows],
                    [("W2 test", "sysreset_find", "/books/" + FILENAME, True),
                     ("W2 test", "sysreset_find", "/books/list.txt", True),
                     ("Fixture !Fixture", "file_list", "/books/" + FILENAME, True)])
                self.assertEqual(rows[2]["listed_at"], entry["listed_at"])

                # The stored row downloads through the usual live check.
                fixture.chat_commands.clear()
                wanted = await downloads.download(KEY_TWO, rows[2]["result_id"])
                done = await wait_download(
                    downloads, wanted["operation_id"],
                    lambda row: row["state"] == "complete", "the listed file", timeout=75)
                published = native.home / "fserve-poc" / "downloads" / done["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual([command.lower() for command in fixture.chat_commands],
                                 ["cd books", "dir", "get " + FILENAME.lower()])
                await wait_true(fixture.chat_closed.is_set, "the second session is closed")

                # History lists each combined search once, newest first.
                self.assertEqual(
                    [(group["group_id"], len(group["members"])) for group in await multi.history()],
                    [(both["group_id"], 2), (alone["group_id"], 1)])
                self.assertEqual(fixture.find_count, 2)
            finally:
                if multi is not None:
                    await multi.close()
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    @unittest.skipUnless(shutil.which("bsdtar"), "7-Zip is made and read with bsdtar")
    def test_a_list_sent_as_an_archive_other_than_zip_is_taken_and_read(self):
        # As a real list server did on 2026-10-28, sending a .rar; made here
        # as a .7z, which bsdtar can write, and read by the same code.
        fixture = DownloadFixture()
        text = ("D:\\Newlist\\Books\\\r\n"
                "!PackBot First.epub  ::INFO:: 1.2MB\r\n"
                "!PackBot Second.pdf  ::INFO:: 3.4MB\r\n")
        with tempfile.TemporaryDirectory() as staging:
            (Path(staging) / "PackBot-list.txt").write_bytes(text.encode("cp1252"))
            archive = Path(staging) / "share.VPS.2026-10-28-(1200).7z"
            subprocess.run(["bsdtar", "--format", "7zip", "-cf", str(archive), "-C", staging,
                            "PackBot-list.txt"], check=True)
            fixture.list_servers["PackBot"] = (archive.name, archive.read_bytes())
        fixture.list_decoys += [("PackBot-setup.exe", b"MZ not a list")]

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                lists = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                downloads.manifests = lists
                fixture.advertise("PackBot", "Type: @PackBot For My List Of: 2 Files")
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    reply = await engine.request("adverts.list", {"source_id": "primary"})
                    if any(advert["nick"] == "PackBot" for advert in reply["adverts"]):
                        break
                    await asyncio.sleep(.2)
                asked = await downloads.request_list(KEY_ONE, "primary", "PackBot")
                lists.follow_list(asked)
                got = await wait_download(
                    downloads, asked["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "expired"),
                    "the list", timeout=60)
                self.assertEqual(got["state"], "complete", got)
                self.assertTrue(got["download_path"].endswith(
                    "/PackBot/@list/share.VPS.2026-10-28-(1200).7z"), got)
                # Kept with the lists, not the downloads (2026-10-28).
                self.assertTrue(
                    (native.home / "fserve-poc" / "lists" / got["download_path"]).is_file())
                self.assertFalse(
                    (native.home / "fserve-poc" / "downloads" / got["download_path"]).exists())
                await wait_true(lambda: lists.list_imports[asked["operation_id"]]["state"]
                                in ("done", "failed"), "the list to be read", timeout=60)
                state = lists.list_imports[asked["operation_id"]]
                self.assertEqual((state["state"], state["files"]), ("done", 2), state)
                # The file that was no list was turned down, and the Log says so.
                log = await engine.request("log.list", {"after": 0, "limit": 200})
                said = "\n".join(line.get("text", "") for line in log["lines"])
                self.assertIn('Turned down PackBot\'s offer of "PackBot-setup.exe"', said)
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_a_list_whose_rows_name_the_list_is_read_and_a_file_fetched(self):
        # 2026-11-02: an OmenServe list's rows start "!Musing-Ebooks2", the
        # list's name, not "!Musing"; none was read, so the list was refused.
        # They are read, posted back as written, and the file is Musing's.
        self.list_with_its_own_word("Musing-Ebooks2")

    def test_a_list_whose_rows_name_the_servers_trigger_is_read_and_a_file_fetched(self):
        # 2026-11-03: another OmenServe server's rows start with its trigger,
        # "!Tome", which is not its nick at all. Get list took the list from
        # Musing, so the rows are posted so and the file is still Musing's.
        self.list_with_its_own_word("Tome")

    def list_with_its_own_word(self, word):
        fixture = DownloadFixture()
        row = f"!{word} Alpha One.epub  ::INFO:: {len(CONTENT)}B ::HASH:: ae2030bdb7a3c9bb"
        posted = f"!{word} Alpha One.epub  ::INFO:: {len(CONTENT)}B"
        text = ("List Musing-Ebooks2 of 2 Files\r\n\r\n"
                "To request a file, copy/paste to the channel... !Musing FILENAME\r\n\r\n"
                "======\r\nEBookz/2006/01 June 06\r\n======\r\n" + row + "\r\n"
                f"!{word} Beta Two.epub  ::INFO:: 1.2MB ::HASH:: 6191bcee55ba0c88\r\n")
        memory = io.BytesIO()
        with zipfile.ZipFile(memory, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Musing-Ebooks2(2026-11-02)-OS.txt", text)
        fixture.list_servers["Musing"] = ("Musing-Ebooks2(2026-11-02)-OS.zip", memory.getvalue())
        fixture.row_files[posted] = ("Alpha One.epub", CONTENT)
        fixture.row_sender[word] = "Musing"

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                lists = downloads.manifests = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                asked = await downloads.request_list(KEY_ONE, "primary", "Musing",
                                                     advertised=True)
                lists.follow_list(asked)
                await wait_true(lambda: lists.list_imports[asked["operation_id"]]["state"]
                                in ("done", "failed"), "the list to be read", timeout=60)
                state = lists.list_imports[asked["operation_id"]]
                self.assertEqual((state["state"], state["files"]), ("done", 2), state)
                (entry,) = (await lists.lists())["lists"]
                self.assertEqual((entry["sender"], entry["trigger"], entry["posted"]),
                                 ("Musing", "!" + word, True))
                found = await lists.search("Alpha", entry["route_key"])
                self.assertEqual([(hit["path"], hit["sender"]) for hit in found["results"]],
                                 [("/EBookz/2006/01 June 06/Alpha One.epub", "Musing")])
                wanted = await downloads.download(
                    "native-download-key-0004", found["results"][0]["result_id"])
                complete = await wait_download(
                    downloads, wanted["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "expired"),
                    "the listed file", timeout=60)
                self.assertEqual(complete["state"], "complete", complete)
                self.assertEqual(fixture.row_requests, [posted])
                self.assertTrue(complete["download_path"].endswith(
                    "/Musing/@list/Alpha One.epub"), complete)
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_a_list_servers_list_is_asked_once_kept_and_a_file_fetched_from_it(self):
        # A list server as in ebook channels (2026-10-27): it
        # advertises "@ListBot", answers that with a zipped list in the
        # layout a real one had, and sends a file when its row is posted.
        fixture = DownloadFixture()
        row = f"!ListBot Alpha One.epub  ::INFO:: {len(CONTENT)}B"
        text = ("  WELCOME TO MY SERVER.\r\n  !ListBot is not a row: indented banner text\r\n"
                "D:\\Newlist\\Books\\\r\n" + row + "\r\n"
                "!ListBot Beta Two.epub  ::INFO:: 1.2MB\r\n"
                "!ListBot %0123ABCDEF99% Alpha One.epub\r\n"
                "D:\\Newlist\\Audio\\\r\n"
                "!ListBot Bren\xe9 Brown - Dare.m4b  ::INFO:: 222.93MB\r\n"
                "!SomeoneElse Not Theirs.epub  ::INFO:: 1KB\r\n"
                "809076 Total files for 2.29TB\r\n")
        memory = io.BytesIO()
        with zipfile.ZipFile(memory, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("ListBot-list-27-Oct.txt", text.encode("cp1252"))
        fixture.list_servers["ListBot"] = ("ListBot-list-27-Oct.zip", memory.getvalue())
        # Offered first, and not taken: a name another request on this
        # connection reserved, and a file that is no list.
        fixture.list_decoys += [("Gamma.zip", b"PK not this one"),
                                ("ListBot-setup.exe", b"MZ not a list")]
        fixture.row_files[row] = ("Alpha One.epub", CONTENT)
        beta = "!ListBot Beta Two.epub  ::INFO:: 1.2MB"
        fixture.row_files[beta] = ("Beta Two.epub", CONTENT)
        # ListBot answers "@find" too; the row it gives is posted and never
        # answered, so its name stays reserved by that request.
        gamma = "!ListBot Gamma.zip ::INFO:: 10B"
        fixture.find_replies = [("ListBot", "PRIVMSG", gamma)]

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                lists = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                downloads.manifests = lists

                search = await searches.search("gamma")
                search = await wait_search(searches, search["search_id"], timeout=20)
                page = await searches.page(search["search_id"], offset=0, limit=10)
                (reserved,) = [hit for hit in page["results"] if hit["sender"] == "ListBot"]
                unanswered = await downloads.download("native-download-key-0007",
                                                      reserved["result_id"])
                await wait_download(downloads, unanswered["operation_id"],
                                    lambda row: row["state"] == "expired", "Gamma's request")
                self.assertEqual(fixture.row_requests, [gamma])

                async def seen():
                    reply = await engine.request("adverts.list", {"source_id": "primary"})
                    return {advert["nick"]: advert for advert in reply["adverts"]}

                # Not seen advertising a list: nothing is sent.
                with self.assertRaises(DownloadError) as unseen:
                    await downloads.request_list(KEY_ONE, "primary", "ListBot")
                self.assertEqual(unseen.exception.code, "not_a_list_server")
                # Someone else's "@ListBot" is not ListBot's advert; its own is.
                fixture.advertise("Reader", "@ListBot thanks for the books")
                fixture.advertise("ListBot", "\x02Type:\x02 @ListBot For My List Of: 3 Files "
                                  "\xb7 Slots: 2/2 \xb7 Search: ON")
                deadline = time.monotonic() + 20
                adverts = {}
                while "ListBot" not in adverts and time.monotonic() < deadline:
                    adverts = await seen()
                    await asyncio.sleep(.2)
                self.assertEqual(sorted(adverts), ["ListBot"])
                self.assertEqual(
                    (adverts["ListBot"]["script"], adverts["ListBot"]["triggers"]),
                    ("list", [{"trigger": "@ListBot", "kind": "list", "voice_only": False}]))
                self.assertEqual(fixture.list_requests, [])

                # Get list: "@ListBot" once; the .exe offered first is not
                # taken, the zipped list is, filed under @list.
                asked = await downloads.request_list(KEY_TWO, "primary", "ListBot")
                self.assertEqual(asked["sender"], "ListBot")
                lists.follow_list(asked)
                got = await wait_download(
                    downloads, asked["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "expired"),
                    "the list", timeout=60)
                self.assertEqual(got["state"], "complete", got)
                self.assertEqual(fixture.list_requests, ["ListBot"])
                self.assertEqual(
                    [(record["filename"], record["accepted"]) for record in fixture.offer_records],
                    [("Gamma.zip", False), ("ListBot-setup.exe", False),
                     ("ListBot-list-27-Oct.zip", True)])
                self.assertTrue(got["download_path"].endswith(
                    "/ListBot/@list/ListBot-list-27-Oct.zip"), got)
                self.assertEqual(got["name"], "ListBot-list-27-Oct.zip")
                published = native.home / "fserve-poc" / "lists" / got["download_path"]
                self.assertEqual(published.read_bytes(), memory.getvalue())

                # Asked once a connection.
                with self.assertRaises(DownloadError) as again:
                    await downloads.request_list(KEY_THREE, "primary", "ListBot")
                self.assertEqual(again.exception.code, "repeat_refused")
                self.assertEqual(fixture.list_requests, ["ListBot"])

                # The list is read in the background and kept: ListBot's own
                # rows, each under its folder; not the banner, not another
                # nick's row, not the hashed repeat.
                await wait_true(lambda: lists.list_imports[asked["operation_id"]]["state"]
                                in ("done", "failed"), "the list to be read", timeout=60)
                state = lists.list_imports[asked["operation_id"]]
                self.assertEqual((state["state"], state["files"]), ("done", 3), state)
                (entry,) = (await lists.lists())["lists"]
                self.assertEqual((entry["sender"], entry["trigger"], entry["posted"],
                                  entry["files"]), ("ListBot", "!ListBot", True, 3))
                found = await lists.search("Alpha", entry["route_key"])
                self.assertEqual(
                    [(hit["path"], hit["sender"], hit["size_text"], hit["selection_available"])
                     for hit in found["results"]],
                    [("/Newlist/Books/Alpha One.epub", "ListBot", f"{len(CONTENT)}B", True)])
                accented = await lists.search("Dare", entry["route_key"])
                self.assertEqual([hit["path"] for hit in accented["results"]],
                                 ["/Newlist/Audio/Bren\xe9 Brown - Dare.m4b"])

                # A hit is fetched by posting its row as the list wrote it,
                # once; only that name from ListBot is taken.
                before = lines_sent(fixture)
                wanted = await downloads.download(
                    "native-download-key-0004", found["results"][0]["result_id"])
                complete = await wait_download(
                    downloads, wanted["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "expired"),
                    "the listed file", timeout=60)
                self.assertEqual(complete["state"], "complete", complete)
                self.assertEqual(fixture.row_requests, [gamma, row])
                self.assertTrue(complete["download_path"].endswith(
                    "/ListBot/@list/Alpha One.epub"), complete)
                self.assertEqual(
                    (native.home / "fserve-poc" / "downloads" /
                     complete["download_path"]).read_bytes(), CONTENT)
                self.assertEqual(lines_sent(fixture) - before, 1)
                # The same file again on this connection is refused unsent.
                with self.assertRaises(DownloadError) as twice:
                    await downloads.download(
                        "native-download-key-0005", found["results"][0]["result_id"])
                self.assertEqual(twice.exception.code, "repeat_refused")
                self.assertEqual(fixture.row_requests, [gamma, row])
                # A name with a letter outside ASCII is not posted.
                with self.assertRaises(DownloadError) as accent:
                    await downloads.download(
                        "native-download-key-0006", accented["results"][0]["result_id"])
                self.assertEqual(accent.exception.code, "invalid_arguments")
                self.assertEqual(fixture.row_requests, [gamma, row])
                self.assertEqual(fixture.find_count, 1)

                # A file from the list can wait in the queue (2026-10-27): its
                # row is built from the stored list when its turn comes.
                queue = QueueService(downloads)
                try:
                    (second,) = (await lists.search("two beta", entry["route_key"]))["results"]
                    added = await queue.add(second["result_id"])
                    self.assertEqual(
                        [(item["trigger_mode"], item["path"], item["trigger"])
                         for item in added["items"]],
                        [("listed", "/Newlist/Books/Beta Two.epub", "!ListBot")])
                    self.assertEqual(fixture.row_requests, [gamma, row], "adding sends nothing")
                    await queue.start()
                    deadline = time.monotonic() + 60
                    while True:
                        await queue.tick()
                        states = [item["state"] for item in queue.view()["items"]]
                        if states == ["done"]:
                            break
                        self.assertLess(time.monotonic(), deadline, queue.view())
                        await asyncio.sleep(.5)
                    self.assertEqual(fixture.row_requests, [gamma, row, beta])
                finally:
                    await queue.close()
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture,
                        settings=("fscrawl_searchbot_content_timeout_ms 3000",))

    def test_find_rows_to_post_back_are_results_and_fetched_once(self):
        fixture = DownloadFixture()
        wanted = f"!Shelf Direct sample.epub ::INFO:: {len(CONTENT)}B"
        fixture.find_replies = [
            ("Shelf", "PRIVMSG", "I have found 2 file(s) for your query: sample. Displaying 2:"),
            ("Shelf", "PRIVMSG", "From list @Shelf found 2, displaying 2:"),
            ("Shelf", "PRIVMSG", "\x0302" + wanted + "\x03"),
            ("Shelf", "NOTICE", "!Shelf Other book.pdf ::INFO:: 2.0 MiB"),
            # A row naming another nick than its sender is not taken.
            ("Liar", "PRIVMSG", "!Shelf Planted.pdf ::INFO:: 1 KiB"),
            # Nor one without the size marker.
            ("Shelf", "PRIVMSG", "!Shelf no marker.pdf"),
        ]
        # Offered as mIRC offers it, with underscores for the spaces.
        fixture.row_files[wanted] = ("Direct_sample.epub", CONTENT)

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(fixture.port))
                await sources.connect()
                await wait_source(engine, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)

                search = await searches.search("sample")
                search = await wait_search(searches, search["search_id"], timeout=20)
                self.assertEqual((search["state"], search["result_count"]),
                                 ("complete", 3), search)
                page = await searches.page(search["search_id"], offset=0, limit=10)
                self.assertEqual(
                    [(row["ordinal"], row["path"], row["sender"], row["trigger"],
                      row["trigger_mode"], row["selection_available"])
                     for row in page["results"]],
                    [(1, f"/books/{FILENAME}", "Fixture", "!Fixture", "channel_text", True),
                     (2, "Direct sample.epub", "Shelf", "!Shelf", "direct", True),
                     (3, "Other book.pdf", "Shelf", "!Shelf", "direct", True)])
                self.assertEqual(page["results"][1]["size_bytes_estimate"], len(CONTENT))
                self.assertEqual(fixture.row_requests, [], "a search posts no row")

                # Fetching it posts the row once, without its colours, and
                # takes only that file from that nick.
                one = await downloads.download(KEY_ONE, page["results"][1]["result_id"])
                complete = await wait_download(
                    downloads, one["operation_id"],
                    lambda row: row["state"] == "complete", "the posted row's file")
                self.assertEqual(fixture.row_requests, [wanted])
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual((complete["sender"], complete["name"]),
                                 ("Shelf", "Direct sample.epub"))
                self.assertEqual(Path(complete["download_path"]).name, "Direct sample.epub",
                                 "kept under the name the row gave")

                # The same row is not posted twice on one connection.
                with self.assertRaises(DownloadError) as repeat:
                    await downloads.download(KEY_TWO, page["results"][1]["result_id"])
                self.assertEqual(repeat.exception.code, "repeat_refused")
                self.assertEqual(fixture.row_requests, [wanted])

                # A fresh search replaces the rows; the old ones cannot be fetched.
                await asyncio.sleep(31)   # the engine's spacing between searches
                again = await searches.search("sample")
                again = await wait_search(searches, again["search_id"], timeout=20)
                self.assertEqual(again["result_count"], 3, again)
                with self.assertRaises((DownloadError, SearchError)):
                    await downloads.download(KEY_THREE, page["results"][2]["result_id"])
                self.assertEqual(fixture.row_requests, [wanted])
                self.assertEqual((fixture.find_count, fixture.trigger_count), (2, 0))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_queued_rows_to_post_back_outlast_a_new_search_and_are_posted_once(self):
        fixture = DownloadFixture()
        first = f"!Shelf First book.epub ::INFO:: {len(CONTENT)}B"
        second = f"!Shelf Second book.epub ::INFO:: {len(CONTENT)}B"
        fixture.find_replies = [("Shelf", "PRIVMSG", first), ("Shelf", "NOTICE", second)]
        fixture.row_files[first] = ("First_book.epub", CONTENT)
        fixture.row_files[second] = ("Second book.epub", CONTENT)

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            queue = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(fixture.port))
                await sources.connect()
                await wait_source(engine, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                queue = QueueService(downloads)

                search = await searches.search("book")
                search = await wait_search(searches, search["search_id"], timeout=20)
                page = await searches.page(search["search_id"], offset=0, limit=10)
                rows = [row for row in page["results"] if row["trigger_mode"] == "direct"]
                self.assertEqual([row["path"] for row in rows],
                                 ["First book.epub", "Second book.epub"])
                for row in rows:
                    await queue.add(row["result_id"])
                self.assertEqual(fixture.row_requests, [], "adding to the queue sends nothing")

                # A fresh search replaces the rows the page shows; the queue
                # keeps the ones it was given.
                await asyncio.sleep(31)   # the engine's spacing between searches
                again = await searches.search("book")
                again = await wait_search(searches, again["search_id"], timeout=20)
                self.assertEqual(again["state"], "complete", again)

                await queue.start()

                async def both_arrived():
                    await queue.tick()
                    return [item["state"] for item in queue.view()["items"]] == ["done", "done"]

                deadline = time.monotonic() + 120
                while not await both_arrived():
                    self.assertLess(time.monotonic(), deadline, queue.view())
                    await asyncio.sleep(0.5)
                self.assertEqual(fixture.row_requests, [first, second],
                                 "each row posted once, in queue order")
                for row in (await downloads.history())[:2]:
                    published = native.home / "fserve-poc" / "downloads" / row["download_path"]
                    self.assertEqual(published.read_bytes(), CONTENT)
                    self.assertEqual(published.parent.name, "@find")
                    self.assertEqual(row["bytes_received"], len(CONTENT))
                self.assertEqual((fixture.find_count, fixture.trigger_count), (2, 0))
            finally:
                if queue is not None:
                    await queue.close()
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_a_session_lost_before_the_request_is_opened_again_only_when_allowed(self):
        fixture = DownloadFixture()
        fixture.drop_chat_on_dir = 1

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                self.assertTrue(downloads.settings.get("retry_before_request"), "on by default")
                result_id = await selectable_result(searches)
                started = await downloads.download(KEY_ONE, result_id)
                complete = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] in {"complete", "stale", "failed",
                                                 "needs_attention"},
                    "the retried download", timeout=90)
                self.assertEqual(complete["state"], "complete", complete)
                self.assertEqual((fixture.trigger_count, fixture.get_count), (2, 1),
                                 "the trigger once more, the file asked for once")
                self.assertEqual(fixture.chat_commands.count("get " + FILENAME), 1)

                # Turned off, a lost session is not opened again.
                downloads.settings.update({"retry_before_request": False})
                fixture.drop_chat_on_dir = 1
                fixture.chat_closed.clear()
                result_id = await result_on_new_connection(sources, searches, engine)
                started = await downloads.download(KEY_TWO, result_id)
                ended = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] not in ACTIVE_JOB_STATES | {"pending"},
                    "the download without a retry", timeout=60)
                self.assertNotEqual(ended["state"], "complete", ended)
                await asyncio.sleep(3)
                self.assertEqual((fixture.trigger_count, fixture.get_count), (3, 1),
                                 "nothing was sent again, and the file was never asked for")
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_an_unreachable_session_is_said_plainly_and_not_tried_again(self):
        fixture = DownloadFixture()
        fixture.chat_unreachable = True

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)
                began = time.monotonic()
                started = await downloads.download(KEY_ONE, result_id)
                ended = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] not in ACTIVE_JOB_STATES | {"pending",
                                                                         "dispatch_pending"},
                    "the unreachable download", timeout=90)
                self.assertLess(time.monotonic() - began, 30, "it ends at once, not after a wait")
                self.assertEqual((ended["state"], ended["outcome"]),
                                 ("stale", "session_unreachable"), ended)
                self.assertIn("connecting to it failed", ended["reason"])
                self.assertIn("the trigger was not sent again", ended["reason"])
                await asyncio.sleep(3)
                self.assertEqual((fixture.trigger_count, fixture.chat_offer_count), (1, 1),
                                 "the trigger was not sent again")
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_two_file_servers_send_at_once_but_one_server_one_file(self):
        fixture = DownloadFixture()
        fixture.stall_after_bytes = STALL_BYTES     # the first file waits part-way
        fixture.extra_files["other.txt"] = b"another file of the first server\n"
        second = b"the second file server's file\n"
        fixture.second = ("Second", "second.txt", second)

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                search = await searches.search("fixture")
                search = await wait_search(searches, search["search_id"], timeout=12)
                rows = {row["path"].rsplit("/", 1)[-1]: row["result_id"] for row in
                        (await searches.page(search["search_id"], offset=0, limit=10))["results"]}
                self.assertEqual(sorted(rows), ["fixture.txt", "other.txt", "second.txt"], rows)

                first = await downloads.download(KEY_ONE, rows[FILENAME])
                await wait_true(fixture.partial_sent.is_set, "the first file's first bytes")
                await wait_download(downloads, first["operation_id"],
                                    lambda row: row["state"] == "receiving", "the first receipt")

                # Not a second file from the same file server.
                with self.assertRaises(DownloadError) as same:
                    await downloads.download(KEY_TWO, rows["other.txt"])
                self.assertEqual(same.exception.code, "transfer_busy", same.exception.message)
                self.assertIn("this file server", same.exception.message)
                self.assertEqual(fixture.trigger_count, 1, "nothing was sent for it")

                # Another file server's file starts beside it, and arrives.
                started = await downloads.download(KEY_THREE, rows["second.txt"])
                done = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] in {"complete", "stale", "failed"},
                    "the second file", timeout=60)
                self.assertEqual(done["state"], "complete", done)
                self.assertEqual((await downloads.status(first["operation_id"]))["state"],
                                 "receiving", "the first is still arriving")
                with self.assertRaises(DownloadError):
                    await downloads.download("native-download-key-0004", rows["other.txt"])

                fixture.resume_transfer.set()
                complete = await wait_download(
                    downloads, first["operation_id"],
                    lambda row: row["state"] in {"complete", "stale", "failed", "interrupted"},
                    "the first file", timeout=60)
                self.assertEqual(complete["state"], "complete", complete)
                home = native.home / "fserve-poc" / "downloads"
                self.assertEqual((home / complete["download_path"]).read_bytes(), CONTENT)
                self.assertEqual((home / done["download_path"]).read_bytes(), second)
                self.assertEqual(
                    (fixture.trigger_count, fixture.get_count,
                     fixture.second_trigger_count, fixture.second_get_count), (1, 1, 1, 1))
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_try_again_is_refused_on_the_same_connection_and_fetches_on_the_next(self):
        fixture = DownloadFixture()
        fixture.stall_after_bytes = STALL_BYTES
        fixture.drop_after_stall = True

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)
                dropped = await downloads.download(KEY_ONE, result_id)
                await wait_download(downloads, dropped["operation_id"],
                                    lambda row: row["state"] == "interrupted", "the dropped receipt")
                with self.assertRaises(DownloadError) as waiting:
                    await downloads.retry(dropped["operation_id"], KEY_TWO)
                self.assertEqual(waiting.exception.code, "not_retryable", "cancel it first")
                await downloads.cancel(dropped["operation_id"])
                await wait_true(fixture.chat_closed.is_set, "the dropped session closes")

                # On the same connection the file was already asked for.
                refused = await downloads.retry(dropped["operation_id"], KEY_TWO)
                self.assertEqual((refused["state"], refused["outcome"]),
                                 ("stale", "tuple_preflight_refused"), refused)
                self.assertEqual((fixture.trigger_count, fixture.get_count), (1, 1))

                # On the next connection, without a new search, it is fetched.
                fixture.stall_after_bytes = None
                fixture.drop_after_stall = False
                fixture.chat_closed.clear()
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                await sources.connect()
                await wait_source(engine, {"ready"})
                again = await downloads.retry(refused["operation_id"], KEY_THREE)
                complete = await wait_download(
                    downloads, again["operation_id"],
                    lambda row: row["state"] in {"complete", "stale", "failed"}, "the retry",
                    timeout=60)
                self.assertEqual(complete["state"], "complete", complete)
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual((fixture.find_count, fixture.trigger_count, fixture.get_count),
                                 (1, 2, 2), "no new search; the trigger and request once more")
                with self.assertRaises(DownloadError) as done:
                    await downloads.retry(complete["operation_id"], "native-download-key-0004")
                self.assertEqual(done.exception.code, "not_retryable", "a complete one is not")
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_a_file_server_is_browsed_once_and_a_browsed_file_fetched(self):
        fixture = DownloadFixture()
        fixture.tree = {
            "/": (["BOOKS"], {"readme.txt": b"r" * 10}),
            "/BOOKS": (["OLD"], {FILENAME: CONTENT}),
            "/BOOKS/OLD": ([], {"older.txt": b"o" * 5}),
        }

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                browses = downloads.browses = BrowseService(downloads)
                result_id = await selectable_result(searches)
                view = await browses.start(result_id)
                self.assertEqual(view["state"], "browsing", view)
                deadline = time.monotonic() + 60
                while view["state"] == "browsing":
                    self.assertLess(time.monotonic(), deadline, view)
                    await asyncio.sleep(.5)
                    view = await browses.view(view["browse_id"])
                self.assertEqual(view["state"], "complete", view)
                self.assertEqual(([f["name"] for f in view["folders"]],
                                  [f["name"] for f in view["files"]]), (["BOOKS"], ["readme.txt"]))
                books = await browses.view(view["browse_id"], "/BOOKS")
                self.assertEqual(([f["name"] for f in books["folders"]],
                                  [f["name"] for f in books["files"]]), (["OLD"], [FILENAME]))
                self.assertEqual(books["files"][0]["size_bytes"], len(CONTENT))
                old = await browses.view(view["browse_id"], "/BOOKS/OLD")
                self.assertEqual([f["name"] for f in old["files"]], ["older.txt"])
                self.assertEqual(old["parent"], "/BOOKS")
                await wait_true(fixture.chat_closed.is_set, "the browse session is closed")
                self.assertEqual((fixture.trigger_count, fixture.get_count), (1, 0),
                                 "one trigger, and nothing asked for")
                self.assertFalse([c for c in fixture.chat_commands if c.lower().startswith("get")])
                history = await browses.history()
                self.assertEqual((history[0]["state"], history[0]["files"]), ("complete", 3))

                # A browsed file is fetched as a file-list hit is: a new
                # session, a fresh listing of its folder, then the request.
                fixture.chat_closed.clear()
                fixture.chat_commands.clear()
                one = await downloads.download(KEY_ONE, books["files"][0]["result_id"])
                complete = await wait_download(
                    downloads, one["operation_id"],
                    lambda row: row["state"] == "complete", "the browsed file", timeout=75)
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual([c.lower() for c in fixture.chat_commands],
                                 ["cd books", "dir", "get " + FILENAME.lower()])
                queued = await QueueService(downloads).add(old["files"][0]["result_id"])
                self.assertEqual([(item["origin"], item["path"]) for item in queued["items"]],
                                 [("browse", "/BOOKS/OLD/older.txt")])
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_a_queued_row_is_waited_for_with_the_senders_words_shown(self):
        fixture = DownloadFixture()
        wanted = f"!Shelf Queued book.epub ::INFO:: {len(CONTENT)}B"
        fixture.find_replies = [("Shelf", "PRIVMSG", wanted)]
        fixture.row_files[wanted] = ("Queued_book.epub", CONTENT)
        fixture.row_queue_notice = ("I have added Queued book.epub as 1 in my queue. "
                                    "The send will be initiated as soon as possible.")
        # Offered after the plain offer wait (3 s here) has run out.
        fixture.row_offer_delay = 6.0

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(fixture.port))
                await sources.connect()
                await wait_source(engine, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                search = await searches.search("queued")
                search = await wait_search(searches, search["search_id"], timeout=20)
                page = await searches.page(search["search_id"], offset=0, limit=10)
                row = next(item for item in page["results"] if item["trigger_mode"] == "direct")

                one = await downloads.download(KEY_ONE, row["result_id"])
                queued = await wait_download(
                    downloads, one["operation_id"],
                    lambda item: item["state"] == "remote_queued", "the queue notice")
                self.assertEqual(
                    queued["reason"],
                    "The file server said: I have added Queued book.epub as 1 in my queue. "
                    "The send will be initiated as soon as possible.")
                complete = await wait_download(
                    downloads, one["operation_id"],
                    lambda item: item["state"] == "complete", "the queued file", timeout=30)
                self.assertEqual(Path(complete["download_path"]).parts,
                                 ("127.0.0.1", "Shelf", "@find", "Queued book.epub"),
                                 "filed under @find, by the row's name")
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual(fixture.row_requests, [wanted], "asked once")
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture, settings=(
            "fscrawl_searchbot_content_timeout_ms 3000",))

    def test_an_fservepl_find_result_is_fetched_through_its_session(self):
        fixture = DownloadFixture()
        fixture.fservepl = True
        fixture.get_reply = f"\x0312Sending '\x0303{FILENAME}\x0312'"

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(fixture.port))
                await sources.connect()
                await wait_source(engine, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                search = await searches.search("fixture")
                search = await wait_search(searches, search["search_id"], timeout=20)
                page = await searches.page(search["search_id"], offset=0, limit=10)
                self.assertEqual(
                    [(row["path"], row["sender"], row["trigger"], row["trigger_mode"],
                      row["selection_available"]) for row in page["results"]],
                    [(f"/books/{FILENAME}", "Fixture", "!Fixture", "ctcp", True)])

                one = await downloads.download(KEY_ONE, page["results"][0]["result_id"])
                complete = await wait_download(
                    downloads, one["operation_id"],
                    lambda item: item["state"] == "complete", "the FServe.pl file")
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual(fixture.trigger_count, 1, "one CTCP trigger")
                self.assertEqual(fixture.chat_commands[:3], ["cd books", "dir", f"get {FILENAME}"])
                self.assertEqual(fixture.get_count, 1)
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_search_bot_source_is_searched_and_a_row_fetched_once(self):
        fixture = DownloadFixture()
        wanted = f"!BookBot Sample.epub  ::INFO:: {len(CONTENT)}B"
        absent = "!BookBot Absent.epub  ::INFO:: 1.2MB"
        fixture.search_rows = [wanted, absent, "!BookBot Café.epub  ::INFO:: 2KB"]
        fixture.row_files[wanted] = ("Sample.epub", CONTENT)
        fixture.row_notice = "Sorry, that file is not here"

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources = SourceService(database, engine)
                with self.assertRaises(SourceValidationError):
                    await sources.save(source_values(fixture.port, provider="searchbot"))
                with self.assertRaises(SourceValidationError):
                    await sources.save(source_values(fixture.port, search_bot="SearchBot"))
                await sources.save(source_values(
                    fixture.port, provider="searchbot", search_bot="SearchBot"))
                await sources.connect()
                source = await wait_source(engine, {"ready"})
                self.assertEqual((source["provider"], source["search_bot"]),
                                 ("searchbot", "SearchBot"))
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)

                # Only text whose reply can be recognised is sent.
                for bad in ("what's this", "a+b", "semi;colon"):
                    with self.assertRaises(SearchError) as refused:
                        await searches.search(bad)
                    self.assertEqual(refused.exception.code, "invalid_query")
                self.assertEqual(fixture.search_count, 0)

                search = await searches.search("sample book")
                self.assertEqual(search["provider"], "searchbot")
                search = await wait_search(searches, search["search_id"], timeout=20)
                self.assertEqual((search["state"], search["result_count"]),
                                 ("complete", 3), search)
                page = await searches.page(search["search_id"], offset=0, limit=10)
                self.assertEqual(
                    [(row["path"], row["sender"], row["trigger"], row["trigger_mode"],
                      row["selection_available"]) for row in page["results"]],
                    [("Sample.epub", "BookBot", "!BookBot", "searchbot", True),
                     ("Absent.epub", "BookBot", "!BookBot", "searchbot", True),
                     # Its row is not plain ASCII, so it is shown but cannot be posted.
                     ("Café.epub", "BookBot", "!BookBot", "searchbot", False)])
                self.assertEqual(page["results"][0]["size_bytes_estimate"], len(CONTENT))
                self.assertEqual(page["results"][0]["provenance"]["provider"], "searchbot")
                self.assertEqual(
                    (fixture.search_count, fixture.find_count, fixture.row_requests),
                    (1, 0, []))

                # The same search is not sent twice, and the first list stays usable.
                again = await searches.search("sample book")
                self.assertEqual((again["state"], again["engine_state"]),
                                 ("failed", "repeat_refused"), again)
                self.assertEqual(fixture.search_count, 1)
                await asyncio.sleep(.2)
                page = await searches.page(search["search_id"], offset=0, limit=10)
                self.assertTrue(page["results"][0]["selection_available"], page)

                # Fetching a row posts that row, exactly as listed, once.
                one = await downloads.download(KEY_ONE, page["results"][0]["result_id"])
                complete = await wait_download(
                    downloads, one["operation_id"],
                    lambda row: row["state"] == "complete", "the search bot's file")
                self.assertEqual(fixture.row_requests, [wanted])
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual(Path(complete["download_path"]).parts[:3],
                                 ("127.0.0.1", "BookBot", "SearchBot"))
                self.assertEqual((complete["sender"], complete["name"]),
                                 ("BookBot", "Sample.epub"))

                # The same row is not requested twice on one connection.
                with self.assertRaises(DownloadError) as repeat:
                    await downloads.download(KEY_TWO, page["results"][0]["result_id"])
                self.assertEqual(repeat.exception.code, "repeat_refused")
                self.assertEqual(fixture.row_requests, [wanted])

                # A row nobody answers is requested once, then given up.
                lost = await downloads.download(KEY_THREE, page["results"][1]["result_id"])
                expired = await wait_download(
                    downloads, lost["operation_id"],
                    lambda row: row["state"] == "expired", "the unanswered request",
                    timeout=75)
                self.assertIn("not sent again", expired["reason"])
                self.assertIn("The sender said: Sorry, that file is not here",
                              expired["reason"])
                self.assertEqual(fixture.row_requests, [wanted, absent])
                self.assertEqual(
                    (fixture.search_count, fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count), (1, 0, 0, 0))

                # A search-bot download is not a file server's own file list.
                lists = ManifestService(
                    downloads, catalog_root=database.parent / "file-lists",
                    download_root=native.home / "fserve-poc" / "downloads",
                    lists_root=native.home / "fserve-poc" / "lists")
                with self.assertRaises(ManifestError) as not_a_list:
                    await lists.import_download(one["operation_id"])
                self.assertEqual(not_a_list.exception.code, "invalid_file")
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        # Irssi spaces its own outgoing lines about two seconds apart, and the
        # engine's deadline runs from the hand-over, so it must outlast that.
        # Eight seconds once did not, in a full run (2026-10-23).
        self.run_native(workflow, fixture=fixture,
                        settings=("fscrawl_searchbot_content_timeout_ms 20000",))

    def test_a_queued_search_bot_row_outlasts_a_new_search_and_is_posted_once(self):
        fixture = DownloadFixture()
        wanted = f"!BookBot Sample.epub  ::INFO:: {len(CONTENT)}B"
        fixture.search_rows = [wanted, "!BookBot Other.epub  ::INFO:: 1KB"]
        fixture.row_files[wanted] = ("Sample.epub", CONTENT)

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            queue = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(
                    fixture.port, provider="searchbot", search_bot="SearchBot"))
                await sources.connect()
                await wait_source(engine, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                queue = QueueService(downloads)

                search = await searches.search("sample book")
                search = await wait_search(searches, search["search_id"], timeout=20)
                page = await searches.page(search["search_id"], offset=0, limit=10)
                self.assertEqual(page["results"][0]["path"], "Sample.epub")
                await queue.add(page["results"][0]["result_id"])
                with self.assertRaises(QueueError) as twice:
                    await queue.add(page["results"][0]["result_id"])
                self.assertEqual(twice.exception.code, "already_queued")
                self.assertEqual(fixture.row_requests, [], "adding to the queue sends nothing")

                # Another search replaces the list the row came from.
                await asyncio.sleep(31)   # the engine's spacing between searches
                other = await searches.search("other book")
                other = await wait_search(searches, other["search_id"], timeout=20)
                self.assertEqual(other["state"], "complete", other)
                self.assertEqual(fixture.search_count, 2)

                await queue.start()
                deadline = time.monotonic() + 90
                while True:
                    await queue.tick()
                    items = queue.view()["items"]
                    if items[0]["state"] not in ("queued", "running"):
                        break
                    self.assertLess(time.monotonic(), deadline, items)
                    await asyncio.sleep(0.5)
                self.assertEqual(items[0]["state"], "done", items)
                self.assertEqual(fixture.row_requests, [wanted])
                done = (await downloads.history())[0]
                published = native.home / "fserve-poc" / "downloads" / done["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)

                # The list the page shows now is the second search's, still
                # downloadable as before.
                page = await searches.page(other["search_id"], offset=0, limit=10)
                self.assertTrue(page["results"][1]["selection_available"], page)

                # A kept row belongs to its connection: after a reconnect it
                # is not posted, and the queue says why.
                await queue.add(page["results"][1]["result_id"])
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                await sources.connect()
                await wait_source(engine, {"ready"})
                await queue.start()
                deadline = time.monotonic() + 30
                while queue.view()["items"][0]["state"] in ("queued", "running"):
                    self.assertLess(time.monotonic(), deadline, queue.view())
                    await queue.tick()
                    await asyncio.sleep(0.5)
                item = queue.view()["items"][0]
                self.assertEqual((item["name"], item["state"], item["outcome"]),
                                 ("Other.epub", "not_requested", "stale_hold"))
                self.assertEqual(fixture.row_requests, [wanted], "nothing more was posted")
            finally:
                if queue is not None:
                    await queue.close()
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture,
                        settings=("fscrawl_searchbot_content_timeout_ms 20000",))

    def test_search_bot_result_list_from_another_nick_is_not_taken(self):
        fixture = DownloadFixture()
        fixture.search_rows = ["!BookBot Sample.epub  ::INFO:: 1KB"]
        fixture.search_reply_from = "Impostor"
        fixture.search_reply_accepted = False
        fixture.search_notice = "Sorry, your search returned no matches"

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(
                    fixture.port, provider="searchbot", search_bot="SearchBot"))
                await sources.connect()
                await wait_source(engine, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                search = await searches.search("sample")
                search = await wait_search(searches, search["search_id"], timeout=20)
                self.assertEqual((search["state"], search["result_count"]),
                                 ("failed", 0), search)
                self.assertIn("no result list", search["note"])
                # What the search bot itself said is shown, and nothing more is made of it.
                self.assertIn("It said: Sorry, your search returned no matches",
                              search["note"])
                await wait_true(lambda: bool(fixture.offer_records),
                                "the impostor's offer is over")
                self.assertEqual(
                    [(record["sender"], record["accepted"])
                     for record in fixture.offer_records], [("Impostor", False)])
                self.assertEqual(published_files(native), [])
                self.assertEqual(fixture.search_count, 1)
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture,
                        settings=("fscrawl_searchbot_timeout_ms 8000",))

    def test_source_changed_from_a_search_bot_to_file_servers_is_searched_normally(self):
        fixture = DownloadFixture()
        fixture.search_rows = ["!BookBot Sample.epub  ::INFO:: 1KB"]

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(
                    fixture.port, provider="searchbot", search_bot="SearchBot"))
                await sources.connect()
                await wait_source(engine, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                listed = await searches.search("sample")
                listed = await wait_search(searches, listed["search_id"], timeout=20)
                self.assertEqual(listed["state"], "complete", listed)

                # The operator corrects the kind of this same source. Its old
                # search-bot list must not be taken for its "@find" search.
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                await sources.save(source_values(fixture.port))
                await sources.connect()
                await wait_source(engine, {"ready"})
                found = await searches.search("fixture")
                self.assertEqual(found["provider"], "sysreset_find")
                found = await wait_search(searches, found["search_id"], timeout=20)
                self.assertEqual((found["state"], found["result_count"]),
                                 ("complete", 1), found)
                page = await searches.page(found["search_id"], offset=0, limit=10)
                self.assertEqual(
                    [(row["trigger_mode"], row["selection_available"])
                     for row in page["results"]], [("channel_text", True)], page)
                self.assertEqual((fixture.search_count, fixture.find_count), (1, 1))
                # The engine reports the source's "@find" search as its
                # current one, not the search-bot list it had before.
                current = (await engine.status())["searches"]["primary"]
                self.assertEqual((current.get("provider"), current["state"]),
                                 (None, "complete"), current)
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_one_search_across_file_servers_and_two_search_bots(self):
        first, second, third = DownloadFixture(), DownloadFixture(), DownloadFixture()
        row = f"!BookBot Sample.epub  ::INFO:: {len(CONTENT)}B"
        for bot in (second, third):
            bot.search_rows = [row]
            bot.row_files[row] = ("Sample.epub", CONTENT)
            bot.start()

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = multi = None
            try:
                sources = SourceService(database, engine)
                await sources.save(source_values(first.port, label="Servers"))
                ids = ["primary"]
                for label, bot in (("Bot one", second), ("Bot two", third)):
                    added = await sources.create(source_values(
                        bot.port, label=label, provider="searchbot",
                        search_bot="SearchBot"))
                    ids.append(added["source_id"])
                for source_id in ids:
                    await sources.connect(source_id)
                for source_id in ids:
                    await wait_source_by_id(engine, source_id, {"ready"})
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                multi = MultiSearchService(searches)
                await multi.startup()

                started = await multi.start("fixture", ids)
                deadline = time.monotonic() + 90
                while True:
                    summary = multi.summary(started["group_id"])
                    if summary["state"] == "complete":
                        break
                    self.assertLess(time.monotonic(), deadline, summary)
                    await asyncio.sleep(.3)
                self.assertEqual(
                    [(member["label"], member["state"], member["result_count"],
                      member["historical"]) for member in summary["members"]],
                    [("Servers", "complete", 1, False), ("Bot one", "complete", 1, False),
                     ("Bot two", "complete", 1, False)])
                # One query per source, each in its own kind.
                self.assertEqual(
                    [(item.find_count, item.search_count) for item in (first, second, third)],
                    [(1, 0), (0, 1), (0, 1)])

                page = await multi.page(started["group_id"], offset=0, limit=10)
                self.assertEqual(
                    [(item["source_label"], item["path"], item["trigger_mode"],
                      item["selection_available"]) for item in page["results"]],
                    [("Servers", "/books/fixture.txt", "channel_text", True),
                     ("Bot one", "Sample.epub", "searchbot", True),
                     ("Bot two", "Sample.epub", "searchbot", True)])

                # The first search bot was asked before the second, yet its
                # row still downloads: each source keeps its own result list.
                one = await downloads.download(KEY_ONE, page["results"][1]["result_id"])
                await wait_download(
                    downloads, one["operation_id"],
                    lambda item: item["state"] == "complete", "the first bot's file")
                self.assertEqual((second.row_requests, third.row_requests), ([row], []))

                two = await downloads.download(KEY_TWO, page["results"][0]["result_id"])
                await wait_download(
                    downloads, two["operation_id"],
                    lambda item: item["state"] == "complete", "the file server's file")
                await wait_true(first.chat_closed.is_set, "the file-server session is closed")
                self.assertEqual(first.get_count, 1)

                await asyncio.sleep(.2)
                again = await multi.page(started["group_id"], offset=0, limit=10)
                self.assertEqual(
                    [item["selection_available"] for item in again["results"]],
                    [True, True, True])
                three = await downloads.download(KEY_THREE, again["results"][2]["result_id"])
                await wait_download(
                    downloads, three["operation_id"],
                    lambda item: item["state"] == "complete", "the second bot's file")
                self.assertEqual((second.row_requests, third.row_requests), ([row], [row]))
                # Three files; the result lists are kept apart. Both bots are
                # SearchBot on 127.0.0.1, so their lists share a name and a
                # folder, and the later one takes the earlier one's place.
                names = sorted(Path(name).name for name in published_files(native))
                self.assertEqual(names, ["Sample.epub", "Sample.epub", "fixture.txt"])
                self.assertEqual([Path(name).name for name in kept_lists(native)],
                                 ["SearchBot_results_for__fixture.txt.zip"])

                # One search bot leaving ends only its own rows.
                await sources.disconnect(ids[1])
                await wait_source_by_id(engine, ids[1], {"disconnected"})
                await asyncio.sleep(.5)
                after = await multi.page(started["group_id"], offset=0, limit=10)
                self.assertEqual(
                    [item["selection_available"] for item in after["results"]],
                    [True, False, True])
                self.assertEqual(
                    [(item.find_count, item.search_count) for item in (first, second, third)],
                    [(1, 0), (0, 1), (0, 1)])
            finally:
                if multi is not None:
                    await multi.close()
                if searches is not None:
                    await searches.close()
                await engine.close()

        try:
            self.run_native(workflow, fixture=first)
            for bot in (second, third):
                self.assertFalse(bot.errors, bot.errors)
        finally:
            for bot in (second, third):
                bot.stop()

    def test_file_server_refusal_is_reported_in_its_own_words_and_settles(self):
        fixture = DownloadFixture()
        # SysReset 2.55, with its colour code, when the user's queue is full.
        fixture.get_reply = "\x0304Sorry, all of your queue slots are full."
        fixture.refuse_get = True

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                started = await downloads.download(KEY_ONE, result_id)
                refused = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] == "refused_without_queue",
                    "the file server's refusal", timeout=15)
                self.assertEqual(refused["outcome"], "user_queue_full", refused)
                self.assertIn("Sorry, all of your queue slots are full.", refused["reason"])
                self.assertNotIn("\x03", refused["reason"])
                self.assertIsNone(refused["download_path"], refused)
                self.assertEqual(downloads.store.active(), [], "a refusal frees the slot")
                await wait_true(fixture.chat_closed.is_set, "refused session closes its CHAT")
                self.assertEqual(published_files(native), [])

                # Nothing was sent after the single GET, and the engine is free.
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))
                self.assertEqual(
                    [command.lower() for command in fixture.chat_commands],
                    ["cd books", "dir", "get " + FILENAME.lower()])
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_request_queued_by_the_file_server_completes_when_it_is_sent(self):
        fixture = DownloadFixture()
        fixture.get_reply = ("\x0304Adding your file to queue slot\x0314 1\x0304. "
                             "The file will send when the next send slot is open.")
        fixture.hold_file_offer = True

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                started = await downloads.download(KEY_ONE, result_id)
                operation_id = started["operation_id"]
                queued = await wait_download(
                    downloads, operation_id,
                    lambda row: row["state"] == "remote_queued", "the queue acknowledgement",
                    timeout=15)
                self.assertIn("Adding your file to queue slot 1.", queued["reason"])
                # Still the one active download: nothing else may be requested.
                with self.assertRaises(DownloadError) as busy:
                    await downloads.download(KEY_TWO, result_id)
                self.assertEqual(busy.exception.code, "download_busy")
                await asyncio.sleep(1)
                self.assertEqual(fixture.get_count, 1)

                fixture.release_file_offer.set()
                complete = await wait_download(
                    downloads, operation_id,
                    lambda row: row["state"] == "complete", "the queued file")
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                await wait_true(fixture.chat_closed.is_set, "adapter closes the idle FServe CHAT")
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_cancelling_a_queued_request_closes_the_session_and_refuses_the_late_file(self):
        fixture = DownloadFixture()
        fixture.get_reply = ("\x0304Adding your file to queue slot\x0314 1\x0304. "
                             "The file will send when the next send slot is open.")
        fixture.hold_file_offer = True

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                started = await downloads.download(KEY_ONE, result_id)
                operation_id = started["operation_id"]
                await wait_download(
                    downloads, operation_id,
                    lambda row: row["state"] == "remote_queued", "the queue acknowledgement",
                    timeout=15)

                await downloads.cancel(operation_id)
                cancelled = await wait_download(
                    downloads, operation_id,
                    lambda row: row["state"] == "cancelled", "the cancelled queued request")
                self.assertIsNone(cancelled["download_path"], cancelled)
                self.assertEqual(downloads.store.active(), [])
                await wait_true(fixture.chat_closed.is_set, "cancelled session closes its CHAT")

                # The server sends the file anyway once its slot opens. Nobody
                # asked for it any more, so it is not taken.
                fixture.expect_offer_accepted = False
                fixture.release_file_offer.set()
                await wait_true(fixture.transfer_finished.is_set, "the late offer", timeout=30)
                self.assertEqual(published_files(native), [])
                self.assertEqual(staged_files(native), [])
                # It is declined rather than left to time out, which frees the
                # server's send slot; and that is the only thing sent.
                await wait_true(lambda: fixture.declines() == 1, "the decline")
                await asyncio.sleep(1)
                self.assertEqual(fixture.declines(), 1)
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)


    def flooded_session(self, fixture: DownloadFixture, reason: str, *, stall: float,
                        then=None, typed=(), kept=64 * 1024):
        """One request whose session delivers data instead of a prompt, or
        instead of the listing it was asked for."""

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                started = await downloads.download(KEY_ONE, result_id)
                async with StatusWatch(engine) as watch:
                    settled = await wait_download(
                        downloads, started["operation_id"],
                        lambda row: row["state"] == "stale", "the flooded session", timeout=20)
                    await wait_true(fixture.chat_closed.is_set, "the flooded CHAT is closed")
                watch.check(self, stall, "the engine kept answering")
                self.assertEqual(settled["outcome"], "session_not_fserve", settled)
                self.assertIn(reason, settled["reason"])
                self.assertEqual(downloads.store.active(), [], "the slot is free")
                # The sender was stopped early and almost none of it was kept.
                self.assertLess(fixture.chat_flood_sent, 8 * 1024 * 1024)
                self.assertLess(sum(record.stat().st_size for record in
                                    (native.home / "fserve-poc").glob("transcript-*.tsv")),
                                kept)
                self.assertEqual(fixture.chat_commands, list(typed),
                                 "nothing was typed into it after the flood began")
                self.assertEqual(published_files(native), [])
                if then is not None:
                    await then(native, engine, sources, searches, downloads)
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(fixture.get_count, 1 if then else 0)
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count, fixture.chat_offer_count),
                    (2, 2, 2) if then else (1, 1, 1))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_chat_that_delivers_file_data_is_closed_and_the_request_settles(self):
        fixture = DownloadFixture()
        # A loopback sender is faster than Irssi works through the lines.
        # Before the session's socket was cut at the first line that is not
        # text, 8 MB kept the engine from answering for about 6 seconds and
        # 32 MB for over two minutes (X6 review, finding 5).
        fixture.chat_flood_bytes = 64 * 1024 * 1024

        async def then(native, engine, sources, searches, downloads):
            # The engine is left fit for use: once the file server behaves,
            # the file is fetched over a new connection.
            fixture.chat_flood_bytes = 0
            fixture.chat_closed.clear()
            result_id = await result_on_new_connection(sources, searches, engine)
            again = await downloads.download(KEY_TWO, result_id)
            complete = await wait_download(
                downloads, again["operation_id"],
                lambda row: row["state"] == "complete", "the next download", timeout=60)
            published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
            self.assertEqual(published.read_bytes(), CONTENT)
            await wait_true(fixture.chat_closed.is_set, "adapter closes the idle FServe CHAT")

        self.flooded_session(fixture, "not text", stall=3, then=then)

    def test_chat_that_delivers_file_data_slowly_is_closed_at_its_first_lines(self):
        fixture = DownloadFixture()
        # As over an ordinary link: these 8 MB would take half a minute to
        # arrive. The session is closed long before they have.
        fixture.chat_flood_bytes = 8 * 1024 * 1024
        fixture.chat_flood_rate = 256 * 1024
        self.flooded_session(fixture, "not text", stall=3)
        self.assertLess(fixture.chat_flood_sent, 1024 * 1024)

    def test_chat_that_delivers_text_without_a_prompt_is_closed_after_500_lines(self):
        fixture = DownloadFixture()
        # A text file sent down the session is text, so it is the count of
        # lines before a prompt that ends it. Irssi has by then read about a
        # megabyte more than it has handed out, and works through that first:
        # about 0.6 seconds, measured alone.
        fixture.chat_flood_bytes = 64 * 1024 * 1024
        fixture.chat_flood_text = True
        self.flooded_session(fixture, "more than 500 lines", stall=5)

    def test_chat_that_delivers_empty_lines_without_a_prompt_is_closed_at_once(self):
        fixture = DownloadFixture()
        # Short lines cost Irssi as much each as long ones, and a megabyte
        # of empty lines is half a million of them. Under the 500-line rule
        # alone this stalled the engine for 23 seconds. The session is now
        # given up once Irssi holds 20,000 lines it has not handed out.
        fixture.chat_flood_bytes = 64 * 1024 * 1024
        fixture.chat_flood_text = True
        fixture.chat_flood_line = b""
        self.flooded_session(fixture, "far faster than it could be read", stall=3)

    def test_chat_that_floods_text_after_its_prompt_is_closed(self):
        fixture = DownloadFixture()
        # Text after the prompt, in place of the listing that was asked
        # for. Once the prompt was seen it was not counted at all: 8 MB of
        # it stalled the engine for 27 seconds, and the request then went
        # on. It is now given up when Irssi holds a megabyte of it.
        fixture.chat_flood_bytes = 64 * 1024 * 1024
        fixture.chat_flood_text = True
        fixture.chat_flood_after_prompt = True
        self.flooded_session(fixture, "far faster than it could be read", stall=3,
                             typed=["cd books", "dir"], kept=128 * 1024)

    def renamed_session(self, fixture: DownloadFixture, *, stall: float):
        """One request whose file server changes its nick once its session is open.

        Irssi then renames the session's CHAT and gives it a new id, and the
        engine, which knows the CHAT by the nick, read none of its lines and
        could not close it (bridge and flood review, finding 1)."""

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                started = await downloads.download(KEY_ONE, result_id)
                async with StatusWatch(engine) as watch:
                    settled = await wait_download(
                        downloads, started["operation_id"],
                        lambda row: row["state"] == "stale", "the renamed session", timeout=20)
                    await wait_true(fixture.chat_closed.is_set, "the renamed CHAT is closed")
                watch.check(self, stall, "the engine kept answering")
                self.assertEqual(settled["outcome"], "file_server_renamed", settled)
                self.assertIn("changed its nick from Fixture to Fixture|away", settled["reason"])
                self.assertEqual(downloads.store.active(), [], "the slot is free")
                self.assertEqual(fixture.chat_commands, [], "nothing was typed into it")
                self.assertEqual(published_files(native), [])
                self.assertEqual([line for line in fixture.lines if b"Fixture|away" in bytes(line)],
                                 [], "nothing was sent under the new nick")
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count, fixture.chat_offer_count,
                     fixture.get_count), (1, 1, 1, 0))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_file_server_that_changes_nick_and_floods_is_given_up_at_once(self):
        fixture = DownloadFixture()
        # Measured before the fix: 32 MB after the change of nick kept the
        # engine from answering for 95 seconds, and the CHAT stayed open.
        fixture.rename_after_chat = .5
        fixture.chat_flood_bytes = 32 * 1024 * 1024
        self.renamed_session(fixture, stall=3)
        self.assertLess(fixture.chat_flood_sent, 8 * 1024 * 1024)

    def test_file_server_that_changes_nick_as_its_session_opens_is_given_up(self):
        fixture = DownloadFixture()
        # Renamed before Irssi reported the CHAT connected, an ordinary
        # session then never settled: no deadline was left to end it.
        fixture.rename_after_chat = 0
        self.renamed_session(fixture, stall=3)

    def test_folder_listing_of_thirty_thousand_files_is_read_and_the_file_fetched(self):
        fixture = DownloadFixture()
        # More than a session may hold, sent at once: it is still read,
        # because it is the listing that was asked for and every line of
        # it is a file. Measured alone, the engine was held up for about
        # 3 seconds by it.
        fixture.listing_padding = 30_000

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                started = await downloads.download(KEY_ONE, result_id)
                async with StatusWatch(engine) as watch:
                    complete = await wait_download(
                        downloads, started["operation_id"],
                        lambda row: row["state"] in {"complete", "stale"}, "the download",
                        timeout=60)
                self.assertEqual(complete["state"], "complete", complete)
                watch.check(self, 15, "the engine answered again in time")
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual(fixture.chat_commands, ["cd books", "dir", "get " + FILENAME])
                await wait_true(fixture.chat_closed.is_set, "adapter closes the idle FServe CHAT")
                record = "".join(item.read_text(errors="replace") for item in
                                 (native.home / "fserve-poc").glob("transcript-*.tsv"))
                self.assertNotIn("CHAT_BACKLOG", record)
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_flooded_chat_of_a_one_port_sender_is_closed_and_its_transfer_finishes(self):
        fixture = DownloadFixture()
        # A file server that takes every DCC on one port, as the lab's does:
        # the session and the file being received lead to the same address
        # and port. Only the session's socket may be cut.
        fixture.one_port = True
        fixture.stall_after_bytes = STALL_BYTES
        fixture.chat_flood_during_transfer = True
        fixture.chat_flood_bytes = 64 * 1024 * 1024

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                started = await downloads.download(KEY_ONE, result_id)
                operation_id = started["operation_id"]
                async with StatusWatch(engine) as watch:
                    await wait_true(fixture.partial_sent.is_set, "the first bytes are sent")
                    await wait_true(fixture.chat_closed.is_set, "the flooded CHAT is closed")
                    receiving = await wait_download(
                        downloads, operation_id,
                        lambda row: row["state"] == "receiving" and row["bytes_received"],
                        "the receipt, still in progress")
                watch.check(self, 3, "the engine kept answering")
                self.assertLess(fixture.chat_flood_sent, 8 * 1024 * 1024)
                self.assertEqual(
                    (receiving["bytes_received"], receiving["total_bytes"]),
                    (STALL_BYTES, len(CONTENT)))

                fixture.resume_transfer.set()
                complete = await wait_download(
                    downloads, operation_id,
                    lambda row: row["state"] == "complete", "the file, after its session was cut")
                published = native.home / "fserve-poc" / "downloads" / complete["download_path"]
                self.assertEqual(published.read_bytes(), CONTENT)
                self.assertEqual(downloads.store.active(), [], "the slot is free")
                self.assertEqual(fixture.chat_commands, ["cd books", "dir", "get " + FILENAME],
                                 "nothing was typed into the session after the flood")
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 1))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)

    def test_chat_offered_on_a_port_with_an_untaken_file_offer_is_not_opened(self):
        fixture = DownloadFixture()

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                # A file offer nobody asked for is left waiting, and the file
                # server then names the same port for its session.
                fixture.offer_stray_file()
                await asyncio.sleep(1)
                started = await downloads.download(KEY_ONE, result_id)
                settled = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] == "stale", "the refused session", timeout=20)
                self.assertEqual(settled["outcome"], "session_port_in_use", settled)
                self.assertIn("still offering a file", settled["reason"])
                self.assertEqual(downloads.store.active(), [], "the slot is free")
                await wait_true(fixture.chat_closed.is_set, "the port was watched to the end",
                                timeout=10)
                self.assertEqual(fixture.stray_connections, 0,
                                 "nothing connected to the port with the waiting offer")
                self.assertEqual(fixture.chat_commands, [])
                self.assertEqual(published_files(native), [])
                self.assertEqual(staged_files(native), [])
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(
                    (fixture.find_count, fixture.trigger_count,
                     fixture.chat_offer_count, fixture.get_count), (1, 1, 1, 0))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture)


    def test_trigger_answered_with_a_notice_or_nothing_settles_the_request(self):
        fixture = DownloadFixture()
        # SysReset 2.55 when another session from the same address is open.
        fixture.trigger_notice = "\x0304Server \x0314Notice: FileServer is busy, please try again later."

        async def workflow(native, database):
            engine = await open_engine(native)
            searches = None
            try:
                sources, searches, downloads = await ready_services(database, engine, fixture)
                result_id = await selectable_result(searches)

                started = await downloads.download(KEY_ONE, result_id)
                settled = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] == "stale", "the busy file server", timeout=10)
                self.assertEqual(settled["outcome"], "session_not_opened", settled)
                self.assertIn("it said: Server Notice: FileServer is busy, please try again later.",
                              settled["reason"])
                self.assertNotIn("\x03", settled["reason"])
                self.assertEqual(downloads.store.active(), [], "the slot is free")

                # A server that says nothing at all: the request gives up
                # after the deadline instead of holding the slot for ever.
                fixture.trigger_notice = ""
                result_id = await result_on_new_connection(sources, searches, engine)
                started = await downloads.download(KEY_TWO, result_id)
                settled = await wait_download(
                    downloads, started["operation_id"],
                    lambda row: row["state"] == "stale", "the silent file server", timeout=45)
                self.assertEqual(settled["outcome"], "session_not_opened", settled)
                self.assertIn("within 3 seconds", settled["reason"])
                self.assertIn("the trigger was not sent again", settled["reason"])
                self.assertEqual(downloads.store.active(), [])
                self.assertEqual(published_files(native), [])
                await sources.disconnect()
                await wait_source(engine, {"disconnected"})
                self.assertEqual(
                    (fixture.trigger_count, fixture.chat_offer_count, fixture.get_count), (2, 0, 0))
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()

        self.run_native(workflow, fixture=fixture, settings=("fscrawl_session_open_ms 3000",))


if __name__ == "__main__":
    unittest.main()
