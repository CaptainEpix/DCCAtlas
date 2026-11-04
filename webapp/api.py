"""Authenticated same-origin HTTP API and static browser assets."""

from __future__ import annotations

import asyncio
import hashlib
import ipaddress
from contextlib import asynccontextmanager
import json
import logging
import time
from pathlib import Path
from typing import Any, Awaitable, Callable
from urllib.parse import urlsplit

from starlette.applications import Starlette
from starlette.datastructures import Headers
from starlette.exceptions import HTTPException
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, Response
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles

from .auth import AuthError, SESSION_LIFETIME_SECONDS, Session
from .errors import ServiceError
from .ids import IRC_NICK, SOURCE_ID_PATTERN
from .manifests import MAX_LIST_BYTES
from .prowlarr import (FEED_LIMIT, VERSION as SABNZBD_VERSION, ProwlarrService, Refusal,
                       wanted_categories)
from .engine_client import EngineProtocolError, EngineRequestError
from .runtime import Runtime, Services
from .searches import MAX_PAGE_SIZE, TERMINAL_STATES
from .sources import (PROVIDER, SOURCE_ID, SourceApplyPending, SourceValidationError,
                      UnknownSource, is_local_server)


logger = logging.getLogger("dccatlas.web")
SESSION_COOKIE = "dccatlas_session"
CSRF_HEADER = "x-csrf-token"
MAX_BODY_BYTES = 16 * 1024
STATIC_DIRECTORY = Path(__file__).resolve().parent / "static"


def page_build() -> str:
    """A fingerprint of the page's own files, so an open page can tell that
    the app was updated under it and ask to be reloaded (2026-10-27)."""
    digest = hashlib.sha256()
    for path in sorted(STATIC_DIRECTORY.rglob("*")):
        if path.is_file():
            digest.update(path.relative_to(STATIC_DIRECTORY).as_posix().encode() + b"\0")
            digest.update(path.read_bytes())
    return digest.hexdigest()[:16]
SAFE_METHODS = frozenset({"GET", "HEAD"})
SECURITY_HEADERS = (
    (b"content-security-policy",
     b"default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"),
    (b"x-content-type-options", b"nosniff"),
    (b"x-frame-options", b"DENY"),
    (b"referrer-policy", b"no-referrer"),
    (b"cross-origin-opener-policy", b"same-origin"),
    (b"cross-origin-resource-policy", b"same-origin"),
)
_STATUS_BY_CODE = {
    "poll_too_fast": 429,
    "too_soon": 429,
    "login_delayed": 429,
    "invalid_credentials": 401,
    "invalid_code": 401,
    "code_requested_recently": 429,
    "not_authenticated": 401,
    "csrf_failed": 403,
    "cross_origin": 403,
    "setup_required": 503,
    "engine_unavailable": 503,
    "engine_unconfirmed": 503,
    "journal_unavailable": 503,
    "confirmation_required": 400,
    "unsupported_media_type": 415,
}


class ApiError(Exception):
    def __init__(self, code: str, message: str, *, status: int | None = None,
                 retry_after: int | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status or status_for(code)
        self.retry_after = retry_after


def status_for(code: str) -> int:
    if code in _STATUS_BY_CODE:
        return _STATUS_BY_CODE[code]
    if code.startswith("invalid_"):
        return 400
    if code.startswith("unknown_"):
        return 404
    return 409


def _clean(message: Any) -> str:
    text = message if isinstance(message, str) else "request could not be processed"
    return "".join(char for char in text if ord(char) >= 32 and ord(char) != 127)[:512]


def error_response(code: str, message: Any, *, status: int | None = None,
                   retry_after: int | None = None) -> JSONResponse:
    response = JSONResponse(
        {"error": {"code": code, "message": _clean(message)}},
        status_code=status or status_for(code),
    )
    if retry_after is not None:
        response.headers["retry-after"] = str(retry_after)
    return response


class SecurityHeaders:
    """Add fixed response headers; API responses are never cached."""

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        is_api = scope.get("path", "").startswith("/api/")

        async def send_with_headers(message) -> None:
            if message["type"] == "http.response.start":
                headers = [item for item in message.get("headers", [])
                           if item[0].lower() != b"server"]
                headers.extend(SECURITY_HEADERS)
                headers.append((b"cache-control", b"no-store" if is_api else b"no-cache"))
                message = {**message, "headers": headers}
            await send(message)

        await self.app(scope, receive, send_with_headers)


def host_name(header: str) -> str:
    """The name or address in a Host header, without its port; "" if malformed."""
    header = header.strip().lower()
    if header.startswith("["):
        # Brackets hold an IPv6 address and nothing else.
        end = header.find("]")
        rest = header[end + 1:] if end > 0 else ":"
        if end <= 0 or (rest and rest[0] != ":"):
            return ""
        try:
            ipaddress.IPv6Address(header[1:end])
        except ValueError:
            return ""
        return header[1:end]
    if header.count(":") > 1:
        return ""   # an IPv6 address must be in brackets
    return header.split(":", 1)[0]


def host_allowed(header: str, allowed: frozenset[str]) -> bool:
    """A listed name, or a private-network address typed as such.

    The check is against DNS rebinding, in which a site's own name is made to
    point at this service. That needs a name: an address in the address bar
    cannot be repointed, so any private-network address is accepted (since
    2026-10-28), letting the page be opened by address from the LAN with no
    setting. Other names are still listed in FSERVE_ALLOWED_HOSTS.
    """
    name = host_name(header)
    if not name:
        return False
    if name in allowed:
        return True
    try:
        ipaddress.ip_address(name)
    except ValueError:
        return False
    return is_local_server(name)


class AllowedHosts:
    """Refuse a request whose Host is neither listed nor a private address."""

    def __init__(self, app, allowed_hosts: list[str]) -> None:
        self.app = app
        self.allowed = frozenset(host.lower() for host in allowed_hosts)

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] in ("http", "websocket") and not host_allowed(
                Headers(scope=scope).get("host", ""), self.allowed):
            await PlainTextResponse("Invalid host header", status_code=400)(scope, receive, send)
            return
        await self.app(scope, receive, send)


