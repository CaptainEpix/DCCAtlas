"""One search across several places: live sources and stored file lists.

Nothing here talks to the engine. A combined search asks each chosen source
through `SearchService`, one query per source, and looks each chosen
file list up through `ManifestService`, which sends nothing. It presents all
of that as one list. Sources searched with @find are asked all at once
(2026-10-27): each is its own connection, and the engine paces each as it
always did. A search bot's source is asked after them, one at a time, as
the engine runs a search bot's search alone. Every row stays what it was: a
live row is the row of its own source's search, and a file-list row names
its list, so how a row was found and how it is downloaded do not change.
"""

from __future__ import annotations

import asyncio
from contextlib import closing
import logging
import os
import re
import sqlite3
import time
import uuid
from typing import Any

from .searches import (MAX_PAGE_SIZE, MAX_RESULTS, TERMINAL_STATES, SearchError,
                       SearchService, validate_terms)
from .sources import SEARCHBOT


logger = logging.getLogger("dccatlas.web")

# The owner's decision of 2026-10-13: at most five sources per search.
MAX_SOURCES_PER_SEARCH = 5
# File lists send nothing, so they are not counted among the five, and since
# 2026-10-29 a search may look in every stored list: the catalog's own bound.
MAX_LISTS_PER_SEARCH = 4096
# Lists looked in at once; each is one catalog worker.
LISTS_AT_ONCE = 4
MAX_GROUPS = 30
# Longest wait for the sources asked together: the 30-second query spacing,
# the engine's 150-second collection limit, and slack.
MEMBER_WAIT_SECONDS = 210.0
POLL_SECONDS = 1.0
LISTS_CACHE_SECONDS = 5.0
FILE_LIST = "file_list"


