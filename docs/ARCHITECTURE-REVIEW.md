# Architecture review

Reviewed and production-validated: 4 October 2026.

## Deployed design

The production compatibility runtime is a dependency-free Python service with
an embedded semantic UI. It is generated into the standalone installer from
`production/openrct2-manager.py`; reusable v3 domain components live under
`src/openrct2_manager`. A token-authenticated remote OpenRCT2 plugin supplies
live telemetry and executes multiplayer-safe custom actions.

The manager has four bounded execution paths:

1. `ThreadingHTTPServer` request threads handle short portal work. Heavy archive
   and transfer work is put in a durable SQLite queue.
2. A single job worker claims rows transactionally, recovers interrupted jobs,
   retries five times with exponential backoff and serialises archive changes.
3. The plugin bridge accepts length-bounded localhost frames. Callback event IDs
   are deduplicated and handlers run outside OpenRCT2's socket callback.
4. SSE is capped at 32 connections. Streams recycle after 60 seconds so browser
   `EventSource` reconnects and stale sockets cannot retain threads forever;
   five-second polling remains the compatibility fallback.

## Resolved production risks

- Park switching now creates a multiplayer-safe live save, commits selection
  atomically, waits for plugin health and rolls back on launch failure.
- Empty native headless pause suppresses normal plugin ticks. Pre-switch saving
  therefore executes through a registered custom game action, whose execute
  context is mutable even while the zero-player server is paused.
- Upload names reject path components, formats are allow-listed, request size is
  bounded and final placement is atomic.
- Portal authentication uses secure, HttpOnly, SameSite=Strict sessions with
  expiry, per-session CSRF, PBKDF2 hashes, throttling and route capabilities.
- Running-group edits use OpenRCT2's live API. Per-player exceptions use hidden
  manager groups which are removed when their final exception is inherited.
- Archive generation uses explicit inputs and a consistent SQLite online backup
  instead of copying a possibly changing WAL database.
- Archives reject traversal, links and special members and require an exact
  SHA-256 manifest. Restore creates a rollback archive before changing data.
- Audit entries contain actor, target, outcome and correlation ID. Each record
  hashes its predecessor; rotation retains ten 10 MiB generations and the CLI
  verifier detects modification or chain breaks.

## Intentional boundaries

- The browser and in-game surfaces do not expose arbitrary console or shell
  execution.
- Portal passwords, game passwords, private SFTP keys and cloud credentials are
  never rendered. Off-server adapters rely on protected host configuration or
  instance roles.
- Remote encryption is a destination policy today, not a checkbox that could
  imply encryption without a verified key/tool. A future in-process adapter
  should use an audited age recipient and verify decryptability before deletion.
- The standard-library compatibility runtime remains larger than desired.
  `src/openrct2_manager` is the extraction boundary; moving HTTP templates and
  handlers there is maintainability work, not a blocker for deployed safety.

## Production evidence

- 28 Python tests pass; installer rebuild is byte-stable and shell syntax passes.
- Live HTTPS login returns a secure session cookie; unauthenticated API requests
  redirect to login and session-authenticated requests succeed.
- The live helper created a 964,019-byte pre-switch park while auto-paused.
- A 94-file production archive passed checksum verification and restore dry-run.
- Game, manager and Caddy remained active afterward; the dashboard showed zero
  players and verified auto-pause.

Official references: the OpenRCT2
[scripting API](https://github.com/OpenRCT2/OpenRCT2/blob/develop/distribution/scripting/openrct2.d.ts)
and [plugin guide](https://github.com/OpenRCT2/OpenRCT2/blob/develop/distribution/scripting/scripting.md).
