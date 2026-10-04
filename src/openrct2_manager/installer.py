"""Guided first-run primitives used by the terminal installer."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import platform
import shutil
import socket
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

from .security import PortalUserStore


@dataclass(frozen=True)
class DoctorReport:
    python: str
    operating_system: str
    architecture: str
    disk_free_bytes: int
    ports_available: dict[int, bool]
    openrct2_binary: str | None
    aws_cli: str | None
    rclone: str | None


def port_available(port: int) -> bool:
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def doctor(path: Path = Path("/")) -> DoctorReport:
    return DoctorReport(
        python=platform.python_version(), operating_system=platform.platform(), architecture=platform.machine(),
        disk_free_bytes=shutil.disk_usage(path).free,
        ports_available={port: port_available(port) for port in (80, 443, 11753, 11754, 11755)},
        openrct2_binary=shutil.which("openrct2-cli") or shutil.which("openrct2"),
        aws_cli=shutil.which("aws"), rclone=shutil.which("rclone"),
    )


def prompt_owner(store: PortalUserStore) -> None:
    if store.all():
        raise ValueError("Portal users already exist; use the portal to manage them.")
    print("\nInitial portal Owner")
    display_name = input("Display name: ").strip()
    username = input("Username [admin]: ").strip() or "admin"
    password = getpass.getpass("Password (12+ characters): ")
    confirmation = getpass.getpass("Confirm password: ")
    if password != confirmation:
        raise ValueError("Passwords do not match.")
    store.create(username, display_name, "owner", password)
    print(f"Created Owner account {username!r}.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="openrct2-manager-installer")
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("doctor", help="Print a redacted host readiness report")
    check.add_argument("--path", type=Path, default=Path("/"))
    owner = commands.add_parser("init-owner", help="Interactively create the first portal Owner")
    owner.add_argument("--state-root", type=Path, default=Path("/var/lib/openrct2-manager"))
    args = parser.parse_args(argv)
    try:
        if args.command == "doctor":
            print(json.dumps(asdict(doctor(args.path)), indent=2)); return 0
        if args.command == "init-owner":
            args.state_root.mkdir(parents=True, exist_ok=True)
            prompt_owner(PortalUserStore(args.state_root / "portal-users.json")); return 0
    except (ValueError, OSError) as exc:
        print(f"Error: {exc}", file=sys.stderr); return 2
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

