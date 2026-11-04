"""Async client for the private FServe Irssi bridge.

This module owns only the local IPC connection. It does not implement IRC/DCC,
retry an operation after a timeout, or interpret terminal output.
"""

from __future__ import annotations

import asyncio
import json
import re
import uuid
from collections import deque
from dataclasses import dataclass
from typing import Any


PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 64 * 1024
EVENT_QUEUE_SIZE = 256
ABANDONED_REQUEST_LIMIT = 256
MUTATING_OPERATIONS = frozenset({
    "source.configure", "source.connect", "source.disconnect", "source.remove",
    "search.find",
    "search.cancel", "search.download", "manifest.download", "job.cancel",
    "source.login", "searchbot.held_download", "browse.start",
    "list.request", "list.download", "list.accept",
})


class EngineProtocolError(RuntimeError):
    """The engine returned malformed or incompatible bridge data."""


class EngineRequestError(RuntimeError):
    """A well-formed request was refused by the engine."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class EngineEvent:
    sequence: int
    name: str
    payload: dict[str, Any]


class EngineClient:
    """One connected application controller for a single Irssi engine."""

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        engine_instance_id: str,
        event_sequence: int,
    ) -> None:
        self._reader = reader
        self._writer = writer
        self._engine_instance_id = engine_instance_id
        self._write_lock = asyncio.Lock()
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._abandoned: set[str] = set()
        self._abandoned_order: deque[str] = deque()
        self._reader_task: asyncio.Task[None] | None = None
        self.events: asyncio.Queue[EngineEvent] = asyncio.Queue(EVENT_QUEUE_SIZE)
        self.last_event_sequence = event_sequence
        self.needs_reconciliation = False
        self._reconciliation_watermark = 0
        self.closed = False

    @property
    def engine_instance_id(self) -> str:
        return self._engine_instance_id

    @classmethod
    async def open(cls, socket_path: str, *, timeout: float = 5.0) -> EngineClient:
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(socket_path, limit=MAX_FRAME_BYTES + 1),
            timeout=timeout,
        )
        client = cls(reader, writer, "", 0)
        request_id = uuid.uuid4().hex
        hello = {
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
            "operation": "hello",
            "arguments": {},
        }
        try:
            await client._write_record(hello)
            record = await asyncio.wait_for(client._read_record(), timeout=timeout)
            if (record.get("protocol_version") != PROTOCOL_VERSION
                    or record.get("request_id") != request_id
                    or record.get("ok") is not True
                    or not isinstance(record.get("result"), dict)):
                raise EngineProtocolError("engine bridge handshake was invalid")
            result = record["result"]
            instance_id = result.get("engine_instance_id")
            sequence = result.get("event_sequence")
            if (not isinstance(instance_id, str) or not instance_id
                    or not isinstance(sequence, int) or isinstance(sequence, bool)
                    or sequence < 0):
                raise EngineProtocolError("engine handshake omitted its identity or event cursor")
            client._engine_instance_id = instance_id
            client.last_event_sequence = sequence
            client._reader_task = asyncio.create_task(client._read_loop())
            return client
        except BaseException:
            await client.close()
            raise

    async def _write_record(self, record: dict[str, Any]) -> None:
        encoded = json.dumps(
            record, ensure_ascii=False, separators=(",", ":"),
        ).encode("utf-8") + b"\n"
        if len(encoded) > MAX_FRAME_BYTES + 1:
            raise EngineProtocolError("outgoing bridge frame exceeds the size limit")
        async with self._write_lock:
            if self.closed:
                raise ConnectionError("engine bridge is closed")
            self._writer.write(encoded)
            await self._writer.drain()

    async def _read_record(self) -> dict[str, Any]:
        try:
            line = await self._reader.readuntil(b"\n")
        except (asyncio.LimitOverrunError, asyncio.IncompleteReadError) as exc:
            raise EngineProtocolError("engine sent an incomplete or oversized frame") from exc
        if len(line) > MAX_FRAME_BYTES + 1:
            raise EngineProtocolError("engine frame exceeds the size limit")
        try:
            record = json.loads(line[:-1].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise EngineProtocolError("engine sent invalid UTF-8 JSON") from exc
        if not isinstance(record, dict):
            raise EngineProtocolError("engine frame must be a JSON object")
        return record

    async def _read_loop(self) -> None:
        failure: BaseException | None = None
        try:
            while not self.closed:
                record = await self._read_record()
                if record.get("protocol_version") != PROTOCOL_VERSION:
                    raise EngineProtocolError("engine protocol version changed")
                if record.get("type") == "event":
                    self._receive_event(record)
                    continue
                request_id = record.get("request_id")
                future = self._pending.pop(request_id, None) if isinstance(request_id, str) else None
                if future is None:
                    if isinstance(request_id, str) and request_id in self._abandoned:
                        self._abandoned.remove(request_id)
                        continue
                    raise EngineProtocolError("engine response has no matching request")
                if record.get("ok") is True and isinstance(record.get("result"), dict):
                    if not future.done():
                        future.set_result(record["result"])
                elif record.get("ok") is False and isinstance(record.get("error"), dict):
                    error = record["error"]
                    if not future.done():
                        future.set_exception(EngineRequestError(
                            str(error.get("code", "request_refused")),
                            str(error.get("message", "request refused")),
                        ))
                else:
                    raise EngineProtocolError("engine response has an invalid shape")
        except asyncio.CancelledError:
            raise
        except BaseException as exc:
            failure = exc
        finally:
            self.closed = True
            self._writer.close()
            for future in self._pending.values():
                if not future.done():
                    future.set_exception(failure or ConnectionError("engine bridge closed"))
            self._pending.clear()

    def _receive_event(self, record: dict[str, Any]) -> None:
        sequence = record.get("event_sequence")
        name = record.get("event")
        payload = record.get("payload")
        if (record.get("engine_instance_id") != self._engine_instance_id
                or not isinstance(sequence, int) or isinstance(sequence, bool)
                or sequence <= 0 or not isinstance(name, str)
                or not isinstance(payload, dict)):
            raise EngineProtocolError("engine event has an invalid identity or shape")
        if sequence != self.last_event_sequence + 1:
            self.needs_reconciliation = True
            self._reconciliation_watermark = max(
                self._reconciliation_watermark, self.last_event_sequence, sequence,
            )
        self.last_event_sequence = sequence
        try:
            self.events.put_nowait(EngineEvent(sequence, name, payload))
        except asyncio.QueueFull:
            self.needs_reconciliation = True
            self._reconciliation_watermark = max(
                self._reconciliation_watermark, sequence,
            )

    async def request(
        self,
        operation: str,
        arguments: dict[str, Any] | None = None,
        *,
        operation_id: str | None = None,
        timeout: float = 10.0,
    ) -> dict[str, Any]:
        if self.closed:
            raise ConnectionError("engine bridge is closed")
        if not isinstance(operation, str) or not re.fullmatch(r"[a-z][a-z0-9_.-]{0,63}", operation):
            raise ValueError("operation must be a valid bridge operation name")
        if arguments is None:
            arguments = {}
        elif not isinstance(arguments, dict):
            raise ValueError("arguments must be an object")
        if operation_id is None:
            if operation in MUTATING_OPERATIONS:
                raise ValueError("mutating engine requests require a stable operation_id")
        elif not isinstance(operation_id, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}", operation_id,
        ):
            raise ValueError("operation_id must be a valid string")
        request_id = uuid.uuid4().hex
        record: dict[str, Any] = {
            "protocol_version": PROTOCOL_VERSION,
            "request_id": request_id,
            "operation": operation,
            "arguments": arguments,
        }
        if operation_id is not None:
            record["operation_id"] = operation_id
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        try:
            await self._write_record(record)
        except BaseException:
            self._pending.pop(request_id, None)
            raise
        try:
            return await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError:
            pending = self._pending.pop(request_id, None)
            if pending is not None:
                self._abandoned.add(request_id)
                self._abandoned_order.append(request_id)
                while len(self._abandoned_order) > ABANDONED_REQUEST_LIMIT:
                    expired = self._abandoned_order.popleft()
                    self._abandoned.discard(expired)
            raise

    async def status(self, *, timeout: float = 10.0) -> dict[str, Any]:
        """Read engine state; callers use it to reconcile missed events."""
        result = await self.request("status", timeout=timeout)
        if result.get("engine_instance_id") != self._engine_instance_id:
            raise EngineProtocolError("status belongs to a different engine instance")
        return result

    def mark_reconciled(self, status: dict[str, Any]) -> None:
        """Acknowledge a caller-applied status snapshot and discard older events."""
        if status.get("engine_instance_id") != self._engine_instance_id:
            raise EngineProtocolError("cannot reconcile a different engine instance")
        sequence = status.get("event_sequence")
        if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 0:
            raise EngineProtocolError("status snapshot has an invalid event cursor")
        self.last_event_sequence = max(self.last_event_sequence, sequence)
        retained: list[EngineEvent] = []
        while not self.events.empty():
            event = self.events.get_nowait()
            if event.sequence > sequence:
                retained.append(event)
        for event in retained:
            self.events.put_nowait(event)
        if sequence >= self._reconciliation_watermark:
            self._reconciliation_watermark = 0
        self.needs_reconciliation = bool(self._reconciliation_watermark) or any(
            event.sequence > sequence for event in retained
        )

    async def wait_closed(self) -> None:
        """Return once the bridge connection has ended, however it ended."""
        task = self._reader_task
        if task is not None:
            await asyncio.wait({task})

    async def close(self) -> None:
        self.closed = True
        task = self._reader_task
        if task and task is not asyncio.current_task():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        self._writer.close()
        try:
            await self._writer.wait_closed()
        except (ConnectionError, OSError):
            pass
