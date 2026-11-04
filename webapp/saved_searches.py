"""Saved searches (2026-10-21).

The operator saves a search's terms and the places it looked, and later runs
it again with one press. Nothing here sends anything: the page puts the saved
terms and places back in the search form and submits it, so a saved search
goes through exactly the same checks and pacing as one typed by hand. A
saved search never runs by itself.
"""

from __future__ import annotations

from contextlib import closing, contextmanager
import json
import os
from pathlib import Path
import re
import sqlite3
import time
import uuid
from typing import Any, Iterator

from .multisearch import MAX_LISTS_PER_SEARCH, MAX_SOURCES_PER_SEARCH
from .searches import SearchError, validate_terms
from .sources import SourceService


MAX_SAVED = 50
_SAVED_ID = re.compile(r"saved-[0-9a-f]{32}")


def _places(value: Any, what: str, limit: int) -> list[str]:
    if value is None:
        return []
    if (not isinstance(value, list) or len(value) > limit or len(set(value)) != len(value)
            or not all(isinstance(item, str) and 0 < len(item) <= 200
                       and not any(ord(char) < 32 or ord(char) == 127 for char in item)
                       for item in value)):
        raise SearchError("invalid_request", f"choose at most {limit} {what}")
    return value


class SavedSearchStore:
    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if not self.path.exists() or not self.path.is_file() or self.path.is_symlink():
            raise ValueError("initialize the source store before the saved-search store")
        with self._transaction() as connection:
            connection.execute("""
                CREATE TABLE IF NOT EXISTS saved_search (
                    saved_id TEXT PRIMARY KEY,
                    terms TEXT NOT NULL,
                    source_ids TEXT NOT NULL,
                    list_keys TEXT NOT NULL,
                    saved_at REAL NOT NULL
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

    @staticmethod
    def _view(row: sqlite3.Row) -> dict[str, Any]:
        return {"saved_id": row["saved_id"], "terms": row["terms"],
                "source_ids": json.loads(row["source_ids"]),
                "list_keys": json.loads(row["list_keys"]), "saved_at": row["saved_at"]}

    def list(self) -> list[dict[str, Any]]:
        with closing(self._connect()) as connection:
            rows = connection.execute(
                "SELECT * FROM saved_search ORDER BY saved_at DESC, saved_id").fetchall()
        return [self._view(row) for row in rows]

    def save(self, terms: str, source_ids: list[str], list_keys: list[str]) -> dict[str, Any]:
        places = (json.dumps(sorted(source_ids)), json.dumps(sorted(list_keys)))
        with self._transaction() as connection:
            same = connection.execute(
                "SELECT * FROM saved_search WHERE terms=? AND source_ids=? AND list_keys=?",
                (terms, *places)).fetchone()
            if same is not None:
                return self._view(same)
            count = connection.execute("SELECT COUNT(*) FROM saved_search").fetchone()[0]
            if count >= MAX_SAVED:
                raise SearchError("too_many_saved",
                                  f"at most {MAX_SAVED} searches can be saved; remove one first")
            saved_id = "saved-" + uuid.uuid4().hex
            connection.execute(
                "INSERT INTO saved_search (saved_id, terms, source_ids, list_keys, saved_at) "
                "VALUES (?, ?, ?, ?, ?)", (saved_id, terms, *places, time.time()))
            row = connection.execute(
                "SELECT * FROM saved_search WHERE saved_id=?", (saved_id,)).fetchone()
        return self._view(row)

    def remove(self, saved_id: str) -> bool:
        with self._transaction() as connection:
            return connection.execute(
                "DELETE FROM saved_search WHERE saved_id=?", (saved_id,)).rowcount > 0


class SavedSearchService:
    def __init__(self, sources: SourceService) -> None:
        self.sources = sources
        self.store = SavedSearchStore(sources.store.path)

    def list(self) -> dict[str, Any]:
        return {"saved": self.store.list(), "limit": MAX_SAVED}

    def save(self, terms: Any, source_ids: Any, list_keys: Any) -> dict[str, Any]:
        terms = validate_terms(terms)
        source_ids = _places(source_ids, "sources", MAX_SOURCES_PER_SEARCH)
        list_keys = _places(list_keys, "file lists", MAX_LISTS_PER_SEARCH)
        if not source_ids and not list_keys:
            raise SearchError("invalid_request", "choose where the search looks")
        for source_id in source_ids:
            if self.sources.store.get(source_id) is None:
                raise SearchError("unknown_source", "no such source is configured")
        return self.store.save(terms, source_ids, list_keys)

    def remove(self, saved_id: Any) -> dict[str, Any]:
        if not isinstance(saved_id, str) or not _SAVED_ID.fullmatch(saved_id) \
                or not self.store.remove(saved_id):
            raise SearchError("unknown_saved", "no such saved search")
        return self.list()
