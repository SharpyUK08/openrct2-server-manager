# OpenRCT2 Server Manager

An independent, MIT-licensed web manager for a headless OpenRCT2 multiplayer
server on Ubuntu. The current standalone v3 installer is
[`outputs/install-openrct2-manager.sh`](outputs/install-openrct2-manager.sh).

## What it provides

- Apple-inspired responsive light/dark UI with a sticky navigation rail,
  persistent live activity console, Material-style icons and the supplied logo.
- HTTPS through Caddy, secure portal sessions, per-session CSRF, PBKDF2 password
  hashes, login throttling and Owner/Administrator/Operator/Viewer RBAC.
- Live player telemetry, retained key-based identities, one-off Kick, persistent
  Block, native group management and per-player Allow/Deny permission overlays.
- In-game `/help`, `/motd`, `/status`, `/players`, `/request`, `/save`, `/backup`
  and `/restart` commands. Powerful commands are granted by player key.
- Scenario database for `.park`, `.sv6`, `.sv4`, `.sc6` and `.sc4`, multi-upload,
  recoverable archiving, saved-game resume and transactional park switching.
- Empty-server auto-pause verification, native autosave settings and manager live
  snapshots. The dashboard distinguishes chat, automatic and safety saves.
- Downloadable full archives, a durable retrying SQLite job queue, scheduled
  SFTP/S3/rclone transfers, strict SFTP host keys and local/remote retention.
- Versioned state migration, structured hash-chained audit records, bounded SSE
  subscribers and an authenticated localhost OpenRCT2 plugin bridge.

## Install or upgrade

New to server administration? Follow the
[`Beginner installation guide`](docs/INSTALLATION.md) for AWS Lightsail, EC2,
other cloud providers and home-router port forwarding.

Requirements are Ubuntu Server 22.04/24.04, systemd, sudo and a compatible park.
OpenRCT2 does not need to be installed first: the installer detects an existing
v0.5.5+ executable and, when none is found, installs the release build from the
official OpenRCT2 Ubuntu PPA. If Ubuntu's packaged build is older than the
manager requires, it downloads the matching official GitHub release bundle,
verifies its published SHA-256 checksum and installs it under `/opt/openrct2`.
The executable and version are verified before services are created. Open
TCP `11753` for players. For HTTPS, point a DNS name at the host and open TCP
`80`/`443`; keep internal port `8080` private.

```bash
sudo env MANAGER_DOMAIN=parks.example.com \
  bash outputs/install-openrct2-manager.sh
```

For a fresh host, download the reviewed installer and run it locally so you can
inspect the exact file before granting root access:

```bash
curl -fL https://raw.githubusercontent.com/SharpyUK08/openrct2-server-manager/main/outputs/install-openrct2-manager.sh \
  -o install-openrct2-manager.sh
less install-openrct2-manager.sh
sudo bash install-openrct2-manager.sh
```

For a beginner-friendly installation, the complete download and installation
can be pasted as one command:

```bash
curl -fsSL https://raw.githubusercontent.com/SharpyUK08/openrct2-server-manager/main/outputs/install-openrct2-manager.sh -o /tmp/openrct2-manager-install.sh && sudo bash /tmp/openrct2-manager-install.sh
```

This executes code as root; the two-step version above is preferable when the
operator knows how to inspect a script.

The installer is idempotent and preserves an existing game configuration,
credential file and live park selection. On a fresh installation it prints a
one-time setup password. Open the manager through its HTTPS address or the SSH
tunnel shown by the installer; the browser guide then verifies the detected
OpenRCT2 executable, creates the first Owner, and configures the server name,
capacity, description, MOTD, discovery and pause-on-empty behaviour. The setup
password is stored only as a PBKDF2 hash and is permanently consumed when the
Owner is created. `WEB_USER` and a 16+ character `WEB_PASSWORD` may set the
suggested Owner name and one-time password. Existing upgrades keep their users.

Important optional variables are `GAME_PORT` (11753), `WEB_PORT` (8080),
`CONTROL_PORT` (11754), `MAX_UPLOAD_MB` (64), `BACKUP_RETENTION` (14),
`SERVER_NAME`, `GAME_PASSWORD`, `ADVERTISE`, `PAUSE_WHEN_EMPTY`, `MAX_PLAYERS`
and `RCT2_DATA_PATH`. A new install without `MANAGER_DOMAIN` binds the portal to
localhost unless `ALLOW_HTTP_REMOTE=true` is deliberately supplied.
`AUTO_INSTALL_OPENRCT2=false` makes a missing executable a hard error instead;
`OPENRCT2_INSTALL_CHANNEL=nightly` opts into the upstream nightly PPA. Release
is the default and recommended channel. A custom executable can be selected with
an absolute `OPENRCT2_BIN` path. `PUBLIC_ADDRESS` can override automatic public
IPv4 detection when a provider uses unusual networking.

