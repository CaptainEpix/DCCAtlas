"""Stored file lists: import one the operator downloaded, and search it offline.

Some file servers publish a list of everything they hold. Searching such a
list sends nothing to IRC. This module wraps the engine project's catalog
worker (`lib/FServe/Catalog/worker.py`), which imports a list into an
immutable snapshot and searches it with bounded memory. A list gets in from
a file DCCAtlas itself downloaded, so where it came from is known (which
source, which file server, which trigger), or from a file the operator put in
the downloads folder by hand, together with those three things typed in.

A hit is not a promise that the file still exists. Downloading one goes
through the engine's ordinary direct fetch, which asks the file server for a
fresh listing of the folder before it requests anything.
"""

from __future__ import annotations

import asyncio
from collections import Counter
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, AsyncIterator
import zipfile

from .downloads import DownloadService
from .errors import ServiceError
from .ids import IRC_NICK, ROUTE_KEY, SOURCE_ID_PATTERN
from .sources import SourceService


PROJECT_ROOT = Path(__file__).resolve().parents[1]
LIBRARY = PROJECT_ROOT / "lib"
WORKER = LIBRARY / "FServe" / "Catalog" / "worker.py"
NETWORK_PREFIX = "web-source:"
# A list, unpacked, may be as large as the catalog reads (1 GiB, its hard
# limit); raised from 256 MB on 2026-10-28 for a 410 MB list. Such a list
# takes about ten times its size in disk while it is read.
MAX_LIST_BYTES = 1024 * 1024 * 1024
MAX_LIST_ROWS = 20_000_000
IMPORT_SECONDS = 1800
# A list server's list can hold a million files; one of 809,076 took some
# 13 minutes to import (2026-10-27).
LIST_IMPORT_SECONDS = 3600
# How long Get list is followed to its end before the import is given up.
LIST_FOLLOW_SECONDS = 3 * 60 * 60
LIST_FOLLOW_POLL_SECONDS = 5
QUERY_SECONDS = 20
# Looking for files placed by hand stays small however full the folder is.
MAX_PLACED_FILES = 200
MAX_FOLDERS_LOOKED_IN = 2000
MAX_FOLDER_DEPTH = 6
TRIGGER_TOKEN = re.compile(r"[^\s\x00-\x1f\x7f]{1,128}")
# A list server's row, "!Nick name  ::INFO:: size", at the start of a line;
# how far into a placed list to look for them.
POSTED_ROW = re.compile(rb"^(?:[^!|\r\n]*\|.*?\|[\t ]*)?!([^\s!|]{1,64})[\t ]+\S",
                        re.MULTILINE)
STYLE_PROBE_BYTES = 4 * 1024 * 1024
LIST_SUFFIXES = (".txt", ".zip", ".rar", ".7z")
# A list sent from the page keeps its own name: one name, no folders.
UPLOAD_NAME = re.compile(r"[^/\\\x00-\x1f\x7f]{1,200}")
# RAR and 7-Zip are unpacked with bsdtar (libarchive, which reads RAR, RAR 5
# and 7-Zip: https://github.com/libarchive/libarchive/blob/v3.7.4/README.md).
UNPACKED_BY_BSDTAR = (".rar", ".7z")
# An archive comes from whoever sent it, and bsdtar parses it: one that keeps
# bsdtar busy without end is given up after this long (2026-11-03). A list of
# a gigabyte unpacks in well under a minute.
BSDTAR_SECONDS = 600
# SysReset shows a CTCP trigger as the mIRC command, "/ctcp Nick payload"
# (lib/FServe/Discovery/SysResetFind.pm reads it the same way).
CTCP_TRIGGER = re.compile(r"/?ctcp\s+(\S+)\s+(\S+)", re.IGNORECASE)


_ENDED = frozenset({"failed", "cancelled", "expired", "stale", "refused_without_queue",
                    "abandoned_uncertain", "needs_attention"})


class ManifestError(ServiceError):
    """A stable, client-safe file-list error."""


def trigger_of(text: Any, sender: str) -> tuple[str, str]:
    """A trigger typed as a file server shows it, as (trigger, mode)."""
    if not isinstance(text, str) or not text.strip():
        raise ManifestError("invalid_trigger", "type the file server's trigger, such as !Name")
    text = text.strip()
    if re.match(r"/?ctcp(?:\s|$)", text, re.IGNORECASE):
        match = CTCP_TRIGGER.fullmatch(text)
        if not match:
            raise ManifestError("invalid_trigger", "a CTCP trigger is written /ctcp Nick trigger")
        target, payload = match.groups()
        if target.casefold() != sender.casefold():
            raise ManifestError(
                "invalid_trigger", "the CTCP trigger names another nick than the file server's")
        if not TRIGGER_TOKEN.fullmatch(payload):
            raise ManifestError("invalid_trigger", "that CTCP trigger cannot be used")
        return payload, "ctcp"
    if not TRIGGER_TOKEN.fullmatch(text):
        raise ManifestError("invalid_trigger", "a trigger is one word, such as !Name")
    # "@find" and the like are channel-wide searches: every file server in
    # the channel would answer one sent as a trigger.
    if text.startswith("@"):
        raise ManifestError(
            "invalid_trigger", "a trigger starting with @ is a search, not a file server's trigger")
    return text, "channel_text"


