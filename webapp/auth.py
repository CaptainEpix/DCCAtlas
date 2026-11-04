"""Single-operator authentication, sessions and CSRF tokens.

Only the password's scrypt verifier is stored. Sessions live in process
memory: restarting the service signs the operator out, and nothing that grants
access is written to disk.

Since 2026-10-28 the operator sets the password on the page. Who may do that
is shown by a one-time code that the service prints to its own output, which
only someone who can read the container's log (``docker logs``) sees: a setup
code while no password is set, and a reset code, valid for 15 minutes, when
"Forgot password" asks for one. A signed-in operator changes the password by
giving the current one. A password file still works, for setups made by
script: its password is adopted when the file is new or has changed, and
otherwise left alone, so it never undoes a password changed on the page.
"""

from __future__ import annotations

from contextlib import closing
from dataclasses import dataclass
import hashlib
import hmac
import os
import secrets
import sqlite3
import time
from pathlib import Path


MIN_PASSWORD_LENGTH = 12
MAX_PASSWORD_BYTES = 1024
MAX_SECRET_FILE_BYTES = 4096
SESSION_IDLE_SECONDS = 12 * 60 * 60
SESSION_LIFETIME_SECONDS = 7 * 24 * 60 * 60
MAX_SESSIONS = 16
FAILURES_BEFORE_DELAY = 5
MAX_LOGIN_DELAY_SECONDS = 15 * 60
RESET_CODE_SECONDS = 15 * 60
RESET_CODE_INTERVAL_SECONDS = 60
# 12 characters from 31 that cannot be mistaken for one another: about 59 bits.
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 12
# One of the equivalent minimum scrypt configurations in the OWASP Password
# Storage Cheat Sheet; this one keeps a verification to about 32 MiB.
_SCRYPT = {"n": 2 ** 15, "r": 8, "p": 3}
_SCRYPT_MAXMEM = 128 * 1024 * 1024
_KEY_BYTES = 32