class MultiSearchStore:
    """Which searches and file-list lookups belong to one combined search."""

    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = database
        with closing(self._connect()) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute("""
                    CREATE TABLE IF NOT EXISTS multi_search (
                        group_id TEXT PRIMARY KEY,
                        terms TEXT NOT NULL,
                        state TEXT NOT NULL CHECK (state IN ('running','complete','interrupted')),
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )
                """)
                connection.execute("""
                    CREATE TABLE IF NOT EXISTS multi_search_member (
                        group_id TEXT NOT NULL REFERENCES multi_search(group_id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        source_id TEXT NOT NULL,
                        label TEXT NOT NULL,
                        channel TEXT NOT NULL,
                        search_id TEXT,
                        note TEXT,
                        PRIMARY KEY (group_id, position)
                    )
                """)
                # A member may also be a stored file list. Its rows are kept
                # here, because nothing else stores a file-list lookup.
                columns = {row["name"] for row in connection.execute(
                    "PRAGMA table_info(multi_search_member)")}
                for name, definition in (
                        ("kind", "TEXT NOT NULL DEFAULT 'source'"),
                        ("route_key", "TEXT"),
                        ("listed_at", "TEXT"),
                        ("result_count", "INTEGER NOT NULL DEFAULT 0"),
                        ("capped", "INTEGER NOT NULL DEFAULT 0"),
                        ("finished", "INTEGER NOT NULL DEFAULT 0")):
                    if name not in columns:
                        connection.execute(
                            f"ALTER TABLE multi_search_member ADD COLUMN {name} {definition}")
                connection.execute("""
                    CREATE TABLE IF NOT EXISTS multi_search_row (
                        group_id TEXT NOT NULL REFERENCES multi_search(group_id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        ordinal INTEGER NOT NULL,
                        token TEXT NOT NULL,
                        path TEXT NOT NULL,
                        sender TEXT NOT NULL,
                        trigger_text TEXT NOT NULL,
                        size_text TEXT NOT NULL,
                        size_bytes INTEGER,
                        size_precision TEXT NOT NULL,
                        PRIMARY KEY (group_id, position, ordinal)
                    )
                """)
                connection.execute("COMMIT")
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    def create(self, group_id: str, terms: str, members: list[dict[str, Any]]) -> None:
        now = time.time()
        with closing(self._connect()) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute(
                    "INSERT INTO multi_search VALUES (?, ?, 'running', ?, ?)",
                    (group_id, terms, now, now))
                connection.executemany("""
                    INSERT INTO multi_search_member
                        (group_id, position, source_id, label, channel, kind, route_key, listed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [(group_id, position, member["source_id"], member["label"],
                       member["channel"], member.get("kind", "source"),
                       member.get("route_key"), member.get("listed_at"))
                      for position, member in enumerate(members)])
                connection.execute("""
                    DELETE FROM multi_search WHERE group_id IN (
                        SELECT group_id FROM multi_search
                        ORDER BY created_at DESC, group_id DESC LIMIT -1 OFFSET ?
                    )
                """, (MAX_GROUPS,))
                connection.execute("COMMIT")
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise

    def get(self, group_id: str) -> tuple[dict[str, Any], list[dict[str, Any]]] | None:
        with closing(self._connect()) as connection:
            group = connection.execute(
                "SELECT * FROM multi_search WHERE group_id=?", (group_id,)).fetchone()
            if group is None:
                return None
            members = connection.execute(
                "SELECT * FROM multi_search_member WHERE group_id=? ORDER BY position",
                (group_id,)).fetchall()
        return dict(group), [dict(member) for member in members]

    def recent(self, limit: int) -> list[str]:
        with closing(self._connect()) as connection:
            rows = connection.execute(
                "SELECT group_id FROM multi_search ORDER BY created_at DESC, group_id DESC "
                "LIMIT ?", (limit,)).fetchall()
        return [row["group_id"] for row in rows]

    def set_member(self, group_id: str, position: int, *, search_id: str | None = None,
                   note: str | None = None, result_count: int | None = None,
                   capped: bool | None = None, finished: bool | None = None) -> None:
        with closing(self._connect()) as connection:
            connection.execute("""
                UPDATE multi_search_member SET search_id=COALESCE(?, search_id),
                    note=COALESCE(?, note), result_count=COALESCE(?, result_count),
                    capped=COALESCE(?, capped), finished=COALESCE(?, finished)
                WHERE group_id=? AND position=?
            """, (search_id, note, result_count,
                  None if capped is None else int(capped),
                  None if finished is None else int(finished), group_id, position))

    def add_rows(self, group_id: str, position: int, first: int,
                 rows: list[dict[str, Any]]) -> None:
        with closing(self._connect()) as connection:
            connection.executemany("""
                INSERT OR IGNORE INTO multi_search_row VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [(group_id, position, first + index, row["token"], row["path"],
                   row["sender"], row["trigger"], row["size_text"], row["size_bytes"],
                   row["size_precision"]) for index, row in enumerate(rows)])

    def rows(self, group_id: str, position: int, offset: int, limit: int
             ) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            found = connection.execute("""
                SELECT * FROM multi_search_row
                WHERE group_id=? AND position=? AND ordinal>=? ORDER BY ordinal LIMIT ?
            """, (group_id, position, offset, limit)).fetchall()
        return [dict(row) for row in found]

    def set_state(self, group_id: str, state: str) -> None:
        with closing(self._connect()) as connection:
            connection.execute(
                "UPDATE multi_search SET state=?, updated_at=? WHERE group_id=?",
                (state, time.time(), group_id))

    def running(self) -> list[str]:
        with closing(self._connect()) as connection:
            rows = connection.execute(
                "SELECT group_id FROM multi_search WHERE state='running'").fetchall()
        return [row["group_id"] for row in rows]


def _text(value: Any, maximum: int) -> str:
    if not isinstance(value, str):
        return ""
    return "".join(char for char in value if ord(char) >= 32 and ord(char) != 127)[:maximum]


