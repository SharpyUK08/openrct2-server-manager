"""Persistent, per-player grants for restricted in-game manager commands."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Protocol

from .atomic import read_json, write_json

RESTRICTED_COMMANDS = frozenset({"save", "backup", "restart"})
KEY_HASH = re.compile(r"[0-9a-f]{40}\Z")


class CommandBridge(Protocol):
    def request(self, action: str, **fields: object) -> dict: ...


class CommandGrantStore:
    def __init__(self, path: Path, bridge: CommandBridge | None = None):
        self.path = path
        self.bridge = bridge

    def all(self) -> dict[str, tuple[str, ...]]:
        if not self.path.exists():
            return {}
        value = read_json(self.path)
        if not isinstance(value, dict) or value.get("schema") != 1 or not isinstance(value.get("players"), dict):
            raise ValueError("Invalid in-game command grant document.")
        result = {}
        for key_hash, commands in value["players"].items():
            if not KEY_HASH.fullmatch(key_hash) or not isinstance(commands, list):
                raise ValueError("Invalid in-game command grant entry.")
            checked = tuple(sorted(set(commands)))
            if any(command not in RESTRICTED_COMMANDS and command != "*" for command in checked):
                raise ValueError("Unknown in-game command grant.")
            result[key_hash] = checked
        return result

    def set(self, public_key_hash: str, command: str, allowed: bool) -> tuple[str, ...]:
        public_key_hash = public_key_hash.lower()
        if not KEY_HASH.fullmatch(public_key_hash):
            raise ValueError("Invalid OpenRCT2 public-key hash.")
        if command not in RESTRICTED_COMMANDS and command != "*":
            raise ValueError("Unknown restricted command.")
        if type(allowed) is not bool:
            raise ValueError("Command access must be enabled or disabled.")
        players = self.all(); grants = set(players.get(public_key_hash, ()))
        if allowed:
            grants.add(command)
        else:
            grants.discard(command)
        if self.bridge is not None:
            response = self.bridge.request(
                "set_command_access", hash=public_key_hash, command=command, allowed=allowed
            )
            if response.get("ok") is not True:
                raise RuntimeError("OpenRCT2 rejected the command-access update.")
        if grants:
            players[public_key_hash] = tuple(sorted(grants))
        else:
            players.pop(public_key_hash, None)
        write_json(self.path, {"schema": 1, "players": {key: list(value) for key, value in players.items()}})
        return tuple(sorted(grants))