def _same_origin(request: Request) -> bool:
    """Refuse browser requests that another site initiated."""
    origin = request.headers.get("origin")
    if origin is not None:
        host = request.headers.get("host", "")
        return bool(host) and urlsplit(origin).netloc.lower() == host.lower()
    fetch_site = request.headers.get("sec-fetch-site")
    return fetch_site is None or fetch_site in ("same-origin", "none")


async def _json_object(request: Request, allowed: set[str]) -> dict[str, Any]:
    media_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if media_type != "application/json":
        raise ApiError("unsupported_media_type", "send the request body as application/json")
    body = await request.body()
    if len(body) > MAX_BODY_BYTES:
        raise ApiError("invalid_request", "the request body is too large", status=413)
    try:
        value = json.loads(body.decode("utf-8")) if body else {}
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ApiError("invalid_request", "the request body is not valid JSON") from exc
    if not isinstance(value, dict) or set(value) - allowed:
        raise ApiError("invalid_request", "the request body has unsupported fields")
    return value


def _query_integer(request: Request, name: str, default: int) -> int:
    raw = request.query_params.get(name)
    if raw is None:
        return default
    if not raw.isascii() or not raw.isdigit() or len(raw) > 6:
        raise ApiError("invalid_page", f"{name} must be a small non-negative integer")
    return int(raw)


Handler = Callable[..., Awaitable[Any]]


