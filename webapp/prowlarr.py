"""Prowlarr on its own (2026-10-26): the app as an indexer and a download client.

Prowlarr asks indexers in the Newznab dialect and hands a chosen release to a
download client in SABnzbd's; neither knows IRC, so the app answers both and
Prowlarr needs no change:

- ``/newznab/api``, added in Prowlarr as a Generic Newznab indexer. Words are
  searched as one combined search, under every rule the page's search keeps,
  of the sources whose category (webapp/categories.py) Prowlarr asked for,
  and of the stored file lists of such sources; asked for no category, only
  the stored lists, which sends nothing. Since 2026-10-28 a source of the
  category that is not connected is connected for the search, and
  disconnected again once no search has used it for a while; one the owner
  connected is left as it is. At most so many searches an hour reach IRC;
  past that Prowlarr is told "Request limit reached", which it answers by
  leaving the indexer alone for an hour (HttpIndexerBase.cs). Prowlarr gets
  its answer within ANSWER_SECONDS with what has arrived; the search goes on,
  and the same search again within REUSE_SECONDS is answered from it, so
  nothing is sent twice. A search with no words, which Prowlarr's Test and
  RSS sync send, is answered from searches already made and sends nothing.
  Anything Prowlarr counts as a failure (every error but the limit) is kept
  for real faults: "nothing to search" and "busy" are answers with no rows,
  and since 2026-10-29 every such note is said in the Log, not as a row.
- ``/sabnzbd/api``, added in Prowlarr as a SABnzbd download client with the
  URL base ``sabnzbd``. A release handed over starts as a Download press
  does, once, and its progress is reported as SABnzbd reports a job.
  ``retry`` is refused: the app never asks for a file again by itself. With
  category folders on, a finished file is moved into a folder named after
  the category its grab came with, as SABnzbd does, for Sonarr, Radarr and
  the rest to import from.

Both need the Prowlarr key, and both are off until turned on in the page.
Every reply is HTTP 200 with the dialect's own error form, never a 5xx:
Prowlarr repeats a request that fails with a 5xx.
"""

from __future__ import annotations

import asyncio
from contextlib import closing
from datetime import datetime, timezone
from email import policy
from email.parser import BytesParser
from email.utils import format_datetime
import hashlib
import hmac
import logging
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import sqlite3
import time
from typing import Any, Callable
from urllib.parse import parse_qs, urlencode, urlsplit
import uuid
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

from .downloads import DownloadError
from . import categories as cats
from .multisearch import MAX_LISTS_PER_SEARCH, MAX_SOURCES_PER_SEARCH
from .searches import MAX_PAGE_SIZE, MIN_PAGE_INTERVAL, SearchError, validate_terms
from .settings import SettingsError, SettingsStore
from .sources import SourceService


logger = logging.getLogger("dccatlas.web")

# The owner's decision of 2026-10-26: answer early, and let a repeat show
# the rest. Prowlarr itself waits 100 seconds for an indexer.
ANSWER_SECONDS = 30.0
REUSE_SECONDS = 30 * 60.0
POLL_SECONDS = 1.0
FEED_LIMIT = 100               # items in one answer; Prowlarr pages past it
MAX_FEED_ROWS = 300            # rows of one search an answer draws from
RECENT_GROUPS = 3              # searches a search with no words is answered from
MAX_GRABS = 200
DOWNLOAD_DIR = os.environ.get("FSERVE_DOWNLOAD_DIR", "/downloads")
VERSION = "4.0.0"              # SABnzbd's: Prowlarr wants 0.7.0 or later

# Searches that reach IRC from Prowlarr in an hour, by default and at most;
# connecting a source for a search; the minutes before one connected so is
# disconnected; and the wait before connecting a source that failed again.
SEARCHES_PER_HOUR = 10
MAX_SEARCHES_PER_HOUR = 60
CONNECT_WAIT_SECONDS = 25.0
IDLE_MINUTES = 30
CONNECT_RETRY_SECONDS = 10 * 60.0
LIMIT_REACHED = "Request limit reached"   # the words Prowlarr reads as the limit
IDLE_CHECK_SECONDS = 60.0
_clock = time.monotonic   # the hour's limit, connecting and idling; tests move it
_FOLDER = re.compile(r"[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}")
_TERMINAL = frozenset({"complete", "failed", "cancelled", "expired", "stale",
                       "refused_without_queue", "abandoned_uncertain"})
_RESULT_ID = re.compile(r"(?:row-[0-9a-f]{32}|mrow-[0-9a-f]{64})")
_NZO_ID = re.compile(r"SABnzbd_nzo_[0-9a-f]{16}")
_NOT_XML = re.compile("[^\t\n\r\x20-퟿-�\U00010000-\U0010ffff]")
NEWZNAB = "http://www.newznab.com/DTD/2010/feeds/attributes/"
NZB = "http://www.newzbin.com/DTD/2003/nzb"
ET.register_namespace("newznab", NEWZNAB)


def _xml_text(value: Any, maximum: int = 1024) -> str:
    text = value if isinstance(value, str) else ""
    return _NOT_XML.sub("", text)[:maximum]


def _words(terms: str) -> str:
    return " ".join(terms.split()).casefold()


