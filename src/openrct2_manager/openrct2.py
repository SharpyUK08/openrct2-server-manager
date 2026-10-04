"""Validated OpenRCT2 configuration and multiplayer-group adapters."""

from __future__ import annotations

import configparser
import ipaddress
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .atomic import read_json, write_bytes, write_json

# Permission names are persisted by OpenRCT2's NetworkGroup::toJson().
GROUP_PERMISSIONS = (
    "PERMISSION_CHAT", "PERMISSION_TERRAFORM", "PERMISSION_SET_WATER_LEVEL",
    "PERMISSION_TOGGLE_PAUSE", "PERMISSION_CREATE_RIDE", "PERMISSION_REMOVE_RIDE",
    "PERMISSION_BUILD_RIDE", "PERMISSION_RIDE_PROPERTIES", "PERMISSION_SCENERY",
    "PERMISSION_PATH", "PERMISSION_CLEAR_LANDSCAPE", "PERMISSION_GUEST",
    "PERMISSION_STAFF", "PERMISSION_PARK_PROPERTIES", "PERMISSION_PARK_FUNDING",
    "PERMISSION_KICK_PLAYER", "PERMISSION_MODIFY_GROUPS", "PERMISSION_SET_PLAYER_GROUP",
    "PERMISSION_CHEAT", "PERMISSION_TOGGLE_SCENERY_CLUSTER",
    "PERMISSION_PASSWORDLESS_LOGIN", "PERMISSION_MODIFY_TILE",
    "PERMISSION_EDIT_SCENARIO_OPTIONS", "PERMISSION_DRAG_PATH_AREA",
)
PERMISSION_INDEX = {permission: index for index, permission in enumerate(GROUP_PERMISSIONS)}
GROUP_NAME = re.compile(r"[^\x00-\x1f\x7f]{1,32}\Z")


@dataclass(frozen=True)
class Group:
    id: int
    name: str
    permissions: tuple[str, ...]

    @classmethod
    def parse(cls, value: object) -> "Group":
        if not isinstance(value, dict):
            raise ValueError("A group entry is not an object.")
        group_id, name, permissions = value.get("id"), value.get("name"), value.get("permissions")
        if type(group_id) is not int or not 0 <= group_id <= 255:
            raise ValueError("Group IDs must be integers from 0 to 255.")
        if not isinstance(name, str) or not GROUP_NAME.fullmatch(name):
            raise ValueError("Group names must contain 1–32 printable characters.")
        if (not isinstance(permissions, list) or any(permission not in PERMISSION_INDEX for permission in permissions)
                or len(permissions) != len(set(permissions))):
            raise ValueError(f"Group {name!r} contains invalid or duplicate permissions.")
        return cls(group_id, name, tuple(sorted(permissions, key=PERMISSION_INDEX.__getitem__)))

    def json(self) -> dict:
        return {"id": self.id, "name": self.name, "permissions": list(self.permissions)}


@dataclass(frozen=True)
class GroupDocument:
    default_group: int
    groups: tuple[Group, ...]

    @classmethod
    def parse(cls, value: object) -> "GroupDocument":
        if not isinstance(value, dict) or type(value.get("default_group")) is not int:
            raise ValueError("groups.json must contain default_group and groups.")
        raw_groups = value.get("groups")
        if not isinstance(raw_groups, list):
            raise ValueError("groups.json groups must be an array.")
        groups = tuple(Group.parse(group) for group in raw_groups)
        ids = [group.id for group in groups]
        if not groups or len(ids) != len(set(ids)) or 0 not in ids:
            raise ValueError("Groups require unique IDs and an Administrator group with ID 0.")
        if value["default_group"] not in ids:
            raise ValueError("The default group does not exist.")
        return cls(value["default_group"], groups)

    def json(self) -> dict:
        return {"default_group": self.default_group, "groups": [group.json() for group in self.groups]}


class LiveGroupBridge(Protocol):
    def request(self, action: str, **fields: object) -> dict: ...


class GroupService:
    """Uses live OpenRCT2 APIs while running; the JSON file is an offline adapter."""

    def __init__(self, path: Path, bridge: LiveGroupBridge | None = None):
        self.path = path
        self.bridge = bridge

    def read_offline(self) -> GroupDocument:
        return GroupDocument.parse(read_json(self.path))

    def write_offline(self, document: GroupDocument) -> None:
        # Re-parse the serialised form so hand-built dataclasses cannot bypass invariants.
        checked = GroupDocument.parse(document.json())
        write_json(self.path, checked.json())

    def live_state(self) -> GroupDocument:
        if self.bridge is None:
            return self.read_offline()
        return GroupDocument.parse(self.bridge.request("groups"))

    def create(self, name: str) -> None:
        self._live("group_create", name=self._name(name))

    def rename(self, group_id: int, name: str) -> None:
        if group_id == 0:
            raise ValueError("The built-in Administrator group cannot be renamed by the manager.")
        self._live("group_rename", group=group_id, name=self._name(name))

    def delete(self, group_id: int) -> None:
        if group_id == 0:
            raise ValueError("The built-in Administrator group cannot be deleted.")
        self._live("group_delete", group=group_id)

    def set_default(self, group_id: int) -> None:
        self._live("group_default", group=group_id)

    def set_permission(self, group_id: int, permission: str, allowed: bool) -> None:
        if group_id == 0:
            raise ValueError("Administrator always has every OpenRCT2 permission.")
        if permission not in PERMISSION_INDEX or type(allowed) is not bool:
            raise ValueError("Unknown OpenRCT2 permission.")
        self._live("group_permission", group=group_id, permission=permission, allowed=allowed)

    def _live(self, action: str, **fields: object) -> None:
        if self.bridge is None:
            raise RuntimeError("Group changes require the live helper; stop the game for offline restore.")
        self.bridge.request(action, **fields)

    @staticmethod
    def _name(name: str) -> str:
        name = name.strip()
        if not GROUP_NAME.fullmatch(name):
            raise ValueError("Group names must contain 1–32 printable characters.")
        return name