def _sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class ManifestService:
    adverts: Any = None   # the AdvertService, set at start-up

    def __init__(self, downloads: DownloadService, *, catalog_root: str | os.PathLike[str],
                 download_root: str | os.PathLike[str],
                 lists_root: str | os.PathLike[str] | None = None) -> None:
        self.downloads = downloads
        self.searches = downloads.searches
        self.sources: SourceService = downloads.sources
        self.engine = downloads.engine
        self.catalog_root = Path(catalog_root)
        self.download_root = Path(download_root)
        # Where the engine keeps the lists Get list receives (2026-10-28).
        self.lists_root = Path(lists_root) if lists_root is not None else None
        self._import_lock = asyncio.Lock()
        # Get list's lists, by download operation: waiting, importing, done
        # or failed, for the page (2026-10-27). Not kept over a restart; a
        # finished list can be imported again from its download.
        self.list_imports: dict[str, dict[str, Any]] = {}
        self._followers: set[asyncio.Task[Any]] = set()

    @classmethod
    def from_environment(cls, downloads: DownloadService) -> ManifestService:
        config = Path(os.environ.get("FSERVE_CONFIG_DIR", "/config"))
        return cls(downloads, catalog_root=config / "fserve" / "file-lists",
                   download_root=os.environ.get("FSERVE_DOWNLOAD_DIR", "/downloads"),
                   lists_root=config / "lists")

    # -- the catalog worker ------------------------------------------------

    async def _worker(self, command: str, *arguments: str, timeout: float) -> dict[str, Any]:
        self.catalog_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            process = await asyncio.create_subprocess_exec(
                sys.executable, "-B", str(WORKER), command,
                "--root", str(self.catalog_root), *arguments,
                stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL)
        except OSError as exc:
            raise ManifestError("catalog_unavailable", "the file-list catalog could not be started") from exc
        try:
            output, _ = await asyncio.wait_for(process.communicate(), timeout)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise ManifestError("catalog_timeout", "the file-list catalog took too long") from None
        result = error = None
        for line in output.decode("utf-8", errors="replace").splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict) and event.get("event") == "result":
                result = event
            elif isinstance(event, dict) and event.get("event") == "error":
                error = event.get("reason")
        if process.returncode or result is None:
            reason = error if isinstance(error, str) and error else "the file-list catalog failed"
            raise ManifestError("catalog_failed", reason[:300])
        return result

    # -- import --------------------------------------------------------------

    def _downloaded_file(self, relative: str, root: Path | None = None) -> Path:
        """A file that must be a plain file inside the downloads folder, or
        the root named."""
        root = (root or self.download_root).resolve()
        candidate = (root / relative)
        if candidate.is_symlink():
            raise ManifestError("invalid_file", "that is not a regular file")
        resolved = candidate.resolve()
        if root not in resolved.parents or not resolved.is_file():
            raise ManifestError("invalid_file", "that is not a file in the downloads folder")
        if resolved.stat().st_size > MAX_LIST_BYTES:
            raise ManifestError("invalid_file", "that file is too large to be a file list")
        return resolved

    async def import_download(self, operation_id: Any) -> dict[str, Any]:
        """Use a completed download as its file server's file list."""
        if not isinstance(operation_id, str):
            raise ManifestError("invalid_request", "name the download to use as a file list")
        row = self.downloads.store.get(operation_id)
        if row is None:
            raise ManifestError("unknown_operation", "download operation was not found")
        if row["state"] != "complete" or not row["download_path"] or not row["sender"]:
            raise ManifestError("invalid_file", "only a completed download can be used as a file list")
        if str(row["result_id"]).startswith("list-"):
            return await self._import_list(row)
        result = self.searches.store.find_result(row["result_id"])
        search = self.searches.store.get(row["search_id"])
        if result is None or search is None:
            raise ManifestError(
                "invalid_file",
                "the search this download came from is no longer recorded, so its file "
                "server and trigger are not known")
        mode = result["trigger_mode"]
        channel = search["channel"]
        if mode == "searchbot":
            raise ManifestError(
                "invalid_file",
                "that file came through a search bot; only a file server's own list can be used")
        if mode not in ("channel_text", "ctcp"):
            raise ManifestError("invalid_file", "that download has no usable trigger")
        # The list describes a file server on the server this source named
        # when the file was downloaded. Only an unchanged source still says
        # which server that was.
        config = self.sources.store.get(row["source_id"])
        if config is None or config.revision != row["source_revision"]:
            raise ManifestError(
                "invalid_file",
                "the source this file was downloaded through has since been changed or "
                "removed, so which server it lists is no longer certain; download the "
                "list again")
        source = self._downloaded_file(row["download_path"])
        return await self._import(
            source, config, row["sender"], result["trigger_text"], mode, channel,
            remote_path=row["remote_path"] or "/" + source.name)

    async def _import_list(self, row: dict[str, Any]) -> dict[str, Any]:
        """Use what Get list received as its list server's list (2026-10-27)."""
        config = self.sources.store.get(row["source_id"])
        if config is None or config.revision != row["source_revision"]:
            raise ManifestError(
                "invalid_file",
                "the source this list was asked through has since been changed or removed, "
                "so which server it lists is no longer certain; ask for the list again")
        # Kept in the lists folder; one received before it was, in the
        # downloads folder.
        relative = row["download_path"]
        if self.lists_root is not None and (self.lists_root / relative).is_file():
            source = self._downloaded_file(relative, self.lists_root)
        else:
            source = self._downloaded_file(relative)
        # A file server that offers its list on "@Nick" too (2026-10-29) may
        # send a listing of its files, fetched by its own trigger, rather
        # than rows to post; the file says which, as for a list added by hand.
        trigger = (self.adverts.file_server_trigger(row["source_id"], row["sender"])
                   if self.adverts is not None else None)
        if trigger is not None:
            imported = await self._import_placed(source, source.name, config, row["sender"],
                                                 trigger)
        else:
            # Rows may name the list rather than the nick, "!Nick-Ebooks2
            # name" (OmenServe, 2026-11-02): they are posted with that word.
            # A .rar or .7z is unpacked once, to look and to read.
            self.catalog_root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=self.catalog_root.parent,
                                             prefix=".unpacked-") as scratch:
                text = source
                if source.suffix.lower() in UNPACKED_BY_BSDTAR:
                    text = await asyncio.to_thread(self._list_text, source, Path(scratch))
                word = await asyncio.to_thread(self._row_word, text, row["sender"])
                imported = await self._import(
                    text, config, row["sender"], "!" + word, "channel_text",
                    config.channel, remote_path="/" + source.name, posted=True,
                    row_nick=word)
        self._remember_file(imported.get("route_key"), source)
        return imported

    async def compact(self) -> list[dict[str, Any]]:
        """Rewrite lists stored before 2026-10-28 in the compact layout, about
        a third of the space; each keeps its rows and search results."""
        if not (self.catalog_root / "catalog-registry.sqlite").exists():
            return []
        async with self._import_lock:
            result = await self._worker("compact", timeout=LIST_IMPORT_SECONDS)
        return result.get("compacted") or []

    async def remove(self, route_key: Any) -> dict[str, Any]:
        """Delete a stored list, as its Delete button on the Servers page asks
        (2026-10-29), and the file it was read from (since the same day): the
        one recorded when it was read, or, for a list read before files were
        recorded, one in the lists folder with its name or its contents."""
        if not isinstance(route_key, str) or not ROUTE_KEY.fullmatch(route_key):
            raise ManifestError("invalid_request", "that file list is not known")
        if not (self.catalog_root / "catalog-registry.sqlite").exists():
            raise ManifestError("unknown_list", "that file list is not known")
        async with self._import_lock:
            removed = await self._worker("remove", "--route-key=" + route_key,
                                         timeout=QUERY_SECONDS)
            kept = self._kept_files()
            recorded = kept.pop(route_key, [])
            self._save_kept_files(kept)
            purged = await asyncio.to_thread(self._purge_list_files, recorded, removed)
        return {**await self.lists(), "purged": purged}

    # -- the files lists were read from (2026-10-29) ------------------------------

    def _kept_files_path(self) -> Path:
        return self.catalog_root / "list-files.json"

    def _kept_files(self) -> dict[str, list[str]]:
        try:
            kept = json.loads(self._kept_files_path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return {key: [path for path in paths if isinstance(path, str)]
                for key, paths in kept.items()
                if isinstance(key, str) and isinstance(paths, list)} if isinstance(kept, dict) else {}

    def _save_kept_files(self, kept: dict[str, list[str]]) -> None:
        self.catalog_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = self._kept_files_path().with_suffix(".tmp")
        temporary.write_text(json.dumps(kept, sort_keys=True), encoding="utf-8")
        os.replace(temporary, self._kept_files_path())

    def _file_roots(self) -> list[Path]:
        roots = [self.download_root]
        roots.append(self.lists_root if self.lists_root is not None
                     else self.catalog_root.parent / "lists")
        return [root.resolve() for root in roots if root is not None]

    def _remember_file(self, route_key: Any, source: Path) -> None:
        """Note which file a list was read from, so Delete list removes it."""
        if not isinstance(route_key, str):
            return
        path = source.resolve()
        if not any(path.is_relative_to(root) for root in self._file_roots()):
            return   # a temporary copy, gone already
        kept = self._kept_files()
        paths = kept.setdefault(route_key, [])
        if str(path) not in paths:
            paths.append(str(path))
        self._save_kept_files(kept)

    def _unpacked_sha256(self, path: Path) -> str | None:
        """The fingerprint of the .txt an archive holds: a listing is read, and
        its fingerprint kept, from that, not from the archive (2026-10-29)."""
        if path.suffix.lower() not in (".zip", *UNPACKED_BY_BSDTAR):
            return None
        self.catalog_root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=self.catalog_root.parent,
                                         prefix=".purge-") as scratch:
            try:
                return _sha256_of(self._list_text(path, Path(scratch)))
            except (ManifestError, OSError):
                return None

    def _purge_list_files(self, recorded: list[str], removed: dict[str, Any]) -> list[str]:
        roots = self._file_roots()
        lists_root = roots[-1]
        candidates = {Path(path) for path in recorded}
        # A list read before its file was recorded: Get list's under its
        # server's @list folder, or one sent from the page, by name; else by
        # what it holds.
        sender = str(removed.get("server_nick") or "").casefold()
        sources = [item for item in removed.get("sources") or [] if isinstance(item, dict)]
        names = {PurePosixPath(str(item["remote_path"])).name for item in sources
                 if item.get("remote_path")}
        digests = {str(item.get("sha256")) for item in sources}
        if lists_root.is_dir():
            for path in lists_root.rglob("*"):
                if (not path.is_file() or path.is_symlink()
                        or path.suffix.lower() not in LIST_SUFFIXES):
                    continue
                if path.name in names and (
                        path.parent.name == "uploaded" or
                        (path.parent.name == "@list" and path.parent.parent.name.casefold() == sender)):
                    candidates.add(path)
                elif path.stat().st_size <= MAX_LIST_BYTES and (
                        _sha256_of(path) in digests or self._unpacked_sha256(path) in digests):
                    candidates.add(path)
        purged = []
        for path in sorted(candidates):
            resolved = path.resolve()
            if (not any(resolved.is_relative_to(root) for root in roots) or path.is_symlink()
                    or not resolved.is_file()):
                continue
            try:
                resolved.unlink()
            except OSError:
                continue
            purged.append(resolved.name)
            # Get list's <network>/<Nick>/@list folders go once empty.
            parent = resolved.parent
            while parent != lists_root and parent.is_relative_to(lists_root):
                try:
                    parent.rmdir()
                except OSError:
                    break
                parent = parent.parent
        return purged

    def dismiss_import(self, operation_id: Any) -> list[dict[str, Any]]:
        """Forget a finished list's report, as the page's close button asks."""
        entry = self.list_imports.get(operation_id) if isinstance(operation_id, str) else None
        if entry is None:
            raise ManifestError("unknown_operation", "that notice is not shown")
        if entry["state"] not in ("done", "failed"):
            raise ManifestError("not_finished", "the list is still being read")
        del self.list_imports[operation_id]
        return self.imports()

    def follow_list(self, operation: dict[str, Any]) -> None:
        """Import a Get list's list once it has arrived, in the background."""
        operation_id = operation["operation_id"]
        if operation_id in self.list_imports:
            return
        self.list_imports[operation_id] = {
            "operation_id": operation_id, "sender": operation.get("sender"),
            "state": "waiting", "reason": None, "files": None, "updated_at": time.time(),
        }
        task = asyncio.create_task(self._follow(operation_id))
        self._followers.add(task)
        task.add_done_callback(self._followers.discard)

    def _set_import(self, operation_id: str, **values: Any) -> None:
        entry = self.list_imports.get(operation_id)
        if entry is not None:
            entry.update(values, updated_at=time.time())

    async def _follow(self, operation_id: str) -> None:
        deadline = time.monotonic() + LIST_FOLLOW_SECONDS
        while True:
            try:
                row = await self.downloads.status(operation_id)
            except Exception:
                row = None
            if row is not None and row["state"] == "complete":
                break
            if row is not None and row["state"] in _ENDED:
                self._set_import(operation_id, state="failed",
                                 reason=row.get("reason") or "the list did not arrive")
                return
            if time.monotonic() > deadline:
                self._set_import(operation_id, state="failed",
                                 reason="the list did not arrive within three hours")
                return
            await asyncio.sleep(LIST_FOLLOW_POLL_SECONDS)
        self._set_import(operation_id, state="importing")
        try:
            imported = await self.import_download(operation_id)
        except ManifestError as exc:
            self._set_import(operation_id, state="failed", reason=exc.message)
            return
        self._set_import(operation_id, state="done", files=imported.get("files"))

    def _placed_file(self, relative: Any) -> Path:
        """A list put in the downloads folder by hand, a .txt or an archive
        (.zip, .rar, .7z) holding one, named by its path there."""
        if not isinstance(relative, str) or not 1 <= len(relative) <= 1024:
            raise ManifestError("invalid_file", "name a file in the downloads folder")
        path = PurePosixPath(relative)
        if (path.is_absolute() or "\\" in relative
                or any(part in ("", ".", "..") or part.startswith(".") for part in path.parts)
                or any(ord(char) < 32 or ord(char) == 127 for char in relative)):
            # A dot folder holds what the engine is still receiving.
            raise ManifestError("invalid_file", "that is not a file in the downloads folder")
        if path.suffix.lower() not in LIST_SUFFIXES:
            raise ManifestError("invalid_file",
                                "a file list is a .txt file, or a .zip, .rar or .7z holding one")
        return self._downloaded_file(relative)

    def _placed_files(self) -> dict[str, Any]:
        root = self.download_root.resolve()
        found: list[dict[str, Any]] = []
        folders = 0
        complete = True
        for folder, subfolders, names in os.walk(root, followlinks=False):
            folders += 1
            depth = len(Path(folder).relative_to(root).parts)
            # Folders whose names start with a dot hold what is still arriving.
            if depth < MAX_FOLDER_DEPTH:
                subfolders[:] = sorted(name for name in subfolders if not name.startswith("."))
            else:
                subfolders[:] = []
            for name in sorted(names):
                if name.startswith(".") or not name.lower().endswith(LIST_SUFFIXES):
                    continue
                try:
                    info = os.lstat(os.path.join(folder, name))
                except OSError:
                    continue
                if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_LIST_BYTES:
                    continue
                if len(found) == MAX_PLACED_FILES:
                    return {"files": found, "complete": False}
                found.append({
                    "path": (Path(folder).relative_to(root) / name).as_posix(),
                    "bytes": info.st_size, "modified_at": int(info.st_mtime),
                })
            if folders >= MAX_FOLDERS_LOOKED_IN:
                complete = False
                break
        return {"files": found, "complete": complete}

    async def placed_files(self) -> dict[str, Any]:
        """The .txt files and archives in the downloads folder, the candidates
        for a list added by hand."""
        if not self.download_root.is_dir():
            return {"files": [], "complete": True}
        return await asyncio.to_thread(self._placed_files)

    async def import_file(self, relative: Any, source_id: Any, sender: Any,
                          trigger: Any) -> dict[str, Any]:
        """Use a file placed in the downloads folder as the list of the file server named.

        Nothing checks that the file is that server's list. What is typed
        here decides which nick a download from it asks, with which trigger,
        and the fresh listing before the GET decides whether a file is there.
        """
        config, sender = self._placed_target(source_id, sender)
        source = self._placed_file(relative)
        imported = await self._import_placed(source, source.name, config, sender, trigger)
        self._remember_file(imported.get("route_key"), source)
        return imported

    def upload_root(self) -> Path:
        """Where lists sent from the page are kept, with the lists Get list keeps."""
        lists = self.lists_root if self.lists_root is not None else self.catalog_root.parent / "lists"
        return lists / "uploaded"

    async def import_upload(self, chunks: AsyncIterator[bytes], name: Any, source_id: Any,
                            sender: Any, trigger: Any) -> dict[str, Any]:
        """Use a file sent from the page as the list of the file server named
        (2026-10-28), as a file placed in the downloads folder is used.

        It is kept, once read, under its own name in the lists folder; one
        sent again under the same name takes the old one's place. One that
        cannot be read is not kept.
        """
        config, sender = self._placed_target(source_id, sender)
        if (not isinstance(name, str) or not UPLOAD_NAME.fullmatch(name)
                or name.startswith(".") or name.strip() != name):
            raise ManifestError("invalid_file", "the file's name cannot be used")
        suffix = PurePosixPath(name).suffix.lower()
        if suffix not in LIST_SUFFIXES:
            raise ManifestError("invalid_file",
                                "a file list is a .txt file, or a .zip, .rar or .7z holding one")
        root = self.upload_root()
        root.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(dir=root, prefix=".upload-", suffix=suffix)
        received = Path(temporary)
        try:
            written = 0
            with os.fdopen(handle, "wb") as out:
                async for chunk in chunks:
                    written += len(chunk)
                    if written > MAX_LIST_BYTES:
                        raise ManifestError("invalid_file", "that file is too large to be a file list")
                    await asyncio.to_thread(out.write, chunk)
            if not written:
                raise ManifestError("invalid_file", "that file is empty")
            imported = await self._import_placed(received, name, config, sender, trigger)
            os.replace(received, root / name)
            self._remember_file(imported.get("route_key"), root / name)
            return imported
        finally:
            received.unlink(missing_ok=True)

    def _placed_target(self, source_id: Any, sender: Any) -> tuple[Any, str]:
        """The source and file server nick typed for a list added by hand."""
        if (not isinstance(source_id, str)
                or not SOURCE_ID_PATTERN.fullmatch(source_id)):
            raise ManifestError("invalid_request", "pick the source the file server is on")
        config = self.sources.store.get(source_id)
        if config is None:
            raise ManifestError("unknown_source", "that source is not configured")
        if not isinstance(sender, str) or not IRC_NICK.fullmatch(sender.strip()):
            raise ManifestError("invalid_sender", "type the file server's nickname")
        return config, sender.strip()

    async def _import_placed(self, source: Path, name: str, config: Any, sender: str,
                             trigger: Any) -> dict[str, Any]:
        """Read a list added by hand, kept at source under the name given."""
        # Since 2026-10-28 the file says which kind of list it is: rows
        # "!Nick name" naming the nick typed make it a list server's list,
        # read as Get list reads one (its files are fetched by posting their
        # rows, so no trigger is needed); anything else is a file server's
        # listing, read as before. A zip holds one .txt.
        self.catalog_root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=self.catalog_root.parent,
                                         prefix=".placed-") as scratch:
            text = await asyncio.to_thread(self._list_text, source, Path(scratch))
            style, other = await asyncio.to_thread(self._list_style, text, sender)
            if style == "posted":
                # The nick as its own rows write it, so the list is the same one
                # however it was typed, and the same as Get list's; rows naming
                # the list ("!Nick-Ebooks2", 2026-11-02) are posted so.
                nick = other[:len(sender)]
                return await self._import(source, config, nick, "!" + other, "channel_text",
                                          config.channel, remote_path="/" + name,
                                          posted=True, row_nick=other)
            if other is not None:
                raise ManifestError(
                    "invalid_sender",
                    f"this is a list server's list, and its rows are for !{other}, not "
                    f"!{sender}: type {other} as the file server's nickname")
            trigger_text, mode = trigger_of(trigger, sender)
            return await self._import(text, config, sender, trigger_text, mode, config.channel,
                                      remote_path=None)

    @staticmethod
    def _list_text(source: Path, scratch: Path) -> Path:
        """The list itself: the file, or the one .txt an archive holds, unpacked
        into scratch, no larger than a list may be."""
        suffix = source.suffix.lower()
        if suffix in UNPACKED_BY_BSDTAR:
            return ManifestService._unpack_with_bsdtar(source, scratch)
        if suffix != ".zip":
            return source
        try:
            with zipfile.ZipFile(source) as archive:
                members = [member for member in archive.infolist()
                           if not member.is_dir() and member.filename.lower().endswith(".txt")]
                if len(members) != 1:
                    raise ManifestError("invalid_file",
                                        "the .zip must hold exactly one .txt file list")
                member = members[0]
                if member.flag_bits & 0x1:
                    raise ManifestError("invalid_file", "the .zip is protected by a password")
                target = scratch / "list.txt"
                written = 0
                with archive.open(member) as packed, open(target, "wb") as out:
                    while chunk := packed.read(1 << 20):
                        written += len(chunk)
                        # Counted as it unpacks: the size the zip claims is
                        # not trusted.
                        if written > MAX_LIST_BYTES:
                            raise ManifestError("invalid_file",
                                                "the list in that .zip is too large")
                        out.write(chunk)
                return target
        except (zipfile.BadZipFile, NotImplementedError, OSError, EOFError) as exc:
            raise ManifestError("invalid_file", "that .zip could not be read") from exc

    @staticmethod
    def _unpack_with_bsdtar(source: Path, scratch: Path) -> Path:
        """The one .txt a .rar or .7z holds, unpacked with bsdtar into scratch,
        its size counted as it unpacks; other files in it are left."""
        kind = source.suffix.lower()
        try:
            listed = subprocess.run(["bsdtar", "-tf", str(source)], capture_output=True,
                                    timeout=60, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ManifestError("invalid_file", f"that {kind} could not be read") from exc
        if listed.returncode != 0:
            raise ManifestError("invalid_file", f"that {kind} could not be read")
        everything = listed.stdout.decode("utf-8", "replace").splitlines()
        if not everything:
            raise ManifestError("invalid_file", f"that {kind} could not be read, or is empty")
        names = [name for name in everything
                 if name.lower().endswith(".txt") and not name.endswith("/")]
        if len(names) != 1:
            raise ManifestError("invalid_file", f"the {kind} must hold exactly one .txt file list")
        # bsdtar reads a member's name as a pattern: its wildcards are escaped.
        pattern = re.sub(r"([\\*?\[])", r"\\\1", names[0])
        target = scratch / "list.txt"
        written = 0
        process = subprocess.Popen(["bsdtar", "-xOf", str(source), "--", pattern],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        # Killed, its output ends, the read below returns and the wait fails.
        deadline = threading.Timer(BSDTAR_SECONDS, process.kill)
        deadline.daemon = True
        deadline.start()
        try:
            with open(target, "wb") as out:
                while chunk := process.stdout.read(1 << 20):
                    written += len(chunk)
                    if written > MAX_LIST_BYTES:
                        raise ManifestError("invalid_file",
                                            f"the list in that {kind} is too large")
                    out.write(chunk)
            if process.wait(timeout=60) != 0 or written == 0:
                raise ManifestError("invalid_file", f"that {kind} could not be read")
        finally:
            deadline.cancel()
            if process.poll() is None:
                process.kill()
                process.wait()
        return target

    @staticmethod
    def _list_style(text: Path, sender: str) -> tuple[str, str | None]:
        """("posted", the nick as the rows write it) when rows name the nick
        typed; else ("listing", the nick the rows name) when they look like
        another server's list, or ("listing", None)."""
        with open(text, "rb") as handle:
            head = handle.read(STYLE_PROBE_BYTES)
        return ManifestService._style_of(head, sender)

    @staticmethod
    def _style_of(head: bytes, sender: str) -> tuple[str, str | None]:
        written: dict[str, str] = {}
        counts: Counter[str] = Counter()
        for match in POSTED_ROW.finditer(head):
            nick = match.group(1).decode("utf-8", "replace")
            written.setdefault(nick.casefold(), nick)
            counts[nick.casefold()] += 1
        if counts.get(sender.casefold()):
            return "posted", written[sender.casefold()]
        # OmenServe names a list "<Nick>-<list name>" and writes that in each
        # row (2026-11-02); the nick's own rows come first.
        named = Counter({nick: count for nick, count in counts.items()
                         if nick.startswith(sender.casefold() + "-") and count >= 2})
        if named:
            return "posted", written[named.most_common(1)[0][0]]
        # Two rows are enough: a file server's listing has no line that starts
        # "!Nick name".
        if counts:
            nick, count = counts.most_common(1)[0]
            if count >= 2:
                return "listing", written[nick]
        return "listing", None

    @staticmethod
    def _row_word(text: Path, sender: str) -> str:
        """The word a list server's rows start with, from the start of its
        list (a .txt, or a .zip of one): its nick, the list's name,
        "Nick-Ebooks2", where the rows name that (2026-11-02), or another
        word nearly every row starts with, the server's own trigger
        ("!Tome", 2026-11-03). Get list took the list from
        the nick, so its files are still taken only from the nick."""
        try:
            if zipfile.is_zipfile(text):
                with zipfile.ZipFile(text) as archive:
                    members = [member for member in archive.infolist()
                               if not member.is_dir()
                               and member.filename.lower().endswith(".txt")]
                    if len(members) != 1:
                        return sender   # the reader says what is wrong with it
                    with archive.open(members[0]) as packed:
                        head = packed.read(STYLE_PROBE_BYTES)
            else:
                with open(text, "rb") as handle:
                    head = handle.read(STYLE_PROBE_BYTES)
        except (OSError, RuntimeError, NotImplementedError, zipfile.BadZipFile):
            return sender
        style, word = ManifestService._style_of(head, sender)
        # As the rows write it: that is what is posted back.
        if style == "posted" and word:
            return word
        counts = Counter(match.group(1) for match in POSTED_ROW.finditer(head))
        if counts:
            other, count = counts.most_common(1)[0]
            if count >= 2 and count * 10 >= sum(counts.values()) * 9:
                return other.decode("utf-8", "replace")
        return sender

    async def _import(self, source: Path, config: Any, sender: str, trigger: str, mode: str,
                      channel: str, *, remote_path: str | None,
                      posted: bool = False, row_nick: str | None = None) -> dict[str, Any]:
        context = {
            "network_id": NETWORK_PREFIX + config.source_id,
            "server_tag": self._server_of(config),
            "server_nick": sender, "trigger_raw": trigger, "trigger_mode": mode,
            "discovery_channel": channel if mode == "channel_text" else "",
            "manifest_remote_path": remote_path,
        }
        # A list server's list: its rows are posted back, not asked for in a
        # session, and it has a reader of its own (2026-10-27).
        if posted:
            context["list_format"] = "posted"
            if row_nick is not None and row_nick.casefold() != sender.casefold():
                context["row_nick"] = row_nick
        profile = ("posted:" + channel if posted
                   else "ctcp" if mode == "ctcp" else "channel:" + channel)
        seconds = LIST_IMPORT_SECONDS if posted else IMPORT_SECONDS
        # A .rar or .7z (some list servers send their list so) is unpacked
        # first; the readers take a .txt or a .zip.
        with tempfile.TemporaryDirectory(dir=self.catalog_root.parent,
                                         prefix=".unpacked-") as scratch:
            if source.suffix.lower() in UNPACKED_BY_BSDTAR:
                source = await asyncio.to_thread(self._list_text, source, Path(scratch))
            async with self._import_lock:
                imported = await self._worker(
                    "import", "--source", str(source),
                    "--context-json", json.dumps(context, separators=(",", ":")),
                    "--perl", "perl", "--library", str(LIBRARY),
                    "--root-profile", profile,
                    "--max-source-bytes", str(MAX_LIST_BYTES),
                    "--max-rows", str(MAX_LIST_ROWS),
                    "--max-seconds", str(seconds),
                    timeout=seconds)
        if not imported.get("records"):
            raise ManifestError("invalid_file", "no file entries were recognised in that file")
        return {"route_key": imported.get("route_key"), "files": imported.get("records"),
                "lists": (await self.lists())["lists"]}

    # -- reading -------------------------------------------------------------

    @staticmethod
    def _server_of(config: Any) -> str:
        return f"{config.host}:{config.port}".casefold()

    def _source_of(self, network_id: Any, server: Any) -> tuple[str | None, str | None]:
        """The source a list belongs to, and that source's label.

        The label is None when the list can no longer be used: its source was
        removed, or now names a different server than the one the list came
        from. A list added before the server was recorded carries its network
        ID there instead, and is taken on trust.
        """
        if not isinstance(network_id, str) or not network_id.startswith(NETWORK_PREFIX):
            return None, None
        source_id = network_id[len(NETWORK_PREFIX):]
        config = self.sources.store.get(source_id)
        if config is None or server not in (self._server_of(config), network_id.casefold()):
            return source_id, None
        return source_id, config.label

    def imports(self) -> list[dict[str, Any]]:
        """Get list's lists still arriving or importing, and the last day's ended ones."""
        now = time.time()
        for key in [key for key, entry in self.list_imports.items()
                    if entry["state"] in ("done", "failed") and now - entry["updated_at"] > 86400]:
            del self.list_imports[key]
        return sorted(self.list_imports.values(), key=lambda entry: -entry["updated_at"])

    async def lists(self) -> dict[str, Any]:
        if not (self.catalog_root / "catalog-registry.sqlite").exists():
            return {"lists": [], "imports": self.imports()}
        routes = (await self._worker("routes", timeout=QUERY_SECONDS)).get("routes") or []
        lists = []
        for route in routes:
            source_id, label = self._source_of(route.get("network_id"), route.get("server_tag"))
            profile = str(route.get("root_profile") or "")
            lists.append({
                "route_key": route.get("route_key"), "source_id": source_id,
                # None: the source was removed or now names another server
                "source_label": label,
                "sender": route.get("server_nick"), "trigger": route.get("trigger_raw"),
                "files": route.get("row_count"), "listed_at": route.get("observed_at"),
                "posted": profile.startswith("posted:"),
                # How its file server is asked: a list server posts rows.
                "trigger_mode": ("posted" if profile.startswith("posted:")
                                 else "ctcp" if profile == "ctcp" else "channel_text"),
            })
        return {"lists": lists, "imports": self.imports()}

    async def search(self, query: Any, route_key: Any = None, cursor: Any = None) -> dict[str, Any]:
        if (not isinstance(query, str) or not 3 <= len(query.strip()) <= 200
                or any(ord(char) < 32 or ord(char) == 127 for char in query)):
            raise ManifestError("invalid_query", "type at least three characters of a file name")
        arguments = ["--query=" + query.strip()]
        if route_key is not None:
            if not isinstance(route_key, str) or not ROUTE_KEY.fullmatch(route_key):
                raise ManifestError("invalid_request", "that file list is not known")
            arguments += ["--route-key=" + route_key]
        if cursor is not None:
            if not isinstance(cursor, str) or not 1 <= len(cursor) <= 4096:
                raise ManifestError("invalid_request", "that page is not available")
            arguments += ["--cursor=" + cursor]
        if not (self.catalog_root / "catalog-registry.sqlite").exists():
            raise ManifestError("no_lists", "no file list has been added yet")
        page = await self._worker("search", *arguments, timeout=QUERY_SECONDS)
        modes = {item.get("mode") for item in page.get("endpoint_modes") or []
                 if isinstance(item, dict)}
        results = []
        for row in page.get("rows") or []:
            source_id, label = self._source_of(row.get("network_id"), row.get("server_tag"))
            token = row.get("token")
            usable = (isinstance(token, str) and re.fullmatch(r"[0-9a-f]{64}", token)
                      and label is not None and len(modes) == 1)
            results.append({
                "result_id": "mrow-" + token if usable else None,
                "selection_available": bool(usable),
                "path": row.get("path"), "sender": row.get("server_nick"),
                "trigger": row.get("trigger_raw"),
                "size_text": row.get("size_raw"), "size_bytes": row.get("size_bytes"),
                "size_precision": row.get("size_precision"),
                "source_id": source_id, "source_label": label,
            })
        return {"query": page.get("query"), "route_key": page.get("route_key"),
                "results": results, "has_more": bool(page.get("has_more")),
                "next_cursor": page.get("next_cursor")}

    # -- handing a hit to the download service -------------------------------

    async def resolve_result(self, result_id: str) -> dict[str, Any]:
        """What the engine needs to fetch one hit, after checking it is still listed."""
        token = result_id[len("mrow-"):]
        try:
            found = await self._worker("resolve", "--selection=" + token, timeout=QUERY_SECONDS)
        except ManifestError as exc:
            raise ManifestError("stale_result", exc.message) from exc
        source_id, label = self._source_of(found.get("network_id"), found.get("server_tag"))
        config = self.sources.store.get(source_id) if source_id else None
        if config is None:
            raise ManifestError("stale_result", "the source this file list came from was removed")
        if label is None:
            raise ManifestError(
                "stale_result",
                "the source now names a different server than the one this file list came from")
        profile = found.get("root_profile")
        posted = str(profile).startswith("posted:")
        mode = "ctcp" if profile == "ctcp" else "channel_text"
        if mode == "channel_text" and profile != ("posted:" if posted else "channel:") + config.channel:
            raise ManifestError(
                "stale_result", "the source's channel changed since this file list was added")
        try:
            status = await self.engine.status()
        except Exception as exc:
            raise ManifestError("engine_unavailable", "the local FServe engine is unavailable") from exc
        live = self.sources.engine_source(status, source_id)
        if not self.sources._matches(live, config) or live.get("state") != "ready":
            raise ManifestError("source_not_ready", "connect that source before downloading from its file list")
        route = str(found.get("route_key") or "")
        if posted:
            # A list server's file is asked for by posting its row back
            # (2026-10-27); the engine builds the row from these.
            arguments = {"source_id": source_id, "sender": found.get("server_nick"),
                         "name": PurePosixPath(str(found.get("path"))).name}
            # Rows that name the list, "!Nick-Ebooks2 name" (2026-11-02).
            word = str(found.get("trigger_raw") or "")[1:]
            if word.casefold() != str(found.get("server_nick") or "").casefold():
                arguments["list_name"] = word
            if found.get("size_raw"):
                arguments["size_raw"] = found.get("size_raw")
            return {
                "search_id": "file-list-" + route[:32],
                "source_id": source_id, "source_revision": config.revision,
                "engine_instance_id": self.engine.engine_instance_id,
                "engine_search_id": "file-list", "engine_operation": "list.download",
                "engine_arguments": arguments, "posted": True,
                "remote_path": found.get("path"), "size_bytes": found.get("size_bytes"),
            }
        return {
            "search_id": "file-list-" + route[:32],
            "source_id": source_id, "source_revision": config.revision,
            "engine_instance_id": self.engine.engine_instance_id,
            "engine_search_id": "file-list",
            "engine_operation": "manifest.download",
            "engine_arguments": {
                "source_id": source_id, "sender": found.get("server_nick"),
                "trigger": found.get("trigger_raw"), "trigger_mode": mode,
                "path": found.get("path"),
            },
        }


__all__ = ["ManifestError", "ManifestService"]
