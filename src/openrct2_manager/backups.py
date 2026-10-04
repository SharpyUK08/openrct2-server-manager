"""Full manager archives, manifests, retention, and remote transfer adapters."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Protocol

ARCHIVE_NAME = re.compile(r"openrct2-manager-[0-9]{8}T[0-9]{6}Z\.tar\.gz\Z")


@dataclass(frozen=True)
class BackupInput:
    path: Path
    archive_name: str
    required: bool = True


@dataclass(frozen=True)
class ArchiveResult:
    path: Path
    size: int
    sha256: str
    created_at: datetime


def default_inputs(state_root: Path, user_data: Path, scenario_root: Path, log_root: Path) -> tuple[BackupInput, ...]:
    """The portable state set; callers may add host-specific service metadata."""
    return (
        BackupInput(scenario_root, "scenarios"),
        BackupInput(user_data / "save", "ServerData/save"),
        BackupInput(user_data / "autosave", "ServerData/autosave", required=False),
        BackupInput(user_data / "groups.json", "ServerData/groups.json", required=False),
        BackupInput(user_data / "users.json", "ServerData/users.json", required=False),
        BackupInput(user_data / "config.ini", "ServerData/config.ini"),
        BackupInput(user_data / "plugin", "ServerData/plugin", required=False),
        BackupInput(log_root, "logs", required=False),
        BackupInput(state_root, "manager-state"),
    )


class ArchiveBuilder:
    schema = 1

    def __init__(self, destination: Path):
        self.destination = destination

    @staticmethod
    def _digest(path: Path, chunk_size: int = 1024 * 1024) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while chunk := stream.read(chunk_size):
                digest.update(chunk)
        return digest.hexdigest()

    @staticmethod
    def _archive_name(value: str) -> str:
        path = Path(value)
        if (not value or value.startswith("/") or "\\" in value or path.as_posix() != value
                or any(part in ("", ".", "..") for part in path.parts)):
            raise ValueError("Backup archive names must be safe relative POSIX paths.")
        return value

    @staticmethod
    def _members(source: Path) -> Iterable[Path]:
        if source.is_symlink():
            raise ValueError(f"Backup source must not be a symbolic link: {source}")
        if source.is_file():
            yield source
            return
        for path in sorted(source.rglob("*")):
            if path.is_symlink():
                raise ValueError(f"Backup source contains a symbolic link: {path}")
            if path.is_file():
                yield path

    def create(self, inputs: Iterable[BackupInput], *, app_version: str) -> ArchiveResult:
        inputs = tuple(inputs)
        missing = [str(item.path) for item in inputs if item.required and not item.path.exists()]
        if missing:
            raise ValueError("Required backup source is missing: " + missing[0])
        self.destination.mkdir(parents=True, exist_ok=True)
        created = datetime.now(timezone.utc)
        filename = created.strftime("openrct2-manager-%Y%m%dT%H%M%SZ.tar.gz")
        target = self.destination / filename
        if target.exists():
            raise FileExistsError("A backup with this timestamp already exists; retry in one second.")
        manifest_files: list[dict] = []
        descriptor, temporary_name = tempfile.mkstemp(prefix=".backup-", suffix=".tar.gz", dir=self.destination)
        os.close(descriptor)
        temporary = Path(temporary_name)
        try:
            # Stage a point-in-time copy so a live log or save cannot change between hashing and tar creation.
            with tempfile.TemporaryDirectory(prefix=".backup-stage-", dir=self.destination) as stage_name:
                stage = Path(stage_name)
                for item in inputs:
                    if not item.path.exists():
                        continue
                    archive_root = self._archive_name(item.archive_name)
                    base = item.path.parent if item.path.is_file() else item.path
                    for source in self._members(item.path):
                        relative = source.name if item.path.is_file() else source.relative_to(base).as_posix()
                        member_name = archive_root if item.path.is_file() else f"{archive_root}/{relative}"
                        staged = stage.joinpath(*Path(member_name).parts)
                        staged.parent.mkdir(parents=True, exist_ok=True)
                        before = source.stat()
                        digest = hashlib.sha256(); size = 0
                        with source.open("rb") as incoming, staged.open("xb") as outgoing:
                            while chunk := incoming.read(1024 * 1024):
                                outgoing.write(chunk); digest.update(chunk); size += len(chunk)
                            outgoing.flush(); os.fsync(outgoing.fileno())
                        after = source.stat()
                        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                            raise RuntimeError(f"Backup source changed while it was staged: {source}")
                        manifest_files.append({
                            "path": member_name, "size": size, "sha256": digest.hexdigest(),
                        })
                manifest = {
                    "schema": self.schema, "created_at": created.isoformat(), "application_version": app_version,
                    "files": manifest_files,
                }
                payload = (json.dumps(manifest, indent=2) + "\n").encode()
                (stage / "manifest.json").write_bytes(payload)
                with tarfile.open(temporary, "w:gz", format=tarfile.PAX_FORMAT) as archive:
                    for staged in sorted(path for path in stage.rglob("*") if path.is_file()):
                        member_name = staged.relative_to(stage).as_posix()
                        info = archive.gettarinfo(str(staged), arcname=member_name)
                        info.uid = info.gid = 0; info.uname = info.gname = ""; info.mode &= 0o750
                        info.mtime = int(created.timestamp())
                        with staged.open("rb") as stream:
                            archive.addfile(info, stream)
            os.chmod(temporary, 0o640)
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
        digest = self._digest(target)
        return ArchiveResult(target, target.stat().st_size, digest, created)

    def prune(self, keep: int) -> list[Path]:
        if not 1 <= keep <= 10_000:
            raise ValueError("Backup retention must be 1–10,000 archives.")
        archives = sorted((path for path in self.destination.iterdir()
                           if path.is_file() and ARCHIVE_NAME.fullmatch(path.name)),
                          key=lambda path: path.stat().st_mtime, reverse=True)
        removed = []
        for path in archives[keep:]:
            path.unlink(); removed.append(path)
        return removed


class RemoteDestination(Protocol):
    def test(self) -> None: ...
    def upload(self, archive: ArchiveResult) -> str: ...


def _run(argv: list[str], *, env: dict[str, str] | None = None, timeout: int = 1800) -> subprocess.CompletedProcess:
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, text=True, capture_output=True,
                            env=env, timeout=timeout, check=False)
    if result.returncode:
        # Never return stdout: third-party CLIs occasionally echo credentials or signed URLs there.
        error = (result.stderr or "remote command failed").strip().splitlines()[-1][:500]
        raise RuntimeError(error)
    return result


@dataclass(frozen=True)
class S3Destination:
    bucket: str
    prefix: str = "openrct2"
    endpoint_url: str = ""
    region: str = ""
    access_key_id: str = ""
    secret_access_key: str = ""

    def _base(self) -> tuple[list[str], dict[str, str]]:
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", self.bucket):
            raise ValueError("Invalid S3 bucket name.")
        argv = ["aws"]
        if self.endpoint_url:
            argv += ["--endpoint-url", self.endpoint_url]
        env = os.environ.copy()
        if self.access_key_id:
            env["AWS_ACCESS_KEY_ID"] = self.access_key_id
            env["AWS_SECRET_ACCESS_KEY"] = self.secret_access_key
        if self.region:
            env["AWS_DEFAULT_REGION"] = self.region
        return argv, env

    def test(self) -> None:
        argv, env = self._base(); _run([*argv, "s3api", "head-bucket", "--bucket", self.bucket], env=env, timeout=30)

    def upload(self, archive: ArchiveResult) -> str:
        argv, env = self._base(); key = f"{self.prefix.strip('/')}/{archive.path.name}".lstrip("/")
        uri = f"s3://{self.bucket}/{key}"
        _run([*argv, "s3", "cp", str(archive.path), uri, "--only-show-errors"], env=env)
        return uri


@dataclass(frozen=True)
class SftpDestination:
    host: str
    username: str
    remote_directory: str
    identity_file: Path
    port: int = 22
    known_hosts_file: Path = Path("/etc/ssh/ssh_known_hosts")

    def _validate(self) -> None:
        if (not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", self.host)
                or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,63}", self.username)
                or not re.fullmatch(r"/(?:[A-Za-z0-9_.-]+/?)*", self.remote_directory)
                or ".." in Path(self.remote_directory).parts
                or not 1 <= self.port <= 65535):
            raise ValueError("Invalid SFTP destination.")
        if not self.identity_file.is_file() or not self.known_hosts_file.is_file():
            raise ValueError("SFTP key or known-hosts file is missing.")

    def _ssh(self) -> list[str]:
        self._validate()
        return ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.known_hosts_file}", "-i", str(self.identity_file),
                "-p", str(self.port), f"{self.username}@{self.host}"]

    def test(self) -> None:
        _run([*self._ssh(), "true"], timeout=30)

    def upload(self, archive: ArchiveResult) -> str:
        # scp writes a temporary remote name; ssh performs the final same-filesystem rename.
        remote = f"{self.remote_directory.rstrip('/')}/{archive.path.name}"
        temporary = remote + ".uploading"
        ssh = self._ssh()
        scp = ["scp", "-q", "-P", str(self.port), "-o", "BatchMode=yes",
               "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={self.known_hosts_file}",
               "-i", str(self.identity_file), str(archive.path), f"{self.username}@{self.host}:{temporary}"]
        _run(scp)
        # Paths are passed as positional shell parameters, never interpolated into the command string.
        _run([*ssh, "sh", "-c", 'test -f "$1" && mv -- "$1" "$2"', "backup-finalise", temporary, remote])
        return f"sftp://{self.host}:{self.port}{remote}"


@dataclass(frozen=True)
class RcloneDestination:
    remote: str
    directory: str = "openrct2"

    def _target(self, filename: str = "") -> str:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", self.remote) or any(x in self.directory for x in ("\n", "\r")):
            raise ValueError("Invalid rclone destination.")
        return f"{self.remote}:{self.directory.strip('/')}/{filename}".rstrip("/")

    def test(self) -> None:
        _run(["rclone", "lsd", self._target()], timeout=30)

    def upload(self, archive: ArchiveResult) -> str:
        target = self._target(archive.path.name)
        _run(["rclone", "copyto", "--immutable", str(archive.path), target])
        return target
