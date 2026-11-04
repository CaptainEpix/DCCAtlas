"""Durable, idempotent handoff from a selected search result to an engine job."""

from __future__ import annotations

import asyncio
from collections.abc import Iterator
from contextlib import closing, contextmanager
import hashlib
import os
import re
import sqlite3
import time
from pathlib import Path
from typing import Any
import uuid

from .engine_client import EngineRequestError
from .errors import ServiceError
from .ids import (BROWSE_ROW, IRC_NICK, LIST_ROW, OPERATION_ID, SEARCH_ROW,
                  SOURCE_ID_PATTERN)
from .searches import SearchError, SearchService
from .settings import DownloadSettings
from .sources import SourceService


_OPERATION_PREFIX = "web-download-"
# Operations whose session the engine may open afresh before the request.
_RETRYABLE_OPERATIONS = frozenset({"search.download", "manifest.download"})
_SQLITE_INTEGER_MAX = 9_223_372_036_854_775_807
_TERMINAL_STATES = frozenset({
    "complete", "failed", "cancelled", "expired", "stale",
    "refused_without_queue", "abandoned_uncertain",
})
_TERMINAL_STATE_SQL = ",".join(f"'{state}'" for state in sorted(_TERMINAL_STATES))
_ENGINE_JOB_STATES = frozenset({
    "held", "ready", "preparing", "backoff", "dispatch_intent",
    "awaiting_offer", "remote_queued", "receiving", "finalizing",
    "interrupted", "resume_pending", "needs_attention", "complete",
    "failed", "cancelled", "expired", "stale", "refused_without_queue",
})
# Replies that do not show whether the request was carried out: the handler
# failed part-way, so the request may already have been sent, or a reply too
# large to send was refused after the engine had acted on the request.
_UNCERTAIN_ENGINE_CODES = frozenset({
    "engine_error", "invalid_engine_response", "response_too_large",
})
_ENGINE_JOB_MISSING = "engine_job_missing"


class DownloadError(ServiceError):
    """A download operation could not be accepted or reconciled."""


def _text(value: Any, maximum: int = 512) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = "".join(char for char in value if ord(char) >= 32 and ord(char) != 127)
    return cleaned[:maximum] or None