def wanted_categories(raw: str | None) -> set[int] | None:
    """The categories asked for, or None when Prowlarr named none."""
    if not raw:
        return None
    return {int(part) for part in raw.split(",") if part.strip().isdigit()
            and len(part.strip()) <= 6}


def _fits(category: int, wanted: set[int] | None) -> bool:
    return wanted is None or cats.reaches(category, wanted)


class ProwlarrAccess:
    """Whether Prowlarr may use the app, and the key it must give."""

    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.store = SettingsStore(database)

    # What may be changed, its stored name, its default, and what it may be.
    SETTINGS = {
        "searches_per_hour": ("prowlarr_searches_per_hour", SEARCHES_PER_HOUR,
                              lambda value: isinstance(value, int) and not isinstance(value, bool)
                              and 1 <= value <= MAX_SEARCHES_PER_HOUR,
                              f"searches_per_hour is a whole number from 1 to "
                              f"{MAX_SEARCHES_PER_HOUR}"),
        "connect_sources": ("prowlarr_connect_sources", True,
                            lambda value: isinstance(value, bool),
                            "connect_sources is true or false"),
        "idle_minutes": ("prowlarr_idle_minutes", IDLE_MINUTES,
                         lambda value: isinstance(value, int) and not isinstance(value, bool)
                         and 5 <= value <= 240,
                         "idle_minutes is a whole number from 5 to 240"),
        "category_folders": ("prowlarr_category_folders", False,
                             lambda value: isinstance(value, bool),
                             "category_folders is true or false"),
        # Stored lists alone (2026-10-29): an answer at once, nothing sent.
        "lists_only": ("prowlarr_lists_only", False,
                       lambda value: isinstance(value, bool),
                       "lists_only is true or false"),
    }

    def view(self) -> dict[str, Any]:
        key = self.store.value("prowlarr_api_key")
        view = {"enabled": self.store.value("prowlarr_enabled") is True,
                "api_key": key if isinstance(key, str) else None}
        for name, (stored, default, allowed, _) in self.SETTINGS.items():
            value = self.store.value(stored)
            view[name] = value if value is not None and allowed(value) else default
        return view

    def update(self, values: dict[str, Any]) -> dict[str, Any]:
        changes: dict[str, Any] = {}
        if "enabled" in values:
            if not isinstance(values["enabled"], bool):
                raise SettingsError("invalid_settings", "enabled is true or false")
            changes["prowlarr_enabled"] = values["enabled"]
            if values["enabled"] and not self.view()["api_key"]:
                changes["prowlarr_api_key"] = secrets.token_hex(16)
        for name, (stored, _, allowed, rule) in self.SETTINGS.items():
            if name in values:
                if not allowed(values[name]):
                    raise SettingsError("invalid_settings", rule)
                changes[stored] = values[name]
        if not changes:
            raise SettingsError("invalid_settings", "nothing to change")
        self.store.put(changes)
        return self.view()

    def new_key(self) -> dict[str, Any]:
        self.store.put({"prowlarr_api_key": secrets.token_hex(16)})
        return self.view()

    def key(self) -> str | None:
        """The key, while Prowlarr is let in."""
        view = self.view()
        return view["api_key"] if view["enabled"] else None

    def admits(self, supplied: Any) -> bool:
        key = self.key()
        return (key is not None and isinstance(supplied, str)
                and hmac.compare_digest(supplied.encode("utf-8"), key.encode("utf-8")))

    def sign(self, result_id: str, title: str) -> str:
        key = self.key() or ""
        return hmac.new(key.encode("utf-8"), f"{result_id}\n{title}".encode("utf-8"),
                        hashlib.sha256).hexdigest()[:32]

    def signed(self, result_id: str, title: str, signature: Any) -> bool:
        return (self.key() is not None and isinstance(signature, str)
                and hmac.compare_digest(signature, self.sign(result_id, title)))


class GrabStore:
    """The releases Prowlarr handed over, by SABnzbd job ID."""

    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database)
        with closing(self._connect()) as connection:
            connection.execute("""
                CREATE TABLE IF NOT EXISTS prowlarr_grab (
                    nzo_id TEXT PRIMARY KEY,
                    result_id TEXT NOT NULL,
                    operation_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    category TEXT NOT NULL,
                    added_at REAL NOT NULL,
                    hidden INTEGER NOT NULL DEFAULT 0
                )
            """)
            columns = {row[1] for row in connection.execute("PRAGMA table_info(prowlarr_grab)")}
            if "moved_to" not in columns:
                # Where a finished file was moved for its category (2026-10-28).
                connection.execute("ALTER TABLE prowlarr_grab ADD COLUMN moved_to TEXT")

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 5000")
        return connection

    def add(self, nzo_id: str, result_id: str, operation_id: str, title: str,
            category: str) -> None:
        with closing(self._connect()) as connection:
            connection.execute("""
                INSERT INTO prowlarr_grab
                    (nzo_id, result_id, operation_id, title, category, added_at, hidden)
                VALUES (?, ?, ?, ?, ?, ?, 0)
            """, (nzo_id, result_id, operation_id, title, category, time.time()))
            connection.execute("""
                DELETE FROM prowlarr_grab WHERE nzo_id IN (
                    SELECT nzo_id FROM prowlarr_grab ORDER BY added_at DESC LIMIT -1 OFFSET ?)
            """, (MAX_GRABS,))

    def latest_for(self, result_id: str) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT * FROM prowlarr_grab WHERE result_id=? ORDER BY added_at DESC LIMIT 1",
                (result_id,)).fetchone()
        return dict(row) if row else None

    def get(self, nzo_id: str) -> dict[str, Any] | None:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT * FROM prowlarr_grab WHERE nzo_id=?", (nzo_id,)).fetchone()
        return dict(row) if row else None

    def shown(self) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            rows = connection.execute(
                "SELECT * FROM prowlarr_grab WHERE hidden=0 ORDER BY added_at").fetchall()
        return [dict(row) for row in rows]

    def moved(self, nzo_id: str, relative: str) -> None:
        with closing(self._connect()) as connection:
            connection.execute("UPDATE prowlarr_grab SET moved_to=? WHERE nzo_id=?",
                               (relative, nzo_id))

    def hide(self, nzo_id: str) -> bool:
        with closing(self._connect()) as connection:
            return connection.execute(
                "UPDATE prowlarr_grab SET hidden=1 WHERE nzo_id=?", (nzo_id,)).rowcount > 0