def create_app(runtime: Runtime) -> Starlette:
    auth = runtime.auth
    settings = runtime.settings
    login_lock = asyncio.Lock()
    prowlarr = ProwlarrService(settings.database, lambda: runtime.services, runtime.log)

    def services() -> Services:
        current = runtime.services
        if current is None:
            raise ApiError("engine_unavailable", "the local FServe engine is not available yet")
        return current

    def endpoint(handler: Handler, *, public: bool = False):
        """Wrap a handler with origin, session, CSRF and error handling."""

        async def wrapped(request: Request) -> Response:
            try:
                unsafe = request.method not in SAFE_METHODS
                if unsafe and not _same_origin(request):
                    raise ApiError("cross_origin", "cross-origin requests are not accepted")
                session = auth.session(request.cookies.get(SESSION_COOKIE))
                if not public:
                    if session is None:
                        raise ApiError("not_authenticated", "sign in to continue")
                    if unsafe and not auth.csrf_matches(
                            session, request.headers.get(CSRF_HEADER)):
                        raise ApiError("csrf_failed", "the request token is missing or stale")
                result = await handler(request, session)
                if isinstance(result, Response):
                    return result
                return JSONResponse(result)
            except ApiError as exc:
                return error_response(exc.code, exc.message, status=exc.status,
                                      retry_after=exc.retry_after)
            except AuthError as exc:
                return error_response(exc.code, exc.message, retry_after=exc.retry_after)
            except ServiceError as exc:
                return error_response(exc.code, exc.message)
            except UnknownSource as exc:
                return error_response("unknown_source", str(exc))
            except SourceValidationError as exc:
                return error_response("invalid_source", str(exc))
            except SourceApplyPending as exc:
                return error_response("engine_unconfirmed", str(exc))
            except EngineRequestError as exc:
                return error_response(exc.code, exc.message)
            except (ConnectionError, asyncio.TimeoutError, EngineProtocolError, OSError):
                return error_response(
                    "engine_unavailable", "the local FServe engine did not answer")
            except HTTPException:
                raise  # Starlette's own refusal, such as an oversized body
            except Exception:
                # Paths carry only opaque IDs; no request body is logged.
                logger.exception("unexpected failure handling %s %s",
                                 request.method, request.url.path)
                return error_response(
                    "internal_error", "the request failed unexpectedly", status=500)

        return wrapped

    # -- session ---------------------------------------------------------

    def session_view(session: Session | None) -> dict[str, Any]:
        return {
            "authenticated": session is not None,
            "setup_required": not auth.configured,
            # Also reported when an earlier password is still in effect, so
            # a rejected replacement is not mistaken for a wrong password.
            "setup_problem": runtime.password_problem,
            "csrf_token": session.csrf_token if session else None,
        }

    async def get_session(request: Request, session: Session | None):
        return session_view(session)

    async def login(request: Request, session: Session | None):
        password = (await _json_object(request, {"password"})).get("password")
        # scrypt is deliberately slow and memory-hard, so it runs off the
        # event loop. One attempt at a time: otherwise parallel guesses would
        # all pass the failure delay before any of them had been counted.
        async with login_lock:
            auth.begin_login()
            verified = isinstance(password, str) and await asyncio.to_thread(
                auth.store.verify, password)
            token, created = auth.finish_login(verified)
        response = JSONResponse(session_view(created))
        response.set_cookie(
            SESSION_COOKIE, token, max_age=SESSION_LIFETIME_SECONDS, path="/",
            httponly=True, samesite="strict", secure=settings.cookie_secure,
        )
        return response

    def signed_in(created: Session, token: str) -> JSONResponse:
        response = JSONResponse(session_view(created))
        response.set_cookie(
            SESSION_COOKIE, token, max_age=SESSION_LIFETIME_SECONDS, path="/",
            httponly=True, samesite="strict", secure=settings.cookie_secure,
        )
        return response

    # Setting, resetting and changing the password take the login lock, so
    # that they and logins are checked one at a time and share one delay;
    # scrypt runs off the event loop.

    async def set_up(request: Request, session: Session | None):
        body = await _json_object(request, {"code", "password"})
        async with login_lock:
            password = auth.begin_setup(body.get("code"), body.get("password"))
            await asyncio.to_thread(auth.store.set_password, password)
            token, created = auth.password_replaced()
        return signed_in(created, token)

    async def reset_code(request: Request, session: Session | None):
        await _json_object(request, set())
        code = auth.reset_code()
        logger.warning("Password reset code: %s (asked for on the sign-in page; it works "
                       "for 15 minutes, once)", code)
        return {"written": True, "minutes": 15}

    async def reset_password(request: Request, session: Session | None):
        body = await _json_object(request, {"code", "password"})
        async with login_lock:
            password = auth.begin_reset(body.get("code"), body.get("password"))
            await asyncio.to_thread(auth.store.set_password, password)
            token, created = auth.password_replaced()
        return signed_in(created, token)

    async def change_password(request: Request, session: Session):
        body = await _json_object(request, {"current_password", "password"})
        current = body.get("current_password")
        async with login_lock:
            auth.begin_login()
            verified = isinstance(current, str) and await asyncio.to_thread(
                auth.store.verify, current)
            password = auth.begin_change(verified, body.get("password"))
            await asyncio.to_thread(auth.store.set_password, password)
            token, created = auth.password_replaced()
        return signed_in(created, token)

    async def logout(request: Request, session: Session | None):
        auth.logout(request.cookies.get(SESSION_COOKIE))
        response = JSONResponse(session_view(None))
        response.delete_cookie(SESSION_COOKIE, path="/", httponly=True,
                               samesite="strict", secure=settings.cookie_secure)
        return response

    # -- status and source -----------------------------------------------

    async def source_view() -> dict[str, Any]:
        status = await services().sources.status()
        engine = status["engine"]
        sources = services().sources
        primary = status["configuration"]
        return {
            "configuration": primary,
            "source": (sources.engine_source(engine, primary["source_id"])
                       if primary else None),
            # Every configured source with the engine's view of it. The two
            # keys above describe the first one, as before several existed.
            "sources": [
                {"configuration": config,
                 "source": sources.engine_source(engine, config["source_id"])}
                for config in status["configurations"]
            ],
            "journal_ready": bool(engine.get("journal_ready")),
            "restore_pending": runtime.source_restore_pending,
        }

    build = page_build()

    async def get_status(request: Request, session: Session):
        if runtime.services is None:
            return {"engine_available": False, "source": None, "configuration": None,
                    "page_build": build}
        try:
            return {"engine_available": True, **(await source_view()), "page_build": build}
        except (ConnectionError, asyncio.TimeoutError, EngineProtocolError, OSError):
            return {"engine_available": False, "source": None, "configuration": None,
                    "page_build": build}

    # A source is one of two kinds. Without a kind it is the first: a
    # channel whose file servers answer "@find".
    SOURCE_FIELDS = {"label", "host", "port", "tls", "nickname", "channel",
                     "provider", "search_bot", "category"}

    def source_values(body: dict[str, Any]) -> dict[str, Any]:
        values = {"provider": PROVIDER, **body}
        if values.get("search_bot") in ("", None):
            values.pop("search_bot", None)
        return values

    async def put_source(request: Request, session: Session):
        body = await _json_object(request, SOURCE_FIELDS)
        await services().sources.save(source_values(body))
        runtime.source_restore_pending = False
        return await source_view()

    async def connect_source(request: Request, session: Session):
        await _json_object(request, set())
        await services().sources.connect()
        prowlarr.forget_manual(SOURCE_ID)
        return await source_view()

    async def disconnect_source(request: Request, session: Session):
        await _json_object(request, set())
        await services().sources.disconnect()
        prowlarr.forget_manual(SOURCE_ID)
        return await source_view()

    # Several sources. The routes above address the first one only.

    async def list_sources(request: Request, session: Session):
        return {"sources": (await source_view())["sources"]}

    async def put_login(request: Request, session: Session):
        body = await _json_object(request, {"kind", "username", "password"})
        await services().sources.set_login(request.path_params["source_id"], body)
        return await source_view()

    async def delete_login(request: Request, session: Session):
        await services().sources.clear_login(request.path_params["source_id"])
        return await source_view()

    def queue_service():
        service = services().queue
        if service is None:
            raise ApiError("engine_unavailable", "the local FServe engine is not available yet")
        return service

    async def get_queue(request: Request, session: Session):
        return queue_service().view()

    async def add_to_queue(request: Request, session: Session):
        body = await _json_object(request, {"result_id"})
        return await queue_service().add(body.get("result_id"))

    async def remove_from_queue(request: Request, session: Session):
        return await queue_service().remove(request.path_params["item_id"])

    async def requeue_item(request: Request, session: Session):
        await _json_object(request, set())
        return await queue_service().requeue(request.path_params["item_id"])

    async def start_queue(request: Request, session: Session):
        await _json_object(request, set())
        return await queue_service().start()

    async def pause_queue(request: Request, session: Session):
        await _json_object(request, set())
        return await queue_service().pause()

    async def clear_queue(request: Request, session: Session):
        await _json_object(request, set())
        return await queue_service().clear_finished()

    async def get_log(request: Request, session: Session):
        raw = request.query_params.get("after", "0")
        if not raw.isascii() or not raw.isdigit() or len(raw) > 15:
            raise ApiError("invalid_page", "after must be a non-negative integer")
        source_id = request.query_params.get("source") or None
        if source_id is not None and not SOURCE_ID_PATTERN.fullmatch(source_id):
            raise ApiError("invalid_request", "source is not a valid source ID")
        return runtime.log.page(int(raw), source_id)

    async def list_adverts(request: Request, session: Session):
        service = services().adverts
        if service is None:
            raise ApiError("engine_unavailable", "the local FServe engine is not available yet")
        return await service.list(request.path_params["source_id"])

    async def create_source(request: Request, session: Session):
        body = await _json_object(request, SOURCE_FIELDS)
        created = await services().sources.create(source_values(body))
        runtime.source_restore_pending = False
        return {"source_id": created["source_id"], **(await source_view())}

    async def put_source_by_id(request: Request, session: Session):
        body = await _json_object(request, SOURCE_FIELDS)
        await services().sources.update(
            source_values(body), request.path_params["source_id"])
        runtime.source_restore_pending = False
        return await source_view()

    async def delete_source(request: Request, session: Session):
        await services().sources.remove(request.path_params["source_id"])
        return await source_view()

    async def connect_source_by_id(request: Request, session: Session):
        await _json_object(request, set())
        await services().sources.connect(request.path_params["source_id"])
        prowlarr.forget_manual(request.path_params["source_id"])
        return await source_view()

    async def disconnect_source_by_id(request: Request, session: Session):
        await _json_object(request, set())
        await services().sources.disconnect(request.path_params["source_id"])
        prowlarr.forget_manual(request.path_params["source_id"])
        return await source_view()

    # -- searches --------------------------------------------------------

    async def create_search(request: Request, session: Session):
        body = await _json_object(request, {"terms", "source_id"})
        source_id = body.get("source_id", SOURCE_ID)
        if not isinstance(source_id, str):
            raise ApiError("invalid_request", "source_id must be a string")
        return await services().searches.search(body.get("terms"), source_id)

    # One search across several sources: a sequence of per-source searches.

    def multi():
        service = services().multi
        if service is None:
            raise ApiError("engine_unavailable", "the local FServe engine is not available yet")
        return service

    async def create_search_group(request: Request, session: Session):
        body = await _json_object(request, {"terms", "source_ids", "list_keys"})
        return await multi().start(
            body.get("terms"), body.get("source_ids"), body.get("list_keys"))

    async def list_search_groups(request: Request, session: Session):
        return {"groups": after_cutoff(await multi().history(limit=20),
                                       lambda group: group["state"] == "running")}

    async def get_search_group(request: Request, session: Session):
        return await multi().status(request.path_params["group_id"])

    async def get_search_group_results(request: Request, session: Session):
        return await multi().page(
            request.path_params["group_id"],
            offset=_query_integer(request, "offset", 0),
            limit=_query_integer(request, "limit", MAX_PAGE_SIZE),
        )

    # Stored file lists: added from a completed download or from a file put
    # in the downloads folder by hand, and searched offline.

    # -- browsing a file server --------------------------------------------

    def browses():
        service = services().browses
        if service is None:
            raise ApiError("engine_unavailable", "the local FServe engine is not available yet")
        return service

    async def start_browse(request: Request, session: Session):
        body = await _json_object(request, {"result_id", "browse_id", "path",
                                            "source_id", "nick", "trigger", "route_key"})
        if "route_key" in body:
            return await browses().start_from_list(body.get("route_key"))
        if "nick" in body:
            return await browses().start_from_advert(
                body.get("source_id"), body.get("nick"), body.get("trigger"))
        if "browse_id" in body:
            return await browses().start_from(body.get("browse_id"), body.get("path"))
        return await browses().start(body.get("result_id"))

    async def list_browses(request: Request, session: Session):
        return {"browses": await browses().history()}

    async def get_browse(request: Request, session: Session):
        if "find" in request.query_params:
            return await browses().find(request.path_params["browse_id"],
                                        request.query_params["find"])
        return await browses().view(request.path_params["browse_id"],
                                    request.query_params.get("path"))

    # -- download settings ---------------------------------------------------

    async def get_settings(request: Request, session: Session):
        return services().downloads.settings.view()

    async def put_settings(request: Request, session: Session):
        body = await _json_object(request, {"retry_before_request", "downloads_at_once"})
        return services().downloads.settings.update(body)

    # -- Prowlarr (2026-10-26): its key, and the two dialects it speaks ------

    async def get_prowlarr(request: Request, session: Session):
        return prowlarr.access.view()

    async def put_prowlarr(request: Request, session: Session):
        body = await _json_object(request, {"enabled", *prowlarr.access.SETTINGS})
        return prowlarr.access.update(body)

    async def new_prowlarr_key(request: Request, session: Session):
        await _json_object(request, set())
        return prowlarr.access.new_key()

    def xml(body: bytes) -> Response:
        return Response(body, media_type="application/xml")

    def bounded(raw: str | None, default: int, highest: int) -> int:
        if raw is None or not raw.isascii() or not raw.isdigit() or len(raw) > 6:
            return default
        return min(int(raw), highest)

    async def newznab(request: Request) -> Response:
        """Prowlarr's indexer. Its errors are Newznab's own, with HTTP 200."""
        params = request.query_params
        kind = params.get("t", "")
        try:
            if kind == "get":
                return Response(
                    prowlarr.nzb(params.get("id"), params.get("name"), params.get("sig")),
                    media_type="application/x-nzb",
                    headers={"content-disposition": 'attachment; filename="dccatlas.nzb"'})
            if not prowlarr.access.admits(params.get("apikey")):
                return xml(prowlarr.error(
                    "Incorrect user credentials" if prowlarr.access.view()["enabled"]
                    else "Prowlarr access is turned off in DCCAtlas", 100))
            if kind == "caps":
                return xml(prowlarr.caps())
            if kind in ("search", "book", "tvsearch", "movie", "music"):
                # Words to search: the query, or what the app sent in its
                # stead (Readarr an author and title, Lidarr an artist and
                # album), and for a TV episode its season and number, as file
                # names write them ("S01E02"). A search by IDs alone has no
                # words, and is answered from searches already made.
                terms = params.get("q") or " ".join(part for part in (
                    params.get("author"), params.get("title"), params.get("artist"),
                    params.get("album")) if part)
                season, episode = params.get("season", ""), params.get("ep", "")
                if kind == "tvsearch" and terms and season.isdigit() and len(season) <= 4:
                    terms += f" S{int(season):02d}"
                    if episode.isdigit() and len(episode) <= 4:
                        terms += f"E{int(episode):02d}"
                return xml(await prowlarr.feed(
                    terms=terms, categories=wanted_categories(params.get("cat")),
                    offset=bounded(params.get("offset"), 0, 100_000),
                    limit=max(1, bounded(params.get("limit"), FEED_LIMIT, FEED_LIMIT)),
                    base_url=str(request.base_url)))
            return xml(prowlarr.error("No such function", 202))
        except Refusal as exc:
            if kind not in ("caps", "get"):
                prowlarr.note(f"Prowlarr was answered with an error: {exc.message}")
            return xml(prowlarr.error(exc.message, exc.code))
        except Exception:
            logger.exception("unexpected failure answering Prowlarr's indexer request")
            prowlarr.note("Prowlarr was answered with an error: DCCAtlas failed unexpectedly")
            return xml(prowlarr.error("DCCAtlas failed unexpectedly; see its log", 900))

    async def sabnzbd(request: Request) -> Response:
        """Prowlarr's download client. Its errors are SABnzbd's own, with HTTP 200."""
        params = request.query_params
        mode = params.get("mode", "")
        try:
            if mode == "version":
                return JSONResponse({"version": SABNZBD_VERSION})
            if mode == "auth":
                return JSONResponse({"auth": "apikey"})
            if not params.get("apikey"):
                raise Refusal("API Key Required")
            if not prowlarr.access.admits(params.get("apikey")):
                raise Refusal("API Key Incorrect" if prowlarr.access.view()["enabled"]
                              else "API Key Incorrect: Prowlarr access is turned off in DCCAtlas")
            if mode == "get_config":
                return JSONResponse(prowlarr.config())
            if mode == "fullstatus":
                return JSONResponse({"status": {"completedir": prowlarr.config()[
                    "config"]["misc"]["complete_dir"]}})
            if mode == "addfile":
                found = prowlarr.nzb_from_form(request.headers.get("content-type", ""),
                                               await request.body())
                return JSONResponse(await prowlarr.add(*prowlarr.from_nzb(found),
                                                       params.get("cat")))
            if mode == "addurl":
                return JSONResponse(await prowlarr.add(*prowlarr.from_link(params.get("name")),
                                                       params.get("cat")))
            if mode in ("queue", "history"):
                if params.get("name") == "delete":
                    return JSONResponse(await prowlarr.remove(
                        params.get("value"), from_queue=mode == "queue"))
                return JSONResponse(await (prowlarr.queue() if mode == "queue"
                                           else prowlarr.history()))
            if mode == "retry":
                raise Refusal("DCCAtlas never asks for a file again by itself; send it from "
                              "Prowlarr again, or press Try again in DCCAtlas")
            raise Refusal(f"DCCAtlas does not do that ({mode or 'no mode'})")
        except Refusal as exc:
            return JSONResponse({"status": False, "error": exc.message})
        except Exception:
            logger.exception("unexpected failure answering Prowlarr's download client request")
            return JSONResponse({"status": False,
                                 "error": "DCCAtlas failed unexpectedly; see its log"})

    # -- saved searches: run again by the page through the search form ------

    def saved():
        service = services().saved
        if service is None:
            raise ApiError("engine_unavailable", "the local FServe engine is not available yet")
        return service

    async def list_saved_searches(request: Request, session: Session):
        return saved().list()

    async def save_search(request: Request, session: Session):
        body = await _json_object(request, {"terms", "source_ids", "list_keys"})
        return saved().save(body.get("terms"), body.get("source_ids"), body.get("list_keys"))

    async def remove_saved_search(request: Request, session: Session):
        return saved().remove(request.path_params["saved_id"])

    def manifests():
        service = services().manifests
        if service is None:
            raise ApiError("engine_unavailable", "the local FServe engine is not available yet")
        return service

    async def list_file_lists(request: Request, session: Session):
        return await manifests().lists()

    async def remove_file_list(request: Request, session: Session):
        return await manifests().remove(request.path_params["route_key"])

    async def dismiss_list_import(request: Request, session: Session):
        return {"imports": manifests().dismiss_import(request.path_params["operation_id"])}

    async def list_placed_files(request: Request, session: Session):
        return await manifests().placed_files()

    PLACED_FIELDS = {"path", "source_id", "sender", "trigger"}

    async def add_file_list(request: Request, session: Session):
        body = await _json_object(request, {"operation_id"} | PLACED_FIELDS)
        if "operation_id" in body:
            if PLACED_FIELDS & set(body):
                raise ApiError("invalid_request",
                               "name either a download or a file placed by hand, not both")
            return await manifests().import_download(body.get("operation_id"))
        return await manifests().import_file(
            body.get("path"), body.get("source_id"), body.get("sender"), body.get("trigger"))

    async def upload_file_list(request: Request, session: Session):
        """A list sent from the page (2026-10-28): its bytes are the body, and
        its name and whose list it is are in the query."""
        media_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        if media_type != "application/octet-stream":
            raise ApiError("unsupported_media_type", "send the file as application/octet-stream")
        query = request.query_params
        if set(query) - {"name", "source_id", "sender", "trigger"}:
            raise ApiError("invalid_request", "the request has unsupported fields")
        return await manifests().import_upload(
            request.stream(), query.get("name"), query.get("source_id"),
            query.get("sender"), query.get("trigger"))

    async def search_file_lists(request: Request, session: Session):
        body = await _json_object(request, {"query", "route_key", "cursor"})
        return await manifests().search(
            body.get("query"), body.get("route_key"), body.get("cursor"))

    # "Clear all" under Earlier searches (2026-10-29) hides what ended before
    # it was pressed. The searches are kept: a download, a queued file or an
    # app's grab may still be fetched through one of their rows.
    HISTORY_CLEARED = "search_history_cleared_at"

    def history_store() -> Any:
        settings = getattr(services().downloads, "settings", None)
        return getattr(settings, "store", None)

    def history_cutoff() -> float:
        store = history_store()
        value = store.value(HISTORY_CLEARED) if store is not None else None
        return float(value) if isinstance(value, (int, float)) else 0.0

    def after_cutoff(entries: list[dict[str, Any]], running: Callable[[dict], bool]) -> list:
        cutoff = history_cutoff()
        if not cutoff:
            return entries
        return [entry for entry in entries
                if (entry.get("started_at") or 0) > cutoff or running(entry)]

    async def list_searches(request: Request, session: Session):
        return {"searches": after_cutoff(await services().searches.history(limit=20),
                                         lambda search: search["state"] not in TERMINAL_STATES)}

    async def clear_search_history(request: Request, session: Session):
        await _json_object(request, set())
        store = history_store()
        if store is None:
            raise ApiError("engine_unavailable", "the search history is not available yet")
        store.put({HISTORY_CLEARED: time.time()})
        return {"cleared": True}

    async def get_search(request: Request, session: Session):
        return await services().searches.status(request.path_params["search_id"])

    async def get_search_results(request: Request, session: Session):
        return await services().searches.page(
            request.path_params["search_id"],
            offset=_query_integer(request, "offset", 0),
            limit=_query_integer(request, "limit", MAX_PAGE_SIZE),
        )

    # -- downloads -------------------------------------------------------

    def with_phrase(row: dict[str, Any]) -> dict[str, Any]:
        downloads = services().downloads
        phrase = (downloads.uncertain_resolution_phrase(row["operation_id"])
                  if row.get("abandonable") else None)
        return {**row, "abandon_confirmation": phrase}

    async def create_download(request: Request, session: Session):
        body = await _json_object(request, {"idempotency_key", "result_id"})
        return with_phrase(await services().downloads.download(
            body.get("idempotency_key"), body.get("result_id")))

    def servers_service():
        service = services().servers
        if service is None:
            raise ApiError("engine_unavailable", "the local FServe engine is not available yet")
        return service

    async def ask_servers(request: Request, session: Session):
        # "!list" to the source's channel (2026-10-28), at most once a minute.
        await _json_object(request, set())
        return await servers_service().ask(request.path_params["source_id"])

    async def server_answers(request: Request, session: Session):
        return await servers_service().answers(request.path_params["source_id"])

    async def request_list(request: Request, session: Session):
        # Get list beside a list server's advert (2026-10-27): "@Nick" once,
        # and the list imported as a file list when it has arrived.
        body = await _json_object(request, {"idempotency_key", "sender", "manual"})
        source_id = request.path_params["source_id"]
        adverts = services().adverts
        # A nick typed beside "!list" (2026-10-29), vouched for by the
        # operator: asked as one that announced itself would be, and the
        # engine's limits still hold.
        if body.get("manual") is True and adverts is not None:
            sender = body.get("sender")
            if not isinstance(sender, str) or not IRC_NICK.fullmatch(sender):
                raise ApiError("invalid_request", "type the list server's nickname")
            if services().sources.store.get(source_id) is None:
                raise ApiError("unknown_source", "that source is not configured")
            adverts.vouch(source_id, sender)
        # While something else runs, it waits in the queue (2026-10-29).
        queue = services().queue
        if queue is not None and await queue.list_should_wait():
            return {"queued": True, "queue": await queue.add_list(source_id, body.get("sender"))}
        operation = await services().downloads.request_list(
            body.get("idempotency_key"), source_id, body.get("sender"),
            advertised=bool(adverts and adverts.offers_list(source_id, body.get("sender"))),
            typed=bool(adverts and adverts.typed(source_id, body.get("sender"))))
        if operation["state"] not in ("failed", "stale", "cancelled"):
            manifests().follow_list(operation)
        return with_phrase(operation)

    async def list_downloads(request: Request, session: Session):
        rows = await services().downloads.history(limit=20)
        return {"downloads": [with_phrase(row) for row in rows]}

    async def get_download(request: Request, session: Session):
        return with_phrase(await services().downloads.status(
            request.path_params["operation_id"]))

    async def cancel_download(request: Request, session: Session):
        await _json_object(request, set())
        return with_phrase(await services().downloads.cancel(
            request.path_params["operation_id"]))

    async def delete_download(request: Request, session: Session):
        await services().downloads.forget(request.path_params["operation_id"])
        return {"downloads": [with_phrase(row)
                              for row in await services().downloads.history(limit=20)]}

    async def clear_downloads(request: Request, session: Session):
        await _json_object(request, set())
        cleared = await services().downloads.forget_finished()
        return {"cleared": cleared,
                "downloads": [with_phrase(row)
                              for row in await services().downloads.history(limit=20)]}

    async def retry_download(request: Request, session: Session):
        body = await _json_object(request, {"idempotency_key"})
        return with_phrase(await services().downloads.retry(
            request.path_params["operation_id"], body.get("idempotency_key")))

    async def abandon_download(request: Request, session: Session):
        body = await _json_object(request, {"confirmation"})
        return with_phrase(await services().downloads.resolve_uncertain(
            request.path_params["operation_id"], confirmation=body.get("confirmation")))

    async def healthz(request: Request) -> Response:
        # Liveness only: a disconnected IRC source or a restarting engine is
        # not a reason to restart the container.
        return JSONResponse({"status": "ok"})

    @asynccontextmanager
    async def lifespan(app: Starlette):
        await runtime.start()
        try:
            yield
        finally:
            await runtime.stop()

    routes = [
        Route("/healthz", healthz, methods=["GET"]),
        Route("/api/session", endpoint(get_session, public=True), methods=["GET"]),
        Route("/api/login", endpoint(login, public=True), methods=["POST"]),
        Route("/api/logout", endpoint(logout, public=True), methods=["POST"]),
        Route("/api/setup", endpoint(set_up, public=True), methods=["POST"]),
        Route("/api/password/reset-code", endpoint(reset_code, public=True), methods=["POST"]),
        Route("/api/password/reset", endpoint(reset_password, public=True), methods=["POST"]),
        Route("/api/password", endpoint(change_password), methods=["POST"]),
        Route("/api/status", endpoint(get_status), methods=["GET"]),
        Route("/api/source", endpoint(put_source), methods=["PUT"]),
        Route("/api/source/connect", endpoint(connect_source), methods=["POST"]),
        Route("/api/source/disconnect", endpoint(disconnect_source), methods=["POST"]),
        Route("/api/sources", endpoint(list_sources), methods=["GET"]),
        Route("/api/sources", endpoint(create_source), methods=["POST"]),
        Route("/api/sources/{source_id}", endpoint(put_source_by_id), methods=["PUT"]),
        Route("/api/sources/{source_id}", endpoint(delete_source), methods=["DELETE"]),
        Route("/api/sources/{source_id}/connect", endpoint(connect_source_by_id),
              methods=["POST"]),
        Route("/api/sources/{source_id}/disconnect", endpoint(disconnect_source_by_id),
              methods=["POST"]),
        Route("/api/sources/{source_id}/adverts", endpoint(list_adverts), methods=["GET"]),
        Route("/api/sources/{source_id}/ask-servers", endpoint(ask_servers), methods=["POST"]),
        Route("/api/sources/{source_id}/ask-servers", endpoint(server_answers),
              methods=["GET"]),
        Route("/api/sources/{source_id}/list", endpoint(request_list), methods=["POST"]),
        Route("/api/log", endpoint(get_log), methods=["GET"]),
        Route("/api/sources/{source_id}/login", endpoint(put_login), methods=["PUT"]),
        Route("/api/sources/{source_id}/login", endpoint(delete_login), methods=["DELETE"]),
        Route("/api/queue", endpoint(get_queue), methods=["GET"]),
        Route("/api/queue", endpoint(add_to_queue), methods=["POST"]),
        Route("/api/queue/start", endpoint(start_queue), methods=["POST"]),
        Route("/api/queue/pause", endpoint(pause_queue), methods=["POST"]),
        Route("/api/queue/clear", endpoint(clear_queue), methods=["POST"]),
        Route("/api/queue/{item_id}", endpoint(remove_from_queue), methods=["DELETE"]),
        Route("/api/queue/{item_id}/again", endpoint(requeue_item), methods=["POST"]),
        Route("/api/searches", endpoint(list_searches), methods=["GET"]),
        Route("/api/searches", endpoint(create_search), methods=["POST"]),
        Route("/api/searches/history/clear", endpoint(clear_search_history), methods=["POST"]),
        Route("/api/searches/{search_id}", endpoint(get_search), methods=["GET"]),
        Route("/api/searches/{search_id}/results", endpoint(get_search_results),
              methods=["GET"]),
        Route("/api/search-groups", endpoint(create_search_group), methods=["POST"]),
        Route("/api/search-groups", endpoint(list_search_groups), methods=["GET"]),
        Route("/api/search-groups/{group_id}", endpoint(get_search_group), methods=["GET"]),
        Route("/api/search-groups/{group_id}/results", endpoint(get_search_group_results),
              methods=["GET"]),
        Route("/api/settings", endpoint(get_settings), methods=["GET"]),
        Route("/api/settings", endpoint(put_settings), methods=["PUT"]),
        Route("/api/prowlarr", endpoint(get_prowlarr), methods=["GET"]),
        Route("/api/prowlarr", endpoint(put_prowlarr), methods=["PUT"]),
        Route("/api/prowlarr/key", endpoint(new_prowlarr_key), methods=["POST"]),
        Route("/newznab/api", newznab, methods=["GET"]),
        Route("/sabnzbd/api", sabnzbd, methods=["GET", "POST"]),
        Route("/api/saved-searches", endpoint(list_saved_searches), methods=["GET"]),
        Route("/api/saved-searches", endpoint(save_search), methods=["POST"]),
        Route("/api/saved-searches/{saved_id}", endpoint(remove_saved_search),
              methods=["DELETE"]),
        Route("/api/browse", endpoint(list_browses), methods=["GET"]),
        Route("/api/browse", endpoint(start_browse), methods=["POST"]),
        Route("/api/browse/{browse_id}", endpoint(get_browse), methods=["GET"]),
        Route("/api/file-lists", endpoint(list_file_lists), methods=["GET"]),
        Route("/api/file-lists", endpoint(add_file_list), methods=["POST"]),
        Route("/api/file-lists/search", endpoint(search_file_lists), methods=["POST"]),
        # The one route that takes more than a small JSON body: a list file.
        Route("/api/file-lists/upload", endpoint(upload_file_list), methods=["POST"],
              max_body_size=MAX_LIST_BYTES),
        Route("/api/file-lists/placed", endpoint(list_placed_files), methods=["GET"]),
        Route("/api/file-lists/{route_key}", endpoint(remove_file_list), methods=["DELETE"]),
        Route("/api/file-lists/imports/{operation_id}", endpoint(dismiss_list_import),
              methods=["DELETE"]),
        Route("/api/downloads", endpoint(list_downloads), methods=["GET"]),
        Route("/api/downloads", endpoint(create_download), methods=["POST"]),
        Route("/api/downloads/clear", endpoint(clear_downloads), methods=["POST"]),
        Route("/api/downloads/{operation_id}", endpoint(get_download), methods=["GET"]),
        Route("/api/downloads/{operation_id}", endpoint(delete_download), methods=["DELETE"]),
        Route("/api/downloads/{operation_id}/cancel", endpoint(cancel_download),
              methods=["POST"]),
        Route("/api/downloads/{operation_id}/retry", endpoint(retry_download),
              methods=["POST"]),
        Route("/api/downloads/{operation_id}/abandon", endpoint(abandon_download),
              methods=["POST"]),
        Mount("/", app=StaticFiles(directory=STATIC_DIRECTORY, html=True), name="static"),
    ]
    return Starlette(
        routes=routes,
        lifespan=lifespan,
        max_body_size=MAX_BODY_BYTES,
        middleware=[
            Middleware(AllowedHosts, allowed_hosts=list(settings.allowed_hosts)),
            Middleware(SecurityHeaders),
        ],
    )
