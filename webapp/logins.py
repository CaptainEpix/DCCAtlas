"""A source's login (web M3, Y2): a server password, a SASL PLAIN account,
(since 2026-10-21) a NickServ password, given to NickServ once the server has
let the client in, or (since 2026-10-27) a client certificate the app makes
for the source, presented over TLS and logged in with by SASL EXTERNAL.

The secret is written once, through the API, and never read back out: the
page and every reply only say which kind of login is set (and the account
name, which is not secret). It is kept in its own table of the private
database, and given to the engine just before each Connect. It belongs to the
server it was entered for: once the source points at another host, port or
TLS setting it is no longer used, and is deleted.

A certificate's private key is the secret, kept where a password is; its
fingerprints are not secret, and are shown so that the user can add the
certificate to their account (Libera: https://libera.chat/guides/certfp;
Ergo: https://github.com/ergochat/ergo/blob/v2.19.1/docs/MANUAL.md).
"""

from __future__ import annotations

from contextlib import closing, contextmanager
import os
from pathlib import Path
import base64
import hashlib
import re
import sqlite3
import subprocess
import tempfile
import time
from typing import Any, Iterator

from .sources import SourceConfig, SourceValidationError, is_local_server


KINDS = ("server_password", "sasl_plain", "nickserv", "certificate")
_LOGIN_TABLE = """
    CREATE TABLE IF NOT EXISTS source_login (
        source_id TEXT PRIMARY KEY,
        endpoint TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('server_password', 'sasl_plain', 'nickserv',
                                           'certificate')),
        username TEXT,
        password TEXT NOT NULL,
        updated_at REAL NOT NULL,
        fingerprints TEXT
    )
"""
_COLUMNS = "source_id, endpoint, kind, username, password, updated_at"
_PEM = re.compile(
    r"-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+-----END CERTIFICATE-----\n"
    r"-----BEGIN PRIVATE KEY-----\n[A-Za-z0-9+/=\n]+-----END PRIVATE KEY-----\n")
CERTIFICATE_DAYS = 3650


def make_certificate() -> dict[str, str]:
    """A new self-signed client certificate and its key, made with openssl.

    RSA rather than Ed25519, which Libera's guide notes some clients cannot
    use. The key is written only to a private temporary folder, read back
    and removed.
    """
    with tempfile.TemporaryDirectory(prefix="dccatlas-cert-") as name:
        folder = Path(name)
        subprocess.run(
            ["openssl", "req", "-x509", "-new", "-newkey", "rsa:3072", "-sha256", "-nodes",
             "-days", str(CERTIFICATE_DAYS), "-subj", "/CN=DCCAtlas",
             "-keyout", str(folder / "key.pem"), "-out", str(folder / "cert.pem")],
            check=True, capture_output=True, timeout=60)
        pem = (folder / "cert.pem").read_text("ascii") + (folder / "key.pem").read_text("ascii")
    if not _PEM.fullmatch(pem):
        raise RuntimeError("openssl made a certificate in an unexpected form")
    return {"kind": "certificate", "certificate": pem, **fingerprints_of(pem)}


def fingerprints_of(pem: str) -> dict[str, str]:
    """The certificate's SHA-256 and SHA-512 fingerprints, as hex."""
    body = pem.split("-----BEGIN CERTIFICATE-----\n", 1)[1].split("-----END CERTIFICATE-----")[0]
    der = base64.b64decode("".join(body.split()))
    return {"sha256": hashlib.sha256(der).hexdigest(), "sha512": hashlib.sha512(der).hexdigest()}


def endpoint_of(config: SourceConfig) -> str:
    return "\x1f".join((config.host.lower(), str(config.port), "1" if config.tls else "0"))


