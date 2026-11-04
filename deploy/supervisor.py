"""Container entry point: run Irssi and the web service as one unit.

Irssi needs a terminal, so it gets a private pseudo-terminal whose output is
discarded; the product never reads or types into it beyond a final `/quit`.
If either process exits, the other is stopped and the container exits, so a
half-running application is never left behind. Nothing connects to IRC here:
the engine starts disconnected and stays that way until the operator asks.

Started as root (since 2026-10-28, as on unRAID, whose shares belong to
nobody:users), it first gives /config, and the top of /downloads, to the user
PUID:PGID (1000:1000 unless set), then becomes that user before anything else
runs: root only ever fixes ownership. Started as another user (the compose
file pins 1000:1000), it runs as that user and changes no ownership.
"""

from __future__ import annotations

import os
from pathlib import Path
import pty
import signal
import subprocess
import sys
import time


APP_ROOT = Path(os.environ.get("FSERVE_APP_ROOT", "/app"))
CONFIG_DIR = Path(os.environ.get("FSERVE_CONFIG_DIR", "/config"))
DOWNLOAD_DIR = Path(os.environ.get("FSERVE_DOWNLOAD_DIR", "/downloads"))
IRSSI_HOME = CONFIG_DIR / "irssi"
# Lists and search bots' result lists are kept apart from the downloads.
LISTS_DIR = CONFIG_DIR / "lists"
SOCKET_PATH = IRSSI_HOME / "fserve-poc" / "engine.sock"
ENGINE_START_SECONDS = 30
STOP_SECONDS = 8
ADAPTER = APP_ROOT / "engine" / "dccatlas.pl"
# The product owns this Irssi home completely, so its configuration is
# rewritten on every start: no stored servers, no auto-connect, no automatic
# reconnect, and the engine settings this image needs. The browser configures
# the only source. Irssi gives a received file its dcc_file_create_mode with
# fchmod, which the umask does not touch (irc/dcc/dcc-get.c), so the mode the
# umask allows is worked out here.
IRSSI_CONFIG = """servers = ( );
chatnets = {{ }};
channels = ( );
settings = {{
  core = {{
    real_name = "user";
    user_name = "user";
    nick = "user";
    settings_autosave = "no";
    server_reconnect_time = "-1";
  }};
  "irc/dcc" = {{ dcc_autoget = "no"; dcc_file_create_mode = "{file_mode}"; }};
  "perl/core/scripts" = {{
    fscrawl_library_dir = "{library}";
    fscrawl_python_executable = "python3";
    fscrawl_download_dir = "{downloads}";
    fscrawl_lists_dir = "{lists}";
    fscrawl_auto_recovery = "no";
  }};
}};
"""


def irssi_config() -> str:
    umask = os.umask(0)
    os.umask(umask)
    return IRSSI_CONFIG.format(file_mode=f"{0o666 & ~umask:o}", library=APP_ROOT / "lib",
                               downloads=DOWNLOAD_DIR, lists=LISTS_DIR)


def log(message: str) -> None:
    print(f"[dccatlas] {message}", flush=True)


def _id_setting(name: str) -> int:
    raw = os.environ.get(name, "1000").strip()
    if not raw.isdigit() or int(raw) == 0 or int(raw) > 2 ** 31 - 2:
        raise SystemExit(f"[dccatlas] {name} must be a user or group number other than 0 "
                         "(DCCAtlas does not run as root)")
    return int(raw)


def _give(path: Path, uid: int, gid: int) -> None:
    status = os.lstat(path)
    if (status.st_uid, status.st_gid) != (uid, gid):
        os.lchown(path, uid, gid)


def become_user() -> None:
    """When started as root: hand over the volumes, then drop to PUID:PGID."""
    if os.getuid() != 0:
        return
    uid, gid = _id_setting("PUID"), _id_setting("PGID")
    umask = os.environ.get("UMASK", "").strip()
    if umask and (len(umask) > 4 or any(char not in "01234567" for char in umask)):
        raise SystemExit("[dccatlas] UMASK must be an octal number such as 022 or 002")
    for directory in (CONFIG_DIR, DOWNLOAD_DIR):
        directory.mkdir(parents=True, exist_ok=True)
    # Everything under /config is the application's own; under /downloads
    # only the folder itself is, so files kept there are left as they are.
    for root, directories, files in os.walk(CONFIG_DIR):
        for name in (*directories, *files):
            _give(Path(root) / name, uid, gid)
    _give(CONFIG_DIR, uid, gid)
    # The downloads folder may be a network share (on unRAID, /mnt/remotes),
    # whose owner is set where it is mounted and cannot be changed from here.
    # That is not fatal: whether the folder is writable is checked next.
    try:
        _give(DOWNLOAD_DIR, uid, gid)
    except OSError as exc:
        log(f"{DOWNLOAD_DIR} keeps its owner ({exc.strerror}); it must be writable by "
            f"user {uid}, group {gid}")
    if umask:
        os.umask(int(umask, 8))
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
    os.environ["HOME"] = str(CONFIG_DIR)
    log(f"running as user {uid}, group {gid}")