class Refusal(Exception):
    """A request answered with the dialect's error form."""

    def __init__(self, message: str, code: int = 900) -> None:
        super().__init__(message)
        self.message = message
        self.code = code


class ProwlarrService:
    def __init__(self, database: str | os.PathLike[str], services: Callable[[], Any],
                 log: Any = None) -> None:
        self.access = ProwlarrAccess(database)
        self.grabs = GrabStore(database)
        self._services = services
        self._log = log
        self._search_lock = asyncio.Lock()
        self._grab_lock = asyncio.Lock()
        # When searches reached IRC, for the hourly limit; the sources
        # connected for Prowlarr, with when a search last used them; and when
        # a source last failed to connect so. All in memory: a restart forgets
        # them, and the engine starts with every source disconnected anyway.
        self._sent: list[float] = []
        self._connected_for_us: dict[str, float] = {}
        self._connect_failed: dict[str, float] = {}
        self._idle_task: asyncio.Task[None] | None = None

    def services(self) -> Any:
        current = self._services()
        if current is None or current.multi is None:
            raise Refusal("the DCCAtlas engine is not running yet; try again in a moment")
        return current

    def note(self, text: str) -> None:
        if self._log is not None:
            self._log.add("web", text)

    # -- Newznab ---------------------------------------------------------------

    def caps(self) -> bytes:
        caps = ET.Element("caps")
        ET.SubElement(caps, "server", {"version": "1.0", "title": "DCCAtlas",
                                       "strapline": "File servers on IRC"})
        ET.SubElement(caps, "limits", {"max": str(FEED_LIMIT), "default": str(FEED_LIMIT)})
        searching = ET.SubElement(caps, "searching")
        for kind, params in (("search", "q"), ("tv-search", "q,season,ep"),
                             ("movie-search", "q"), ("audio-search", "q,artist,album"),
                             ("book-search", "q,author,title")):
            ET.SubElement(searching, kind, {"available": "yes", "supportedParams": params})
        categories = ET.SubElement(caps, "categories")
        tops: dict[int, ET.Element] = {}
        for number, name in sorted(cats.CATEGORIES.items()):
            top = cats.parent(number)
            if top not in tops:
                tops[top] = ET.SubElement(categories, "category", {
                    "id": str(top), "name": cats.CATEGORIES.get(top, name.split("/")[0])})
            if number != top:
                ET.SubElement(tops[top], "subcat", {"id": str(number), "name": name})
        return ET.tostring(caps, encoding="utf-8", xml_declaration=True)

    @staticmethod
    def error(message: str, code: int = 900) -> bytes:
        element = ET.Element("error", {"code": str(code), "description": _xml_text(message, 400)})
        return ET.tostring(element, encoding="utf-8", xml_declaration=True)

    async def feed(self, *, terms: str, categories: set[int] | None, offset: int,
                   limit: int, base_url: str) -> bytes:
        if categories is not None and not categories:
            return self._feed([], 0, offset, base_url)
        if not terms.strip():
            items, notes = await self._recent()
        else:
            items, notes = await self._search(terms, categories)
        before = len(items)
        items = [item for item in items if _fits(item["category"], categories)]
        if terms.strip() and len(items) < before:
            self.note(f"Prowlarr: {before - len(items)} of those rows left out, not in the "
                      "categories asked for")
        if terms.strip():
            # Only files go to the apps (2026-10-29): a note such as "the
            # search bot sent no result list" is kept in the Log instead, as
            # a row the apps would show, and try, as a release.
            for note in notes:
                self.note("Prowlarr: " + note["title"].removeprefix("[DCCAtlas] "))
            notes = []
        elif not items:
            # The one note sent as a row, to a search with no words: the Test
            # of Prowlarr, and of Readarr in the categories it asks for, fails
            # an answer with no releases ("Query successful, but no results
            # ... were returned", TestConnection in HttpIndexerBase.cs).
            notes = [self._note(
                "[DCCAtlas] Ready. Search by name to look on IRC; this is a note, not a file.",
                "ready", time.time())]
        for note in notes:   # shown under a category Prowlarr asked for
            note["category"] = min(categories) if categories else cats.DEFAULT
        shown = items[offset:offset + limit]
        if offset and terms.strip():
            # Prowlarr's More asks for the next 100 (SearchFooter.js).
            self.note(f"Prowlarr: “{terms.strip()}” page from row {offset + 1}: "
                      + (f"{len(shown)} row{'' if len(shown) == 1 else 's'}" if shown
                         else "none left"))
        if offset == 0:
            shown = notes + shown
        return self._feed(shown, len(items) + (len(notes) if offset == 0 else 0),
                          offset, base_url)

    async def _places(self, services: Any, asked: set[int] | None
                      ) -> tuple[list[str], list[str], list[str]]:
        """The ready sources and the stored lists a search of these categories
        reaches, and the sources of them that are not connected."""
        status = await services.sources.engine.status()
        ready, idle = [], []
        for config in services.sources.store.list():
            if asked is None or not cats.reaches(config.category, asked):
                continue
            live = SourceService.engine_source(status, config.source_id)
            if live and live.get("state") == "ready" and SourceService._matches(live, config):
                ready.append(config.source_id)
            elif not live or live.get("state") in ("configured", "disconnected", "failed"):
                idle.append(config.source_id)
        list_keys: list[str] = []
        if services.manifests is not None:
            try:
                listed = (await services.manifests.lists())["lists"]
            except Exception:
                listed = []
            for item in listed:
                if not (isinstance(item.get("route_key"), str)
                        and item.get("source_label") is not None):
                    continue
                config = services.sources.store.get(item.get("source_id") or "")
                if asked is None or (config is not None and cats.reaches(config.category, asked)):
                    list_keys.append(item["route_key"])
        return (ready[:MAX_SOURCES_PER_SEARCH], list_keys[:MAX_LISTS_PER_SEARCH],
                idle[:MAX_SOURCES_PER_SEARCH])

    @staticmethod
    def _reusable(multi: Any, terms: str, sources: set[str], lists: set[str]) -> str | None:
        """A combined search for the same words, recent enough to answer from,
        that already covered every place this one would reach: answering from
        it sends nothing, and the rows are sorted by category afterwards."""
        now = time.time()
        for group_id in multi.store.recent(30):
            summary = multi.summary(group_id)
            members = summary["members"]
            covered_sources = {member.get("source_id") for member in members
                               if member.get("kind") == "source"}
            covered_lists = {member.get("route_key") for member in members
                             if member.get("kind") == "list"}
            if (_words(summary["terms"]) == _words(terms)
                    and sources <= covered_sources and lists <= covered_lists
                    and summary["state"] != "interrupted"
                    and now - summary["started_at"] < REUSE_SECONDS):
                return group_id
        return None

    def _sent_this_hour(self) -> int:
        cutoff = _clock() - 3600
        self._sent = [when for when in self._sent if when > cutoff]
        return len(self._sent)

    async def _connect_for_search(self, services: Any, idle: list[str]) -> list[str]:
        """Connect these sources and wait until they are ready; the ones now ready."""
        now = _clock()
        started = []
        for source_id in idle:
            if now - self._connect_failed.get(source_id, -CONNECT_RETRY_SECONDS) \
                    < CONNECT_RETRY_SECONDS:
                continue
            try:
                await services.sources.connect(source_id)
            except Exception as exc:   # refused, or the engine did not answer
                self._connect_failed[source_id] = now
                self.note(f"Prowlarr: could not connect {self._label(services, source_id)}: "
                          f"{getattr(exc, 'message', exc)}")
                continue
            started.append(source_id)
            self._connected_for_us[source_id] = now
            self.note(f"Prowlarr: connecting {self._label(services, source_id)} for a search; "
                      "it is disconnected again when no search has used it for a while")
        ready: list[str] = []
        deadline = time.monotonic() + CONNECT_WAIT_SECONDS
        while started and time.monotonic() < deadline:
            status = await services.sources.engine.status()
            for source_id in list(started):
                live = SourceService.engine_source(status, source_id)
                state = live.get("state") if live else None
                if state == "ready":
                    ready.append(source_id)
                    started.remove(source_id)
                elif state in ("failed", "disconnected"):
                    self._connect_failed[source_id] = _clock()
                    self._connected_for_us.pop(source_id, None)
                    started.remove(source_id)
            if started:
                await asyncio.sleep(POLL_SECONDS)
        for source_id in started:   # not ready in time: tried again next search
            self._connect_failed[source_id] = _clock()
        self._watch_idle()
        return ready

    @staticmethod
    def _label(services: Any, source_id: str) -> str:
        config = services.sources.store.get(source_id)
        return config.label if config is not None else source_id

    def _watch_idle(self) -> None:
        if self._connected_for_us and (self._idle_task is None or self._idle_task.done()):
            self._idle_task = asyncio.get_running_loop().create_task(self._disconnect_idle())

    def _busy(self, services: Any, source_id: str) -> bool:
        """Whether a download, or a queued one, still needs the source's connection."""
        for row in services.downloads.store.active():
            if row.get("source_id") == source_id:
                return True
        queue = getattr(services, "queue", None)
        if queue is not None:
            for item in queue.store.items():
                if item.get("source_id") == source_id and item.get("state") in ("queued",
                                                                               "running"):
                    return True
        return False

    async def _disconnect_idle(self) -> None:
        """Disconnect each source connected for Prowlarr once no search has used
        it for the idle time, unless a download still needs it."""
        while self._connected_for_us:
            await asyncio.sleep(IDLE_CHECK_SECONDS)
            current = self._services()
            if current is None:
                continue
            idle_after = self.access.view()["idle_minutes"] * 60
            now = _clock()
            for source_id, used in list(self._connected_for_us.items()):
                if now - used < idle_after or self._busy(current, source_id):
                    continue
                self._connected_for_us.pop(source_id, None)
                try:
                    await current.sources.disconnect(source_id)
                    self.note(f"Prowlarr: disconnected {self._label(current, source_id)}, "
                              "unused for a while")
                except Exception as exc:
                    self.note(f"Prowlarr: could not disconnect "
                              f"{self._label(current, source_id)}: "
                              f"{getattr(exc, 'message', exc)}")

    def used(self, source_ids: list[str]) -> None:
        """A search used these sources: one connected for Prowlarr stays a while longer."""
        now = _clock()
        for source_id in source_ids:
            if source_id in self._connected_for_us:
                self._connected_for_us[source_id] = now

    def forget_manual(self, source_id: str) -> None:
        """The owner connected or disconnected it: it is no longer ours to disconnect."""
        self._connected_for_us.pop(source_id, None)

    async def _search(self, terms: str, asked: set[int] | None
                      ) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        try:
            terms = validate_terms(terms)
        except SearchError as exc:
            raise Refusal(f"DCCAtlas cannot search for that: {exc.message}", 201) from exc
        services = self.services()
        multi = services.multi
        when = time.time()
        async with self._search_lock:
            settings = self.access.view()
            source_ids, list_keys, idle = await self._places(services, asked)
            if not settings["connect_sources"]:
                idle = []
            if settings["lists_only"]:
                source_ids, idle = [], []
            group_id = self._reusable(multi, terms, {*source_ids, *idle}, set(list_keys))
            reused = group_id is not None
            if group_id is None:
                if (source_ids or idle) \
                        and self._sent_this_hour() >= settings["searches_per_hour"]:
                    self.note(f"Prowlarr searched for “{terms}”; nothing was sent: "
                              f"{settings['searches_per_hour']} searches an hour have reached "
                              "IRC already, so Prowlarr is told the limit is reached")
                    raise Refusal(LIMIT_REACHED, 500)
                if idle:
                    source_ids += await self._connect_for_search(services, idle)
                    source_ids = source_ids[:MAX_SOURCES_PER_SEARCH]
                if not source_ids and not list_keys:
                    why = ("only stored file lists are searched (set under Apps), and none "
                           "is stored for the categories asked for; nothing was sent"
                           if settings["lists_only"] else
                           "Prowlarr asked for no category, so no source was searched; "
                           "choose a category to search IRC" if asked is None else
                           "no source of the categories asked for is connected"
                           + ("" if settings["connect_sources"] else
                              ", and connecting sources for Prowlarr is turned off")
                           + "; nothing was sent")
                    return [], [self._note(f"[DCCAtlas] {why[0].upper()}{why[1:]}.",
                                           f"none-{terms}", when)]
                try:
                    started = await multi.start(terms, source_ids, list_keys)
                except SearchError as exc:
                    if exc.code == "search_active":
                        running = [multi.summary(group) for group in multi.store.running()]
                        what = f" for “{running[0]['terms']}”" if running else ""
                        return [], [self._note(
                            f"[DCCAtlas] Busy with another search{what}; nothing was sent. "
                            "Search again in a minute.", f"busy-{terms}", when)]
                    raise Refusal(f"DCCAtlas could not search: {exc.message}") from exc
                group_id = started["group_id"]
                if source_ids:
                    self._sent.append(_clock())
                self.used(source_ids)
                self.note(f"Prowlarr searched for “{terms}”")
            else:
                self.used([member["source_id"] for member in multi.summary(group_id)["members"]
                           if member.get("kind") == "source" and member.get("source_id")])
        deadline = time.monotonic() + ANSWER_SECONDS
        summary = await multi.status(group_id)
        while summary["state"] == "running" and time.monotonic() < deadline:
            await asyncio.sleep(POLL_SECONDS)
            summary = await multi.status(group_id)
        items = await self._rows(multi, group_id, summary)
        seen = self._seen
        member_states = ", ".join(f"{member['label']} {member['state']}"
                                  for member in summary["members"])
        self.note(f"Prowlarr: “{terms}” answered "
                  f"{'from the search already made' if reused else 'from this search'} "
                  f"({summary['state']}; {member_states}): {len(items)} of "
                  f"{seen['result_count']} rows offered"
                  + (f", {seen['not_downloadable']} not downloadable yet"
                     if seen["not_downloadable"] else "")
                  + (f"; reading its rows failed: {seen['page_error']}"
                     if seen["page_error"] else ""))
        notes = []
        if summary["state"] == "running":
            answered = sum(1 for member in summary["members"]
                           if member["state"] not in ("waiting", "collecting",
                                                      "dispatch_pending", "dispatching"))
            notes.append(self._note(
                f"[DCCAtlas] Still searching: {answered} of {len(summary['members'])} places "
                "have answered. Search again in a minute for the rest; nothing is sent again.",
                group_id, summary["started_at"]))
        else:
            for member in summary["members"]:
                # A place that found nothing says why; one that found rows
                # needs no note beside them.
                if (member.get("note") and member["kind"] == "source"
                        and not member.get("result_count")):
                    notes.append(self._note(f"[DCCAtlas] {member['label']}: {member['note']}",
                                            f"{group_id}-{member['position']}",
                                            summary["started_at"]))
        return items, notes

    async def _recent(self) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        """Rows of the last few searches; sends nothing."""
        services = self.services()
        multi = services.multi
        items: list[dict[str, Any]] = []
        for group_id in multi.store.recent(RECENT_GROUPS):
            summary = await multi.status(group_id)
            items.extend(await self._rows(multi, group_id, summary))
            if len(items) >= FEED_LIMIT:
                break
        return items, []

    async def _rows(self, multi: Any, group_id: str,
                    summary: dict[str, Any]) -> list[dict[str, Any]]:
        services = self.services()
        total = min(summary["result_count"], MAX_FEED_ROWS)
        items: list[dict[str, Any]] = []
        # What this answer saw, for the log line that says what Prowlarr got.
        self._seen = {"rows": 0, "not_downloadable": 0, "page_error": None,
                      "result_count": summary["result_count"]}
        offset = 0
        while offset < total:
            for attempt in range(5):
                try:
                    page = await multi.page(group_id, offset=offset,
                                            limit=min(MAX_PAGE_SIZE, total - offset))
                    break
                except SearchError as exc:
                    if exc.code != "poll_too_fast" or attempt == 4:
                        self._seen["page_error"] = f"{exc.code}: {exc.message}"
                        return items
                    await asyncio.sleep(MIN_PAGE_INTERVAL * 1.5)
            rows = page["results"]
            if not rows:
                break
            for row in rows:
                self._seen["rows"] += 1
                result_id = row.get("result_id")
                if not (row.get("selection_available") and isinstance(result_id, str)
                        and _RESULT_ID.fullmatch(result_id)):
                    self._seen["not_downloadable"] += 1
                    continue
                path = _xml_text(row.get("path"), 4096)
                title = PurePosixPath(path).name or path
                config = services.sources.store.get(row.get("source_id") or "")
                size = row.get("size_bytes_exact") or row.get("size_bytes_estimate") or 0
                items.append({
                    "result_id": result_id, "title": title,
                    "category": cats.of_file(title, config.category if config is not None
                                             else cats.DEFAULT),
                    "size": size if isinstance(size, int) and size >= 0 else 0,
                    "published": summary["started_at"],
                    "description": _xml_text(
                        f"{path} from {row.get('sender')} ({row.get('trigger')}) "
                        f"on {row.get('source_label')}", 1024),
                })
            offset += len(rows)
            await asyncio.sleep(MIN_PAGE_INTERVAL * 1.2)
        return items

    @staticmethod
    def _note(text: str, key: str, published: float) -> dict[str, Any]:
        return {"result_id": "note-" + hashlib.sha256(key.encode()).hexdigest()[:16],
                "title": _xml_text(text, 400), "category": cats.DEFAULT, "size": 0,
                "published": published, "description": _xml_text(text, 400)}

    def link(self, base_url: str, result_id: str, title: str) -> str:
        query = urlencode({"t": "get", "id": result_id, "name": title,
                           "sig": self.sign_or_note(result_id, title)})
        return f"{base_url.rstrip('/')}/newznab/api?{query}"

    def sign_or_note(self, result_id: str, title: str) -> str:
        return "" if result_id.startswith("note-") else self.access.sign(result_id, title)

    def _feed(self, items: list[dict[str, Any]], total: int, offset: int,
              base_url: str) -> bytes:
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "DCCAtlas"
        ET.SubElement(channel, "description").text = "File servers on IRC, through DCCAtlas"
        ET.SubElement(channel, f"{{{NEWZNAB}}}response",
                      {"offset": str(offset), "total": str(total)})
        for item in items:
            entry = ET.SubElement(channel, "item")
            ET.SubElement(entry, "title").text = item["title"]
            ET.SubElement(entry, "guid", {"isPermaLink": "false"}).text = \
                "dccatlas-" + item["result_id"]
            url = self.link(base_url, item["result_id"], item["title"])
            ET.SubElement(entry, "link").text = url
            ET.SubElement(entry, "pubDate").text = format_datetime(
                datetime.fromtimestamp(item["published"], timezone.utc))
            ET.SubElement(entry, "category").text = cats.CATEGORIES.get(
                item["category"], cats.CATEGORIES.get(cats.parent(item["category"]), "Other"))
            ET.SubElement(entry, "description").text = item["description"]
            ET.SubElement(entry, "enclosure", {"url": url, "length": str(item["size"]),
                                               "type": "application/x-nzb"})
            for name, value in (("category", item["category"]), ("size", item["size"])):
                ET.SubElement(entry, f"{{{NEWZNAB}}}attr", {"name": name, "value": str(value)})
        return ET.tostring(rss, encoding="utf-8", xml_declaration=True)

    def nzb(self, result_id: Any, title: Any, signature: Any) -> bytes:
        """The small file Prowlarr hands to its download client: which row, signed."""
        if isinstance(result_id, str) and result_id.startswith("note-"):
            raise Refusal("this is a note from DCCAtlas, not a file", 300)
        if not (isinstance(result_id, str) and _RESULT_ID.fullmatch(result_id)
                and isinstance(title, str) and self.access.signed(result_id, title, signature)):
            raise Refusal("this link was not made by DCCAtlas, or its key has changed since; "
                          "search again", 300)
        name = escape(_xml_text(title, 4096))
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<nzb xmlns="{NZB}">\n'
            f' <head>\n  <meta type="name">{name}</meta>\n'
            f'  <meta type="dccatlas-result">{result_id}</meta>\n'
            f'  <meta type="dccatlas-sig">{signature}</meta>\n </head>\n'
            f' <file poster="DCCAtlas" date="{int(time.time())}" subject={quoteattr(name)}>\n'
            '  <groups><group>dccatlas</group></groups>\n'
            f'  <segments><segment bytes="0" number="1">{result_id}@dccatlas</segment></segments>\n'
            ' </file>\n</nzb>\n').encode("utf-8")

    # -- SABnzbd ---------------------------------------------------------------

    @staticmethod
    def from_nzb(data: bytes) -> tuple[str, str, str]:
        try:
            root = ET.fromstring(data)
        except ET.ParseError as exc:
            raise Refusal("that is not an NZB file from DCCAtlas") from exc
        meta = {element.get("type"): element.text or ""
                for element in root.iter() if element.tag.endswith("}meta")
                or element.tag == "meta"}
        return (meta.get("dccatlas-result", ""), meta.get("name", ""),
                meta.get("dccatlas-sig", ""))

    @staticmethod
    def nzb_from_form(content_type: str, body: bytes) -> bytes:
        """The uploaded file of a multipart form, read with the standard library."""
        message = BytesParser(policy=policy.HTTP).parsebytes(
            b"Content-Type: " + content_type.encode("latin-1", "replace") + b"\r\n\r\n" + body)
        if message.is_multipart():
            for part in message.iter_parts():
                if part.get_param("name", header="content-disposition") in ("name", "nzbfile"):
                    payload = part.get_payload(decode=True)
                    if isinstance(payload, bytes):
                        return payload
        raise Refusal("no NZB file was sent")

    def from_link(self, url: Any) -> tuple[str, str, str]:
        """The row an NZB link of this app names. Nothing is fetched."""
        if not isinstance(url, str):
            raise Refusal("no NZB link was sent")
        parts = urlsplit(url)
        if not parts.path.endswith("/newznab/api"):
            raise Refusal("DCCAtlas takes only its own links")
        query = parse_qs(parts.query)
        first = lambda name: (query.get(name) or [""])[0]
        if first("t") != "get":
            raise Refusal("DCCAtlas takes only its own links")
        return first("id"), first("name"), first("sig")

    async def add(self, result_id: str, title: str, signature: str,
                  category: Any) -> dict[str, Any]:
        """Start the download of a release Prowlarr handed over, once."""
        if result_id.startswith("note-"):
            raise Refusal("that release is a note from DCCAtlas, not a file")
        if not (_RESULT_ID.fullmatch(result_id) and self.access.signed(result_id, title, signature)):
            raise Refusal("that release was not found by DCCAtlas, or its key has changed "
                          "since; search again")
        services = self.services()
        async with self._grab_lock:
            prior = self.grabs.latest_for(result_id)
            if prior is not None:
                row = services.downloads.store.get(prior["operation_id"])
                if row is not None and row["state"] not in _TERMINAL:
                    return {"status": True, "nzo_ids": [prior["nzo_id"]]}
            try:
                started = await services.downloads.download(
                    "prowlarr-" + uuid.uuid4().hex, result_id)
            except DownloadError as exc:
                self.note(f"Prowlarr sent “{title}”; it was not started: {exc.message}")
                raise Refusal(f"DCCAtlas did not start it: {exc.message}") from exc
            nzo_id = "SABnzbd_nzo_" + uuid.uuid4().hex[:16]
            self.grabs.add(nzo_id, result_id, started["operation_id"], title,
                           category if isinstance(category, str) and category else "*")
        self.note(f"Prowlarr sent “{title}” to download")
        return {"status": True, "nzo_ids": [nzo_id]}

    @staticmethod
    def config() -> dict[str, Any]:
        categories = [{"name": name, "order": order, "pp": "", "script": "None",
                       "dir": "", "newzbin": "", "priority": 0}
                      # Each app's own category, so that any of them may name
                      # one; with category folders on, it names the folder.
                      for order, name in enumerate((
                          "*", "prowlarr", "books", "readarr", "bindery", "audiobooks",
                          "tv", "sonarr", "movies", "radarr", "music", "lidarr",
                          "software", "games", "other"))]
        return {"config": {
            "misc": {"complete_dir": DOWNLOAD_DIR, "download_dir": DOWNLOAD_DIR,
                     "pre_check": False, "enable_tv_sorting": False,
                     "enable_movie_sorting": False, "enable_date_sorting": False,
                     "tv_categories": [], "movie_categories": [], "date_categories": [],
                     "history_retention": "", "history_retention_option": "all",
                     "history_retention_number": 0},
            "categories": categories, "servers": [], "sorters": []}}

    async def _jobs(self) -> list[tuple[dict[str, Any], dict[str, Any] | None]]:
        services = self.services()
        jobs = []
        for grab in self.grabs.shown():
            row = services.downloads.store.get(grab["operation_id"])
            if row is not None and row["state"] not in _TERMINAL:
                try:
                    row = await services.downloads.status(grab["operation_id"])
                except DownloadError:
                    pass
            jobs.append((grab, row))
        return jobs

    @staticmethod
    def _megabytes(count: Any) -> str:
        return f"{(count or 0) / 1048576:.2f}"

    async def queue(self) -> dict[str, Any]:
        slots = []
        for grab, row in await self._jobs():
            if row is None or row["state"] in _TERMINAL:
                continue
            total, got = row.get("total_bytes") or 0, row.get("bytes_received") or 0
            slots.append({
                "index": len(slots), "nzo_id": grab["nzo_id"], "filename": grab["title"],
                "cat": grab["category"], "priority": "Normal",
                "status": "Downloading" if row["state"] == "receiving" else "Queued",
                "mb": self._megabytes(total), "mbleft": self._megabytes(max(total - got, 0)),
                "percentage": str(int(got * 100 / total)) if total else "0",
                "timeleft": "0:00:00",
            })
        return {"queue": {"status": "Downloading" if slots else "Idle", "paused": False,
                          "speed": "0", "kbpersec": "0.00", "my_home": DOWNLOAD_DIR,
                          "noofslots": len(slots), "noofslots_total": len(slots),
                          "slots": slots}}

    def _file_for(self, grab: dict[str, Any], row: dict[str, Any]) -> str:
        """Where a finished grab's file is, relative to the downloads folder; with
        category folders on, moved into its category's folder first, as SABnzbd
        moves a finished job."""
        if grab.get("moved_to"):
            return grab["moved_to"]
        relative = row["download_path"]
        folder = grab["category"]
        if (not self.access.view()["category_folders"] or folder in ("", "*")
                or not _FOLDER.fullmatch(folder) or folder.endswith((".", " "))):
            return relative
        root = Path(DOWNLOAD_DIR)
        source = root / relative
        if not source.is_file() or source.is_symlink():
            return relative
        target_dir = root / folder
        try:
            target_dir.mkdir(exist_ok=True)
            if target_dir.is_symlink() or not target_dir.is_dir():
                return relative
            target = target_dir / source.name
            stem, suffix, number = source.stem, source.suffix, 1
            while target.exists() or target.is_symlink():
                target = target_dir / f"{stem}-{number}{suffix}"
                number += 1
            try:
                os.link(source, target)   # never replaces a file already there
            except OSError:
                # A network share may refuse hard links: copy into a name that
                # must not exist yet, as the engine does when it publishes.
                created = False
                try:
                    with open(source, "rb") as reader, \
                            open(target, "xb") as writer:   # "x": never replaces either
                        created = True
                        shutil.copyfileobj(reader, writer, 1 << 20)
                    shutil.copystat(source, target)
                except OSError:
                    if created:   # a part copy of ours is not left behind
                        target.unlink(missing_ok=True)
                    raise
            source.unlink()
        except OSError as exc:
            self.note(f"Prowlarr: “{source.name}” could not be moved into {folder}: {exc}")
            return relative
        moved = target.relative_to(root).as_posix()
        self.grabs.moved(grab["nzo_id"], moved)
        self.note(f"Prowlarr: “{source.name}” moved into the {folder} folder")
        return moved

    async def history(self) -> dict[str, Any]:
        slots = []
        for grab, row in reversed(await self._jobs()):
            if row is None or row["state"] not in _TERMINAL:
                continue
            done = row["state"] == "complete" and row.get("download_path")
            storage = (str(PurePosixPath(DOWNLOAD_DIR) / self._file_for(grab, row))
                       if done else "")
            slots.append({
                "nzo_id": grab["nzo_id"], "name": grab["title"],
                "nzb_name": grab["title"] + ".nzb", "category": grab["category"],
                "status": "Completed" if done else "Failed",
                "fail_message": "" if done else (row.get("reason") or row.get("outcome")
                                                 or row["state"]),
                "storage": storage, "path": storage,
                "bytes": row.get("total_bytes") or 0,
                "download_time": int((row.get("updated_at") or 0) - (row.get("created_at") or 0)),
                "completed": int(row.get("updated_at") or 0),
            })
        return {"history": {"noofslots": len(slots), "slots": slots, "total_size": "0",
                            "month_size": "0", "week_size": "0", "day_size": "0"}}

    async def remove(self, nzo_id: Any, *, from_queue: bool) -> dict[str, Any]:
        """Forget a job; a file still on its way is cancelled first, as Cancel does."""
        if not (isinstance(nzo_id, str) and _NZO_ID.fullmatch(nzo_id)):
            raise Refusal("there is no such job")
        grab = self.grabs.get(nzo_id)
        if grab is None:
            raise Refusal("there is no such job")
        if from_queue:
            services = self.services()
            row = services.downloads.store.get(grab["operation_id"])
            if row is not None and row["state"] not in _TERMINAL:
                try:
                    await services.downloads.cancel(grab["operation_id"])
                except DownloadError as exc:
                    raise Refusal(f"DCCAtlas could not cancel it: {exc.message}") from exc
        self.grabs.hide(nzo_id)
        return {"status": True, "nzo_ids": [nzo_id]}
