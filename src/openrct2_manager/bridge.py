"""Authenticated localhost event bridge for in-game commands."""

from __future__ import annotations

import hmac
import json
import logging
import queue
import re
import socketserver
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .openrct2 import PERMISSION_INDEX

ALLOWED_EVENTS = frozenset({"backup", "restart", "audit", "permission_request"})
EVENT_ID = re.compile(r"[A-Za-z0-9_.:-]{8,96}\Z")
KEY_HASH = re.compile(r"[0-9a-f]{40}\Z")
LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class BridgeEvent:
    event_id: str
    action: str
    player_id: int
    player_name: str
    public_key_hash: str
    received_at: float
    permission: str | None = None
    permission_name: str | None = None


class _Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        self.connection.settimeout(3)
        if self.client_address[0] not in ("127.0.0.1", "::1"):
            return
        line = self.rfile.readline(8193)
        if not line or len(line) > 8192:
            return
        try:
            value = json.loads(line)
            token = str(value.pop("token", ""))
            event = BridgeEvent(
                event_id=str(value["event_id"]),
                action=value["action"], player_id=value["player_id"],
                player_name=value["player_name"], public_key_hash=value["public_key_hash"].lower(),
                received_at=time.monotonic(), permission=value.get("permission"),
                permission_name=value.get("permission_name"),
            )
            if (not hmac.compare_digest(token, self.server.bridge_token)
                    or event.action not in ALLOWED_EVENTS or type(event.player_id) is not int
                    or not 0 <= event.player_id <= 65535 or not 1 <= len(event.player_name) <= 32
                    or any(ord(character) < 32 for character in event.player_name)
                    or not KEY_HASH.fullmatch(event.public_key_hash)
                    or not EVENT_ID.fullmatch(event.event_id)
                    or (event.action == "permission_request" and event.permission not in PERMISSION_INDEX)
                    or (event.action != "permission_request" and event.permission is not None)
                    or (event.permission_name is not None and
                        (not isinstance(event.permission_name, str) or len(event.permission_name) > 32))):
                raise ValueError
            if not self.server.ledger.claim(event.event_id):
                self.wfile.write(b'{"ok":true,"status":"duplicate"}\n')
                return
            try:
                self.server.events.put_nowait(event)
            except queue.Full:
                self.server.ledger.release(event.event_id)
                raise
            self.wfile.write(b'{"ok":true,"status":"accepted"}\n')
        except (ValueError, KeyError, TypeError, json.JSONDecodeError, queue.Full):
            self.wfile.write(b'{"ok":false,"status":"rejected"}\n')
        except TimeoutError:
            return


class _Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    request_queue_size = 16

    def __init__(self, address: tuple[str, int], token: str, events: queue.Queue[BridgeEvent], ledger,
                 max_connections: int = 16):
        self.bridge_token = token
        self.events = events
        self.ledger = ledger
        self._slots = threading.BoundedSemaphore(max_connections)
        super().__init__(address, _Handler)

    def process_request(self, request, client_address) -> None:
        if not self._slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


class EventLedger:
    """Small durable idempotency ledger for retried plug-in callbacks."""

    def __init__(self, path: Path | str = ":memory:", retention_seconds: int = 7 * 86400):
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(str(path), check_same_thread=False)
        self.retention_seconds = retention_seconds
        self._lock = threading.Lock()
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS bridge_events "
            "(event_id TEXT PRIMARY KEY, handled_at INTEGER NOT NULL)"
        )
        self.connection.commit()

    def claim(self, event_id: str) -> bool:
        now = int(time.time())
        with self._lock, self.connection:
            self.connection.execute("DELETE FROM bridge_events WHERE handled_at < ?", (now - self.retention_seconds,))
            cursor = self.connection.execute("INSERT OR IGNORE INTO bridge_events(event_id, handled_at) VALUES (?, ?)",
                                             (event_id, now))
        return cursor.rowcount == 1

    def release(self, event_id: str) -> None:
        with self._lock, self.connection:
            self.connection.execute("DELETE FROM bridge_events WHERE event_id=?", (event_id,))

    def close(self) -> None:
        self.connection.close()


class CommandBridge:
    """Receives tiny authenticated events and processes them away from game/plugin threads."""

    def __init__(self, token: str, handlers: dict[str, Callable[[BridgeEvent], None]],
                 host: str = "127.0.0.1", port: int = 11755,
                 ledger_path: Path | str = ":memory:", queue_size: int = 128):
        if len(token) < 32:
            raise ValueError("Bridge token is too short.")
        if not 8 <= queue_size <= 4096:
            raise ValueError("Bridge queue size must be between 8 and 4096.")
        self.events: queue.Queue[BridgeEvent] = queue.Queue(maxsize=queue_size)
        self._ledger = EventLedger(ledger_path)
        self.server = _Server((host, port), token, self.events, self._ledger)
        self.handlers = handlers
        self._last: dict[tuple[str, str], float] = {}
        self._attempts: dict[str, int] = {}
        self._stopping = threading.Event()
        self._server_thread = threading.Thread(target=self.server.serve_forever, name="command-bridge", daemon=True)
        self._worker_thread = threading.Thread(target=self._work, name="command-worker", daemon=True)

    def start(self) -> None:
        self._server_thread.start(); self._worker_thread.start()

    def stop(self) -> None:
        self._stopping.set(); self.server.shutdown(); self.server.server_close()
        self._server_thread.join(timeout=5); self._worker_thread.join(timeout=5)
        self._ledger.close()

    def _work(self) -> None:
        while not self._stopping.is_set():
            try:
                event = self.events.get(timeout=0.5)
            except queue.Empty:
                continue
            key = (event.public_key_hash, event.action + ":" + (event.permission or ""))
            previous = self._last.get(key, 0)
            # Defence in depth; the plugin also applies command-specific cooldowns.
            cooldown = {"permission_request": 60, "backup": 300, "restart": 300}.get(event.action, 30)
            if previous == 0 or event.received_at - previous >= cooldown:
                handler = self.handlers.get(event.action)
                if handler:
                    try:
                        handler(event)
                    except Exception:
                        LOGGER.exception("Command bridge handler failed for %s", event.action)
                        attempt = self._attempts.get(event.event_id, 0) + 1
                        self._attempts[event.event_id] = attempt
                        if attempt < 5:
                            try:
                                self.events.put_nowait(event)
                            except queue.Full:
                                LOGGER.error("Bridge retry queue full for %s", event.event_id)
                        else:
                            LOGGER.error("Bridge event %s failed permanently", event.event_id)
                    else:
                        self._last[key] = event.received_at
                        self._attempts.pop(event.event_id, None)
            if len(self._last) > 4096:
                cutoff = time.monotonic() - 86400
                self._last = {key: value for key, value in self._last.items() if value >= cutoff}
            self.events.task_done()
