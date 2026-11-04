"""Persistent, bounded search history and process-local Find selections.

The engine remains the authority for every actionable selection. This module
persists display/history data, but intentionally keeps bridge selection tokens
only in memory so an application restart cannot resurrect them.
"""

from __future__ import annotations

import asyncio
from contextlib import closing
import os
import re
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

from .engine_client import EngineRequestError
from .errors import ServiceError
from .ids import SEARCH_ROW
from .sources import (
    PROVIDER, SEARCHBOT, SOURCE_ID, SourceConfig, SourceService,
)


MAX_QUERY_BYTES = 350
MAX_RESULTS = 1000
MAX_PAGE_SIZE = 10
SEARCHBOT_FETCH_SIZE = 25   # a result list arrives whole; the bridge serves it in larger pages
MAX_HISTORY = 30
MIN_POLL_INTERVAL = 0.5
MIN_PAGE_INTERVAL = 0.1
ACTIVE_ENGINE_STATES = frozenset({"dispatch_pending", "dispatching", "collecting"})
TERMINAL_STATES = frozenset({"complete", "failed", "interrupted", "cancelled"})
# Engine refusals made before the source's earlier search was touched.
_EARLIER_SEARCH_KEPT = frozenset({
    "repeat_refused", "invalid_query", "search_active", "transfer_busy",
    "source_not_ready", "connection_changed",
})


class SearchError(ServiceError):
    """A search request is invalid, unavailable, or stale."""


def validate_terms(terms: Any, provider: str = PROVIDER) -> str:
    if (provider == SEARCHBOT and isinstance(terms, str)
            and not re.fullmatch(r" *[A-Za-z0-9][A-Za-z0-9 !]*", terms)):
        # The reply is recognised by a file name built from the search text,
        # and only this much of that naming is known.
        raise SearchError(
            "invalid_query",
            "a search-bot search may contain only letters, digits and spaces")
    if not isinstance(terms, str):
        raise SearchError("invalid_query", "search terms must be text")
    try:
        encoded = terms.encode("utf-8")
    except UnicodeError as exc:
        raise SearchError("invalid_query", "search terms are not valid UTF-8 text") from exc
    if not terms.strip() or len(encoded) > MAX_QUERY_BYTES:
        raise SearchError("invalid_query", f"search terms must be 1 to {MAX_QUERY_BYTES} UTF-8 bytes")
    if any(ord(char) < 32 or ord(char) == 127 for char in terms):
        raise SearchError("invalid_query", "search terms cannot contain control characters")
    # Preserve the user's exact text. In particular, never add quotes: the
    # existing provider treats the remainder of @find as an unquoted query.
    return terms


