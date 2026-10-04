"""Durable SQLite queue for archive, checksum, upload, and remote-transfer work."""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


@dataclass(frozen=True)
class Job:
    id: str
    kind: str
    payload: dict
    attempts: int


class JobStore:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path, timeout=5, isolation_level=None)
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA busy_timeout=5000")
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS jobs ("
            "id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, "
            "attempts INTEGER NOT NULL DEFAULT 0, available_at INTEGER NOT NULL, created_at INTEGER NOT NULL, "
            "started_at INTEGER, finished_at INTEGER, error TEXT)"
        )

    def enqueue(self, kind: str, payload: dict, *, delay_seconds: int = 0) -> str:
        if not kind.replace("_", "").isalnum() or len(kind) > 48:
            raise ValueError("Invalid job type.")
        encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
        if len(encoded.encode()) > 64 * 1024:
            raise ValueError("Job payloads are limited to 64 KiB; store files by safe internal ID.")
        job_id = uuid.uuid4().hex; now = int(time.time())
        self.connection.execute(
            "INSERT INTO jobs(id,kind,payload,status,available_at,created_at) VALUES(?,?,?,'queued',?,?)",
            (job_id, kind, encoded, now + max(0, delay_seconds), now),
        )
        return job_id

    def claim(self) -> Job | None:
        now = int(time.time())
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            row = self.connection.execute(
                "SELECT id,kind,payload,attempts FROM jobs "
                "WHERE status='queued' AND available_at<=? ORDER BY created_at,id LIMIT 1", (now,)
            ).fetchone()
            if row is None:
                self.connection.execute("COMMIT"); return None
            changed = self.connection.execute(
                "UPDATE jobs SET status='running', attempts=attempts+1, started_at=? "
                "WHERE id=? AND status='queued'", (now, row[0]),
            ).rowcount
            self.connection.execute("COMMIT")
        except Exception:
            self.connection.execute("ROLLBACK"); raise
        return Job(row[0], row[1], json.loads(row[2]), row[3] + 1) if changed else None

    def complete(self, job_id: str) -> None:
        self.connection.execute(
            "UPDATE jobs SET status='complete',finished_at=?,error=NULL WHERE id=? AND status='running'",
            (int(time.time()), job_id),
        )

    def fail(self, job: Job, error: Exception, *, max_attempts: int = 5) -> None:
        message = f"{type(error).__name__}: {error}".replace("\x00", "")[:500]
        if job.attempts >= max_attempts:
            self.connection.execute(
                "UPDATE jobs SET status='failed',finished_at=?,error=? WHERE id=? AND status='running'",
                (int(time.time()), message, job.id),
            )
            return
        delay = min(3600, 30 * (2 ** (job.attempts - 1)))
        self.connection.execute(
            "UPDATE jobs SET status='queued',available_at=?,error=? WHERE id=? AND status='running'",
            (int(time.time()) + delay, message, job.id),
        )

    def recover_abandoned(self, *, older_than_seconds: int = 3600) -> int:
        return self.connection.execute(
            "UPDATE jobs SET status='queued',available_at=?,error='worker exited during job' "
            "WHERE status='running' AND started_at<?",
            (int(time.time()), int(time.time()) - older_than_seconds),
        ).rowcount

    def close(self) -> None:
        self.connection.close()


def work_once(store: JobStore, handlers: dict[str, Callable[[dict], None]]) -> bool:
    job = store.claim()
    if job is None:
        return False
    try:
        handler = handlers.get(job.kind)
        if handler is None:
            raise RuntimeError(f"No worker handles job type {job.kind!r}.")
        handler(job.payload)
    except Exception as error:
        store.fail(job, error)
    else:
        store.complete(job.id)
    return True