The final setup screen can prepare a domain without giving the manager access
to a DNS or cloud account. First create an A/AAAA record for the server and open
inbound TCP 80 and 443 in the host firewall. Then run the exact guarded command
shown by the browser, for example:

```bash
sudo openrct2-manager-enable-https parks.example.com
```

The helper verifies that the hostname resolves, refuses to replace an unrelated
Caddy configuration, installs Caddy when needed, moves the manager to its
localhost-only bind and enables automatically renewed HTTPS. Port 8080 should
remain private. DNS and AWS/Lightsail firewall changes stay manual because the
manager has no cloud-account credentials.

Run local guided diagnostics and first-owner helpers with:

```bash
bin/openrct2-manager-installer doctor
sudo bin/openrct2-manager-installer init-owner
```

## Day-to-day operation

- The scenario page uploads, searches, launches and archives parks. A launch
  creates a live `pre-switch-…park`, changes the selection atomically, waits for
  helper health and automatically rolls back to the previous park on failure.
- Player role, block, command and individual permission changes apply live;
  they do not restart OpenRCT2. `PERMISSION_TOGGLE_SCENERY_CLUSTER` is exposed as
  the scenery brush/cluster permission.
- Server name, description, greeting/MOTD, capacity, password, advertised
  address, discovery, port, pause-on-empty and native autosave values are in
  Server settings. Game passwords are write-only.
- Full archives briefly stop and restart the game. Portal-triggered archive and
  remote-transfer work is queued, retried with exponential backoff and survives
  manager restarts.

The control and callback sockets bind only to `127.0.0.1`, require a random
token and accept an allow-list of structured actions—there is no arbitrary web
or in-game shell.

## Backup and recovery

Full archives explicitly include scenario/save/autosave data, `groups.json`,
`users.json`, `config.ini`, plugins, portal settings, roles and the durable job
database. A versioned manifest records every file's size and SHA-256. Transport
credentials, SFTP private keys and known-host data are excluded.

```bash
sudo openrct2-verify-backup /var/lib/openrct2/backups/openrct2-YYYYMMDDTHHMMSSZ.tar.gz
sudo openrct2-restore-backup --dry-run /path/to/openrct2-YYYYMMDDTHHMMSSZ.tar.gz
sudo openrct2-restore-backup --apply --confirm APPLY /path/to/openrct2-YYYYMMDDTHHMMSSZ.tar.gz
```

Apply mode refuses an unverified archive, creates a fresh rollback archive,
stops both services, restores only allow-listed trees, fixes ownership, runs
state migration and starts both services. Keep a copy outside the instance.
Optional client-side encryption is not silently implied: enforce encryption in
the destination or add an audited age/GPG adapter first.

## Services and important paths

| Path or service | Purpose |
| --- | --- |
| `openrct2.service` | Dedicated game server |
| `openrct2-manager.service` | Portal, workers, SSE and callback bridge |
| `/var/lib/openrct2/scenarios` | Active scenario library |
| `/var/lib/openrct2/scenario-archive` | Recoverably archived scenarios |
| `/var/lib/openrct2/user-data/save` | Chat saves, snapshots and autosaves |
| `/var/lib/openrct2/backups` | Full archives |
| `/var/lib/openrct2-manager` | Portal state, jobs, selection and audit chain |
| `/etc/openrct2-manager` | Host configuration and protected credentials |

Useful checks:

```bash
sudo systemctl status openrct2 openrct2-manager caddy
sudo journalctl -u openrct2 -n 100
sudo journalctl -u openrct2-manager -n 100
sudo -u openrct2 python3 /usr/local/lib/openrct2-manager.py --verify-audit
```

## Development

```bash
ruby work/sync-production-installer.rb
python3 -m unittest discover -s tests -v
bash -n outputs/install-openrct2-manager.sh production/openrct2-backup production/openrct2-restore-backup production/openrct2-manager-enable-https
```

The tests cover modular primitives and the exact installer-embedded runtime.
OpenRCT2 is still required for plugin integration checks. See
[`docs/ARCHITECTURE-REVIEW.md`](docs/ARCHITECTURE-REVIEW.md),
[`docs/REMAINING-WORK.md`](docs/REMAINING-WORK.md), [`SECURITY.md`](SECURITY.md)
and [`CONTRIBUTING.md`](CONTRIBUTING.md).

MIT licensed; see [`LICENSE`](LICENSE).
