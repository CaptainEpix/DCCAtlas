"""Persistent source configuration and typed engine lifecycle calls."""

from __future__ import annotations

import asyncio
from contextlib import closing
import ipaddress
import os
import re
import sqlite3
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .categories import CATEGORIES, DEFAULT as DEFAULT_CATEGORY, valid as category_valid
from .engine_client import EngineRequestError
from .ids import SOURCE_ID_PATTERN


SOURCE_ID = "primary"
PROVIDER = "sysreset_find"      # file servers answering "@find" in the channel
SEARCHBOT = "searchbot"         # one search bot answering "@search" with a result list
PROVIDERS = (PROVIDER, SEARCHBOT)
SCHEMA_VERSION = 4
MAX_SOURCES = 8   # the engine bridge enforces the same limit


class SourceValidationError(ValueError):
    """A source configuration value is malformed or outside the supported scope."""


class UnknownSource(SourceValidationError):
    """The named source is not configured."""


class SourceApplyPending(RuntimeError):
    """Saved settings could not be confirmed in the current engine process."""


@dataclass(frozen=True)
class SourceConfig:
    source_id: str
    revision: int
    label: str
    provider: str
    host: str
    port: int
    tls: bool
    nickname: str
    channel: str
    updated_at: float
    search_bot: str = ""    # the search bot's nickname; only a search-bot source has one
    # What it holds, as a Newznab category (webapp/categories.py); only a
    # search from Prowlarr reads it, so the engine is not told.
    category: int = DEFAULT_CATEGORY

    def public(self) -> dict[str, Any]:
        return {**self.engine_arguments(), "search_bot": self.search_bot,
                "category": self.category, "updated_at": self.updated_at}

    def engine_arguments(self) -> dict[str, Any]:
        arguments = {
            "source_id": self.source_id,
            "revision": self.revision,
            "label": self.label,
            "provider": self.provider,
            "host": self.host,
            "port": self.port,
            "tls": self.tls,
            "nickname": self.nickname,
            "channel": self.channel,
        }
        if self.provider == SEARCHBOT:
            arguments["search_bot"] = self.search_bot
        return arguments


# Loopback, the RFC 1918 and RFC 4193 private ranges, and link-local. Named
# here rather than taken from ``is_private``, which also counts ranges that
# are reached over the Internet, such as Teredo (2001::/32) and NAT64.
_LOCAL_NETWORKS = tuple(ipaddress.ip_network(network) for network in (
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
    "::1/128", "fc00::/7", "fe80::/10",
))


def is_local_server(host: str) -> bool:
    """True for a loopback or private-network address: a lab or test server.

    Only an address says so. A host name is taken to be a public server,
    whatever it resolves to, except ``localhost``.
    """
    if host == "localhost" or host.endswith(".localhost"):
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    return any(address in network for network in _LOCAL_NETWORKS)


def channel_key(channel: str) -> str:
    """A channel name as IRC compares it, ignoring letter case."""
    # IRC's own case mapping also treats [ ] \ ~ as the lower case of { } | ^.
    return channel.lower().translate(str.maketrans("[]\\~", "{}|^"))