@dataclass(frozen=True)
class ServerSettings:
    server_name: str
    server_description: str
    server_greeting: str
    max_players: int
    default_port: int
    advertise: bool
    advertise_address: str
    pause_when_empty: bool
    autosave: int
    autosave_amount: int
    has_password: bool


class ConfigStore:
    """Reads and updates only supported OpenRCT2 INI keys, preserving other sections."""

    def __init__(self, path: Path):
        self.path = path

    def _parser(self) -> configparser.ConfigParser:
        parser = configparser.ConfigParser(interpolation=None, strict=True)
        parser.optionxform = str
        parser.read(self.path, encoding="utf-8")
        if not parser.has_section("network"):
            parser.add_section("network")
        if not parser.has_section("general"):
            parser.add_section("general")
        return parser

    @staticmethod
    def _unquote(value: str, default: str = "") -> str:
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            return value[1:-1].replace('\\"', '"').replace('\\\\', '\\')
        return value or default

    @staticmethod
    def _quote(value: str) -> str:
        if any(character in value for character in "\r\n\x00"):
            raise ValueError("Configuration text may not contain control characters.")
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    def read(self) -> ServerSettings:
        parser = self._parser(); network = parser["network"]; general = parser["general"]
        password = self._unquote(network.get("default_password", '""'))
        return ServerSettings(
            self._unquote(network.get("server_name", '"OpenRCT2 Server"')),
            self._unquote(network.get("server_description", '""')),
            self._unquote(network.get("server_greeting", '""')),
            network.getint("maxplayers", fallback=16), network.getint("default_port", fallback=11753),
            network.getboolean("advertise", fallback=True),
            self._unquote(network.get("advertise_address", '""')),
            network.getboolean("pause_server_if_no_clients", fallback=True),
            general.getint("autosave", fallback=1), general.getint("autosave_amount", fallback=10),
            bool(password),
        )

    def update(self, values: dict[str, object], *, password: str | None = None,
               remove_password: bool = False) -> ServerSettings:
        current = self.read()
        merged = {**current.__dict__, **values}
        for key in ("server_name", "server_description", "server_greeting"):
            value = merged[key]
            limit = 64 if key == "server_name" else 256
            if not isinstance(value, str) or not 1 <= len(value.strip()) <= limit:
                raise ValueError(f"{key} must contain 1–{limit} characters.")
        if (type(merged["max_players"]) is not int or not 1 <= merged["max_players"] <= 255 or
                type(merged["default_port"]) is not int or not 1 <= merged["default_port"] <= 65535 or
                type(merged["autosave"]) is not int or not 0 <= merged["autosave"] <= 5 or
                type(merged["autosave_amount"]) is not int or not 1 <= merged["autosave_amount"] <= 1000):
            raise ValueError("A numeric server setting is outside its supported range.")
        address = merged["advertise_address"]
        if address:
            try:
                ipaddress.ip_address(str(address))
            except ValueError:
                if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?", str(address)):
                    raise ValueError("Advertised address must be an IP address or hostname.")
        parser = self._parser(); network = parser["network"]; general = parser["general"]
        network["server_name"] = self._quote(str(merged["server_name"]).strip())
        network["server_description"] = self._quote(str(merged["server_description"]).strip())
        network["server_greeting"] = self._quote(str(merged["server_greeting"]).strip())
        network["maxplayers"] = str(merged["max_players"]); network["default_port"] = str(merged["default_port"])
        network["advertise"] = str(bool(merged["advertise"])).lower()
        network["advertise_address"] = self._quote(str(address))
        network["pause_server_if_no_clients"] = str(bool(merged["pause_when_empty"])).lower()
        general["autosave"] = str(merged["autosave"]); general["autosave_amount"] = str(merged["autosave_amount"])
        if remove_password:
            network["default_password"] = '""'
        elif password is not None:
            if len(password) > 128 or any(ord(character) < 32 for character in password):
                raise ValueError("Game password is too long or contains control characters.")
            network["default_password"] = self._quote(password)
        from io import StringIO
        output = StringIO(); parser.write(output, space_around_delimiters=True)
        write_bytes(self.path, output.getvalue().encode("utf-8"))
        return self.read()

