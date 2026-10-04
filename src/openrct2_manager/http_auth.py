"""Reusable authentication/RBAC layer for BaseHTTPRequestHandler applications."""

from __future__ import annotations

import hmac
import json
from dataclasses import dataclass
from http.cookies import SimpleCookie
from typing import Any

from .security import PortalUser, PortalUserStore, Session, SessionStore


@dataclass(frozen=True)
class AuthContext:
    user: PortalUser
    session: Session


class AuthMixin:
    """Mixin requiring `users`, `sessions`, and BaseHTTPRequestHandler methods."""

    users: PortalUserStore
    sessions: SessionStore
    secure_cookies = True
    session_cookie = "openrct2_session"

    def auth_context(self) -> AuthContext | None:
        cookie = SimpleCookie(); cookie.load(self.headers.get("Cookie", ""))
        morsel = cookie.get(self.session_cookie)
        session = self.sessions.get(morsel.value) if morsel else None
        if session is None:
            return None
        user = next((item for item in self.users.all() if item.id == session.user_id and item.active), None)
        return AuthContext(user, session) if user else None

    def require_capability(self, capability: str) -> AuthContext | None:
        context = self.auth_context()
        if context is None:
            self.json_response(401, {"error": "authentication_required"})
            return None
        if not context.user.allows(capability):
            self.json_response(403, {"error": "permission_denied"})
            return None
        return context

    def require_csrf(self, context: AuthContext, supplied: str) -> bool:
        if hmac.compare_digest(context.session.csrf, supplied):
            return True
        self.json_response(403, {"error": "csrf_failed"})
        return False

    def login(self, username: str, password: str) -> None:
        user = self.users.authenticate(username, password)
        if user is None:
            self.json_response(401, {"error": "invalid_credentials"})
            return
        session = self.sessions.create(user.id)
        cookie = SimpleCookie(); cookie[self.session_cookie] = session.token
        cookie[self.session_cookie]["path"] = "/"; cookie[self.session_cookie]["httponly"] = True
        cookie[self.session_cookie]["samesite"] = "Strict"; cookie[self.session_cookie]["max-age"] = 12 * 60 * 60
        if self.secure_cookies:
            cookie[self.session_cookie]["secure"] = True
        self.json_response(200, {"user": user.public(), "csrf": session.csrf},
                           headers={"Set-Cookie": cookie.output(header="").strip()})

    def logout(self) -> None:
        context = self.auth_context()
        if context:
            self.sessions.revoke(context.session.token)
        cookie = (f"{self.session_cookie}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" +
                  ("; Secure" if self.secure_cookies else ""))
        self.json_response(200, {"ok": True}, headers={"Set-Cookie": cookie})

    def json_response(self, status: int, value: Any, headers: dict[str, str] | None = None) -> None:
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        for name, content in (headers or {}).items():
            self.send_header(name, content)
        self.end_headers(); self.wfile.write(payload)