def validate_source(values: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(values, dict):
        raise SourceValidationError("source configuration must be an object")
    allowed = {"label", "provider", "host", "port", "tls", "nickname", "channel"}
    if set(values) - {"search_bot", "category"} != allowed:
        raise SourceValidationError("source configuration must contain exactly the supported fields")

    label = values["label"]
    if (not isinstance(label, str) or not label or len(label) > 80
            or any(ord(char) < 32 or ord(char) == 127 for char in label)):
        raise SourceValidationError("label must be 1 to 80 printable characters")

    provider = values["provider"]
    if provider not in PROVIDERS:
        raise SourceValidationError("provider must be one of " + ", ".join(PROVIDERS))

    raw_host = values["host"]
    if not isinstance(raw_host, str) or not raw_host or raw_host != raw_host.strip():
        raise SourceValidationError("host must be a nonempty hostname or IP address")
    if any(ord(char) < 33 or ord(char) == 127 for char in raw_host):
        raise SourceValidationError("host contains whitespace or a control character")
    try:
        address = ipaddress.ip_address(raw_host)
        if getattr(address, "scope_id", None):
            raise ValueError("scoped IPv6 addresses are not supported")
        host = address.compressed
    except ValueError as ip_error:
        if ":" in raw_host or any(char in raw_host for char in "/@?#[]\\%"):
            raise SourceValidationError("host must be a hostname or an unscoped IP address") from ip_error
        try:
            host = raw_host.encode("idna").decode("ascii").lower()
        except UnicodeError as exc:
            raise SourceValidationError("host is not a valid IDNA hostname") from exc
        if len(host) > 253 or not host:
            raise SourceValidationError("hostname is too long")
        labels = host.split(".")
        if any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", item)
               for item in labels):
            raise SourceValidationError("host is not a valid hostname")

    port = values["port"]
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
        raise SourceValidationError("port must be an integer from 1 through 65535")

    tls = values["tls"]
    if not isinstance(tls, bool):
        raise SourceValidationError("tls must be true or false")

    nickname = values["nickname"]
    nick_pattern = r"[A-Za-z\[\]\\`_^{}|][A-Za-z0-9\-\[\]\\`_^{}|]{0,29}"
    if not isinstance(nickname, str) or not re.fullmatch(nick_pattern, nickname):
        raise SourceValidationError("nickname must be 1 to 30 valid IRC nickname characters")

    channel = values["channel"]
    if (not isinstance(channel, str) or len(channel) > 200
            or not re.fullmatch(r"[#&+!][^\s,\x00-\x1f\x7f]{0,199}", channel)):
        raise SourceValidationError("channel is not a valid IRC channel name")

    search_bot = values.get("search_bot", "")
    if provider == SEARCHBOT:
        if not isinstance(search_bot, str) or not re.fullmatch(nick_pattern, search_bot):
            raise SourceValidationError(
                "a search-bot source needs the nickname of the channel's search bot")
    elif search_bot not in ("", None):
        raise SourceValidationError("only a search-bot source has a search bot nickname")
    else:
        search_bot = ""

    # Every source has a category. Saved without one, a source keeps the one
    # it has, and a new one holds books, as every source did before.
    category = values.get("category")
    if category is not None and not category_valid(category):
        raise SourceValidationError(
            "category must be one of " + ", ".join(str(number) for number in CATEGORIES))

    return {
        "source_id": SOURCE_ID, "label": label, "provider": provider,
        "host": host, "port": port, "tls": tls, "nickname": nickname,
        "channel": channel, "search_bot": search_bot, "category": category,
    }


