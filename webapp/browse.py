"""Browsing a file server from the page (2026-10-21).

The operator presses Browse beside a file server's search result. The engine
opens that server's session once, with the result's own trigger, reads its
folders (at most two deep and 40 in all, at the session's usual pacing),
requests nothing, and closes the session. A folder it did not get to can be
browsed from in the same way. A file server seen announcing itself in the
channel can be browsed by a trigger of its announcement (2026-10-22). What it read is kept here, so the
page can walk the folders, also after a restart. A file is fetched exactly as
a file-list hit is: through ``manifest.download``, which opens a new session
and checks the file in a fresh listing of its folder before any request.
"""

from __future__ import annotations

import asyncio
from contextlib import closing, contextmanager
import os
from pathlib import Path
import re
import sqlite3
import time
import json
import uuid
from typing import Any, Iterator

from .adverts import AdvertStore, endpoint_of, nick_key
from .downloads import DownloadService
from .engine_client import EngineRequestError
from .errors import ServiceError
from .ids import BROWSE_ROW, ROUTE_KEY, SEARCH_ROW


MAX_KEPT = 10            # browses kept, newest first
ENGINE_PAGE = 100        # entries asked of the engine at a time
SHOWN_PER_FOLDER = 500   # folders and files shown of one folder
SHOWN_FOUND = 200        # files shown of a find in one browse
MAX_FIND_CHARS = 100
_BROWSE_ID = re.compile(r"browse-([0-9a-f]{32})")


class BrowseError(ServiceError):
    pass


def parent_of(path: str) -> str:
    head = path.rstrip("/").rsplit("/", 1)[0]
    return head or "/"


def _folder(path: Any) -> str:
    if not isinstance(path, str) or not path.startswith("/") or len(path) > 1024 \
            or any(ord(char) < 32 or ord(char) == 127 for char in path):
        raise BrowseError("invalid_path", "that folder is not a usable path")
    return path.rstrip("/") or "/"


