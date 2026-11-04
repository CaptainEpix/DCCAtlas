"""Real FServe.pl file servers on a real IRC server, offline (2026-10-27).

The other tests play the file servers with a loopback fixture. Here two Irssi
instances run FServe.pl 2.0.0 itself (https://scripts.irssi.org/scripts/fserve.pl,
the script real file servers run) on an Ergo IRC server
(https://github.com/ergochat/ergo), and the app's engine is their client:
they advertise, and Browse from an advert reads one's folders; a large file
from one is still arriving when the other's file starts, and both arrive.
tools/fservepl_lab_check.sh runs it on an internal Docker network; without
FSERVE_ERGO_HOST and FSERVE_FSERVEPL it is skipped.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "t"))
from webapp.adverts import AdvertService
from webapp.browse import BrowseService
from webapp.downloads import DownloadService
from webapp.searches import SearchService
from webapp.sources import SourceService

try:
    from web_bridge_test import NativeIrssi
    from web_download_native_test import open_engine, wait_download
    from web_login_ergo_test import RawClient
    from web_search_test import wait_search
except ImportError:   # the native helpers need a POSIX pty
    NativeIrssi = None

HOST = os.environ.get("FSERVE_ERGO_HOST")
SCRIPT = os.environ.get("FSERVE_FSERVEPL")
CHANNEL = "#books"
BIG_BYTES = 1024 * 1024 * 1024
SMALL = b"the second file server's small book\n"


class FServePl:
    """One Irssi running FServe.pl 2.0.0 as a file server in the channel."""

    def __init__(self, nick: str, trigger: str, files: dict[str, bytes | int]):
        self.nick, self.trigger, self.files = nick, trigger, files

    def __enter__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fservepl-")
        base = Path(self.temporary.name)
        self.home, self.root = base / "home", base / "files"
        self.home.mkdir()
        for relative, content in self.files.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(content, int):
                with path.open("wb") as handle:
                    handle.truncate(content)   # sparse: its size, not its disk
            else:
                path.write_bytes(content)
        self.master, slave = pty.openpty()
        self.transcript = bytearray()
        self.stopped = threading.Event()
        self.process = subprocess.Popen(
            ["irssi", "--noconnect", "--home=" + str(self.home)],
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
            env=dict(os.environ, TERM="xterm", LC_ALL="C"))
        os.close(slave)
        threading.Thread(target=self._pump, daemon=True).start()
        time.sleep(.5)
        for command in (
                f"/set nick {self.nick}", f"/set user_name {self.nick.lower()}",
                "/network add Ergo", f"/server add -network Ergo -noautosendcmd {HOST} 6667",
                f"/channel add -auto {CHANNEL} Ergo", "/connect Ergo",
                f"/script load {SCRIPT}", "/fs addq",
                f"/fs sett channels {CHANNEL}", "/fs sett servers Ergo",
                f"/fs sett root_dir {self.root}", f"/fs sett trigger {self.trigger}",
                "/fs sett notify_interval 10", "/fs sett min_cps 0", "/fs on"):
            self.command(command)
            time.sleep(.2)
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

    def __exit__(self, *exc):
        if self.process.poll() is None:
            self.command("/quit")
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.stopped.set()
        os.close(self.master)
        self.temporary.cleanup()


async def until(label: str, check, timeout: float = 60, every: float = .5):
    deadline = time.monotonic() + timeout
    while True:
        value = await check()
        if value:
            return value
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {label}: {value!r}")
        await asyncio.sleep(every)


@unittest.skipIf(HOST is None or SCRIPT is None or NativeIrssi is None,
                 "needs Ergo and FServe.pl (tools/fservepl_lab_check.sh)")
class FServePlLabTests(unittest.TestCase):
    def test_adverts_browse_and_two_file_servers_at_once(self):
        alpha = FServePl("FsAlpha", "!alpha", {"films/big.bin": BIG_BYTES,
                                               "films/notes.txt": b"notes\n"})
        beta = FServePl("FsBeta", "!beta", {"books/small.txt": SMALL,
                                            "books/old/older.txt": b"older\n"})
        with alpha, beta, NativeIrssi() as native:
            # FServe.pl replies through Irssi's flood control, a line about every
            # 2.2 s; the app's own default waits 30 s.
            native.command("/set fscrawl_find_quiet_ms 6000")
            native.command("/set dcc_autoget OFF")
            native.command("/set dcc_autochat OFF")
            asyncio.run(self.workflow(native, alpha))

    async def workflow(self, native, alpha):
        engine = await open_engine(native)
        with tempfile.TemporaryDirectory() as name:
            searches = None
            try:
                database = Path(name) / "fserve.sqlite3"
                sources = SourceService(database, engine)
                await sources.save(dict(label="Lab", provider="sysreset_find", host=HOST,
                                        port=6667, tls=False, nickname="Atlas",
                                        channel=CHANNEL))
                await sources.connect()

                async def ready():
                    view = sources.engine_source(await engine.status(), "primary")
                    return view if view and view["state"] == "ready" else None
                await until("the source", ready)
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                browses = downloads.browses = BrowseService(downloads)
                adverts = AdvertService(sources)

                # Both servers advertise on their own timer, as FServe.pl does.
                async def both_seen():
                    listed = (await adverts.list("primary"))["adverts"]
                    found = {advert["nick"]: advert for advert in listed}
                    return found if {"FsAlpha", "FsBeta"} <= set(found) else None
                seen = await until("both adverts", both_seen, timeout=90, every=2)
                for nick, trigger in (("FsAlpha", "!alpha"), ("FsBeta", "!beta")):
                    self.assertEqual(seen[nick]["script"], "fserve.pl")
                    self.assertEqual([(t["trigger"], t["kind"]) for t in seen[nick]["triggers"]],
                                     [(trigger, "ctcp")])

                # Browse from FsBeta's advert: one trigger, its folders read.
                view = await browses.start_from_advert("primary", "FsBeta", "!beta")

                async def browsed():
                    nonlocal view
                    view = await browses.view(view["browse_id"])
                    return view if view["state"] != "browsing" else None
                await until("the browse", browsed, timeout=90)
                self.assertEqual(view["state"], "complete", view)
                listed = await browses.view(view["browse_id"], "/books")
                self.assertEqual([entry["name"] for entry in listed["files"]], ["small.txt"])
                self.assertEqual([entry["name"] for entry in listed["folders"]], ["old"])

                # Two at once: FsAlpha's large file is still arriving when
                # FsBeta's starts, and FsBeta's arrives first.
                search = await searches.search("big")
                search = await wait_search(searches, search["search_id"], timeout=60)
                page = await searches.page(search["search_id"], offset=0, limit=10)
                found = [row for row in page["results"] if row["path"].endswith("/big.bin")]
                self.assertEqual(len(found), 1, (search, page["results"], (await engine.request(
                    "log.list", {"after": 0, "limit": 200}))["lines"][24:]))
                (big,) = found
                self.assertEqual(big["sender"], "FsAlpha")
                first = await downloads.download("lab-download-key-0001", big["result_id"])
                await wait_download(downloads, first["operation_id"],
                                    lambda row: row["state"] == "receiving",
                                    "the large file to arrive", timeout=90)
                # FsAlpha is paused, as a slow sender stalls: its file stays
                # part-way while FsBeta's is fetched.
                os.kill(alpha.process.pid, signal.SIGSTOP)
                try:
                    second = await downloads.download("lab-download-key-0002",
                                                      listed["files"][0]["result_id"])
                    done = await wait_download(
                        downloads, second["operation_id"],
                        lambda row: row["state"] in ("complete", "failed", "stale", "expired"),
                        "the small file", timeout=120)
                    self.assertEqual(done["state"], "complete", done)
                    still = await downloads.status(first["operation_id"])
                    self.assertEqual(still["state"], "receiving",
                                     "the large file was still arriving when the small one ended")
                finally:
                    os.kill(alpha.process.pid, signal.SIGCONT)
                home = native.home / "fserve-poc" / "downloads"
                self.assertEqual((home / done["download_path"]).read_bytes(), SMALL)
                large = await wait_download(
                    downloads, first["operation_id"],
                    lambda row: row["state"] in ("complete", "failed", "stale", "interrupted"),
                    "the large file", timeout=600)
                self.assertEqual(large["state"], "complete", large)
                self.assertEqual((home / large["download_path"]).stat().st_size, BIG_BYTES)
                await sources.disconnect()
            finally:
                if searches is not None:
                    await searches.close()
                await engine.close()


if __name__ == "__main__":
    unittest.main()
