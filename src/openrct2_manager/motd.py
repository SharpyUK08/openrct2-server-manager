"""Validated message-of-the-day configuration with live game delivery."""

from __future__ import annotations

from pathlib import Path
from typing import Protocol

from .atomic import read_json, write_json


class MotdBridge(Protocol):
    def request(self, action: str, **fields: object) -> dict: ...


def validate_lines(lines: object) -> tuple[str, ...]:
    if not isinstance(lines, (list, tuple)) or len(lines) > 5:
        raise ValueError("The MOTD may contain up to five lines.")
    cleaned = []
    for value in lines:
        if not isinstance(value, str):
            raise ValueError("Every MOTD line must be text.")
        value = value.strip()
        if not 1 <= len(value) <= 180 or any(ord(character) < 32 for character in value):
            raise ValueError("MOTD lines must contain 1–180 printable characters.")
        cleaned.append(value)
    return tuple(cleaned)


class MotdStore:
    def __init__(self, path: Path, bridge: MotdBridge | None = None):
        self.path = path
        self.bridge = bridge

    def get(self) -> tuple[str, ...]:
        if not self.path.exists():
            return ()
        value = read_json(self.path)
        if not isinstance(value, dict):
            raise ValueError("Invalid MOTD settings document.")
        return validate_lines(value.get("lines", []))

    def set(self, lines: object) -> tuple[str, ...]:
        checked = validate_lines(lines)
        if self.bridge is not None:
            response = self.bridge.request("set_motd", lines=list(checked))
            if response.get("ok") is not True:
                raise RuntimeError("OpenRCT2 rejected the MOTD update.")
        write_json(self.path, {"schema": 1, "lines": list(checked)})
        return checked