def prepare_directories() -> None:
    for directory in (CONFIG_DIR, DOWNLOAD_DIR):
        if not directory.is_dir() or not os.access(directory, os.W_OK | os.X_OK):
            raise SystemExit(
                f"[dccatlas] {directory} must be a directory writable by uid {os.getuid()}; "
                "fix the volume ownership and start again")
    autorun = IRSSI_HOME / "scripts" / "autorun"
    autorun.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(IRSSI_HOME, 0o700)
    config = IRSSI_HOME / "config"
    config.write_text(irssi_config(), encoding="utf-8")
    os.chmod(config, 0o600)
    # Irssi loads everything in scripts/autorun at startup; always point it
    # at the adapter shipped in this image.
    link = autorun / ADAPTER.name
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(ADAPTER)


class Supervisor:
    def __init__(self) -> None:
        self.irssi: subprocess.Popen | None = None
        self.web: subprocess.Popen | None = None
        self.master: int | None = None
        self.stopping = False

    def request_stop(self, *_args) -> None:
        self.stopping = True

    def start_irssi(self) -> None:
        self.master, slave = pty.openpty()
        os.set_blocking(self.master, False)
        environment = dict(os.environ, TERM="xterm", LC_ALL="C.UTF-8",
                           PERL5LIB=str(APP_ROOT / "lib"))
        self.irssi = subprocess.Popen(
            ["irssi", "--noconnect", "--home=" + str(IRSSI_HOME)],
            stdin=slave, stdout=slave, stderr=slave, env=environment,
            start_new_session=True,
        )
        os.close(slave)

    def drain_terminal(self) -> None:
        if self.master is None:
            return
        try:
            while os.read(self.master, 65536):
                pass
        except (BlockingIOError, OSError):
            pass

    def wait_for_engine(self) -> bool:
        deadline = time.monotonic() + ENGINE_START_SECONDS
        while time.monotonic() < deadline and not self.stopping:
            self.drain_terminal()
            if self.irssi.poll() is not None:
                return False
            if SOCKET_PATH.is_socket():
                return True
            time.sleep(0.1)
        return False

    def start_web(self) -> None:
        environment = dict(
            os.environ,
            FSERVE_CONFIG_DIR=str(CONFIG_DIR),
            FSERVE_ENGINE_SOCKET=str(SOCKET_PATH),
            FSERVE_HTTP_HOST=os.environ.get("FSERVE_HTTP_HOST", "0.0.0.0"),
            PYTHONPATH=str(APP_ROOT),
        )
        self.web = subprocess.Popen(
            [sys.executable, "-m", "webapp"], cwd=APP_ROOT, env=environment,
            start_new_session=True,
        )

    @staticmethod
    def _wait(process: subprocess.Popen, seconds: float) -> bool:
        try:
            process.wait(timeout=seconds)
            return True
        except subprocess.TimeoutExpired:
            return False

    def stop_children(self) -> None:
        if self.web is not None and self.web.poll() is None:
            self.web.terminate()
            if not self._wait(self.web, STOP_SECONDS):
                self.web.kill()
                self.web.wait()
        if self.irssi is not None and self.irssi.poll() is None:
            try:
                os.write(self.master, b"/quit\n")
            except OSError:
                pass
            if not self._wait(self.irssi, STOP_SECONDS):
                self.irssi.terminate()
                if not self._wait(self.irssi, 2):
                    # The whole session: Irssi plus any helper it started.
                    try:
                        os.killpg(self.irssi.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    self.irssi.wait()
        if self.master is not None:
            os.close(self.master)
            self.master = None

    def run(self) -> int:
        signal.signal(signal.SIGTERM, self.request_stop)
        signal.signal(signal.SIGINT, self.request_stop)
        become_user()
        prepare_directories()
        try:
            self.start_irssi()
            if not self.wait_for_engine():
                if not self.stopping:
                    log("the engine did not start; check that /config is writable")
                return 0 if self.stopping else 1
            self.start_web()
            log("started; the engine is disconnected until you connect from the browser")
            while not self.stopping:
                self.drain_terminal()
                if self.irssi.poll() is not None:
                    log(f"the engine exited with status {self.irssi.returncode}")
                    return 1
                if self.web.poll() is not None:
                    log(f"the web service exited with status {self.web.returncode}")
                    return 1
                time.sleep(0.2)
            return 0
        finally:
            self.stop_children()


if __name__ == "__main__":
    sys.exit(Supervisor().run())
