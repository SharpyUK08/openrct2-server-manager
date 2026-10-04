"""Per-player OpenRCT2 permission overlays implemented with derived groups."""

from __future__ import annotations

import hashlib
import re
import threading
from dataclasses import dataclass
from pathlib import Path

from .atomic import read_json, write_json
from .openrct2 import GROUP_PERMISSIONS, PERMISSION_INDEX, Group

KEY_HASH = re.compile(r"[0-9a-f]{40}\Z")
DERIVED_PREFIX = "@manager/"


@dataclass(frozen=True)
class PlayerOverride:
    public_key_hash: str
    base_group: int
    allow: tuple[str, ...] = ()
    deny: tuple[str, ...] = ()

    @classmethod
    def parse(cls, value: object) -> "PlayerOverride":
        if not isinstance(value, dict):
            raise ValueError("Player permission override must be an object.")
        key = value.get("public_key_hash")
        base = value.get("base_group")
        allow, deny = value.get("allow", []), value.get("deny", [])
        if not isinstance(key, str) or not KEY_HASH.fullmatch(key):
            raise ValueError("Player permission override has an invalid public-key hash.")
        if type(base) is not int or not 0 <= base <= 255:
            raise ValueError("Player permission override has an invalid base group.")
        for collection in (allow, deny):
            if (not isinstance(collection, list) or len(collection) != len(set(collection))
                    or any(item not in PERMISSION_INDEX for item in collection)):
                raise ValueError("Player permission override contains an invalid permission.")
        if set(allow) & set(deny):
            raise ValueError("A permission cannot be both allowed and denied.")
        order = PERMISSION_INDEX.__getitem__
        return cls(key, base, tuple(sorted(allow, key=order)), tuple(sorted(deny, key=order)))

    def effective(self, base_permissions: tuple[str, ...]) -> tuple[str, ...]:
        effective = (set(base_permissions) | set(self.allow)) - set(self.deny)
        return tuple(permission for permission in GROUP_PERMISSIONS if permission in effective)

    def json(self) -> dict:
        return {
            "public_key_hash": self.public_key_hash, "base_group": self.base_group,
            "allow": list(self.allow), "deny": list(self.deny),
        }


def derived_group_name(permissions: tuple[str, ...]) -> str:
    signature = hashlib.sha256("\0".join(permissions).encode()).hexdigest()[:12]
    return DERIVED_PREFIX + signature


class OverrideStore:
    schema = 1

    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.RLock()

    def all(self) -> list[PlayerOverride]:
        data = read_json(self.path, {"schema": self.schema, "overrides": []})
        if not isinstance(data, dict) or data.get("schema") != self.schema or not isinstance(data.get("overrides"), list):
            raise ValueError("Player override database has an unsupported schema.")
        values = [PlayerOverride.parse(item) for item in data["overrides"]]
        if len({item.public_key_hash for item in values}) != len(values):
            raise ValueError("Player override database contains duplicate identities.")
        return values

    def set(self, override: PlayerOverride) -> None:
        checked = PlayerOverride.parse(override.json())
        with self._lock:
            values = [item for item in self.all() if item.public_key_hash != checked.public_key_hash]
            if checked.allow or checked.deny:
                values.append(checked)
            write_json(self.path, {"schema": self.schema, "overrides": [item.json() for item in values]})

    def remove(self, public_key_hash: str) -> None:
        if not KEY_HASH.fullmatch(public_key_hash):
            raise ValueError("Invalid player public-key hash.")
        with self._lock:
            values = [item for item in self.all() if item.public_key_hash != public_key_hash]
            write_json(self.path, {"schema": self.schema, "overrides": [item.json() for item in values]})


def plan_derived_groups(groups: tuple[Group, ...], overrides: list[PlayerOverride]) -> dict[str, tuple[str, ...]]:
    """Return the minimal signature→permissions pool required by all overrides."""
    ordinary = {group.id: group for group in groups if not group.name.startswith(DERIVED_PREFIX)}
    result: dict[str, tuple[str, ...]] = {}
    for override in overrides:
        base = ordinary.get(override.base_group)
        if base is None:
            raise ValueError(f"Player override refers to missing base group {override.base_group}.")
        effective = override.effective(base.permissions)
        result[derived_group_name(effective)] = effective
    return result