def _optional_count(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= _SQLITE_INTEGER_MAX:
        return None
    return value


def _fingerprint(result_id: str) -> str:
    return hashlib.sha256(result_id.encode("utf-8")).hexdigest()


class DownloadStore:
    """Durable application-operation records in the existing private DB."""

    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if not self.path.exists() or not self.path.is_file() or self.path.is_symlink():
            raise ValueError("initialize the source store before the download store")
        self._migrate()

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

    @staticmethod
    def _row(connection: sqlite3.Connection, operation_id: str) -> dict[str, Any] | None:
        row = connection.execute(
            "SELECT * FROM download_operation WHERE operation_id=?", (operation_id,)
        ).fetchone()
        return dict(row) if row is not None else None

    def _migrate(self) -> None:
        with self._transaction() as connection:
            connection.execute("""
                CREATE TABLE IF NOT EXISTS download_schema (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    version INTEGER NOT NULL CHECK (version > 0)
                )
            """)
            version = connection.execute(
                "SELECT version FROM download_schema WHERE singleton=1"
            ).fetchone()
            if version is not None and version["version"] > 3:
                raise RuntimeError("download database was created by a newer application")
            existing = connection.execute(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='download_operation'"
            ).fetchone()
            if existing is not None and "CHECK (active_guard = 1)" in existing[0]:
                # Version 3 (2026-10-22): two downloads may be active at once,
                # each in a slot of its own, so the slot may be 1 or 2. The
                # table is rebuilt to change that check.
                connection.execute("DROP INDEX IF EXISTS download_one_active")
                connection.execute("ALTER TABLE download_operation RENAME TO download_operation_v2")
            connection.execute("""
                CREATE TABLE IF NOT EXISTS download_operation (
                    operation_id TEXT PRIMARY KEY,
                    idempotency_key TEXT NOT NULL UNIQUE,
                    request_fingerprint TEXT NOT NULL,
                    result_id TEXT NOT NULL,
                    search_id TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    source_revision INTEGER NOT NULL CHECK (source_revision > 0),
                    engine_instance_id TEXT NOT NULL,
                    engine_search_id TEXT NOT NULL,
                    job_id TEXT,
                    engine_transition_sequence INTEGER NOT NULL DEFAULT -1,
                    engine_state TEXT,
                    state TEXT NOT NULL,
                    outcome TEXT,
                    reason TEXT,
                    sender TEXT,
                    name TEXT,
                    remote_path TEXT,
                    download_path TEXT,
                    bytes_received INTEGER CHECK (bytes_received IS NULL OR bytes_received >= 0),
                    total_bytes INTEGER CHECK (total_bytes IS NULL OR total_bytes >= 0),
                    cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK (cancel_requested IN (0,1)),
                    active_guard INTEGER NOT NULL DEFAULT 1 CHECK (active_guard IN (1, 2)),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)
            if connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' "
                                  "AND name='download_operation_v2'").fetchone():
                connection.execute(
                    "INSERT INTO download_operation SELECT * FROM download_operation_v2")
                connection.execute("DROP TABLE download_operation_v2")
            if version is None or version["version"] < 2:
                # Version 2 adds an explicit, operator-confirmed terminal
                # state for an unresolved operation. Rebuild the predicate
                # so retiring one does not keep occupying the single slot.
                connection.execute("DROP INDEX IF EXISTS download_one_active")
            connection.execute(f"""
                CREATE UNIQUE INDEX IF NOT EXISTS download_one_active
                ON download_operation(active_guard)
                WHERE state NOT IN ({_TERMINAL_STATE_SQL})
            """)
            connection.execute(
                "INSERT INTO download_schema(singleton,version) VALUES(1,3) "
                "ON CONFLICT(singleton) DO UPDATE SET version=excluded.version"
            )

    def get(self, operation_id: str) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            return self._row(connection, operation_id)

    def by_idempotency_key(self, key: str) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT * FROM download_operation WHERE idempotency_key=?", (key,)
            ).fetchone()
        return dict(row) if row is not None else None

    def active(self) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            rows = connection.execute(
                f"SELECT * FROM download_operation WHERE state NOT IN ({_TERMINAL_STATE_SQL}) "
                "ORDER BY created_at, operation_id"
            ).fetchall()
        return [dict(row) for row in rows]

    def recent(self, limit: int) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            rows = connection.execute(
                "SELECT * FROM download_operation ORDER BY created_at DESC, operation_id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [dict(row) for row in rows]

    def forget(self, operation_id: str | None = None) -> int:
        """Delete the record of one ended download, or of every ended one
        (2026-10-29). The file, if any, stays where it was saved.

        A record the queue is still following is kept: the queue would take
        its absence for a request never sent, and send it.
        """
        with self._transaction() as connection:
            followed = ""
            if connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' "
                                  "AND name='download_queue'").fetchone():
                followed = ("AND NOT EXISTS (SELECT 1 FROM download_queue WHERE "
                            "download_queue.state='running' AND "
                            "download_queue.operation_key=download_operation.idempotency_key)")
            which, arguments = ("AND operation_id=?", (operation_id,)) if operation_id else ("", ())
            return connection.execute(
                f"DELETE FROM download_operation WHERE state IN ({_TERMINAL_STATE_SQL}) "
                f"{which} {followed}", arguments).rowcount

    def create_pending(
        self, *, operation_id: str, idempotency_key: str, result_id: str,
        selection: dict[str, Any], at_once: int = 1,
        sender: str | None = None, remote_path: str | None = None,
    ) -> tuple[dict[str, Any], bool]:
        now = time.time()
        fingerprint = _fingerprint(result_id)
        with self._transaction() as connection:
            previous = connection.execute(
                "SELECT * FROM download_operation WHERE idempotency_key=?",
                (idempotency_key,),
            ).fetchone()
            if previous is not None:
                if previous["request_fingerprint"] != fingerprint:
                    raise DownloadError(
                        "idempotency_conflict",
                        "this idempotency key already belongs to a different result",
                    )
                return dict(previous), False
            active = connection.execute(f"""
                SELECT operation_id, state, active_guard FROM download_operation
                WHERE state NOT IN ({_TERMINAL_STATE_SQL})
            """).fetchall()
            # A second one only alongside one already being received
            # (downloads_at_once, 2026-10-22); the engine checks again.
            if len(active) >= at_once or any(row["state"] != "receiving" for row in active):
                raise DownloadError("download_busy", "another download operation is still active"
                                    if at_once < 2 or not active else
                                    "another download is still starting; a second one can "
                                    "start once the first is being received")
            connection.execute("""
                INSERT INTO download_operation (
                    operation_id, idempotency_key, request_fingerprint,
                    result_id, search_id, source_id, source_revision,
                    engine_instance_id, engine_search_id, state,
                    active_guard, sender, name, remote_path, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'dispatch_pending', ?, ?, ?, ?, ?, ?)
            """, (
                operation_id, idempotency_key, fingerprint, result_id,
                selection["search_id"], selection["source_id"],
                selection["source_revision"], selection["engine_instance_id"],
                selection["engine_search_id"],
                # The free slot; the unique index allows each once among
                # the active ones, so never more than two run.
                2 if any(row["active_guard"] == 1 for row in active) else 1,
                # What was asked for, so a refused start still names its
                # file (2026-10-27); the engine's job replaces these.
                sender, remote_path.rsplit("/", 1)[-1] if remote_path else None, remote_path,
                now, now,
            ))
            row = self._row(connection, operation_id)
            assert row is not None
            return row, True

    def mark_cancel_requested(self, operation_id: str) -> None:
        with self._transaction() as connection:
            connection.execute(
                "UPDATE download_operation SET cancel_requested=1, updated_at=? "
                "WHERE operation_id=?", (time.time(), operation_id),
            )

    def _set_attention(
        self, connection: sqlite3.Connection, operation_id: str, *,
        outcome: str, reason: str | None,
    ) -> dict[str, Any]:
        connection.execute("""
            UPDATE download_operation
            SET state='needs_attention', engine_state=COALESCE(engine_state,'unknown'),
                outcome=?, reason=?, updated_at=?
            WHERE operation_id=?
        """, (outcome, reason, time.time(), operation_id))
        row = self._row(connection, operation_id)
        assert row is not None
        return row

    def mark_needs_attention(
        self, operation_id: str, *, outcome: str, reason: str | None,
    ) -> dict[str, Any] | None:
        """Record uncertainty without overwriting a durable terminal result."""
        with self._transaction() as connection:
            row = self._row(connection, operation_id)
            if row is None or row["state"] in _TERMINAL_STATES:
                return row
            return self._set_attention(
                connection, operation_id, outcome=outcome, reason=reason)

    def record_refusal(
        self, operation_id: str, *, outcome: str, reason: str | None,
    ) -> dict[str, Any] | None:
        """Persist a definitive engine refusal without demoting later evidence."""
        with self._transaction() as connection:
            row = self._row(connection, operation_id)
            if row is None or row["state"] in _TERMINAL_STATES or row["job_id"] is not None:
                return row
            connection.execute("""
                UPDATE download_operation
                SET state='failed', engine_state='refused', outcome=?,
                    reason=?, updated_at=?
                WHERE operation_id=?
            """, (outcome, reason, time.time(), operation_id))
            return self._row(connection, operation_id)

    @staticmethod
    def can_abandon(row: dict[str, Any]) -> bool:
        """Only an operation the engine cannot act on may be retired locally.

        That is one with no correlated job, or one whose recorded job the
        engine has reported as absent from its journal. A job the engine
        still knows must be cancelled through the engine instead.
        """
        return row["state"] == "needs_attention" and (
            row["job_id"] is None or row["outcome"] == _ENGINE_JOB_MISSING
        )

    def abandon_uncertain(self, operation_id: str) -> tuple[dict[str, Any] | None, bool]:
        """Release an unresolvable attention row after explicit operator consent."""
        with self._transaction() as connection:
            row = self._row(connection, operation_id)
            if row is None or not self.can_abandon(row):
                return row, False
            connection.execute("""
                UPDATE download_operation
                SET state='abandoned_uncertain',
                    outcome='operator_abandoned_uncertain',
                    reason='The operator retired this unresolved local operation. A remote request or queue entry may still exist; this operation will not be replayed.',
                    updated_at=?
                WHERE operation_id=?
            """, (time.time(), operation_id))
            return self._row(connection, operation_id), True

    def apply_engine_job(
        self, operation_id: str, *, job_id: str, sequence: int, state: str,
        outcome: str | None, reason: str | None, sender: str | None,
        name: str | None, remote_path: str | None, download_path: str | None,
        bytes_received: int | None, total_bytes: int | None,
    ) -> tuple[dict[str, Any], str]:
        """Apply one validated job snapshot atomically and monotonically."""
        with self._transaction() as connection:
            row = self._row(connection, operation_id)
            if row is None:
                raise DownloadError("unknown_operation", "download operation was not found")
            if row["state"] in _TERMINAL_STATES:
                return row, "terminal"
            if row["job_id"] is not None and row["job_id"] != job_id:
                return self._set_attention(
                    connection, operation_id, outcome="job_identity_conflict",
                    reason="The engine returned a different job ID for this durable operation; newer state was not applied.",
                ), "conflict"
            previous_sequence = row["engine_transition_sequence"]
            if sequence < previous_sequence:
                return row, "stale"
            if (sequence == previous_sequence and row["engine_state"] is not None
                    and row["engine_state"] != state):
                return self._set_attention(
                    connection, operation_id, outcome="sequence_state_conflict",
                    reason="The engine reported different states at the same transition sequence; newer state was not applied.",
                ), "conflict"

            if row["bytes_received"] is not None:
                bytes_received = max(row["bytes_received"], bytes_received or 0)
            if row["total_bytes"] is not None:
                total_bytes = max(row["total_bytes"], total_bytes or 0)
            connection.execute("""
                UPDATE download_operation SET
                    job_id=?, engine_transition_sequence=?, engine_state=?, state=?,
                    outcome=?, reason=?, sender=COALESCE(?, sender), name=COALESCE(?, name),
                    remote_path=COALESCE(?, remote_path), download_path=?,
                    bytes_received=?, total_bytes=?, updated_at=?
                WHERE operation_id=?
            """, (
                job_id, sequence, state, state, outcome, reason, sender, name,
                remote_path, download_path, bytes_received, total_bytes,
                time.time(), operation_id,
            ))
            result = self._row(connection, operation_id)
            assert result is not None
            return result, "applied"


class DownloadService:
    """Idempotent bridge to durable engine jobs; never replays uncertain GETs."""

    def __init__(self, sources: SourceService, searches: SearchService) -> None:
        if sources.store.path != searches.store.path:
            raise ValueError("source, search and download services must share one database")
        self.sources = sources
        self.searches = searches
        self.engine = sources.engine
        self.store = DownloadStore(sources.store.path)
        self.settings = DownloadSettings(sources.store.path)
        self._lock = asyncio.Lock()
        # Set by the runtime: resolves a hit from a stored file list, and a
        # file read by browsing a file server.
        self.manifests: Any = None
        self.adverts: Any = None
        self.browses: Any = None

    @staticmethod
    def _validate_key(key: Any) -> str:
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{15,127}", key):
            raise DownloadError("invalid_idempotency_key", "idempotency key must be 16 to 128 safe characters")
        return key

    @staticmethod
    def _operation_id(key: str) -> str:
        return _OPERATION_PREFIX + hashlib.sha256(key.encode("utf-8")).hexdigest()

    @staticmethod
    def _cancel_operation_id(operation_id: str) -> str:
        # Each Cancel is its own request. The engine remembers its reply to an
        # operation ID, failures included, and cancelling twice does nothing
        # more than cancelling once, so one fixed ID per download would only
        # repeat a failed Cancel's failure.
        return ("web-cancel-" + hashlib.sha256(operation_id.encode("ascii")).hexdigest()[:32]
                + "-" + uuid.uuid4().hex)

    @staticmethod
    def _require_operation_id(operation_id: Any) -> str:
        if not isinstance(operation_id, str) or not OPERATION_ID.fullmatch(operation_id):
            raise DownloadError("invalid_operation", "download operation ID is invalid")
        return operation_id

    @staticmethod
    def uncertain_resolution_phrase(operation_id: str) -> str:
        """Return the exact, operation-bound phrase required to retire uncertainty."""
        return f"ABANDON-UNCERTAIN {operation_id}"

    @staticmethod
    def _public(row: dict[str, Any]) -> dict[str, Any]:
        return {
            "operation_id": row["operation_id"],
            "job_id": row["job_id"],
            "state": row["state"],
            "engine_state": row["engine_state"],
            "outcome": row["outcome"],
            "reason": row["reason"],
            "search_id": row["search_id"],
            "result_id": row["result_id"],
            "source_revision": row["source_revision"],
            "sender": row["sender"],
            "name": row["name"],
            "remote_path": row["remote_path"],
            "download_path": row["download_path"],
            "bytes_received": row["bytes_received"],
            "total_bytes": row["total_bytes"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "cancel_requested": bool(row["cancel_requested"]),
            "abandonable": DownloadStore.can_abandon(row),
        }

    def _require_row(self, operation_id: Any) -> dict[str, Any]:
        row = self.store.get(self._require_operation_id(operation_id))
        if row is None:
            raise DownloadError("unknown_operation", "download operation was not found")
        return row

    def _attention(self, operation_id: str, outcome: str, reason: str | None) -> dict[str, Any]:
        saved = self.store.mark_needs_attention(operation_id, outcome=outcome, reason=reason)
        if saved is None:
            raise DownloadError("unknown_operation", "download operation was not found")
        return saved

    def _engine_refusal_attention(
        self, operation_id: str, exc: EngineRequestError,
    ) -> dict[str, Any]:
        """Record an engine refusal about a job this operation already owns."""
        if exc.code == "unknown_job":
            return self._attention(
                operation_id, _ENGINE_JOB_MISSING,
                "The engine journal no longer contains the job recorded for this operation. It will not be replayed.",
            )
        return self._attention(operation_id, exc.code, _text(exc.message))

    async def startup(self) -> list[dict[str, Any]]:
        """Reconcile durable operations against journal identity; never dispatch."""
        async with self._lock:
            return [await self._reconcile(row) for row in self.store.active()]

    async def download(self, idempotency_key: Any, result_id: Any) -> dict[str, Any]:
        key = self._validate_key(idempotency_key)
        from_list = isinstance(result_id, str) and bool(
            LIST_ROW.fullmatch(result_id)) and self.manifests is not None
        # A file read by browsing a file server (2026-10-21).
        from_browse = isinstance(result_id, str) and bool(
            BROWSE_ROW.fullmatch(result_id)) and self.browses is not None
        if not from_list and not from_browse and (
                not isinstance(result_id, str) or not SEARCH_ROW.fullmatch(result_id)):
            raise DownloadError("invalid_result", "result ID is invalid")
        operation_id = self._operation_id(key)
        async with self._lock:
            prior = self.store.by_idempotency_key(key)
            if prior is not None:
                if prior["request_fingerprint"] != _fingerprint(result_id):
                    raise DownloadError("idempotency_conflict", "this idempotency key belongs to another result")
                return self._public(await self._reconcile(prior))
            try:
                if from_browse:
                    selection = await self.browses.resolve_result(result_id)
                elif from_list:
                    selection = await self.manifests.resolve_result(result_id)
                else:
                    selection = await self.searches.resolve_result(result_id)
            except SearchError as exc:
                raise DownloadError(exc.code, exc.message) from exc
            except ValueError as exc:
                if not (from_list or from_browse) or not hasattr(exc, "code"):
                    raise
                raise DownloadError(exc.code, exc.message) from exc
            return await self._dispatch(operation_id, key, result_id, selection)

    async def retry(self, operation_id: Any, idempotency_key: Any) -> dict[str, Any]:
        """Ask again for a file whose download ended without it, at the operator's press.

        It goes as any download does: a fresh session, a fresh listing of the
        file's folder, then the request, and the engine still refuses a file
        already asked for on this connection, so a request that was sent can
        be repeated only on a later connection. A search result is fetched
        by the file server, trigger and path it named, so it can be retried
        after the search is no longer current; a search bot's row, or a row a
        file server sent to be posted back, cannot (search again).
        """
        if not isinstance(operation_id, str) or not OPERATION_ID.fullmatch(operation_id):
            raise DownloadError("invalid_operation", "download ID is invalid")
        row = self.store.get(operation_id)
        if row is None:
            raise DownloadError("unknown_operation", "that download is not known")
        if row["state"] not in _TERMINAL_STATES or row["state"] == "complete":
            raise DownloadError("not_retryable", "only a download that ended without its file "
                                "can be tried again; cancel it first if it is still waiting")
        result_id = row["result_id"]
        if isinstance(result_id, str) and result_id.startswith("list-"):
            # Asked as Get list asks (2026-10-29); the engine refuses it on
            # the same connection unless the list's transfer failed.
            return await self.request_list(
                idempotency_key, row["source_id"], row["sender"], advertised=True,
                typed=bool(self.adverts and self.adverts.typed(row["source_id"], row["sender"])))
        if not (isinstance(result_id, str) and SEARCH_ROW.fullmatch(result_id)):
            return await self.download(idempotency_key, result_id)
        stored = self.searches.store.find_result(result_id)
        if stored is None:
            raise DownloadError("not_retryable", "its search result is not kept any more; "
                                "search again")
        if stored.get("provider") == "searchbot" or stored.get("trigger_mode") == "direct":
            raise DownloadError("not_retryable", "a search bot's row, or one a file server sent "
                                "to be posted back, can be asked for again only from a new search")
        config = self.sources.store.get(row["source_id"])
        if config is None or config.revision != row["source_revision"]:
            raise DownloadError("not_retryable", "its source was changed or removed since; "
                                "search again")
        selection = {
            "search_id": row["search_id"], "source_id": config.source_id,
            "source_revision": config.revision,
            "engine_instance_id": self.engine.engine_instance_id,
            "engine_search_id": "retry", "engine_operation": "manifest.download",
            "engine_arguments": {
                "source_id": config.source_id, "sender": stored["sender"],
                "trigger": stored["trigger_text"],
                "trigger_mode": "ctcp" if stored["trigger_mode"] == "ctcp" else "channel_text",
                "path": stored["remote_path"],
            },
        }
        status = await self.engine.status()
        live = self.sources.engine_source(status, config.source_id)
        if not live or live.get("state") != "ready" or not self.sources._matches(live, config):
            raise DownloadError("source_not_ready", f"connect {config.label} to try again")
        return await self.download_queued(self._validate_key(idempotency_key), result_id, selection)

    async def request_list(self, idempotency_key: Any, source_id: Any,
                           sender: Any, *, advertised: bool = False,
                           typed: bool = False) -> dict[str, Any]:
        """Ask a list server for its whole list with "@Nick" (2026-10-27).

        It is a download like any other: one operation, sent once, its file
        filed under the server's "@list" folder. The engine sends it only to
        a nick seen advertising a list in the source's channel, once a
        connection. A nick the operator typed (typed) may have its list sent
        by another nick (2026-11-02).
        """
        key = self._validate_key(idempotency_key)
        if (not isinstance(source_id, str)
                or not SOURCE_ID_PATTERN.fullmatch(source_id)):
            raise DownloadError("invalid_request", "pick the source the list server is on")
        if not isinstance(sender, str) or not IRC_NICK.fullmatch(sender):
            raise DownloadError("invalid_request", "name the list server's nickname")
        config = self.sources.store.get(source_id)
        if config is None:
            raise DownloadError("unknown_source", "that source is not configured")
        operation_id = self._operation_id(key)
        # A list that stopped part-way is not resumed; it is cancelled here,
        # so asking again is one press (2026-10-29). The engine allows a
        # second ask on the same connection only after such a failure.
        if self.store.by_idempotency_key(key) is None:
            for row in self.store.active():
                if (row["result_id"] == f"list-{source_id}-{sender}"
                        and row["state"] == "interrupted"):
                    await self.cancel(row["operation_id"])
        async with self._lock:
            prior = self.store.by_idempotency_key(key)
            if prior is not None:
                return self._public(await self._reconcile(prior))
            status = await self.engine.status()
            live = self.sources.engine_source(status, source_id)
            if not live or live.get("state") != "ready" or not self.sources._matches(live, config):
                raise DownloadError("source_not_ready", f"connect {config.label} first")
            selection = {
                "search_id": "list-" + source_id, "source_id": source_id,
                "source_revision": config.revision,
                "engine_instance_id": self.engine.engine_instance_id,
                "engine_search_id": "list", "engine_operation": "list.request",
                "engine_arguments": {"source_id": source_id, "sender": sender,
                                     **({"advertised": True} if advertised else {}),
                                     **({"typed": True} if typed else {})},
            }
            return await self._dispatch(operation_id, key, f"list-{source_id}-{sender}",
                                        selection)

    async def accept_list(self, idempotency_key: Any, source_id: Any, sender: Any,
                          name: Any) -> dict[str, Any]:
        """Take a list a server offered unasked after "!list" (2026-10-28).

        A download like Get list's, under the same result ID, so it is read as
        that server's list; the engine sends nothing for it, and takes only
        the offer it noted.
        """
        key = self._validate_key(idempotency_key)
        if (not isinstance(source_id, str)
                or not SOURCE_ID_PATTERN.fullmatch(source_id)):
            raise DownloadError("invalid_request", "pick the source the list server is on")
        if not isinstance(sender, str) or not IRC_NICK.fullmatch(sender):
            raise DownloadError("invalid_request", "name the list server's nickname")
        if not isinstance(name, str) or not 0 < len(name) <= 255:
            raise DownloadError("invalid_request", "name the list offered")
        config = self.sources.store.get(source_id)
        if config is None:
            raise DownloadError("unknown_source", "that source is not configured")
        operation_id = self._operation_id(key)
        async with self._lock:
            prior = self.store.by_idempotency_key(key)
            if prior is not None:
                return self._public(await self._reconcile(prior))
            selection = {
                "search_id": "list-" + source_id, "source_id": source_id,
                "source_revision": config.revision,
                "engine_instance_id": self.engine.engine_instance_id,
                "engine_search_id": "list", "engine_operation": "list.accept",
                "engine_arguments": {"source_id": source_id, "sender": sender, "name": name},
            }
            return await self._dispatch(operation_id, key, f"list-{source_id}-{sender}",
                                        selection)

    async def download_queued(self, idempotency_key: str, result_id: str,
                              selection: dict[str, Any]) -> dict[str, Any]:
        """Start one file of the download queue, from the target it captured.

        The selection names the file server, trigger and path, so the engine's
        explicit-target fetch is used (``manifest.download``): the file is
        checked in a fresh listing of its folder before any GET, as for any
        download. The key is the queue item's own, so a repeated call finds
        the same operation and never sends twice.
        """
        key = self._validate_key(idempotency_key)
        operation_id = self._operation_id(key)
        async with self._lock:
            prior = self.store.by_idempotency_key(key)
            if prior is not None:
                return self._public(await self._reconcile(prior))
            return await self._dispatch(operation_id, key, result_id, selection)

    async def _dispatch(self, operation_id: str, key: str, result_id: str,
                        selection: dict[str, Any]) -> dict[str, Any]:
        """Record the operation, then send it once. The lock is held."""
        operation = selection.get("engine_operation", "search.download")
        # Only a file server's file runs alongside another; a search bot's
        # row, or a row posted back, waits for every transfer to end.
        at_once = (self.settings.get("downloads_at_once")
                   if operation in _RETRYABLE_OPERATIONS
                   and selection.get("provider") != "searchbot"
                   and selection.get("trigger_mode") != "direct" else 1)
        # The file server and file asked for: a list's, a browse's or the
        # queue's target names them; a search result's are in its row.
        target = selection.get("engine_arguments") or {}
        if not target.get("sender"):
            target = self.searches.store.find_result(result_id) or {}
        row, created = self.store.create_pending(
            operation_id=operation_id, idempotency_key=key,
            result_id=result_id, selection=selection, at_once=at_once,
            sender=_text(target.get("sender"), 128),
            remote_path=_text(target.get("path") or target.get("remote_path")
                              or target.get("name"), 4096),
        )
        if not created:
            return self._public(await self._reconcile(row))
        try:
            # A hit from a stored file list names its file server and
            # path; a search result names the engine's own selection.
            arguments = dict(selection.get("engine_arguments") or {
                "source_id": selection["source_id"],
                "search_id": selection["engine_search_id"],
                "selection_id": selection["engine_selection_id"],
            })
            if operation in _RETRYABLE_OPERATIONS:
                # The engine's own retry before the request (2026-10-22): a
                # file server's session that drops before the file is asked
                # for is opened afresh, at most twice within two minutes.
                arguments["retry_before_request"] = self.settings.get("retry_before_request")
                arguments["at_once"] = at_once
            response = await self.engine.request(operation, arguments, operation_id=operation_id)
        except EngineRequestError as exc:
            return self._public(await self._settle_refused_dispatch(operation_id, exc))
        except Exception:
            return self._public(self._attention(
                operation_id, "dispatch_outcome_unknown",
                "The engine reply was not confirmed. The request was not retried.",
            ))
        job = response.get("job") if isinstance(response, dict) else None
        if not isinstance(job, dict):
            try:
                job = await self._find_engine_job(operation_id)
            except Exception:
                return self._public(self._attention(
                    operation_id, "dispatch_job_unconfirmed",
                    "The dispatch reply omitted its job and durable lookup failed. The request was not retried.",
                ))
        return self._public(self._apply_job(operation_id, job))

    async def _settle_refused_dispatch(
        self, operation_id: str, exc: EngineRequestError,
    ) -> dict[str, Any]:
        """Decide what an engine error reply proves about the dispatch."""
        try:
            existing_job = await self._find_engine_job(operation_id)
        except Exception:
            return self._attention(
                operation_id, "dispatch_refusal_unreconciled",
                "The engine returned an error, but durable job lookup failed. The request was not retried.",
            )
        if existing_job is not None:
            return self._apply_job(operation_id, existing_job)
        if exc.code in _UNCERTAIN_ENGINE_CODES:
            return self._attention(
                operation_id, "dispatch_outcome_unknown",
                "The engine failed while handling the request, so it may have been sent. The request was not retried.",
            )
        saved = self.store.record_refusal(
            operation_id, outcome=exc.code, reason=_text(exc.message),
        )
        if saved is None:
            raise DownloadError("unknown_operation", "download operation was not found")
        if saved["state"] == "failed" and saved["outcome"] == exc.code:
            raise DownloadError(exc.code, exc.message) from exc
        return saved

    async def status(self, operation_id: str) -> dict[str, Any]:
        async with self._lock:
            return self._public(await self._reconcile(self._require_row(operation_id)))

    async def history(self, *, limit: int = 20) -> list[dict[str, Any]]:
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 50:
            raise DownloadError("invalid_page", "download history limit must be between 1 and 50")
        return [self._public(row) for row in self.store.recent(limit)]

    async def forget(self, operation_id: Any) -> None:
        """Delete one ended download's record, as its Delete button asks."""
        operation_id = self._require_operation_id(operation_id)
        async with self._lock:
            row = self._require_row(operation_id)
            if row["state"] not in _TERMINAL_STATES:
                raise DownloadError("not_finished", "only a download that has ended can be "
                                    "deleted; cancel it first")
            if not self.store.forget(operation_id):
                raise DownloadError("in_queue", "the queue is still following this download")

    async def forget_finished(self) -> int:
        """Delete every ended download's record, as Clear asks."""
        async with self._lock:
            return self.store.forget()

    async def cancel(self, operation_id: str) -> dict[str, Any]:
        async with self._lock:
            row = self._require_row(operation_id)
            if row["state"] in _TERMINAL_STATES:
                return self._public(row)
            if row["cancel_requested"] or not row["job_id"]:
                row = await self._reconcile(row)
                if row["state"] in _TERMINAL_STATES or not row["job_id"]:
                    return self._public(row)
            self.store.mark_cancel_requested(operation_id)
            try:
                response = await self.engine.request(
                    "job.cancel", {"job_id": row["job_id"]},
                    operation_id=self._cancel_operation_id(operation_id),
                )
            except EngineRequestError as exc:
                return self._public(self._engine_refusal_attention(operation_id, exc))
            except Exception:
                return self._public(self._attention(
                    operation_id, "cancel_outcome_unknown",
                    "Cancellation was not confirmed; inspect the durable engine job. No new request was sent.",
                ))
            return self._public(self._apply_job(operation_id, response.get("job")))

    async def _reconcile(self, row: dict[str, Any]) -> dict[str, Any]:
        if row["state"] in _TERMINAL_STATES:
            return row
        operation_id = row["operation_id"]
        if row["job_id"]:
            try:
                response = await self.engine.request("job.status", {"job_id": row["job_id"]})
            except EngineRequestError as exc:
                return self._engine_refusal_attention(operation_id, exc)
            except Exception:
                # The engine could not be asked; the last durable view stands.
                return row
            return self._apply_job(operation_id, response.get("job"))
        try:
            job = await self._find_engine_job(operation_id)
        except Exception:
            return self._attention(
                operation_id, "job_lookup_unavailable",
                "The durable engine job could not be queried. The download will not be replayed.",
            )
        if job is None:
            return self._attention(
                operation_id, "job_not_reconciled",
                "No durable engine job matched this operation. It will not be replayed.",
            )
        return self._apply_job(operation_id, job)

    async def resolve_uncertain(
        self, operation_id: str, *, confirmation: Any,
    ) -> dict[str, Any]:
        """Retire one unresolvable operation only after explicit confirmation.

        This is a local bookkeeping action; it does not query or cancel the
        engine, and it never replays the original request. It applies only
        when the engine has nothing to act on: no job was ever correlated,
        or the engine reported the recorded job as missing from its journal.
        The operator must verify that no transfer is active and accept that
        remote queue state may remain unknown.
        """
        self._require_operation_id(operation_id)
        if confirmation != self.uncertain_resolution_phrase(operation_id):
            raise DownloadError(
                "confirmation_required",
                "explicitly confirm this exact operation with its ABANDON-UNCERTAIN phrase",
            )
        async with self._lock:
            saved, changed = self.store.abandon_uncertain(operation_id)
            if saved is None:
                raise DownloadError("unknown_operation", "download operation was not found")
            if not changed:
                raise DownloadError(
                    "not_resolvable",
                    "only a needs-attention operation whose job is absent from the engine can be retired this way",
                )
            return self._public(saved)

    async def _find_engine_job(self, operation_id: str) -> dict[str, Any] | None:
        response = await self.engine.request(
            "job.find_by_operation", {"web_operation_id": operation_id},
        )
        job = response.get("job") if isinstance(response, dict) else None
        return job if isinstance(job, dict) else None

    def _apply_job(self, operation_id: str, job: Any) -> dict[str, Any]:
        if (not isinstance(job, dict)
                or job.get("web_operation_id") != operation_id
                or not isinstance(job.get("job_id"), str)
                or not re.fullmatch(r"job-[0-9a-f]{32}", job["job_id"])
                or not isinstance(job.get("state"), str)
                or job["state"] not in _ENGINE_JOB_STATES):
            return self._attention(
                operation_id, "invalid_job_evidence",
                "The engine returned a malformed, unknown-state, or non-matching durable job record. It will not be replayed.",
            )
        sequence = job.get("transition_sequence")
        if (isinstance(sequence, bool) or not isinstance(sequence, int)
                or not 0 <= sequence <= _SQLITE_INTEGER_MAX):
            return self._attention(
                operation_id, "invalid_transition_sequence",
                "The engine job omitted a valid non-negative transition sequence. It will not be replayed.",
            )
        download_path = _text(job.get("download_path"), 2048)
        if download_path and (download_path.startswith(("/", "\\")) or
                              ".." in Path(download_path).parts):
            download_path = None
        applied, _disposition = self.store.apply_engine_job(
            operation_id, job_id=job["job_id"], sequence=sequence, state=job["state"],
            outcome=_text(job.get("outcome"), 96),
            reason=_text(job.get("reason")),
            sender=_text(job.get("sender"), 128),
            name=_text(job.get("name"), 512),
            remote_path=_text(job.get("remote_path"), 4096),
            download_path=download_path,
            bytes_received=_optional_count(job.get("bytes_received")),
            total_bytes=_optional_count(job.get("total_bytes")),
        )
        return applied
