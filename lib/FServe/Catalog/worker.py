#!/usr/bin/env python3
"""Bounded-memory SQLite worker for immutable FServe manifest snapshots."""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import errno
import hashlib
import heapq
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import unicodedata
import uuid

# 3 (2026-10-27): names are also kept without accents (fold_key), and that
# is what a search reads, so "Renee" finds "Renée".
NORMALIZER_VERSION = 3
PARSER_VERSION = "box-tree-size-v1"
MAX_ROUTES = 4096   # 32 until 2026-10-29, when a search could look in every list
MAX_QUERY_CHARS = 256
MAX_PATH_BYTES = 8192
MAX_RECORD_LINE_BYTES = 65_536
MAX_PAGE_BYTES = 512 * 1024
BATCH_ROWS = 2000
MIN_FREE_BYTES = 512 * 1024 * 1024
RESERVE_MULTIPLIER = 6
ACTIVE_PRODUCER: subprocess.Popen | None = None
CANCEL_REQUESTED = False
_TEST_CHECKPOINTS: set[str] = set()


def handle_termination(signum: int, frame: object) -> None:
    global ACTIVE_PRODUCER, CANCEL_REQUESTED
    CANCEL_REQUESTED = True
    if ACTIVE_PRODUCER is not None and ACTIVE_PRODUCER.poll() is None:
        ACTIVE_PRODUCER.terminate()
        try:
            ACTIVE_PRODUCER.wait(timeout=3)
        except subprocess.TimeoutExpired:
            ACTIVE_PRODUCER.kill()
            ACTIVE_PRODUCER.wait()
        ACTIVE_PRODUCER = None


def check_cancelled() -> None:
    if CANCEL_REQUESTED:
        raise InterruptedError("catalog worker was cancelled")


def sqlite_cancel_progress() -> int:
    """Interrupt a long SQLite validation when the worker is cancelled."""
    return 1 if CANCEL_REQUESTED else 0


def test_checkpoint(stage: str) -> None:
    """Optional deterministic barriers for isolated acceptance tests only."""
    if os.environ.get("FSERVE_CATALOG_TEST_MODE") != "1" or \
       os.environ.get("FSERVE_CATALOG_TEST_PAUSE_AT") != stage or stage in _TEST_CHECKPOINTS:
        return
    directory = os.environ.get("FSERVE_CATALOG_TEST_CHECKPOINT_DIR")
    if not directory:
        raise ValueError("test checkpoint directory is required for the selected test pause")
    checkpoint_dir = Path(directory)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    _TEST_CHECKPOINTS.add(stage)
    marker = checkpoint_dir / f"{stage}.reached"
    marker.write_text(json.dumps({"stage": stage, "pid": os.getpid()}), encoding="utf-8")
    release = checkpoint_dir / f"{stage}.release"
    while not release.exists() and not CANCEL_REQUESTED:
        time.sleep(0.01)


def sqlite_import_progress() -> int:
    if CANCEL_REQUESTED:
        return 1
    test_checkpoint("sqlite-index")
    return 1 if CANCEL_REQUESTED else 0


def apply_test_sqlite_full_limit(db: sqlite3.Connection) -> None:
    """Constrain SQLite page allocation to exercise SQLITE_FULL in a test DB."""
    if os.environ.get("FSERVE_CATALOG_TEST_MODE") != "1" or \
       os.environ.get("FSERVE_CATALOG_TEST_SQLITE_FULL_AT") != "first-index":
        return
    try:
        delta = int(os.environ.get("FSERVE_CATALOG_TEST_PAGE_LIMIT_DELTA", "1"))
    except ValueError as exc:
        raise ValueError("invalid test SQLite page-limit delta") from exc
    if delta < 1 or delta > 100_000:
        raise ValueError("test SQLite page-limit delta must be between 1 and 100000")
    pages = db.execute("PRAGMA page_count").fetchone()[0]
    db.execute(f"PRAGMA max_page_count={pages + delta}")


def emit(value: dict) -> None:
    line = json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n"
    if len(line.encode("utf-8")) > 1_048_576:
        raise ValueError("catalog worker response exceeds the 1 MiB limit")
    sys.stdout.write(line)
    sys.stdout.flush()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def process_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        # Windows os.kill(pid, 0) is not the POSIX existence probe; signals
        # other than CTRL_C_EVENT/CTRL_BREAK_EVENT may terminate the target.
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        open_process = kernel32.OpenProcess
        open_process.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        open_process.restype = wintypes.HANDLE
        wait_for_single_object = kernel32.WaitForSingleObject
        wait_for_single_object.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        wait_for_single_object.restype = wintypes.DWORD
        close_handle = kernel32.CloseHandle
        close_handle.argtypes = (wintypes.HANDLE,)
        close_handle.restype = wintypes.BOOL

        synchronize = 0x00100000
        handle = open_process(synchronize, False, pid)
        if not handle:
            error = ctypes.get_last_error()
            if error == 87:  # ERROR_INVALID_PARAMETER: no such process ID
                return False
            # Fail closed: an access/inspection failure must not expire a
            # lease that may still belong to a live process.
            return True
        try:
            state = wait_for_single_object(handle, 0)
            if state == 0:  # WAIT_OBJECT_0: the process has exited
                return False
            if state == 0x00000102:  # WAIT_TIMEOUT: still running
                return True
            # WAIT_FAILED or an unexpected status: preserve the lease.
            return True
        finally:
            close_handle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError as exc:
        return exc.errno != errno.ESRCH


def framed_digest(parts: list[bytes]) -> bytes:
    digest = hashlib.sha256()
    digest.update(b"FServeCatalogKey\x00\x01")
    for part in parts:
        digest.update(len(part).to_bytes(8, "big"))
        digest.update(part)
    return digest.digest()


def irc_fold(value: str, mapping: str) -> str:
    result = value.lower()
    if mapping in ("rfc1459", "strict-rfc1459"):
        result = result.translate(str.maketrans("{}|", "[]\\"))
        if mapping == "rfc1459":
            result = result.replace("~", "^")
    elif mapping != "ascii":
        raise ValueError("IRC casemapping must be ascii, strict-rfc1459, or rfc1459")
    return result


def fold_text(value: str) -> str:
    """Text as a search compares it: without accents, case or width."""
    decomposed = unicodedata.normalize("NFKD", value)
    bare = "".join(char for char in decomposed if not unicodedata.combining(char))
    return unicodedata.normalize("NFKC", bare).casefold()


