"""Bounded fan-out for live portal events and Server-Sent Events."""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from collections.abc import AsyncIterator
from dataclasses import dataclass


@dataclass(frozen=True)
class Event:
    sequence: int
    kind: str
    payload: dict
    created_at: float


class TooManySubscribers(RuntimeError):
    pass


class EventBroker:
    """A bounded best-effort live feed; durable audit data belongs in the database."""

    def __init__(self, *, max_subscribers: int = 32, queue_size: int = 64):
        if not 1 <= max_subscribers <= 1024 or not 2 <= queue_size <= 1024:
            raise ValueError("Invalid event broker limits.")
        self.max_subscribers = max_subscribers
        self.queue_size = queue_size
        self._subscribers: dict[str, asyncio.Queue[Event]] = {}
        self._sequence = 0
        self.dropped_events = 0

    @property
    def subscriber_count(self) -> int:
        return len(self._subscribers)

    def publish(self, kind: str, payload: dict) -> Event:
        if not kind or len(kind) > 64 or any(character in kind for character in "\r\n"):
            raise ValueError("Invalid event type.")
        # Serialising here rejects non-JSON payloads before they poison every subscriber.
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
        if len(encoded.encode("utf-8")) > 64 * 1024:
            raise ValueError("Live events are limited to 64 KiB.")
        self._sequence += 1
        event = Event(self._sequence, kind, payload, time.time())
        for stream in tuple(self._subscribers.values()):
            if stream.full():
                try:
                    stream.get_nowait()
                except asyncio.QueueEmpty:
                    pass
                self.dropped_events += 1
            try:
                stream.put_nowait(event)
            except asyncio.QueueFull:
                self.dropped_events += 1
        return event

    async def subscribe(self, *, heartbeat_seconds: float = 15,
                        max_lifetime_seconds: float = 6 * 3600) -> AsyncIterator[bytes]:
        if self.subscriber_count >= self.max_subscribers:
            raise TooManySubscribers("Live connection limit reached.")
        subscriber_id = uuid.uuid4().hex
        stream: asyncio.Queue[Event] = asyncio.Queue(maxsize=self.queue_size)
        self._subscribers[subscriber_id] = stream
        started = time.monotonic()
        try:
            yield b"retry: 3000\n\n"
            while time.monotonic() - started < max_lifetime_seconds:
                try:
                    event = await asyncio.wait_for(stream.get(), timeout=heartbeat_seconds)
                except TimeoutError:
                    yield b": keepalive\n\n"
                    continue
                data = json.dumps(event.payload, separators=(",", ":"), ensure_ascii=False)
                yield f"id: {event.sequence}\nevent: {event.kind}\ndata: {data}\n\n".encode("utf-8")
        finally:
            self._subscribers.pop(subscriber_id, None)