class AuthError(Exception):
    """A login or setup step was refused."""

    def __init__(self, code: str, message: str, *, retry_after: int | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.retry_after = retry_after


@dataclass(frozen=True)
class Session:
    token_digest: bytes
    csrf_token: str
    created_at: float
    last_seen: float


def _derive(password: bytes, salt: bytes, n: int, r: int, p: int) -> bytes:
    return hashlib.scrypt(password, salt=salt, n=n, r=r, p=p,
                          maxmem=_SCRYPT_MAXMEM, dklen=_KEY_BYTES)


def read_password_file(path: str | os.PathLike[str]) -> str:
    """Read one password from a secret file; a trailing newline is not part of it."""
    secret = Path(path)
    try:
        if secret.stat().st_size > MAX_SECRET_FILE_BYTES:
            raise AuthError("invalid_password_file", "the password file is too large")
        raw = secret.read_bytes()
    except OSError as exc:
        raise AuthError("password_file_unreadable", "the password file could not be read") from exc
    try:
        # Windows editors often prepend a byte-order mark; it is not typed at
        # the sign-in page, so it must not become part of the password.
        password = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise AuthError("invalid_password_file", "the password file is not UTF-8 text") from exc
    password = password.removesuffix("\n").removesuffix("\r")
    validate_password(password)
    return password


def new_code() -> str:
    """A one-time code, shown in groups of four."""
    raw = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
    return "-".join(raw[index:index + 4] for index in range(0, CODE_LENGTH, 4))


def normalized_code(value: object) -> str:
    """A code as typed, without case, spaces or dashes."""
    if not isinstance(value, str) or len(value) > 64:
        return ""
    return "".join(char for char in value.upper() if char not in " -\t")


def validate_password(password: str) -> None:
    if (not isinstance(password, str) or len(password) < MIN_PASSWORD_LENGTH
            or len(password.encode("utf-8")) > MAX_PASSWORD_BYTES
            or any(ord(char) < 32 or ord(char) == 127 for char in password)):
        raise AuthError(
            "invalid_password",
            f"the password must be at least {MIN_PASSWORD_LENGTH} characters with no control characters",
        )


class CredentialStore:
    """Password verification data in the private application database."""

    def __init__(self, database: str | os.PathLike[str]) -> None:
        self.path = Path(database).expanduser().absolute()
        if not self.path.is_file() or self.path.is_symlink():
            raise ValueError("initialize the source store before the credential store")
        with closing(self._connect()) as connection:
            connection.execute("""
                CREATE TABLE IF NOT EXISTS auth_credential (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    salt BLOB NOT NULL,
                    verifier BLOB NOT NULL,
                    scrypt_n INTEGER NOT NULL,
                    scrypt_r INTEGER NOT NULL,
                    scrypt_p INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)
            # The password file last adopted, kept as a verifier like the
            # password itself, so that an unchanged file is not adopted again.
            connection.execute("""
                CREATE TABLE IF NOT EXISTS auth_password_file (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    salt BLOB NOT NULL,
                    verifier BLOB NOT NULL,
                    scrypt_n INTEGER NOT NULL,
                    scrypt_r INTEGER NOT NULL,
                    scrypt_p INTEGER NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.execute("PRAGMA busy_timeout = 5000")
        return connection

    def configured(self) -> bool:
        with closing(self._connect()) as connection:
            return connection.execute(
                "SELECT 1 FROM auth_credential WHERE singleton=1").fetchone() is not None

    def set_password(self, password: str) -> None:
        validate_password(password)
        self._store("auth_credential", password)

    def remember_file(self, password: str) -> None:
        """Record the password file's contents as adopted."""
        self._store("auth_password_file", password)

    def file_unchanged(self, password: str) -> bool:
        """True when the password file holds what was last adopted from it."""
        return self._verify("auth_password_file", password)

    def _store(self, table: str, password: str) -> None:
        salt = secrets.token_bytes(16)
        verifier = _derive(password.encode("utf-8"), salt, **_SCRYPT)
        with closing(self._connect()) as connection:
            connection.execute(f"""
                INSERT INTO {table}
                    (singleton, salt, verifier, scrypt_n, scrypt_r, scrypt_p, updated_at)
                VALUES (1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET
                    salt=excluded.salt, verifier=excluded.verifier,
                    scrypt_n=excluded.scrypt_n, scrypt_r=excluded.scrypt_r,
                    scrypt_p=excluded.scrypt_p, updated_at=excluded.updated_at
            """, (salt, verifier, _SCRYPT["n"], _SCRYPT["r"], _SCRYPT["p"], time.time()))

    def outdated(self) -> bool:
        """True when the stored verifier predates the current scrypt cost."""
        with closing(self._connect()) as connection:
            row = connection.execute("""
                SELECT scrypt_n, scrypt_r, scrypt_p FROM auth_credential WHERE singleton=1
            """).fetchone()
        return row is not None and tuple(row) != (_SCRYPT["n"], _SCRYPT["r"], _SCRYPT["p"])

    def verify(self, password: str) -> bool:
        return self._verify("auth_credential", password)

    def _verify(self, table: str, password: str) -> bool:
        with closing(self._connect()) as connection:
            row = connection.execute(f"""
                SELECT salt, verifier, scrypt_n, scrypt_r, scrypt_p
                FROM {table} WHERE singleton=1
            """).fetchone()
        if row is None or not isinstance(password, str):
            return False
        encoded = password.encode("utf-8")
        if len(encoded) > MAX_PASSWORD_BYTES:
            return False
        salt, verifier, n, r, p = row
        try:
            candidate = _derive(encoded, salt, n, r, p)
        except ValueError:
            return False
        return hmac.compare_digest(candidate, verifier)


class Authenticator:
    """Login throttling plus in-memory sessions for the one operator.

    Not thread-safe: every method except the slow password check belongs to
    one thread. A caller that moves the check elsewhere must run
    `begin_login`, the check and `finish_login` for one attempt at a time,
    so that each attempt sees the failures of the one before it.
    """

    def __init__(self, store: CredentialStore, *, clock=time.monotonic) -> None:
        self.store = store
        self._clock = clock
        self._sessions: dict[bytes, Session] = {}
        self._failures = 0
        self._locked_until = 0.0
        # One-time codes, in memory only: kind -> (normalized code, expiry or None).
        self._codes: dict[str, tuple[str, float | None]] = {}
        self._reset_code_made_at: float | None = None

    def apply_password_file(self, path: str | os.PathLike[str] | None) -> bool:
        """Adopt the mounted password if the file is new or has changed.

        A file holding what was adopted before is left alone, so a password
        set on the page since stays. A password that differs from the one in
        use signs every session out.
        """
        if not path or not Path(path).exists():
            return False
        password = read_password_file(path)
        matches = self.store.verify(password)
        if self.store.file_unchanged(password):
            if matches and self.store.outdated():
                self.store.set_password(password)
            return True
        if not matches:
            self._sessions.clear()
            self._codes.clear()
        if not matches or self.store.outdated():
            self.store.set_password(password)
        self.store.remember_file(password)
        return True

    # -- one-time codes ------------------------------------------------------

    def setup_code(self) -> str | None:
        """A new setup code while no password is set; the caller prints it."""
        if self.configured:
            return None
        code = new_code()
        self._codes["setup"] = (normalized_code(code), None)
        return code

    def reset_code(self) -> str:
        """A new reset code, replacing any earlier one; the caller prints it.

        At most one a minute, so that the button cannot fill the log.
        """
        if not self.configured:
            raise AuthError("setup_required", "no operator password has been set yet")
        now = self._clock()
        if (self._reset_code_made_at is not None
                and now - self._reset_code_made_at < RESET_CODE_INTERVAL_SECONDS):
            raise AuthError(
                "code_requested_recently",
                "a reset code was written to the log less than a minute ago; use that one",
                retry_after=max(1, int(RESET_CODE_INTERVAL_SECONDS
                                       - (now - self._reset_code_made_at)) + 1))
        self._reset_code_made_at = now
        code = new_code()
        self._codes["reset"] = (normalized_code(code), now + RESET_CODE_SECONDS)
        return code

    def _code_matches(self, kind: str, supplied: object) -> bool:
        held = self._codes.get(kind)
        if held is None:
            return False
        code, expires = held
        if expires is not None and self._clock() > expires:
            del self._codes[kind]
            return False
        return hmac.compare_digest(code.encode(), normalized_code(supplied).encode())

    # Setting, resetting or changing the password is three steps, as a login
    # is: a check on this thread (begin_*), storing the new password (the
    # slow scrypt, which may run elsewhere), then password_replaced here.

    def begin_setup(self, code: object, password: object) -> str:
        """Check the setup code; the new password to store is returned."""
        self._check_delay()
        if self.configured:
            raise AuthError("already_set_up", "a password is already set; sign in instead")
        if not self._code_matches("setup", code):
            self._fail("invalid_code", "the setup code is not correct")
        return self._new_password(password)

    def begin_reset(self, code: object, password: object) -> str:
        """Check the reset code; the new password to store is returned."""
        self._check_delay()
        if not self.configured:
            raise AuthError("setup_required", "no operator password has been set yet")
        if not self._code_matches("reset", code):
            self._fail("invalid_code", "the reset code is not correct, or has expired")
        return self._new_password(password)

    def begin_change(self, verified: bool, password: object) -> str:
        """After begin_login and the check of the current password, as for a login."""
        if not verified:
            self._fail("invalid_credentials", "the current password is not correct")
        return self._new_password(password)

    @staticmethod
    def _new_password(password: object) -> str:
        if not isinstance(password, str):
            raise AuthError("invalid_password", "a new password is required")
        validate_password(password)
        return password

    def password_replaced(self) -> tuple[str, Session]:
        """Once the new password is stored: every other session ends, no earlier
        code works any more, and this browser is signed in."""
        self._sessions.clear()
        self._codes.clear()
        self._reset_code_made_at = None
        return self.finish_login(True)

    def set_up(self, code: object, password: object) -> tuple[str, Session]:
        """The three steps of setting the first password, on one thread."""
        self.store.set_password(self.begin_setup(code, password))
        return self.password_replaced()

    def reset(self, code: object, password: object) -> tuple[str, Session]:
        """The three steps of resetting a forgotten password, on one thread."""
        self.store.set_password(self.begin_reset(code, password))
        return self.password_replaced()

    @property
    def configured(self) -> bool:
        return self.store.configured()

    @staticmethod
    def _digest(token: str) -> bytes:
        return hashlib.sha256(token.encode("utf-8")).digest()

    def begin_login(self) -> None:
        """Refuse an attempt that may not be checked yet."""
        self._check_delay()
        if not self.configured:
            raise AuthError("setup_required", "no operator password has been set yet")

    def _check_delay(self) -> None:
        """Wrong passwords and wrong codes share one delay."""
        now = self._clock()
        if now < self._locked_until:
            raise AuthError("login_delayed", "too many failed attempts; wait before trying again",
                            retry_after=max(1, int(self._locked_until - now) + 1))

    def _fail(self, code: str, message: str):
        self._failures += 1
        if self._failures >= FAILURES_BEFORE_DELAY:
            delay = min(MAX_LOGIN_DELAY_SECONDS,
                        2 ** (self._failures - FAILURES_BEFORE_DELAY + 1))
            self._locked_until = self._clock() + delay
        raise AuthError(code, message)

    def finish_login(self, verified: bool) -> tuple[str, Session]:
        """Record the outcome of one checked attempt; open a session on success."""
        now = self._clock()
        if not verified:
            self._fail("invalid_credentials", "the password is not correct")
        self._failures = 0
        self._locked_until = 0.0
        self._expire(now)
        while len(self._sessions) >= MAX_SESSIONS:
            oldest = min(self._sessions.values(), key=lambda item: item.last_seen)
            del self._sessions[oldest.token_digest]
        token = secrets.token_urlsafe(32)
        session = Session(self._digest(token), secrets.token_urlsafe(32), now, now)
        self._sessions[session.token_digest] = session
        return token, session

    def login(self, password: object) -> tuple[str, Session]:
        self.begin_login()
        return self.finish_login(isinstance(password, str) and self.store.verify(password))

    def session(self, token: str | None) -> Session | None:
        if not token or len(token) > 128:
            return None
        now = self._clock()
        self._expire(now)
        digest = self._digest(token)
        session = self._sessions.get(digest)
        if session is None:
            return None
        refreshed = Session(digest, session.csrf_token, session.created_at, now)
        self._sessions[digest] = refreshed
        return refreshed

    def logout(self, token: str | None) -> None:
        if token and len(token) <= 128:
            self._sessions.pop(self._digest(token), None)

    def _expire(self, now: float) -> None:
        for digest, session in list(self._sessions.items()):
            if (now - session.last_seen > SESSION_IDLE_SECONDS
                    or now - session.created_at > SESSION_LIFETIME_SECONDS):
                del self._sessions[digest]

    @staticmethod
    def csrf_matches(session: Session, supplied: str | None) -> bool:
        return bool(supplied) and hmac.compare_digest(
            session.csrf_token.encode("utf-8"), supplied.encode("utf-8", errors="replace"))
