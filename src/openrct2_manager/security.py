"""Portal users, password hashing, sessions, and server-side RBAC."""

from __future__ import annotations

import base64
import hashlib
import hmac
import re
import secrets
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from .atomic import read_json, write_json

USERNAME = re.compile(r"[a-z0-9][a-z0-9_.-]{0,63}\Z")
ROLES = ("owner", "administrator", "operator", "viewer")
ROLE_CAPABILITIES = {
    "viewer": frozenset({"view"}),
    "operator": frozenset({"view", "server.control", "chat.send", "scenario.manage", "save.manage"}),
    "administrator": frozenset({
        "view", "server.control", "chat.send", "scenario.manage", "save.manage",
        "player.manage", "group.manage", "settings.manage", "backup.manage",
    }),
    "owner": frozenset({"*"}),
}


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _unb64(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def hash_password(password: str, *, iterations: int = 600_000, salt: bytes | None = None) -> str:
    if not 12 <= len(password) <= 1024:
        raise ValueError("Portal passwords must contain 12–1024 characters.")
    salt = salt or secrets.token_bytes(18)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return f"pbkdf2_sha256${iterations}${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        scheme, rounds, salt, expected = encoded.split("$", 3)
        if scheme != "pbkdf2_sha256":
            return False
        iterations = int(rounds)
        if not 100_000 <= iterations <= 2_000_000:
            return False
        actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), _unb64(salt), iterations)
        return hmac.compare_digest(actual, _unb64(expected))
    except (ValueError, TypeError):
        return False


@dataclass(frozen=True)
class PortalUser:
    id: str
    username: str
    display_name: str
    role: str
    password_hash: str
    active: bool = True
    must_change_password: bool = False

    def allows(self, capability: str) -> bool:
        allowed = ROLE_CAPABILITIES[self.role]
        return "*" in allowed or capability in allowed

    def public(self) -> dict:
        return {
            "id": self.id, "username": self.username, "display_name": self.display_name,
            "role": self.role, "active": self.active,
            "must_change_password": self.must_change_password,
        }


class PortalUserStore:
    """Validated, atomic storage for web identities."""

    schema = 1

    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.RLock()

    def _decode(self, item: dict) -> PortalUser:
        user = PortalUser(**item)
        if (not re.fullmatch(r"[0-9a-f-]{36}", user.id) or not USERNAME.fullmatch(user.username)
                or user.role not in ROLES or not 1 <= len(user.display_name) <= 100
                or not user.password_hash.startswith("pbkdf2_sha256$")):
            raise ValueError("Portal user database contains an invalid record.")
        return user

    def all(self) -> list[PortalUser]:
        data = read_json(self.path, {"schema": self.schema, "users": []})
        if not isinstance(data, dict) or data.get("schema") != self.schema or not isinstance(data.get("users"), list):
            raise ValueError("Portal user database has an unsupported schema.")
        users = [self._decode(item) for item in data["users"] if isinstance(item, dict)]
        if len({user.username for user in users}) != len(users):
            raise ValueError("Portal user database contains duplicate usernames.")
        return users

    def _save(self, users: Iterable[PortalUser]) -> None:
        users = list(users)
        if users and not any(user.active and user.role == "owner" for user in users):
            raise ValueError("At least one active Owner must remain.")
        write_json(self.path, {"schema": self.schema, "users": [user.__dict__ for user in users]}, 0o600)

    def create(self, username: str, display_name: str, role: str, password: str,
               *, must_change_password: bool = False) -> PortalUser:
        username = username.strip().lower()
        display_name = display_name.strip()
        if not USERNAME.fullmatch(username):
            raise ValueError("Username must use lowercase letters, numbers, dot, dash, or underscore.")
        if role not in ROLES or not 1 <= len(display_name) <= 100:
            raise ValueError("Choose a valid role and display name.")
        with self._lock:
            users = self.all()
            if any(user.username == username for user in users):
                raise ValueError("That portal username already exists.")
            user = PortalUser(str(uuid.uuid4()), username, display_name, role, hash_password(password),
                              must_change_password=must_change_password)
            self._save([*users, user])
            return user

    def authenticate(self, username: str, password: str) -> PortalUser | None:
        username = username.strip().lower()
        # Perform one dummy hash when the username is absent to reduce account enumeration timing.
        dummy = "pbkdf2_sha256$100000$AAAAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        user = next((item for item in self.all() if item.username == username and item.active), None)
        valid = verify_password(password, user.password_hash if user else dummy)
        return user if user and valid else None

    def replace(self, changed: PortalUser) -> None:
        with self._lock:
            users = self.all()
            if not any(user.id == changed.id for user in users):
                raise ValueError("Portal user no longer exists.")
            self._save(changed if user.id == changed.id else user for user in users)

    def delete(self, user_id: str) -> None:
        with self._lock:
            users = self.all()
            remaining = [user for user in users if user.id != user_id]
            if len(remaining) == len(users):
                raise ValueError("Portal user no longer exists.")
            self._save(remaining)


@dataclass(frozen=True)
class Session:
    token: str
    csrf: str
    user_id: str
    expires_at: float


class SessionStore:
    """Process-local sessions; restarting the portal intentionally signs everyone out."""

    def __init__(self, lifetime_seconds: int = 12 * 60 * 60):
        self.lifetime_seconds = lifetime_seconds
        self._items: dict[str, Session] = {}
        self._lock = threading.Lock()

    def create(self, user_id: str) -> Session:
        now = time.time()
        session = Session(secrets.token_urlsafe(32), secrets.token_urlsafe(32), user_id,
                          now + self.lifetime_seconds)
        with self._lock:
            self._items[session.token] = session
            self._prune(now)
        return session

    def get(self, token: str) -> Session | None:
        now = time.time()
        with self._lock:
            self._prune(now)
            return self._items.get(token)

    def revoke(self, token: str) -> None:
        with self._lock:
            self._items.pop(token, None)

    def revoke_user(self, user_id: str) -> None:
        with self._lock:
            self._items = {token: item for token, item in self._items.items() if item.user_id != user_id}

    def _prune(self, now: float) -> None:
        self._items = {token: item for token, item in self._items.items() if item.expires_at > now}

