# OpenRCT2 Server Manager rewrite

This document captures the agreed direction for the local prototype. It is an implementation contract, not a claim that these features are already deployed.

## Product goal

The manager should be the easiest safe way to operate a persistent OpenRCT2 server. Routine tasks should be obvious to a non-specialist, while dangerous or security-sensitive actions remain explicit and auditable.

## Primary navigation

1. **Overview** — live status, player count, current park, join address, discovery/password state, game chat, console, and five newest saves.
2. **Scenarios** — searchable scenario database, multi-file upload, format guidance, installed/latest OpenRCT2 version, and one-action launch.
3. **Saved games** — chronological save library with localised timestamps, source, actor, size, download, and resume actions; automatic save and full-archive controls; remote destinations.
4. **Players & commands** — retained player identities, OpenRCT2 roles, block state, and a separate in-game command allow-list.
5. **Portal users** — web accounts and role-based access.
6. **Activity** — game events, chat, command use, and an immutable portal audit trail.
7. **Server settings** — name, description, maximum players, public listing, advertised address, pause-when-empty, join password, and software version.

## Portal roles

| Capability | Owner | Administrator | Operator | Viewer |
|---|:---:|:---:|:---:|:---:|
| View status and logs | Yes | Yes | Yes | Yes |
| Start/stop/restart, chat | Yes | Yes | Yes | No |
| Upload/launch scenarios, resume/download saves | Yes | Yes | Yes | No |
| Change players, commands, schedules, server identity | Yes | Yes | No | No |
| Manage portal users and backup credentials | Yes | No | No | No |

Every mutating HTTP endpoint must check a server-side capability. UI visibility is not an authorisation control.

The existing installer web username becomes the first Owner during upgrade. A fresh install prompts for an Owner username, display name, and password. Passwords are stored using a memory-hard password hash where the Ubuntu runtime supports it, with PBKDF2-SHA256 as the dependency-free fallback. The application stores no plaintext portal password.

## Scenarios and version checks

- Accept `.park`, `.sc6`, and `.sv6`; recommend `.park`.
- Validate extension, safe filename, size, duplicate policy, and non-empty content before atomic placement.
- Show original filename, format, byte size, uploaded timestamp, uploader, and running state.
- Show the installed OpenRCT2 version and a cached result from the official GitHub releases feed. A failed internet check must not block local operation.
- Do not claim a scenario is compatible merely from its extension. OpenRCT2 remains the authority when it loads a file; failed launches should retain the previous selection and surface the relevant log excerpt.

## Save catalogue

The catalogue indexes manager snapshots, `/save` chat saves, OpenRCT2 autosaves, and other valid park saves. Each record exposes:

- canonical UTC creation time plus browser-local display time;
- source (`chat`, `automatic manager snapshot`, `OpenRCT2 autosave`, or `other`);
- initiating player where known;
- filename, format, size, and checksum;
- download and resume actions.

The Overview always shows the newest five. Resuming a save requires a confirmation explaining that players will disconnect. The source save is immutable; launch uses an atomic copy or an explicit source reference.

## In-game commands

The built-in set is `/help`, `/motd`, `/status`, `/players`, `/request <permission>`,
`/save [label]`, `/backup`, and `/restart` (plus documented aliases). Read-only discovery
commands are available to every authenticated player. Save, backup, and restart are separately
grantable per player; granting one never implies another.

`/save` creates a timestamped save without restarting the server. `/request scenery-brush`, for
example, creates a durable portal approval item tied to the player's public-key hash. It never
grants access automatically. An Administrator or Owner approves or rejects the request, and the
decision is audited before the per-player OpenRCT2 override is applied live.

The message of the day contains zero to five validated lines. It is sent privately after join,
can be replayed with `/motd`, persists in plug-in shared storage, and can be updated live without
restarting or disconnecting the game.

Commands are individually registered with a description, required capability, cooldown,
validation function, audit event, and private success/failure response. Plug-in callbacks use a
64-item acknowledged outbox with exponential backoff and durable manager-side event IDs.
Arbitrary shell execution is never exposed through game chat.

## Full manager backups

A full manager archive contains everything required to reconstruct the service:

- scenario library and selected scenario;
- all saved games and save catalogue metadata;
- OpenRCT2 user data, player identities, roles, and block list;
- portal accounts, role assignments, password hashes, and session-revocation metadata;
- server identity/discovery/password configuration;
- in-game command permissions, automatic-save schedule, and retention rules;
- manager configuration, audit metadata, and a manifest with schema and software versions.

Secrets are never written to logs. Provider credentials in archives are encrypted rather than stored in plaintext. The restore command validates the manifest and checksum before replacing any state and creates a rollback archive first.

## Off-server backups

Initial providers:

- SFTP using a dedicated SSH key;
- S3-compatible storage, covering AWS S3, Backblaze B2, and Cloudflare R2;
- an existing `rclone` remote for other providers.

Each destination has a schedule, retention policy, optional client-side encryption, connection test, last-success/last-error status, and a manual “Back up now” action. Transfers upload a completed immutable archive to a temporary remote name and rename/commit only after verification. Local backup creation succeeds independently if a remote destination is unavailable.

## Terminal installer

The supported entry point remains a terminal tool and gains a guided first-run mode:

1. check Ubuntu version, architecture, disk space, ports, and OpenRCT2;
2. choose new install, upgrade, repair, restore, or uninstall;
3. configure game port, name, description, public listing, address, password, and player limit;
4. configure manager hostname/HTTPS and firewall guidance;
5. create the initial Owner account without echoing its password;
6. optionally configure and test an off-server backup destination;
7. display a redacted review screen before writing anything;
8. install atomically, run health checks, and print the portal URL and recovery commands.

Non-interactive environment variables remain available for automation. Secrets may be passed by protected file descriptor or secret file; command-line arguments and process listings must not expose them.

## Upgrade safety

- Existing games are not restarted merely to update the web manager.
- Settings that OpenRCT2 reads only at startup are grouped into a single explicit “Save and restart” operation.
- Portal user, role, command permission, and non-runtime manager changes do not restart the game.
- Schema migrations are versioned, backed up, and idempotent.