def normalize_path(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("record has no remote path")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("remote path contains a control character")
    if re.match(r"^(?:[A-Za-z]:|[\\/]{2})", value):
        raise ValueError("remote path must be relative to the FServe root")
    path = value.replace("\\", "/")
    parts = [piece for piece in path.split("/") if piece]
    if not parts or any(piece in (".", "..") for piece in parts):
        raise ValueError("remote path contains an unsafe component")
    normalized = "/" + "/".join(parts)
    if len(normalized.encode("utf-8")) > MAX_PATH_BYTES:
        raise ValueError("remote path exceeds the 8192-byte limit")
    return normalized


def open_registry(root: Path) -> sqlite3.Connection:
    root.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(root / "catalog-registry.sqlite", timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA busy_timeout=30000")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    db.executescript("""
      CREATE TABLE IF NOT EXISTS route (
        route_id INTEGER PRIMARY KEY,
        route_key BLOB NOT NULL UNIQUE,
        network_id TEXT NOT NULL,
        server_tag TEXT NOT NULL,
        server_nick TEXT NOT NULL,
        nick_key TEXT NOT NULL,
        trigger_raw TEXT NOT NULL,
        root_profile TEXT NOT NULL,
        irc_casemapping TEXT NOT NULL,
        path_policy TEXT NOT NULL CHECK(path_policy IN ('sensitive','insensitive')),
        normalizer_version INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS route_endpoint (
        route_id INTEGER NOT NULL REFERENCES route(route_id),
        trigger_mode TEXT NOT NULL CHECK(trigger_mode IN ('ctcp','channel_text','unknown')),
        channel TEXT NOT NULL DEFAULT '',
        PRIMARY KEY(route_id,trigger_mode,channel)
      ) WITHOUT ROWID;
      CREATE TABLE IF NOT EXISTS snapshot (
        snapshot_id TEXT PRIMARY KEY,
        route_id INTEGER NOT NULL REFERENCES route(route_id),
        database_path TEXT NOT NULL UNIQUE,
        source_sha256 BLOB NOT NULL,
        parser_version TEXT NOT NULL,
        normalizer_version INTEGER NOT NULL,
        manifest_remote_path TEXT,
        observed_at TEXT NOT NULL,
        generated_at TEXT,
        row_count INTEGER NOT NULL DEFAULT 0,
        duplicate_count INTEGER NOT NULL DEFAULT 0,
        retired_at TEXT,
        status TEXT NOT NULL CHECK(status IN ('building','ready','failed','retired')),
        UNIQUE(route_id,snapshot_id)
      );
      CREATE TABLE IF NOT EXISTS active_snapshot (
        route_id INTEGER PRIMARY KEY REFERENCES route(route_id),
        snapshot_id TEXT NOT NULL,
        generation INTEGER NOT NULL,
        FOREIGN KEY(route_id,snapshot_id) REFERENCES snapshot(route_id,snapshot_id)
      );
      CREATE TABLE IF NOT EXISTS selection (
        selection_token TEXT PRIMARY KEY,
        route_id INTEGER NOT NULL,
        snapshot_id TEXT NOT NULL,
        file_key BLOB NOT NULL,
        path TEXT NOT NULL,
        query_key BLOB NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(route_id,snapshot_id) REFERENCES snapshot(route_id,snapshot_id)
      );
      CREATE INDEX IF NOT EXISTS selection_expiry ON selection(created_at);
      CREATE TABLE IF NOT EXISTS route_import_lock (
        route_id INTEGER PRIMARY KEY REFERENCES route(route_id),
        lock_token TEXT NOT NULL UNIQUE,
        owner_pid INTEGER NOT NULL,
        started_epoch REAL NOT NULL
      );
      CREATE TABLE IF NOT EXISTS fetch_lease (
        lease_token TEXT PRIMARY KEY,
        route_id INTEGER NOT NULL,
        snapshot_id TEXT NOT NULL,
        owner_pid INTEGER NOT NULL,
        created_epoch REAL NOT NULL,
        FOREIGN KEY(route_id,snapshot_id) REFERENCES snapshot(route_id,snapshot_id)
      );
    """)
    snapshot_columns = {row[1] for row in db.execute("PRAGMA table_info(snapshot)")}
    if "retired_at" not in snapshot_columns:
        db.execute("ALTER TABLE snapshot ADD COLUMN retired_at TEXT")
    cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=30)).replace(
        microsecond=0).isoformat().replace("+00:00", "Z")
    with db:
        db.execute("DELETE FROM selection WHERE created_at<?", (cutoff,))
    return db


def route_identity(context: dict, mapping: str, path_policy: str, root_profile: str) -> tuple[bytes, dict]:
    required = ("network_id", "server_tag", "server_nick", "trigger_raw")
    for name in required:
        if not isinstance(context.get(name), str) or not context[name]:
            raise ValueError(f"route is missing {name}")
    if context.get("trigger_mode") not in ("channel_text", "ctcp", "unknown"):
        raise ValueError("invalid trigger mode")
    channel = context.get("discovery_channel") or ""
    if not isinstance(channel, str) or len(channel) > 200 or any(ord(c) < 33 or ord(c) == 127 for c in channel):
        raise ValueError("route channel is unsafe or too long")
    if context["trigger_mode"] == "channel_text" and not re.fullmatch(r"[#&+!][^\s,\x00-\x1f\x7f]{0,199}", channel):
        raise ValueError("channel-text endpoint requires a safe channel name")
    if path_policy not in ("sensitive", "insensitive"):
        raise ValueError("path policy must be sensitive or insensitive")
    if not root_profile or len(root_profile) > 256 or any(ord(c) < 32 or ord(c) == 127 for c in root_profile):
        raise ValueError("root profile must contain 1 to 256 characters")
    for name in required:
        value = context[name]
        if len(value) > 256 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError(f"route field {name} is unsafe or too long")
    if any(ch.isspace() for ch in context["server_nick"]) or any(ch.isspace() for ch in context["trigger_raw"]):
        raise ValueError("server nick and trigger must be single IRC tokens")
    normalized = {
        **context,
        "network_id": context["network_id"].casefold(),
        "server_tag": context["server_tag"].casefold(),
        "nick_key": irc_fold(context["server_nick"], mapping),
        "irc_casemapping": mapping,
        "path_policy": path_policy,
        "root_profile": root_profile,
    }
    fields = [normalized[k].encode("utf-8") for k in (
        "network_id", "server_tag", "nick_key", "trigger_raw", "root_profile", "path_policy")]
    return framed_digest(fields), normalized


def register_route(db: sqlite3.Connection, route_key: bytes, route: dict) -> int:
    if db.execute("SELECT 1 FROM route WHERE route_key=?", (route_key,)).fetchone() is None:
        if db.execute("SELECT count(*) FROM route").fetchone()[0] >= MAX_ROUTES:
            raise ValueError(f"catalog is limited to {MAX_ROUTES} distinct routes")
    with db:
        db.execute("""INSERT OR IGNORE INTO route
          (route_key,network_id,server_tag,server_nick,nick_key,trigger_raw,
           root_profile,irc_casemapping,path_policy,normalizer_version)
          VALUES (?,?,?,?,?,?,?,?,?,?)""", (
            route_key, route["network_id"], route["server_tag"], route["server_nick"],
            route["nick_key"], route["trigger_raw"], route["root_profile"],
            route["irc_casemapping"], route["path_policy"], NORMALIZER_VERSION))
        row = db.execute("SELECT route_id FROM route WHERE route_key=?", (route_key,)).fetchone()
        if row is None:
            raise RuntimeError("could not create catalog route")
        route_id = row[0]
        db.execute("UPDATE route SET normalizer_version=? WHERE route_id=?",
                   (NORMALIZER_VERSION, route_id))
        db.execute("""INSERT OR IGNORE INTO route_endpoint(route_id,trigger_mode,channel)
          VALUES (?,?,?)""", (route_id, route["trigger_mode"], route.get("discovery_channel") or ""))
        return route_id


# The compact layout (2026-10-28). A list took about ten times its text: each
# row kept its path six ways and two indexes copied the keys again. Now a
# folder is kept once, a row keeps its name, and the name as a search compares
# it only when SQLite's lower() does not already give it (a plain-ASCII name
# never needs it). entry_v shows a row as the old layout did, so every reader
# asks the same columns of either; an old snapshot is read as it is until
# "compact" rewrites it. The keys, file_key included, are unchanged, so
# selections and the snapshot ID carry over.
COMPACT_VIEW = "entry_v"
PRECISIONS = ("unknown", "estimated", "exact")
_ASCII_LOWER = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")
FOLDER_CACHE = 65_536


def stored_fold(basename: str) -> str | None:
    """The searched form of a name, or None when lower() gives it."""
    folded = fold_text(basename)
    return None if folded == basename.translate(_ASCII_LOWER) else folded


def entry_source(db: sqlite3.Connection) -> str:
    """What a reader asks for a snapshot's rows: the compact view, or the old table."""
    found = db.execute("SELECT 1 FROM sqlite_master WHERE type='view' AND name=?",
                       (COMPACT_VIEW,)).fetchone()
    return COMPACT_VIEW if found else "entry"


def snapshot_schema(path: Path) -> sqlite3.Connection:
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA busy_timeout=30000")
    db.execute("PRAGMA journal_mode=DELETE")
    db.execute("PRAGMA synchronous=FULL")
    db.execute("PRAGMA cache_size=-32768")
    db.execute("PRAGMA temp_store=FILE")
    db.executescript("""
      CREATE TABLE snapshot_meta (
        route_key BLOB NOT NULL, snapshot_id TEXT NOT NULL, source_sha256 BLOB NOT NULL,
        parser_version TEXT NOT NULL, normalizer_version INTEGER NOT NULL,
        observed_at TEXT NOT NULL, manifest_remote_path TEXT, row_count INTEGER NOT NULL
      );
      CREATE TABLE folder (
        folder_id INTEGER PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        key TEXT NOT NULL
      );
      CREATE TABLE entry (
        row_id INTEGER PRIMARY KEY,
        file_key BLOB NOT NULL UNIQUE,
        folder_id INTEGER NOT NULL,
        basename TEXT NOT NULL,
        fold_key TEXT,
        size_raw TEXT,
        size_bytes INTEGER CHECK(size_bytes IS NULL OR size_bytes >= 0),
        precision INTEGER NOT NULL CHECK(precision IN (0,1,2))
      );
      CREATE VIEW entry_text AS
        SELECT row_id, COALESCE(fold_key, lower(basename)) AS fold_key FROM entry;
      CREATE VIEW entry_v AS
        SELECT e.row_id AS row_id, e.file_key AS file_key,
          CASE f.path WHEN '/' THEN '/' || e.basename ELSE f.path || '/' || e.basename END AS path,
          f.key AS parent_key, e.basename AS basename,
          COALESCE(e.fold_key, lower(e.basename)) AS name_key,
          COALESCE(e.fold_key, lower(e.basename)) AS fold_key,
          e.size_raw AS size_raw, e.size_bytes AS size_bytes,
          CASE e.precision WHEN 2 THEN 'exact' WHEN 1 THEN 'estimated' ELSE 'unknown' END
            AS size_precision
        FROM entry e JOIN folder f ON f.folder_id = e.folder_id;
    """)
    return db


class CompactWriter:
    """Rows into a compact snapshot, a folder once each."""

    def __init__(self, cursor: sqlite3.Cursor, path_policy: str) -> None:
        self.cursor = cursor
        self.insensitive = path_policy == "insensitive"
        self.folders: dict[str, int] = {}

    def folder_id(self, parent: str) -> int:
        found = self.folders.get(parent)
        if found is not None:
            return found
        if len(self.folders) >= FOLDER_CACHE:
            self.folders.clear()
        self.cursor.execute("INSERT OR IGNORE INTO folder(path,key) VALUES (?,?)",
                            (parent, parent.casefold() if self.insensitive else parent))
        found = self.cursor.execute("SELECT folder_id FROM folder WHERE path=?",
                                    (parent,)).fetchone()[0]
        self.folders[parent] = found
        return found

    def insert(self, file_key: bytes, path: str, size_raw, size_bytes, precision: str) -> None:
        parent, basename = path.rsplit("/", 1)
        self.cursor.execute("""INSERT INTO entry
          (file_key,folder_id,basename,fold_key,size_raw,size_bytes,precision)
          VALUES (?,?,?,?,?,?,?)""", (file_key, self.folder_id(parent or "/"), basename,
                                      stored_fold(basename), size_raw, size_bytes,
                                      PRECISIONS.index(precision)))


def finish_compact(db: sqlite3.Connection) -> bool:
    """The compact snapshot's indexes, once its rows are in."""
    db.execute("CREATE INDEX entry_folder ON entry(folder_id)")
    db.execute("CREATE INDEX folder_key ON folder(key)")
    fts_available = create_fts(db, "entry_text")
    if fts_available:
        db.execute("INSERT INTO entry_fts(entry_fts,rank) VALUES('integrity-check',1)")
    return fts_available


def selection_key(route_key: bytes, snapshot_id: str, file_key: bytes, query_key: bytes) -> str:
    return framed_digest([route_key, snapshot_id.encode("ascii"), file_key, query_key]).hex()


def cleanup_dead_leases(registry: sqlite3.Connection, route_id: int | None = None) -> None:
    sql = "SELECT lease_token,owner_pid,created_epoch FROM fetch_lease"
    params: tuple = ()
    if route_id is not None:
        sql += " WHERE route_id=?"
        params = (route_id,)
    for lease in registry.execute(sql, params).fetchall():
        alive = process_is_alive(lease["owner_pid"])
        if not alive or time.time() - lease["created_epoch"] > 3600:
            registry.execute("DELETE FROM fetch_lease WHERE lease_token=?", (lease["lease_token"],))


def create_fts(db: sqlite3.Connection, content: str = "entry") -> bool:
    try:
        db.execute(f"""CREATE VIRTUAL TABLE entry_fts USING fts5(
          fold_key, content='{content}', content_rowid='row_id',
          tokenize='trigram', detail='none')""")
        db.execute("INSERT INTO entry_fts(entry_fts) VALUES('rebuild')")
        return True
    except sqlite3.OperationalError as exc:
        if "no such module" in str(exc).lower() or "fts5" in str(exc).lower():
            return False
        raise


def import_manifest(args: argparse.Namespace) -> int:
    global ACTIVE_PRODUCER
    root = Path(args.root).expanduser().resolve()
    source = Path(args.source).expanduser().resolve(strict=True)
    if not source.is_file():
        raise ValueError("manifest source must be a regular local file")
    source_size = source.stat().st_size
    if source_size <= 0 or source_size > args.max_source_bytes:
        raise ValueError(f"manifest source must be between 1 and {args.max_source_bytes} bytes")
    root.mkdir(parents=True, exist_ok=True)
    usage = shutil.disk_usage(root)
    reserve = max(args.reserve_bytes, MIN_FREE_BYTES)
    required = source_size * RESERVE_MULTIPLIER + reserve
    if usage.free < required:
        raise OSError(f"insufficient free space: need about {required} bytes, have {usage.free}")

    context = json.loads(args.context_json)
    route_key, route = route_identity(context, args.irc_casemapping, args.path_policy, args.root_profile)
    registry = open_registry(root)
    route_id = register_route(registry, route_key, route)
    lock_token = uuid.uuid4().hex
    with registry:
        registry.execute("BEGIN IMMEDIATE")
        old_lock = registry.execute("SELECT lock_token,owner_pid,started_epoch FROM route_import_lock WHERE route_id=?",
                                    (route_id,)).fetchone()
        if old_lock is not None:
            alive = process_is_alive(old_lock["owner_pid"])
            stale = not alive or time.time() - old_lock["started_epoch"] > args.max_seconds + 300
            if not stale:
                raise ValueError("an import is already running for this catalog route")
            registry.execute("DELETE FROM route_import_lock WHERE route_id=?", (route_id,))
        registry.execute("INSERT INTO route_import_lock VALUES (?,?,?,?)",
                         (route_id, lock_token, os.getpid(), time.time()))
    started = time.monotonic()
    generation_row = registry.execute(
        "SELECT generation,snapshot_id FROM active_snapshot WHERE route_id=?", (route_id,)).fetchone()
    prior_generation = generation_row["generation"] if generation_row else 0
    parser_version = args.parser_version
    if parser_version != PARSER_VERSION:
        raise ValueError("worker/parser versions do not agree")

    temp_name = f".building-{uuid.uuid4().hex}.sqlite"
    temp_path = root / temp_name
    final_path: Path | None = None
    snapshot_db = None
    producer = None
    registry_snapshot_id = None
    inserted = duplicates = conflicts = rows_seen = 0
    batch_rows = 0
    last_progress = time.monotonic()
    provider_result = None
    try:
        limits = {"max_line_bytes": min(args.max_line_bytes, 65_536),
                  "max_source_bytes": args.max_source_bytes,
                  "max_rows": args.max_rows, "max_seconds": args.max_seconds}
        command = [args.perl, str(Path(args.helper).resolve()), str(source),
                   json.dumps(context, ensure_ascii=True, separators=(",", ":")),
                   str(Path(args.library).resolve()),
                   json.dumps(limits, separators=(",", ":"))]
        producer = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    bufsize=1 << 16, shell=False)
        ACTIVE_PRODUCER = producer
        snapshot_db = snapshot_schema(temp_path)
        dbcur = snapshot_db.cursor()
        writer = CompactWriter(dbcur, args.path_policy)
        dbcur.execute("BEGIN IMMEDIATE")
        while True:
            check_cancelled()
            raw = producer.stdout.readline(MAX_RECORD_LINE_BYTES + 1)
            if not raw:
                break
            if len(raw) > MAX_RECORD_LINE_BYTES:
                raise ValueError("normalized provider record exceeds the 64 KiB transport limit")
            try:
                record = json.loads(raw)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ValueError("manifest provider emitted invalid JSON") from exc
            if not isinstance(record, dict) or record.get("type") != "file":
                raise ValueError("manifest provider emitted an invalid file record")
            path = normalize_path(record.get("remote_path"))
            path_key = path.casefold() if args.path_policy == "insensitive" else path
            file_key = framed_digest([route_key, path_key.encode("utf-8")])
            size_bytes = record.get("size_bytes")
            if size_bytes is not None and (isinstance(size_bytes, bool) or not isinstance(size_bytes, int) or size_bytes < 0 or size_bytes > 9_223_372_036_854_775_807):
                raise ValueError("manifest size is outside SQLite's supported integer range")
            precision = record.get("size_precision", "estimated" if record.get("size_is_estimate") else "unknown")
            if precision not in ("unknown", "estimated", "exact"):
                raise ValueError("manifest record has an invalid size precision")
            item = (record.get("size_raw"), size_bytes, precision)
            try:
                writer.insert(file_key, path, *item)
                inserted += 1
            except sqlite3.IntegrityError as exc:
                # file_key is the path's key, so one path, or two that the
                # path policy takes as one, meet here.
                old = dbcur.execute("SELECT path,size_raw,size_bytes,size_precision FROM entry_v WHERE file_key=?",
                                    (file_key,)).fetchone()
                if old is None or old["path"] != path:
                    raise ValueError(f"manifest has colliding path identity: {path}") from exc
                # One name twice in a folder with two sizes (one real list
                # had 3,855 of 607,545, 2026-10-29): a request names the file
                # alone, so only one can be had; the first is kept.
                if tuple(old[key] for key in ("size_raw", "size_bytes", "size_precision")) != item:
                    conflicts += 1
                duplicates += 1
            rows_seen += 1
            batch_rows += 1
            if batch_rows >= BATCH_ROWS:
                snapshot_db.commit()
                dbcur.execute("BEGIN IMMEDIATE")
                batch_rows = 0
            if rows_seen > args.max_rows:
                raise ValueError(f"manifest exceeds the {args.max_rows}-record limit")
            if time.monotonic() - started > args.max_seconds:
                raise TimeoutError(f"manifest import exceeded {args.max_seconds} seconds")
            if time.monotonic() - last_progress >= 5:
                emit({"event": "progress", "rows": rows_seen, "inserted": inserted,
                      "duplicates": duplicates, "elapsed_seconds": round(time.monotonic() - started, 1)})
                last_progress = time.monotonic()
        producer.stdout.close()
        stderr = producer.stderr.read(MAX_RECORD_LINE_BYTES).decode("utf-8", "replace")
        exit_code = producer.wait(timeout=10)
        ACTIVE_PRODUCER = None
        check_cancelled()
        if exit_code:
            try:
                provider_result = json.loads(stderr.splitlines()[-1])
            except (IndexError, json.JSONDecodeError):
                provider_result = None
            reason = (provider_result or {}).get("reason", "manifest parser process failed")
            raise ValueError(reason)
        try:
            provider_result = json.loads(stderr.splitlines()[-1])
        except (IndexError, json.JSONDecodeError) as exc:
            raise ValueError("manifest parser did not return a final validation result") from exc
        if not provider_result.get("ok") or provider_result.get("records_emitted") != rows_seen:
            raise ValueError("provider result/count does not match staged records")
        if rows_seen > args.max_rows:
            raise ValueError("manifest exceeds configured row limit")
        snapshot_db.commit()
        apply_test_sqlite_full_limit(snapshot_db)
        snapshot_db.set_progress_handler(sqlite_import_progress, 1000)
        fts_available = finish_compact(snapshot_db)
        snapshot_db.execute("ANALYZE")
        check = snapshot_db.execute("PRAGMA quick_check").fetchone()[0]
        if check != "ok":
            raise RuntimeError(f"snapshot integrity check failed: {check}")
        stored_count = snapshot_db.execute("SELECT count(*) FROM entry").fetchone()[0]
        if stored_count != inserted:
            raise RuntimeError("snapshot row count differs from inserted-record count")
        observed_at = utc_now()
        snapshot_id = framed_digest([route_key, bytes.fromhex(provider_result["sha256"]),
                                     parser_version.encode("ascii"),
                                     str(NORMALIZER_VERSION).encode("ascii")]).hex()
        manifest_remote_path = context.get("manifest_remote_path")
        snapshot_db.execute("INSERT INTO snapshot_meta VALUES (?,?,?,?,?,?,?,?)", (
            route_key, snapshot_id, bytes.fromhex(provider_result["sha256"]), parser_version,
            NORMALIZER_VERSION, observed_at, manifest_remote_path, inserted))
        snapshot_db.commit()
        snapshot_db.execute("PRAGMA optimize")
        snapshot_db.close()
        snapshot_db = None
        registry_snapshot_id = snapshot_id
        existing = registry.execute("SELECT database_path,status FROM snapshot WHERE snapshot_id=?",
                                    (snapshot_id,)).fetchone()
        if existing is not None and existing["status"] in ("ready", "retired"):
            existing_path = (root / existing["database_path"]).resolve()
            reusable = False
            if existing_path.parent == root.resolve() and existing_path.is_file():
                old_db = None
                try:
                    check_cancelled()
                    old_db = sqlite3.connect(existing_path.as_uri() + "?mode=ro&immutable=1", uri=True, timeout=5)
                    old_db.set_progress_handler(sqlite_cancel_progress, 1000)
                    meta = old_db.execute("SELECT route_key,snapshot_id,source_sha256,row_count FROM snapshot_meta").fetchone()
                    integrity = old_db.execute("PRAGMA quick_check").fetchone()[0]
                    reusable = bool(meta and meta[0] == route_key and meta[1] == snapshot_id and
                                    meta[2] == bytes.fromhex(provider_result["sha256"]) and
                                    integrity == "ok" and entry_source(old_db) == COMPACT_VIEW)
                except (OSError, sqlite3.Error):
                    reusable = False
                finally:
                    if old_db is not None:
                        old_db.close()
                # SQLite reports interruption as OperationalError; do not
                # mistake a cancelled integrity check for an unusable snapshot.
                check_cancelled()
            if reusable:
                temp_path.unlink(missing_ok=True)
                with registry:
                    # Make the generation and lease decision atomic with reuse.
                    registry.execute("BEGIN IMMEDIATE")
                    check_cancelled()
                    current = registry.execute("SELECT generation,snapshot_id FROM active_snapshot WHERE route_id=?",
                                               (route_id,)).fetchone()
                    current_generation = current[0] if current else 0
                    if current_generation != prior_generation:
                        emit({"event": "error", "reason": "a newer snapshot was published while this import ran"})
                        return 3
                    cleanup_dead_leases(registry, route_id)
                    if registry.execute("SELECT 1 FROM fetch_lease WHERE route_id=? LIMIT 1", (route_id,)).fetchone():
                        emit({"event": "error", "reason": "a manifest-backed fetch is in progress; compatible snapshot was not activated"})
                        return 3
                    if current is not None and current["snapshot_id"] != snapshot_id:
                        registry.execute("UPDATE snapshot SET status='retired',retired_at=? WHERE snapshot_id=?",
                                         (utc_now(), current["snapshot_id"]))
                    registry.execute("UPDATE snapshot SET observed_at=?,generated_at=?,duplicate_count=?,status='ready' WHERE snapshot_id=?",
                                     (observed_at, provider_result.get("generated_at"), duplicates, snapshot_id))
                    if current is None or current["snapshot_id"] != snapshot_id:
                        registry.execute("""INSERT INTO active_snapshot(route_id,snapshot_id,generation)
                          VALUES (?,?,?) ON CONFLICT(route_id) DO UPDATE SET
                          snapshot_id=excluded.snapshot_id,generation=excluded.generation""",
                                         (route_id, snapshot_id, prior_generation + 1))
                        published_generation = prior_generation + 1
                        status = "reused"
                    else:
                        published_generation = current_generation
                        status = "unchanged"
                    registry.execute("DELETE FROM route_import_lock WHERE route_id=? AND lock_token=?",
                                     (route_id, lock_token))
                    # This is the cancellation boundary for the transaction:
                    # before commit, cancellation rolls back the activation.
                    check_cancelled()
                emit({"event": "result", "status": status, "route_id": route_id,
                      "route_key": route_key.hex(), "snapshot_id": snapshot_id,
                      "generation": published_generation, "records": inserted,
                      "duplicates": duplicates, "fts5": fts_available,
                      "sha256": provider_result["sha256"],
                      "elapsed_seconds": round(time.monotonic() - started, 2),
                      "snapshot_bytes": existing_path.stat().st_size})
                return 0
        final_name = f"snapshot-{snapshot_id[:20]}-{uuid.uuid4().hex[:8]}.sqlite"
        final_path = root / final_name
        os.replace(temp_path, final_path)
        with final_path.open("rb+") as published_file:
            published_file.flush()
            os.fsync(published_file.fileno())
        test_checkpoint("snapshot-renamed")
        check_cancelled()
        relative_path = final_name
        replaced_path = None
        publish_error = None
        published_generation = None
        publication_status = None
        with registry:
            # Serialize generation and lease checks with snapshot publication.
            registry.execute("BEGIN IMMEDIATE")
            check_cancelled()
            current = registry.execute("SELECT generation,snapshot_id FROM active_snapshot WHERE route_id=?",
                                       (route_id,)).fetchone()
            current_generation = current["generation"] if current else 0
            cleanup_dead_leases(registry, route_id)
            has_fetch_lease = registry.execute(
                "SELECT 1 FROM fetch_lease WHERE route_id=? LIMIT 1", (route_id,)).fetchone()
            generation_changed = current_generation != prior_generation
            same_snapshot_active = current is not None and current["snapshot_id"] == snapshot_id
            if has_fetch_lease and same_snapshot_active:
                publish_error = "a manifest-backed fetch is in progress; the active snapshot was left untouched"
            elif generation_changed and not same_snapshot_active:
                registry.execute("""INSERT INTO snapshot
                  (snapshot_id,route_id,database_path,source_sha256,parser_version,
                   normalizer_version,manifest_remote_path,observed_at,generated_at,
                   row_count,duplicate_count,status)
                  VALUES (?,?,?,?,?,?,?,?,?,?,?,'ready')
                  ON CONFLICT(snapshot_id) DO UPDATE SET
                    database_path=excluded.database_path, observed_at=excluded.observed_at,
                    generated_at=excluded.generated_at,row_count=excluded.row_count,
                    duplicate_count=excluded.duplicate_count,status='ready'""", (
                    snapshot_id, route_id, relative_path, bytes.fromhex(provider_result["sha256"]),
                    parser_version, NORMALIZER_VERSION, manifest_remote_path, observed_at,
                    provider_result.get("generated_at"), inserted, duplicates))
                publish_error = "a newer snapshot was published while this import ran; validated snapshot retained but not activated"
            elif has_fetch_lease:
                registry.execute("""INSERT INTO snapshot
                  (snapshot_id,route_id,database_path,source_sha256,parser_version,
                   normalizer_version,manifest_remote_path,observed_at,generated_at,
                   row_count,duplicate_count,status)
                  VALUES (?,?,?,?,?,?,?,?,?,?,?,'ready')
                  ON CONFLICT(snapshot_id) DO UPDATE SET
                    database_path=excluded.database_path, observed_at=excluded.observed_at,
                    generated_at=excluded.generated_at,row_count=excluded.row_count,
                    duplicate_count=excluded.duplicate_count,status='ready'""", (
                    snapshot_id, route_id, relative_path, bytes.fromhex(provider_result["sha256"]),
                    parser_version, NORMALIZER_VERSION, manifest_remote_path, observed_at,
                    provider_result.get("generated_at"), inserted, duplicates))
                publish_error = "a manifest-backed fetch is in progress; validated snapshot retained but not activated"
            else:
                # The same snapshot in the old layout, which this file replaces.
                prior = registry.execute("SELECT database_path FROM snapshot WHERE snapshot_id=?",
                                         (snapshot_id,)).fetchone()
                if prior is not None and prior["database_path"] != relative_path:
                    replaced_path = prior["database_path"]
                registry.execute("""INSERT INTO snapshot
                  (snapshot_id,route_id,database_path,source_sha256,parser_version,
                   normalizer_version,manifest_remote_path,observed_at,generated_at,
                   row_count,duplicate_count,status)
                  VALUES (?,?,?,?,?,?,?,?,?,?,?,'ready')
                  ON CONFLICT(snapshot_id) DO UPDATE SET
                    database_path=excluded.database_path, observed_at=excluded.observed_at,
                    generated_at=excluded.generated_at,row_count=excluded.row_count,
                    duplicate_count=excluded.duplicate_count,status='ready'""", (
                    snapshot_id, route_id, relative_path, bytes.fromhex(provider_result["sha256"]),
                    parser_version, NORMALIZER_VERSION, manifest_remote_path, observed_at,
                    provider_result.get("generated_at"), inserted, duplicates))
                if current is not None and current["snapshot_id"] != snapshot_id:
                    registry.execute("UPDATE snapshot SET status='retired',retired_at=? WHERE snapshot_id=?",
                                     (utc_now(), current["snapshot_id"]))
                if current is None or current["snapshot_id"] != snapshot_id or generation_changed:
                    published_generation = current_generation + 1
                    publication_status = "published" if not generation_changed else "repaired"
                    registry.execute("""INSERT INTO active_snapshot(route_id,snapshot_id,generation)
                      VALUES (?,?,?) ON CONFLICT(route_id) DO UPDATE SET
                      snapshot_id=excluded.snapshot_id,generation=excluded.generation""",
                                     (route_id, snapshot_id, published_generation))
                else:
                    published_generation = current_generation
                    publication_status = "unchanged"
            registry.execute("DELETE FROM route_import_lock WHERE route_id=? AND lock_token=?",
                             (route_id, lock_token))
            # Raising here rolls back both the registry updates and active
            # pointer; the exception handler removes the unregistered file.
            check_cancelled()
        if publish_error:
            emit({"event": "error", "reason": publish_error})
            return 3
        if replaced_path:
            remove_replaced_snapshot(root, registry, replaced_path)
        emit({"event": "result", "route_id": route_id,
              "route_key": route_key.hex(), "snapshot_id": snapshot_id,
              "status": publication_status, "generation": published_generation, "records": inserted,
              "duplicates": duplicates, "conflicting": conflicts,
              "estimated_sizes": provider_result.get("estimated_sizes", 0),
              "fts5": fts_available, "sha256": provider_result["sha256"],
              "elapsed_seconds": round(time.monotonic() - started, 2),
              "snapshot_bytes": final_path.stat().st_size})
        return 0
    except BaseException:
        if producer is not None and producer.poll() is None:
            producer.terminate()
            try:
                producer.wait(timeout=2)
            except subprocess.TimeoutExpired:
                producer.kill()
                producer.wait()
        ACTIVE_PRODUCER = None
        if snapshot_db is not None:
            snapshot_db.rollback()
            snapshot_db.close()
        try:
            temp_path.unlink(missing_ok=True)
        except OSError:
            pass
        if final_path is not None:
            try:
                published_row = registry.execute(
                    "SELECT database_path FROM snapshot WHERE snapshot_id=?", (registry_snapshot_id,)
                ).fetchone() if registry_snapshot_id else None
                if (published_row is None or published_row["database_path"] != final_path.name) and final_path.exists():
                    final_path.unlink()
            except OSError:
                pass
        if registry_snapshot_id:
            with registry:
                registry.execute("UPDATE snapshot SET status='failed' WHERE snapshot_id=? AND status='building'",
                                 (registry_snapshot_id,))
        raise
    finally:
        debug_cleanup = os.environ.get("FSERVE_CATALOG_DEBUG_IMPORT") == "1"
        if debug_cleanup:
            print(f"catalog import cleanup: begin route={route_id} transaction={registry.in_transaction}",
                  file=sys.stderr, flush=True)
        with registry:
            registry.execute("DELETE FROM route_import_lock WHERE route_id=? AND lock_token=?",
                             (route_id, lock_token))
        if debug_cleanup:
            print(f"catalog import cleanup: lock transaction committed; transaction={registry.in_transaction}",
                  file=sys.stderr, flush=True)
            print("catalog import cleanup: closing registry connection", file=sys.stderr, flush=True)
        registry.close()
        if debug_cleanup:
            print("catalog import cleanup: registry connection closed", file=sys.stderr, flush=True)


def load_active_route(registry: sqlite3.Connection, route_key: str | None) -> tuple[sqlite3.Row, sqlite3.Row]:
    if route_key:
        try:
            key = bytes.fromhex(route_key)
        except ValueError as exc:
            raise ValueError("route key must be hexadecimal") from exc
        route = registry.execute("SELECT * FROM route WHERE route_key=?", (key,)).fetchone()
    else:
        routes = registry.execute("""SELECT r.* FROM route r JOIN active_snapshot a USING(route_id)
          ORDER BY r.route_id LIMIT 2""").fetchall()
        if len(routes) != 1:
            raise ValueError("specify a route key; the catalog has zero or multiple active routes")
        route = routes[0]
    if route is None:
        raise ValueError("unknown catalog route")
    active = registry.execute("""SELECT s.*,a.generation,r.route_key AS route_key FROM active_snapshot a
      JOIN snapshot s ON s.snapshot_id=a.snapshot_id AND s.route_id=a.route_id
      JOIN route r ON r.route_id=a.route_id
      WHERE a.route_id=? AND s.status='ready'""", (route["route_id"],)).fetchone()
    if active is None:
        raise ValueError("route has no ready active manifest snapshot")
    if active["normalizer_version"] != NORMALIZER_VERSION:
        raise ValueError("active snapshot uses an old path-key format; reimport the manifest before browsing or fetching")
    return route, active


def readonly_snapshot(root: Path, snapshot: sqlite3.Row) -> sqlite3.Connection:
    path = (root / snapshot["database_path"]).resolve(strict=True)
    if path.parent != root.resolve(strict=True):
        raise ValueError("snapshot database path escaped the catalog directory")
    db = sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True, timeout=5)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    try:
        meta = db.execute("SELECT route_key,snapshot_id,row_count FROM snapshot_meta").fetchone()
        if meta is None or meta[0] != snapshot["route_key"] or \
           meta[1] != snapshot["snapshot_id"] or meta[2] != snapshot["row_count"]:
            raise ValueError("snapshot metadata does not match the registry")
    except (sqlite3.Error, ValueError) as exc:
        db.close()
        raise ValueError(f"active snapshot database is missing or corrupt: {exc}") from exc
    return db


def install_query_timeout(db: sqlite3.Connection, seconds: float = 5.0) -> None:
    if seconds <= 0 or seconds > 60:
        raise ValueError("query timeout must be between 0 and 60 seconds")
    deadline = time.monotonic() + seconds
    db.set_progress_handler(lambda: 1 if time.monotonic() >= deadline else 0, 10_000)


def decode_cursor(raw: str | None, query_key: bytes, route_key: bytes, snapshot_id: str) -> int:
    if not raw:
        return 0
    try:
        data = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, json.JSONDecodeError) as exc:
        raise ValueError("invalid catalog cursor") from exc
    if not isinstance(data, dict):
        raise ValueError("invalid catalog cursor")
    if data.get("v") != 1 or data.get("q") != query_key.hex() or \
       data.get("r") != route_key.hex() or data.get("s") != snapshot_id:
        raise ValueError("catalog cursor belongs to a different query or expired snapshot")
    last = data.get("last", 0)
    if isinstance(last, bool) or not isinstance(last, int) or last < 0:
        raise ValueError("invalid catalog cursor position")
    return last


