"""Process runtime: one engine connection and the services built on it.

The engine bridge can go away (Irssi restart, protocol fault). Services are
bound to one engine connection, so each new connection gets a fresh set and
its startup reconciliation; nothing is dispatched while reconnecting.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
import logging
import os
from pathlib import Path
import time

from .adverts import AdvertService
from .browse import BrowseService
from .auth import AuthError, Authenticator, CredentialStore
from .download_queue import QueueService
from .downloads import DownloadService
from .engine_client import EngineClient, EngineProtocolError
from .engine_log import LogBook, LogCopier
from .manifests import ManifestService
from .servers import ServersService
from .multisearch import MultiSearchService
from .saved_searches import SavedSearchService
from .searches import SearchService
from .sources import SourceApplyPending, SourceConfigStore, SourceService


logger = logging.getLogger("dccatlas.web")
RECONNECT_SECONDS = 1.0
# Seconds an unreachable engine is tolerated quietly, and the least time
# between two reports of a failure that keeps repeating.
UNREACHABLE_GRACE_SECONDS = 10.0
REPORT_INTERVAL_SECONDS = 60.0
# The health check and same-machine browsing always use these names. They
# cannot be reached through another site's host name, so they stay allowed.
LOOPBACK_HOSTS = ("localhost", "127.0.0.1")


@dataclass(frozen=True)
class Services:
    sources: SourceService
    searches: SearchService
    downloads: DownloadService
    multi: MultiSearchService | None = None
    manifests: ManifestService | None = None
    adverts: AdvertService | None = None
    queue: QueueService | None = None
    browses: BrowseService | None = None
    saved: SavedSearchService | None = None
    servers: ServersService | None = None


@dataclass(frozen=True)
class Settings:
    database: Path
    socket_path: str
    password_file: str | None
    cookie_secure: bool
    allowed_hosts: tuple[str, ...]

    @classmethod
    def from_environment(cls) -> Settings:
        config_dir = Path(os.environ.get("FSERVE_CONFIG_DIR", "/config"))
        configured = (
            item.strip() for item in os.environ.get("FSERVE_ALLOWED_HOSTS", "").split(",")
        )
        hosts = tuple(dict.fromkeys((*LOOPBACK_HOSTS, *filter(None, configured))))
        return cls(
            database=config_dir / "fserve" / "fserve.sqlite3",
            socket_path=os.environ.get(
                "FSERVE_ENGINE_SOCKET",
                str(config_dir / "irssi" / "fserve-poc" / "engine.sock")),
            password_file=os.environ.get(
                "FSERVE_PASSWORD_FILE", "/run/secrets/dccatlas_password"),
            cookie_secure=os.environ.get("FSERVE_COOKIE_SECURE", "") == "1",
            allowed_hosts=hosts,
        )


class Runtime:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        # Creating the source store first establishes the private database
        # file and directory permissions that every other store relies on.
        SourceConfigStore(settings.database)
        self.auth = Authenticator(CredentialStore(settings.database))
        self.password_problem: str | None = None
        try:
            self.auth.apply_password_file(settings.password_file)
        except AuthError as exc:
            self.password_problem = exc.message
        # With no password yet, the page asks for this code: only someone who
        # can read the container's log sees it.
        code = self.auth.setup_code()
        if code is not None:
            logger.warning("Setup code: %s (enter it on the DCCAtlas page to set the "
                           "password; a new one is printed at each start until then)", code)
        self.services: Services | None = None
        # Kept across engine connections, and saved next to the database, so
        # the lines from before a restart of either stay readable.
        self.log = LogBook(path=settings.database.parent / "connection-log.jsonl")
        # Lists stored in the old layout are rewritten once a start (2026-10-28).
        self._compactor: asyncio.Task[None] | None = None
        self.source_restore_pending = False
        self._task: asyncio.Task[None] | None = None
        self._failing_since: float | None = None
        self._reported_at: float | None = None

    async def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._maintain())

    async def stop(self) -> None:
        if self._compactor is not None and not self._compactor.done():
            self._compactor.cancel()
        task, self._task = self._task, None
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    async def _compact_lists(self, manifests: ManifestService) -> None:
        try:
            compacted = await manifests.compact()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.error("stored file lists could not be compacted: %s", exc)
            return
        for item in compacted:
            before, after = item.get("bytes_before"), item.get("bytes_after")
            if isinstance(before, int) and isinstance(after, int):
                self.log.add("web", f"A stored file list was rewritten smaller: "
                                    f"{before / 2**20:.0f} MB to {after / 2**20:.0f} MB")

    def _report(self, message: str, exc: BaseException, *, grace: float = 0.0,
                traceback: bool = False) -> None:
        """Log a failure that is being retried, without repeating it every second."""
        now = time.monotonic()
        if self._failing_since is None:
            self._failing_since = now
        if now - self._failing_since < grace:
            return
        if self._reported_at is not None and now - self._reported_at < REPORT_INTERVAL_SECONDS:
            return
        self._reported_at = now
        logger.error("%s; retrying: %s: %s", message, type(exc).__name__, exc,
                     exc_info=exc if traceback else None)

    async def _maintain(self) -> None:
        while True:
            try:
                client = await EngineClient.open(self.settings.socket_path)
            except (OSError, asyncio.TimeoutError, EngineProtocolError) as exc:
                self._report("the engine bridge is not reachable", exc,
                             grace=UNREACHABLE_GRACE_SECONDS)
                await asyncio.sleep(RECONNECT_SECONDS)
                continue
            searches: SearchService | None = None
            multi: MultiSearchService | None = None
            queue: QueueService | None = None
            copier: asyncio.Task[None] | None = None
            self.log.add("web", "Connected to the engine")
            try:
                sources = SourceService(self.settings.database, client)
                copier = asyncio.create_task(LogCopier(
                    self.log, client,
                    lambda: {item.source_id: item.label for item in sources.store.list()},
                ).run())
                try:
                    await sources.startup()
                    self.source_restore_pending = False
                except SourceApplyPending:
                    self.source_restore_pending = True
                searches = SearchService(sources)
                await searches.startup()
                downloads = DownloadService(sources, searches)
                await downloads.startup()
                multi = MultiSearchService(searches)
                await multi.startup()
                manifests = ManifestService.from_environment(downloads)
                downloads.manifests = manifests
                if self._compactor is None:
                    self._compactor = asyncio.create_task(self._compact_lists(manifests))
                multi.manifests = manifests
                downloads.browses = browses = BrowseService(downloads)
                queue = QueueService(downloads)
                adverts = queue.adverts = manifests.adverts = downloads.adverts = AdvertService(
                    sources)
                self.services = Services(sources, searches, downloads, multi, manifests,
                                         adverts, queue, browses,
                                         SavedSearchService(sources),
                                         ServersService(downloads, manifests))
                queue.start_runner()
                self._failing_since = self._reported_at = None
                await client.wait_closed()
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                # A failed startup is retried on a fresh connection below.
                self._report("the engine services could not start", exc, traceback=True)
            finally:
                self.services = None
                if copier is not None:
                    copier.cancel()
                    try:
                        await copier
                    except asyncio.CancelledError:
                        pass
                    except Exception as exc:
                        logger.error("the connection log stopped copying: %s", exc)
                self.log.add("web", "Lost the engine connection")
                if queue is not None:
                    await queue.close()
                if multi is not None:
                    await multi.close()
                if searches is not None:
                    await searches.close()
                await client.close()
            await asyncio.sleep(RECONNECT_SECONDS)
