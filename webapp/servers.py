"""Asking a source's channel which lists its servers have (2026-10-28).

"!list" goes to the channel at most once a minute (the engine keeps to that,
and to its usual spacing). For two minutes after, what servers answer is read
as their adverts are, so they show under Servers. A list a server sends
unasked in that time is taken as Get list takes one: the engine notes the
offer, and this service asks for it with ``list.accept``, one at a time, and
has it read as that server's file list.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import time
from typing import Any

from .downloads import DownloadError, DownloadService
from .engine_client import EngineRequestError
from .sources import UnknownSource


logger = logging.getLogger(__name__)

# How long offers are followed after "!list": the two minutes the engine
# listens, and the time Irssi leaves an offer pending after that.
FOLLOW_SECONDS = 7 * 60
POLL_SECONDS = 3.0
# Refusals that mean "not now": the offer is tried again on a later poll.
_BUSY = frozenset({"transfer_busy", "search_active"})


class ServersService:
    def __init__(self, downloads: DownloadService, manifests: Any) -> None:
        self.downloads = downloads
        self.sources = downloads.sources
        self.engine = downloads.engine
        self.manifests = manifests
        self._followers: dict[str, asyncio.Task[Any]] = {}
        # Per source: the lists taken from offers, for the page.
        self.taken: dict[str, list[dict[str, Any]]] = {}
        self._attempts: dict[str, int] = {}

    def _require(self, source_id: Any) -> Any:
        config = self.sources.store.get(source_id) if isinstance(source_id, str) else None
        if config is None:
            raise UnknownSource("no such source is configured")
        return config

    async def ask(self, source_id: Any) -> dict[str, Any]:
        """Send "!list" to the source's channel, and follow what comes of it."""
        self._require(source_id)
        view = await self.engine.request("servers.ask", {"source_id": source_id})
        previous = self._followers.pop(source_id, None)
        if previous is not None:
            previous.cancel()
        self.taken[source_id] = []
        task = asyncio.create_task(self._follow(source_id, view.get("asked_at")))
        self._followers[source_id] = task
        task.add_done_callback(lambda done: self._followers.get(source_id) is done
                               and self._followers.pop(source_id, None))
        return self._public(source_id, view)

    async def answers(self, source_id: Any) -> dict[str, Any]:
        self._require(source_id)
        try:
            view = await self.engine.request("servers.answers", {"source_id": source_id})
        except EngineRequestError as exc:
            if exc.code in ("unknown_source", "unsupported_operation"):
                view = {"state": "idle", "answered": [], "offers": []}
            else:
                raise
        return self._public(source_id, view)

    def _public(self, source_id: str, view: dict[str, Any]) -> dict[str, Any]:
        # Spans, not times (2026-10-28): the page counts them down by its own
        # clock, which need not agree with this computer's.
        now = view.get("now")
        now = now if isinstance(now, (int, float)) and not isinstance(now, bool) else None

        def seconds(value: Any, *, since: bool = False) -> int | None:
            if now is None or not isinstance(value, (int, float)) or isinstance(value, bool):
                return None
            return max(0, round(now - value if since else value - now))

        return {
            "source_id": source_id, "state": view.get("state", "idle"),
            "asked_seconds_ago": seconds(view.get("asked_at"), since=True),
            "listening_seconds": seconds(view.get("listening_until")),
            "wait_seconds": seconds(view.get("next_ask_at")) or 0,
            "reason": view.get("reason"),
            "answered": [nick for nick in view.get("answered") or [] if isinstance(nick, str)],
            "offers": [offer for offer in view.get("offers") or [] if isinstance(offer, dict)],
            "taken": list(self.taken.get(source_id, [])),
        }

    def _key(self, source_id: str, asked_at: Any, offer: dict[str, Any]) -> str:
        base = "\0".join((source_id, str(asked_at), offer["sender"], offer["name"]))
        attempt = self._attempts.get(base, 0)
        return "unasked-list-" + hashlib.sha256(
            f"{base}\0{attempt}".encode("utf-8")).hexdigest()[:48]

    async def _follow(self, source_id: str, asked_at: Any) -> None:
        deadline = time.monotonic() + FOLLOW_SECONDS
        while time.monotonic() < deadline:
            await asyncio.sleep(POLL_SECONDS)
            try:
                view = await self.engine.request("servers.answers", {"source_id": source_id})
            except Exception:
                continue
            if view.get("asked_at") != asked_at:
                return   # asked again since: that ask has its own follower
            offers = [offer for offer in view.get("offers") or []
                      if isinstance(offer, dict) and isinstance(offer.get("sender"), str)
                      and isinstance(offer.get("name"), str)]
            # One transfer at a time: an offer waits while anything runs.
            if offers and not self.downloads.store.active():
                await self._take(source_id, asked_at, offers[0])
            if view.get("state") in ("done", "failed") and not offers:
                return

    async def _take(self, source_id: str, asked_at: Any, offer: dict[str, Any]) -> None:
        key = self._key(source_id, asked_at, offer)
        try:
            operation = await self.downloads.accept_list(
                key, source_id, offer["sender"], offer["name"])
        except DownloadError as exc:
            base = "\0".join((source_id, str(asked_at), offer["sender"], offer["name"]))
            if exc.code in _BUSY:
                self._attempts[base] = self._attempts.get(base, 0) + 1
            else:
                logger.info("an unasked list from %s was not taken: %s", offer["sender"],
                            exc.message)
            return
        self.taken.setdefault(source_id, []).append(
            {"operation_id": operation["operation_id"], "sender": offer["sender"],
             "name": offer["name"]})
        if operation["state"] not in ("failed", "stale", "cancelled") and self.manifests:
            self.manifests.follow_list(operation)

    async def close(self) -> None:
        for task in list(self._followers.values()):
            task.cancel()
        self._followers.clear()