class SearchStore:
    """SQLite persistence for search summaries and non-authoritative rows."""

    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if not self.path.exists() or not self.path.is_file():
            raise ValueError("initialize the source store before the search store")
        if self.path.is_symlink():
            raise ValueError("search database path cannot be a symbolic link")
        self._migrate()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    def _migrate(self) -> None:
        with closing(self._connect()) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute("""
                    CREATE TABLE IF NOT EXISTS search_schema (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        version INTEGER NOT NULL CHECK (version > 0)
                    )
                """)
                version = connection.execute(
                    "SELECT version FROM search_schema WHERE singleton=1"
                ).fetchone()
                if version is not None and version["version"] > 2:
                    raise RuntimeError("search database was created by a newer application")
                connection.execute("""
                    CREATE TABLE IF NOT EXISTS search_history (
                        search_id TEXT PRIMARY KEY,
                        source_id TEXT NOT NULL,
                        source_revision INTEGER NOT NULL CHECK (source_revision > 0),
                        engine_instance_id TEXT NOT NULL,
                        engine_search_id TEXT,
                        operation_id TEXT NOT NULL,
                        terms TEXT NOT NULL,
                        channel TEXT NOT NULL,
                        state TEXT NOT NULL CHECK (state IN
                            ('dispatch_pending','collecting','complete','failed','interrupted','cancelled')),
                        engine_state TEXT NOT NULL,
                        note TEXT,
                        started_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        completed_at REAL,
                        result_count INTEGER NOT NULL DEFAULT 0 CHECK (result_count >= 0),
                        capped INTEGER NOT NULL DEFAULT 0 CHECK (capped IN (0,1)),
                        provider TEXT NOT NULL DEFAULT 'sysreset_find'
                    )
                """)
                # Version 2 records which kind of source a search asked.
                columns = {row["name"] for row in connection.execute(
                    "PRAGMA table_info(search_history)")}
                if "provider" not in columns:
                    connection.execute(
                        "ALTER TABLE search_history ADD COLUMN provider TEXT NOT NULL "
                        "DEFAULT 'sysreset_find'")
                connection.execute("""
                    CREATE UNIQUE INDEX IF NOT EXISTS search_history_engine_identity
                    ON search_history(engine_instance_id, engine_search_id)
                    WHERE engine_search_id IS NOT NULL
                """)
                connection.execute("""
                    CREATE INDEX IF NOT EXISTS search_history_recent
                    ON search_history(started_at DESC, search_id DESC)
                """)
                connection.execute("""
                    CREATE TABLE IF NOT EXISTS search_result (
                        row_id TEXT PRIMARY KEY,
                        search_id TEXT NOT NULL REFERENCES search_history(search_id) ON DELETE CASCADE,
                        ordinal INTEGER NOT NULL CHECK (ordinal BETWEEN 1 AND 1000),
                        sender TEXT NOT NULL,
                        trigger_text TEXT NOT NULL,
                        trigger_mode TEXT NOT NULL,
                        remote_path TEXT NOT NULL,
                        size_text TEXT NOT NULL,
                        size_bytes INTEGER CHECK (size_bytes IS NULL OR size_bytes >= 0),
                        size_precision TEXT NOT NULL CHECK (size_precision IN ('unknown','estimated','exact')),
                        received_at REAL NOT NULL,
                        UNIQUE(search_id, ordinal)
                    )
                """)
                connection.execute("""
                    CREATE INDEX IF NOT EXISTS search_result_page
                    ON search_result(search_id, ordinal)
                """)
                connection.execute(
                    "INSERT INTO search_schema(singleton, version) VALUES(1, 2) "
                    "ON CONFLICT(singleton) DO UPDATE SET version=excluded.version"
                )
                connection.execute("COMMIT")
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise

    @staticmethod
    def _search_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
        return dict(row) if row is not None else None

    def create(
        self, *, search_id: str, source: SourceConfig, engine_instance_id: str,
        operation_id: str, terms: str, started_at: float,
    ) -> dict[str, Any]:
        with closing(self._connect()) as connection:
            connection.execute("""
                INSERT INTO search_history (
                    search_id, source_id, source_revision, engine_instance_id,
                    operation_id, terms, channel, state, engine_state,
                    started_at, updated_at, provider
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 'dispatch_pending',
                          'dispatch_pending', ?, ?, ?)
            """, (search_id, source.source_id, source.revision,
                  engine_instance_id, operation_id, terms, source.channel,
                  started_at, started_at, source.provider))
        result = self.get(search_id)
        assert result is not None
        self.prune()
        return result

    def get(self, search_id: str) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT * FROM search_history WHERE search_id=?", (search_id,)
            ).fetchone()
        return self._search_dict(row)

    def find_engine_search(
        self, engine_instance_id: str, engine_search_id: str,
    ) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute("""
                SELECT * FROM search_history
                WHERE engine_instance_id=? AND engine_search_id=?
            """, (engine_instance_id, engine_search_id)).fetchone()
        return self._search_dict(row)

    def update(
        self, search_id: str, *, state: str | None = None,
        engine_state: str | None = None, engine_search_id: str | None = None,
        note: str | None = None, result_count: int | None = None,
        updated_at: float | None = None, completed_at: float | None = None,
    ) -> dict[str, Any] | None:
        now = time.time() if updated_at is None else updated_at
        assignments = ["updated_at=?"]
        parameters: list[Any] = [now]
        for column, value in (
            ("state", state), ("engine_state", engine_state),
            ("engine_search_id", engine_search_id), ("note", note),
            ("result_count", result_count), ("completed_at", completed_at),
        ):
            if value is not None:
                assignments.append(f"{column}=?")
                parameters.append(value)
        assignments.append("capped=CASE WHEN COALESCE(?, result_count) > ? THEN 1 ELSE 0 END")
        parameters.extend((result_count, MAX_RESULTS))
        parameters.append(search_id)
        with closing(self._connect()) as connection:
            connection.execute(
                f"UPDATE search_history SET {', '.join(assignments)} WHERE search_id=?",
                parameters,
            )
        return self.get(search_id)

    def mark_open_interrupted(self, note: str) -> None:
        now = time.time()
        with closing(self._connect()) as connection:
            connection.execute("""
                UPDATE search_history SET state='interrupted', engine_state='interrupted',
                    note=?, updated_at=?, completed_at=COALESCE(completed_at, ?)
                WHERE state IN ('dispatch_pending','collecting')
            """, (note, now, now))

    def save_result(self, search_id: str, record: dict[str, Any]) -> tuple[dict[str, Any], bool]:
        row_id = "row-" + uuid.uuid4().hex
        now = time.time()
        values = (
            search_id, record["ordinal"], record["sender"], record["trigger"],
            record["trigger_mode"], record["path"], record["size_text"],
            record["size_bytes"], record["size_precision"],
        )
        with closing(self._connect()) as connection:
            connection.execute("""
                INSERT OR IGNORE INTO search_result (
                    row_id, search_id, ordinal, sender, trigger_text, trigger_mode,
                    remote_path, size_text, size_bytes, size_precision, received_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (row_id, *values, now))
            row = connection.execute("""
                SELECT * FROM search_result WHERE search_id=? AND ordinal=?
            """, (search_id, record["ordinal"])).fetchone()
            assert row is not None
            stored = dict(row)
            same = (
                stored["sender"], stored["trigger_text"], stored["trigger_mode"],
                stored["remote_path"], stored["size_text"], stored["size_bytes"],
                stored["size_precision"],
            ) == values[2:]
        return stored, same

    def page(self, search_id: str, offset: int, limit: int) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            rows = connection.execute("""
                SELECT * FROM search_result
                WHERE search_id=? AND ordinal>? AND ordinal<=?
                ORDER BY ordinal LIMIT ?
            """, (search_id, offset, offset + limit, limit)).fetchall()
        return [dict(row) for row in rows]

    def find_result(self, row_id: str) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute("""
                SELECT r.*, s.source_id, s.source_revision, s.engine_instance_id,
                       s.engine_search_id, s.state, s.terms, s.channel, s.provider
                FROM search_result r JOIN search_history s ON s.search_id=r.search_id
                WHERE r.row_id=?
            """, (row_id,)).fetchone()
        return dict(row) if row is not None else None

    def count_results(self, search_id: str) -> int:
        with closing(self._connect()) as connection:
            return int(connection.execute(
                "SELECT COUNT(*) FROM search_result WHERE search_id=?", (search_id,)
            ).fetchone()[0])

    def recent(self, limit: int) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            rows = connection.execute("""
                SELECT * FROM search_history ORDER BY started_at DESC, search_id DESC LIMIT ?
            """, (limit,)).fetchall()
        return [dict(row) for row in rows]

    def prune(self) -> None:
        with closing(self._connect()) as connection:
            connection.execute("""
                DELETE FROM search_history WHERE search_id IN (
                    SELECT search_id FROM search_history
                    ORDER BY started_at DESC, search_id DESC LIMIT -1 OFFSET ?
                )
            """, (MAX_HISTORY,))


class SearchService:
    """Search/history facade for a future HTTP layer.

    `resolve_result` is an internal W4 handoff point: callers provide only the
    opaque application result ID. It returns private engine identity after a
    fresh availability check; public projections never expose bridge tokens.
    """

    def __init__(self, sources: SourceService) -> None:
        self.sources = sources
        self.engine = sources.engine
        self.store = SearchStore(sources.store.path)
        self._generation = uuid.uuid4().hex
        # The current search of each source, by source ID. A new search on a
        # source replaces only that source's entry; the others stay selectable.
        self._current: dict[str, str] = {}
        self._selection_tokens: dict[str, dict[str, dict[str, Any]]] = {}
        self._search_lock = asyncio.Lock()
        self._lifecycle_lock = asyncio.Lock()
        self._reconcile_lock = asyncio.Lock()
        self._poll_rate_lock = asyncio.Lock()
        self._page_rate_lock = asyncio.Lock()
        self._event_task: asyncio.Task[None] | None = None
        self._started = False
        self._last_poll: dict[str, float] = {}
        self._last_page_fetch: dict[str, float] = {}
        self._result_reconcile_coverage: dict[str, tuple[int, int]] = {}
        self._search_event_sequence: dict[str, int] = {}
        self._last_event_error: str | None = None

    async def startup(self) -> None:
        """Start event capture and make pre-existing history non-actionable."""
        async with self._lifecycle_lock:
            if self._started:
                return
            self.store.mark_open_interrupted(
                "Application restarted while this search was in progress; run a fresh search."
            )
            events = getattr(self.engine, "events", None)
            if events is not None:
                while not events.empty():
                    try:
                        events.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                self._event_task = asyncio.create_task(self._event_loop())
            self._started = True

    async def close(self) -> None:
        async with self._lifecycle_lock:
            task = self._event_task
            self._event_task = None
            self._started = False
            if task is not None:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
            self.store.mark_open_interrupted(
                "Application stopped while this search was in progress; run a fresh search."
            )
            self._selection_tokens.clear()
            self._current.clear()
            self._last_poll.clear()
            self._last_page_fetch.clear()
            self._result_reconcile_coverage.clear()
            self._search_event_sequence.clear()

    async def _event_loop(self) -> None:
        while True:
            event = await self.engine.events.get()
            try:
                await self._apply_event(event)
                self._last_event_error = None
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # Keep the bounded event consumer alive.
                self._last_event_error = str(exc)[:240]

    async def _apply_event(self, event: Any) -> None:
        if getattr(event, "name", None) == "source.state":
            source = event.payload.get("source")
            if isinstance(source, dict) and source.get("state") != "ready":
                # Only that source's search is affected; a source going away
                # does not touch another source's results.
                named = source.get("source_id")
                for source_id, search_id in list(self._current.items()):
                    if named in (None, source_id):
                        active = self.store.get(search_id)
                        if active is not None:
                            self._invalidate(
                                active, "Source connection changed; run a fresh search.")
            return
        if getattr(event, "name", None) == "search.result":
            payload = event.payload
            engine_search_id = payload.get("search_id")
            search = self.store.find_engine_search(
                self.engine.engine_instance_id, engine_search_id
            ) if isinstance(engine_search_id, str) else None
            result = payload.get("result")
            if (search and isinstance(result, dict)
                    and self._remember_search_event(search, event)):
                self._ingest_result(search, result)
            return
        if getattr(event, "name", None) == "search.state":
            snapshot = event.payload
            engine_search_id = snapshot.get("search_id")
            search = self.store.find_engine_search(
                self.engine.engine_instance_id, engine_search_id
            ) if isinstance(engine_search_id, str) else None
            if search and self._remember_search_event(search, event):
                self._save_snapshot(search, snapshot)

    def _remember_search_event(self, search: dict[str, Any], event: Any) -> bool:
        sequence = getattr(event, "sequence", None)
        if (isinstance(sequence, bool) or not isinstance(sequence, int)
                or sequence < 0):
            return True
        search_id = search["search_id"]
        latest = self._search_event_sequence.get(search_id, -1)
        if sequence < latest:
            return False
        self._search_event_sequence[search_id] = sequence
        return True

    @staticmethod
    def _public_state(engine_state: str) -> str:
        if engine_state in ACTIVE_ENGINE_STATES:
            return "collecting"
        if engine_state == "complete":
            return "complete"
        if engine_state == "cancelled":
            return "cancelled"
        if engine_state in {"disconnected", "stale", "unavailable", "unknown"}:
            return "interrupted"
        return "failed"

    @staticmethod
    def _safe_note(note: Any) -> str | None:
        if not isinstance(note, str):
            return None
        cleaned = "".join(char for char in note if ord(char) >= 32 and ord(char) != 127)
        return cleaned[:500] or None

    async def search(self, terms: Any, source_id: str = SOURCE_ID) -> dict[str, Any]:
        query = validate_terms(terms)
        if not self._started:
            await self.startup()
        async with self._search_lock:
            config = self.sources.store.get(source_id)
            if config is None:
                raise SearchError("source_not_configured", "configure the source before searching")
            query = validate_terms(terms, config.provider)
            try:
                engine_status = await self.engine.status()
            except Exception as exc:
                raise SearchError("engine_unavailable", "the local FServe engine is unavailable") from exc
            source = self.sources.engine_source(engine_status, source_id)
            if not self.sources._matches(source, config) or source.get("state") != "ready":
                raise SearchError("source_not_ready", "connect and join the configured channel before searching")
            # Another source's search may run alongside (2026-10-27); this
            # source's own may not, and the engine refuses whatever else waits.
            current = self._engine_search(engine_status, {"source_id": source_id})
            if isinstance(current, dict) and current.get("state") in ACTIVE_ENGINE_STATES:
                raise SearchError("search_active", "wait for or cancel the current search")

            now = time.time()
            search_id = "search-" + uuid.uuid4().hex
            operation_id = "web-search-" + uuid.uuid4().hex
            row = self.store.create(
                search_id=search_id, source=config,
                engine_instance_id=self.engine.engine_instance_id,
                operation_id=operation_id, terms=query, started_at=now,
            )
            # A new accepted attempt replaces this source's selection set in
            # the engine. Clear local authority for it before dispatch,
            # because the bridge clears its previous selections for the source
            # before it attempts the new provider call. Other sources keep
            # their finished searches.
            replaced = self._current.pop(source_id, None)
            held_tokens = None
            if replaced is not None:
                held_tokens = self._selection_tokens.pop(replaced, None)
                self._last_poll.pop(replaced, None)
                self._last_page_fetch.pop(replaced, None)
                self._result_reconcile_coverage.pop(replaced, None)
                self._search_event_sequence.pop(replaced, None)
            try:
                snapshot = await self.engine.request(
                    "search.find", {"source_id": config.source_id, "terms": query},
                    operation_id=operation_id,
                )
            except EngineRequestError as exc:
                self.store.update(search_id, state="failed", engine_state=exc.code,
                                  note=self._safe_note(exc.message), completed_at=time.time())
                if replaced is not None and exc.code in _EARLIER_SEARCH_KEPT:
                    # Nothing was sent and nothing was replaced, so the
                    # source's earlier results stay downloadable.
                    self._current[source_id] = replaced
                    if held_tokens is not None:
                        self._selection_tokens[replaced] = held_tokens
                return self._public_summary(self.store.get(search_id), historical=False)
            except Exception:
                self.store.update(
                    search_id, state="interrupted", engine_state="dispatch_uncertain",
                    note="The engine did not confirm the search dispatch. It was not retried.",
                    completed_at=time.time(),
                )
                return self._public_summary(self.store.get(search_id), historical=True)

            engine_search_id = snapshot.get("search_id")
            if not isinstance(engine_search_id, str) or not engine_search_id:
                self.store.update(
                    search_id, state="interrupted", engine_state="invalid_response",
                    note="The engine response omitted the search identity; run a fresh search.",
                    completed_at=time.time(),
                )
                return self._public_summary(self.store.get(search_id), historical=True)
            self.store.update(search_id, engine_search_id=engine_search_id)
            row = self.store.get(search_id)
            assert row is not None
            self._current[source_id] = search_id
            self._save_snapshot(row, snapshot)
            for result in snapshot.get("results", []):
                if isinstance(result, dict):
                    self._ingest_result(self.store.get(search_id) or row, result)
            return self._public_summary(self.store.get(search_id), historical=False)

    async def status(self, search_id: str) -> dict[str, Any]:
        row = self._require_search(search_id)
        if not self._is_runtime_current(row):
            self._selection_tokens.pop(search_id, None)
            return self._public_summary(row, historical=True)
        async with self._poll_rate_lock:
            now = time.monotonic()
            last = self._last_poll.get(search_id, 0.0)
            should_poll = now - last >= MIN_POLL_INTERVAL
            if should_poll:
                self._last_poll[search_id] = now
        if should_poll:
            try:
                snapshot = await self.engine.status()
                await self._reconcile_snapshot(row, snapshot)
            except Exception:
                current = self.store.get(search_id)
                if current and current["state"] in {"collecting", "dispatch_pending"}:
                    self._invalidate(
                        current, "The engine status could not be confirmed; run a fresh search.",
                        engine_state="engine_unavailable",
                    )
        row = self._require_search(search_id)
        return self._public_summary(row, historical=not self._is_runtime_current(row))

    async def page(self, search_id: str, *, offset: int = 0, limit: int = MAX_PAGE_SIZE) -> dict[str, Any]:
        if (isinstance(offset, bool) or not isinstance(offset, int) or offset < 0
                or offset > MAX_RESULTS):
            raise SearchError("invalid_page", f"offset must be between 0 and {MAX_RESULTS}")
        if (isinstance(limit, bool) or not isinstance(limit, int)
                or not 1 <= limit <= MAX_PAGE_SIZE):
            raise SearchError("invalid_page", f"page size must be between 1 and {MAX_PAGE_SIZE}")
        row = self._require_search(search_id)
        live = False
        if self._is_runtime_current(row):
            async with self._page_rate_lock:
                now = time.monotonic()
                last = self._last_page_fetch.get(search_id, 0.0)
                if now - last < MIN_PAGE_INTERVAL:
                    raise SearchError("poll_too_fast", "wait briefly before requesting another result page")
                self._last_page_fetch[search_id] = now
            try:
                snapshot = await self.engine.request("search.status", {
                    "source_id": row["source_id"],
                    "search_id": row["engine_search_id"],
                    "offset": offset,
                    "limit": limit,
                })
                self._save_snapshot(row, snapshot)
                for result in snapshot.get("results", []):
                    if isinstance(result, dict):
                        self._ingest_result(self.store.get(search_id) or row, result)
                row = self._require_search(search_id)
                live = self._snapshot_is_current(row, snapshot)
            except EngineRequestError:
                self._invalidate(row, "This search is no longer current; run a fresh search.")
            except (TimeoutError, ConnectionError, OSError):
                pass
        else:
            self._selection_tokens.pop(search_id, None)
        result_rows = self.store.page(search_id, offset, limit)
        return self._public_page(row, result_rows, offset, limit,
                                 historical=not live)

    def snapshot(self, search_id: str) -> dict[str, Any] | None:
        """A search's stored summary, without asking the engine."""
        row = self.store.get(search_id)
        if row is None:
            return None
        return self._public_summary(row, historical=not self._is_runtime_current(row))

    async def history(self, *, limit: int = 20) -> list[dict[str, Any]]:
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 20:
            raise SearchError("invalid_page", "history page size must be between 1 and 20")
        items = self.store.recent(limit)
        return [self._public_summary(row,
                                     historical=not self._is_runtime_current(row))
                for row in items]

    async def resolve_result(self, result_id: str) -> dict[str, Any]:
        """Return W4's private selection tuple; never accept remote fields."""
        if (not isinstance(result_id, str)
                or not SEARCH_ROW.fullmatch(result_id)):
            raise SearchError("invalid_result", "result ID is invalid")
        stored_result = self.store.find_result(result_id)
        if stored_result is None:
            raise SearchError("unknown_result", "result history row was not found")
        search_id = stored_result["search_id"]
        row = self._require_search(search_id)
        if row["state"] != "complete" or not self._is_runtime_current(row):
            self._selection_tokens.pop(search_id, None)
            raise SearchError("stale_result", "this result is historical or no longer selectable")
        token = self._selection_tokens.get(search_id, {}).get(result_id)
        if token is None:
            raise SearchError("stale_result", "this result is historical or no longer selectable")
        config = self.sources.store.get(row["source_id"])
        if config is None or config.revision != token["source_revision"]:
            self._invalidate(row, "Source configuration changed; run a fresh search.")
            raise SearchError("stale_result", "source configuration changed; run a fresh search")
        try:
            status = await self.engine.status()
        except Exception as exc:
            self._invalidate(row, "The local FServe engine is unavailable; run a fresh search.",
                             engine_state="engine_unavailable")
            raise SearchError("engine_unavailable", "the local FServe engine is unavailable") from exc
        engine_search = self._engine_search(status, row) or {}
        if (status.get("engine_instance_id") != token["engine_instance_id"]
                or not self._snapshot_is_current(row, engine_search)
                or engine_search.get("state") != "complete"
                or (self.sources.engine_source(status, row["source_id"]) or {}).get("state") != "ready"
                or not self.sources._matches(
                    self.sources.engine_source(status, row["source_id"]), config)):
            self._invalidate(row, "The source or engine changed; run a fresh search.")
            raise SearchError("stale_result", "the source or engine changed; run a fresh search")
        return {"search_id": search_id, "provider": row["provider"], **token}

    @staticmethod
    def _engine_search(status: dict[str, Any], row: dict[str, Any]) -> dict[str, Any] | None:
        """The engine's view of this row's source's current search."""
        searches = status.get("searches")
        if isinstance(searches, dict):
            found = searches.get(row["source_id"])
            return found if isinstance(found, dict) else None
        found = status.get("search")
        return found if isinstance(found, dict) else None

    async def _reconcile_snapshot(self, row: dict[str, Any], status: dict[str, Any]) -> None:
        snapshot = self._engine_search(status, row)
        config = self.sources.store.get(row["source_id"])
        source = self.sources.engine_source(status, row["source_id"])
        if (not isinstance(snapshot, dict) or not self._snapshot_is_current(row, snapshot)
                or config is None or config.revision != row["source_revision"]
                or not isinstance(source, dict) or source.get("state") != "ready"
                or not self.sources._matches(source, config)):
            self._invalidate(row, "The source or engine changed; run a fresh search.")
            return
        async with self._reconcile_lock:
            if not self._is_runtime_current(row):
                return
            snapshot_sequence = status.get("event_sequence")
            if (not isinstance(snapshot_sequence, bool)
                    and isinstance(snapshot_sequence, int)
                    and snapshot_sequence >= 0):
                client_sequence = getattr(self.engine, "last_event_sequence", -1)
                if not isinstance(client_sequence, int) or isinstance(client_sequence, bool):
                    client_sequence = -1
                latest_seen = max(
                    self._search_event_sequence.get(row["search_id"], -1),
                    client_sequence,
                )
                if snapshot_sequence < latest_seen:
                    return
                self._search_event_sequence[row["search_id"]] = max(
                    snapshot_sequence,
                    self._search_event_sequence.get(row["search_id"], -1),
                )
            self._save_snapshot(row, snapshot)
            current = self.store.get(row["search_id"])
            result_count = min(current["result_count"] if current else 0, MAX_RESULTS)
            stored_count = self.store.count_results(row["search_id"])
            coverage = (result_count, stored_count)
            needs_transport_reconciliation = getattr(
                self.engine, "needs_reconciliation", False
            )
            if (needs_transport_reconciliation
                    or (stored_count < result_count
                        and self._result_reconcile_coverage.get(row["search_id"]) != coverage)):
                # Events can be consumed before search.find's acknowledgement is
                # bound to its persistent row, without a transport sequence gap.
                # Reconcile on a reported deficit as well as a transport gap.
                # This fetch is read-only, limited to 100 pages, and paced at
                # the same maximum rate as explicit result-page requests.
                fetch_size = (SEARCHBOT_FETCH_SIZE if row["provider"] == SEARCHBOT
                              else MAX_PAGE_SIZE)
                for page_number, offset in enumerate(
                    range(0, result_count, fetch_size)
                ):
                    if page_number:
                        await asyncio.sleep(MIN_PAGE_INTERVAL)
                    page = await self.engine.request("search.status", {
                        "source_id": row["source_id"],
                        "search_id": row["engine_search_id"],
                        "offset": offset,
                        "limit": fetch_size,
                    })
                    if not self._snapshot_is_current(row, page):
                        self._invalidate(row, "The source or engine changed; run a fresh search.")
                        return
                    for result in page.get("results", []):
                        if isinstance(result, dict):
                            self._ingest_result(row, result)
                self._result_reconcile_coverage[row["search_id"]] = (
                    result_count, self.store.count_results(row["search_id"])
                )
                marker = getattr(self.engine, "mark_reconciled", None)
                if callable(marker):
                    marker(status)

    def _invalidate(
        self, row: dict[str, Any], note: str, *, engine_state: str = "stale",
    ) -> None:
        self.store.update(
            row["search_id"], state="interrupted", engine_state=engine_state,
            note=note, completed_at=time.time(),
        )
        self._selection_tokens.pop(row["search_id"], None)
        self._result_reconcile_coverage.pop(row["search_id"], None)
        self._search_event_sequence.pop(row["search_id"], None)
        if self._current.get(row["source_id"]) == row["search_id"]:
            del self._current[row["source_id"]]

    def _save_snapshot(self, row: dict[str, Any], snapshot: dict[str, Any]) -> None:
        raw_state = snapshot.get("state")
        if not isinstance(raw_state, str):
            return
        state = self._public_state(raw_state)
        current = self.store.get(row["search_id"])
        if current is None:
            return
        if current["state"] in TERMINAL_STATES:
            if state != current["state"]:
                return
        note = self._safe_note(snapshot.get("note"))
        result_count = snapshot.get("result_count", row["result_count"])
        if (isinstance(result_count, bool) or not isinstance(result_count, int)
                or result_count < 0):
            result_count = row["result_count"]
        result_count = max(current["result_count"], result_count)
        completed = time.time() if state in TERMINAL_STATES else None
        if current["completed_at"] is not None and state in TERMINAL_STATES:
            completed = current["completed_at"]
        self.store.update(
            row["search_id"], state=state, engine_state=raw_state,
            note=note, result_count=result_count,
            updated_at=time.time(), completed_at=completed,
        )
        if state in {"failed", "interrupted", "cancelled"}:
            self._selection_tokens.pop(row["search_id"], None)

    def _ingest_result(self, search: dict[str, Any], result: dict[str, Any]) -> None:
        ordinal = result.get("ordinal")
        if (isinstance(ordinal, bool) or not isinstance(ordinal, int)
                or not 1 <= ordinal <= MAX_RESULTS):
            return
        text_fields = {
            "sender": (result.get("sender"), 64),
            "trigger": (result.get("trigger"), 128),
            "trigger_mode": (result.get("trigger_mode"), 32),
            "path": (result.get("path"), 4096),
            "size_text": (result.get("size_text", ""), 4096),
        }
        normalized: dict[str, Any] = {"ordinal": ordinal}
        for key, (value, maximum) in text_fields.items():
            if (not isinstance(value, str) or len(value) > maximum
                    or any(ord(char) < 32 or ord(char) == 127 for char in value)):
                return
            normalized[key] = value
        precision = result.get("size_precision", "unknown")
        if precision not in {"unknown", "estimated", "exact"}:
            precision = "unknown"
        size_bytes = result.get("size_bytes")
        if (isinstance(size_bytes, bool) or not isinstance(size_bytes, int)
                or size_bytes < 0 or size_bytes > 9_223_372_036_854_775_807):
            size_bytes = None
        normalized["size_bytes"] = size_bytes
        normalized["size_precision"] = precision
        stored, same = self.store.save_result(search["search_id"], normalized)
        if not same:
            self._selection_tokens.get(search["search_id"], {}).pop(stored["row_id"], None)
            return
        selection_id = result.get("selection_id")
        if (not isinstance(selection_id, str)
                or not re.fullmatch(r"sel-[0-9a-f]{40}", selection_id)
                or self._current.get(search["source_id"]) != search["search_id"]
                or search["engine_instance_id"] != self.engine.engine_instance_id
                or search["source_revision"] != result.get("source_revision")
                or result.get("source_id") != search["source_id"]
                or normalized["trigger_mode"] not in (
                    {"searchbot"} if search["provider"] == SEARCHBOT
                    # "direct": a "!Nick file ::INFO:: size" row sent in
                    # answer to @find, fetched as a search bot's row is.
                    else {"channel_text", "ctcp", "direct"})):
            return
        self._selection_tokens.setdefault(search["search_id"], {})[stored["row_id"]] = {
            "source_id": search["source_id"],
            "source_revision": search["source_revision"],
            "engine_instance_id": search["engine_instance_id"],
            "engine_search_id": search["engine_search_id"],
            "engine_selection_id": selection_id,
            "result_row_id": stored["row_id"],
            "ordinal": ordinal,
            "sender": normalized["sender"],
            "trigger": normalized["trigger"],
            "trigger_mode": normalized["trigger_mode"],
            "remote_path": normalized["path"],
            "size_text": normalized["size_text"],
            "size_bytes": normalized["size_bytes"],
            "size_precision": normalized["size_precision"],
        }

    def _require_search(self, search_id: str) -> dict[str, Any]:
        if (not isinstance(search_id, str)
                or not re.fullmatch(r"search-[0-9a-f]{32}", search_id)):
            raise SearchError("invalid_search", "search ID is invalid")
        row = self.store.get(search_id)
        if row is None:
            raise SearchError("unknown_search", "search history entry was not found")
        return row

    def _is_runtime_current(self, row: dict[str, Any]) -> bool:
        config = self.sources.store.get(row["source_id"])
        return bool(
            self._started
            and self._current.get(row["source_id"]) == row["search_id"]
            and row["engine_instance_id"] == self.engine.engine_instance_id
            and row["engine_search_id"]
            and config is not None
            and config.source_id == row["source_id"]
            and config.revision == row["source_revision"]
            and row["state"] in {"collecting", "complete"}
        )

    def _snapshot_is_current(self, row: dict[str, Any], snapshot: dict[str, Any]) -> bool:
        return bool(
            isinstance(snapshot, dict)
            and snapshot.get("search_id") == row["engine_search_id"]
            and snapshot.get("source_id") == row["source_id"]
            and snapshot.get("state") not in {"stale", "disconnected", "unavailable"}
        )

    @staticmethod
    def _public_summary(row: dict[str, Any] | None, *, historical: bool) -> dict[str, Any]:
        if row is None:
            raise SearchError("unknown_search", "search history entry was not found")
        capped = bool(row["capped"] or row["result_count"] > MAX_RESULTS)
        return {
            "search_id": row["search_id"],
            "source_id": row["source_id"],
            "source_revision": row["source_revision"],
            "provider": row["provider"],
            "terms": row["terms"],
            "channel": row["channel"],
            "state": row["state"],
            "engine_state": row["engine_state"],
            "note": row["note"],
            "started_at": row["started_at"],
            "updated_at": row["updated_at"],
            "completed_at": row["completed_at"],
            "result_count": row["result_count"],
            "stored_result_limit": MAX_RESULTS,
            "capped": capped,
            "cap_notice": (
                f"Only the first {MAX_RESULTS:,} results are retained; refine the search."
                if capped else None
            ),
            "historical": historical,
            "selection_available": False,
            "poll_after_seconds": MIN_POLL_INTERVAL,
        }

    def _public_page(
        self, search: dict[str, Any], rows: list[dict[str, Any]],
        offset: int, limit: int, *, historical: bool,
    ) -> dict[str, Any]:
        selectable = search["state"] == "complete" and not historical
        tokens = self._selection_tokens.get(search["search_id"], {})
        results = []
        for row in rows:
            precision = row["size_precision"]
            exact = row["size_bytes"] if precision == "exact" else None
            estimate = row["size_bytes"] if precision == "estimated" else None
            token = tokens.get(row["row_id"]) if selectable else None
            results.append({
                "row_key": row["row_id"],
                "result_id": row["row_id"] if token else None,
                "selection_available": token is not None,
                "ordinal": row["ordinal"],
                "sender": row["sender"],
                "trigger": row["trigger_text"],
                "trigger_mode": row["trigger_mode"],
                "path": row["remote_path"],
                "size_text": row["size_text"],
                "size_precision": precision,
                "size_bytes_exact": exact,
                "size_bytes_estimate": estimate,
                "received_at": row["received_at"],
                "provenance": {
                    "provider": search["provider"],
                    "source_id": search["source_id"],
                    "source_revision": search["source_revision"],
                    "channel": search["channel"],
                    "search_id": search["search_id"],
                    "ordinal": row["ordinal"],
                },
            })
        summary = self._public_summary(search, historical=historical)
        summary.update({
            "offset": offset,
            "page_size": limit,
            "returned_count": len(results),
            "results": results,
        })
        return summary
