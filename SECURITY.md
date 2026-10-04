# Security guidance

OpenRCT2 Server Manager controls a game server and serves private backup files. Treat an Owner or Administrator portal account as administrative access to the park and its saved player information.

## Safe deployment

- Prefer `MANAGER_DOMAIN` and HTTPS. Caddy obtains and renews certificates when DNS points to the server and ports 80/443 are reachable. Keep the manager's internal port closed externally.
- New installs without HTTPS bind the web panel to localhost. Use an SSH tunnel. Existing remote-HTTP installations must limit the web port to your own IP in the AWS security group. Never expose portal credentials or session cookies over public HTTP.
- The terminal installer prints a one-time browser-setup password. Only its PBKDF2 hash is persisted, attempts are throttled, and successful Owner creation writes a completion marker before consuming the hash. The legacy credential file contains no usable copy of the setup password, so deleting the portal-user database cannot resurrect it.
- `openrct2-manager-enable-https` must run as root. It validates a single hostname, requires working DNS and refuses to overwrite a Caddyfile it does not manage. It never changes AWS security groups or DNS records.
- Never expose `CONTROL_PORT` (`11754` by default) or the callback port. Both bind to `127.0.0.1`, require a random local token and accept only allow-listed structured actions.
- Keep Ubuntu and OpenRCT2 updated. Portal passwords are PBKDF2 hashes; HTTPS sessions are Secure, HttpOnly, SameSite=Strict and use per-session CSRF tokens. The legacy Basic-auth fallback exists only for upgrade compatibility and should not be used over HTTP.
- Download backups over HTTPS. Full archives contain portal password hashes, player identities and game state; store them privately and encrypt the destination. SFTP/S3/rclone credentials and private keys are deliberately excluded.
- The web Activity view is read-only apart from a strictly limited chat announcement. Do not add arbitrary shell or OpenRCT2 command execution to this interface without a separate security review.

## Reporting a vulnerability

Do not post exploit details or secrets in a public issue. Contact the repository maintainer privately using the security-reporting mechanism configured on the eventual hosting platform. Until this project has a public repository, report issues directly to the operator who gave you this software.

## Current limitations

This is a small self-hosted tool, not a multi-tenant control plane. It has individual RBAC accounts and permission-request approval, but has not had an independent security audit. Sessions and login throttles are process-local and are invalidated by manager restart. Remote archive encryption is a destination policy rather than an in-process feature. Destructive restore has a verifier and rollback archive but still requires a tested independent backup and maintenance window.
