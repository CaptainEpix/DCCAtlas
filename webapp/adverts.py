"""File servers seen in a source's channel (web M3, Y1).

The engine reads the adverts file servers send to a channel it has joined and
lists them over the bridge (``adverts.list``). Nothing is sent to IRC to get
them. This service keeps what the engine lists, so a restart of either does
not lose it, and drops a file server after a day without an advert.
"""

from __future__ import annotations

import asyncio
from contextlib import closing, contextmanager
import json
import os
from pathlib import Path
import re
import sqlite3
import time
from typing import Any, Iterator

from .engine_client import EngineRequestError
from .ids import IRC_NICK
from .sources import SourceService, UnknownSource, channel_key


STALE_SECONDS = 60 * 60          # shown greyed after an hour without an advert
KEEP_SECONDS = 24 * 60 * 60      # removed after a day
REFRESH_SECONDS = 5.0            # the engine is asked at most this often per source
PAGE_SIZE = 25                   # the engine's largest page
MAX_SERVERS = 200                # the engine keeps as many per source
_TRIGGER = re.compile(r"[^\s\x00-\x1f\x7f]{1,60}")


def _count(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 99999:
        return None
    return value


def _text(value: Any, limit: int) -> str | None:
    if not isinstance(value, str) or len(value) > limit:
        return None
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        return None
    return value


def _pair(value: Any) -> dict[str, int] | None:
    if not isinstance(value, dict):
        return None
    in_use, limit = _count(value.get("in_use")), _count(value.get("limit"))
    if in_use is None or limit is None:
        return None
    return {"in_use": in_use, "limit": limit}


def clean_advert(raw: Any) -> dict[str, Any] | None:
    """What the page may show of one engine entry; None if it is malformed."""
    if not isinstance(raw, dict):
        return None
    nick = raw.get("nick")
    if not isinstance(nick, str) or not IRC_NICK.fullmatch(nick):
        return None
    triggers = raw.get("triggers")
    if not isinstance(triggers, list) or len(triggers) > 8:
        return None
    cleaned_triggers = []
    for item in triggers:
        if not isinstance(item, dict) or item.get("kind") not in ("channel", "ctcp", "list"):
            return None
        trigger = item.get("trigger")
        if not isinstance(trigger, str) or not _TRIGGER.fullmatch(trigger):
            return None
        entry: dict[str, Any] = {"trigger": trigger, "kind": item["kind"],
                                 "voice_only": item.get("voice_only") is True}
        if item["kind"] == "ctcp":
            ctcp_nick = item.get("ctcp_nick")
            if not isinstance(ctcp_nick, str) or not IRC_NICK.fullmatch(ctcp_nick):
                return None
            entry["ctcp_nick"] = ctcp_nick
            entry["ctcp_nick_is_sender"] = item.get("ctcp_nick_is_sender") is True
        for key in ("pool", "queued", "queue_limit"):
            if key in item:
                number = _count(item[key])
                if number is None:
                    return None
                entry[key] = number
        cleaned_triggers.append(entry)
    advert: dict[str, Any] = {"nick": nick, "triggers": cleaned_triggers}
    for key in ("users", "sends"):
        if key in raw:
            pair = _pair(raw[key])
            if pair is None:
                return None
            advert[key] = pair
    if "queues" in raw:
        queues = raw["queues"]
        pair = _pair(queues)
        pools = _text(queues.get("pools"), 100) if isinstance(queues, dict) else None
        if pair is None and pools is None:
            return None
        advert["queues"] = pair if pair is not None else {"pools": pools}
    advert["script"] = raw.get("script", "sysreset")
    if advert["script"] not in ("sysreset", "fserve.pl", "list"):
        return None
    # A list server's one trigger is "@" and its own nick (2026-10-27); a
    # file server may offer its list so too, beside its own (2026-10-29).
    listed = [item for item in cleaned_triggers if item["kind"] == "list"]
    if advert["script"] == "list" and len(cleaned_triggers) != 1:
        return None
    if (advert["script"] == "list" and not listed) or len(listed) > 1 or any(
            item["trigger"] != "@" + nick for item in listed):
        return None
    if advert["script"] != "list" and listed and len(cleaned_triggers) == len(listed):
        return None   # a file server's advert names its own trigger too
    for key, limit in (("message", 300), ("notice", 300), ("content", 300), ("version", 16)):
        if key in raw:
            value = _text(raw[key], limit)
            if value is None:
                return None
            advert[key] = value
    if "restricted" in raw:
        if raw["restricted"] not in ("OP", "Voice"):
            return None
        advert["restricted"] = raw["restricted"]
    stats = raw.get("stats")
    if stats is not None:
        if not isinstance(stats, dict) or len(stats) > 12:
            return None
        cleaned_stats = {}
        for key, value in stats.items():
            key_text, value_text = _text(key, 40), _text(value, 60)
            if key_text is None or value_text is None:
                return None
            cleaned_stats[key_text] = value_text
        advert["stats"] = cleaned_stats
    return advert


def nick_key(nick: str) -> str:
    """A nick as IRC compares it, ignoring letter case."""
    return channel_key(nick)


class AdvertStore:
    """The file servers seen, per source, in the existing private database."""

    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if not self.path.exists() or not self.path.is_file() or self.path.is_symlink():
            raise ValueError("initialize the source store before the advert store")
        with self._transaction() as connection:
            connection.execute("""
                CREATE TABLE IF NOT EXISTS advert (
                    source_id TEXT NOT NULL,
                    endpoint TEXT NOT NULL,
                    nick_key TEXT NOT NULL,
                    nick TEXT NOT NULL,
                    advert TEXT NOT NULL,
                    first_seen REAL NOT NULL,
                    last_seen REAL NOT NULL,
                    seen_count INTEGER NOT NULL CHECK (seen_count >= 0),
                    PRIMARY KEY (source_id, nick_key)
                )
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

    def merge(self, source_id: str, endpoint: str,
              entries: list[tuple[dict[str, Any], float, float, int]]) -> None:
        with self._transaction() as connection:
            for advert, first_seen, last_seen, seen_count in entries:
                connection.execute("""
                    INSERT INTO advert (source_id, endpoint, nick_key, nick, advert,
                                        first_seen, last_seen, seen_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (source_id, nick_key) DO UPDATE SET
                        endpoint = excluded.endpoint,
                        nick = CASE WHEN excluded.last_seen >= advert.last_seen
                                    THEN excluded.nick ELSE advert.nick END,
                        advert = CASE WHEN excluded.last_seen >= advert.last_seen
                                      THEN excluded.advert ELSE advert.advert END,
                        first_seen = CASE WHEN advert.endpoint = excluded.endpoint
                                          THEN MIN(advert.first_seen, excluded.first_seen)
                                          ELSE excluded.first_seen END,
                        last_seen = MAX(advert.last_seen, excluded.last_seen),
                        seen_count = MAX(advert.seen_count, excluded.seen_count)
                """, (source_id, endpoint, nick_key(advert["nick"]), advert["nick"],
                      json.dumps(advert, separators=(",", ":"), sort_keys=True),
                      first_seen, last_seen, seen_count))

    def prune(self, configured: dict[str, str], now: float) -> None:
        """Forget sources that are gone or moved, adverts over a day old, and the excess."""
        with self._transaction() as connection:
            rows = connection.execute("SELECT DISTINCT source_id, endpoint FROM advert").fetchall()
            for row in rows:
                if configured.get(row["source_id"]) != row["endpoint"]:
                    connection.execute("DELETE FROM advert WHERE source_id=? AND endpoint=?",
                                       (row["source_id"], row["endpoint"]))
            connection.execute("DELETE FROM advert WHERE last_seen < ?", (now - KEEP_SECONDS,))
            for source_id in configured:
                connection.execute("""
                    DELETE FROM advert WHERE source_id = ? AND nick_key NOT IN (
                        SELECT nick_key FROM advert WHERE source_id = ?
                        ORDER BY last_seen DESC, nick_key LIMIT ?)
                """, (source_id, source_id, MAX_SERVERS))

    def list(self, source_id: str, endpoint: str) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            rows = connection.execute("""
                SELECT * FROM advert WHERE source_id=? AND endpoint=?
                ORDER BY last_seen DESC, nick_key
            """, (source_id, endpoint)).fetchall()
        return [dict(row) for row in rows]


def endpoint_of(config: Any) -> str:
    return "\x1f".join((config.host.lower(), str(config.port), channel_key(config.channel)))


class AdvertService:
    def __init__(self, sources: SourceService) -> None:
        self.sources = sources
        self.store = AdvertStore(sources.store.path)
        self._refreshed: dict[str, float] = {}
        self._unrecognised: dict[str, int] = {}
        # Nicks typed into "Get list for a nick" (2026-10-29): the operator
        # vouches that each offers a list, for a day, until a restart.
        self._vouched: dict[tuple[str, str], float] = {}
        self._lock = asyncio.Lock()

    def vouch(self, source_id: str, nick: str) -> None:
        """Take nick as a list server in the source's channel, on the
        operator's word, as if it had announced itself."""
        now = time.time()
        for key in [key for key, at in self._vouched.items() if now - at > KEEP_SECONDS]:
            del self._vouched[key]
        self._vouched[(source_id, nick_key(nick))] = now

    async def list(self, source_id: str) -> dict[str, Any]:
        config = self.sources.store.get(source_id)
        if config is None:
            raise UnknownSource("no such source is configured")
        endpoint = endpoint_of(config)
        async with self._lock:
            now = time.time()
            if now - self._refreshed.get(source_id, 0.0) >= REFRESH_SECONDS:
                self._refreshed[source_id] = now
                await self._refresh(source_id, endpoint)
            self.store.prune({item.source_id: endpoint_of(item)
                              for item in self.sources.store.list()}, time.time())
        now = time.time()
        adverts = []
        for row in self.store.list(source_id, endpoint):
            advert = json.loads(row["advert"])
            age = max(0.0, now - row["last_seen"])
            adverts.append({**advert, "first_seen": row["first_seen"],
                            "last_seen": row["last_seen"], "seen_count": row["seen_count"],
                            "age_seconds": round(age), "stale": age >= STALE_SECONDS})
        return {"source_id": source_id, "supported": True, "adverts": adverts,
                "unrecognised": self._unrecognised.get(source_id)}

    def offers_list(self, source_id: str, nick: Any) -> bool:
        """Whether nick was seen offering a list in the source's channel within
        the day (2026-10-28): the engine forgets what it saw on a restart, and
        this is kept."""
        config = self.sources.store.get(source_id)
        if config is None or not isinstance(nick, str):
            return False
        cutoff = time.time() - KEEP_SECONDS
        if self._vouched.get((source_id, nick_key(nick)), 0) >= cutoff:
            return True
        return any(row["nick_key"] == nick_key(nick) and row["last_seen"] >= cutoff
                   and any(trigger.get("kind") == "list"
                           for trigger in json.loads(row["advert"]).get("triggers") or [])
                   for row in self.store.list(source_id, endpoint_of(config)))

    def typed(self, source_id: str, nick: Any) -> bool:
        """Whether the operator typed nick beside "!list" within the day: its
        list may then come from another nick (2026-11-02), as one nick
        advertises "@Name" and another sends it."""
        if not isinstance(nick, str):
            return False
        return self._vouched.get((source_id, nick_key(nick)), 0) >= time.time() - KEEP_SECONDS

    def file_server_trigger(self, source_id: str, nick: Any) -> str | None:
        """The trigger a file server's advert gave, written as the page shows
        it, for a list it sent on "@Nick" that is a listing of its files
        rather than rows to post (2026-10-29)."""
        config = self.sources.store.get(source_id)
        if config is None or not isinstance(nick, str):
            return None
        for row in self.store.list(source_id, endpoint_of(config)):
            if row["nick_key"] != nick_key(nick):
                continue
            for trigger in json.loads(row["advert"]).get("triggers") or []:
                if trigger.get("kind") == "ctcp" and trigger.get("ctcp_nick_is_sender"):
                    return f"/ctcp {trigger['ctcp_nick']} {trigger['trigger']}"
                if trigger.get("kind") == "channel":
                    return trigger["trigger"]
        return None

    async def _refresh(self, source_id: str, endpoint: str) -> None:
        """Copy the engine's list. It sends nothing to IRC."""
        entries: list[tuple[dict[str, Any], float, float, int]] = []
        offset = 0
        while offset < MAX_SERVERS:
            try:
                page = await self.sources.engine.request(
                    "adverts.list", {"source_id": source_id, "offset": offset, "limit": PAGE_SIZE})
            except EngineRequestError as exc:
                # An engine that restarted has not been given the source yet,
                # or predates adverts: keep what is stored.
                if exc.code in ("unknown_source", "unsupported_operation"):
                    return
                raise
            if not isinstance(page, dict) or not isinstance(page.get("adverts"), list):
                return
            engine_now = page.get("now")
            if not isinstance(engine_now, (int, float)) or isinstance(engine_now, bool):
                return
            # Times are taken relative to the engine's own clock.
            shift = time.time() - engine_now
            for raw in page["adverts"]:
                if not isinstance(raw, dict):
                    continue
                advert = clean_advert(raw)
                first_seen, last_seen = raw.get("first_seen"), raw.get("last_seen")
                seen_count = _count(raw.get("seen_count"))
                if (advert is None or seen_count is None
                        or not all(isinstance(value, (int, float)) and not isinstance(value, bool)
                                   for value in (first_seen, last_seen))):
                    continue
                entries.append((advert, first_seen + shift, last_seen + shift, seen_count))
            unrecognised = _count(page.get("unrecognised"))
            if unrecognised is not None:
                self._unrecognised[source_id] = unrecognised
            total = page.get("total")
            offset += PAGE_SIZE
            if not isinstance(total, int) or offset >= total or not page["adverts"]:
                break
        if entries:
            self.store.merge(source_id, endpoint, entries)
