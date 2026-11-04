"""The download queue (web M3, Y3).

The operator adds files from search results and stored file lists, then
presses Start. The files are fetched one at a time, each through the same
checked path as a Download press: for a file server's file, a fresh listing of
its folder before any request; for a search bot's row or a row a file server
sent to be posted back, the row posted exactly as it came, from the copy the
engine kept of its list when the row was added. Either way the engine's own
spacing and its one request per file server and file name on a connection
apply.

The queue goes on only after a file arrives complete, or after "Not requested"
(the fresh listing showed the file gone, or it was already asked for on this
connection; nothing was sent for it). With two downloads at once allowed
(2026-10-22), the next file also starts while one is being received, if it
comes from another file server and neither is a row to post back. At anything else it pauses and waits
for the operator. It never starts by itself: after a restart of the web
service or the engine it comes back paused, and it pauses when a source's
connection is not the one it had when Start was pressed.

Each file is an ordinary download operation under a key of its own, so a
restart in the middle finds that operation again and never sends it twice.
"""

from __future__ import annotations

import asyncio
from contextlib import closing, contextmanager
import logging
import os
from pathlib import Path
import re
import sqlite3
import time
import uuid
from typing import Any, Iterator

from .downloads import DownloadError, DownloadService
from .engine_client import EngineRequestError
from .errors import ServiceError
from .ids import BROWSE_ROW, IRC_NICK, LIST_ROW, SEARCH_ROW
from .searches import ACTIVE_ENGINE_STATES, SearchError


logger = logging.getLogger("dccatlas.web")
MAX_WAITING = 25            # files queued or running at once
MAX_SHOWN = 60              # finished files kept for the page, newest first
TICK_SECONDS = 1.0
RETRY_SECONDS = 5.0         # after the engine said "busy" and sent nothing
RETRY_MAX_SECONDS = 60.0    # the wait doubles after each "busy", up to this
MAX_BUSY_RETRIES = 6        # about three minutes of "busy", then the queue pauses
_TERMINAL = {"complete", "failed", "cancelled", "expired", "stale",
             "refused_without_queue", "abandoned_uncertain"}
# Nothing was asked for: the file had gone, or was already asked for.
_NOT_REQUESTED = {"live_parent_file_missing", "tuple_preflight_refused"}
# The download cannot move until the operator does something.
_STUCK = {"interrupted", "needs_attention", "resume_pending"}
# Refusals that prove nothing was sent and that pass by themselves.
_BUSY = {"search_active", "transfer_busy", "download_busy"}
# Refusals of a posted row that prove nothing was sent and never pass: its
# kept list is gone, or the file was already asked for on this connection.
_POSTED_NOT_SENT = {"stale_hold", "repeat_refused", "not_a_list_server"}
# A posted row, a list server's file, and a list server's whole list (Get
# list, queued since 2026-10-29) each run alone.
_POSTED = {"posted", "listed", "list"}
_HOLD_ID = re.compile(r"hold-[0-9a-f]{32}")
# What the pause says for a file whose session never opened (2026-10-22).
_WHY = {
    "session_not_opened": "the file server did not open a session; the trigger was not sent again",
    "session_unreachable": "its session could not be reached; the trigger was not sent again",
}

_QUEUE_TABLE = """
    CREATE TABLE IF NOT EXISTS download_queue (
        item_id TEXT PRIMARY KEY,
        position INTEGER NOT NULL,
        state TEXT NOT NULL CHECK (state IN
            ('queued', 'running', 'done', 'not_requested', 'stopped')),
        source_id TEXT NOT NULL,
        source_revision INTEGER NOT NULL,
        result_id TEXT NOT NULL,
        origin TEXT NOT NULL CHECK (origin IN ('search', 'file_list', 'browse', 'list')),
        sender TEXT NOT NULL,
        trigger_text TEXT NOT NULL,
        trigger_mode TEXT NOT NULL CHECK (trigger_mode IN
            ('channel_text', 'ctcp', 'posted', 'listed', 'list')),
        remote_path TEXT NOT NULL,
        size_bytes INTEGER,
        attempt INTEGER NOT NULL DEFAULT 0,
        operation_key TEXT,
        outcome TEXT,
        added_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        hold_id TEXT CHECK ((trigger_mode = 'posted') = (hold_id IS NOT NULL))
    )
"""
_QUEUE_COLUMNS = ("item_id, position, state, source_id, source_revision, result_id, origin, "
                  "sender, trigger_text, trigger_mode, remote_path, size_bytes, attempt, "
                  "operation_key, outcome, added_at, updated_at")