class MultiSearchService:
    def __init__(self, searches: SearchService, manifests: Any = None) -> None:
        self.searches = searches
        self.sources = searches.sources
        self.store = MultiSearchStore(searches.store.path)
        # Set by the runtime: looks stored file lists up. Without it a
        # combined search can ask sources only.
        self.manifests = manifests
        self._lists: dict[str, dict[str, Any]] = {}
        self._lists_read = 0.0
        self._task: asyncio.Task[None] | None = None
        self._running: str | None = None
        self._lock = asyncio.Lock()
        self._page_lock = asyncio.Lock()

    async def startup(self) -> None:
        """A search that was running when the application stopped is over."""
        for group_id in self.store.running():
            if group_id != self._running:
                self.store.set_state(group_id, "interrupted")

    async def close(self) -> None:
        task, self._task = self._task, None
        if task is not None:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        if self._running is not None:
            self.store.set_state(self._running, "interrupted")
            self._running = None

    # -- stored file lists ---------------------------------------------------

    async def refresh(self, *, force: bool = False) -> None:
        """Re-read which file lists are stored; a replaced list ends its old rows."""
        if self.manifests is None:
            return
        if not force and time.monotonic() - self._lists_read < LISTS_CACHE_SECONDS:
            return
        try:
            listed = (await self.manifests.lists())["lists"]
        except Exception:
            return   # keep the last view; a download still checks for itself
        self._lists = {item["route_key"]: item for item in listed
                       if isinstance(item.get("route_key"), str)}
        self._lists_read = time.monotonic()

    def _list_is_current(self, member: dict[str, Any]) -> bool:
        current = self._lists.get(member["route_key"] or "")
        return bool(current and current.get("listed_at") == member["listed_at"]
                    and current.get("source_label") is not None)

    # -- starting ------------------------------------------------------------

    @staticmethod
    def _chosen(value: Any, what: str) -> list[str]:
        if value is None:
            return []
        if (not isinstance(value, list) or not all(isinstance(item, str) for item in value)
                or len(set(value)) != len(value)):
            raise SearchError("invalid_request", f"choose the {what} to search")
        return value

    async def start(self, terms: Any, source_ids: Any, list_keys: Any = None
                    ) -> dict[str, Any]:
        query = validate_terms(terms)
        source_ids = self._chosen(source_ids, "sources")
        list_keys = self._chosen(list_keys, "file lists")
        if not source_ids and not list_keys:
            raise SearchError("invalid_request", "choose the sources to search")
        if len(source_ids) > MAX_SOURCES_PER_SEARCH:
            raise SearchError(
                "invalid_request",
                f"one search may ask at most {MAX_SOURCES_PER_SEARCH} sources")
        if len(list_keys) > MAX_LISTS_PER_SEARCH:
            raise SearchError(
                "invalid_request",
                f"one search may look in at most {MAX_LISTS_PER_SEARCH} file lists")
        members: list[dict[str, Any]] = []
        for source_id in source_ids:
            config = self.sources.store.get(source_id)
            if config is None:
                raise SearchError("unknown_source", "no such source is configured")
            members.append({"kind": "source", "source_id": source_id,
                            "label": config.label, "channel": config.channel})
        if list_keys:
            if self.manifests is None:
                raise SearchError("unknown_list", "no file list is stored")
            await self.refresh(force=True)
            for key in list_keys:
                listed = self._lists.get(key)
                if listed is None:
                    raise SearchError("unknown_list", "no such file list is stored")
                members.append({
                    "kind": "list", "route_key": key,
                    "source_id": listed.get("source_id") or "",
                    "label": _text(f"{listed.get('sender')} {listed.get('trigger')}", 200),
                    "channel": _text(listed.get("source_label"), 80),
                    "listed_at": listed.get("listed_at"),
                })
        async with self._lock:
            if self._task is not None and not self._task.done():
                raise SearchError("search_active", "wait for the current search to finish")
            group_id = "multi-" + uuid.uuid4().hex
            self.store.create(group_id, query, members)
            self._running = group_id
            self._task = asyncio.create_task(self._run(group_id, query, members))
        return self.summary(group_id)

    async def _run(self, group_id: str, terms: str, members: list[dict[str, Any]]) -> None:
        """File lists first, as they send nothing; then every @find source at
        once, one query each; then each search bot's source, one at a time."""
        try:
            at_once = asyncio.Semaphore(LISTS_AT_ONCE)

            async def look(position: int, member: dict[str, Any]) -> None:
                async with at_once:
                    await self._look_in_list(group_id, position, member, terms)

            await asyncio.gather(*(look(position, member)
                                   for position, member in enumerate(members)
                                   if member["kind"] == "list"))
            sources = [(position, member) for position, member in enumerate(members)
                       if member["kind"] == "source"]
            alone = [item for item in sources if self._provider(item[1]) == SEARCHBOT]
            together = [item for item in sources if item not in alone]
            if together:
                await self._ask(group_id, terms, together)
            for item in alone:
                await self._ask(group_id, terms, [item])
            self.store.set_state(group_id, "complete")
        except Exception:
            # Whatever went wrong, the search is over: it must not be shown
            # as still running, and nothing is asked again.
            logger.exception("a combined search stopped unexpectedly")
            self.store.set_state(group_id, "interrupted")
        finally:
            if self._running == group_id:
                self._running = None

    def _provider(self, member: dict[str, Any]) -> str | None:
        config = self.sources.store.get(member["source_id"])
        return getattr(config, "provider", None)

    async def _ask(self, group_id: str, terms: str,
                   chosen: list[tuple[int, dict[str, Any]]]) -> None:
        """Send each source its query, then wait until every one has ended."""
        waiting = []
        for position, member in chosen:
            try:
                started = await self.searches.search(terms, member["source_id"])
            except SearchError as exc:
                self.store.set_member(group_id, position, note=exc.message)
                continue
            self.store.set_member(group_id, position, search_id=started["search_id"])
            waiting.append(started["search_id"])
        deadline = time.monotonic() + MEMBER_WAIT_SECONDS
        while waiting and time.monotonic() < deadline:
            still = []
            for search_id in waiting:
                try:
                    current = await self.searches.status(search_id)
                except SearchError:
                    continue
                if current["state"] not in TERMINAL_STATES and not current["historical"]:
                    still.append(search_id)
            waiting = still
            if waiting:
                await asyncio.sleep(POLL_SECONDS)

    async def _look_in_list(self, group_id: str, position: int,
                            member: dict[str, Any], terms: str) -> None:
        """Copy up to the first thousand matches of one stored list. Sends nothing."""
        count, cursor, more = 0, None, False
        try:
            while count < MAX_RESULTS:
                page = await self.manifests.search(terms, member["route_key"], cursor)
                found = page.get("results") or []
                rows = []
                for row in found[:MAX_RESULTS - count]:
                    result_id = row.get("result_id")
                    precision = row.get("size_precision")
                    size = row.get("size_bytes")
                    rows.append({
                        "token": result_id[len("mrow-"):] if isinstance(result_id, str) else "",
                        "path": _text(row.get("path"), 4096),
                        "sender": _text(row.get("sender"), 64),
                        "trigger": _text(row.get("trigger"), 128),
                        "size_text": _text(row.get("size_text"), 4096),
                        "size_bytes": size if isinstance(size, int)
                        and not isinstance(size, bool) and size >= 0 else None,
                        "size_precision": precision
                        if precision in ("exact", "estimated") else "unknown",
                    })
                self.store.add_rows(group_id, position, count, rows)
                count += len(rows)
                cursor = page.get("next_cursor")
                more = bool(page.get("has_more")) and bool(cursor)
                if not more or not found:
                    break
            self.store.set_member(group_id, position, result_count=count,
                                  capped=more, finished=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            message = getattr(exc, "message", None) or "the file list could not be searched"
            self.store.set_member(group_id, position, result_count=count,
                                  note=_text(message, 300))

    # -- reading -------------------------------------------------------------

    def _require(self, group_id: Any) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        if not isinstance(group_id, str) or not re.fullmatch(r"multi-[0-9a-f]{32}", group_id):
            raise SearchError("unknown_search", "search was not found")
        found = self.store.get(group_id)
        if found is None:
            raise SearchError("unknown_search", "search was not found")
        return found

    def _member_view(self, group: dict[str, Any], member: dict[str, Any]) -> dict[str, Any]:
        view = {"kind": member["kind"], "position": member["position"],
                "source_id": member["source_id"], "label": member["label"],
                "channel": member["channel"], "search_id": member["search_id"],
                "result_count": 0, "historical": True, "note": member["note"]}
        if member["kind"] == "list":
            # A stored list: its rows are downloadable while that same list
            # is still the stored one and its source is still configured.
            view.update(provider=FILE_LIST, route_key=member["route_key"],
                        listed_at=member["listed_at"],
                        result_count=member["result_count"],
                        capped=bool(member["capped"]),
                        historical=not self._list_is_current(member))
            if member["note"]:
                view["state"] = "failed"
            elif member["finished"]:
                view["state"] = "complete"
            else:
                view["state"] = "waiting" if group["state"] == "running" else "interrupted"
            view["engine_state"] = view["state"]
            return view
        child = self.searches.snapshot(member["search_id"]) if member["search_id"] else None
        if child is not None:
            view.update(state=child["state"], engine_state=child["engine_state"],
                        provider=child.get("provider"),
                        result_count=min(child["result_count"], MAX_RESULTS),
                        historical=child["historical"], note=child["note"])
        elif member["note"]:
            view["state"] = "failed"
        else:
            view["state"] = "waiting" if group["state"] == "running" else "interrupted"
        return view

    def summary(self, group_id: Any) -> dict[str, Any]:
        group, members = self._require(group_id)
        views = [self._member_view(group, member) for member in members]
        return {
            "group_id": group["group_id"], "terms": group["terms"],
            "state": group["state"], "started_at": group["created_at"],
            "members": views,
            "result_count": sum(view["result_count"] for view in views),
            "max_sources": MAX_SOURCES_PER_SEARCH,
        }

    async def status(self, group_id: Any) -> dict[str, Any]:
        """The summary, after re-reading which file lists are stored."""
        await self.refresh()
        return self.summary(group_id)

    async def history(self, *, limit: int = 20) -> list[dict[str, Any]]:
        """Recent combined searches, newest first, each with what it searched."""
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_GROUPS:
            raise SearchError("invalid_page", "history page size is out of range")
        await self.refresh()
        return [self.summary(group_id) for group_id in self.store.recent(limit)]

    def _list_row(self, group_id: str, member: dict[str, Any],
                  row: dict[str, Any]) -> dict[str, Any]:
        available = bool(row["token"]) and not member["historical"]
        precision = row["size_precision"]
        return {
            "row_key": f"{group_id}:{member['position']}:{row['ordinal']}",
            "result_id": "mrow-" + row["token"] if available else None,
            "selection_available": available,
            "ordinal": row["ordinal"] + 1,
            "sender": row["sender"],
            "trigger": row["trigger_text"],
            "trigger_mode": FILE_LIST,
            "path": row["path"],
            "size_text": row["size_text"],
            "size_precision": precision,
            "size_bytes_exact": row["size_bytes"] if precision == "exact" else None,
            "size_bytes_estimate": row["size_bytes"] if precision == "estimated" else None,
        }

    async def page(self, group_id: Any, *, offset: int = 0,
                   limit: int = MAX_PAGE_SIZE) -> dict[str, Any]:
        """One page of the combined list: each place's rows in the order asked."""
        if (isinstance(offset, bool) or not isinstance(offset, int) or offset < 0
                or offset > MAX_RESULTS * (MAX_SOURCES_PER_SEARCH + MAX_LISTS_PER_SEARCH)):
            raise SearchError("invalid_page", "offset is out of range")
        if (isinstance(limit, bool) or not isinstance(limit, int)
                or not 1 <= limit <= MAX_PAGE_SIZE):
            raise SearchError("invalid_page", f"page size must be between 1 and {MAX_PAGE_SIZE}")
        async with self._page_lock:
            summary = await self.status(group_id)
            results: list[dict[str, Any]] = []
            skip, want = offset, limit
            for member in summary["members"]:
                count = member["result_count"]
                if want <= 0 or (member["kind"] == "source" and not member["search_id"]):
                    continue
                if skip >= count:
                    skip -= count
                    continue
                take = min(want, count - skip)
                # Every row says where it came from and how it was found.
                origin = {"source_id": member["source_id"], "source_label": member["label"],
                          "provider": member.get("provider")}
                if member["kind"] == "list":
                    origin["listed_at"] = member["listed_at"]
                    for row in self.store.rows(summary["group_id"], member["position"],
                                               skip, take):
                        results.append({**self._list_row(summary["group_id"], member, row),
                                        **origin})
                else:
                    page = await self.searches.page(member["search_id"], offset=skip, limit=take)
                    for row in page["results"]:
                        results.append({**row, **origin})
                want -= take
                skip = 0
            summary = self.summary(group_id)
            summary.update(offset=offset, page_size=limit,
                           returned_count=len(results), results=results)
            return summary
