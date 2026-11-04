"""The operator's settings for downloads (2026-10-22), kept in the database.

- ``retry_before_request``: when a file server's session drops after it
  opened and before the file was asked for, the engine opens a fresh one by
  itself: at most twice, on the same connection, within two minutes. A
  request that may have been sent is never sent again by itself. On unless
  turned off.
- ``downloads_at_once``: 1 or 2. With 2, a file server's file may start
  while another file server's file is already being received; never two from
  one file server, and searches, browses and search bots' files still wait
  for every transfer to end. The engine's spacing and its one request per
  file server and file name on a connection apply as always.
"""

from __future__ import annotations

from contextlib import closing, contextmanager
import json
import os
from pathlib import Path
import sqlite3
from typing import Any, Iterator

from .errors import ServiceError


DEFAULTS: dict[str, Any] = {"retry_before_request": True, "downloads_at_once": 2}


class SettingsError(ServiceError):
    pass


class SettingsStore:
    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if not self.path.exists() or not self.path.is_file() or self.path.is_symlink():
            raise ValueError("initialize the source store before the settings store")
        with self._transaction() as connection:
            connection.execute("""
                CREATE TABLE IF NOT EXISTS web_setting (
                    name TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
            """)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
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

    def all(self) -> dict[str, Any]:
        with closing(self._connect()) as connection:
            rows = connection.execute("SELECT name, value FROM web_setting").fetchall()
        values = dict(DEFAULTS)
        for name, value in rows:
            if name in DEFAULTS:
                try:
                    values[name] = json.loads(value)
                except ValueError:
                    pass
        return values

    def value(self, name: str) -> Any:
        """One stored value that is not a download setting, or None."""
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT value FROM web_setting WHERE name=?", (name,)).fetchone()
        if row is None:
            return None
        try:
            return json.loads(row[0])
        except ValueError:
            return None

    def put(self, changes: dict[str, Any]) -> None:
        with self._transaction() as connection:
            for name, value in changes.items():
                connection.execute(
                    "INSERT INTO web_setting (name, value) VALUES (?, ?) "
                    "ON CONFLICT (name) DO UPDATE SET value = excluded.value",
                    (name, json.dumps(value)))


class DownloadSettings:
    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.store = SettingsStore(database)

    def view(self) -> dict[str, Any]:
        return self.store.all()

    def get(self, name: str) -> Any:
        return self.store.all()[name]

    def update(self, changes: Any) -> dict[str, Any]:
        if not isinstance(changes, dict) or not changes:
            raise SettingsError("invalid_settings", "name the settings to change")
        for name, value in changes.items():
            if name not in DEFAULTS:
                raise SettingsError("invalid_settings", f"there is no setting {name!r}")
            if name == "retry_before_request" and not isinstance(value, bool):
                raise SettingsError("invalid_settings", "retry_before_request is true or false")
            if name == "downloads_at_once" and (type(value) is not int or value not in (1, 2)):
                raise SettingsError("invalid_settings", "downloads_at_once is 1 or 2")
        self.store.put(changes)
        return self.view()