class BrowseStore:
    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if not self.path.exists() or not self.path.is_file() or self.path.is_symlink():
            raise ValueError("initialize the source store before the browse store")
        with self._transaction() as connection:
            connection.execute("""
                CREATE TABLE IF NOT EXISTS browse (
                    browse_id TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL,
                    source_revision INTEGER NOT NULL,
                    host TEXT NOT NULL,
                    port INTEGER NOT NULL,
                    channel TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    trigger_text TEXT NOT NULL,
                    trigger_mode TEXT NOT NULL CHECK (trigger_mode IN ('channel_text', 'ctcp')),
                    engine_instance_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('browsing', 'complete', 'failed')),
                    note TEXT,
                    truncated INTEGER NOT NULL DEFAULT 0,
                    folders_read INTEGER NOT NULL DEFAULT 0,
                    started_at REAL NOT NULL,
                    finished_at REAL,
                    start_path TEXT NOT NULL DEFAULT '/'
                )
            """)
            connection.execute("""
                CREATE TABLE IF NOT EXISTS browse_entry (
                    browse_id TEXT NOT NULL REFERENCES browse(browse_id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('dir', 'file')),
                    path TEXT NOT NULL,
                    parent TEXT NOT NULL,
                    size_raw TEXT,
                    size_bytes INTEGER,
                    is_read INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (browse_id, ordinal)
                )
            """)
            # Columns added after the first live browse (2026-10-21).
            for table, column, kind in (("browse", "start_path", "TEXT NOT NULL DEFAULT '/'"),
                                        ("browse_entry", "is_read", "INTEGER NOT NULL DEFAULT 0")):
                if column not in {row["name"] for row in
                                  connection.execute(f"PRAGMA table_info({table})")}:
                    connection.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind}")
            connection.execute(
                "CREATE INDEX IF NOT EXISTS browse_entry_parent ON browse_entry (browse_id, parent)")

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        with closing(self._connect()) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                yield connection
                connection.execute("COMMIT")
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise

    def add(self, row: dict[str, Any]) -> None:
        with self._transaction() as connection:
            connection.execute("""
                INSERT INTO browse (browse_id, source_id, source_revision, host, port, channel,
                    sender, trigger_text, trigger_mode, engine_instance_id, state, started_at,
                    start_path)
                VALUES (:browse_id, :source_id, :source_revision, :host, :port, :channel,
                    :sender, :trigger_text, :trigger_mode, :engine_instance_id, 'browsing',
                    :started_at, :start_path)
                ON CONFLICT (browse_id) DO NOTHING
            """, row)
            old = connection.execute(
                "SELECT browse_id FROM browse ORDER BY started_at DESC LIMIT -1 OFFSET ?",
                (MAX_KEPT,)).fetchall()
            for item in old:
                connection.execute("DELETE FROM browse WHERE browse_id=?", (item["browse_id"],))

    def get(self, browse_id: str) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute("SELECT * FROM browse WHERE browse_id=?",
                                     (browse_id,)).fetchone()
        return dict(row) if row is not None else None

    def recent(self) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            rows = connection.execute("""
                SELECT browse.*, (SELECT COUNT(*) FROM browse_entry e
                    WHERE e.browse_id = browse.browse_id AND e.kind = 'file') AS files
                FROM browse ORDER BY started_at DESC""").fetchall()
        return [dict(row) for row in rows]

    def finish(self, browse_id: str, *, state: str, note: str | None, truncated: bool,
               folders_read: int, entries: list[dict[str, Any]]) -> None:
        with self._transaction() as connection:
            connection.execute("DELETE FROM browse_entry WHERE browse_id=?", (browse_id,))
            connection.executemany("""
                INSERT INTO browse_entry (browse_id, ordinal, kind, path, parent, size_raw,
                    size_bytes, is_read)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [(browse_id, number, entry["kind"], entry["path"], parent_of(entry["path"]),
                   entry.get("size_raw"), entry.get("size_bytes"), int(entry.get("read", False)))
                  for number, entry in enumerate(entries, 1)])
            connection.execute("""
                UPDATE browse SET state=?, note=?, truncated=?, folders_read=?, finished_at=?
                WHERE browse_id=?
            """, (state, note, int(truncated), folders_read, time.time(), browse_id))

    def folder(self, browse_id: str, path: str) -> tuple[list[dict[str, Any]], dict[str, int]]:
        """The first entries of each kind directly in a folder, and how many there are."""
        with closing(self._connect()) as connection:
            rows = []
            for kind in ("dir", "file"):
                rows += connection.execute("""
                    SELECT * FROM browse_entry WHERE browse_id=? AND parent=? AND kind=?
                    ORDER BY path LIMIT ?""", (browse_id, path, kind, SHOWN_PER_FOLDER)).fetchall()
            counts = dict(connection.execute("""
                SELECT kind, COUNT(*) FROM browse_entry WHERE browse_id=? AND parent=?
                GROUP BY kind""", (browse_id, path)).fetchall())
            read = connection.execute(
                "SELECT is_read FROM browse_entry WHERE browse_id=? AND kind='dir' AND path=?",
                (browse_id, path)).fetchone()
        counts["read"] = int(read is not None and bool(read[0]))
        return [dict(row) for row in rows], counts

    def find(self, browse_id: str, words: list[str]) -> tuple[list[dict[str, Any]], int]:
        """The first files whose path holds every word, ignoring case, and how many do."""
        where = " AND ".join(["instr(lower(path), ?) > 0"] * len(words))
        arguments = (browse_id, *words)
        with closing(self._connect()) as connection:
            rows = connection.execute(f"""
                SELECT * FROM browse_entry WHERE browse_id=? AND kind='file' AND {where}
                ORDER BY path LIMIT ?""", (*arguments, SHOWN_FOUND)).fetchall()
            total = connection.execute(f"""
                SELECT COUNT(*) FROM browse_entry WHERE browse_id=? AND kind='file' AND {where}
                """, arguments).fetchone()[0]
        return [dict(row) for row in rows], total

    def entry(self, browse_id: str, ordinal: int) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT * FROM browse_entry WHERE browse_id=? AND ordinal=?",
                (browse_id, ordinal)).fetchone()
        return dict(row) if row is not None else None


def _entry(raw: Any) -> dict[str, Any] | None:
    """One entry as the engine listed it, or None if it is not usable."""
    if not isinstance(raw, dict) or raw.get("type") not in ("dir", "file"):
        return None
    path = raw.get("path")
    if not isinstance(path, str) or not path.startswith("/") or len(path) > 1024 \
            or any(ord(char) < 32 or ord(char) == 127 for char in path) or path == "/":
        return None
    size_raw = raw.get("size_raw")
    size_bytes = raw.get("size_bytes")
    return {
        "kind": raw["type"], "path": path.rstrip("/"), "read": raw.get("read") is True,
        "size_raw": size_raw[:32] if isinstance(size_raw, str) else None,
        "size_bytes": size_bytes if isinstance(size_bytes, int)
        and not isinstance(size_bytes, bool) and 0 <= size_bytes < 2 ** 63 else None,
    }


class BrowseService:
    def __init__(self, downloads: DownloadService) -> None:
        self.downloads = downloads
        self.sources = downloads.sources
        self.searches = downloads.searches
        self.engine = self.sources.engine
        self.store = BrowseStore(self.sources.store.path)
        self.adverts = AdvertStore(self.sources.store.path)
        self._lock = asyncio.Lock()

    async def start(self, result_id: Any) -> dict[str, Any]:
        """Browse the file server of one of the current search's results."""
        if not isinstance(result_id, str) or not SEARCH_ROW.fullmatch(result_id):
            raise BrowseError("invalid_result", "result ID is invalid")
        stored = self.searches.store.find_result(result_id)
        if stored is None:
            raise BrowseError("unknown_result", "result history row was not found")
        if stored["trigger_mode"] not in ("channel_text", "ctcp"):
            raise BrowseError("not_browsable",
                              "only a file server with a session can be browsed; this row is "
                              "fetched by posting it back")
        search = self.searches.store.get(stored["search_id"])
        config = self.sources.store.get(search["source_id"]) if search else None
        if config is None:
            raise BrowseError("unknown_source", "the source of that result was removed")
        return await self._start(config, stored["sender"], stored["trigger_text"],
                                 stored["trigger_mode"], "/")

    async def start_from_advert(self, source_id: Any, nick: Any, trigger: Any) -> dict[str, Any]:
        """Browse a file server seen announcing itself, by a trigger it announced."""
        if not all(isinstance(value, str) and 0 < len(value) <= 128
                   for value in (source_id, nick, trigger)):
            raise BrowseError("invalid_advert", "name the source, file server and trigger")
        config = self.sources.store.get(source_id)
        if config is None:
            raise BrowseError("unknown_source", "no such source is configured")
        row = next((item for item in self.adverts.list(config.source_id, endpoint_of(config))
                    if item["nick_key"] == nick_key(nick)), None)
        if row is None:
            raise BrowseError("unknown_advert",
                              "that file server has not been seen in this source's channel")
        advert = json.loads(row["advert"])
        if advert.get("restricted"):
            raise BrowseError("not_browsable", "that file server serves only "
                              f"{advert['restricted']} users; its trigger is not sent")
        chosen = next((item for item in advert.get("triggers") or []
                       if item.get("trigger") == trigger), None)
        if chosen is None:
            raise BrowseError("unknown_advert", "that file server did not announce this trigger")
        if chosen.get("voice_only"):
            raise BrowseError("not_browsable", "that trigger is for voiced users only")
        if chosen["kind"] == "ctcp" and not chosen.get("ctcp_nick_is_sender"):
            raise BrowseError("not_browsable",
                              "that trigger names another nick than the one announcing it")
        return await self._start(config, advert["nick"], trigger,
                                 "ctcp" if chosen["kind"] == "ctcp" else "channel_text", "/")

    async def start_from_list(self, route_key: Any) -> dict[str, Any]:
        """Browse the file server a stored file list is of (2026-10-28), by the
        trigger the list was kept with, whether or not it announced lately."""
        if not isinstance(route_key, str) or not ROUTE_KEY.fullmatch(route_key):
            raise BrowseError("invalid_list", "name a stored file list")
        manifests = getattr(self.downloads, "manifests", None)
        if manifests is None:
            raise BrowseError("unknown_list", "file lists are not available")
        found = next((item for item in (await manifests.lists())["lists"]
                      if item["route_key"] == route_key), None)
        if found is None:
            raise BrowseError("unknown_list", "that file list is not stored")
        if found["trigger_mode"] not in ("channel_text", "ctcp"):
            raise BrowseError("not_browsable",
                              "a list server has no session to browse; its files are asked "
                              "for by posting their rows")
        config = self.sources.store.get(found["source_id"]) if found["source_label"] else None
        if config is None:
            raise BrowseError("unknown_source",
                              "the source of that list was removed or now names another server")
        return await self._start(config, found["sender"], found["trigger"],
                                 found["trigger_mode"], "/")

    async def start_from(self, browse_id: Any, path: Any) -> dict[str, Any]:
        """Browse again, from a folder an earlier browse of the same server did not read."""
        row = self._require(browse_id)
        folder = _folder(path)
        config = self.sources.store.get(row["source_id"])
        if config is None or (config.host.lower(), config.port) != (row["host"].lower(), row["port"]):
            raise BrowseError("stale_browse",
                              "the source now names another server; search and browse again")
        return await self._start(config, row["sender"], row["trigger_text"],
                                 row["trigger_mode"], folder)

    async def _start(self, config: Any, sender: str, trigger: str, mode: str,
                     folder: str) -> dict[str, Any]:
        status = await self.engine.status()
        live = self.sources.engine_source(status, config.source_id)
        if not live or live.get("state") != "ready" or not self.sources._matches(live, config):
            raise BrowseError("source_not_ready", f"connect {config.label} to browse its file servers")
        async with self._lock:
            try:
                reply = await self.engine.request("browse.start", {
                    "source_id": config.source_id, "sender": sender,
                    "trigger": trigger, "trigger_mode": mode,
                    **({"path": folder} if folder != "/" else {}),
                }, operation_id="browse-op-" + uuid.uuid4().hex)
            except EngineRequestError as exc:
                raise BrowseError(exc.code, exc.message) from exc
            browse_id = reply.get("browse_id") if isinstance(reply, dict) else None
            if not isinstance(browse_id, str) or not _BROWSE_ID.fullmatch(browse_id):
                raise BrowseError("engine_unavailable", "the engine did not start the browse")
            self.store.add({
                "browse_id": browse_id, "source_id": config.source_id,
                "source_revision": config.revision, "host": config.host, "port": config.port,
                "channel": config.channel, "sender": sender,
                "trigger_text": trigger, "trigger_mode": mode,
                "engine_instance_id": self.engine.engine_instance_id, "started_at": time.time(),
                "start_path": folder,
            })
        return await self.view(browse_id)

    async def _refresh(self, row: dict[str, Any]) -> dict[str, Any]:
        """A browse still running: ask the engine; once it ended, keep what it read."""
        if row["state"] != "browsing":
            return row
        gone = "The engine restarted while browsing, so nothing was kept."
        if row["engine_instance_id"] != self.engine.engine_instance_id:
            self.store.finish(row["browse_id"], state="failed", note=gone, truncated=False,
                              folders_read=0, entries=[])
            return self.store.get(row["browse_id"]) or row
        arguments = {"source_id": row["source_id"], "browse_id": row["browse_id"]}
        try:
            summary = await self.engine.request("browse.status", {**arguments, "limit": 0})
        except EngineRequestError:
            self.store.finish(row["browse_id"], state="failed", note=gone, truncated=False,
                              folders_read=0, entries=[])
            return self.store.get(row["browse_id"]) or row
        if summary.get("state") not in ("complete", "failed"):
            return {**row, "folders_read": summary.get("folders_read") or 0}
        entries: list[dict[str, Any]] = []
        total = summary.get("total") if isinstance(summary.get("total"), int) else 0
        for offset in range(0, total, ENGINE_PAGE):
            page = await self.engine.request(
                "browse.status", {**arguments, "offset": offset, "limit": ENGINE_PAGE})
            entries.extend(item for item in map(_entry, page.get("entries") or []) if item)
        note = summary.get("note")
        self.store.finish(row["browse_id"], state=summary["state"],
                          note=note[:300] if isinstance(note, str) else None,
                          truncated=summary.get("truncated") is True,
                          folders_read=summary.get("folders_read") or 0, entries=entries)
        return self.store.get(row["browse_id"]) or row

    def _require(self, browse_id: Any) -> dict[str, Any]:
        if not isinstance(browse_id, str) or not _BROWSE_ID.fullmatch(browse_id):
            raise BrowseError("invalid_browse", "browse ID is invalid")
        row = self.store.get(browse_id)
        if row is None:
            raise BrowseError("unknown_browse", "that browse is not kept any more")
        return row

    @staticmethod
    def _summary(row: dict[str, Any]) -> dict[str, Any]:
        return {
            "browse_id": row["browse_id"], "source_id": row["source_id"],
            "sender": row["sender"], "trigger": row["trigger_text"], "state": row["state"],
            "note": row["note"], "truncated": bool(row["truncated"]),
            "folders_read": row["folders_read"], "started_at": row["started_at"],
            "finished_at": row["finished_at"], "start_path": row["start_path"],
        }

    async def view(self, browse_id: Any, path: Any = None) -> dict[str, Any]:
        row = self._require(browse_id)
        folder = _folder(path if path is not None else row["start_path"])
        async with self._lock:
            row = await self._refresh(row)
        view = self._summary(row)
        entries, counts = (self.store.folder(row["browse_id"], folder)
                           if row["state"] != "browsing" else ([], {"read": 0}))
        folders = [item for item in entries if item["kind"] == "dir"]
        files = [item for item in entries if item["kind"] == "file"]
        view.update({
            "path": folder, "parent": None if folder == "/" else parent_of(folder),
            # Whether this folder's own contents were listed; one the walk
            # did not get to shows only what its parent's listing named.
            "read": row["state"] != "browsing" and (folder == row["start_path"]
                                                    or bool(counts["read"])),
            "more_folders": counts.get("dir", 0) - len(folders),
            "more_files": counts.get("file", 0) - len(files),
            "folders": [{"name": item["path"].rsplit("/", 1)[-1], "path": item["path"],
                         "read": bool(item["is_read"])} for item in folders],
            "files": [self._file(row, item) for item in files],
        })
        return view

    @staticmethod
    def _file(row: dict[str, Any], item: dict[str, Any]) -> dict[str, Any]:
        return {
            "name": item["path"].rsplit("/", 1)[-1], "path": item["path"],
            "folder": item["parent"],
            "size_text": item["size_raw"], "size_bytes": item["size_bytes"],
            "result_id": f"brow-{row['browse_id'][len('browse-'):]}-{item['ordinal']}",
        }

    async def find(self, browse_id: Any, terms: Any) -> dict[str, Any]:
        """Files anywhere in what a browse read, by words in their path; nothing is sent."""
        row = self._require(browse_id)
        if not isinstance(terms, str) or not terms.strip() or len(terms) > MAX_FIND_CHARS                 or any(ord(char) < 32 or ord(char) == 127 for char in terms):
            raise BrowseError("invalid_find", f"type 1 to {MAX_FIND_CHARS} characters to find")
        async with self._lock:
            row = await self._refresh(row)
        if row["state"] == "browsing":
            raise BrowseError("still_browsing", "wait for the browse to finish, then find")
        words = sorted(set(terms.lower().split()))[:8]
        files, total = self.store.find(row["browse_id"], words)
        return {**self._summary(row), "terms": terms, "total": total,
                "more_files": total - len(files),
                "files": [self._file(row, item) for item in files]}

    async def history(self) -> list[dict[str, Any]]:
        return [{**self._summary(row), "files": row["files"]} for row in self.store.recent()]

    async def resolve_result(self, result_id: str) -> dict[str, Any]:
        """What the engine needs to fetch one browsed file, from its source as it is now."""
        match = BROWSE_ROW.fullmatch(result_id) if isinstance(result_id, str) else None
        if match is None:
            raise BrowseError("invalid_result", "result ID is invalid")
        browse_id = "browse-" + match.group(1)
        row = self.store.get(browse_id)
        entry = self.store.entry(browse_id, int(match.group(2))) if row else None
        if row is None or entry is None or entry["kind"] != "file":
            raise BrowseError("stale_result", "that browsed file is not kept any more")
        config = self.sources.store.get(row["source_id"])
        if config is None:
            raise BrowseError("stale_result", "the source this browse came from was removed")
        if (config.host.lower(), config.port) != (row["host"].lower(), row["port"]) or (
                row["trigger_mode"] == "channel_text" and config.channel != row["channel"]):
            raise BrowseError("stale_result",
                              "the source now names another server or channel; browse again")
        status = await self.engine.status()
        live = self.sources.engine_source(status, config.source_id)
        if not live or live.get("state") != "ready" or not self.sources._matches(live, config):
            raise BrowseError("source_not_ready", f"connect {config.label} to download from it")
        return {
            "search_id": "browse-" + match.group(1), "source_id": config.source_id,
            "source_revision": config.revision,
            "engine_instance_id": self.engine.engine_instance_id,
            "engine_search_id": "browse", "engine_operation": "manifest.download",
            "engine_arguments": {
                "source_id": config.source_id, "sender": row["sender"],
                "trigger": row["trigger_text"], "trigger_mode": row["trigger_mode"],
                "path": entry["path"],
            },
            "sender": row["sender"], "path": entry["path"], "size_bytes": entry["size_bytes"],
        }


__all__ = ["BrowseError", "BrowseService", "parent_of"]