def validate_login(config: SourceConfig, values: Any) -> dict[str, str]:
    if not isinstance(values, dict):
        raise SourceValidationError("a login must be an object")
    kind = values.get("kind")
    if kind not in KINDS:
        raise SourceValidationError(
            "the kind of login must be server_password, sasl_plain, nickserv or certificate")
    if kind == "certificate":
        # The certificate is made by the app, not given; and it is only ever
        # presented inside TLS, on any network.
        if set(values) != {"kind"}:
            raise SourceValidationError("a certificate login takes nothing but its kind")
        if not config.tls:
            raise SourceValidationError(
                "a client certificate is only presented over TLS; turn TLS on for this "
                "source first")
        return {"kind": "certificate"}
    allowed = {"kind", "password"} | ({"username"} if kind == "sasl_plain" else set())
    # NickServ takes an account name only when it differs from the nick.
    if kind == "nickserv" and "username" in values:
        allowed.add("username")
    if set(values) != allowed:
        raise SourceValidationError(
            "a server password takes only a password; an account takes a name and a password")
    # Over plain text the password would cross the network as it is typed.
    # A private-network server, such as a lab's, is the one exception.
    if not config.tls and not is_local_server(config.host):
        raise SourceValidationError(
            "this source does not use TLS, so a password would cross the network in "
            "plain text; turn TLS on for it first")
    password = values["password"]
    if not isinstance(password, str) or not re.fullmatch(r"[\x20-\x7e]{1,128}", password):
        raise SourceValidationError("the password must be 1 to 128 printable ASCII characters")
    login = {"kind": kind, "password": password}
    if kind == "server_password":
        # Irssi sends it as "PASS <password>", so it must be one IRC parameter.
        if " " in password or password.startswith(":"):
            raise SourceValidationError(
                "a server password cannot contain a space or start with a colon")
        # Irssi's CONNECT takes "-" to mean no password, and would drop it.
        if password == "-":
            raise SourceValidationError('a server password cannot be just "-"')
    # NickServ reads "IDENTIFY [account] password" as words.
    if kind == "nickserv" and " " in password:
        raise SourceValidationError("a NickServ password cannot contain a space")
    if "username" in values:
        username = values["username"]
        if not isinstance(username, str) or not re.fullmatch(r"[\x21-\x7e]{1,64}", username):
            raise SourceValidationError(
                "the account name must be 1 to 64 printable ASCII characters without spaces")
        login["username"] = username
    return login


def login_view(login: dict[str, Any] | None) -> dict[str, str] | None:
    """What may be shown of a login: never the password."""
    if login is None:
        return None
    view = {"kind": login["kind"]}
    if login["kind"] == "certificate":
        view.update(sha256=login["sha256"], sha512=login["sha512"])
    if login.get("username"):
        view["username"] = login["username"]
    return view


class LoginStore:
    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if not self.path.exists() or not self.path.is_file() or self.path.is_symlink():
            raise ValueError("initialize the source store before the login store")
        with self._transaction() as connection:
            existing = connection.execute(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='source_login'"
            ).fetchone()
            if existing is not None and "'certificate'" not in existing[0]:
                # NickServ logins and certificates came later; the table is
                # rebuilt to allow them.
                connection.execute("ALTER TABLE source_login RENAME TO source_login_old")
                connection.execute(_LOGIN_TABLE)
                connection.execute(f"INSERT INTO source_login ({_COLUMNS}) "
                                   f"SELECT {_COLUMNS} FROM source_login_old")
                connection.execute("DROP TABLE source_login_old")
            connection.execute(_LOGIN_TABLE)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout = 5000")
        # A deleted or replaced password is overwritten in the file, not
        # left in free pages until SQLite reuses them.
        connection.execute("PRAGMA secure_delete = ON")
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

    def set(self, config: SourceConfig, login: dict[str, str]) -> None:
        certificate = login["kind"] == "certificate"
        with self._transaction() as connection:
            connection.execute(f"""
                INSERT INTO source_login ({_COLUMNS}, fingerprints)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (source_id) DO UPDATE SET endpoint=excluded.endpoint,
                    kind=excluded.kind, username=excluded.username,
                    password=excluded.password, updated_at=excluded.updated_at,
                    fingerprints=excluded.fingerprints
            """, (config.source_id, endpoint_of(config), login["kind"], login.get("username"),
                  login["certificate"] if certificate else login["password"], time.time(),
                  f"{login['sha256']} {login['sha512']}" if certificate else None))

    def clear(self, source_id: str) -> None:
        with self._transaction() as connection:
            connection.execute("DELETE FROM source_login WHERE source_id=?", (source_id,))

    def get(self, config: SourceConfig) -> dict[str, Any] | None:
        """The login for the source as it is now; none if it was for another server.

        Reading never deletes: the configuration seen may be a change that is
        about to be rolled back. ``drop_if_moved`` deletes, once a change is kept.
        """
        with closing(self._connect()) as connection:
            row = connection.execute(
                "SELECT * FROM source_login WHERE source_id=?", (config.source_id,)).fetchone()
        if row is None or row["endpoint"] != endpoint_of(config):
            return None
        if row["kind"] == "certificate":
            sha256, sha512 = row["fingerprints"].split()
            return {"kind": "certificate", "certificate": row["password"],
                    "sha256": sha256, "sha512": sha512}
        login = {"kind": row["kind"], "password": row["password"]}
        if row["username"] is not None:
            login["username"] = row["username"]
        return login

    def drop_if_moved(self, config: SourceConfig) -> None:
        """Delete the login once the source points at another server."""
        with self._transaction() as connection:
            connection.execute("DELETE FROM source_login WHERE source_id=? AND endpoint != ?",
                               (config.source_id, endpoint_of(config)))

    def forget_except(self, source_ids: set[str]) -> None:
        """Delete the logins of sources that no longer exist."""
        with self._transaction() as connection:
            for row in connection.execute("SELECT source_id FROM source_login").fetchall():
                if row["source_id"] not in source_ids:
                    connection.execute("DELETE FROM source_login WHERE source_id=?",
                                       (row["source_id"],))