def encode_cursor(query_key: bytes, route_key: bytes, snapshot_id: str, last: int) -> str:
    payload = json.dumps({"v": 1, "q": query_key.hex(), "r": route_key.hex(),
                          "s": snapshot_id, "last": last}, sort_keys=True, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(payload).decode().rstrip("=")


def cursor_query_key(mode: str, value: str) -> bytes:
    return framed_digest([mode.encode("ascii"), value.encode("utf-8"),
                          str(NORMALIZER_VERSION).encode("ascii")])


def format_selected_page(registry: sqlite3.Connection, route: sqlite3.Row,
                         snapshot: sqlite3.Row, query_key: bytes,
                         rows: list[sqlite3.Row], has_more: bool,
                         query: str, cursor_kind: str) -> dict:
    endpoints = [dict(mode=row[0], channel=row[1]) for row in registry.execute(
        "SELECT trigger_mode,channel FROM route_endpoint WHERE route_id=? ORDER BY trigger_mode,channel",
        (route["route_id"],))]
    page_count = min(50, len(rows))
    result = None
    while page_count >= 0:
        selected_rows = rows[:page_count]
        more = has_more or len(rows) > page_count
        next_cursor = None
        if more and selected_rows:
            last = selected_rows[-1]
            if cursor_kind == "row":
                next_cursor = encode_cursor(query_key, route["route_key"],
                                            snapshot["snapshot_id"], last["row_id"])
            elif cursor_kind == "name":
                payload = {"v": 1, "q": query_key.hex(), "r": route["route_key"].hex(),
                           "s": snapshot["snapshot_id"], "name": last["name_key"],
                           "row": last["row_id"]}
                next_cursor = base64.urlsafe_b64encode(json.dumps(
                    payload, sort_keys=True, separators=(",", ":")).encode()).decode().rstrip("=")
        selections = []
        for row in selected_rows:
            token = selection_key(route["route_key"], snapshot["snapshot_id"], row["file_key"], query_key)
            parent = row["path"].rsplit("/", 1)[0] or "/"
            selections.append({"token": token, "path": row["path"], "parent": parent,
                "name": row["basename"], "server_nick": route["server_nick"],
                "server_tag": route["server_tag"], "network_id": route["network_id"],
                "trigger_raw": route["trigger_raw"], "size_raw": row["size_raw"],
                "size_bytes": row["size_bytes"], "size_precision": row["size_precision"],
                "route_key": route["route_key"].hex(), "snapshot_id": snapshot["snapshot_id"],
                "generation": snapshot["generation"]})
        result = {"event": "result", "route_key": route["route_key"].hex(),
                  "snapshot_id": snapshot["snapshot_id"], "generation": snapshot["generation"],
                  "query": query, "rows": selections, "endpoint_modes": endpoints,
                  "has_more": more, "next_cursor": next_cursor}
        if len(json.dumps(result, ensure_ascii=True, separators=(",", ":")).encode("utf-8")) <= MAX_PAGE_BYTES:
            break
        page_count -= 1
    if result is None or page_count < 0:
        raise ValueError("one catalog result exceeds the 512 KiB page limit")
    with registry:
        for row in rows[:page_count]:
            token = selection_key(route["route_key"], snapshot["snapshot_id"], row["file_key"], query_key)
            registry.execute("""INSERT OR IGNORE INTO selection
              (selection_token,route_id,snapshot_id,file_key,path,query_key,created_at)
              VALUES (?,?,?,?,?,?,?)""", (token, route["route_id"], snapshot["snapshot_id"],
                                              row["file_key"], row["path"], query_key, utc_now()))
    return result


def manifest_search(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser().resolve(strict=True)
    term = unicodedata.normalize("NFKC", args.query).casefold()
    if not term or len(term) > MAX_QUERY_CHARS or any(ord(c) < 32 or ord(c) == 127 for c in term):
        raise ValueError("search text must contain 1 to 256 characters")
    if len(term) < 3:
        raise ValueError("filename substring search needs at least three characters")
    registry = open_registry(root)
    db = None
    try:
        route, snapshot = load_active_route(registry, args.route_key)
        db = readonly_snapshot(root, snapshot)
        install_query_timeout(db, getattr(args, "query_timeout", 5.0))
        has_fts = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='entry_fts'").fetchone()
        if not has_fts:
            raise ValueError("this snapshot has no trigram index; use manifest-prefix or parent browsing")
        query_key = cursor_query_key("substring", term)
        last_row = decode_cursor(args.cursor, query_key, route["route_key"], snapshot["snapshot_id"])
        # Every word, in any order (2026-10-27); a snapshot made since then
        # also compares without accents. The index is asked for the longest
        # word, and each word is then checked in the name.
        source = entry_source(db)
        folded = source == COMPACT_VIEW or any(
            row[1] == "fold_key" for row in db.execute("PRAGMA table_info(entry)"))
        key = "fold_key" if folded else "name_key"
        words = list(dict.fromkeys((fold_text(term) if folded else term).split()))
        runs = [run for word in words for run in re.findall(r"[^%_]+", word)]
        candidate = max(runs, key=len) if runs else ""
        if not candidate or len(candidate) < 3:
            raise ValueError("search for at least one word of three or more characters")
        like_pattern = f"%{candidate}%"
        checks = " ".join(f"AND instr(e.{key},?)>0" for _ in words)
        matches = db.execute(f"""SELECT e.row_id,e.file_key,e.path,e.parent_key,e.basename,
            e.size_raw,e.size_bytes,e.size_precision FROM entry_fts f
            JOIN {source} e ON e.row_id=f.rowid
            WHERE f.{key} LIKE ? {checks} AND f.rowid>?
            ORDER BY f.rowid LIMIT 51""", (like_pattern, *words, last_row)).fetchall()
        has_more = len(matches) > 50
        page = matches[:50]
        db.close()
        db = None
        emit(format_selected_page(registry, route, snapshot, query_key, page,
                                  has_more, term, "row"))
        return 0
    finally:
        if db is not None:
            db.close()
        registry.close()


def prefix_upper_bound(prefix: str) -> str | None:
    points = [ord(char) for char in prefix]
    for position in range(len(points) - 1, -1, -1):
        if points[position] < 0x10FFFF:
            return "".join(chr(point) for point in points[:position]) + chr(points[position] + 1)
    return None


def manifest_browse(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser().resolve(strict=True)
    value = args.value
    registry = open_registry(root)
    db = None
    try:
        route, snapshot = load_active_route(registry, args.route_key)
        db = readonly_snapshot(root, snapshot)
        install_query_timeout(db, getattr(args, "query_timeout", 5.0))
        source = entry_source(db)
        if args.mode == "parent":
            if value.replace("\\", "/").strip("/"):
                value = normalize_path(value)
            else:
                value = "/"
            if route["path_policy"] == "insensitive":
                value = value.casefold()
            query_key = cursor_query_key("parent", value)
            if args.cursor:
                try:
                    cursor = json.loads(base64.urlsafe_b64decode(args.cursor + "=" * (-len(args.cursor) % 4)))
                except (ValueError, json.JSONDecodeError) as exc:
                    raise ValueError("invalid catalog cursor") from exc
                if not isinstance(cursor, dict) or cursor.get("v") != 1 or cursor.get("q") != query_key.hex() or \
                   cursor.get("r") != route["route_key"].hex() or cursor.get("s") != snapshot["snapshot_id"]:
                    raise ValueError("catalog cursor belongs to a different query or expired snapshot")
                last_name, last_id = cursor.get("name", ""), cursor.get("row", 0)
                if not isinstance(last_name, str) or isinstance(last_id, bool) or not isinstance(last_id, int) or last_id < 0:
                    raise ValueError("invalid catalog cursor position")
            else:
                last_name, last_id = "", 0
            rows = db.execute(f"""SELECT row_id,file_key,path,parent_key,basename,name_key,
              size_raw,size_bytes,size_precision FROM {source}
              WHERE parent_key=? AND (name_key,row_id)>(?,?)
              ORDER BY name_key,row_id LIMIT 51""", (value, last_name, last_id)).fetchall()
        elif args.mode == "prefix":
            # A compact snapshot's names are kept as a search compares them.
            term = (fold_text(value) if source == COMPACT_VIEW
                    else unicodedata.normalize("NFKC", value).casefold())
            if not term or len(term) > MAX_QUERY_CHARS:
                raise ValueError("filename prefix must contain 1 to 256 characters")
            query_key = cursor_query_key("prefix", term)
            if args.cursor:
                try:
                    cursor = json.loads(base64.urlsafe_b64decode(args.cursor + "=" * (-len(args.cursor) % 4)))
                except (ValueError, json.JSONDecodeError) as exc:
                    raise ValueError("invalid catalog cursor") from exc
                if not isinstance(cursor, dict) or cursor.get("v") != 1 or cursor.get("q") != query_key.hex() or \
                   cursor.get("r") != route["route_key"].hex() or cursor.get("s") != snapshot["snapshot_id"]:
                    raise ValueError("catalog cursor belongs to a different query or expired snapshot")
                last_name, last_id = cursor.get("name", ""), cursor.get("row", 0)
                if not isinstance(last_name, str) or isinstance(last_id, bool) or not isinstance(last_id, int) or last_id < 0:
                    raise ValueError("invalid catalog cursor position")
            else:
                last_name, last_id = "", 0
            upper = prefix_upper_bound(term)
            if upper is None:
                sql = f"""SELECT row_id,file_key,path,parent_key,basename,name_key,size_raw,size_bytes,size_precision
                  FROM {source} WHERE name_key>=? AND (name_key,row_id)>(?,?)
                  ORDER BY name_key,row_id LIMIT 51"""
                params = (term, last_name, last_id)
            else:
                sql = f"""SELECT row_id,file_key,path,parent_key,basename,name_key,size_raw,size_bytes,size_precision
                  FROM {source} WHERE name_key>=? AND name_key<? AND (name_key,row_id)>(?,?)
                  ORDER BY name_key,row_id LIMIT 51"""
                params = (term, upper, last_name, last_id)
            rows = db.execute(sql, params).fetchall()
        else:
            value = normalize_path(value)
            value = value.casefold() if route["path_policy"] == "insensitive" else value
            query_key = cursor_query_key("exact", value)
            # A path's file_key is its key's digest, in either layout.
            rows = db.execute(f"""SELECT row_id,file_key,path,parent_key,basename,
              size_raw,size_bytes,size_precision FROM {source} WHERE file_key=? LIMIT 1""",
                              (framed_digest([route["route_key"], value.encode("utf-8")]),)).fetchall()
        has_more = args.mode != "exact" and len(rows) > 50
        page = rows[:50]
        db.close()
        db = None
        emit(format_selected_page(registry, route, snapshot, query_key, page,
                                  has_more, f"{args.mode}:{value}",
                                  "name" if args.mode in ("parent", "prefix") else "none"))
        return 0
    finally:
        if db is not None:
            db.close()
        registry.close()


def list_routes(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser().resolve(strict=True)
    registry = open_registry(root)
    routes = registry.execute("""SELECT r.route_id,r.route_key,r.network_id,r.server_tag,
      r.server_nick,r.trigger_raw,r.root_profile,a.snapshot_id,a.generation,s.row_count,
      s.observed_at FROM route r LEFT JOIN active_snapshot a USING(route_id)
      LEFT JOIN snapshot s ON s.snapshot_id=a.snapshot_id WHERE a.snapshot_id IS NOT NULL
      ORDER BY r.network_id,r.server_nick,r.trigger_raw LIMIT ?""", (MAX_ROUTES + 1,)).fetchall()
    if len(routes) > MAX_ROUTES:
        raise ValueError(f"route listing exceeds the {MAX_ROUTES}-route display limit")
    emit({"event": "result", "routes": [{k: (row[k].hex() if k == "route_key" else row[k])
         for k in row.keys()} for row in routes]})
    registry.close()
    return 0


def remove_route(args: argparse.Namespace) -> int:
    """Forget one file server's stored list, as Delete on the Servers page asks
    (2026-10-29): its route, every snapshot of it and their files. A list
    being imported, or a file of it being checked before a download, is
    left alone."""
    root = Path(args.root).expanduser().resolve(strict=True)
    if not re.fullmatch(r"[0-9a-f]{64}", args.route_key):
        raise ValueError("that file list is not known")
    registry = open_registry(root)
    try:
        with registry:
            registry.execute("BEGIN IMMEDIATE")
            route = registry.execute("SELECT route_id,server_nick FROM route WHERE route_key=?",
                                     (bytes.fromhex(args.route_key),)).fetchone()
            if route is None:
                raise ValueError("that file list is not known")
            route_id = route["route_id"]
            lock = registry.execute("SELECT owner_pid FROM route_import_lock WHERE route_id=?",
                                    (route_id,)).fetchone()
            if lock is not None and process_is_alive(lock["owner_pid"]):
                raise ValueError("that list is being read; try again when it is done")
            cleanup_dead_leases(registry, route_id)
            if registry.execute("SELECT 1 FROM fetch_lease WHERE route_id=? LIMIT 1",
                                (route_id,)).fetchone():
                raise ValueError("a file from that list is being checked for a download")
            paths, sources = [], []
            for row in registry.execute("""SELECT database_path,source_sha256,manifest_remote_path
                                           FROM snapshot WHERE route_id=?""",
                                        (route_id,)).fetchall():
                path = (root / row["database_path"]).resolve()
                if path.parent != root:
                    raise ValueError("refusing to remove a snapshot outside the catalog directory")
                paths.append(path)
                # What the list was read from, so the caller may find its file.
                sources.append({"sha256": bytes(row["source_sha256"]).hex(),
                                "remote_path": row["manifest_remote_path"]})
            for table in ("selection", "active_snapshot", "snapshot", "route_endpoint",
                          "route_import_lock"):
                registry.execute(f"DELETE FROM {table} WHERE route_id=?", (route_id,))
            registry.execute("DELETE FROM route WHERE route_id=?", (route_id,))
        for path in paths:
            for name in (path, *(Path(str(path) + suffix) for suffix in ("-journal", "-wal", "-shm"))):
                name.unlink(missing_ok=True)
    finally:
        registry.close()
    emit({"event": "result", "removed": len(paths), "server_nick": route["server_nick"],
          "sources": sources})
    return 0


def collect_snapshots(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser().resolve(strict=True)
    if args.retention_days < 1 or args.retention_days > 3650:
        raise ValueError("retention must be between 1 and 3650 days")
    registry = open_registry(root)
    cutoff_epoch = time.time() - args.retention_days * 86400
    cutoff_text = dt.datetime.fromtimestamp(cutoff_epoch, dt.timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z")
    cleanup_dead_leases(registry)
    active = {row[0] for row in registry.execute("SELECT snapshot_id FROM active_snapshot")}
    protected_routes = set()
    for lock in registry.execute("SELECT route_id,owner_pid,started_epoch FROM route_import_lock").fetchall():
        if process_is_alive(lock["owner_pid"]):
            protected_routes.add(lock["route_id"])
        else:
            with registry:
                registry.execute("DELETE FROM route_import_lock WHERE route_id=?", (lock["route_id"],))
    candidates = []
    for row in registry.execute("""SELECT snapshot_id,route_id,database_path,status,
        COALESCE(retired_at,observed_at) AS age FROM snapshot
        WHERE status IN ('retired','ready','failed','building')""").fetchall():
        if row["snapshot_id"] in active or row["route_id"] in protected_routes:
            continue
        if row["age"] >= cutoff_text:
            continue
        if registry.execute("SELECT 1 FROM fetch_lease WHERE snapshot_id=? LIMIT 1",
                            (row["snapshot_id"],)).fetchone():
            continue
        candidates.append(row)

    to_unlink = []
    if args.apply:
        with registry:
            for row in candidates:
                db_path = (root / row["database_path"]).resolve()
                if db_path.parent != root:
                    raise ValueError("refusing to collect a snapshot outside the catalog directory")
                registry.execute("DELETE FROM selection WHERE snapshot_id=?", (row["snapshot_id"],))
                registry.execute("DELETE FROM snapshot WHERE snapshot_id=? AND route_id=?",
                                 (row["snapshot_id"], row["route_id"]))
                to_unlink.append(db_path)

    referenced = {row[0] for row in registry.execute("SELECT database_path FROM snapshot")}
    orphan_paths = []
    # An unregistered snapshot can be between file rename and registry commit.
    # Likewise, a building database has no route row linking it to its owner.
    # Do not collect either class while any live import could be publishing it.
    if not protected_routes:
        for path in root.iterdir():
            if path.is_file() and re.fullmatch(r"snapshot-[0-9a-f]{20}-[0-9a-f]{8}\.sqlite", path.name) and \
               path.name not in referenced and path.stat().st_mtime < cutoff_epoch:
                orphan_paths.append(path)
    building_paths = [] if protected_routes else [path for path in root.iterdir()
        if path.is_file() and re.fullmatch(r"\.building-[0-9a-f]{32}\.sqlite", path.name) and
        path.stat().st_mtime < cutoff_epoch]
    candidates_size = 0
    for row in candidates:
        candidate_path = (root / row["database_path"]).resolve()
        if candidate_path.parent == root and candidate_path.is_file():
            candidates_size += candidate_path.stat().st_size
            for suffix in ("-journal", "-wal", "-shm"):
                sidecar = Path(str(candidate_path) + suffix)
                if sidecar.is_file():
                    candidates_size += sidecar.stat().st_size
    removed_files = 0
    removed_bytes = 0
    if args.apply:
        deletion_paths = set()
        for path in [*to_unlink, *orphan_paths, *building_paths]:
            deletion_paths.add(path)
            deletion_paths.update(Path(str(path) + suffix)
                                  for suffix in ("-journal", "-wal", "-shm"))
        for path in sorted(deletion_paths, key=lambda item: str(item)):
            try:
                size = path.stat().st_size
                path.unlink(missing_ok=True)
                removed_files += 1
                removed_bytes += size
            except OSError:
                continue
    emit({"event": "result", "dry_run": not args.apply,
          "retired_candidates": len(candidates), "candidate_bytes": candidates_size,
          "orphan_candidates": len(orphan_paths), "building_candidates": len(building_paths),
          "removed_files": removed_files, "removed_bytes": removed_bytes,
          "retention_days": args.retention_days})
    registry.close()
    return 0


def resolve_selection(args: argparse.Namespace) -> int:
    root = Path(args.root).expanduser().resolve(strict=True)
    registry = open_registry(root)
    db = None
    try:
        row = registry.execute("""SELECT s.selection_token,s.route_id,s.snapshot_id,s.file_key,s.path,
          r.route_key,r.network_id,r.server_tag,r.server_nick,r.trigger_raw,r.irc_casemapping,
          r.root_profile,r.path_policy,a.generation,a.snapshot_id AS active_id,
          snap.normalizer_version AS selection_normalizer_version
          FROM selection s JOIN route r USING(route_id)
          LEFT JOIN active_snapshot a USING(route_id)
          LEFT JOIN snapshot snap ON snap.snapshot_id=s.snapshot_id
          WHERE s.selection_token=? AND snap.database_path IS NOT NULL
          AND snap.status IN ('ready','retired')""", (args.selection,)).fetchone()
        if row is None:
            raise ValueError("selection has expired or is unknown; search the catalog again")
        if row["selection_normalizer_version"] != NORMALIZER_VERSION:
            raise ValueError("selection belongs to an old catalog format; reimport and search again")
        if row["active_id"] != row["snapshot_id"]:
            raise ValueError("selection is stale because the route's manifest snapshot changed; search again")
        active = registry.execute("""SELECT s.*,r.route_key AS route_key FROM snapshot s
          JOIN route r ON r.route_id=s.route_id
          WHERE s.snapshot_id=? AND s.route_id=? AND s.status='ready'""",
                                  (row["snapshot_id"], row["route_id"])).fetchone()
        db = readonly_snapshot(root, active)
        install_query_timeout(db, getattr(args, "query_timeout", 5.0))
        entry = db.execute(f"SELECT path,parent_key,basename,size_raw,size_bytes,size_precision FROM {entry_source(db)} WHERE file_key=?",
                           (row["file_key"],)).fetchone()
        db.close()
        db = None
        if entry is None or entry["path"] != row["path"]:
            raise ValueError("selected file identity no longer matches its snapshot")
        endpoints = registry.execute("SELECT trigger_mode,channel FROM route_endpoint WHERE route_id=?",
                                     (row["route_id"],)).fetchall()
        lease_token = None
        if args.command == "check" and args.acquire:
            if args.owner_pid <= 0:
                raise ValueError("invalid client process identifier")
            lease_token = args.lease_token or uuid.uuid4().hex
            if not re.fullmatch(r"[0-9a-f]{32}", lease_token):
                raise ValueError("invalid fetch lease token")
            with registry:
                registry.execute("BEGIN IMMEDIATE")
                cleanup_dead_leases(registry, row["route_id"])
                current = registry.execute("SELECT snapshot_id FROM active_snapshot WHERE route_id=?",
                                           (row["route_id"],)).fetchone()
                if current is None or current[0] != row["snapshot_id"]:
                    raise ValueError("selection became stale while it was being acquired; search again")
                registry.execute("INSERT INTO fetch_lease VALUES (?,?,?,?,?)",
                                 (lease_token, row["route_id"], row["snapshot_id"],
                                  args.owner_pid, time.time()))
        elif args.command == "check" and args.lease_token:
            if args.owner_pid <= 0:
                raise ValueError("invalid client process identifier")
            with registry:
                registry.execute("BEGIN IMMEDIATE")
                lease = registry.execute("""SELECT route_id,snapshot_id,owner_pid FROM fetch_lease
                  WHERE lease_token=?""", (args.lease_token,)).fetchone()
                current = registry.execute("SELECT snapshot_id FROM active_snapshot WHERE route_id=?",
                                           (row["route_id"],)).fetchone()
                if lease is None or lease["route_id"] != row["route_id"] or \
                   lease["snapshot_id"] != row["snapshot_id"] or lease["owner_pid"] != args.owner_pid or \
                   current is None or current[0] != row["snapshot_id"]:
                    raise ValueError("fetch lease expired or selection became stale; refusing GET")
                registry.execute("UPDATE fetch_lease SET created_epoch=? WHERE lease_token=?",
                                 (time.time(), args.lease_token))
                lease_token = args.lease_token
        emit({"event": "result", "valid": True, "selection": args.selection,
              "snapshot_id": row["snapshot_id"], "generation": row["generation"],
              "file_key": row["file_key"].hex(), "route_key": row["route_key"].hex(),
              "network_id": row["network_id"], "server_tag": row["server_tag"],
              "server_nick": row["server_nick"], "trigger_raw": row["trigger_raw"],
              "root_profile": row["root_profile"], "path": entry["path"],
              "parent": entry["path"].rsplit("/", 1)[0] or "/", "name": entry["basename"],
              "size_raw": entry["size_raw"], "size_bytes": entry["size_bytes"],
              "size_precision": entry["size_precision"],
              "endpoint_modes": [dict(mode=e[0], channel=e[1]) for e in endpoints],
              "fetch_lease": lease_token})
        return 0
    finally:
        if db is not None:
            db.close()
        registry.close()


def remove_replaced_snapshot(root: Path, registry: sqlite3.Connection, relative: str) -> None:
    """Delete a snapshot file no registry row names any longer."""
    if registry.execute("SELECT 1 FROM snapshot WHERE database_path=?", (relative,)).fetchone():
        return
    old = (root / relative).resolve()
    if old.parent != root.resolve() or not re.fullmatch(
            r"snapshot-[0-9a-f]{20}-[0-9a-f]{8}\.sqlite", old.name):
        return
    for suffix in ("", "-journal", "-wal", "-shm"):
        Path(str(old) + suffix).unlink(missing_ok=True)


def compact_snapshots(args: argparse.Namespace) -> int:
    """Rewrite each ready snapshot still in the old layout in the compact one
    (2026-10-28), from its own rows: nothing is fetched or parsed again, and
    its snapshot ID, row keys and selections stay as they were."""
    root = Path(args.root).expanduser().resolve(strict=True)
    registry = open_registry(root)
    compacted = []
    try:
        rows = registry.execute("""SELECT s.snapshot_id,s.route_id,s.database_path,s.row_count,
            r.path_policy FROM snapshot s JOIN route r USING(route_id)
            WHERE s.status='ready' AND s.normalizer_version=? ORDER BY s.snapshot_id""",
            (NORMALIZER_VERSION,)).fetchall()
        for row in rows:
            check_cancelled()
            old_path = (root / row["database_path"]).resolve()
            if old_path.parent != root or not old_path.is_file():
                continue
            old = sqlite3.connect(old_path.as_uri() + "?mode=ro&immutable=1", uri=True, timeout=5)
            old.row_factory = sqlite3.Row
            try:
                if entry_source(old) == COMPACT_VIEW:
                    continue
                usage = shutil.disk_usage(root)
                if usage.free < old_path.stat().st_size + MIN_FREE_BYTES:
                    emit({"event": "progress", "skipped": row["snapshot_id"],
                          "reason": "not enough free space to rewrite it"})
                    continue
                with registry:
                    registry.execute("BEGIN IMMEDIATE")
                    if registry.execute("SELECT 1 FROM route_import_lock WHERE route_id=?",
                                        (row["route_id"],)).fetchone():
                        continue   # an import is publishing this route
                    registry.execute("INSERT INTO route_import_lock VALUES (?,?,?,?)",
                                     (row["route_id"], uuid.uuid4().hex, os.getpid(), time.time()))
                temp_path = root / f".building-{uuid.uuid4().hex}.sqlite"
                new = None
                try:
                    new = snapshot_schema(temp_path)
                    cursor = new.cursor()
                    writer = CompactWriter(cursor, row["path_policy"])
                    cursor.execute("BEGIN IMMEDIATE")
                    meta = old.execute("SELECT * FROM snapshot_meta").fetchone()
                    cursor.execute("INSERT INTO snapshot_meta VALUES (?,?,?,?,?,?,?,?)",
                                   tuple(meta))
                    count = 0
                    for item in old.execute("""SELECT file_key,path,size_raw,size_bytes,size_precision
                                               FROM entry ORDER BY row_id"""):
                        writer.insert(item["file_key"], item["path"], item["size_raw"],
                                      item["size_bytes"], item["size_precision"])
                        count += 1
                        if count % BATCH_ROWS == 0:
                            check_cancelled()
                    if count != row["row_count"]:
                        raise RuntimeError("the rewritten snapshot's rows differ from the registry's count")
                    new.commit()
                    finish_compact(new)
                    new.execute("ANALYZE")
                    if new.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                        raise RuntimeError("the rewritten snapshot failed its integrity check")
                    new.commit()
                    new.close()
                    new = None
                    final_name = f"snapshot-{row['snapshot_id'][:20]}-{uuid.uuid4().hex[:8]}.sqlite"
                    os.replace(temp_path, root / final_name)
                    with (root / final_name).open("rb+") as published:
                        os.fsync(published.fileno())
                    with registry:
                        registry.execute("UPDATE snapshot SET database_path=? WHERE snapshot_id=?",
                                         (final_name, row["snapshot_id"]))
                    old.close()
                    old = None
                    remove_replaced_snapshot(root, registry, row["database_path"])
                    compacted.append({"snapshot_id": row["snapshot_id"],
                                      "bytes_before": old_path.stat().st_size if old_path.exists() else None,
                                      "bytes_after": (root / final_name).stat().st_size})
                finally:
                    if new is not None:
                        new.close()
                    temp_path.unlink(missing_ok=True)
                    with registry:
                        registry.execute("DELETE FROM route_import_lock WHERE route_id=? AND owner_pid=?",
                                         (row["route_id"], os.getpid()))
            finally:
                if old is not None:
                    old.close()
        emit({"event": "result", "compacted": compacted})
        return 0
    finally:
        registry.close()


def release_lease(args: argparse.Namespace) -> int:
    if not re.fullmatch(r"[0-9a-f]{32}", args.lease_token):
        raise ValueError("invalid fetch lease token")
    root = Path(args.root).expanduser().resolve(strict=True)
    registry = open_registry(root)
    with registry:
        removed = registry.execute("DELETE FROM fetch_lease WHERE lease_token=?",
                                   (args.lease_token,)).rowcount
    registry.close()
    emit({"event": "result", "released": bool(removed)})
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    sub = root.add_subparsers(dest="command", required=True)
    imp = sub.add_parser("import")
    imp.add_argument("--root", required=True)
    imp.add_argument("--source", required=True)
    imp.add_argument("--context-json", required=True)
    imp.add_argument("--perl", required=True)
    imp.add_argument("--library", required=True)
    imp.add_argument("--helper", default=str(Path(__file__).with_name("ManifestStream.pl")))
    imp.add_argument("--irc-casemapping", choices=("ascii", "strict-rfc1459", "rfc1459"), default="rfc1459")
    imp.add_argument("--path-policy", choices=("sensitive", "insensitive"), default="sensitive")
    imp.add_argument("--root-profile", required=True)
    imp.add_argument("--parser-version", default=PARSER_VERSION)
    imp.add_argument("--max-line-bytes", type=int, default=65_536)
    imp.add_argument("--max-source-bytes", type=int, default=1_073_741_824)
    imp.add_argument("--max-rows", type=int, default=5_000_000)
    imp.add_argument("--max-seconds", type=int, default=3_600)
    imp.add_argument("--reserve-bytes", type=int, default=MIN_FREE_BYTES)
    search = sub.add_parser("search")
    search.add_argument("--root", required=True)
    search.add_argument("--route-key")
    search.add_argument("--query", required=True)
    search.add_argument("--cursor")
    search.add_argument("--query-timeout", type=float, default=5.0)
    routes = sub.add_parser("routes")
    routes.add_argument("--root", required=True)
    gc = sub.add_parser("gc")
    gc.add_argument("--root", required=True)
    gc.add_argument("--retention-days", type=int, default=30)
    gc.add_argument("--apply", action="store_true")
    browse = sub.add_parser("browse")
    browse.add_argument("--root", required=True)
    browse.add_argument("--route-key")
    browse.add_argument("--mode", choices=("parent", "exact", "prefix"), required=True)
    browse.add_argument("--value", required=True)
    browse.add_argument("--cursor")
    browse.add_argument("--query-timeout", type=float, default=5.0)
    resolve = sub.add_parser("resolve")
    resolve.add_argument("--root", required=True)
    resolve.add_argument("--selection", required=True)
    check = sub.add_parser("check")
    check.add_argument("--root", required=True)
    check.add_argument("--selection", required=True)
    check.add_argument("--acquire", action="store_true")
    check.add_argument("--lease-token")
    check.add_argument("--owner-pid", type=int, default=os.getpid())
    check.add_argument("--query-timeout", type=float, default=5.0)
    release = sub.add_parser("release")
    release.add_argument("--root", required=True)
    release.add_argument("--lease-token", required=True)
    compact = sub.add_parser("compact")
    compact.add_argument("--root", required=True)
    remove = sub.add_parser("remove")
    remove.add_argument("--root", required=True)
    remove.add_argument("--route-key", required=True)
    return root


def main() -> int:
    global CANCEL_REQUESTED
    CANCEL_REQUESTED = False
    _TEST_CHECKPOINTS.clear()
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, handle_termination)
    args = parser().parse_args()
    try:
        if args.command == "import":
            return import_manifest(args)
        if args.command == "search":
            return manifest_search(args)
        if args.command == "routes":
            return list_routes(args)
        if args.command == "gc":
            return collect_snapshots(args)
        if args.command == "compact":
            return compact_snapshots(args)
        if args.command == "remove":
            return remove_route(args)
        if args.command == "browse":
            return manifest_browse(args)
        if args.command in ("resolve", "check"):
            return resolve_selection(args)
        if args.command == "release":
            return release_lease(args)
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError, TimeoutError,
            InterruptedError) as exc:
        reason = "catalog worker was cancelled" if CANCEL_REQUESTED else str(exc)
        emit({"event": "error", "reason": reason[:1000]})
        return 2
    return 2


if __name__ == "__main__":
    sys.exit(main())