class SourceConfigStore:
    """SQLite storage for the configured sources, with transactional schema upgrades."""

    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if self.path.parent == Path(self.path.anchor):
            raise ValueError("source database must live in a dedicated config directory")
        if self.path.parent.is_symlink():
            raise ValueError("source config directory cannot be a symbolic link")
        new_directory = not self.path.parent.exists()
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.path.is_symlink():
            raise ValueError("source database path cannot be a symbolic link")
        if self.path.exists() and not self.path.is_file():
            raise ValueError("source database path must be a regular file")
        if os.name != "nt":
            if new_directory:
                os.chmod(self.path.parent, 0o700)
            elif self.path.parent.stat().st_mode & 0o077:
                raise ValueError("source config directory permissions must be owner-only")
            if self.path.exists():
                if self.path.stat().st_nlink != 1:
                    raise ValueError("source database cannot have additional hard links")
                os.chmod(self.path, 0o600)
        self._migrate()
        if self.path.exists() and os.name != "nt":
            if self.path.stat().st_nlink != 1:
                raise ValueError("source database cannot have additional hard links")
            os.chmod(self.path, 0o600)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    def _migrate(self) -> None:
        with closing(self._connect()) as connection:
            # Read the version inside the exclusive transaction so two
            # processes starting together cannot both try to create the table.
            connection.execute("BEGIN EXCLUSIVE")
            try:
                version = connection.execute("PRAGMA user_version").fetchone()[0]
                if version > SCHEMA_VERSION:
                    raise RuntimeError("source database was created by a newer application")
                if version == 2:
                    # Version 2 allowed one kind of source. Version 3 adds
                    # the search-bot kind, so the table is rebuilt.
                    connection.execute("ALTER TABLE sources RENAME TO sources_v2")
                if version < 3:
                    connection.execute("""
                        CREATE TABLE sources (
                            source_id TEXT PRIMARY KEY,
                            revision INTEGER NOT NULL CHECK (revision > 0),
                            label TEXT NOT NULL,
                            provider TEXT NOT NULL
                                CHECK (provider IN ('sysreset_find', 'searchbot')),
                            host TEXT NOT NULL,
                            port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),
                            tls INTEGER NOT NULL CHECK (tls IN (0, 1)),
                            nickname TEXT NOT NULL,
                            channel TEXT NOT NULL,
                            created_at REAL NOT NULL,
                            updated_at REAL NOT NULL,
                            search_bot TEXT NOT NULL DEFAULT '',
                            category INTEGER NOT NULL DEFAULT 7000
                        )
                    """)
                elif version == 3:
                    # Version 4 gives each source a category; those saved
                    # before held books, as the app then did.
                    connection.execute(
                        "ALTER TABLE sources ADD COLUMN category INTEGER NOT NULL DEFAULT 7000")
                if version == 2:
                    connection.execute("""
                        INSERT INTO sources
                            (source_id, revision, label, provider, host, port, tls,
                             nickname, channel, created_at, updated_at)
                        SELECT source_id, revision, label, provider, host, port, tls,
                               nickname, channel, created_at, updated_at
                        FROM sources_v2
                    """)
                    connection.execute("DROP TABLE sources_v2")
                if version < 2:
                    # A removed source's last revision. The engine refuses a
                    # revision it has already seen for an ID, so an ID that
                    # comes back continues from here.
                    connection.execute("""
                        CREATE TABLE removed_sources (
                            source_id TEXT PRIMARY KEY,
                            last_revision INTEGER NOT NULL
                        )
                    """)
                if version == 1:
                    # Version 1 held exactly one source in a single-row table.
                    connection.execute("""
                        INSERT INTO sources
                            (source_id, revision, label, provider, host, port, tls,
                             nickname, channel, created_at, updated_at)
                        SELECT source_id, revision, label, provider, host, port, tls,
                               nickname, channel, updated_at, updated_at
                        FROM source_configuration
                    """)
                    connection.execute("DROP TABLE source_configuration")
                if version < SCHEMA_VERSION:
                    connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
                connection.execute("COMMIT")
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise

    @staticmethod
    def _from_row(row: sqlite3.Row | None) -> SourceConfig | None:
        if row is None:
            return None
        return SourceConfig(
            source_id=row["source_id"], revision=row["revision"],
            label=row["label"], provider=row["provider"], host=row["host"],
            port=row["port"], tls=bool(row["tls"]), nickname=row["nickname"],
            channel=row["channel"], updated_at=row["updated_at"],
            search_bot=row["search_bot"], category=row["category"],
        )

    @staticmethod
    def new_source_id() -> str:
        return "src-" + uuid.uuid4().hex[:12]

    def get(self, source_id: str = SOURCE_ID) -> SourceConfig | None:
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT * FROM sources WHERE source_id = ?", (source_id,)
            ).fetchone()
        return self._from_row(row)

    def list(self) -> list[SourceConfig]:
        with closing(self._connect()) as connection:
            rows = connection.execute(
                "SELECT * FROM sources ORDER BY created_at, source_id"
            ).fetchall()
        return [config for config in map(self._from_row, rows) if config is not None]

    def save(self, values: dict[str, Any], source_id: str = SOURCE_ID
             ) -> tuple[SourceConfig, SourceConfig | None, bool]:
        normalized = {**validate_source(values), "source_id": source_id}
        if not SOURCE_ID_PATTERN.fullmatch(source_id):
            raise SourceValidationError("source ID has an invalid format")
        now = time.time()
        with closing(self._connect()) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                previous = self._from_row(connection.execute(
                    "SELECT * FROM sources WHERE source_id = ?", (source_id,)
                ).fetchone())
                if normalized["category"] is None:
                    normalized["category"] = previous.category if previous else DEFAULT_CATEGORY
                if previous and all(getattr(previous, key) == normalized[key]
                                     for key in normalized):
                    connection.execute("COMMIT")
                    return previous, previous, False
                others = connection.execute(
                    "SELECT host, port, nickname, channel, provider FROM sources "
                    "WHERE source_id != ?", (source_id,)).fetchall()
                if previous is None and len(others) >= MAX_SOURCES:
                    raise SourceValidationError(
                        f"at most {MAX_SOURCES} sources can be configured")
                # One source is one IRC connection: the same server and
                # nickname cannot be claimed by two of them.
                if any(row["host"].lower() == normalized["host"].lower()
                       and row["port"] == normalized["port"]
                       and row["nickname"].lower() == normalized["nickname"].lower()
                       for row in others):
                    raise SourceValidationError(
                        "another source already uses this server and nickname")
                # Two sources of one kind on the same server and channel
                # would put the same query in that channel twice whenever
                # both are searched. The owner decided on 2026-10-13 to
                # refuse that, except on a lab or test server, where it is
                # the only way to try several sources. The port is not
                # compared: a network's plain and TLS ports are one server.
                if not is_local_server(normalized["host"]) and any(
                        row["host"].lower() == normalized["host"].lower()
                        and row["provider"] == normalized["provider"]
                        and channel_key(row["channel"]) == channel_key(normalized["channel"])
                        for row in others):
                    raise SourceValidationError(
                        "another source of the same kind already has this channel on this "
                        "server; searching both would send the same query there twice")
                if previous:
                    revision = previous.revision + 1
                else:
                    removed = connection.execute(
                        "SELECT last_revision FROM removed_sources WHERE source_id = ?",
                        (source_id,)).fetchone()
                    revision = (removed["last_revision"] if removed else 0) + 1
                connection.execute("""
                    INSERT INTO sources
                        (source_id, revision, label, provider, host, port, tls,
                         nickname, channel, created_at, updated_at, search_bot, category)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source_id) DO UPDATE SET
                        revision=excluded.revision,
                        label=excluded.label, provider=excluded.provider,
                        host=excluded.host, port=excluded.port, tls=excluded.tls,
                        nickname=excluded.nickname, channel=excluded.channel,
                        updated_at=excluded.updated_at, search_bot=excluded.search_bot,
                        category=excluded.category
                """, (source_id, revision, normalized["label"], normalized["provider"],
                      normalized["host"], normalized["port"], int(normalized["tls"]),
                      normalized["nickname"], normalized["channel"], now, now,
                      normalized["search_bot"], normalized["category"]))
                current = self._from_row(connection.execute(
                    "SELECT * FROM sources WHERE source_id = ?", (source_id,)
                ).fetchone())
                connection.execute("COMMIT")
                assert current is not None
                return current, previous, True
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise

    def restore(self, previous: SourceConfig | None, expected_revision: int,
                source_id: str = SOURCE_ID) -> None:
        """Rollback a configuration refused by the engine, if still current."""
        with closing(self._connect()) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                row = connection.execute(
                    "SELECT revision FROM sources WHERE source_id = ?", (source_id,)
                ).fetchone()
                if row is None or row["revision"] != expected_revision:
                    raise RuntimeError("source configuration changed during rollback")
                if previous is None:
                    connection.execute("DELETE FROM sources WHERE source_id = ?", (source_id,))
                else:
                    connection.execute("""
                        UPDATE sources SET revision=?,
                            label=?, provider=?, host=?, port=?, tls=?, nickname=?,
                            channel=?, updated_at=?, search_bot=?, category=?
                        WHERE source_id=?
                    """, (previous.revision, previous.label,
                          previous.provider, previous.host, previous.port,
                          int(previous.tls), previous.nickname, previous.channel,
                          previous.updated_at, previous.search_bot, previous.category,
                          source_id))
                connection.execute("COMMIT")
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise

    def delete(self, source_id: str) -> SourceConfig | None:
        """Remove a source, remembering its last revision. Returns what was removed."""
        with closing(self._connect()) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                previous = self._from_row(connection.execute(
                    "SELECT * FROM sources WHERE source_id = ?", (source_id,)
                ).fetchone())
                if previous is not None:
                    connection.execute("""
                        INSERT INTO removed_sources (source_id, last_revision) VALUES (?, ?)
                        ON CONFLICT(source_id) DO UPDATE SET last_revision=excluded.last_revision
                    """, (source_id, previous.revision))
                    connection.execute("DELETE FROM sources WHERE source_id = ?", (source_id,))
                connection.execute("COMMIT")
                return previous
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise


class SourceService:
    """Explicit source setup/connect operations for the HTTP layer.

    Every operation names a source. The default is the first source,
    ``primary``, which is all that existed before several were supported.
    """

    def __init__(self, database: str | os.PathLike[str], engine: Any) -> None:
        from .logins import LoginStore
        self.store = SourceConfigStore(database)
        self.logins = LoginStore(self.store.path)
        self.engine = engine
        self._lock = asyncio.Lock()

    @classmethod
    def from_environment(cls, engine: Any) -> SourceService:
        config_dir = Path(os.environ.get("FSERVE_CONFIG_DIR", "/config"))
        return cls(config_dir / "fserve" / "fserve.sqlite3", engine)

    async def startup(self) -> dict[str, Any] | None:
        """Restore saved settings into the bridge without connecting to IRC."""
        configs = self.store.list()
        self.logins.forget_except({config.source_id for config in configs})
        for config in configs:
            self.logins.drop_if_moved(config)
        if not configs:
            return None
        try:
            status = await self.engine.status()
            for config in configs:
                if not self._matches(self.engine_source(status, config.source_id), config):
                    await self._apply(config)
        except Exception as exc:
            raise SourceApplyPending(
                "saved source settings could not be confirmed in the engine"
            ) from exc
        return configs[0].public()

    async def save(self, values: dict[str, Any], source_id: str = SOURCE_ID) -> dict[str, Any]:
        async with self._lock:
            config, previous, changed = self.store.save(values, source_id)
            try:
                await (self._apply(config) if changed else self._ensure_engine_source(config))
            except EngineRequestError:
                if changed:
                    self.store.restore(previous, config.revision, source_id)
                raise
            except Exception as exc:
                self.logins.drop_if_moved(config)   # the change is kept
                raise SourceApplyPending(
                    "source settings were saved, but the engine did not confirm applying them"
                ) from exc
            self.logins.drop_if_moved(config)
            return config.public()

    async def create(self, values: dict[str, Any]) -> dict[str, Any]:
        """Add a further source under a new ID."""
        return await self.save(values, self.store.new_source_id())

    async def update(self, values: dict[str, Any], source_id: str) -> dict[str, Any]:
        """Change an existing source; unlike save, never creates one."""
        self._required(source_id)
        return await self.save(values, source_id)

    async def remove(self, source_id: str) -> dict[str, Any]:
        """Remove a disconnected source from the engine, then from storage."""
        async with self._lock:
            config = self._required(source_id)
            try:
                await self.engine.request(
                    "source.remove", {"source_id": source_id},
                    operation_id=f"source-remove-{uuid.uuid4().hex}",
                )
            except EngineRequestError as exc:
                # An engine that restarted has not been told about this
                # source yet; there is nothing to remove there.
                if exc.code != "unknown_source":
                    raise
            self.store.delete(source_id)
            self.logins.clear(source_id)
            return config.public()

    async def set_login(self, source_id: str, values: Any) -> dict[str, Any]:
        """Keep a login for the source; it is given to the engine at the next Connect."""
        from .logins import login_view, make_certificate, validate_login
        async with self._lock:
            config = self._required(source_id)
            login = validate_login(config, values)
            if login["kind"] == "certificate":
                # Saved again, a certificate login keeps its certificate,
                # which may already be added to an account; Clear login, then
                # Save, makes a new one.
                kept = self.logins.get(config)
                login = (kept if kept and kept["kind"] == "certificate"
                         else await asyncio.to_thread(make_certificate))
            self.logins.set(config, login)
            return {"source_id": source_id, "login": login_view(login)}

    async def clear_login(self, source_id: str) -> dict[str, Any]:
        async with self._lock:
            config = self._required(source_id)
            self.logins.clear(source_id)
            try:
                await self.engine.request(
                    "source.login", {"source_id": source_id, "kind": "none"},
                    operation_id=f"source-login-{uuid.uuid4().hex}")
            except EngineRequestError as exc:
                if exc.code != "unknown_source":
                    raise
            return {"source_id": config.source_id, "login": None}

    async def _give_login(self, config: SourceConfig) -> None:
        """Tell the engine the source's login, or that it has none, before connecting."""
        login = self.logins.get(config) or {"kind": "none"}
        # The fingerprints are the page's; the engine needs only the certificate.
        arguments = {"source_id": config.source_id,
                     **{key: value for key, value in login.items()
                        if key in ("kind", "username", "password", "certificate")}}
        await self.engine.request("source.login", arguments,
                                  operation_id=f"source-login-{uuid.uuid4().hex}")

    async def _apply(self, config: SourceConfig) -> dict[str, Any]:
        return await self.engine.request(
            "source.configure", config.engine_arguments(),
            operation_id=f"source-config-{config.revision}-{uuid.uuid4().hex}",
        )

    def _required(self, source_id: str) -> SourceConfig:
        config = self.store.get(source_id)
        if config is None:
            raise UnknownSource("no such source is configured")
        return config

    async def connect(self, source_id: str = SOURCE_ID) -> dict[str, Any]:
        async with self._lock:
            config = self.store.get(source_id)
            if config is None and source_id != SOURCE_ID:
                raise UnknownSource("no such source is configured")
            if config is None:
                raise SourceValidationError("configure the source before connecting")
            await self._ensure_engine_source(config)
            await self._give_login(config)
            return await self.engine.request(
                "source.connect", {"source_id": config.source_id},
                operation_id=f"source-connect-{uuid.uuid4().hex}",
            )

    async def disconnect(self, source_id: str = SOURCE_ID) -> dict[str, Any]:
        async with self._lock:
            config = self.store.get(source_id)
            if config is None and source_id != SOURCE_ID:
                raise UnknownSource("no such source is configured")
            if config is None:
                raise SourceValidationError("no source is configured")
            await self._ensure_engine_source(config)
            return await self.engine.request(
                "source.disconnect", {"source_id": config.source_id},
                operation_id=f"source-disconnect-{uuid.uuid4().hex}",
            )

    async def status(self) -> dict[str, Any]:
        from .logins import login_view
        configs = self.store.list()
        first = next((config for config in configs if config.source_id == SOURCE_ID),
                     configs[0] if configs else None)
        engine_status = await self.engine.status()

        def shown(config: SourceConfig) -> dict[str, Any]:
            return {**config.public(), "login": login_view(self.logins.get(config))}

        return {
            "configuration": shown(first) if first else None,
            "configurations": [shown(config) for config in configs],
            "engine": engine_status,
        }

    async def _ensure_engine_source(self, config: SourceConfig) -> None:
        status = await self.engine.status()
        if not self._matches(self.engine_source(status, config.source_id), config):
            await self._apply(config)

    @staticmethod
    def engine_source(status: Any, source_id: str) -> dict[str, Any] | None:
        """The engine's view of one source, from a status reply."""
        if not isinstance(status, dict):
            return None
        listed = status.get("sources")
        candidates = listed if isinstance(listed, list) else [status.get("source")]
        for source in candidates:
            if isinstance(source, dict) and source.get("source_id") == source_id:
                return source
        return None

    @staticmethod
    def _matches(source: Any, config: SourceConfig) -> bool:
        if not isinstance(source, dict):
            return False
        expected = config.engine_arguments()
        return all(source.get(key) == value for key, value in expected.items())
