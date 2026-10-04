"""Durable approval queue for in-game `/request <permission>` commands."""

from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .bridge import BridgeEvent


@dataclass(frozen=True)
class PermissionRequest:
    event_id: str
    public_key_hash: str
    player_name: str
    permission: str
    status: str
    requested_at: int
    resolved_at: int | None
    resolved_by: str | None


class PermissionRequestStore:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path)
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA busy_timeout=5000")
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS permission_requests ("
            "event_id TEXT PRIMARY KEY, public_key_hash TEXT NOT NULL, player_name TEXT NOT NULL, "
            "permission TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('pending','approved','rejected')), "
            "requested_at INTEGER NOT NULL, resolved_at INTEGER, resolved_by TEXT)"
        )
        self.connection.commit()

    def add(self, event: BridgeEvent) -> bool:
        if event.action != "permission_request" or event.permission is None:
            raise ValueError("Not a permission-request bridge event.")
        with self.connection:
            result = self.connection.execute(
                "INSERT OR IGNORE INTO permission_requests"
                "(event_id,public_key_hash,player_name,permission,status,requested_at) "
                "VALUES(?,?,?,?,'pending',?)",
                (event.event_id, event.public_key_hash, event.player_name, event.permission, int(time.time())),
            )
        return result.rowcount == 1

    def pending(self, *, limit: int = 100) -> list[PermissionRequest]:
        if not 1 <= limit <= 500:
            raise ValueError("Permission-request limit must be 1–500.")
        rows = self.connection.execute(
            "SELECT event_id,public_key_hash,player_name,permission,status,requested_at,resolved_at,resolved_by "
            "FROM permission_requests WHERE status='pending' ORDER BY requested_at,event_id LIMIT ?", (limit,)
        ).fetchall()
        return [PermissionRequest(*row) for row in rows]

    def get(self, event_id: str) -> PermissionRequest | None:
        row = self.connection.execute(
            "SELECT event_id,public_key_hash,player_name,permission,status,requested_at,resolved_at,resolved_by "
            "FROM permission_requests WHERE event_id=?", (event_id,)
        ).fetchone()
        return PermissionRequest(*row) if row else None

    def resolve(self, event_id: str, *, approved: bool, portal_user_id: str) -> PermissionRequest:
        if not portal_user_id or len(portal_user_id) > 128:
            raise ValueError("A valid portal user is required.")
        status = "approved" if approved else "rejected"
        with self.connection:
            changed = self.connection.execute(
                "UPDATE permission_requests SET status=?,resolved_at=?,resolved_by=? "
                "WHERE event_id=? AND status='pending'",
                (status, int(time.time()), portal_user_id, event_id),
            ).rowcount
        if changed != 1:
            raise ValueError("The permission request is missing or already resolved.")
        row = self.connection.execute(
            "SELECT event_id,public_key_hash,player_name,permission,status,requested_at,resolved_at,resolved_by "
            "FROM permission_requests WHERE event_id=?", (event_id,)
        ).fetchone()
        return PermissionRequest(*row)

    def close(self) -> None:
        self.connection.close()


class PermissionApprovalService:
    """Coordinates portal decisions with the existing per-player override applier."""

    def __init__(self, store: PermissionRequestStore,
                 grant: Callable[[str, str], None]):
        self.store = store
        self.grant = grant

    def approve(self, event_id: str, *, portal_user_id: str) -> PermissionRequest:
        request = self.store.get(event_id)
        if request is None or request.status != "pending":
            raise ValueError("The permission request is missing or already resolved.")
        # The grant function must atomically persist/reconcile the per-player override and apply
        # its derived group live. We record approval only after that operation succeeds.
        self.grant(request.public_key_hash, request.permission)
        return self.store.resolve(event_id, approved=True, portal_user_id=portal_user_id)

    def reject(self, event_id: str, *, portal_user_id: str) -> PermissionRequest:
        return self.store.resolve(event_id, approved=False, portal_user_id=portal_user_id)
