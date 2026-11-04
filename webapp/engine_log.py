"""The connection log: the engine's log lines, kept here for the page.

The engine keeps its last thousand lines in memory and lists them with
log.list: what the managed connections' servers send to this client, what
the engine sends, Irssi's own notices and errors, and each source's state.
This copies them every two seconds into a bounded list the page reads, and
prints each one to standard output, which `docker logs` keeps. Given a file,
the list is also saved there, next to the database, and read back when the
web service starts, so a restart keeps it; the file is capped at two parts of
1 MB. Copying only reads the engine; nothing is sent to IRC.
"""

from __future__ import annotations

import asyncio
from collections import deque
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any, Callable, TextIO

from .engine_client import EngineClient, EngineProtocolError, EngineRequestError


POLL_SECONDS = 2.0
KEEP_LINES = 2000
ENGINE_PAGE_LINES = 200
API_PAGE_LINES = 500
TEXT_CHARS = 400
KINDS = frozenset({"received", "sent", "irssi", "error", "state", "engine", "web"})
FILE_PART_BYTES = 1024 * 1024   # the saved log moves to its ".1" part past this
_CONTROL = re.compile(r"[\x00-\x1f\x7f]+")


def _clean(text: Any) -> str:
    return _CONTROL.sub(" ", str(text)).strip()[:TEXT_CHARS]


class LogBook:
    """The lines kept for the page, newest last, each with its own id."""

    def __init__(self, keep: int = KEEP_LINES, out: TextIO | None = None,
                 path: str | os.PathLike[str] | None = None) -> None:
        self._lines: deque[dict[str, Any]] = deque(maxlen=keep)
        self._next_id = 1
        self._out = out
        # How far each engine instance's log has been copied.
        self.copied: dict[str, int] = {}
        self._path = Path(path) if path is not None else None
        if self._path is not None and self._load():
            self.add("web", "DCCAtlas started again; the lines above are from before")

    def _load(self) -> bool:
        """Read the saved log back; a damaged line is skipped."""
        assert self._path is not None
        loaded = False
        for part in (self._path.with_name(self._path.name + ".1"), self._path):
            try:
                with open(part, encoding="utf-8") as handle:
                    rows = handle.readlines()
            except OSError:
                continue
            for raw in rows:
                try:
                    saved = json.loads(raw)
                    line = {"id": int(saved["id"]), "time": float(saved["time"]),
                            "kind": saved["kind"], "text": _clean(saved["text"]),
                            "source_ids": [str(item) for item in saved["source_ids"]][:8],
                            "labels": [_clean(item) for item in saved["labels"]][:8]}
                except (ValueError, KeyError, TypeError):
                    continue
                if line["kind"] not in KINDS or line["id"] < self._next_id:
                    continue
                self._lines.append(line)
                self._next_id = line["id"] + 1
                loaded = True
                engine, seq = saved.get("engine"), saved.get("seq")
                if isinstance(engine, str) and isinstance(seq, int):
                    self.copied[engine] = max(self.copied.get(engine, 0), seq)
        return loaded

    def _save(self, line: dict[str, Any], origin: tuple[str, int] | None) -> None:
        assert self._path is not None
        record = dict(line)
        if origin is not None:
            record["engine"], record["seq"] = origin
        try:
            if self._path.exists() and self._path.stat().st_size >= FILE_PART_BYTES:
                os.replace(self._path, self._path.with_name(self._path.name + ".1"))
            descriptor = os.open(self._path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(descriptor, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        except OSError:
            pass   # the page and docker logs still have the line

    def add(self, kind: str, text: Any, *, source_ids: list[str] | tuple[str, ...] = (),
            labels: dict[str, str] | None = None, at: float | None = None,
            origin: tuple[str, int] | None = None) -> None:
        """Keep a line. Origin is the engine instance and sequence it was copied from."""
        text = _clean(text)
        if not text or kind not in KINDS:
            return
        ids = [str(item) for item in source_ids][:8]
        line = {
            "id": self._next_id,
            "time": at if at is not None else time.time(),
            "kind": kind,
            "source_ids": ids,
            "labels": [_clean((labels or {}).get(item, item)) for item in ids],
            "text": text,
        }
        self._next_id += 1
        self._lines.append(line)
        if self._path is not None:
            self._save(line, origin)
        out = self._out if self._out is not None else sys.stdout
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(line["time"]))
        where = f" [{', '.join(line['labels'])}]" if line["labels"] else ""
        try:
            print(f"[log] {stamp} {kind}{where}: {text}", file=out, flush=True)
        except (OSError, ValueError):
            pass

    def page(self, after: int = 0, source_id: str | None = None,
             limit: int = API_PAGE_LINES) -> dict[str, Any]:
        """Lines after an id. For one source, lines tied to no source are kept
        too: an error such as a TLS failure names no server."""
        lines = []
        more = False
        for line in self._lines:
            if line["id"] <= after:
                continue
            if source_id is not None and line["source_ids"] and source_id not in line["source_ids"]:
                continue
            if len(lines) >= limit:
                more = True
                break
            lines.append(dict(line))
        return {
            "lines": lines,
            "more": more,
            "last_id": self._next_id - 1,
            "first_id": self._lines[0]["id"] if self._lines else self._next_id,
        }


def _number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


class LogCopier:
    """Copies one engine connection's log into a LogBook until cancelled."""

    def __init__(self, book: LogBook, client: EngineClient,
                 labels: Callable[[], dict[str, str]]) -> None:
        self.book = book
        self.client = client
        self.labels = labels

    async def run(self) -> None:
        instance = self.client.engine_instance_id
        while not self.client.closed:
            try:
                await self.copy_once(instance)
            except EngineRequestError as exc:
                if exc.code == "unsupported_operation":
                    return   # an engine from before the log
            except (ConnectionError, asyncio.TimeoutError, EngineProtocolError):
                return
            await asyncio.sleep(POLL_SECONDS)

    async def copy_once(self, instance: str) -> None:
        for _ in range(20):
            after = self.book.copied.get(instance, 0)
            page = await self.client.request(
                "log.list", {"after": after, "limit": ENGINE_PAGE_LINES})
            if not isinstance(page, dict) or not isinstance(page.get("lines"), list):
                return
            first = page.get("first_seq")
            if after and isinstance(first, int) and first > after + 1:
                self.book.add("web", f"{first - after - 1} engine log lines were dropped "
                              "before they could be copied")
            raw = [line for line in page["lines"] if isinstance(line, dict)
                   and isinstance(line.get("seq"), int) and line["seq"] > after]
            if not raw:
                if isinstance(page.get("last_seq"), int) and page["last_seq"] > after:
                    self.book.copied[instance] = page["last_seq"]
                return
            # Times are taken relative to the engine's own clock.
            shift = time.time() - page["now"] if _number(page.get("now")) else 0.0
            labels = self.labels()
            for line in raw:
                ids = line.get("source_ids")
                ids = [item for item in ids if isinstance(item, str)] if isinstance(ids, list) else []
                at = line["time"] + shift if _number(line.get("time")) else None
                self.book.copied[instance] = line["seq"]
                self.book.add(line.get("kind") if line.get("kind") in KINDS else "engine",
                              line.get("text", ""), source_ids=ids, labels=labels, at=at,
                              origin=(instance, line["seq"]))
            if page.get("more") is not True:
                return
