# Remaining work

Last reviewed after the live v3 hardening deployment on 4 October 2026.

## Completed in this deployment

- [x] Transactional park switching, live safety save, health wait and rollback.
- [x] Durable background archive/transfer jobs with restart recovery and backoff.
- [x] SHA-256 manifests, strict verifier, restore dry-run and rollback-first apply.
- [x] Secure portal sessions, per-session CSRF, logout, expiry and login throttle.
- [x] Versioned state migration with pre-migration state copies.
- [x] Explicit Kick alongside persistent key-based Block.
- [x] Live per-player Allow/Deny exceptions and derived-group cleanup.
- [x] Bounded/recycled SSE with polling fallback.
- [x] Scenario archiving with running-park protection and recoverable restore.
- [x] SFTP/S3/rclone scheduling, retries, atomic uploads and remote retention.
- [x] Read-only destination connection tests.
- [x] Structured tamper-evident audit records, rotation, retention and verifier.
- [x] Correct safety-save labelling and a last-five recoverable saves overview.
- [x] Browser first-run guide with a hashed one-time password, OpenRCT2
  detection, first Owner creation, basic server configuration and guarded
  domain/HTTPS handoff.
- [x] Automatic OpenRCT2 detection, official Ubuntu PPA installation and
  post-install version verification for fresh hosts.
- [x] Live verification of HTTPS sessions, auto-pause, paused safety-save,
  full-archive integrity, restore dry-run and all three systemd services.

## Release follow-ups

- [ ] Finish extracting production HTTP handlers/templates/static assets into
  `src/openrct2_manager`; the deployed compatibility file is generated and
  tested but remains large.
- [ ] Add byte progress and next-run timestamps to the background-job UI.
- [ ] Add an optional, explicitly verified age-encryption adapter. Current
  encryption must be enforced by SFTP/S3/rclone destination policy.
- [ ] Add a repeatable two-client OpenRCT2 integration test for join → unpause →
  leave → auto-pause and malformed/retried socket frames.
- [ ] Add browser automation for every portal role and mobile breakpoint. The
  current release has unit/render tests plus manual Chrome validation.
- [ ] Exercise install, upgrade, repair and destructive restore in a fresh
  disposable Ubuntu VM before a public release; the live host covered upgrade
  and restore dry-run only.
- [ ] Add release tag, changelog, installer checksum and migration notes when the
  owner authorises publishing. Do not publish this repository yet.