class QueueError(ServiceError):
    pass


class QueueStore:
    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if not self.path.exists() or not self.path.is_file() or self.path.is_symlink():
            raise ValueError("initialize the source store before the queue store")
        with self._transaction() as connection:
            existing = connection.execute(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='download_queue'"
            ).fetchone()
            if existing is not None and "'listed', 'list'" not in existing[0]:
                # Posted rows, browsed files, list servers' files ('listed',
                # 2026-10-27) and whole lists ('list', 2026-10-29) came later;
                # the table is rebuilt to allow them.
                columns = _QUEUE_COLUMNS + (", hold_id" if "hold_id" in existing[0] else "")
                connection.execute("ALTER TABLE download_queue RENAME TO download_queue_old")
                connection.execute(_QUEUE_TABLE)
                connection.execute(
                    f"INSERT INTO download_queue ({columns}) "
                    f"SELECT {columns} FROM download_queue_old")
                connection.execute("DROP TABLE download_queue_old")
            connection.execute(_QUEUE_TABLE)
            connection.execute("""
                CREATE TABLE IF NOT EXISTS download_queue_state (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    running INTEGER NOT NULL CHECK (running IN (0, 1)),
                    paused_reason TEXT,
                    retry_after REAL NOT NULL DEFAULT 0
                )
            """)
            connection.execute("""
                INSERT INTO download_queue_state (singleton, running) VALUES (1, 0)
                ON CONFLICT (singleton) DO NOTHING
            """)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 5000")
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

    def state(self) -> dict[str, Any]:
        with closing(self._connect()) as connection:
            return dict(connection.execute(
                "SELECT * FROM download_queue_state WHERE singleton=1").fetchone())

    def set_state(self, *, running: bool, reason: str | None = None,
                  retry_after: float = 0.0) -> None:
        with self._transaction() as connection:
            connection.execute(
                "UPDATE download_queue_state SET running=?, paused_reason=?, retry_after=? "
                "WHERE singleton=1", (int(running), reason, retry_after))

    def set_retry_after(self, when: float) -> None:
        with self._transaction() as connection:
            connection.execute("UPDATE download_queue_state SET retry_after=? WHERE singleton=1",
                               (when,))

    def items(self) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            waiting = connection.execute(
                "SELECT * FROM download_queue WHERE state IN ('queued', 'running') "
                "ORDER BY position").fetchall()
            finished = connection.execute(
                "SELECT * FROM download_queue WHERE state NOT IN ('queued', 'running') "
                "ORDER BY updated_at DESC, position DESC LIMIT ?", (MAX_SHOWN,)).fetchall()
        return [dict(row) for row in waiting] + [dict(row) for row in finished]

    def get(self, item_id: str) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT * FROM download_queue WHERE item_id=?", (item_id,)).fetchone()
        return dict(row) if row is not None else None

    def running(self) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            rows = connection.execute(
                "SELECT * FROM download_queue WHERE state='running' ORDER BY position").fetchall()
        return [dict(row) for row in rows]

    def next_queued(self) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT * FROM download_queue WHERE state='queued' "
                "ORDER BY position LIMIT 1").fetchone()
        return dict(row) if row is not None else None

    def add(self, item: dict[str, Any]) -> dict[str, Any]:
        now = time.time()
        with self._transaction() as connection:
            waiting = connection.execute(
                "SELECT * FROM download_queue WHERE state IN ('queued', 'running')").fetchall()
            if len(waiting) >= MAX_WAITING:
                raise QueueError("queue_full", f"the queue holds at most {MAX_WAITING} files")
            for row in waiting:
                if (row["source_id"] == item["source_id"]
                        and row["sender"].lower() == item["sender"].lower()
                        and row["remote_path"] == item["remote_path"]):
                    raise QueueError("already_queued", "this file is already in the queue")
            position = connection.execute(
                "SELECT COALESCE(MAX(position), 0) + 1 FROM download_queue").fetchone()[0]
            item_id = "queue-" + uuid.uuid4().hex
            connection.execute("""
                INSERT INTO download_queue (item_id, position, state, source_id, source_revision,
                    result_id, origin, sender, trigger_text, trigger_mode, remote_path, size_bytes,
                    added_at, updated_at, hold_id)
                VALUES (?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (item_id, position, item["source_id"], item["source_revision"], item["result_id"],
                  item["origin"], item["sender"], item["trigger_text"], item["trigger_mode"],
                  item["remote_path"], item.get("size_bytes"), now, now, item.get("hold_id")))
        added = self.get(item_id)
        assert added is not None
        return added

    def remove(self, item_id: str) -> bool:
        """Remove a file that has not started, or a finished one."""
        with self._transaction() as connection:
            return connection.execute(
                "DELETE FROM download_queue WHERE item_id=? AND state != 'running'",
                (item_id,)).rowcount == 1

    def clear_finished(self) -> None:
        with self._transaction() as connection:
            connection.execute(
                "DELETE FROM download_queue WHERE state NOT IN ('queued', 'running')")

    def start_item(self, item_id: str, key: str) -> None:
        with self._transaction() as connection:
            connection.execute(
                "UPDATE download_queue SET state='running', operation_key=?, updated_at=? "
                "WHERE item_id=? AND state='queued'", (key, time.time(), item_id))

    def back_to_queued(self, item_id: str) -> None:
        """The engine was busy and sent nothing: wait, and try under a new key."""
        with self._transaction() as connection:
            connection.execute(
                "UPDATE download_queue SET state='queued', operation_key=NULL, "
                "attempt=attempt+1, updated_at=? WHERE item_id=?", (time.time(), item_id))

    def finish(self, item_id: str, state: str, outcome: str | None) -> None:
        with self._transaction() as connection:
            connection.execute(
                "UPDATE download_queue SET state=?, outcome=?, updated_at=? WHERE item_id=?",
                (state, outcome, time.time(), item_id))


def _name(path: str) -> str:
    return path.rsplit("/", 1)[-1] or path


def _search_running(status: Any) -> bool:
    """True while the engine has a search going; a download would be refused."""
    if not isinstance(status, dict):
        return False
    views = [status.get("search")]
    if isinstance(status.get("searches"), dict):
        views.extend(status["searches"].values())
    return any(isinstance(view, dict) and view.get("state") in ACTIVE_ENGINE_STATES
               for view in views)


class QueueService:
    def __init__(self, downloads: DownloadService) -> None:
        self.downloads = downloads
        self.sources = downloads.sources
        self.searches = downloads.searches
        self.store = QueueStore(self.sources.store.path)
        self._lock = asyncio.Lock()
        self._task: asyncio.Task[None] | None = None
        # "Busy" refusals in a row since Start or the last file requested.
        self._busy_retries = 0
        # Each source's connection, as it was at Start (or when the queue
        # first used it, for one connected later). Another one means the
        # source reconnected, and the queue pauses rather than going on.
        self._connections: dict[str, Any] = {}
        # The servers seen, which vouch for a list server to the engine.
        self.adverts: Any = None
        # A queue never runs on by itself after a restart.
        state = self.store.state()
        if state["running"]:
            self.store.set_state(
                running=False,
                reason="DCCAtlas or its engine restarted, so the queue was paused. "
                       "Press Start to go on.")

    # -- what the page sees and does -----------------------------------------

    def view(self) -> dict[str, Any]:
        state = self.store.state()
        return {
            "running": bool(state["running"]),
            "paused_reason": state["paused_reason"],
            "limit": MAX_WAITING,
            "items": [{
                "item_id": item["item_id"], "state": item["state"],
                "source_id": item["source_id"], "origin": item["origin"],
                "sender": item["sender"], "trigger": item["trigger_text"],
                "trigger_mode": item["trigger_mode"], "path": item["remote_path"], "name": _name(item["remote_path"]),
                "size_bytes": item["size_bytes"], "outcome": item["outcome"],
                "operation_id": (self.downloads._operation_id(item["operation_key"])
                                 if item["operation_key"] else None),
                "added_at": item["added_at"], "updated_at": item["updated_at"],
            } for item in self.store.items()],
        }

    async def add(self, result_id: Any) -> dict[str, Any]:
        if isinstance(result_id, str) and SEARCH_ROW.fullmatch(result_id):
            item = await self._from_search(result_id)
        elif isinstance(result_id, str) and LIST_ROW.fullmatch(result_id):
            item = await self._from_file_list(result_id)
        elif isinstance(result_id, str) and BROWSE_ROW.fullmatch(result_id):
            item = await self._from_browse(result_id)
        else:
            raise QueueError("invalid_result", "result ID is invalid")
        async with self._lock:
            self.store.add(item)
        return self.view()

    async def list_should_wait(self) -> bool:
        """Whether Get list should queue rather than go now (2026-10-29):
        something is being fetched, the queue holds files ahead of it, or a
        search is running, any of which the engine would refuse it for."""
        if self.downloads.store.active() or self.store.running() or self.store.next_queued():
            return True
        try:
            return _search_running(await self.sources.engine.status())
        except Exception:
            return False

    async def add_list(self, source_id: Any, sender: Any) -> dict[str, Any]:
        """Queue Get list of a list server. A press of Get list starts a paused
        queue that holds nothing but lists; other files queued wait for Start."""
        config = self.sources.store.get(source_id) if isinstance(source_id, str) else None
        if config is None:
            raise QueueError("unknown_source", "that source is not configured")
        if not isinstance(sender, str) or not IRC_NICK.fullmatch(sender):
            raise QueueError("invalid_request", "name the list server's nickname")
        async with self._lock:
            # A nick in any case is the same server.
            if any(item["state"] in ("queued", "running") and item["trigger_mode"] == "list"
                   and item["source_id"] == config.source_id
                   and item["sender"].lower() == sender.lower() for item in self.store.items()):
                raise QueueError("already_queued", f"{sender}'s list is already in the queue")
            self.store.add({
                "source_id": config.source_id, "source_revision": config.revision,
                "result_id": f"list-{config.source_id}-{sender}", "origin": "list",
                "sender": sender, "trigger_text": "@" + sender, "trigger_mode": "list",
                "remote_path": f"{sender}'s list", "size_bytes": None,
            })
            waiting = [item for item in self.store.items()
                       if item["state"] in ("queued", "running")]
            start = (not self.store.state()["running"]
                     and all(item["trigger_mode"] == "list" for item in waiting))
        if start:
            return await self.start()
        return self.view()

    async def _from_search(self, result_id: str) -> dict[str, Any]:
        stored = self.searches.store.find_result(result_id)
        if stored is None:
            raise QueueError("unknown_result", "result history row was not found")
        try:
            # The same check as a Download press: the result is from the
            # current search, on the source as it is now, connected.
            selection = await self.searches.resolve_result(result_id)
        except SearchError as exc:
            raise QueueError(exc.code, exc.message) from exc
        item = {
            "source_id": selection["source_id"], "source_revision": selection["source_revision"],
            "result_id": result_id, "origin": "search", "sender": stored["sender"],
            "trigger_text": stored["trigger_text"],
            "remote_path": stored["remote_path"], "size_bytes": stored["size_bytes"],
        }
        if stored["provider"] != "searchbot" and stored["trigger_mode"] != "direct":
            return {**item, "trigger_mode": "ctcp" if stored["trigger_mode"] == "ctcp"
                    else "channel_text"}
        # A search bot's row, or a "!Nick file" row a file server sent, is
        # fetched by posting it back as its list gave it. The source's next
        # search replaces that list, so the engine keeps a copy for the queue.
        try:
            held = await self.sources.engine.request("searchbot.hold", {
                "source_id": selection["source_id"],
                "search_id": selection["engine_search_id"],
                "selection_id": selection["engine_selection_id"],
            })
        except EngineRequestError as exc:
            raise QueueError(exc.code, exc.message) from exc
        hold_id = held.get("hold_id") if isinstance(held, dict) else None
        if not isinstance(hold_id, str) or not _HOLD_ID.fullmatch(hold_id):
            raise QueueError("engine_unavailable", "the engine did not keep the row for the queue")
        return {**item, "trigger_mode": "posted", "hold_id": hold_id}

    async def _from_file_list(self, result_id: str) -> dict[str, Any]:
        manifests = self.downloads.manifests
        if manifests is None:
            raise QueueError("file_lists_unavailable", "file lists are not available")
        try:
            selection = await manifests.resolve_result(result_id)
        except ValueError as exc:
            raise QueueError(getattr(exc, "code", "stale_result"),
                             getattr(exc, "message", str(exc))) from exc
        if selection.get("posted"):
            # A list server's file (2026-10-27): its row is built again from
            # the stored list when its turn comes, and posted back.
            target = selection["engine_arguments"]
            return {
                "source_id": selection["source_id"],
                "source_revision": selection["source_revision"],
                "result_id": result_id, "origin": "file_list", "sender": target["sender"],
                "trigger_text": "!" + target.get("list_name", target["sender"]),
                "trigger_mode": "listed",
                "remote_path": selection["remote_path"],
                "size_bytes": selection.get("size_bytes"),
            }
        target = selection["engine_arguments"]
        return {
            "source_id": selection["source_id"], "source_revision": selection["source_revision"],
            "result_id": result_id, "origin": "file_list", "sender": target["sender"],
            "trigger_text": target["trigger"], "trigger_mode": target["trigger_mode"],
            "remote_path": target["path"], "size_bytes": None,
        }

    async def _from_browse(self, result_id: str) -> dict[str, Any]:
        browses = self.downloads.browses
        if browses is None:
            raise QueueError("browse_unavailable", "browsing is not available")
        try:
            selection = await browses.resolve_result(result_id)
        except ValueError as exc:
            raise QueueError(getattr(exc, "code", "stale_result"),
                             getattr(exc, "message", str(exc))) from exc
        target = selection["engine_arguments"]
        return {
            "source_id": selection["source_id"], "source_revision": selection["source_revision"],
            "result_id": result_id, "origin": "browse", "sender": target["sender"],
            "trigger_text": target["trigger"], "trigger_mode": target["trigger_mode"],
            "remote_path": target["path"], "size_bytes": selection.get("size_bytes"),
        }

    async def requeue(self, item_id: Any) -> dict[str, Any]:
        """Put a stopped file back at the end of the queue, by the target it captured.

        It is asked for only once the operator presses Start, and as any
        queued file is. A row to post back is tied to the list of the
        connection it came from, so it is not put back (search again).
        """
        async with self._lock:
            item = self.store.get(item_id) if isinstance(item_id, str) else None
            if item is None:
                raise QueueError("unknown_item", "that file is not in the queue")
            if item["state"] != "stopped":
                raise QueueError("not_requeueable", "only a stopped file can be queued again")
            if item["trigger_mode"] == "posted":
                raise QueueError("not_requeueable", "a row posted back belongs to the search it "
                                 "came from; search again and add it from there")
            # A list server's file is requeued like any other; whether the
            # engine asks for it again on this connection is the engine's.
            config = self.sources.store.get(item["source_id"])
            if config is None or config.revision != item["source_revision"]:
                raise QueueError("not_requeueable", "its source was changed or removed since; "
                                 "search again")
            self.store.add(item)   # refused when the queue is full; then the old one stays
            self.store.remove(item_id)
        return self.view()

    async def remove(self, item_id: str) -> dict[str, Any]:
        async with self._lock:
            if not self.store.remove(item_id):
                raise QueueError("not_removable", "only a file that is not being fetched can be removed")
        return self.view()

    async def clear_finished(self) -> dict[str, Any]:
        async with self._lock:
            self.store.clear_finished()
        return self.view()

    async def start(self) -> dict[str, Any]:
        async with self._lock:
            self._busy_retries = 0
            self._connections = await self._current_connections()
            self.store.set_state(running=True)
        await self.tick()
        return self.view()

    async def pause(self) -> dict[str, Any]:
        async with self._lock:
            self.store.set_state(running=False, reason="Paused. The file being fetched carries on.")
        return self.view()

    async def _current_connections(self) -> dict[str, Any]:
        try:
            status = await self.sources.engine.status()
        except Exception:
            return {}   # a source that is not seen now is taken when first used
        sources = status.get("sources") if isinstance(status, dict) else None
        return {source["source_id"]: source.get("connection_epoch")
                for source in sources or []
                if isinstance(source, dict) and isinstance(source.get("source_id"), str)
                and source.get("state") == "ready"}

    # -- the runner ----------------------------------------------------------

    def start_runner(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._run())

    async def close(self) -> None:
        task, self._task = self._task, None
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    async def _run(self) -> None:
        while True:
            try:
                await self.tick()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("the download queue could not go on; it was paused")
                try:
                    self.store.set_state(
                        running=False, reason="Something unexpected happened, so the queue "
                                              "was paused. Press Start to try again.")
                except Exception:
                    pass
            await asyncio.sleep(TICK_SECONDS)

    def _pause(self, reason: str) -> None:
        self.store.set_state(running=False, reason=reason)

    async def tick(self) -> None:
        async with self._lock:
            for current in self.store.running():
                await self._follow(current)
            running = self.store.running()
            state = self.store.state()
            if not state["running"] or time.time() < state["retry_after"]:
                return
            item = self.store.next_queued()
            if item is None:
                if not running:
                    self.store.set_state(running=False, reason=None)
                return
            if running and not self._alongside(item, running):
                return
            await self._begin(item)

    def _room(self) -> bool:
        """Whether a download may start now: none runs, or another fits beside it."""
        active = self.downloads.store.active()
        return not active or (len(active) < self.downloads.settings.get("downloads_at_once")
                              and all(row["state"] == "receiving" for row in active))

    def _alongside(self, item: dict[str, Any], running: list[dict[str, Any]]) -> bool:
        """Whether this file may start beside the ones being fetched."""
        # A posted row, from a search or a list server's list, runs alone.
        if item["trigger_mode"] in _POSTED or any(
                other["trigger_mode"] in _POSTED for other in running):
            return False
        if any(other["source_id"] == item["source_id"]
               and other["sender"].lower() == item["sender"].lower() for other in running):
            return False   # one at a time from each file server
        return self._room()

    async def _follow(self, item: dict[str, Any]) -> None:
        """Watch the file being fetched; decide what its end means."""
        try:
            operation = await self.downloads.status(self.downloads._operation_id(item["operation_key"]))
        except DownloadError as exc:
            if exc.code != "unknown_operation":
                raise
            # The operation was never recorded: the dispatch did not happen.
            self.store.back_to_queued(item["item_id"])
            return
        state, outcome = operation["state"], operation["outcome"]
        name = _name(item["remote_path"])
        if state == "complete":
            self.store.finish(item["item_id"], "done", None)
        elif state in _TERMINAL and outcome in _NOT_REQUESTED:
            self.store.finish(item["item_id"], "not_requested", outcome)
        elif state in _TERMINAL:
            self.store.finish(item["item_id"], "stopped", outcome or state)
            if self.store.state()["running"]:
                why = _WHY.get(outcome, outcome or state)
                self._pause(f"{name} did not arrive ({why}), so the queue was "
                            "paused. Press Start to go on with the next file.")
        elif state in _STUCK or operation.get("engine_state") in _STUCK:
            if self.store.state()["running"]:
                self._pause(f"{name} needs attention under Downloads, so the queue was paused.")

    async def _begin(self, item: dict[str, Any]) -> None:
        name = _name(item["remote_path"])
        config = self.sources.store.get(item["source_id"])
        if config is None or config.revision != item["source_revision"]:
            self.store.finish(item["item_id"], "stopped", "source_changed")
            self._pause(f"The source of {name} was changed or removed since it was queued, "
                        "so it was not requested and the queue was paused.")
            return
        status = await self.sources.engine.status()
        live = self.sources.engine_source(status, config.source_id)
        if not live or live.get("state") != "ready" or not self.sources._matches(live, config):
            self._pause(f"Connect {config.label} to go on with the queue.")
            return
        connection = live.get("connection_epoch")
        seen = self._connections.setdefault(config.source_id, connection)
        if seen != connection:
            self._pause(f"{config.label} reconnected since Start, so the queue was paused. "
                        "Press Start to go on.")
            return
        if not self._room():
            return   # a download started by hand, or one still starting
        if _search_running(status):
            # The engine would refuse while a search runs; wait for it
            # without asking, so no refused download is recorded.
            self.store.set_retry_after(time.time() + RETRY_SECONDS)
            return
        key = f"{item['item_id']}-{item['attempt']}"
        self.store.start_item(item["item_id"], key)
        selection = {
            "search_id": item["item_id"], "source_id": config.source_id,
            "source_revision": config.revision,
            "engine_instance_id": self.sources.engine.engine_instance_id,
            "engine_search_id": "queue",
        }
        if item["trigger_mode"] == "list":
            advertised = bool(self.adverts and self.adverts.offers_list(
                config.source_id, item["sender"]))
            selection["engine_operation"] = "list.request"
            selection["engine_arguments"] = {
                "source_id": config.source_id, "sender": item["sender"],
                **({"advertised": True} if advertised else {}),
                **({"typed": True} if self.adverts and self.adverts.typed(
                    config.source_id, item["sender"]) else {})}
        elif item["trigger_mode"] == "posted":
            selection["engine_operation"] = "searchbot.held_download"
            selection["engine_arguments"] = {
                "source_id": config.source_id, "hold_id": item["hold_id"]}
        elif item["trigger_mode"] == "listed":
            # The stored list still holds it, on the source as it was added:
            # the engine gets the row's name and size from there.
            try:
                resolved = await self.downloads.manifests.resolve_result(item["result_id"])
            except ValueError as exc:
                self.store.finish(item["item_id"], "not_requested",
                                  getattr(exc, "code", "stale_result"))
                return
            selection["engine_operation"] = resolved["engine_operation"]
            selection["engine_arguments"] = resolved["engine_arguments"]
        else:
            selection["engine_operation"] = "manifest.download"
            selection["engine_arguments"] = {
                "source_id": config.source_id, "sender": item["sender"],
                "trigger": item["trigger_text"], "trigger_mode": item["trigger_mode"],
                "path": item["remote_path"],
            }
        try:
            operation = await self.downloads.download_queued(key, item["result_id"], selection)
        except DownloadError as exc:
            if exc.code in _BUSY:
                # Nothing was sent. Try again later under a new key, waiting
                # longer each time, and pause if the engine stays busy.
                self.store.back_to_queued(item["item_id"])
                self._busy_retries += 1
                if self._busy_retries > MAX_BUSY_RETRIES:
                    self._pause(f"The engine stayed busy ({exc.message}), so {name} was not "
                                "requested and the queue was paused. Press Start to try again.")
                    return
                self.store.set_retry_after(time.time() + min(
                    RETRY_SECONDS * 2 ** (self._busy_retries - 1), RETRY_MAX_SECONDS))
                return
            if exc.code in _POSTED_NOT_SENT and item["trigger_mode"] in _POSTED:
                # Nothing was sent, and nothing would be on a later try.
                self.store.finish(item["item_id"], "not_requested", exc.code)
                return
            self.store.finish(item["item_id"], "stopped", exc.code)
            self._pause(f"{name} was not requested ({exc.message}), so the queue was paused.")
            return
        self._busy_retries = 0
        if item["trigger_mode"] == "list" and self.downloads.manifests is not None \
                and operation["state"] not in ("failed", "stale", "cancelled"):
            self.downloads.manifests.follow_list(operation)   # read when it arrives
        await self._follow(self.store.get(item["item_id"]) or item)


__all__ = ["QueueError", "QueueService"]
