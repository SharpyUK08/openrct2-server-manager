"""Safe scenario/save catalogue and upload primitives."""

from __future__ import annotations

import os
import re
import tempfile
from io import BytesIO
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import BinaryIO, Iterable

from .atomic import write_bytes

ALLOWED_SUFFIXES = frozenset({".park", ".sv6", ".sv4", ".sc6", ".sc4"})
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._ ()\[\]-]{0,179}\Z")


def safe_filename(untrusted: str) -> str:
    # Never silently flatten a path: a path component is evidence of a hostile or broken client.
    if not isinstance(untrusted, str) or Path(untrusted).name != untrusted or "/" in untrusted or "\\" in untrusted:
        raise ValueError("Uploaded filenames must not contain a path.")
    if not SAFE_NAME.fullmatch(untrusted) or Path(untrusted).suffix.lower() not in ALLOWED_SUFFIXES:
        raise ValueError("Allowed scenario/save types: .park, .sv6, .sv4, .sc6, and .sc4.")
    return untrusted


@dataclass(frozen=True)
class Scenario:
    name: str
    size: int
    modified_at: datetime
    format: str


class ScenarioStore:
    def __init__(self, root: Path, max_upload_bytes: int = 64 * 1024 * 1024):
        self.root = root
        self.max_upload_bytes = max_upload_bytes

    def path(self, name: str) -> Path:
        return self.root / safe_filename(name)

    def list(self) -> list[Scenario]:
        result = []
        for path in self.root.iterdir():
            if not path.is_file() or path.suffix.lower() not in ALLOWED_SUFFIXES or not SAFE_NAME.fullmatch(path.name):
                continue
            stat = path.stat()
            result.append(Scenario(path.name, stat.st_size, datetime.fromtimestamp(stat.st_mtime, timezone.utc),
                                   path.suffix.lower().removeprefix(".")))
        return sorted(result, key=lambda item: item.name.casefold())

    def upload(self, files: list[tuple[str, bytes]], *, overwrite: bool = False) -> list[Scenario]:
        return self.upload_streams(((name, BytesIO(content)) for name, content in files), overwrite=overwrite)

    def upload_streams(self, files: Iterable[tuple[str, BinaryIO]], *, overwrite: bool = False) -> list[Scenario]:
        """Stream an upload batch to bounded temporary files before publishing it."""
        files = list(files)
        if not files:
            raise ValueError("Choose one or more scenario or park files.")
        checked = [(safe_filename(name), stream) for name, stream in files]
        names = [name for name, _ in checked]
        if len(names) != len(set(names)):
            raise ValueError("The upload contains duplicate filenames.")
        self.root.mkdir(parents=True, exist_ok=True)
        if not overwrite:
            existing = [name for name, _ in checked if (self.root / name).exists()]
            if existing:
                raise ValueError(f"{existing[0]} already exists; explicitly enable replacement.")
        total = 0
        with tempfile.TemporaryDirectory(prefix=".upload-", dir=self.root) as staging_name:
            staging = Path(staging_name)
            for name, stream in checked:
                size = 0
                with (staging / name).open("xb") as output:
                    while chunk := stream.read(1024 * 1024):
                        if not isinstance(chunk, bytes):
                            raise ValueError("Upload streams must yield bytes.")
                        size += len(chunk); total += len(chunk)
                        if total > self.max_upload_bytes:
                            raise ValueError("Combined upload exceeds the configured limit.")
                        output.write(chunk)
                    output.flush(); os.fsync(output.fileno())
                if size == 0:
                    raise ValueError("Empty scenario files are not accepted.")
            # Nothing reaches the catalogue until the entire request has passed validation.
            for name in names:
                destination = self.root / name
                if not overwrite and destination.exists():
                    raise ValueError(f"{name} already exists; explicitly enable replacement.")
                os.replace(staging / name, destination)
        indexed = {item.name: item for item in self.list()}
        return [indexed[name] for name in names]

    def select(self, name: str, selection_file: Path) -> Path:
        source = self.path(name)
        if not source.is_file():
            raise ValueError("That scenario no longer exists.")
        write_bytes(selection_file, (source.name + "\n").encode("utf-8"))
        return source
