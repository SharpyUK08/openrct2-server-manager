#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

# OpenRCT2 dedicated server + small web manager for Ubuntu Server.
# Designed for Ubuntu 22.04/24.04 (amd64 or arm64 via the OpenRCT2 PPA).
#
# Optional environment variables:
#   WEB_USER=admin
#   WEB_PASSWORD='a-long-random-password'  # generated when omitted
#   WEB_PORT=8080
#   MANAGER_DOMAIN=parks.example.com          # enables HTTPS via Caddy
#   CONTROL_PORT=11754                      # local-only chat bridge
#   ALLOW_HTTP_REMOTE=true                   # opt in to remote HTTP without TLS
#   GAME_PORT=11753
#   SERVER_NAME='My OpenRCT2 Server'
#   GAME_PASSWORD=''                       # blank allows passwordless joining
#   ADVERTISE=true
#   PAUSE_WHEN_EMPTY=true
#   MAX_PLAYERS=16
#   MAX_UPLOAD_MB=64
#   BACKUP_RETENTION=14
#   RCT2_DATA_PATH=/path/to/legal/RCT2/files # usually unnecessary for .park saves
#   AUTO_INSTALL_OPENRCT2=true              # install from the official PPA when absent
#   OPENRCT2_INSTALL_CHANNEL=release         # release or nightly
#   PUBLIC_ADDRESS=203.0.113.10              # auto-detected when omitted
#
# Run with: sudo -E bash install-openrct2-manager.sh
# Upgrades leave an already-running game untouched. Restart it when safe to
# activate the new in-game helper; restarting may lose changes since last save.

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this installer as root (for example: sudo -E bash $0)." >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify this operating system." >&2
  exit 1
fi
. /etc/os-release
if [[ ${ID:-} != ubuntu ]]; then
  echo "This installer supports Ubuntu Server only (found: ${ID:-unknown})." >&2
  exit 1
fi

existing_server_env=false
[[ -r /etc/openrct2-manager/server.env ]] && existing_server_env=true
declare -A requested_values=()
for setting_name in OPENRCT2_BIN WEB_PORT WEB_BIND GAME_PORT RCT2_DATA_PATH BACKUP_RETENTION MAX_UPLOAD_MB MANAGER_DOMAIN CONTROL_PORT PUBLIC_ADDRESS; do
  if declare -p "$setting_name" >/dev/null 2>&1; then
    requested_values[$setting_name]=${!setting_name}
  fi
done
if [[ -r /etc/openrct2-manager/server.env ]]; then
  . /etc/openrct2-manager/server.env
fi
for setting_name in "${!requested_values[@]}"; do
  printf -v "$setting_name" '%s' "${requested_values[$setting_name]}"
done
if [[ -r /etc/openrct2-manager/web-credentials ]]; then
  existing_credentials=$(</etc/openrct2-manager/web-credentials)
  WEB_USER=${WEB_USER:-${existing_credentials%%:*}}
  WEB_PASSWORD=${WEB_PASSWORD:-${existing_credentials#*:}}
fi
WEB_USER=${WEB_USER:-admin}
WEB_PORT=${WEB_PORT:-8080}
GAME_PORT=${GAME_PORT:-11753}
SERVER_NAME=${SERVER_NAME:-My OpenRCT2 Server}
GAME_PASSWORD=${GAME_PASSWORD:-}
ADVERTISE=${ADVERTISE:-true}
PAUSE_WHEN_EMPTY=${PAUSE_WHEN_EMPTY:-true}
MAX_PLAYERS=${MAX_PLAYERS:-16}
MAX_UPLOAD_MB=${MAX_UPLOAD_MB:-64}
BACKUP_RETENTION=${BACKUP_RETENTION:-14}
RCT2_DATA_PATH=${RCT2_DATA_PATH:-}
MANAGER_DOMAIN=${MANAGER_DOMAIN:-}
CONTROL_PORT=${CONTROL_PORT:-11754}
ALLOW_HTTP_REMOTE=${ALLOW_HTTP_REMOTE:-false}
AUTO_INSTALL_OPENRCT2=${AUTO_INSTALL_OPENRCT2:-true}
OPENRCT2_INSTALL_CHANNEL=${OPENRCT2_INSTALL_CHANNEL:-release}
PUBLIC_ADDRESS=${PUBLIC_ADDRESS:-}
if [[ -n $MANAGER_DOMAIN ]]; then
  WEB_BIND=127.0.0.1
elif [[ -z ${WEB_BIND:-} ]]; then
  if [[ $existing_server_env == true || $ALLOW_HTTP_REMOTE == true ]]; then
    WEB_BIND=0.0.0.0
  else
    WEB_BIND=127.0.0.1
  fi
fi

is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
is_uint() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 )); }
is_bool() { [[ $1 == true || $1 == false ]]; }
is_ipv4() {
  local value=$1 octet
  [[ $value =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  local IFS=.; read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]+$ ]] && (( 10#$octet <= 255 )) || return 1
  done
}

is_port "$WEB_PORT" || { echo "WEB_PORT must be 1-65535." >&2; exit 1; }
is_port "$GAME_PORT" || { echo "GAME_PORT must be 1-65535." >&2; exit 1; }
is_port "$CONTROL_PORT" || { echo "CONTROL_PORT must be 1-65535." >&2; exit 1; }
[[ $WEB_PORT != "$GAME_PORT" ]] || { echo "WEB_PORT and GAME_PORT must differ." >&2; exit 1; }
[[ $CONTROL_PORT != "$GAME_PORT" && $CONTROL_PORT != "$WEB_PORT" ]] || { echo "CONTROL_PORT must differ from both other ports." >&2; exit 1; }
if [[ -n $MANAGER_DOMAIN && ! $MANAGER_DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; then
  echo "MANAGER_DOMAIN must be a public DNS name, for example parks.example.com." >&2
  exit 1
fi
if [[ -n $MANAGER_DOMAIN && -s /etc/caddy/Caddyfile ]] && \
   ! grep -q '^# Managed by OpenRCT2 Manager$' /etc/caddy/Caddyfile; then
  echo "A Caddy configuration already exists. Configure HTTPS manually or move that configuration aside before using MANAGER_DOMAIN." >&2
  exit 1
fi
is_uint "$MAX_PLAYERS" || { echo "MAX_PLAYERS must be a positive integer." >&2; exit 1; }
is_uint "$MAX_UPLOAD_MB" || { echo "MAX_UPLOAD_MB must be a positive integer." >&2; exit 1; }
is_uint "$BACKUP_RETENTION" || { echo "BACKUP_RETENTION must be a positive integer." >&2; exit 1; }
is_bool "$ADVERTISE" || { echo "ADVERTISE must be true or false." >&2; exit 1; }
is_bool "$PAUSE_WHEN_EMPTY" || { echo "PAUSE_WHEN_EMPTY must be true or false." >&2; exit 1; }
is_bool "$ALLOW_HTTP_REMOTE" || { echo "ALLOW_HTTP_REMOTE must be true or false." >&2; exit 1; }
is_bool "$AUTO_INSTALL_OPENRCT2" || { echo "AUTO_INSTALL_OPENRCT2 must be true or false." >&2; exit 1; }
[[ $OPENRCT2_INSTALL_CHANNEL == release || $OPENRCT2_INSTALL_CHANNEL == nightly ]] || {
  echo "OPENRCT2_INSTALL_CHANNEL must be release or nightly." >&2
  exit 1
}
[[ $WEB_BIND == 127.0.0.1 || $WEB_BIND == 0.0.0.0 ]] || { echo "WEB_BIND must be 127.0.0.1 or 0.0.0.0." >&2; exit 1; }
[[ $WEB_USER =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { echo "WEB_USER contains unsupported characters." >&2; exit 1; }
[[ -z $PUBLIC_ADDRESS ]] || is_ipv4 "$PUBLIC_ADDRESS" || { echo "PUBLIC_ADDRESS must be a valid IPv4 address." >&2; exit 1; }

generated_password=false
existing_password=false
[[ -r /etc/openrct2-manager/web-credentials ]] && existing_password=true
if [[ -n ${WEB_PASSWORD:-} ]] && (( ${#WEB_PASSWORD} < 12 )); then
  echo "WEB_PASSWORD must contain at least 12 characters." >&2
  exit 1
fi
for value in "$SERVER_NAME" "$GAME_PASSWORD" "${WEB_PASSWORD:-}" "$RCT2_DATA_PATH"; do
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || { echo "Configuration values may not contain line breaks." >&2; exit 1; }
done

echo "Installing operating-system packages and checking OpenRCT2..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl python3 software-properties-common sudo

CLOUD_PROVIDER='Cloud/VPS provider'
detect_public_ipv4() {
  local token candidate
  if [[ -n $PUBLIC_ADDRESS ]]; then return 0; fi
  token=$(curl --noproxy '*' -fsS --max-time 2 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token 2>/dev/null || true)
  if [[ -n $token ]]; then
    candidate=$(curl --noproxy '*' -fsS --max-time 2 \
      -H "X-aws-ec2-metadata-token: $token" \
      http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
    if is_ipv4 "$candidate"; then PUBLIC_ADDRESS=$candidate; CLOUD_PROVIDER='Amazon Web Services'; return 0; fi
  fi
  candidate=$(curl -fsS --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
  if is_ipv4 "$candidate"; then PUBLIC_ADDRESS=$candidate; return 0; fi
  return 1
}
if detect_public_ipv4; then
  echo "Detected public server address: ${PUBLIC_ADDRESS} (${CLOUD_PROVIDER})."
else
  echo "Public IPv4 could not be detected. You can enter it later in Server settings."
fi
if [[ -z ${WEB_PASSWORD:-} ]]; then
  WEB_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
  generated_password=true
fi
find_openrct2() {
  local candidate
  for candidate in \
    "${OPENRCT2_BIN:-}" \
    /opt/openrct2/openrct2-cli \
    /usr/games/openrct2-cli \
    /usr/games/openrct2 \
    /usr/bin/openrct2-cli \
    /usr/bin/openrct2; do
    if [[ -n $candidate && -x $candidate ]]; then
      readlink -f "$candidate"
      return 0
    fi
  done
  for candidate in openrct2-cli openrct2; do
    if command -v "$candidate" >/dev/null 2>&1; then
      readlink -f "$(command -v "$candidate")"
      return 0
    fi
  done
  return 1
}

openrct2_version_supported() {
  local text=$1 major minor patch
  if [[ $text =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}; patch=${BASH_REMATCH[3]}
    (( major > 0 || minor > 5 || (minor == 5 && patch >= 5) ))
  else
    return 1
  fi
}

release_stage=''
cleanup_release_stage() {
  if [[ ${release_stage:-} == /tmp/openrct2-release.* && -d $release_stage ]]; then
    rm -rf -- "$release_stage"
  fi
}
trap cleanup_release_stage EXIT

install_openrct2_release_bundle() {
  local architecture codename metadata asset_name asset_url checksum_url expected_sha target binary
  architecture=$(dpkg --print-architecture)
  if [[ $architecture != amd64 ]]; then
    echo "The official OpenRCT2 release bundle is currently available only for amd64 (found: ${architecture})." >&2
    echo "Install OpenRCT2 v0.5.5+ yourself and set OPENRCT2_BIN to its executable." >&2
    return 1
  fi
  codename=${VERSION_CODENAME:-noble}
  release_stage=$(mktemp -d /tmp/openrct2-release.XXXXXX)
  metadata=$release_stage/release.json
  echo "The Ubuntu package is too old; downloading the current official OpenRCT2 release bundle..."
  curl -fsSL --retry 3 --connect-timeout 15 \
    https://api.github.com/repos/OpenRCT2/OpenRCT2/releases/latest -o "$metadata"
  mapfile -t release_details < <(python3 - "$metadata" "$codename" <<'PYRELEASE'
import json, re, sys
release = json.load(open(sys.argv[1], encoding='utf-8'))
tag = str(release.get('tag_name', ''))
if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
    raise SystemExit('The official release API returned an invalid version tag.')
assets = release.get('assets', [])
names = [f'-Linux-{sys.argv[2]}-x86_64.tar.gz', '-linux-x86_64.AppImage']
selected = next((asset for suffix in names for asset in assets
                 if str(asset.get('name', '')).endswith(suffix)), None)
checksums = next((asset for asset in assets
                  if str(asset.get('name', '')).endswith('-sha256sums.txt')), None)
if not selected or not checksums:
    raise SystemExit(f'No supported Linux bundle or checksum file was published for {tag}.')
for value in (tag, selected['name'], selected['browser_download_url'], checksums['browser_download_url']):
    print(value)
PYRELEASE
  )
  if (( ${#release_details[@]} != 4 )); then
    echo "Could not identify a supported asset in the official OpenRCT2 release." >&2
    return 1
  fi
  OPENRCT2_RELEASE_TAG=${release_details[0]}
  asset_name=${release_details[1]}
  asset_url=${release_details[2]}
  checksum_url=${release_details[3]}
  for asset_url_check in "$asset_url" "$checksum_url"; do
    [[ $asset_url_check == https://github.com/OpenRCT2/OpenRCT2/releases/download/* ]] || {
      echo "The release API returned an unexpected download host." >&2; return 1;
    }
  done
  curl -fL --retry 3 --connect-timeout 15 "$asset_url" -o "$release_stage/$asset_name"
  curl -fsSL --retry 3 --connect-timeout 15 "$checksum_url" -o "$release_stage/sha256sums.txt"
  expected_sha=$(awk -v name="$asset_name" '$2 == name || $2 == "./" name {print $1; exit}' "$release_stage/sha256sums.txt")
  [[ $expected_sha =~ ^[0-9a-fA-F]{64}$ ]] || { echo "No SHA-256 was published for ${asset_name}." >&2; return 1; }
  printf '%s  %s\n' "$expected_sha" "$release_stage/$asset_name" | sha256sum -c -
  install -d -m 0755 /opt/openrct2/releases
  target=/opt/openrct2/releases/$OPENRCT2_RELEASE_TAG
  if [[ ! -d $target ]]; then
    install -d -m 0755 "$release_stage/extracted"
    if [[ $asset_name == *.tar.gz ]]; then
      if tar -tzf "$release_stage/$asset_name" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
        echo "The OpenRCT2 archive contains an unsafe path." >&2; return 1
      fi
      tar -xzf "$release_stage/$asset_name" -C "$release_stage/extracted" --no-same-owner --no-same-permissions
    else
      chmod 0755 "$release_stage/$asset_name"
      (cd "$release_stage/extracted" && "$release_stage/$asset_name" --appimage-extract >/dev/null)
    fi
    mv "$release_stage/extracted" "$target"
  fi
  binary=$(find "$target" -maxdepth 5 -type f \( -name openrct2-cli -o -name openrct2 \) -perm -0100 -print -quit)
  [[ -n $binary ]] || { echo "The verified OpenRCT2 bundle contained no executable." >&2; return 1; }
  ln -sfn "$binary" /opt/openrct2/openrct2-cli
  OPENRCT2_BIN=/opt/openrct2/openrct2-cli
}

openrct2_was_installed=false
if detected_openrct2=$(find_openrct2); then
  OPENRCT2_BIN=$detected_openrct2
  echo "Found OpenRCT2 at ${OPENRCT2_BIN}."
else
  if [[ $AUTO_INSTALL_OPENRCT2 != true ]]; then
    echo "OpenRCT2 was not found and automatic installation is disabled." >&2
    echo "Install it first, set OPENRCT2_BIN, or rerun with AUTO_INSTALL_OPENRCT2=true." >&2
    exit 1
  fi
  ppa_channel=master
  [[ $OPENRCT2_INSTALL_CHANNEL == nightly ]] && ppa_channel=nightly
  echo "OpenRCT2 was not found. Installing the ${OPENRCT2_INSTALL_CHANNEL} build from ppa:openrct2/${ppa_channel}..."
  add-apt-repository -y "ppa:openrct2/${ppa_channel}"
  apt-get update
  if ! apt-get install -y --no-install-recommends openrct2; then
    echo "OpenRCT2 installation failed. Review the apt output above, then rerun this installer." >&2
    exit 1
  fi
  unset OPENRCT2_BIN
  if ! detected_openrct2=$(find_openrct2); then
    echo "The OpenRCT2 package installed, but its executable could not be located." >&2
    echo "Set OPENRCT2_BIN to the full executable path and rerun the installer." >&2
    exit 1
  fi
  OPENRCT2_BIN=$detected_openrct2
  openrct2_was_installed=true
fi
version_line=$("$OPENRCT2_BIN" --version 2>/dev/null | head -n 1 || true)
if ! openrct2_version_supported "$version_line"; then
  if [[ $AUTO_INSTALL_OPENRCT2 == true ]]; then
    echo "OpenRCT2 v0.5.5 or newer is required (found: ${version_line:-unknown})."
    install_openrct2_release_bundle
    openrct2_was_installed=true
    version_line=$("$OPENRCT2_BIN" --version 2>/dev/null | head -n 1 || true)
  fi
  if ! openrct2_version_supported "$version_line"; then
    echo "OpenRCT2 v0.5.5 or newer is needed for the manager helper (found: ${version_line:-unknown})." >&2
    exit 1
  fi
fi
if [[ $openrct2_was_installed == true ]]; then
  echo "Installed and verified ${version_line} at ${OPENRCT2_BIN}."
else
  echo "Verified ${version_line}."
fi

if ! id openrct2 >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/openrct2 --create-home --shell /usr/sbin/nologin openrct2
fi
usermod -a -G systemd-journal openrct2 2>/dev/null || true

install -d -o openrct2 -g openrct2 -m 0750 \
  /var/lib/openrct2 \
  /var/lib/openrct2/user-data \
  /var/lib/openrct2/user-data/plugin \
  /var/lib/openrct2/user-data/save \
  /var/lib/openrct2/scenarios \
  /var/lib/openrct2/scenario-archive \
  /var/lib/openrct2/backups \
  /var/lib/openrct2-manager
install -d -o root -g openrct2 -m 0750 /etc/openrct2-manager
install -d -o root -g root -m 0755 /usr/local/share/openrct2-manager
if [[ -f $(dirname -- "${BASH_SOURCE[0]}")/openrct2-manager-logo.png ]]; then
  install -o root -g root -m 0644 \
    "$(dirname -- "${BASH_SOURCE[0]}")/openrct2-manager-logo.png" \
    /usr/local/share/openrct2-manager/logo.png
fi

ini_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

if [[ ! -e /var/lib/openrct2/user-data/config.ini ]]; then
cat > /var/lib/openrct2/user-data/config.ini <<EOF
[network]
default_port = ${GAME_PORT}
server_name = "$(ini_escape "$SERVER_NAME")"
default_password = "$(ini_escape "$GAME_PASSWORD")"
advertise = ${ADVERTISE}
advertise_address = "$(ini_escape "$PUBLIC_ADDRESS")"
pause_server_if_no_clients = ${PAUSE_WHEN_EMPTY}
maxplayers = ${MAX_PLAYERS}
EOF
chown openrct2:openrct2 /var/lib/openrct2/user-data/config.ini
chmod 0640 /var/lib/openrct2/user-data/config.ini
fi

# Preserve an operator's existing address, but repair a blank/missing value left
# by an interrupted fresh installation.
if [[ -n $PUBLIC_ADDRESS ]]; then
  python3 - /var/lib/openrct2/user-data/config.ini "$PUBLIC_ADDRESS" <<'PYADDRESS'
import os, re, sys, tempfile
path, address = sys.argv[1:]
lines = open(path, encoding='utf-8').read().splitlines()
start = next((i for i, line in enumerate(lines) if line.strip().lower() == '[network]'), None)
if start is not None:
    end = next((i for i in range(start + 1, len(lines)) if re.fullmatch(r'\s*\[[^]]+\]\s*', lines[i])), len(lines))
    match = next((i for i in range(start + 1, end) if re.match(r'\s*advertise_address\s*=', lines[i], re.I)), None)
    if match is None:
        lines.insert(start + 1, f'advertise_address = "{address}"')
    elif lines[match].split('=', 1)[1].strip() in ('', '""'):
        lines[match] = f'advertise_address = "{address}"'
    else:
        raise SystemExit(0)
    fd, temporary = tempfile.mkstemp(prefix='.config.', dir=os.path.dirname(path), text=True)
    with os.fdopen(fd, 'w', encoding='utf-8') as handle:
        handle.write('\n'.join(lines) + '\n')
        handle.flush(); os.fsync(handle.fileno())
    os.replace(temporary, path)
PYADDRESS
  chown openrct2:openrct2 /var/lib/openrct2/user-data/config.ini
  chmod 0640 /var/lib/openrct2/user-data/config.ini
fi

{
  printf 'OPENRCT2_BIN=%q\n' "$OPENRCT2_BIN"
  printf 'GAME_PORT=%q\n' "$GAME_PORT"
  printf 'RCT2_DATA_PATH=%q\n' "$RCT2_DATA_PATH"
  printf 'BACKUP_RETENTION=%q\n' "$BACKUP_RETENTION"
  printf 'MAX_UPLOAD_MB=%q\n' "$MAX_UPLOAD_MB"
  printf 'WEB_PORT=%q\n' "$WEB_PORT"
  printf 'WEB_BIND=%q\n' "$WEB_BIND"
  printf 'MANAGER_DOMAIN=%q\n' "$MANAGER_DOMAIN"
  printf 'CONTROL_PORT=%q\n' "$CONTROL_PORT"
} > /etc/openrct2-manager/server.env
chown root:openrct2 /etc/openrct2-manager/server.env
chmod 0640 /etc/openrct2-manager/server.env

if [[ $existing_server_env == false ]]; then
  # The browser setup password is persisted only as a PBKDF2 hash in first-run.json.
  # Keep the legacy credential file structurally valid without retaining that secret.
  printf '%s:%s\n' "$WEB_USER" '!browser-first-run-disabled!' > /etc/openrct2-manager/web-credentials
else
  printf '%s:%s\n' "$WEB_USER" "$WEB_PASSWORD" > /etc/openrct2-manager/web-credentials
fi
chown root:openrct2 /etc/openrct2-manager/web-credentials
chmod 0640 /etc/openrct2-manager/web-credentials

cat > /usr/local/sbin/openrct2-run-server <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/openrct2-manager/server.env
SCENARIO_ROOT=/var/lib/openrct2/scenarios
SELECTION_FILE=/var/lib/openrct2-manager/selected-scenario
USER_DATA=/var/lib/openrct2/user-data

[[ -s $SELECTION_FILE ]] || { echo "No scenario has been selected in the web manager." >&2; exit 2; }
scenario=$(<"$SELECTION_FILE")
[[ $scenario != */* && $scenario != *\\* && $scenario != .* ]] || { echo "Invalid scenario selection." >&2; exit 2; }
case "${scenario,,}" in
  *.park|*.sv6|*.sv4|*.sc6|*.sc4) ;;
  *) echo "Unsupported scenario/save extension." >&2; exit 2 ;;
esac
scenario_path="$SCENARIO_ROOT/$scenario"
[[ -f $scenario_path ]] || { echo "Selected scenario does not exist: $scenario" >&2; exit 2; }

args=(host "$scenario_path" --port "$GAME_PORT" --headless --user-data-path "$USER_DATA")
if [[ -n ${RCT2_DATA_PATH:-} ]]; then
  args+=(--rct2-data-path "$RCT2_DATA_PATH")
fi
exec "$OPENRCT2_BIN" "${args[@]}"
RUNNER
chmod 0755 /usr/local/sbin/openrct2-run-server

cat > /usr/local/sbin/openrct2-backup <<'BACKUP'
set -Eeuo pipefail

. /etc/openrct2-manager/server.env
BACKUP_DIR=/var/lib/openrct2/backups
stamp=$(date -u +%Y%m%dT%H%M%SZ)
archive="$BACKUP_DIR/openrct2-$stamp.tar.gz"
stage=$(mktemp -d "$BACKUP_DIR/.archive-stage.XXXXXX")
was_active=false

cleanup() {
  rm -rf -- "$stage"
  if [[ $was_active == true ]] && ! systemctl is-active --quiet openrct2.service; then
    systemctl start openrct2.service
  fi
}
trap cleanup EXIT

if systemctl is-active --quiet openrct2.service; then
  was_active=true
  systemctl stop openrct2.service
fi

install -d -m 0750 "$stage/ServerData" "$stage/manager-state" "$stage/scenarios" "$stage/scenario-archive" "$stage/host-config"
for source in save autosave plugin; do
  [[ -e /var/lib/openrct2/user-data/$source ]] && cp -a -- "/var/lib/openrct2/user-data/$source" "$stage/ServerData/$source"
done
for source in groups.json users.json config.ini plugin.store.json; do
  [[ -e /var/lib/openrct2/user-data/$source ]] && cp -a -- "/var/lib/openrct2/user-data/$source" "$stage/ServerData/$source"
done
cp -a -- /var/lib/openrct2/scenarios/. "$stage/scenarios/"
[[ -d /var/lib/openrct2/scenario-archive ]] && cp -a -- /var/lib/openrct2/scenario-archive/. "$stage/scenario-archive/"
# SQLite databases must not be copied while the manager worker may be writing.
# Copy atomic JSON state normally and snapshot the durable queue with SQLite's
# online backup API below.
find /var/lib/openrct2-manager -maxdepth 1 -type f ! -name 'jobs.sqlite3*' -exec cp -a -- {} "$stage/manager-state/" \;
if [[ -f /var/lib/openrct2-manager/jobs.sqlite3 ]]; then
  SOURCE_DB=/var/lib/openrct2-manager/jobs.sqlite3 TARGET_DB="$stage/manager-state/jobs.sqlite3" /usr/bin/python3 - <<'PY'
import os, sqlite3
source = sqlite3.connect(f"file:{os.environ['SOURCE_DB']}?mode=ro", uri=True)
target = sqlite3.connect(os.environ['TARGET_DB'])
with target: source.backup(target)
target.close(); source.close()
PY
fi
cp -a -- /etc/openrct2-manager/server.env "$stage/host-config/server.env"

STAGE_ROOT=$stage ARCHIVE_NAME=$(basename -- "$archive") /usr/bin/python3 - <<'PY'
import hashlib, json, os
from datetime import datetime, timezone
from pathlib import Path

root = Path(os.environ['STAGE_ROOT'])
files = []
for path in sorted(item for item in root.rglob('*') if item.is_file() and item.name != 'manifest.json'):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    files.append({'path': path.relative_to(root).as_posix(), 'size': path.stat().st_size,
                  'sha256': digest.hexdigest()})
manifest = {'schema': 1, 'created_at': datetime.now(timezone.utc).isoformat(),
            'archive': os.environ['ARCHIVE_NAME'], 'files': files,
            'secret_policy': 'Portal password hashes are included; transport credentials and SFTP private keys are excluded.'}
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY

/usr/bin/tar --create --gzip --file "$archive.uploading" --directory "$stage" .
chmod 0640 "$archive.uploading"
mv -- "$archive.uploading" "$archive"

mapfile -t old_backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'openrct2-*.tar.gz' -printf '%T@ %p\n' | sort -rn | tail -n "+$((BACKUP_RETENTION + 1))" | cut -d' ' -f2-)
if ((${#old_backups[@]})); then rm -f -- "${old_backups[@]}"; fi
printf '%s\n' "$archive"
BACKUP
chmod 0755 /usr/local/sbin/openrct2-backup
cat > /usr/local/sbin/openrct2-verify-backup <<'VERIFY'
"""Read-only archive manifest/checksum and traversal validation."""
import hashlib
import json
import re
import sys
import tarfile
from pathlib import PurePosixPath

if len(sys.argv) != 2:
    raise SystemExit('Usage: openrct2-verify-backup ARCHIVE.tar.gz')
path = sys.argv[1]
if not re.search(r'openrct2-[0-9]{8}T[0-9]{6}Z\.tar\.gz\Z', path.rsplit('/', 1)[-1]):
    raise SystemExit('Refusing an unexpected archive filename.')
with tarfile.open(path, 'r:gz') as archive:
    members = archive.getmembers()
    for member in members:
        name = member.name.removeprefix('./')
        parts = PurePosixPath(name).parts
        if (not (member.isfile() or member.isdir()) or member.issym() or member.islnk() or
                name.startswith('/') or '..' in parts):
            raise SystemExit(f'Unsafe archive member: {member.name}')
    manifest_member = next((item for item in members if item.name.removeprefix('./') == 'manifest.json'), None)
    if manifest_member is None or manifest_member.size > 10 * 1024 * 1024:
        raise SystemExit('Missing or oversized manifest.json.')
    manifest = json.load(archive.extractfile(manifest_member))
    if manifest.get('schema') != 1 or not isinstance(manifest.get('files'), list):
        raise SystemExit('Unsupported manifest schema.')
    indexed = {item.name.removeprefix('./'): item for item in members if item.isfile()}
    records = manifest['files']
    if len(records) != len({record.get('path') for record in records}):
        raise SystemExit('Manifest contains duplicate paths.')
    if set(indexed) - {'manifest.json'} != {record.get('path') for record in records}:
        raise SystemExit('Archive and manifest file lists differ.')
    for record in records:
        name = record.get('path'); member = indexed.get(name)
        if member is None or member.size != record.get('size'):
            raise SystemExit(f'Missing or wrong-sized member: {name}')
        digest = hashlib.sha256()
        stream = archive.extractfile(member)
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
        if digest.hexdigest() != record.get('sha256'):
            raise SystemExit(f'Checksum mismatch: {name}')
print(f'Archive verified: {path} ({len(manifest["files"])} files)')
VERIFY
chmod 0755 /usr/local/sbin/openrct2-verify-backup
cat > /usr/local/sbin/openrct2-restore-backup <<'RESTORE'
# Validate or restore a complete manager archive. Apply is intentionally local,
# explicit, and creates a rollback archive before changing live data.
set -Eeuo pipefail

usage() { echo "Usage: openrct2-restore-backup --dry-run ARCHIVE | --apply --confirm APPLY ARCHIVE" >&2; exit 2; }
mode=${1:-}; shift || true
confirm=
if [[ $mode == --apply && ${1:-} == --confirm ]]; then confirm=${2:-}; shift 2 || true; fi
archive=${1:-}
[[ -n $archive && $# -eq 1 && -f $archive ]] || usage
/usr/local/sbin/openrct2-verify-backup "$archive"

if [[ $mode == --dry-run ]]; then
  /usr/bin/python3 - "$archive" <<'PY'
import json, sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as source:
    member = next(item for item in source.getmembers() if item.name.removeprefix('./') == 'manifest.json')
    manifest = json.load(source.extractfile(member))
print(f"Restore dry-run passed: {len(manifest['files'])} files; created {manifest.get('created_at', 'unknown')}")
PY
  exit 0
fi
[[ $mode == --apply && $confirm == APPLY && ${EUID} -eq 0 ]] || usage

rollback=$(/usr/local/sbin/openrct2-backup)
stage=$(mktemp -d /var/lib/openrct2/backups/.restore-stage.XXXXXX)
cleanup() {
  rm -rf -- "$stage"
  systemctl start openrct2-manager.service >/dev/null 2>&1 || true
  systemctl start openrct2.service >/dev/null 2>&1 || true
}
trap cleanup EXIT
systemctl stop openrct2.service openrct2-manager.service
/usr/bin/tar --extract --gzip --file "$archive" --directory "$stage" --no-same-owner --no-same-permissions

for pair in \
  "ServerData:/var/lib/openrct2/user-data" \
  "scenarios:/var/lib/openrct2/scenarios" \
  "scenario-archive:/var/lib/openrct2/scenario-archive" \
  "manager-state:/var/lib/openrct2-manager"; do
  source=${pair%%:*}; destination=${pair#*:}
  [[ -d $stage/$source ]] || continue
  install -d -o openrct2 -g openrct2 -m 0750 "$destination"
  cp -a -- "$stage/$source/." "$destination/"
done
chown -R openrct2:openrct2 /var/lib/openrct2/user-data /var/lib/openrct2/scenarios \
  /var/lib/openrct2/scenario-archive /var/lib/openrct2-manager
runuser -u openrct2 -- /usr/bin/python3 /usr/local/lib/openrct2-manager.py --setup
systemctl start openrct2-manager.service openrct2.service
trap - EXIT
rm -rf -- "$stage"
printf 'Restore complete. Pre-restore rollback archive: %s\n' "$rollback"
RESTORE
chmod 0755 /usr/local/sbin/openrct2-restore-backup
cat > /usr/local/sbin/openrct2-manager-enable-https <<'HTTPSHELPER'
set -Eeuo pipefail

if [[ ${EUID} -ne 0 || $# -ne 1 ]]; then
  echo "Usage: sudo openrct2-manager-enable-https parks.example.com" >&2
  exit 2
fi
domain=${1,,}
if [[ ! $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}$ ]]; then
  echo "Enter a hostname such as parks.example.com, without https:// or a path." >&2
  exit 2
fi
if ! getent ahostsv4 "$domain" >/dev/null; then
  echo "DNS does not resolve yet. Create the A record, wait for it to propagate, then retry." >&2
  exit 1
fi
if [[ -s /etc/caddy/Caddyfile ]] && ! grep -q '^# Managed by OpenRCT2 Manager$' /etc/caddy/Caddyfile; then
  echo "An unmanaged Caddy configuration exists; refusing to overwrite it." >&2
  exit 1
fi
. /etc/openrct2-manager/server.env

if ! command -v caddy >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https curl gpg
  curl -1fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
    gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    -o /etc/apt/sources.list.d/caddy-stable.list
  chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y --no-install-recommends caddy
fi

cat > /etc/caddy/Caddyfile <<EOF
# Managed by OpenRCT2 Manager
${domain} {
  encode zstd gzip
  reverse_proxy 127.0.0.1:${WEB_PORT}
}
EOF
caddy validate --config /etc/caddy/Caddyfile >/dev/null
sed -i -E "s/^MANAGER_DOMAIN=.*/MANAGER_DOMAIN=${domain}/; s/^WEB_BIND=.*/WEB_BIND=127.0.0.1/" /etc/openrct2-manager/server.env
systemctl enable --now caddy.service >/dev/null
systemctl reload caddy.service
systemctl restart openrct2-manager.service
echo "HTTPS provisioning started for https://${domain}/"
echo "Caddy obtains the certificate automatically. Ensure public TCP 80 and 443 are open."
HTTPSHELPER
chmod 0755 /usr/local/sbin/openrct2-manager-enable-https



cat > /etc/systemd/system/openrct2.service <<'SERVICE'
[Unit]
Description=OpenRCT2 multiplayer server
After=network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/openrct2-manager/selected-scenario

[Service]
Type=simple
User=openrct2
Group=openrct2
ExecStart=/usr/local/sbin/openrct2-run-server
Restart=on-failure
RestartSec=5s
TimeoutStopSec=45s
KillSignal=SIGINT
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/openrct2 /var/lib/openrct2-manager
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
SERVICE

cat > /usr/local/lib/openrct2-manager.py <<'PYAPP'
#!/usr/bin/env python3
import base64
import configparser
import hashlib
import filecmp
import hmac
import html
import json
import os
import re
import secrets
import shlex
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCENARIOS = Path('/var/lib/openrct2/scenarios')
SCENARIO_ARCHIVE = Path('/var/lib/openrct2/scenario-archive')
BACKUPS = Path('/var/lib/openrct2/backups')
SELECTED = Path('/var/lib/openrct2-manager/selected-scenario')
CREDENTIALS = Path('/etc/openrct2-manager/web-credentials')
ENV_FILE = Path('/etc/openrct2-manager/server.env')
USERS_JSON = Path('/var/lib/openrct2/user-data/users.json')
SETTINGS = Path('/var/lib/openrct2-manager/settings.json')
ROLE_OVERRIDES = Path('/var/lib/openrct2-manager/role-overrides.json')
HELPER = Path('/var/lib/openrct2/user-data/plugin/manager-helper.js')
HELPER_TEMPLATE = Path('/usr/local/share/openrct2-manager/manager-helper.template.js')
LOGO_PNG = Path('/usr/local/share/openrct2-manager/logo.png')
SAVES = Path('/var/lib/openrct2/user-data/save')
CONTROL_TOKEN_FILE = Path('/var/lib/openrct2-manager/control-token')
AUDIT_LOG = Path('/var/lib/openrct2-manager/audit.log')
AUDIT_CHAIN = Path('/var/lib/openrct2-manager/audit-chain')
MOTD_FILE = Path('/var/lib/openrct2-manager/motd.json')
COMMAND_GRANTS = Path('/var/lib/openrct2-manager/command-grants.json')
PERMISSION_REQUESTS = Path('/var/lib/openrct2-manager/permission-requests.json')
PLAYER_PERMISSION_OVERRIDES = Path('/var/lib/openrct2-manager/player-permission-overrides.json')
PORTAL_USERS = Path('/var/lib/openrct2-manager/portal-users.json')
SETUP_STATE = Path('/var/lib/openrct2-manager/first-run.json')
SETUP_COMPLETE = Path('/var/lib/openrct2-manager/first-run-complete.json')
VERSION_CHECK = Path('/var/lib/openrct2-manager/version-check.json')
BACKUP_DESTINATIONS = Path('/var/lib/openrct2-manager/backup-destinations.json')
JOB_DB = Path('/var/lib/openrct2-manager/jobs.sqlite3')
STATE_VERSION = Path('/var/lib/openrct2-manager/schema-version')
CURRENT_STATE_VERSION = 4
GROUPS_JSON = Path('/var/lib/openrct2/user-data/groups.json')
CONFIG_INI = Path('/var/lib/openrct2/user-data/config.ini')
ALLOWED = {'.park', '.sv6', '.sv4', '.sc6', '.sc4'}
CSRF = secrets.token_urlsafe(32)
CHANGE_LOCK = threading.RLock()
AUDIT_LOCK = threading.Lock()
SSE_SLOTS = threading.BoundedSemaphore(32)
ROLES = {0: 'Administrator', 1: 'Spectator', 2: 'Player'}
GROUP_PERMISSIONS = (
    'PERMISSION_CHAT', 'PERMISSION_TERRAFORM', 'PERMISSION_SET_WATER_LEVEL',
    'PERMISSION_TOGGLE_PAUSE', 'PERMISSION_CREATE_RIDE', 'PERMISSION_REMOVE_RIDE',
    'PERMISSION_BUILD_RIDE', 'PERMISSION_RIDE_PROPERTIES', 'PERMISSION_SCENERY',
    'PERMISSION_PATH', 'PERMISSION_CLEAR_LANDSCAPE', 'PERMISSION_GUEST',
    'PERMISSION_STAFF', 'PERMISSION_PARK_PROPERTIES', 'PERMISSION_PARK_FUNDING',
    'PERMISSION_KICK_PLAYER', 'PERMISSION_MODIFY_GROUPS', 'PERMISSION_SET_PLAYER_GROUP',
    'PERMISSION_CHEAT', 'PERMISSION_TOGGLE_SCENERY_CLUSTER', 'PERMISSION_PASSWORDLESS_LOGIN',
    'PERMISSION_MODIFY_TILE', 'PERMISSION_EDIT_SCENARIO_OPTIONS', 'PERMISSION_DRAG_PATH_AREA')
PORTAL_ROLES = ('owner', 'administrator', 'operator', 'viewer')
ROLE_CAPABILITIES = {
    'viewer': {'view'},
    'operator': {'view', 'server.control', 'chat.send', 'scenario.manage', 'save.manage'},
    'administrator': {'view', 'server.control', 'chat.send', 'scenario.manage', 'save.manage',
                      'player.manage', 'group.manage', 'settings.manage', 'backup.manage'},
    'owner': {'*'},
}
AUTH_CACHE = {}
SESSIONS = {}
SESSION_LOCK = threading.Lock()
LOGIN_ATTEMPTS = {}
KEY_HASH = re.compile(r'[0-9a-fA-F]{40}\Z')
SNAPSHOT_NAME = re.compile(r'manager-snapshot-[0-9]{8}T[0-9]{6}Z\.park\Z')
QUICK_SAVE_NAME = re.compile(r'(?:quick-save|chat-save(?:-[A-Za-z0-9_-]{1,24})?|pre-restart|pre-switch)-[0-9]{8}T[0-9]{9}Z\.park\Z')
SAVE_FILE_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._ ()\[\]-]{0,179}\.(?:park|sv6|sv4)\Z', re.IGNORECASE)
DEFAULT_SETTINGS = {'snapshot_minutes': 10, 'snapshot_keep': 48, 'blocked_hashes': []}
LOGO_SVG = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-labelledby="title desc"><title id="title">OpenRCT2 Server Manager</title><desc id="desc">A coaster track crest with two peaks and a small car.</desc><rect width="64" height="64" rx="15" fill="#14263d"/><path d="M8 45h48" fill="none" stroke="#7de1c7" stroke-width="4" stroke-linecap="round"/><path d="M8 40c8 0 9-17 17-17s10 17 17 17 7-14 14-14" fill="none" stroke="#7de1c7" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><path d="M11 51h42" fill="none" stroke="#487b8b" stroke-width="2" stroke-linecap="round" stroke-dasharray="3 4"/><rect x="18" y="18" width="12" height="6" rx="2" fill="#ffb66d"/><circle cx="21" cy="26" r="2" fill="#ffb66d"/><circle cx="27" cy="26" r="2" fill="#ffb66d"/></svg>'''
ICONS = {
    'overview': 'M3 3h8v8H3z M13 3h8v5h-8z M13 10h8v11h-8z M3 13h8v8H3z',
    'parks': 'M3 19h18 M5 19V9l4-4 5 4 4-3 1 13 M7 13h10 M9 5v8 M14 9v4',
    'players': 'M16 19v-1a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v1 M9 10a3 3 0 1 0 0-6 3 3 0 0 0 0 6 M18 10a3 3 0 0 1 0 6 M17 4a3 3 0 0 1 1 6 M17 14h1a4 4 0 0 1 4 4v1',
    'groups': 'M4 4h16v5H4z M4 15h7v5H4z M15 15h5v5h-5z M12 9v3 M7.5 12h10 M7.5 12v3 M17.5 12v3',
    'users': 'M16 20v-1a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v1 M9 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8 M19 8v6 M16 11h6',
    'backups': 'M4 4v5h5 M4 9a8 8 0 1 1-1 5 M12 8v5l3 2',
    'activity': 'M2 12h4l3-7 4 14 3-7h6',
    'settings': 'M12 3v2 M12 19v2 M3 12h2 M19 12h2 M5.6 5.6 7 7 M17 17l1.4 1.4 M18.4 5.6 17 7 M7 17l-1.4 1.4 M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8',
    'play': 'm7 4 12 8-12 8z',
    'stop': 'M6 6h12v12H6z',
    'refresh': 'M20 11a8 8 0 0 0-14-5L4 8 M4 4v4h4 M4 13a8 8 0 0 0 14 5l2-2 M20 20v-4h-4',
    'message': 'M3 4h18v13H8l-5 4z',
    'download': 'M12 3v12 M7 10l5 5 5-5 M4 20h16',
    'theme': 'M20 15.2A8 8 0 0 1 8.8 4a8 8 0 1 0 11.2 11.2z',
}

def icon(name):
    return (f'<svg class="icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="1.9" stroke-linecap="round" '
            f'stroke-linejoin="round"><path d="{ICONS[name]}"></path></svg>')

HELPER_SOURCE = r'''var blockedHashes = __BLOCKED_HASHES__;
var roleOverrides = __ROLE_OVERRIDES__;
var snapshotMinutes = __SNAPSHOT_MINUTES__;
var controlPort = __CONTROL_PORT__;
var controlToken = __CONTROL_TOKEN__;
var seen = {};
var controlListener = null;
var ticksSincePlayerScan = 0;
var snapshotDue = false;
var quickSaveDue = false;
var lastQuickSaveAt = 0;
var roleUpdateDue = false;

function applyRoleOverrides() {
    for (var i = 0; i < network.players.length; i++) {
        var player = network.players[i];
        var hash = String(player.publicKeyHash || "").toLowerCase();
        if (!Object.prototype.hasOwnProperty.call(roleOverrides, hash) || player.group === roleOverrides[hash]) continue;
        try {
            player.group = roleOverrides[hash];
            console.log("Applied saved role to key " + hash.slice(0, 10));
        } catch (error) {
            console.log("Could not apply saved role to key " + hash.slice(0, 10) + ": " + error);
        }
    }
}

function main() {
    if (network.mode !== "server") return;
    context.subscribe("network.authenticate", function (event) {
        var hash = String(event.publicKeyHash || "").toLowerCase();
        if (blockedHashes.indexOf(hash) !== -1) {
            event.cancel = true;
            console.log("Blocked player key " + hash.slice(0, 10));
        }
    });
    context.subscribe("network.chat", function (event) {
        var player = null;
        try { player = network.getPlayer(event.player); } catch (error) {}
        var name = player ? player.name : "Player";
        var message = String(event.message || "").replace(/[\r\n\t]/g, " ").slice(0, 500);
        if (message.trim().toLowerCase() === "/save") {
            event.message = "";
            var commandHash = player ? String(player.publicKeyHash || "").toLowerCase() : "";
            if (player && player.group === 0 && /^[0-9a-f]{40}$/.test(commandHash) &&
                    (!Object.prototype.hasOwnProperty.call(roleOverrides, commandHash) || roleOverrides[commandHash] === 0)) {
                if (quickSaveDue || Date.now() - lastQuickSaveAt < 30000) {
                    network.sendMessage("Manager: A quick save was just requested. Wait 30 seconds before trying again.", [player.id]);
                } else {
                    quickSaveDue = true;
                    console.log("[ADMIN] " + name + " requested /save");
                    network.sendMessage("Manager: Saving a quick copy of the current park.", [player.id]);
                }
            } else {
                console.log("[ADMIN] Denied /save from " + name);
                if (player) network.sendMessage("Manager: /save is for administrators only.", [player.id]);
            }
            return;
        }
        console.log("[CHAT] " + name + ": " + message);
    });
    try {
        controlListener = network.createListener();
        controlListener.on("connection", function (socket) {
            var buffer = "";
            var done = false;
            socket.on("data", function (chunk) {
                if (done) return;
                buffer += chunk;
                if (buffer.length > 4096) { done = true; socket.end('{"ok":false}'); return; }
                var end = buffer.indexOf("\n");
                if (end < 0) return;
                done = true;
                try {
                    var request = JSON.parse(buffer.slice(0, end));
                    if (request.token !== controlToken) {
                        socket.end('{"ok":false}');
                        return;
                    }
                    if (request.action === "status") {
                        var ownId = -1;
                        try { ownId = network.currentPlayer.id; } catch (error) {}
                        var connected = 0;
                        for (var i = 0; i < network.players.length; i++) {
                            if (network.players[i].id !== ownId) connected++;
                        }
                        socket.end(JSON.stringify({ ok: true, players: connected }));
                        return;
                    }
                    if (request.action === "set_role") {
                        var key = String(request.hash || "").toLowerCase();
                        var role = request.group;
                        if (!/^[0-9a-f]{40}$/.test(key) || (role !== 0 && role !== 1 && role !== 2)) {
                            socket.end('{"ok":false}');
                            return;
                        }
                        roleOverrides[key] = role;
                        roleUpdateDue = true;
                        socket.end('{"ok":true}');
                        return;
                    }
                    if (request.action !== "chat" || typeof request.message !== "string" || request.message.length < 1 ||
                            request.message.length > 180 || /[\r\n\x00-\x1f]/.test(request.message)) {
                        socket.end('{"ok":false}');
                        return;
                    }
                    network.sendMessage("Manager: " + request.message);
                    console.log("[CHAT] Manager: " + request.message);
                    socket.end('{"ok":true}');
                } catch (error) {
                    socket.end('{"ok":false}');
                }
            });
        });
        controlListener.listen(controlPort, "127.0.0.1");
        console.log("Manager chat bridge listening locally on " + controlPort);
    } catch (error) {
        console.log("Manager chat bridge unavailable: " + error);
    }
    // Multiplayer game state can only be changed in a mutable game hook.
    // Timers and socket callbacks may request work, but cannot save a park or
    // update a player's persistent group directly.
    context.subscribe("interval.tick", function () {
        if (quickSaveDue) {
            var quickStamp = new Date().toISOString().replace(/[-:.]/g, "");
            var quickName = "quick-save-" + quickStamp;
            try {
                context.saveGame({ filename: quickName });
                quickSaveDue = false;
                lastQuickSaveAt = Date.now();
                console.log("[ADMIN] Saved quick park " + quickName + ".park");
                network.sendMessage("Manager: Quick save ready in the web manager: " + quickName + ".park");
            } catch (error) {
                quickSaveDue = false;
                console.log("[ADMIN] Quick save failed: " + error);
                network.sendMessage("Manager: Quick save failed. Check the server activity log.");
            }
        }
        if (snapshotDue) {
            var stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
            var name = "manager-snapshot-" + stamp;
            try {
                context.saveGame({ filename: name });
                snapshotDue = false;
                console.log("Saved live park snapshot " + name);
            } catch (error) {
                console.log("Could not save live park snapshot: " + error);
            }
        }
        if (roleUpdateDue) {
            roleUpdateDue = false;
            applyRoleOverrides();
        }
        ticksSincePlayerScan++;
        if (ticksSincePlayerScan < 40) return;
        ticksSincePlayerScan = 0;
        applyRoleOverrides();
        for (var i = 0; i < network.players.length; i++) {
            var player = network.players[i];
            var hash = String(player.publicKeyHash || "").toLowerCase();
            if (!/^[0-9a-f]{40}$/.test(hash) || seen[hash]) continue;
            // OpenRCT2 saves users by public key, not by name. Reapplying the
            // current group records a new visitor so the manager can edit it.
            try {
                player.group = player.group;
                seen[hash] = true;
                console.log("Recorded player " + player.name + " key " + hash.slice(0, 10));
            } catch (error) {
                console.log("Could not record player " + player.name + ": " + error);
            }
        }
    });
    if (snapshotMinutes > 0) {
        context.setInterval(function () {
            snapshotDue = true;
        }, snapshotMinutes * 60000);
    }
}

registerPlugin({
    name: "OpenRCT2 Manager Helper",
    version: "2.0.0",
    authors: ["OpenRCT2 Manager"],
    type: "remote",
    licence: "MIT",
    targetApiVersion: 122,
    minApiVersion: 122,
    main: main
});
'''

def read_env():
    values = {}
    for line in ENV_FILE.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            pieces = shlex.split(value)
            values[key] = pieces[0] if pieces else ''
    return values

ENV = read_env()
PORT = int(ENV.get('WEB_PORT', '8080'))
MAX_UPLOAD = int(ENV.get('MAX_UPLOAD_MB', '64')) * 1024 * 1024
GAME_PORT = ENV.get('GAME_PORT', '11753')
CONTROL_PORT = int(ENV.get('CONTROL_PORT', '11754'))
CALLBACK_PORT = int(ENV.get('CALLBACK_PORT', '11755'))
MANAGER_DOMAIN = ENV.get('MANAGER_DOMAIN', '')
WEB_BIND = ENV.get('WEB_BIND', '127.0.0.1')

def run(*args, timeout=60):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=False)

def service_active():
    return run('/usr/bin/systemctl', 'is-active', '--quiet', 'openrct2.service').returncode == 0

def safe_name(name):
    if (not isinstance(name, str) or '/' in name or '\\' in name or Path(name).name != name or
            not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._ ()\[\]-]{0,179}', name)):
        raise ValueError('Filenames must be plain names without folders or unsafe characters.')
    return name

def scenario_files():
    return sorted((p for p in SCENARIOS.iterdir() if p.is_file() and p.suffix.lower() in ALLOWED), key=lambda p: p.name.lower())

def archived_scenario_files():
    SCENARIO_ARCHIVE.mkdir(parents=True, exist_ok=True)
    return sorted((path for path in SCENARIO_ARCHIVE.iterdir() if path.is_file() and path.suffix.lower() in ALLOWED),
                  key=lambda path: path.name.lower())

def backup_files():
    return sorted((p for p in BACKUPS.glob('openrct2-*.tar.gz') if p.is_file()), key=lambda p: p.stat().st_mtime, reverse=True)

def backup_destinations():
    try: data = json.loads(BACKUP_DESTINATIONS.read_text())
    except FileNotFoundError: return []
    except (json.JSONDecodeError, OSError) as exc: raise ValueError(f'Cannot read backup destinations: {exc}')
    rows = data.get('destinations', []) if isinstance(data, dict) and data.get('schema') == 1 else None
    if not isinstance(rows, list): raise ValueError('Backup destinations have an unsupported format.')
    result = []
    for row in rows:
        if (not isinstance(row, dict) or not re.fullmatch(r'[0-9a-f]{24}', str(row.get('id', ''))) or
                row.get('type') not in ('sftp', 's3', 'rclone') or
                row.get('schedule') not in ('manual', 'after_backup', 'daily', 'weekly') or
                not 1 <= len(str(row.get('name', ''))) <= 64 or
                not 1 <= int(row.get('retention', 30)) <= 1000):
            raise ValueError('A backup destination is invalid.')
        result.append(row)
    return result

def save_backup_destinations(rows):
    write_json(BACKUP_DESTINATIONS, {'schema': 1, 'destinations': rows})

def create_full_archive():
    result = run('/usr/bin/sudo', '/usr/local/sbin/openrct2-backup', timeout=300)
    if result.returncode: raise ValueError(result.stderr.strip() or 'Backup failed.')
    archives = backup_files()
    if not archives: raise ValueError('Backup completed but no archive was found.')
    return archives[0]

def transfer_archive(destination, archive):
    kind = destination['type']; config = destination.get('config', {})
    if not isinstance(config, dict): raise ValueError('Backup destination configuration is invalid.')
    if kind == 'sftp':
        host = str(config.get('host', '')); username = str(config.get('username', ''))
        remote = str(config.get('path', '')); port = int(config.get('port', 22))
        key_name = str(config.get('identity', ''))
        if (not re.fullmatch(r'[A-Za-z0-9.-]{1,253}', host) or
                not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]{0,63}', username) or
                not re.fullmatch(r'/[A-Za-z0-9_./-]{0,511}', remote) or '..' in Path(remote).parts or
                not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', key_name) or not 1 <= port <= 65535):
            raise ValueError('SFTP destination fields are invalid.')
        identity = Path('/etc/openrct2-manager/keys') / key_name
        known_hosts = Path('/etc/openrct2-manager/known_hosts')
        if not identity.is_file() or not known_hosts.is_file():
            raise ValueError('Install the SFTP key and known_hosts file before testing this destination.')
        base = ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known_hosts}',
                '-i', str(identity)]
        target_dir = remote.rstrip('/') or '/'; target = target_dir + '/' + archive.name
        mkdir = run('/usr/bin/ssh', *base, '-p', str(port), f'{username}@{host}',
                    'mkdir', '-p', '--', target_dir, timeout=30)
        if mkdir.returncode: raise ValueError((mkdir.stderr or 'SFTP connection failed.').strip().splitlines()[-1][:300])
        result = run('/usr/bin/scp', '-q', *base, '-P', str(port), str(archive),
                     f'{username}@{host}:{target}.uploading', timeout=1800)
        if not result.returncode:
            result = run('/usr/bin/ssh', *base, '-p', str(port), f'{username}@{host}',
                         'mv', '--', target + '.uploading', target, timeout=30)
        label = f'sftp://{host}:{port}{target}'
    elif kind == 's3':
        executable = shutil.which('aws')
        bucket = str(config.get('bucket', '')); prefix = str(config.get('prefix', 'openrct2')).strip('/')
        if not executable: raise ValueError('AWS CLI is not installed; install it or use SFTP/rclone.')
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket) or not re.fullmatch(r'[A-Za-z0-9_./-]{0,300}', prefix):
            raise ValueError('S3 bucket or prefix is invalid.')
        label = f's3://{bucket}/{prefix}/{archive.name}'.replace('//openrct2-', '/openrct2-')
        result = run(executable, 's3', 'cp', str(archive), label, '--only-show-errors', timeout=1800)
    else:
        executable = shutil.which('rclone'); remote = str(config.get('remote', '')); directory = str(config.get('path', 'openrct2')).strip('/')
        if not executable: raise ValueError('rclone is not installed on this server.')
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', remote) or not re.fullmatch(r'[A-Za-z0-9_./ -]{0,300}', directory) or '..' in Path(directory).parts:
            raise ValueError('rclone remote or directory is invalid.')
        label = f'{remote}:{directory}/{archive.name}'
        result = run(executable, 'copyto', '--immutable', str(archive), label, timeout=1800)
    if result.returncode:
        raise ValueError((result.stderr or 'Remote transfer failed.').strip().splitlines()[-1][:300])
    retention = int(destination.get('retention', 30))
    if not 1 <= retention <= 1000: raise ValueError('Remote retention must be 1–1000 archives.')
    if kind == 'sftp':
        listing = run('/usr/bin/ssh', *base, '-p', str(port), f'{username}@{host}', 'find', target_dir,
                      '-maxdepth', '1', '-type', 'f', '-name', 'openrct2-*.tar.gz', '-printf', '%T@ %f\\n', timeout=30)
        if listing.returncode: raise ValueError('Upload succeeded, but SFTP retention listing failed.')
        names = [line.split(' ', 1)[1] for line in listing.stdout.splitlines() if ' ' in line]
        for old_name in sorted(names, reverse=True)[retention:]:
            if re.fullmatch(r'openrct2-[0-9]{8}T[0-9]{6}Z\.tar\.gz', old_name):
                removed = run('/usr/bin/ssh', *base, '-p', str(port), f'{username}@{host}',
                              'rm', '--', target_dir + '/' + old_name, timeout=30)
                if removed.returncode: raise ValueError('Upload succeeded, but SFTP retention cleanup failed.')
    elif kind == 's3':
        listed = run(executable, 's3api', 'list-objects-v2', '--bucket', bucket, '--prefix', prefix + '/',
                     '--output', 'json', timeout=60)
        if listed.returncode: raise ValueError('Upload succeeded, but S3 retention listing failed.')
        objects = sorted((item for item in json.loads(listed.stdout).get('Contents', [])
                          if re.fullmatch(r'(?:[A-Za-z0-9_./-]*/)?openrct2-[0-9]{8}T[0-9]{6}Z\.tar\.gz', str(item.get('Key', '')))),
                         key=lambda item: item.get('LastModified', ''), reverse=True)
        for item in objects[retention:]:
            removed = run(executable, 's3api', 'delete-object', '--bucket', bucket, '--key', item['Key'], timeout=60)
            if removed.returncode: raise ValueError('Upload succeeded, but S3 retention cleanup failed.')
    else:
        listed = run(executable, 'lsjson', f'{remote}:{directory}', '--files-only', timeout=60)
        if listed.returncode: raise ValueError('Upload succeeded, but rclone retention listing failed.')
        objects = sorted((item for item in json.loads(listed.stdout)
                          if re.fullmatch(r'openrct2-[0-9]{8}T[0-9]{6}Z\.tar\.gz', str(item.get('Name', '')))),
                         key=lambda item: item.get('ModTime', ''), reverse=True)
        for item in objects[retention:]:
            removed = run(executable, 'deletefile', f'{remote}:{directory}/{item["Name"]}', timeout=60)
            if removed.returncode: raise ValueError('Upload succeeded, but rclone retention cleanup failed.')
    return label

def test_destination(destination):
    """Validate credentials and remote reachability without creating or uploading data."""
    kind = destination['type']; config = destination.get('config', {})
    if not isinstance(config, dict): raise ValueError('Backup destination configuration is invalid.')
    if kind == 'sftp':
        host = str(config.get('host', '')); username = str(config.get('username', ''))
        remote = str(config.get('path', '')); port = int(config.get('port', 22))
        key_name = str(config.get('identity', ''))
        if (not re.fullmatch(r'[A-Za-z0-9.-]{1,253}', host) or
                not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]{0,63}', username) or
                not re.fullmatch(r'/[A-Za-z0-9_./-]{0,511}', remote) or '..' in Path(remote).parts or
                not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', key_name) or not 1 <= port <= 65535):
            raise ValueError('SFTP destination fields are invalid.')
        identity = Path('/etc/openrct2-manager/keys') / key_name
        known_hosts = Path('/etc/openrct2-manager/known_hosts')
        if not identity.is_file() or not known_hosts.is_file():
            raise ValueError('Install the SFTP key and known_hosts file before testing this destination.')
        base = ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known_hosts}',
                '-i', str(identity), '-p', str(port)]
        result = run('/usr/bin/ssh', *base, f'{username}@{host}', 'test', '-d', '--', remote.rstrip('/') or '/', timeout=30)
        label = f'sftp://{host}:{port}{remote}'
    elif kind == 's3':
        executable = shutil.which('aws'); bucket = str(config.get('bucket', ''))
        if not executable: raise ValueError('AWS CLI is not installed; install it or use SFTP/rclone.')
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket):
            raise ValueError('S3 bucket is invalid.')
        result = run(executable, 's3api', 'head-bucket', '--bucket', bucket, timeout=30)
        label = f's3://{bucket}'
    elif kind == 'rclone':
        executable = shutil.which('rclone'); remote = str(config.get('remote', ''))
        directory = str(config.get('path', 'openrct2')).strip('/')
        if not executable: raise ValueError('rclone is not installed on this server.')
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', remote) or not re.fullmatch(r'[A-Za-z0-9_./ -]{0,300}', directory) or '..' in Path(directory).parts:
            raise ValueError('rclone remote or directory is invalid.')
        # lsf is read-only. An empty directory is still a successful connection.
        result = run(executable, 'lsf', f'{remote}:{directory}', '--max-depth', '1', timeout=30)
        label = f'{remote}:{directory}'
    else:
        raise ValueError('Unknown backup destination type.')
    if result.returncode:
        raise ValueError((result.stderr or 'Connection test failed.').strip().splitlines()[-1][:300])
    return label

def transfer_scheduled_destinations(archive, schedules):
    rows = backup_destinations(); transferred = 0
    for destination in rows:
        if destination['schedule'] not in schedules: continue
        try:
            destination['last_location'] = transfer_archive(destination, archive)
            destination['last_status'] = 'Healthy'; transferred += 1
        except (ValueError, OSError, subprocess.SubprocessError) as exc:
            destination['last_status'] = 'Failed: ' + str(exc)[:180]
        destination['last_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    save_backup_destinations(rows)
    return transferred

def job_connection():
    connection = sqlite3.connect(JOB_DB, timeout=5)
    connection.execute('PRAGMA journal_mode=WAL'); connection.execute('PRAGMA busy_timeout=5000')
    connection.execute('CREATE TABLE IF NOT EXISTS jobs ('
                       'id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, '
                       'attempts INTEGER NOT NULL DEFAULT 0, available_at INTEGER NOT NULL, created_at INTEGER NOT NULL, '
                       'started_at INTEGER, finished_at INTEGER, error TEXT)')
    connection.commit(); return connection

def enqueue_job(kind, payload=None, delay=0):
    if kind not in ('full_backup', 'destination_backup'): raise ValueError('Unsupported background job.')
    encoded = json.dumps(payload or {}, separators=(',', ':'))
    if len(encoded) > 8192: raise ValueError('Background job payload is too large.')
    job_id = secrets.token_hex(16); now = int(time.time())
    with job_connection() as connection:
        connection.execute("INSERT INTO jobs VALUES(?,?,?,'queued',0,?,?,NULL,NULL,NULL)",
                           (job_id, kind, encoded, now + max(0, delay), now))
    return job_id

def recent_jobs(limit=12):
    with job_connection() as connection:
        rows = connection.execute('SELECT id,kind,status,attempts,created_at,finished_at,error FROM jobs '
                                  'ORDER BY created_at DESC,id DESC LIMIT ?', (limit,)).fetchall()
    return [{'id': row[0], 'kind': row[1], 'status': row[2], 'attempts': row[3],
             'created_at': row[4], 'finished_at': row[5], 'error': row[6]} for row in rows]

def run_background_job(kind, payload):
    with CHANGE_LOCK:
        archive = create_full_archive()
        if kind == 'full_backup':
            transfer_scheduled_destinations(archive, {'after_backup'})
        else:
            target_id = str(payload.get('destination_id', ''))
            rows = backup_destinations(); target = next((row for row in rows if row['id'] == target_id), None)
            if not target: raise ValueError('Backup destination no longer exists.')
            target['last_location'] = transfer_archive(target, archive); target['last_status'] = 'Healthy'
            target['last_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            save_backup_destinations(rows)

def job_worker():
    with job_connection() as connection:
        connection.execute("UPDATE jobs SET status='queued',available_at=?,error='manager restarted during job' WHERE status='running'",
                           (int(time.time()),)); connection.commit()
    while True:
        job = None
        try:
            now = int(time.time())
            with job_connection() as connection:
                connection.execute('BEGIN IMMEDIATE')
                row = connection.execute("SELECT id,kind,payload,attempts FROM jobs WHERE status='queued' AND available_at<=? "
                                         'ORDER BY created_at,id LIMIT 1', (now,)).fetchone()
                if row:
                    connection.execute("UPDATE jobs SET status='running',attempts=attempts+1,started_at=? WHERE id=?", (now, row[0]))
                connection.commit(); job = row
            if not job: time.sleep(2); continue
            try:
                run_background_job(job[1], json.loads(job[2]))
            except Exception as exc:
                attempts = job[3] + 1; terminal = attempts >= 5
                with job_connection() as connection:
                    connection.execute("UPDATE jobs SET status=?,available_at=?,finished_at=?,error=? WHERE id=?",
                                       ('failed' if terminal else 'queued', now + min(3600, 30 * 2 ** (attempts - 1)),
                                        now if terminal else None, f'{type(exc).__name__}: {exc}'[:500], job[0]))
                    connection.commit()
            else:
                with job_connection() as connection:
                    connection.execute("UPDATE jobs SET status='complete',finished_at=?,error=NULL WHERE id=?", (int(time.time()), job[0]))
                    connection.commit()
        except Exception as exc:
            print(f'Background job worker error: {exc}', flush=True); time.sleep(5)

def backup_scheduler():
    """Run low-frequency remote schedules without blocking HTTP or game bridge threads."""
    while True:
        time.sleep(60)
        try:
            now = int(time.time()); rows = backup_destinations()
            due = [row for row in rows if row['schedule'] in ('daily', 'weekly') and int(row.get('next_at', 0)) <= now]
            for destination in due:
                enqueue_job('destination_backup', {'destination_id': destination['id']})
                destination['next_at'] = now + (86400 if destination['schedule'] == 'daily' else 604800)
                destination['last_status'] = 'Queued'
                save_backup_destinations(rows)
                audit_event(f'Queued scheduled remote backup for {destination["name"]}')
        except Exception as exc:
            print(f'Backup scheduler error: {exc}', flush=True)

def snapshot_files():
    return sorted((p for p in SAVES.glob('manager-snapshot-*.park') if p.is_file() and SNAPSHOT_NAME.fullmatch(p.name)), reverse=True)

def quick_save_files():
    return sorted((p for p in SAVES.iterdir() if p.is_file() and QUICK_SAVE_NAME.fullmatch(p.name)),
                  key=lambda path: path.stat().st_mtime, reverse=True)

def all_save_files():
    return sorted((path for path in SAVES.iterdir() if path.is_file() and SAVE_FILE_NAME.fullmatch(path.name)),
                  key=lambda path: path.stat().st_mtime, reverse=True)

def role_overrides():
    try:
        data = json.loads(ROLE_OVERRIDES.read_text())
    except FileNotFoundError:
        return {}
    except (json.JSONDecodeError, OSError) as exc:
        raise ValueError(f'Cannot read saved role assignments: {exc}')
    if not isinstance(data, dict) or any(
            not isinstance(key, str) or not KEY_HASH.fullmatch(key) or
            type(value) is not int or not 0 <= value <= 255
            for key, value in data.items()):
        raise ValueError('Saved role assignments have an unexpected format.')
    return {key.lower(): value for key, value in data.items()}

def command_grants():
    try:
        data = json.loads(COMMAND_GRANTS.read_text())
    except FileNotFoundError:
        return {}
    except (json.JSONDecodeError, OSError) as exc:
        raise ValueError(f'Cannot read command grants: {exc}')
    if not isinstance(data, dict):
        raise ValueError('Command grants have an unexpected format.')
    result = {}
    for key, commands in data.items():
        if (not isinstance(key, str) or not KEY_HASH.fullmatch(key) or
                not isinstance(commands, list) or
                any(command not in ('save', 'backup', 'restart', '*') for command in commands)):
            raise ValueError('Command grants have an unexpected format.')
        result[key.lower()] = sorted(set(commands))
    return result

def command_hashes():
    return sorted(key for key, commands in command_grants().items() if '*' in commands)

def motd_lines():
    try:
        data = json.loads(MOTD_FILE.read_text())
    except FileNotFoundError:
        return []
    except (json.JSONDecodeError, OSError) as exc:
        raise ValueError(f'Cannot read the MOTD: {exc}')
    lines = data.get('lines', []) if isinstance(data, dict) else []
    if (not isinstance(lines, list) or len(lines) > 5 or
            any(not isinstance(line, str) or not 1 <= len(line) <= 180 or
                any(ord(character) < 32 for character in line) for line in lines)):
        raise ValueError('The saved MOTD is invalid.')
    return lines

def permission_requests():
    try:
        data = json.loads(PERMISSION_REQUESTS.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    return data if isinstance(data, list) else []

def player_permission_overrides():
    try:
        data = json.loads(PLAYER_PERMISSION_OVERRIDES.read_text())
    except FileNotFoundError:
        return {}
    except (json.JSONDecodeError, OSError) as exc:
        raise ValueError(f'Cannot read individual player permissions: {exc}')
    rows = data.get('overrides', []) if isinstance(data, dict) and data.get('schema') == 1 else None
    if not isinstance(rows, list):
        raise ValueError('Individual player permissions have an unsupported format.')
    result = {}
    for row in rows:
        if not isinstance(row, dict): raise ValueError('An individual player permission is invalid.')
        key = str(row.get('public_key_hash', '')).lower(); base = row.get('base_group')
        allow, deny = row.get('allow', []), row.get('deny', [])
        if (not KEY_HASH.fullmatch(key) or type(base) is not int or not 0 <= base <= 255 or
                not isinstance(allow, list) or not isinstance(deny, list) or
                any(item not in GROUP_PERMISSIONS for item in allow + deny) or
                set(allow) & set(deny)):
            raise ValueError('An individual player permission is invalid.')
        result[key] = {'base_group': base, 'allow': sorted(set(allow)), 'deny': sorted(set(deny))}
    return result

def save_player_permission_overrides(overrides):
    rows = [dict({'public_key_hash': key}, **value) for key, value in sorted(overrides.items())
            if value.get('allow') or value.get('deny')]
    write_json(PLAYER_PERMISSION_OVERRIDES, {'schema': 1, 'overrides': rows})

def apply_player_permission_override(key_hash, override):
    """Materialise one player's allow/deny overlay as a native OpenRCT2 group."""
    state = control_request('groups'); groups = state.get('groups', [])
    base_id = int(override['base_group'])
    base = next((group for group in groups if group.get('id') == base_id and
                 not str(group.get('name', '')).startswith('@manager/')), None)
    if not base: raise ValueError('The player base group no longer exists.')
    allow, deny = set(override['allow']), set(override['deny'])
    if not allow and not deny:
        control_request('set_role', hash=key_hash, group=base_id)
        roles = role_overrides(); roles[key_hash] = base_id; write_json(ROLE_OVERRIDES, roles)
        return base_id
    desired = (set(base.get('permissions', [])) | allow) - deny
    name = '@manager/' + key_hash[:10]
    derived = next((group for group in groups if group.get('name') == name), None)
    if not derived:
        created = control_request('group_create', name=name)
        derived = next((group for group in created.get('groups', []) if group.get('name') == name), None)
    if not derived: raise ValueError('OpenRCT2 could not create the individual permission group.')
    for permission in GROUP_PERMISSIONS:
        control_request('group_permission', group=int(derived['id']), permission=permission,
                        allowed=permission in desired)
    group_id = int(derived['id'])
    control_request('set_role', hash=key_hash, group=group_id)
    roles = role_overrides(); roles[key_hash] = group_id; write_json(ROLE_OVERRIDES, roles)
    return group_id

def add_permission_request(event):
    requests = permission_requests()
    if any(item.get('event_id') == event.get('event_id') for item in requests if isinstance(item, dict)):
        return
    requests.append(event)
    write_json(PERMISSION_REQUESTS, requests[-250:])

def settings():
    try:
        data = json.loads(SETTINGS.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        data = {}
    if not isinstance(data, dict):
        raise ValueError('Manager settings have an unexpected format.')
    result = DEFAULT_SETTINGS.copy()
    result.update({key: data[key] for key in result if key in data})
    if (type(result['snapshot_minutes']) is not int or not 0 <= result['snapshot_minutes'] <= 1440 or
            type(result['snapshot_keep']) is not int or not 1 <= result['snapshot_keep'] <= 500 or
            not isinstance(result['blocked_hashes'], list) or
            any(not isinstance(key, str) or not KEY_HASH.fullmatch(key) for key in result['blocked_hashes'])):
        raise ValueError('Manager settings contain invalid values.')
    result['blocked_hashes'] = sorted(set(key.lower() for key in result['blocked_hashes']))
    return result

def game_config():
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.read(CONFIG_INI, encoding='utf-8')
    if not parser.has_section('network'): parser.add_section('network')
    if not parser.has_section('general'): parser.add_section('general')
    network = parser['network']; general = parser['general']
    unquote = lambda value: value.strip()[1:-1] if len(value.strip()) >= 2 and value.strip()[0] == value.strip()[-1] == '"' else value.strip()
    return {
        'server_name': unquote(network.get('server_name', 'OpenRCT2 Server')),
        'server_description': unquote(network.get('server_description', '')),
        'server_greeting': unquote(network.get('server_greeting', '')),
        'max_players': network.getint('maxplayers', fallback=16),
        'port': network.getint('default_port', fallback=11753),
        'advertise': network.getboolean('advertise', fallback=True),
        'advertise_address': unquote(network.get('advertise_address', '')),
        'pause_when_empty': network.getboolean('pause_server_if_no_clients', fallback=True),
        'autosave': general.getint('autosave', fallback=1),
        'autosave_amount': general.getint('autosave_amount', fallback=10),
        'has_password': bool(unquote(network.get('default_password', ''))),
    }

def installed_openrct2_version():
    executable = shutil.which('openrct2-cli') or '/usr/bin/openrct2-cli'
    if not Path(executable).is_file(): return 'unavailable'
    result = run(executable, '--version', timeout=10)
    match = re.search(r'v([0-9]+(?:\.[0-9]+){2})', result.stdout)
    return match.group(1) if match else 'unknown'

def version_status():
    installed = installed_openrct2_version()
    try: cached = json.loads(VERSION_CHECK.read_text())
    except (FileNotFoundError, json.JSONDecodeError): cached = {}
    return {'installed': installed, 'latest': cached.get('latest', ''), 'checked_at': cached.get('checked_at', '')}

def check_latest_version():
    result = run('/usr/bin/curl', '-fsSL', '--max-time', '12',
                 '-H', 'Accept: application/vnd.github+json',
                 'https://api.github.com/repos/OpenRCT2/OpenRCT2/releases/latest', timeout=15)
    if result.returncode: raise ValueError('Could not reach the official OpenRCT2 release feed.')
    try: tag = json.loads(result.stdout).get('tag_name', '')
    except json.JSONDecodeError as exc: raise ValueError('The version feed returned invalid data.') from exc
    match = re.fullmatch(r'v?([0-9]+(?:\.[0-9]+){2})', str(tag))
    if not match: raise ValueError('The version feed did not contain a stable version.')
    data = {'latest': match.group(1), 'checked_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
    write_json(VERSION_CHECK, data); return data['latest']

def update_game_config(values, password=None, remove_password=False):
    parser = configparser.ConfigParser(interpolation=None, strict=False); parser.optionxform = str
    parser.read(CONFIG_INI, encoding='utf-8')
    if not parser.has_section('network'): parser.add_section('network')
    if not parser.has_section('general'): parser.add_section('general')
    network = parser['network']; general = parser['general']
    quote = lambda value: '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
    for key in ('server_name', 'server_description', 'server_greeting'):
        value = str(values[key]).strip(); limit = 64 if key == 'server_name' else 256
        minimum = 1 if key == 'server_name' else 0
        if not (minimum <= len(value) <= limit) or any(ord(char) < 32 for char in value):
            raise ValueError(f'{key.replace("_", " ").title()} must contain {minimum}–{limit} printable characters.')
        network[key] = quote(value)
    max_players = int(values['max_players']); port = int(values['port'])
    autosave = int(values['autosave']); autosave_amount = int(values['autosave_amount'])
    if not (1 <= max_players <= 255 and 1 <= port <= 65535 and 0 <= autosave <= 5 and 1 <= autosave_amount <= 1000):
        raise ValueError('A numeric server setting is outside its supported range.')
    address = str(values['advertise_address']).strip()
    if address and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}', address):
        raise ValueError('Advertise address must be an IP address or hostname.')
    network['maxplayers'] = str(max_players); network['default_port'] = str(port)
    network['advertise'] = str(bool(values['advertise'])).lower(); network['advertise_address'] = quote(address)
    network['pause_server_if_no_clients'] = str(bool(values['pause_when_empty'])).lower()
    general['autosave'] = str(autosave); general['autosave_amount'] = str(autosave_amount)
    if remove_password: network['default_password'] = '""'
    elif password:
        if len(password) > 128 or any(ord(char) < 32 for char in password): raise ValueError('Invalid game password.')
        network['default_password'] = quote(password)
    from io import StringIO
    output = StringIO(); parser.write(output, space_around_delimiters=True)
    with tempfile.NamedTemporaryFile('w', dir=CONFIG_INI.parent, prefix='.config-', delete=False) as temp:
        temp.write(output.getvalue()); temporary = Path(temp.name)
    try:
        os.chmod(temporary, 0o640); os.replace(temporary, CONFIG_INI)
    finally: temporary.unlink(missing_ok=True)

def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', dir=path.parent, prefix='.manager-', delete=False) as temp:
        json.dump(data, temp, indent=2, ensure_ascii=False)
        temp.write('\n')
        temporary = Path(temp.name)
    try:
        os.chmod(temporary, 0o640)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

def migrate_state():
    try: current = int(STATE_VERSION.read_text().strip())
    except FileNotFoundError: current = 0
    except ValueError as exc: raise ValueError('Manager schema-version file is invalid.') from exc
    if current > CURRENT_STATE_VERSION:
        raise ValueError(f'Manager state schema {current} is newer than this application supports.')
    if current == CURRENT_STATE_VERSION: return
    migration_root = STATE_VERSION.parent / 'migrations' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    migration_root.mkdir(parents=True, exist_ok=False)
    for source in STATE_VERSION.parent.glob('*.json'):
        if source.is_file() and not source.is_symlink(): shutil.copy2(source, migration_root / source.name)
    if not BACKUP_DESTINATIONS.exists(): save_backup_destinations([])
    if not PLAYER_PERMISSION_OVERRIDES.exists(): save_player_permission_overrides({})
    if not PERMISSION_REQUESTS.exists(): write_json(PERMISSION_REQUESTS, [])
    with tempfile.NamedTemporaryFile('w', dir=STATE_VERSION.parent, prefix='.schema-', delete=False) as temp:
        temp.write(str(CURRENT_STATE_VERSION) + '\n'); temporary = Path(temp.name)
    try: os.chmod(temporary, 0o640); os.replace(temporary, STATE_VERSION)
    finally: temporary.unlink(missing_ok=True)
    audit_event(f'Migrated manager state schema from {current} to {CURRENT_STATE_VERSION}')

def hash_portal_password(password, salt=None, iterations=600000):
    if not 12 <= len(password) <= 1024:
        raise ValueError('Portal passwords must contain 12–1024 characters.')
    salt = salt or secrets.token_bytes(18)
    digest = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, iterations)
    encode = lambda value: base64.urlsafe_b64encode(value).decode().rstrip('=')
    return f'pbkdf2_sha256${iterations}${encode(salt)}${encode(digest)}'

def verify_portal_password(password, encoded):
    try:
        scheme, rounds, salt_text, digest_text = encoded.split('$', 3)
        if scheme != 'pbkdf2_sha256': return False
        iterations = int(rounds)
        if not 100000 <= iterations <= 2000000: return False
        decode = lambda value: base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
        actual = hashlib.pbkdf2_hmac('sha256', password.encode(), decode(salt_text), iterations)
        return hmac.compare_digest(actual, decode(digest_text))
    except (ValueError, TypeError):
        return False

def portal_users():
    try: data = json.loads(PORTAL_USERS.read_text())
    except FileNotFoundError: return []
    except (json.JSONDecodeError, OSError) as exc: raise ValueError(f'Cannot read portal users: {exc}')
    users = data.get('users', []) if isinstance(data, dict) and data.get('schema') == 1 else None
    if not isinstance(users, list): raise ValueError('Portal user database is invalid.')
    for user in users:
        if (not isinstance(user, dict) or not re.fullmatch(r'[0-9a-f]{32}', str(user.get('id', ''))) or
                not re.fullmatch(r'[a-z0-9][a-z0-9_.-]{0,63}', str(user.get('username', ''))) or
                user.get('role') not in PORTAL_ROLES or not isinstance(user.get('active'), bool) or
                not str(user.get('password_hash', '')).startswith('pbkdf2_sha256$')):
            raise ValueError('Portal user database contains an invalid record.')
    return users

def save_portal_users(users):
    if not any(user['active'] and user['role'] == 'owner' for user in users):
        raise ValueError('At least one active Owner must remain.')
    write_json(PORTAL_USERS, {'schema': 1, 'users': users}); AUTH_CACHE.clear()
    with SESSION_LOCK: SESSIONS.clear()

def ensure_portal_owner():
    if portal_users(): return
    if setup_pending(): return
    if SETUP_COMPLETE.exists(): return
    username, password = CREDENTIALS.read_text().rstrip('\n').split(':', 1)
    username = username.strip().lower()
    if not re.fullmatch(r'[a-z0-9][a-z0-9_.-]{0,63}', username): username = 'owner'
    save_portal_users([{'id': secrets.token_hex(16), 'username': username,
                        'display_name': username, 'role': 'owner', 'active': True,
                        'password_hash': hash_portal_password(password)}])

def setup_record():
    try: data = json.loads(SETUP_STATE.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError): return None
    if (not isinstance(data, dict) or data.get('schema') != 1 or data.get('complete') is not False or
            not str(data.get('password_hash', '')).startswith('pbkdf2_sha256$')):
        return None
    return data

def setup_pending():
    return not portal_users() and setup_record() is not None

def initialize_setup_token(token):
    if portal_users(): raise ValueError('Portal users already exist; first-run setup is not available.')
    if not 16 <= len(token) <= 256 or any(ord(char) < 33 or ord(char) > 126 for char in token):
        raise ValueError('The one-time setup password must contain 16–256 printable characters.')
    SETUP_COMPLETE.unlink(missing_ok=True)
    write_json(SETUP_STATE, {'schema': 1, 'complete': False, 'created_at': int(time.time()),
                             'password_hash': hash_portal_password(token)})

def detected_openrct2():
    candidates = [ENV.get('OPENRCT2_BIN', ''), shutil.which('openrct2-cli'), shutil.which('openrct2'),
                  '/opt/openrct2/openrct2-cli']
    for candidate in candidates:
        if not candidate: continue
        path = Path(candidate)
        if path.is_file() and os.access(path, os.X_OK):
            result = run(str(path), '--version', timeout=10)
            first = (result.stdout or result.stderr).splitlines()
            return {'path': str(path), 'version': first[0][:120] if first else 'Version unavailable',
                    'healthy': result.returncode == 0}
    return {'path': '', 'version': 'OpenRCT2 executable was not found', 'healthy': False}

def publish_helper(config):
    blocked = sorted(set(config['blocked_hashes']))
    source = HELPER_TEMPLATE.read_text() if HELPER_TEMPLATE.is_file() else HELPER_SOURCE
    source = source.replace('__BLOCKED_HASHES__', json.dumps(blocked))
    source = source.replace('__ROLE_OVERRIDES__', json.dumps(role_overrides()))
    source = source.replace('__COMMAND_ACCESS__', json.dumps(command_grants()))
    source = source.replace('__SNAPSHOT_MINUTES__', str(config['snapshot_minutes']))
    source = source.replace('__PAUSE_WHEN_EMPTY__', 'true' if game_config()['pause_when_empty'] else 'false')
    source = source.replace('__CONTROL_PORT__', str(CONTROL_PORT))
    source = source.replace('__CALLBACK_PORT__', str(CALLBACK_PORT))
    source = source.replace('__CONTROL_TOKEN__', json.dumps(CONTROL_TOKEN_FILE.read_text().strip()))
    HELPER.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', dir=HELPER.parent, prefix='.manager-helper-', delete=False) as temp:
        temp.write(source)
        temporary = Path(temp.name)
    try:
        os.chmod(temporary, 0o640)
        os.replace(temporary, HELPER)
        if os.geteuid() == 0:
            shutil.chown(HELPER, user='openrct2', group='openrct2')
    finally:
        temporary.unlink(missing_ok=True)

def save_settings(config):
    write_json(SETTINGS, config)
    publish_helper(config)

def ensure_control_token():
    CONTROL_TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(CONTROL_TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        token = CONTROL_TOKEN_FILE.read_text().strip()
        if not re.fullmatch(r'[0-9a-f]{64}', token):
            raise ValueError('The local chat token is invalid; check the manager state file.')
        return
    try:
        os.write(descriptor, (secrets.token_hex(32) + '\n').encode())
    finally:
        os.close(descriptor)

def prune_snapshots():
    keep = settings()['snapshot_keep']
    for path in snapshot_files()[keep:]:
        if path.stat().st_mtime < time.time() - 120:
            path.unlink()

def control_server(action):
    result = run('/usr/bin/sudo', '/usr/bin/systemctl', action, 'openrct2.service', timeout=75)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f'Could not {action} the game server.')
    if action in ('start', 'restart'):
        time.sleep(1)
        if not service_active():
            raise ValueError('The game server exited after launch. Check its logs with: sudo journalctl -u openrct2 -n 50')

def change_with_restart(callback):
    with CHANGE_LOCK:
        was_active = service_active()
        if was_active:
            control_server('stop')
        try:
            callback()
        finally:
            if was_active:
                control_server('start')
        return was_active

def all_user_records():
    try:
        data = json.loads(USERS_JSON.read_text())
    except FileNotFoundError:
        return []
    except (json.JSONDecodeError, OSError) as exc:
        raise ValueError(f'Cannot read the saved player list: {exc}')
    if not isinstance(data, list):
        raise ValueError('The saved player list has an unexpected format; no changes were made.')
    return data

def user_roles():
    return [item for item in all_user_records() if isinstance(item, dict)
            and isinstance(item.get('name'), str) and isinstance(item.get('hash'), str)
            and KEY_HASH.fullmatch(item['hash'])]

def write_user_roles(users):
    write_json(USERS_JSON, users)

def selected_name():
    try:
        name = SELECTED.read_text().strip()
        return name if name == safe_name(name) and (SCENARIOS / name).is_file() else ''
    except FileNotFoundError:
        return ''

def write_selection(filename):
    SELECTED.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', dir=SELECTED.parent, prefix='.selection-', delete=False) as temp:
        temp.write(filename + '\n'); temporary = Path(temp.name)
    try:
        os.chmod(temporary, 0o640); os.replace(temporary, SELECTED)
    finally: temporary.unlink(missing_ok=True)

def wait_for_game_health(timeout=15):
    deadline = time.monotonic() + timeout; last_error = 'service did not become healthy'
    while time.monotonic() < deadline:
        if service_active():
            try:
                result = control_request('status')
                if result.get('ok') is True: return
            except ValueError as exc: last_error = str(exc)
        time.sleep(0.5)
    raise ValueError('OpenRCT2 did not become healthy: ' + last_error)

def create_live_switch_save(timeout=20):
    response = control_request('prepare_switch')
    filename = str(response.get('filename', ''))
    if not QUICK_SAVE_NAME.fullmatch(filename) or not filename.startswith('pre-switch-'):
        raise ValueError('The game helper returned an invalid pre-switch save name.')
    path = SAVES / filename; deadline = time.monotonic() + timeout; previous_size = -1
    while time.monotonic() < deadline:
        if path.is_file():
            size = path.stat().st_size
            if size > 0 and size == previous_size: return path
            previous_size = size
        time.sleep(0.25)
    raise ValueError('The live park did not finish its safety save; the scenario was not switched.')

def visible_user_roles():
    overrides = role_overrides()
    users = user_roles()
    for item in users:
        key = item['hash'].lower()
        if key in overrides:
            item['groupId'] = overrides[key]
    return users

def human_size(size):
    for unit in ('B', 'KB', 'MB', 'GB'):
        if size < 1024 or unit == 'GB':
            return f'{size:.0f} {unit}' if unit == 'B' else f'{size:.1f} {unit}'
        size /= 1024

def audit_event(message, actor='system', target='', outcome='success', correlation=None):
    clean = re.sub(r'[\r\n\x00-\x1f]+', ' ', message)[:300]
    actor = re.sub(r'[^A-Za-z0-9_.:@/-]+', '_', str(actor))[:80] or 'system'
    target = re.sub(r'[\r\n\x00-\x1f]+', ' ', str(target))[:120]
    outcome = outcome if outcome in ('success', 'failure', 'queued') else 'success'
    correlation = correlation or secrets.token_hex(8)
    stamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    try:
        with AUDIT_LOCK:
            previous = AUDIT_CHAIN.read_text().strip() if AUDIT_CHAIN.is_file() else '0' * 64
            content = f'{stamp} MANAGER actor={actor} outcome={outcome} corr={correlation} target={target or "-"} {clean}'
            digest = hashlib.sha256((previous + '\n' + content).encode()).hexdigest()
            if AUDIT_LOG.is_file() and AUDIT_LOG.stat().st_size > 10 * 1024 * 1024:
                rotated = AUDIT_LOG.with_name('audit-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '.log')
                os.replace(AUDIT_LOG, rotated)
                for expired in sorted(AUDIT_LOG.parent.glob('audit-[0-9]*T[0-9]*Z.log'),
                                      key=lambda path: path.name, reverse=True)[10:]:
                    expired.unlink(missing_ok=True)
            descriptor = os.open(AUDIT_LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
            try: os.write(descriptor, f'{content} prev={previous} hash={digest}\n'.encode('utf-8'))
            finally: os.close(descriptor)
            with tempfile.NamedTemporaryFile('w', dir=AUDIT_CHAIN.parent, prefix='.audit-chain-', delete=False) as temp:
                temp.write(digest + '\n'); temporary = Path(temp.name)
            try: os.chmod(temporary, 0o640); os.replace(temporary, AUDIT_CHAIN)
            finally: temporary.unlink(missing_ok=True)
    except OSError as exc:
        print(f'Could not record manager action: {exc}', flush=True)

def verify_audit_log():
    """Verify the retained audit chain from its first retained record to its head."""
    files = sorted(AUDIT_LOG.parent.glob('audit-[0-9]*T[0-9]*Z.log'), key=lambda path: path.name)
    if AUDIT_LOG.is_file(): files.append(AUDIT_LOG)
    previous = None; count = 0
    pattern = re.compile(r'^(.*) prev=([0-9a-f]{64}) hash=([0-9a-f]{64})$')
    for path in files:
        for line in path.read_text().splitlines():
            match = pattern.fullmatch(line)
            # Upgrades may retain pre-v3 plain-text records before the first
            # chained entry. Once the chain begins, every record is strict.
            if not match:
                if previous is None: continue
                raise ValueError(f'Invalid audit record in {path.name} after chained record {count}.')
            content, recorded_previous, recorded_hash = match.groups()
            if previous is not None and recorded_previous != previous:
                raise ValueError(f'Audit chain break in {path.name} at record {count + 1}.')
            calculated = hashlib.sha256((recorded_previous + '\n' + content).encode()).hexdigest()
            if calculated != recorded_hash: raise ValueError(f'Audit hash mismatch in {path.name} at record {count + 1}.')
            previous = recorded_hash; count += 1
    if previous is not None and AUDIT_CHAIN.is_file() and AUDIT_CHAIN.read_text().strip() != previous:
        raise ValueError('Audit chain head does not match the retained log.')
    return count

def activity_text(mode='chat'):
    try:
        result = run('/usr/bin/journalctl', '-u', 'openrct2.service', '-n', '500',
                     '--no-pager', '--output=short-iso', timeout=10)
        lines = result.stdout.splitlines() if result.returncode == 0 else [
            'Could not read the game log. Check systemd-journal group access.']
        lines = [line for line in lines if 'VERBOSE:' not in line]
    except (OSError, subprocess.TimeoutExpired):
        lines = ['The game log is temporarily unavailable.']
    if mode == 'chat':
        lines = [line for line in lines if '[CHAT]' in line]
        return '\n'.join(lines[-150:])[-50000:] or 'No chat messages yet.'
    try:
        audit = AUDIT_LOG.read_text().splitlines()
    except (FileNotFoundError, OSError):
        audit = []
    if mode == 'dock':
        return ('MANAGER ACTIONS\n' + ('\n'.join(audit[-8:]) or 'No actions yet.') +
                '\n\nGAME SERVER\n' + ('\n'.join(lines[-18:]) or 'No recent events.'))[-12000:]
    return ('MANAGER ACTIONS\n' + ('\n'.join(audit[-60:]) or 'No actions yet.') +
            '\n\nGAME SERVER\n' + ('\n'.join(lines[-150:]) or 'No recent events.'))[-50000:]

def control_request(action, message=None, **extra):
    payload = {'token': CONTROL_TOKEN_FILE.read_text().strip(), 'action': action}
    if message is not None:
        payload['message'] = message
    payload.update(extra)
    try:
        with socket.create_connection(('127.0.0.1', CONTROL_PORT), timeout=3) as connection:
            connection.settimeout(3)
            connection.sendall(json.dumps(payload).encode() + b'\n')
            chunks = []
            total = 0
            while total <= 65536:
                chunk = connection.recv(min(8192, 65537 - total))
                if not chunk:
                    break
                chunks.append(chunk); total += len(chunk)
                if b'\n' in chunk:
                    break
            reply = b''.join(chunks)
            if len(reply) > 65536:
                raise ValueError('The game server response was too large.')
    except OSError as exc:
        raise ValueError('The game connection is unavailable. Restart the game server to load its helper.') from exc
    try:
        result = json.loads(reply)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError('The game server returned an invalid response.') from exc
    if not isinstance(result, dict) or result.get('ok') is not True:
        raise ValueError('The game server rejected the request.')
    return result

def game_status():
    if not service_active():
        return {'online': False, 'players': 0, 'paused': False, 'auto_paused': False, 'auto_pause_enabled': False}
    try:
        result = control_request('status')
        players = result.get('players')
        count = len(players) if isinstance(players, list) else players
        if type(count) is not int or not 0 <= count <= 256:
            raise ValueError('Invalid player count from the game server.')
        return {'online': True, 'players': count, 'details': players if isinstance(players, list) else [],
                'paused': result.get('paused') is True,
                'auto_paused': result.get('auto_paused') is True,
                'auto_pause_enabled': result.get('auto_pause_enabled') is True}
    except (ValueError, OSError):
        return {'online': True, 'players': None, 'paused': None, 'auto_paused': False,
                'auto_pause_enabled': game_config()['pause_when_empty']}

def send_chat(message):
    message = message.strip()
    if not 1 <= len(message) <= 180 or any(ord(character) < 32 for character in message):
        raise ValueError('Write a message of 1–180 characters without line breaks.')
    control_request('chat', message)
    audit_event('Sent game chat announcement')

CALLBACK_SEEN = set()
CALLBACK_LOCK = threading.Lock()

def process_callback(event):
    action = event['action']
    player = re.sub(r'[\r\n\x00-\x1f]+', ' ', event['player_name'])[:32]
    key_hash = event['public_key_hash'].lower()
    if action == 'permission_request':
        event['received_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        event['status'] = 'pending'
        add_permission_request(event)
        audit_event(f'{player} requested {event["permission_name"]} permission ({key_hash[:12]})')
    elif action == 'backup':
        audit_event(f'{player} requested a full backup from game chat')
        try: enqueue_job('full_backup', {'source': 'game_chat', 'player': key_hash})
        except (ValueError, OSError, sqlite3.Error) as exc: audit_event(f'Chat-requested backup failed to queue: {str(exc)[:160]}')
    elif action == 'restart':
        audit_event(f'{player} requested a server restart from game chat')
        control_server('restart')

def callback_client(connection):
    try:
        connection.settimeout(3)
        data = b''
        while b'\n' not in data and len(data) <= 8192:
            chunk = connection.recv(2048)
            if not chunk: break
            data += chunk
        value = json.loads(data.split(b'\n', 1)[0])
        token = str(value.pop('token', ''))
        valid = (hmac.compare_digest(token, CONTROL_TOKEN_FILE.read_text().strip()) and
                 value.get('action') in ('backup', 'restart', 'permission_request') and
                 isinstance(value.get('event_id'), str) and 8 <= len(value['event_id']) <= 96 and
                 type(value.get('player_id')) is int and
                 isinstance(value.get('player_name'), str) and 1 <= len(value['player_name']) <= 32 and
                 isinstance(value.get('public_key_hash'), str) and
                 KEY_HASH.fullmatch(value['public_key_hash'].lower()))
        if value.get('action') == 'permission_request':
            valid = valid and isinstance(value.get('permission'), str) and value['permission'].startswith('PERMISSION_')
            valid = valid and isinstance(value.get('permission_name'), str) and len(value['permission_name']) <= 32
        if not valid:
            connection.sendall(b'{"ok":false,"status":"rejected"}\n'); return
        with CALLBACK_LOCK:
            duplicate = value['event_id'] in CALLBACK_SEEN
            if not duplicate:
                CALLBACK_SEEN.add(value['event_id'])
                if len(CALLBACK_SEEN) > 4096:
                    CALLBACK_SEEN.clear(); CALLBACK_SEEN.add(value['event_id'])
        connection.sendall(b'{"ok":true,"status":"duplicate"}\n' if duplicate else
                           b'{"ok":true,"status":"accepted"}\n')
        if not duplicate:
            threading.Thread(target=process_callback, args=(value,), daemon=True).start()
    except Exception as exc:
        print(f'Callback rejected: {exc}', flush=True)
        try: connection.sendall(b'{"ok":false,"status":"rejected"}\n')
        except OSError: pass
    finally:
        connection.close()

def callback_server():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', CALLBACK_PORT)); listener.listen(16)
    while True:
        connection, address = listener.accept()
        if address[0] != '127.0.0.1':
            connection.close(); continue
        threading.Thread(target=callback_client, args=(connection,), daemon=True).start()

class Handler(BaseHTTPRequestHandler):
    server_version = 'OpenRCT2Manager/2.0'

    def log_message(self, fmt, *args):
        print(f'{self.client_address[0]} - {fmt % args}', flush=True)

    def authenticated(self):
        cookie = self.headers.get('Cookie', '')
        session_id = next((part.split('=', 1)[1] for part in cookie.split('; ')
                           if part.startswith('openrct2_session=')), '')
        if re.fullmatch(r'[0-9a-f]{64}', session_id):
            with SESSION_LOCK:
                session = SESSIONS.get(session_id)
                if session and session['expires'] > time.time():
                    match = next((user for user in portal_users()
                                  if user['id'] == session['user_id'] and user['active']), None)
                    if match:
                        session['expires'] = time.time() + 12 * 3600
                        self.portal_user = match; self.portal_session = session_id
                        self.csrf_token = session['csrf']; return True
                SESSIONS.pop(session_id, None)
        header = self.headers.get('Authorization', '')
        if not header.startswith('Basic '):
            return False
        cache_key = hashlib.sha256(header.encode()).hexdigest()
        cached = AUTH_CACHE.get(cache_key)
        users = portal_users()
        if cached and cached[1] > time.time():
            match = next((user for user in users if user['id'] == cached[0] and user['active']), None)
            if match:
                self.portal_user = match; self.csrf_token = CSRF; return True
        try:
            supplied = base64.b64decode(header[6:], validate=True).decode('utf-8')
            user, password = supplied.split(':', 1)
        except (ValueError, UnicodeDecodeError):
            return False
        match = next((item for item in users if item['username'] == user.strip().lower() and item['active']), None)
        valid = verify_portal_password(password, match['password_hash']) if match else verify_portal_password(
            password, 'pbkdf2_sha256$100000$AAAAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
        if not valid: return False
        self.portal_user = match; self.csrf_token = CSRF
        AUTH_CACHE[cache_key] = (match['id'], time.time() + 60)
        if len(AUTH_CACHE) > 128:
            AUTH_CACHE.clear(); AUTH_CACHE[cache_key] = (match['id'], time.time() + 60)
        return True

    def require_auth(self):
        if self.authenticated():
            return True
        self.send_response(303)
        self.send_header('Location', '/setup' if setup_pending() else '/login')
        self.send_header('Content-Length', '0')
        self.end_headers()
        return False

    def login_page(self, message=''):
        if setup_pending():
            self.send_response(303); self.send_header('Location', '/setup')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        notice = f'<p role="alert">{html.escape(message)}</p>' if message else ''
        body = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sign in · OpenRCT2 Server Manager</title><style>body{{margin:0;min-height:100vh;display:grid;place-items:center;background:#0c1724;color:#e8f1fa;font:15px system-ui}}main{{width:min(390px,calc(100% - 32px));background:#132438;border:1px solid #30465c;border-radius:20px;padding:28px;box-shadow:0 24px 70px #0006}}h1{{margin-top:0}}label{{display:block;margin:15px 0 6px;font-weight:700}}input{{box-sizing:border-box;width:100%;padding:12px;border-radius:11px;border:1px solid #536b82;background:#102034;color:white}}button{{width:100%;margin-top:20px;padding:12px;border:0;border-radius:11px;background:#55b9f4;color:#071521;font-weight:800}}p{{color:#a6b8ca}}</style></head><body><main><h1>OpenRCT2 Server Manager</h1><p>Sign in with your portal account.</p>{notice}<form method="post" action="/login"><label>Username</label><input name="username" autocomplete="username" required autofocus><label>Password</label><input type="password" name="password" autocomplete="current-password" required><button>Sign in</button></form></main></body></html>'''.encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store'); self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers(); self.wfile.write(body)

    def login(self):
        now = time.time(); key = self.client_address[0]
        attempts = [stamp for stamp in LOGIN_ATTEMPTS.get(key, []) if now - stamp < 900]
        if len(attempts) >= 10: self.login_page('Too many attempts. Try again later.'); return
        try: fields, _ = self.read_form()
        except ValueError: self.login_page('Invalid sign-in request.'); return
        username = fields.get('username', '').strip().lower(); password = fields.get('password', '')
        user = next((item for item in portal_users() if item['username'] == username and item['active']), None)
        valid = verify_portal_password(password, user['password_hash']) if user else verify_portal_password(
            password, 'pbkdf2_sha256$100000$AAAAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
        if not valid:
            attempts.append(now); LOGIN_ATTEMPTS[key] = attempts; self.login_page('Incorrect username or password.'); return
        LOGIN_ATTEMPTS.pop(key, None); self.start_session(user)

    def start_session(self, user, location='/'):
        now = time.time(); session_id = secrets.token_hex(32)
        with SESSION_LOCK:
            for item in [item for item, value in SESSIONS.items() if value['expires'] <= now]: SESSIONS.pop(item, None)
            if len(SESSIONS) >= 256: SESSIONS.pop(next(iter(SESSIONS)))
            SESSIONS[session_id] = {'user_id': user['id'], 'csrf': secrets.token_urlsafe(32), 'expires': now + 12 * 3600}
        self.send_response(303); self.send_header('Location', location)
        secure = '; Secure' if MANAGER_DOMAIN or self.headers.get('X-Forwarded-Proto', '').lower() == 'https' else ''
        self.send_header('Set-Cookie', f'openrct2_session={session_id}; Path=/; Max-Age=43200; HttpOnly{secure}; SameSite=Strict')
        self.send_header('Content-Length', '0'); self.end_headers()

    def setup_page(self, message=''):
        if not setup_pending():
            self.send_response(303); self.send_header('Location', '/login' if not portal_users() else '/')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        detected = detected_openrct2(); config = game_config()
        try: suggested_user = CREDENTIALS.read_text().split(':', 1)[0].strip().lower()
        except (FileNotFoundError, OSError): suggested_user = 'admin'
        if not re.fullmatch(r'[a-z0-9][a-z0-9_.-]{0,63}', suggested_user): suggested_user = 'admin'
        notice = f'<div class="notice" role="alert">{html.escape(message)}</div>' if message else ''
        detected_class = 'good' if detected['healthy'] else 'bad'
        checked_advertise = ' checked' if config['advertise'] else ''
        checked_pause = ' checked' if config['pause_when_empty'] else ''
        domain_status = (f'<span class="pill good">HTTPS configured</span><p><code>https://{html.escape(MANAGER_DOMAIN)}/</code></p>'
                         if MANAGER_DOMAIN else '<span class="pill bad">Not configured yet</span>')
        domain_input = (f'<input name="domain" value="{html.escape(MANAGER_DOMAIN)}" readonly>' if MANAGER_DOMAIN else
                        '<input name="domain" placeholder="parks.example.com" pattern="[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,}">')
        body = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>First-time setup · OpenRCT2 Server Manager</title><style>
:root{{--bg:#edf3f8;--card:#fff;--ink:#172b3f;--muted:#63768a;--line:#dbe4ec;--blue:#0877b9;--good:#14704d;--bad:#a63445}}*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}}main{{width:min(920px,calc(100% - 32px));margin:42px auto}}header{{display:flex;align-items:center;gap:16px;margin-bottom:24px}}header img{{width:72px;height:72px;object-fit:cover;border-radius:18px}}h1{{font-size:32px;letter-spacing:-.04em;margin:0}}h2{{font-size:18px;margin:0 0 7px}}p{{color:var(--muted);margin:5px 0 16px}}.card{{background:color-mix(in srgb,var(--card) 93%,transparent);border:1px solid var(--line);border-radius:20px;padding:23px;margin:16px 0;box-shadow:0 14px 40px #17324c0c;backdrop-filter:blur(18px)}}.grid{{display:grid;grid-template-columns:1fr 1fr;gap:16px}}.span{{grid-column:1/-1}}label{{display:block;font-weight:700;margin:5px 0 6px}}input,textarea{{width:100%;padding:11px 12px;border:1px solid #bdccd8;border-radius:11px;background:white;color:var(--ink);font:inherit}}textarea{{min-height:80px;resize:vertical}}.check{{display:flex;align-items:center;gap:8px;font-weight:650}}.check input{{width:auto}}button{{width:100%;border:0;border-radius:12px;padding:13px;background:var(--blue);color:white;font-weight:800;font-size:16px;cursor:pointer}}code{{overflow-wrap:anywhere}}.pill{{display:inline-block;padding:4px 9px;border-radius:99px;font-weight:750;font-size:12px}}.good{{background:#dff3e9;color:var(--good)}}.bad{{background:#fde8eb;color:var(--bad)}}.notice{{background:#fff1dc;border-left:4px solid #d87913;padding:12px 14px;border-radius:9px}}small{{display:block;color:var(--muted);margin-top:5px}}@media(max-width:650px){{.grid{{grid-template-columns:1fr}}.span{{grid-column:auto}}main{{margin:20px auto}}}}
</style></head><body><main><header><img src="/logo.svg" alt=""><div><p>WELCOME</p><h1>Set up your server</h1><p>This one-time guide creates the first Owner and configures the essentials.</p></div></header>{notice}
<form method="post" action="/setup"><section class="card"><h2>1. Verify this installation</h2><p>Enter the one-time setup password printed by the terminal installer.</p><label>One-time setup password</label><input type="password" name="setup_password" autocomplete="one-time-code" required autofocus></section>
<section class="card"><h2>2. OpenRCT2 installation</h2><p><span class="pill {detected_class}">{'Detected' if detected['healthy'] else 'Needs attention'}</span></p><div class="grid"><div><label>Executable</label><code>{html.escape(detected['path'] or 'Not found')}</code></div><div><label>Version</label><code>{html.escape(detected['version'])}</code></div></div><p>The terminal installer searches its supplied path, `/opt/openrct2`, and commands available on PATH. The portal verifies the result without accepting an arbitrary executable path.</p></section>
<section class="card"><h2>3. Create the first Owner</h2><div class="grid"><div><label>Username</label><input name="username" value="{html.escape(suggested_user)}" pattern="[a-z0-9][a-z0-9_.-]{{0,63}}" required></div><div><label>Display name</label><input name="display_name" value="Administrator" maxlength="100" required></div><div><label>New portal password</label><input type="password" name="password" autocomplete="new-password" minlength="12" required><small>At least 12 characters; this replaces the one-time password.</small></div><div><label>Confirm portal password</label><input type="password" name="password_confirm" autocomplete="new-password" minlength="12" required></div></div></section>
<section class="card"><h2>4. Server basics</h2><div class="grid"><div><label>Server name</label><input name="server_name" value="{html.escape(config['server_name'])}" maxlength="64" required></div><div><label>Maximum players</label><input type="number" name="max_players" min="1" max="255" value="{config['max_players']}" required></div><div class="span"><label>Description</label><input name="server_description" value="{html.escape(config['server_description'])}" maxlength="200"></div><div class="span"><label>Greeting / MOTD</label><textarea name="server_greeting" maxlength="500">{html.escape(config['server_greeting'])}</textarea></div><label class="check"><input type="checkbox" name="advertise" value="yes"{checked_advertise}> List in the OpenRCT2 server browser</label><label class="check"><input type="checkbox" name="pause_when_empty" value="yes"{checked_pause}> Pause simulation when nobody is connected</label></div></section>
<section class="card"><h2>5. Domain and HTTPS</h2>{domain_status}<p>Enter the hostname you want to use. After setup, the guide will show the DNS, firewall and one-command HTTPS steps. DNS and AWS firewall changes require your hosting account and are never guessed by the portal.</p><label>Manager hostname (optional)</label>{domain_input}<small>Use a hostname such as parks.example.com, not an IP address or URL.</small></section><button>Finish setup and sign in</button></form></main></body></html>'''.encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store'); self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer'); self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Security-Policy', "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers(); self.wfile.write(body)

    def finish_setup(self):
        key = 'setup:' + self.client_address[0]; now = time.time()
        attempts = [stamp for stamp in LOGIN_ATTEMPTS.get(key, []) if now - stamp < 900]
        if len(attempts) >= 10: self.setup_page('Too many attempts. Try again in 15 minutes.'); return
        try: fields, _ = self.read_form()
        except ValueError: self.setup_page('Invalid setup request.'); return
        record = setup_record(); supplied = fields.get('setup_password', '')
        valid = verify_portal_password(supplied, record['password_hash']) if record else verify_portal_password(
            supplied, 'pbkdf2_sha256$100000$AAAAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
        if not valid:
            attempts.append(now); LOGIN_ATTEMPTS[key] = attempts; self.setup_page('The one-time setup password is incorrect.'); return
        detected = detected_openrct2()
        if not detected['healthy']: self.setup_page('OpenRCT2 could not be verified. Run the installer repair step and try again.'); return
        username = fields.get('username', '').strip().lower(); display_name = fields.get('display_name', '').strip()
        requested_domain = fields.get('domain', '').strip().lower()
        if requested_domain and not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}', requested_domain):
            self.setup_page('Enter a valid hostname such as parks.example.com, without https:// or a path.'); return
        password = fields.get('password', '')
        if password != fields.get('password_confirm', ''): self.setup_page('The new portal passwords do not match.'); return
        if not re.fullmatch(r'[a-z0-9][a-z0-9_.-]{0,63}', username) or not 1 <= len(display_name) <= 100:
            self.setup_page('Enter a valid Owner username and display name.'); return
        try:
            password_hash = hash_portal_password(password)
            values = {'server_name': fields.get('server_name', ''),
                      'server_description': fields.get('server_description', ''),
                      'server_greeting': fields.get('server_greeting', ''),
                      'max_players': fields.get('max_players', ''), 'port': str(game_config()['port']),
                      'advertise': fields.get('advertise') == 'yes',
                      'advertise_address': game_config()['advertise_address'],
                      'pause_when_empty': fields.get('pause_when_empty') == 'yes',
                      'autosave': str(game_config()['autosave']), 'autosave_amount': str(game_config()['autosave_amount'])}
            with CHANGE_LOCK: update_game_config(values)
            user = {'id': secrets.token_hex(16), 'username': username, 'display_name': display_name,
                    'role': 'owner', 'active': True, 'password_hash': password_hash}
            save_portal_users([user])
            write_json(SETUP_COMPLETE, {'schema': 1, 'completed_at': int(time.time()),
                                        'owner_id': user['id']})
            SETUP_STATE.unlink(missing_ok=True); LOGIN_ATTEMPTS.pop(key, None)
            audit_event('Completed browser first-time setup', actor=username, target='server')
            if service_active(): control_server('restart')
            destination = '/setup-complete?' + urllib.parse.urlencode({'domain': requested_domain})
            self.start_session(user, destination)
        except (ValueError, OSError, subprocess.SubprocessError) as exc:
            self.setup_page(str(exc))

    def setup_complete_page(self, domain):
        domain = domain.strip().lower()
        configured = bool(MANAGER_DOMAIN)
        if domain and not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}', domain): domain = ''
        hostname = MANAGER_DOMAIN or domain
        address = game_config()['advertise_address'] or 'this server’s public IP address'
        if configured:
            https_steps = f'<div class="done"><strong>HTTPS is already configured.</strong><br><a href="https://{html.escape(MANAGER_DOMAIN)}/">https://{html.escape(MANAGER_DOMAIN)}/</a></div>'
        elif hostname:
            command = 'sudo openrct2-manager-enable-https ' + shlex.quote(hostname)
            https_steps = (f'<ol><li>Create a DNS <strong>A record</strong> for <code>{html.escape(hostname)}</code> pointing to <code>{html.escape(address)}</code>.</li>'
                           '<li>Allow inbound TCP ports <strong>80</strong> and <strong>443</strong> in the cloud firewall. Keep manager port 8080 private.</li>'
                           f'<li>After DNS resolves, run this on the server:<pre>{html.escape(command)}</pre></li>'
                           f'<li>Open <code>https://{html.escape(hostname)}/</code> and confirm the browser shows a valid certificate.</li></ol>')
        else:
            https_steps = '<p>No hostname was supplied. Continue through an SSH tunnel for now. You can later run <code>sudo openrct2-manager-enable-https parks.example.com</code>.</p>'
        body = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Setup complete · OpenRCT2 Server Manager</title><style>body{{margin:0;background:#edf3f8;color:#172b3f;font:15px/1.55 system-ui,-apple-system,sans-serif}}main{{width:min(760px,calc(100% - 32px));margin:45px auto}}.card{{background:white;border:1px solid #dbe4ec;border-radius:20px;padding:26px;box-shadow:0 16px 45px #17324c12}}h1{{font-size:32px;letter-spacing:-.04em;margin:0 0 8px}}h2{{margin-top:28px}}p,li{{color:#5e7185}}li{{margin:12px 0}}code,pre{{background:#eaf0f5;border-radius:8px;padding:3px 6px;color:#17324c}}pre{{padding:13px;overflow:auto}}a.button{{display:inline-block;margin-top:18px;background:#0877b9;color:white;text-decoration:none;padding:11px 16px;border-radius:11px;font-weight:800}}.done{{background:#dff3e9;color:#14704d;padding:14px;border-radius:11px}}</style></head><body><main><div class="card"><p>SETUP COMPLETE</p><h1>Your manager is ready</h1><p>The first Owner account has been created and the one-time setup password has been invalidated.</p><h2>Domain and HTTPS</h2>{https_steps}<h2>Next step</h2><p>Open the Scenario Database, upload a park or saved game, and launch it.</p><a class="button" href="/">Open the dashboard</a></div></main></body></html>'''.encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY'); self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.end_headers(); self.wfile.write(body)

    def require_capability(self, capability):
        allowed = ROLE_CAPABILITIES[self.portal_user['role']]
        if '*' in allowed or capability in allowed: return True
        self.error_page(403, 'Your portal role does not allow this action.')
        return False

    def redirect(self, message='', tab='overview'):
        target = '/?' + urllib.parse.urlencode({'tab': tab, 'message': message})
        self.send_response(303)
        self.send_header('Location', target)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def error_page(self, status, message):
        body = (f'<!doctype html><meta charset="utf-8"><title>Error</title>'
                f'<h1>{status}</h1><p>{html.escape(message)}</p>'
                f'<p><a href="/">Back to manager</a></p>').encode()
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_form(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length < 0 or length > MAX_UPLOAD + 1024 * 1024:
            raise ValueError(f'Request exceeds the {MAX_UPLOAD // 1024 // 1024} MB upload limit.')
        content_type = self.headers.get('Content-Type', '')
        body = self.rfile.read(length)
        if content_type.startswith('application/x-www-form-urlencoded'):
            parsed = urllib.parse.parse_qs(body.decode('utf-8'), keep_blank_values=True)
            return {key: values[-1] for key, values in parsed.items()}, None
        if content_type.startswith('multipart/form-data'):
            message = BytesParser(policy=default).parsebytes(
                b'Content-Type: ' + content_type.encode('ascii') + b'\r\nMIME-Version: 1.0\r\n\r\n' + body
            )
            fields, uploads = {}, []
            for part in message.iter_parts():
                name = part.get_param('name', header='content-disposition')
                filename = part.get_filename()
                payload = part.get_payload(decode=True) or b''
                if filename is not None:
                    uploads.append((filename, payload))
                elif name:
                    fields[name] = payload.decode('utf-8', 'replace')
            return fields, uploads
        raise ValueError('Unsupported form encoding.')

    def check_csrf(self, fields):
        return hmac.compare_digest(fields.get('csrf', ''), getattr(self, 'csrf_token', CSRF))

    def do_GET(self):
        public_path = urllib.parse.urlparse(self.path).path
        if public_path == '/logo.svg':
            data = LOGO_SVG.encode('utf-8'); self.send_response(200)
            self.send_header('Content-Type', 'image/svg+xml; charset=utf-8'); self.send_header('Cache-Control', 'public, max-age=86400')
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        if public_path == '/setup':
            self.setup_page(); return
        if public_path == '/login':
            self.login_page(); return
        if not self.require_auth():
            return
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/setup-complete':
            domain = urllib.parse.parse_qs(parsed.query).get('domain', [''])[0]
            self.setup_complete_page(domain); return
        if parsed.path == '/events':
            if not SSE_SLOTS.acquire(blocking=False):
                self.error_page(503, 'Too many live browser connections. Close an unused manager tab and retry.')
                return
            try:
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Cache-Control', 'no-cache, no-store'); self.send_header('Connection', 'keep-alive')
                self.send_header('X-Accel-Buffering', 'no'); self.end_headers()
                # Deliberately recycle streams so abandoned browser/network state cannot
                # retain a server thread indefinitely. EventSource reconnects automatically.
                for _ in range(12):
                    payload = json.dumps({'status': game_status(), 'activity': activity_text('dock')},
                                         separators=(',', ':')).replace('\n', '\\n')
                    self.wfile.write(f'data: {payload}\n\n'.encode()); self.wfile.flush(); time.sleep(5)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                SSE_SLOTS.release()
            return
        if parsed.path == '/':
            message = urllib.parse.parse_qs(parsed.query).get('message', [''])[0]
            tab = urllib.parse.parse_qs(parsed.query).get('tab', ['overview'])[0]
            tab_capability = {'users': 'portal.manage', 'groups': 'group.manage'}.get(tab)
            if tab_capability and not self.require_capability(tab_capability): return
            try:
                self.dashboard(message, tab)
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                self.error_page(500, str(exc))
            return
        if parsed.path == '/logo.svg':
            data = LOGO_SVG.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'image/svg+xml; charset=utf-8')
            self.send_header('Cache-Control', 'public, max-age=86400')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == '/logo.png' and LOGO_PNG.is_file():
            data = LOGO_PNG.read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Cache-Control', 'public, max-age=86400')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == '/activity.txt':
            mode = urllib.parse.parse_qs(parsed.query).get('mode', ['chat'])[0]
            if mode not in ('chat', 'console', 'dock'):
                self.error_page(400, 'Unknown activity view.')
                return
            data = activity_text(mode).encode('utf-8', 'replace')
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == '/activity-export.txt':
            data = activity_text('console').encode('utf-8', 'replace')
            self.send_response(200); self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Disposition', 'attachment; filename="openrct2-activity.txt"')
            self.send_header('Cache-Control', 'no-store'); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        if parsed.path == '/status.json':
            data = json.dumps(game_status()).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path.startswith('/backup/'):
            self.download_backup(urllib.parse.unquote(parsed.path.removeprefix('/backup/')))
            return
        if parsed.path.startswith('/snapshot/'):
            self.download_snapshot(urllib.parse.unquote(parsed.path.removeprefix('/snapshot/')))
            return
        if parsed.path.startswith('/quick-save/'):
            self.download_quick_save(urllib.parse.unquote(parsed.path.removeprefix('/quick-save/')))
            return
        if parsed.path.startswith('/save/'):
            self.download_save(urllib.parse.unquote(parsed.path.removeprefix('/save/')))
            return
        self.error_page(404, 'Not found.')

    def do_POST(self):
        if self.path == '/setup':
            self.finish_setup(); return
        if self.path == '/login':
            self.login(); return
        if not self.require_auth():
            return
        required = {
            '/upload': 'scenario.manage', '/select': 'scenario.manage', '/permissions': 'player.manage',
            '/block': 'player.manage', '/kick': 'player.manage', '/snapshot-settings': 'backup.manage', '/motd': 'settings.manage',
            '/command-grant': 'player.manage', '/group-action': 'group.manage', '/chat': 'chat.send',
            '/action': 'server.control', '/portal-user': 'portal.manage',
            '/server-settings': 'settings.manage',
            '/permission-request': 'player.manage',
            '/player-permission': 'player.manage',
            '/backup-destination': 'backup.manage',
            '/scenario-archive': 'scenario.manage',
            '/version-check': 'view',
            '/logout': 'view',
        }.get(self.path)
        if required and not self.require_capability(required): return
        correlation = secrets.token_hex(8)
        try:
            fields, upload = self.read_form()
            if not self.check_csrf(fields):
                self.error_page(403, 'The form expired. Refresh the page and try again.')
                return
            if self.path == '/upload':
                self.upload(fields, upload)
            elif self.path == '/select':
                self.select(fields)
            elif self.path == '/permissions':
                self.permissions(fields)
            elif self.path == '/block':
                self.block(fields)
            elif self.path == '/kick':
                self.kick(fields)
            elif self.path == '/snapshot-settings':
                self.snapshot_settings(fields)
            elif self.path == '/motd':
                self.motd(fields)
            elif self.path == '/command-grant':
                self.command_grant(fields)
            elif self.path == '/group-action':
                self.group_action(fields)
            elif self.path == '/portal-user':
                self.portal_user_action(fields)
            elif self.path == '/server-settings':
                self.server_settings(fields)
            elif self.path == '/permission-request':
                self.permission_request_action(fields)
            elif self.path == '/player-permission':
                self.player_permission_action(fields)
            elif self.path == '/backup-destination':
                self.backup_destination_action(fields)
            elif self.path == '/scenario-archive':
                self.scenario_archive_action(fields)
            elif self.path == '/version-check':
                latest = check_latest_version(); audit_event('Checked official OpenRCT2 version feed')
                self.redirect(f'Latest stable OpenRCT2 version is {latest}.', fields.get('return_tab', 'settings'))
            elif self.path == '/logout':
                session_id = getattr(self, 'portal_session', '')
                with SESSION_LOCK: SESSIONS.pop(session_id, None)
                self.send_response(303); self.send_header('Location', '/login')
                secure = '; Secure' if MANAGER_DOMAIN or self.headers.get('X-Forwarded-Proto', '').lower() == 'https' else ''
                self.send_header('Set-Cookie', f'openrct2_session=; Path=/; Max-Age=0; HttpOnly{secure}; SameSite=Strict')
                self.send_header('Content-Length', '0'); self.end_headers()
            elif self.path == '/chat':
                send_chat(fields.get('message', ''))
                self.redirect('Message sent to players.',
                              'overview' if fields.get('return_tab') == 'overview' else 'activity')
            elif self.path == '/action':
                self.action(fields)
            else:
                self.error_page(404, 'Not found.')
            audit_event('Portal request completed', actor=self.portal_user['username'], target=self.path,
                        outcome='success', correlation=correlation)
        except (ValueError, OSError, sqlite3.Error, subprocess.SubprocessError) as exc:
            audit_event(str(exc), actor=self.portal_user['username'], target=self.path,
                        outcome='failure', correlation=correlation)
            self.error_page(400, str(exc))

    def upload(self, fields, uploads):
        uploads = [(safe_name(name), content) for name, content in (uploads or []) if name]
        if not uploads:
            raise ValueError('Choose one or more scenarios or saved parks first.')
        names = [name for name, _ in uploads]
        if len(names) != len(set(names)):
            raise ValueError('Two uploaded files have the same name after cleaning their filenames.')
        for filename, content in uploads:
            if not filename or Path(filename).suffix.lower() not in ALLOWED:
                raise ValueError('Allowed file types: .park, .sv6, .sv4, .sc6 and .sc4.')
            if not content:
                raise ValueError(f'{filename} is empty.')
            if (SCENARIOS / filename).exists() and fields.get('overwrite') != 'yes':
                raise ValueError(f'{filename} already exists. Tick overwrite to replace it.')
        if sum(len(content) for _, content in uploads) > MAX_UPLOAD:
            raise ValueError(f'Total files exceed the {MAX_UPLOAD // 1024 // 1024} MB upload limit.')
        with CHANGE_LOCK:
            for filename, content in uploads:
                with tempfile.NamedTemporaryFile(dir=SCENARIOS, prefix='.upload-', delete=False) as temp:
                    temp.write(content)
                    temp_path = Path(temp.name)
                try:
                    os.chmod(temp_path, 0o640)
                    os.replace(temp_path, SCENARIOS / filename)
                finally:
                    temp_path.unlink(missing_ok=True)
        audit_event(f'Uploaded {len(uploads)} park file(s)')
        self.redirect(f'Uploaded {len(uploads)} park(s). Choose one below to launch it.', 'parks')

    def select(self, fields):
        choice = fields.get('scenario', '')
        saved = choice.startswith('quick:') or choice.startswith('save:')
        filename = choice.split(':', 1)[1] if saved else choice
        if filename != safe_name(filename) or Path(filename).suffix.lower() not in ALLOWED:
            raise ValueError('Invalid scenario name.')
        source = SAVES / filename if saved else SCENARIOS / filename
        if saved and not SAVE_FILE_NAME.fullmatch(filename):
            raise ValueError('That is not a supported saved game.')
        if not source.is_file():
            raise ValueError('That park no longer exists.')
        with CHANGE_LOCK:
            old_selection = selected_name(); was_active = service_active(); safety_save = None
            if was_active:
                safety_save = create_live_switch_save()
            if saved:
                destination = SCENARIOS / filename
                if destination.exists() and not filecmp.cmp(source, destination, shallow=False):
                    raise ValueError('A library park already has this quick-save name; rename it before launching.')
                if not destination.exists():
                    with tempfile.NamedTemporaryFile(dir=SCENARIOS, prefix='.quick-save-', delete=False) as temp:
                        temp_path = Path(temp.name)
                    try:
                        shutil.copyfile(source, temp_path)
                        os.chmod(temp_path, 0o640)
                        os.replace(temp_path, destination)
                    finally:
                        temp_path.unlink(missing_ok=True)
            write_selection(filename)
            try:
                control_server('restart' if was_active else 'start')
                wait_for_game_health()
            except (ValueError, OSError, subprocess.SubprocessError) as launch_error:
                if old_selection:
                    write_selection(old_selection)
                    try:
                        control_server('restart' if service_active() else 'start'); wait_for_game_health()
                    except Exception as rollback_error:
                        audit_event(f'CRITICAL park rollback failed after {filename}: {rollback_error}')
                        raise ValueError(f'{filename} failed to launch and rollback also failed; inspect the game service immediately.') from launch_error
                    audit_event(f'Rolled back failed park launch {filename} to {old_selection}')
                    raise ValueError(f'{filename} failed to launch. The previous park was restored automatically.') from launch_error
                raise
        audit_event(f'Launched park {filename}; safety save {safety_save.name if safety_save else "not needed"}')
        self.redirect(f'Launched {filename}. A pre-switch safety save was created first.' if safety_save else f'Launched {filename}.', 'parks')

    def scenario_archive_action(self, fields):
        filename = safe_name(fields.get('scenario', '')); mode = fields.get('mode', '')
        if Path(filename).suffix.lower() not in ALLOWED or mode not in ('archive', 'restore'):
            raise ValueError('Choose a valid scenario and archive action.')
        SCENARIO_ARCHIVE.mkdir(parents=True, exist_ok=True)
        source, destination = ((SCENARIOS / filename, SCENARIO_ARCHIVE / filename) if mode == 'archive'
                               else (SCENARIO_ARCHIVE / filename, SCENARIOS / filename))
        if mode == 'archive' and filename == selected_name():
            raise ValueError('The running park cannot be archived. Launch another park first.')
        if not source.is_file(): raise ValueError('That scenario no longer exists.')
        if destination.exists(): raise ValueError('A file with that name already exists at the destination.')
        with CHANGE_LOCK: os.replace(source, destination)
        audit_event(f'{mode.title()}d scenario {filename}', actor=self.portal_user['username'], target=filename)
        self.redirect(f'{filename} {mode}d successfully.', 'parks')

    def permissions(self, fields):
        key_hash = fields.get('hash', '').lower()
        if not KEY_HASH.fullmatch(key_hash):
            raise ValueError('Choose a saved player identity.')
        try:
            group_id = int(fields.get('role', ''))
        except ValueError:
            raise ValueError('Choose a valid role.')
        groups = control_request('groups').get('groups', []) if service_active() else []
        if groups and not any(group.get('id') == group_id for group in groups):
            raise ValueError('Choose a valid role.')
        if not groups and group_id not in ROLES:
            raise ValueError('Choose a valid role.')

        matches = [item for item in visible_user_roles() if item['hash'].lower() == key_hash]
        if not matches:
            raise ValueError('This player identity is no longer in the saved list.')
        player = matches[0]['name']
        with CHANGE_LOCK:
            individual = player_permission_overrides()
            if key_hash in individual:
                individual[key_hash]['base_group'] = group_id
                save_player_permission_overrides(individual)
            if service_active():
                try:
                    effective_group = (apply_player_permission_override(key_hash, individual[key_hash])
                                       if key_hash in individual else group_id)
                    if key_hash not in individual:
                        control_request('set_role', hash=key_hash, group=group_id)
                except ValueError as exc:
                    raise ValueError('Role was saved, but the live game helper could not apply it. '
                                     'Check the game activity log before changing it again.') from exc
            else:
                effective_group = group_id
                users = all_user_records()
                for item in users:
                    if isinstance(item, dict) and str(item.get('hash', '')).lower() == key_hash:
                        item['groupId'] = group_id
                write_user_roles(users)
            overrides = role_overrides(); overrides[key_hash] = effective_group
            write_json(ROLE_OVERRIDES, overrides)
            publish_helper(settings())
        role_name = next((str(group.get('name')) for group in groups if group.get('id') == group_id), ROLES.get(group_id, f'Group {group_id}'))
        audit_event(f'Changed player key {key_hash[:12]} to {role_name}')
        self.redirect(f'{player} is now {role_name}. The game was not restarted.', 'players')

    def player_permission_action(self, fields):
        key_hash = fields.get('hash', '').lower(); permission = fields.get('permission', '')
        mode = fields.get('override', '')
        if (not KEY_HASH.fullmatch(key_hash) or permission not in GROUP_PERMISSIONS or
                mode not in ('inherit', 'allow', 'deny')):
            raise ValueError('Choose a valid player, permission, and override.')
        user = next((item for item in user_roles() if item['hash'].lower() == key_hash), None)
        if not user: raise ValueError('This player identity is no longer in the saved list.')
        overrides = player_permission_overrides()
        current = overrides.get(key_hash)
        if current is None:
            visible_role = next((item.get('groupId', 2) for item in visible_user_roles()
                                 if item['hash'].lower() == key_hash), 2)
            live_groups = control_request('groups').get('groups', [])
            base_group = int(visible_role)
            if any(group.get('id') == base_group and str(group.get('name', '')).startswith('@manager/')
                   for group in live_groups):
                base_group = int(user.get('groupId', 2))
            current = {'base_group': base_group, 'allow': [], 'deny': []}
        allow, deny = set(current['allow']), set(current['deny'])
        allow.discard(permission); deny.discard(permission)
        if mode == 'allow': allow.add(permission)
        elif mode == 'deny': deny.add(permission)
        current['allow'] = sorted(allow); current['deny'] = sorted(deny)
        if allow or deny: overrides[key_hash] = current
        else: overrides.pop(key_hash, None)
        with CHANGE_LOCK:
            effective = apply_player_permission_override(key_hash, current)
            save_player_permission_overrides(overrides)
            roles = role_overrides(); roles[key_hash] = effective; write_json(ROLE_OVERRIDES, roles)
            if not allow and not deny:
                state = control_request('groups')
                derived = next((group for group in state.get('groups', [])
                                if group.get('name') == '@manager/' + key_hash[:10]), None)
                if derived: control_request('group_delete', group=int(derived['id']))
            publish_helper(settings())
        audit_event(f'Set {permission} override to {mode} for player key {key_hash[:12]}')
        self.redirect(f'Individual permission updated live for {user["name"]}.', 'players')

    def block(self, fields):
        key_hash = fields.get('hash', '').lower()
        action = fields.get('mode', '')
        if not KEY_HASH.fullmatch(key_hash) or action not in ('block', 'unblock'):
            raise ValueError('Choose a valid saved player and action.')
        if not any(item['hash'].lower() == key_hash for item in user_roles()):
            raise ValueError('This player identity is no longer in the saved list.')
        def update():
            config = settings()
            blocked = set(config['blocked_hashes'])
            if action == 'block':
                blocked.add(key_hash)
            else:
                blocked.discard(key_hash)
            config['blocked_hashes'] = sorted(blocked)
            save_settings(config)
        with CHANGE_LOCK:
            update()
            if service_active():
                control_request('set_blocked', hash=key_hash, blocked=(action == 'block'))
        audit_event(f'{action.capitalize()}ed player key {key_hash[:12]}')
        self.redirect(f'Player identity {action}ed. The game was not restarted.', 'players')

    def kick(self, fields):
        key_hash = fields.get('hash', '').lower()
        if not KEY_HASH.fullmatch(key_hash): raise ValueError('Choose a valid player identity.')
        state = game_status(); player = next((item for item in state.get('details', [])
                                             if item.get('public_key_hash') == key_hash), None)
        if not player: raise ValueError('That player is no longer connected.')
        player_id = player.get('id')
        if type(player_id) is not int: raise ValueError('The live player record is invalid.')
        control_request('kick', player_id=player_id)
        audit_event(f'Kicked connected player key {key_hash[:12]} without blocking it')
        self.redirect('Player disconnected. Their identity was not blocked.', 'players')

    def snapshot_settings(self, fields):
        try:
            minutes = int(fields.get('minutes', ''))
            keep = int(fields.get('keep', ''))
        except ValueError:
            raise ValueError('Enter whole numbers for the interval and copies to keep.')
        if not 0 <= minutes <= 1440 or not 1 <= keep <= 500:
            raise ValueError('Minutes must be 0–1440; copies to keep must be 1–500.')
        def update():
            config = settings()
            config['snapshot_minutes'] = minutes
            config['snapshot_keep'] = keep
            save_settings(config)
            prune_snapshots()
        with CHANGE_LOCK:
            update()
            if service_active():
                control_request('set_snapshot_config', minutes=minutes)
        audit_event(f'Set live snapshot interval to {minutes} minute(s), retaining {keep}')
        self.redirect(f'Automatic snapshots set to every {minutes} minute(s); keeping {keep}. No restart was needed.', 'backups')

    def motd(self, fields):
        lines = [line.strip() for line in fields.get('motd', '').splitlines() if line.strip()]
        if len(lines) > 5 or any(len(line) > 180 or any(ord(char) < 32 for char in line) for line in lines):
            raise ValueError('The MOTD supports up to five lines of 180 printable characters each.')
        if service_active():
            control_request('set_motd', lines=lines)
        write_json(MOTD_FILE, {'lines': lines})
        audit_event('Updated the message of the day')
        self.redirect('Message of the day updated live.', 'settings')

    def command_grant(self, fields):
        key_hash = fields.get('hash', '').lower(); command = fields.get('command', '')
        allowed = fields.get('allowed') == 'yes'
        if not KEY_HASH.fullmatch(key_hash) or command not in ('save', 'backup', 'restart', '*'):
            raise ValueError('Choose a valid player and command.')
        grants = command_grants(); commands = set(grants.get(key_hash, []))
        commands.add(command) if allowed else commands.discard(command)
        if commands: grants[key_hash] = sorted(commands)
        else: grants.pop(key_hash, None)
        if service_active():
            control_request('set_command_access', hash=key_hash, command=command, allowed=allowed)
        write_json(COMMAND_GRANTS, grants); publish_helper(settings())
        audit_event(f'{"Granted" if allowed else "Revoked"} /{command} for player key {key_hash[:12]}')
        self.redirect('In-game command access updated live.', 'players')

    def group_action(self, fields):
        action = fields.get('mode', '')
        if action == 'create':
            name = fields.get('name', '').strip()
            if not 1 <= len(name) <= 32 or any(ord(char) < 32 for char in name):
                raise ValueError('Group names must contain 1–32 printable characters.')
            control_request('group_create', name=name)
        elif action in ('rename', 'delete', 'default', 'permission'):
            try: group = int(fields.get('group', ''))
            except ValueError: raise ValueError('Choose a valid group.')
            if action == 'rename':
                name = fields.get('name', '').strip()
                if group == 0 or not 1 <= len(name) <= 32: raise ValueError('Choose a valid editable group and name.')
                control_request('group_rename', group=group, name=name)
            elif action == 'delete': control_request('group_delete', group=group)
            elif action == 'default': control_request('group_default', group=group)
            else:
                permission = fields.get('permission', '')
                if not re.fullmatch(r'PERMISSION_[A-Z_]{2,40}', permission): raise ValueError('Choose a valid permission.')
                control_request('group_permission', group=group, permission=permission,
                                allowed=fields.get('allowed') == 'yes')
        else: raise ValueError('Unknown group action.')
        audit_event(f'Applied live in-game group change: {action}')
        self.redirect('In-game permission groups updated live.', 'groups')

    def portal_user_action(self, fields):
        mode = fields.get('mode', '')
        users = portal_users()
        if mode == 'create':
            username = fields.get('username', '').strip().lower()
            display_name = fields.get('display_name', '').strip()
            role = fields.get('role', '')
            password = fields.get('password', '')
            if (not re.fullmatch(r'[a-z0-9][a-z0-9_.-]{0,63}', username) or
                    not 1 <= len(display_name) <= 100 or role not in PORTAL_ROLES):
                raise ValueError('Enter a valid username, display name, and portal role.')
            if any(user['username'] == username for user in users):
                raise ValueError('That portal username already exists.')
            users.append({'id': secrets.token_hex(16), 'username': username, 'display_name': display_name,
                          'role': role, 'active': True, 'password_hash': hash_portal_password(password)})
        elif mode in ('update', 'delete', 'password'):
            user_id = fields.get('id', '')
            target = next((user for user in users if user['id'] == user_id), None)
            if not target: raise ValueError('That portal user no longer exists.')
            if mode == 'delete':
                users = [user for user in users if user['id'] != user_id]
            elif mode == 'password':
                target['password_hash'] = hash_portal_password(fields.get('password', ''))
            else:
                role = fields.get('role', '')
                if role not in PORTAL_ROLES: raise ValueError('Choose a valid portal role.')
                target['role'] = role; target['active'] = fields.get('active') == 'yes'
        else: raise ValueError('Unknown portal-user action.')
        save_portal_users(users)
        audit_event(f'Portal Owner applied user action: {mode}')
        self.redirect('Portal users updated.', 'users')

    def server_settings(self, fields):
        if fields.get('game_password', '') != fields.get('game_password_confirm', ''):
            raise ValueError('The new game password and confirmation do not match.')
        values = {
            'server_name': fields.get('server_name', ''), 'server_description': fields.get('server_description', ''),
            'server_greeting': fields.get('server_greeting', ''), 'max_players': fields.get('max_players', ''),
            'port': fields.get('port', ''), 'advertise': fields.get('advertise') == 'yes',
            'advertise_address': fields.get('advertise_address', ''),
            'pause_when_empty': fields.get('pause_when_empty') == 'yes', 'autosave': fields.get('autosave', ''),
            'autosave_amount': fields.get('autosave_amount', ''),
        }
        with CHANGE_LOCK:
            update_game_config(values, password=fields.get('game_password', ''),
                               remove_password=fields.get('remove_password') == 'yes')
            control_server('restart' if service_active() else 'start')
        audit_event('Updated OpenRCT2 server settings and restarted the game')
        self.redirect('Server settings saved and the game restarted.', 'settings')

    def permission_request_action(self, fields):
        event_id = fields.get('event_id', ''); decision = fields.get('decision', '')
        if decision not in ('approve', 'reject'): raise ValueError('Choose approve or reject.')
        requests = permission_requests()
        request = next((item for item in requests if isinstance(item, dict) and item.get('event_id') == event_id), None)
        if not request or request.get('status') != 'pending': raise ValueError('That request is no longer pending.')
        if decision == 'approve':
            key_hash = str(request.get('public_key_hash', '')).lower(); permission = request.get('permission')
            if not KEY_HASH.fullmatch(key_hash) or permission not in GROUP_PERMISSIONS:
                raise ValueError('The permission request is invalid.')
            individual = player_permission_overrides(); current = individual.get(key_hash)
            if current is None:
                saved = next((item for item in user_roles() if item['hash'].lower() == key_hash), None)
                current = {'base_group': int(saved.get('groupId', 2)) if saved else 2,
                           'allow': [], 'deny': []}
            current['allow'] = sorted(set(current['allow']) | {permission})
            current['deny'] = sorted(set(current['deny']) - {permission})
            individual[key_hash] = current
            apply_player_permission_override(key_hash, current)
            save_player_permission_overrides(individual)
            publish_helper(settings())
        request['status'] = 'approved' if decision == 'approve' else 'rejected'
        request['resolved_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        request['resolved_by'] = self.portal_user['username']
        write_json(PERMISSION_REQUESTS, requests)
        audit_event(f'{decision.title()}d in-game permission request {event_id[:24]}')
        self.redirect(f'Permission request {request["status"]}.', 'players')

    def backup_destination_action(self, fields):
        mode = fields.get('mode', ''); rows = backup_destinations()
        if mode == 'create':
            kind = fields.get('type', ''); name = fields.get('name', '').strip()
            schedule = fields.get('schedule', 'manual')
            if kind not in ('sftp', 's3', 'rclone') or schedule not in ('manual', 'after_backup', 'daily', 'weekly'):
                raise ValueError('Choose a supported backup type and schedule.')
            if not 1 <= len(name) <= 64 or any(ord(char) < 32 for char in name):
                raise ValueError('Destination name must contain 1–64 printable characters.')
            config = ({'host': fields.get('host', '').strip(), 'username': fields.get('username', '').strip(),
                       'path': fields.get('remote_path', '').strip(), 'port': int(fields.get('port', '22')),
                       'identity': fields.get('identity', '').strip()} if kind == 'sftp' else
                      {'bucket': fields.get('bucket', '').strip(), 'prefix': fields.get('prefix', '').strip()}
                      if kind == 's3' else
                      {'remote': fields.get('remote', '').strip(), 'path': fields.get('remote_path', '').strip()})
            interval = 86400 if schedule == 'daily' else 604800 if schedule == 'weekly' else 0
            rows.append({'id': secrets.token_hex(12), 'name': name, 'type': kind, 'schedule': schedule,
                         'config': config, 'created_at': int(time.time()),
                         'retention': max(1, min(1000, int(fields.get('retention', '30')))),
                         'next_at': int(time.time()) + interval if interval else 0,
                         'last_at': '', 'last_status': 'Not tested', 'last_location': ''})
            save_backup_destinations(rows); audit_event(f'Created {kind} backup destination {name}')
            self.redirect('Backup destination saved. Use Test before relying on it.', 'backups'); return
        target_id = fields.get('id', ''); target = next((row for row in rows if row['id'] == target_id), None)
        if not target: raise ValueError('That backup destination no longer exists.')
        if mode == 'delete':
            rows = [row for row in rows if row['id'] != target_id]
            save_backup_destinations(rows); audit_event(f'Deleted backup destination {target["name"]}')
            self.redirect('Backup destination removed. Remote files were left untouched.', 'backups'); return
        if mode not in ('test', 'backup'): raise ValueError('Unknown backup destination action.')
        if mode == 'backup':
            job_id = enqueue_job('destination_backup', {'destination_id': target_id})
            target['last_status'] = 'Queued'; save_backup_destinations(rows)
            audit_event(f'Queued remote backup to {target["name"]} as job {job_id[:12]}')
            self.redirect(f'Remote backup queued for {target["name"]}.', 'backups'); return
        try:
            location = test_destination(target)
            target['last_status'] = 'Healthy'; target['last_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            target['last_location'] = location
        except (ValueError, OSError, subprocess.SubprocessError) as exc:
            target['last_status'] = 'Failed: ' + str(exc)[:180]; target['last_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            save_backup_destinations(rows); audit_event(f'Remote backup destination {target["name"]} failed')
            raise
        save_backup_destinations(rows); audit_event(f'Tested remote backup destination {target["name"]}')
        self.redirect(f'Connection to {target["name"]} succeeded without uploading a file.', 'backups')

    def action(self, fields):
        action = fields.get('action', '')
        allowed = {'start', 'stop', 'restart'}
        if action in allowed:
            if action != 'stop' and not selected_name():
                raise ValueError('Upload and select a scenario first.')
            control_server(action)
            audit_event(f'{action.capitalize()} game server')
            self.redirect(f'Server {action} command completed.')
            return
        if action == 'backup':
            job_id = enqueue_job('full_backup', {'source': 'portal', 'actor': self.portal_user['username']})
            audit_event(f'Queued full server archive as job {job_id[:12]}')
            self.redirect('Full backup queued. Progress appears below.', 'backups')
            return
        raise ValueError('Unknown action.')

    def download_backup(self, filename):
        if not re.fullmatch(r'openrct2-[0-9]{8}T[0-9]{6}Z\.tar\.gz', filename):
            self.error_page(404, 'Backup not found.')
            return
        path = BACKUPS / filename
        if not path.is_file():
            self.error_page(404, 'Backup not found.')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/gzip')
        self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Length', str(path.stat().st_size))
        self.end_headers()
        with path.open('rb') as source:
            shutil.copyfileobj(source, self.wfile)

    def download_snapshot(self, filename):
        if not SNAPSHOT_NAME.fullmatch(filename):
            self.error_page(404, 'Snapshot not found.')
            return
        path = SAVES / filename
        if not path.is_file():
            self.error_page(404, 'Snapshot not found.')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Length', str(path.stat().st_size))
        self.end_headers()
        with path.open('rb') as source:
            shutil.copyfileobj(source, self.wfile)

    def download_quick_save(self, filename):
        if not QUICK_SAVE_NAME.fullmatch(filename):
            self.error_page(404, 'Quick save not found.')
            return
        path = SAVES / filename
        if not path.is_file():
            self.error_page(404, 'Quick save not found.')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Length', str(path.stat().st_size))
        self.end_headers()
        with path.open('rb') as source:
            shutil.copyfileobj(source, self.wfile)

    def download_save(self, filename):
        if not SAVE_FILE_NAME.fullmatch(filename):
            self.error_page(404, 'Saved game not found.'); return
        path = SAVES / filename
        if not path.is_file() or path.parent != SAVES:
            self.error_page(404, 'Saved game not found.'); return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
        self.send_header('Cache-Control', 'no-store'); self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Length', str(path.stat().st_size)); self.end_headers()
        with path.open('rb') as source: shutil.copyfileobj(source, self.wfile)

    def dashboard(self, message, tab='overview'):
        tabs = {'overview': 'Overview', 'parks': 'Scenarios', 'backups': 'Saved games',
                'players': 'Players & commands', 'groups': 'Groups & permissions',
                'users': 'Portal users', 'activity': 'Activity', 'settings': 'Server settings'}
        if tab not in tabs:
            tab = 'overview'
        active = service_active()
        selected = selected_name()
        scenarios = scenario_files()
        archived_scenarios = archived_scenario_files()
        backups = backup_files()
        destinations = backup_destinations()
        jobs = recent_jobs()
        users = visible_user_roles()
        config = settings()
        game = game_config()
        versions = version_status()
        blocked = set(config['blocked_hashes'])
        grants = command_grants()
        individual_permissions = player_permission_overrides()
        live_state = game_status() if tab in ('overview', 'players') else None
        live_players = live_state.get('details', []) if live_state else []
        player_groups = []
        if tab in ('players', 'groups') and active:
            try: player_groups = control_request('groups').get('groups', [])
            except ValueError: player_groups = []
        snapshots = snapshot_files()[:50]
        quick_saves = quick_save_files()[:100]
        saved_games = all_save_files()
        nonce = secrets.token_urlsafe(16)
        status = 'Running' if active else 'Stopped'
        status_class = 'running' if active else 'stopped'
        logo_url = '/logo.png' if LOGO_PNG.is_file() else '/logo.svg'
        notice = f'<div class="notice" role="status">{html.escape(message)}</div>' if message else ''
        nav = ''.join(
            f'<a href="/?tab={key}" {"aria-current=page" if key == tab else ""}>{icon(key)}<span>{label}</span></a>'
            for key, label in tabs.items() if key != 'groups'
        )
        token = f'<input type="hidden" name="csrf" value="{html.escape(getattr(self, "csrf_token", CSRF))}">' 
        library_options = ''.join(
            f'<option value="{html.escape(p.name)}" {"selected" if p.name == selected else ""}>'
            f'{html.escape(p.name)} · {human_size(p.stat().st_size)}</option>'
            for p in scenarios
        )
        quick_options = ''.join(
            f'<option value="quick:{html.escape(p.name)}">{html.escape(p.name)} · {human_size(p.stat().st_size)}</option>'
            for p in quick_saves
        )
        scenario_options = (f'<optgroup label="Uploaded parks">{library_options}</optgroup>' if library_options else '') + (
            f'<optgroup label="In-game quick saves">{quick_options}</optgroup>' if quick_options else '')
        scenario_options = scenario_options or '<option value="">Upload a park first</option>'
        park_rows = ''.join(
            f'<li><span>{html.escape(p.name)}</span><small>{human_size(p.stat().st_size)}</small></li>'
            for p in scenarios
        ) or '<li class="empty">Your library is empty. Upload parks below.</li>'
        scenario_cards = ''
        for path in scenarios:
            suffix = path.suffix.lower().removeprefix('.'); running = path.name == selected
            added = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).strftime('%-d %b %Y')
            scenario_cards += (f'<article class="scenario-card {"running" if running else ""}" data-format="{suffix}" data-search="{html.escape(path.name.lower())}">'
                               f'<div class="scenario-top"><span class="scenario-icon">{icon("parks")}</span><span class="pill {"good" if suffix == "park" else "neutral"}">{"Running" if running else "."+suffix}</span></div>'
                               f'<div><h3>{html.escape(path.name)}</h3><p>Added {added} · {human_size(path.stat().st_size)}</p></div><div class="scenario-foot"><span class="tiny muted">{"Modern format" if suffix == "park" else "Legacy format"}</span>'
                               f'<div class="row-actions"><form method="post" action="/select">{token}<input type="hidden" name="scenario" value="{html.escape(path.name)}"><button class="small {"secondary" if running else ""}" {"disabled" if running else ""}>{"Running" if running else "Launch"}</button></form>'
                               f'<form method="post" action="/scenario-archive">{token}<input type="hidden" name="scenario" value="{html.escape(path.name)}"><button class="small secondary" name="mode" value="archive" {"disabled" if running else ""}>Archive</button></form></div></div></article>')
        scenario_cards = scenario_cards or '<p class="empty">No scenarios uploaded yet.</p>'
        archived_rows = ''.join(
            f'<li><span>{html.escape(path.name)}</span><small>{human_size(path.stat().st_size)}</small><form method="post" action="/scenario-archive">{token}'
            f'<input type="hidden" name="scenario" value="{html.escape(path.name)}"><button class="secondary small" name="mode" value="restore">Restore</button></form></li>'
            for path in archived_scenarios) or '<li class="empty">No archived scenarios.</li>'
        archive_rows = ''.join(
            f'<li><span>{html.escape(p.name)}</span><small>{human_size(p.stat().st_size)}</small>'
            f'<a class="download" href="/backup/{urllib.parse.quote(p.name)}" download>{icon("download")} Download archive</a></li>'
            for p in backups
        ) or '<li class="empty">No full backups yet.</li>'
        destination_rows = ''.join(
            f'<tr><td><strong>{html.escape(row["name"])}</strong><small class="key">{html.escape(row["type"].upper())}</small></td>'
            f'<td>{html.escape(row["schedule"].replace("_", " ").title())}</td><td>{int(row.get("retention", 30))}</td><td>{html.escape(row.get("last_at") or "Never")}</td>'
            f'<td><span class="pill {"good" if row.get("last_status") == "Healthy" else "warn"}">{html.escape(row.get("last_status", "Not tested"))}</span></td>'
            f'<td><form method="post" action="/backup-destination" class="row-form">{token}<input type="hidden" name="id" value="{row["id"]}">'
            f'<button class="secondary small" name="mode" value="test">Test connection</button><button class="small" name="mode" value="backup">Back up now</button>'
            f'<button class="danger small" name="mode" value="delete">Remove</button></form></td></tr>'
            for row in destinations) or '<tr><td colspan="6" class="empty">No off-server destination configured yet.</td></tr>'
        job_rows = ''.join(
            f'<tr><td><code>{job["id"][:12]}</code></td><td>{html.escape(job["kind"].replace("_", " ").title())}</td>'
            f'<td><span class="pill {"good" if job["status"] == "complete" else "warn" if job["status"] in ("queued", "running") else "bad"}">{html.escape(job["status"].title())}</span></td>'
            f'<td>{job["attempts"]}</td><td>{html.escape(job["error"] or "—")}</td></tr>' for job in jobs
        ) or '<tr><td colspan="5" class="empty">No background backup jobs yet.</td></tr>'
        snapshot_rows = ''.join(
            f'<li><span>{html.escape(p.name)}</span><small>{human_size(p.stat().st_size)}</small>'
            f'<a class="download" href="/snapshot/{urllib.parse.quote(p.name)}" download>{icon("download")} Download park</a></li>'
            for p in snapshots
        ) or '<li class="empty">No live snapshots yet. The first one appears after the chosen interval while the game is active.</li>'
        quick_rows = ''.join(
            f'<li><span>{html.escape(p.name)}</span><small>{human_size(p.stat().st_size)}</small>'
            f'<a class="download" href="/quick-save/{urllib.parse.quote(p.name)}" download>{icon("download")} Download park</a></li>'
            for p in quick_saves
        ) or '<li class="empty">No quick saves yet. An administrator can type /save in game chat.</li>'
        recent_saves = saved_games[:5]
        recent_rows = ''
        for path in recent_saves:
            is_quick = bool(QUICK_SAVE_NAME.fullmatch(path.name)); is_snapshot = bool(SNAPSHOT_NAME.fullmatch(path.name))
            is_switch = path.name.startswith('pre-switch-'); is_restart = path.name.startswith('pre-restart-')
            title = ('Park-switch safety save' if is_switch else 'Restart safety save' if is_restart else
                     'Chat save' if is_quick else 'Automatic snapshot' if is_snapshot else 'OpenRCT2 autosave')
            detail = ('Created immediately before switching parks' if is_switch else 'Created immediately before restart' if is_restart else
                      'Created with /save' if is_quick else f'Scheduled every {config["snapshot_minutes"]} minutes' if is_snapshot else 'Created by OpenRCT2')
            when = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).strftime('%-d %b %Y, %H:%M UTC')
            recent_rows += (f'<div class="save-row"><div><div class="file-title">{title}</div><div class="file-meta"><span>{detail}</span><span>·</span>'
                            f'<span>{html.escape(path.name)}</span><span>·</span><span>{human_size(path.stat().st_size)}</span></div></div><time class="save-time">{when}</time>'
                            f'<div class="row-actions"><a class="button secondary small" href="/save/{urllib.parse.quote(path.name)}" download>{icon("download")} Download</a>'
                            f'<form method="post" action="/select">{token}<input type="hidden" name="scenario" value="save:{html.escape(path.name)}"><button class="small">{icon("play")} Resume</button></form></div></div>')
        recent_rows = recent_rows or '<p class="empty">No saved games yet.</p>'
        user_rows = ''
        for item in sorted(users, key=lambda item: (item.get('name', '').casefold(), item['hash'])):
            key_hash = item['hash'].lower()
            identity = html.escape(item.get('name', ''))
            player_override = individual_permissions.get(key_hash)
            role = player_override['base_group'] if player_override else item.get('groupId', 2)
            is_blocked = key_hash in blocked
            mode = 'unblock' if is_blocked else 'block'
            group_choices = [(int(group['id']), str(group['name'])) for group in player_groups if not str(group.get('name', '')).startswith('@manager/')]
            group_choices = group_choices or list(ROLES.items())
            choices = ''.join(f'<option value="{group_id}" {"selected" if role == group_id else ""}>{html.escape(name)}</option>'
                              for group_id, name in group_choices)
            live_player = next((player for player in live_players if player.get('public_key_hash') == key_hash), None)
            live_stats = ('<span class="pill good">Online · ' + html.escape(str(live_player.get('ping', '—'))) + ' ms</span>'
                          '<small class="key">' + html.escape(str(live_player.get('money_spent', '—'))) +
                          ' spent · ' + html.escape(str(live_player.get('last_action') or 'idle')) + '</small>') if live_player else '<span class="pill neutral">Offline</span>'
            command_controls = ''
            for command in ('save', 'backup', 'restart'):
                granted = command in grants.get(key_hash, []) or '*' in grants.get(key_hash, [])
                command_controls += (
                    f'<form method="post" action="/command-grant" class="mini-form">{token}'
                    f'<input type="hidden" name="hash" value="{key_hash}">'
                    f'<input type="hidden" name="command" value="{command}">'
                    f'<button class="{"light" if granted else "ghost"}" name="allowed" value="{"no" if granted else "yes"}">'
                    f'/{command} {"✓" if granted else "+"}</button></form>')
            override_count = len(player_override['allow']) + len(player_override['deny']) if player_override else 0
            permission_options = ''.join(
                f'<option value="{permission}">{html.escape(permission.removeprefix("PERMISSION_").replace("_", " ").title())}</option>'
                for permission in GROUP_PERMISSIONS)
            override_summary = 'None' if not override_count else f'{override_count} exception' + ('s' if override_count != 1 else '')
            override_details = ''.join(
                f'<li><span>{html.escape(permission.removeprefix("PERMISSION_").replace("_", " ").title())}</span><strong>{mode.title()}</strong></li>'
                for mode, values in (('allow', player_override['allow'] if player_override else []),
                                     ('deny', player_override['deny'] if player_override else []))
                for permission in values) or '<li class="empty">Everything currently inherits from the base group.</li>'
            override_controls = (
                f'<details class="override-editor"><summary class="button secondary small">Overrides '
                f'<span class="pill {"warn" if override_count else "neutral"}">{override_summary}</span></summary>'
                f'<div class="override-popover"><ul class="override-current">{override_details}</ul>'
                f'<form method="post" action="/player-permission" class="override-form">{token}'
                f'<input type="hidden" name="hash" value="{key_hash}"><label>Permission</label>'
                f'<select name="permission">{permission_options}</select><label>Rule</label><select name="override">'
                f'<option value="inherit">Inherit from group</option><option value="allow">Allow for this player</option>'
                f'<option value="deny">Deny for this player</option></select><button class="small">Apply live</button></form></div></details>')
            kick_control = (f'<form method="post" action="/kick" class="mini-form">{token}<input type="hidden" name="hash" value="{key_hash}">'
                            f'<button class="secondary small">Kick</button></form>') if live_player else ''
            user_rows += (
                f'<tr><td><strong>{identity}</strong><small class="key">Key {key_hash[:12]}…</small></td>'
                f'<td>{live_stats}</td><td><span class="tag {"bad" if is_blocked else "good"}">{"Blocked" if is_blocked else "Allowed"}</span></td>'
                f'<td><form method="post" action="/permissions" class="row-form">{token}'
                f'<input type="hidden" name="hash" value="{key_hash}">'
                f'<select name="role" aria-label="Role for {identity}">{choices}</select><button>Save</button></form></td>'
                f'<td>{override_controls}</td>'
                f'<td><div class="command-grid">{command_controls}</div></td>'
                f'<td><div class="command-grid">{kick_control}<form method="post" action="/block" class="row-form">{token}'
                f'<input type="hidden" name="hash" value="{key_hash}">'
                f'<button class="{"light" if is_blocked else "danger"}" name="mode" value="{mode}">'
                f'{"Unblock" if is_blocked else "Block"}</button></form></div></td></tr>'
            )
        user_rows = user_rows or '<tr><td colspan="7" class="empty">No one recorded yet. Ask a player to join once, then refresh this page.</td></tr>'
        pending_requests = [item for item in permission_requests() if isinstance(item, dict) and item.get('status') == 'pending']
        pending_rows = ''.join(
            f'<div class="save-row request-row"><div><div class="file-title">{html.escape(str(item.get("player_name", "Player")))} requests '
            f'{html.escape(str(item.get("permission_name", "permission")).replace("-", " ").title())}</div><div class="file-meta">Key '
            f'{html.escape(str(item.get("public_key_hash", ""))[:12])}… · {html.escape(str(item.get("received_at", "")))}</div></div>'
            f'<div class="row-actions"><form method="post" action="/permission-request">{token}<input type="hidden" name="event_id" value="{html.escape(str(item.get("event_id", "")))}">'
            f'<button class="secondary small" name="decision" value="reject">Reject</button><button class="small" name="decision" value="approve">Approve</button></form></div></div>'
            for item in pending_requests) or '<p class="empty">No pending permission requests.</p>'

        dock_feed = html.escape(activity_text('dock'))
        live = live_state if tab == 'overview' else None
        connected_count = str(live['players']) if live and live['players'] is not None else '—'
        verified_auto_paused = bool(live and live.get('auto_paused'))
        session_state = 'Auto-paused' if verified_auto_paused else ('Paused' if live and live.get('paused') else status)
        session_state_class = 'warn' if verified_auto_paused else ('neutral' if live and live.get('paused') else 'good')
        join_host = game['advertise_address'] or MANAGER_DOMAIN
        join_address = f'{join_host}:{game["port"]}' if join_host else 'Public address not configured'
        discovery_label = 'Listed' if game['advertise'] else 'Private'
        discovery_class = 'good' if game['advertise'] else 'neutral'
        overview = f'''
<div class="heading"><div><h1>Good evening, {html.escape(self.portal_user["display_name"].split()[0])}</h1><p>Your server is {status.lower()} with <span id="online-count">{connected_count}</span> player(s) connected.</p></div>
<div class="heading-actions"><a class="button secondary" href="/?tab=activity">{icon('message')} Message players</a><a class="button" href="/?tab=parks">{icon('parks')} Change scenario</a></div></div>
<div class="grid four overview-stats"><article class="card stat"><div class="stat-label"><span>SERVER</span><span class="pill {session_state_class}" id="server-mode">{session_state}</span></div><strong>{connected_count} players</strong><small id="server-pause-detail">{'Verified paused with nobody online' if verified_auto_paused else 'of ' + str(game['max_players']) + ' slots'}</small></article>
<article class="card stat"><div class="stat-label">CURRENT PARK</div><strong>{html.escape(Path(selected).stem) if selected else 'No park selected'}</strong><small>{html.escape(selected) if selected else 'Choose a scenario'}</small></article>
<article class="card stat"><div class="stat-label">AUTO SAVE</div><strong>{config['snapshot_minutes']} min</strong><small>{'Enabled' if config['snapshot_minutes'] else 'Disabled'}</small></article>
<article class="card stat"><div class="stat-label"><span>DISCOVERY</span><span class="pill {discovery_class}">{discovery_label}</span></div><strong>{'Public browser' if game['advertise'] else 'Direct connection'}</strong><small>{html.escape(join_address)}</small></article></div>
<div class="overview-layout"><div class="overview-main">
<section class="card"><div class="card-head"><div><h2>Join this server</h2><p class="muted">Share this address with players who are not using the server browser.</p></div></div><div class="join-box"><span><strong class="join-address">{html.escape(join_address)}</strong><small>OpenRCT2 multiplayer address</small></span>{f'<button type="button" class="secondary small" id="copy-address" data-address="{html.escape(join_address)}">Copy</button>' if join_host else ''}</div></section>
<section class="card"><div class="card-head"><div><h2>{icon('parks')} Current session</h2><p>{html.escape(selected) if selected else 'No scenario selected'}</p></div><span class="pill {session_state_class}" id="session-state">{session_state}</span></div><div class="current-park"><h3>{html.escape(Path(selected).stem) if selected else 'No park selected'}</h3><p id="session-pause-detail">{connected_count} player(s) connected · {'verified auto-paused' if verified_auto_paused else ('pause when empty enabled' if game['pause_when_empty'] else 'pause when empty disabled')}</p></div>
<form method="post" action="/action">{token}<div class="server-actions"><button name="action" value="restart" class="secondary">{icon('refresh')} Restart</button><button name="action" value="stop" class="danger">{icon('stop')} Stop server</button></div></form></section>
<section class="card"><div class="card-head"><div><h2>Last five saves</h2><p>Your most recent recoverable copies, newest first.</p></div><a class="button secondary small" href="/?tab=backups">View all</a></div><div class="save-list">{recent_rows}</div></section>
</div><section class="card overview-console console-card"><div class="card-head"><div><h2>Live server console</h2><p>Events and game chat · updates automatically</p></div><span class="pill good">Live</span></div>
<pre id="overview-feed" class="console" aria-live="off">{dock_feed}</pre><form class="chat-form" method="post" action="/chat">{token}<input type="hidden" name="return_tab" value="overview"><input name="message" maxlength="180" placeholder="Send a message to everyone…" required><button aria-label="Send">{icon('message')}</button></form></section></div>'''

        parks = f'''
<div class="page-heading"><p class="eyebrow">SCENARIO DATABASE</p><h1>Upload once, start at a moment's notice</h1>
<p>Search your uploaded scenarios and launch one when the group is ready.</p></div>
<section class="card"><div class="card-head"><div><h2>OpenRCT2 {html.escape(versions['installed'])} is installed</h2><p class="muted">Latest known stable: {html.escape(versions['latest'] or 'not checked yet')}.</p></div>
<form method="post" action="/version-check">{token}<input type="hidden" name="return_tab" value="parks"><button class="secondary small">Check official release</button></form></div></section>
<section class="card"><div class="card-head"><div><h2>{len(scenarios)} scenarios</h2><p class="muted">The running scenario is highlighted. Launching another disconnects current players.</p></div></div>
<div class="toolbar"><input id="scenario-search" type="search" placeholder="Search scenarios…"><select id="scenario-format" style="width:auto"><option value="all">All formats</option><option value="park">.park</option><option value="sc6">.sc6</option><option value="sv6">.sv6</option><option value="sc4">.sc4</option><option value="sv4">.sv4</option></select></div>
<div class="divider"></div><div class="database" id="scenario-database">{scenario_cards}</div>
<p class="fine warning">Switching restarts the game. The current live park is preserved by the automatic save schedule.</p></section>
<section class="card"><h2>Upload parks</h2><p class="muted">Add several files at once without interrupting the current game.</p>
<form method="post" action="/upload" enctype="multipart/form-data">{token}
<label for="files">Choose .park, .sv6, .sv4, .sc6 or .sc4 files</label><input id="files" type="file" name="files" accept=".park,.sv6,.sv4,.sc6,.sc4" multiple required>
<label class="check"><input type="checkbox" name="overwrite" value="yes"> Replace files with matching names</label>
<div class="actions"><button>{icon('parks')} Upload files</button></div></form>
<p class="fine">Combined upload limit: {MAX_UPLOAD // 1024 // 1024} MB. Uploading does not launch a park.</p></section>
<section class="card"><h2>Archived scenarios</h2><p class="muted">Archiving is recoverable and never removes the currently running park.</p><ul class="file-list">{archived_rows}</ul></section>'''

        players = f'''
<div class="page-heading"><p class="eyebrow">PLAYER ACCESS</p><h1>Know who can do what</h1>
<p>OpenRCT2 identifies a player by their key, not the name they type. A player's key stays here after they leave.</p></div>
<div class="tabs"><a class="button secondary small" href="/?tab=players">Players &amp; commands</a><a class="button secondary small" href="/?tab=groups">Groups &amp; permissions</a></div>
<section class="card"><div class="card-head"><div><h2>In-game commands</h2><p class="muted">Commands are intercepted by the manager and do not appear in public chat.</p></div><span class="pill good">8 available</span></div>
<div class="command"><code>/help</code><p>Shows commands available to the player.</p><span class="pill good">Everyone</span></div><div class="command"><code>/motd</code><p>Replays the message of the day.</p><span class="pill good">Everyone</span></div>
<div class="command"><code>/status</code><p>Shows server and player status.</p><span class="pill good">Everyone</span></div><div class="command"><code>/request</code><p>Requests a named permission for approval.</p><span class="pill good">Everyone</span></div>
<div class="command"><code>/save [label]</code><p>Creates a timestamped park copy live.</p><span class="pill warn">Grantable</span></div><div class="command"><code>/backup</code><p>Creates a full manager archive.</p><span class="pill warn">Grantable</span></div>
<div class="command"><code>/restart</code><p>Saves, then restarts the game daemon.</p><span class="pill warn">Grantable</span></div></section>
<section class="card"><div class="card-head"><div><h2>Permission requests</h2><p class="muted">Requests never grant access until an administrator decides.</p></div><span class="pill {"warn" if pending_requests else "neutral"}">{len(pending_requests)} pending</span></div>{pending_rows}</section>
<section class="card"><h2>Roles and blocking</h2>
<div class="explain-grid"><p><strong>Administrator</strong><br>Full park and server control.</p>
<p><strong>Player</strong><br>Can play and build.</p><p><strong>Spectator</strong><br>Can watch without building.</p></div>
<p class="fine">Role and block changes apply live without restarting. Saved keys retain their roles and command grants after leaving.</p>
<p class="fine">Grant <code>/save</code>, <code>/backup</code>, or <code>/restart</code> separately. Administrators retain these commands by default.</p>
<div class="table-wrap"><table><thead><tr><th>Player</th><th>Live stats</th><th>Access</th><th>Base group</th><th>Individual permissions</th><th>Chat commands</th><th>Action</th></tr></thead><tbody>{user_rows}</tbody></table></div></section>
<section class="card"><h2>Which player should I choose?</h2>
<p class="muted">Names can repeat or change. Compare the short key shown under each name. If someone is missing, ask them to join once and refresh this tab.</p></section>'''

        all_save_rows = ''
        for path in saved_games:
            safety = path.name.startswith(('pre-switch-', 'pre-restart-'))
            save_type = 'automatic' if safety else ('chat' if QUICK_SAVE_NAME.fullmatch(path.name) else ('automatic' if SNAPSHOT_NAME.fullmatch(path.name) else 'openrct2'))
            title = ('Park-switch safety save' if path.name.startswith('pre-switch-') else
                     'Restart safety save' if path.name.startswith('pre-restart-') else
                     {'chat': 'Chat save', 'automatic': 'Automatic snapshot', 'openrct2': 'OpenRCT2 autosave'}[save_type])
            when = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            all_save_rows += (f'<div class="save-row filter-save" data-type="{save_type}" data-search="{html.escape((title+" "+path.name).lower())}">'
                              f'<div><div class="file-title">{title}</div><div class="file-meta"><span>{html.escape(path.name)}</span><span>·</span><span>{human_size(path.stat().st_size)}</span></div></div>'
                              f'<time class="save-time" datetime="{when}">{datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).strftime("%-d %b %Y, %H:%M UTC")}</time><div class="row-actions">'
                              f'<a class="button secondary small" href="/save/{urllib.parse.quote(path.name)}" download>{icon("download")} Download</a>'
                              f'<form method="post" action="/select">{token}<input type="hidden" name="scenario" value="save:{html.escape(path.name)}"><button class="small">{icon("play")} Resume</button></form></div></div>')
        all_save_rows = all_save_rows or '<p class="empty">No saved games yet.</p>'

        groups_page = ''
        if tab == 'groups':
            group_state = control_request('groups') if active else {'default_group': None, 'groups': []}
            default_group = group_state.get('default_group')
            group_cards = ''
            for group in group_state.get('groups', []):
                if str(group.get('name', '')).startswith('@manager/'): continue
                group_id = int(group.get('id')); group_name = str(group.get('name', ''))
                enabled = set(group.get('permissions', []))
                permission_rows = ''
                for permission in GROUP_PERMISSIONS:
                    label = permission.removeprefix('PERMISSION_').replace('_', ' ').title()
                    if permission == 'PERMISSION_TOGGLE_SCENERY_CLUSTER':
                        label = 'Multiple scenery brush (cluster tool)'
                    checked = permission in enabled or group_id == 0
                    permission_rows += (
                        f'<form method="post" action="/group-action" class="permission-row">{token}'
                        f'<input type="hidden" name="mode" value="permission"><input type="hidden" name="group" value="{group_id}">'
                        f'<input type="hidden" name="permission" value="{permission}">'
                        f'<span>{html.escape(label)}</span><button class="{"light" if checked else "ghost"}" '
                        f'name="allowed" value="{"no" if checked else "yes"}" {"disabled" if group_id == 0 else ""}>'
                        f'{"On" if checked else "Off"}</button></form>')
                manage = '' if group_id == 0 else (
                    f'<form method="post" action="/group-action" class="row-form">{token}<input type="hidden" name="mode" value="rename">'
                    f'<input type="hidden" name="group" value="{group_id}"><input name="name" maxlength="32" value="{html.escape(group_name)}" required><button>Rename</button></form>'
                    f'<form method="post" action="/group-action" class="row-form">{token}<input type="hidden" name="group" value="{group_id}">'
                    f'<button class="danger" name="mode" value="delete">Delete group</button></form>')
                default_action = '<span class="tag good">Default group</span>' if group_id == default_group else (
                    f'<form method="post" action="/group-action">{token}<input type="hidden" name="group" value="{group_id}">'
                    f'<button class="light" name="mode" value="default">Make default</button></form>')
                group_cards += (f'<details class="card group-card" {"open" if group_id == default_group else ""}>'
                                f'<summary><span><strong>{html.escape(group_name)}</strong><small> Group {group_id}</small></span>{default_action}</summary>'
                                f'<div class="group-tools">{manage}</div><div class="permission-list">{permission_rows}</div></details>')
            request_rows = ''.join(
                f'<li><span><strong>{html.escape(str(item.get("player_name", "Player")))}</strong> requested '
                f'{html.escape(str(item.get("permission_name", "permission")))}<small class="key">Key {html.escape(str(item.get("public_key_hash", ""))[:12])}… · '
                f'{html.escape(str(item.get("received_at", "")))}</small></span><span class="tag">{html.escape(str(item.get("status", "pending")))}</span></li>'
                for item in reversed(permission_requests()[-20:]) if isinstance(item, dict)) or '<li class="empty">No permission requests yet.</li>'
            groups_page = f'''
<div class="page-heading"><p class="eyebrow">IN-GAME PERMISSIONS</p><h1>Groups and capabilities</h1>
<p>Changes use OpenRCT2's live network API and take effect immediately without restarting the game.</p></div>
<section class="card"><h2>Create a group</h2><form method="post" action="/group-action">{token}<input type="hidden" name="mode" value="create">
<div class="fields"><div><label for="group-name">Group name</label><input id="group-name" name="name" maxlength="32" placeholder="Moderator" required></div></div>
<div class="actions"><button>Create group</button></div></form></section>
<section><h2>Permission groups</h2><p class="muted">Open a group to toggle individual permissions, including the multiple-scenery brush.</p>{group_cards}</section>
<section class="card"><h2>Requests from game chat</h2><p class="muted">Players can type <code>/request scenery-brush</code> or another whitelisted permission.</p>
<ul class="file-list">{request_rows}</ul></section>'''

        portal_rows = ''
        for portal in portal_users():
            role_options = ''.join(f'<option value="{role}" {"selected" if portal["role"] == role else ""}>{role.title()}</option>'
                                   for role in PORTAL_ROLES)
            initials = ''.join(part[:1] for part in portal['display_name'].split()[:2]).upper() or 'U'
            portal_rows += (f'<tr><td><div class="identity"><span class="avatar">{html.escape(initials)}</span><span><strong>{html.escape(portal["display_name"])}</strong>'
                            f'<small>@{html.escape(portal["username"])}</small></span></div></td><td>'
                            f'<form method="post" action="/portal-user" class="row-form">{token}<input type="hidden" name="mode" value="update">'
                            f'<input type="hidden" name="id" value="{portal["id"]}"><select name="role">{role_options}</select>'
                            f'<label class="switch"><input type="checkbox" name="active" value="yes" {"checked" if portal["active"] else ""}><span class="switch-track"></span><span>Active</span></label>'
                            f'<button>Save</button></form></td><td><form method="post" action="/portal-user" class="row-form">{token}'
                            f'<input type="hidden" name="id" value="{portal["id"]}"><input type="password" name="password" minlength="12" placeholder="New password" required>'
                            f'<button class="light" name="mode" value="password">Reset</button></form><form method="post" action="/portal-user" class="mini-form">{token}'
                            f'<input type="hidden" name="id" value="{portal["id"]}"><button class="danger" name="mode" value="delete">Delete</button></form></td></tr>')
        users_page = f'''
<div class="page-heading"><p class="eyebrow">PORTAL ACCESS</p><h1>Portal users</h1><p>Separate web accounts with server-enforced roles. Only Owners can manage this page.</p></div>
<section class="card"><div class="card-head"><div><h2>Access matrix</h2><p class="muted">Portal roles control the web manager only; in-game groups are managed separately.</p></div></div>
<div class="table-wrap"><table class="access-matrix"><thead><tr><th>Capability</th><th>Owner</th><th>Administrator</th><th>Operator</th><th>Viewer</th></tr></thead><tbody>
<tr><td>View status, saves and activity</td><td>✓</td><td>✓</td><td>✓</td><td>✓</td></tr>
<tr><td>Start, stop, message and switch parks</td><td>✓</td><td>✓</td><td>✓</td><td>—</td></tr>
<tr><td>Manage players, groups and backups</td><td>✓</td><td>✓</td><td>—</td><td>—</td></tr>
<tr><td>Server settings</td><td>✓</td><td>✓</td><td>—</td><td>—</td></tr>
<tr><td>Manage portal users</td><td>✓</td><td>—</td><td>—</td><td>—</td></tr></tbody></table></div></section>
<section class="card"><div class="card-head"><div><h2>Add a portal user</h2><p class="muted">Passwords are stored with PBKDF2-SHA256, never as plaintext.</p></div></div>
<form method="post" action="/portal-user">{token}<input type="hidden" name="mode" value="create"><div class="form-grid">
<div><label>Display name</label><input name="display_name" maxlength="100" required></div><div><label>Username</label><input name="username" pattern="[a-z0-9][a-z0-9_.-]*" required></div>
<div><label>Role</label><select name="role"><option value="operator">Operator</option><option value="administrator">Administrator</option><option value="viewer">Viewer</option><option value="owner">Owner</option></select></div>
<div><label>Temporary password</label><input type="password" name="password" minlength="12" required></div></div><div class="actions"><button>Create user</button></div></form></section>
<section class="card"><h2>People with portal access</h2><div class="table-wrap"><table><thead><tr><th>User</th><th>Access</th><th>Password / removal</th></tr></thead><tbody>{portal_rows}</tbody></table></div></section>'''

        backups_page = f'''
<div class="page-heading"><p class="eyebrow">SAVED GAMES</p><h1>Every recoverable park copy</h1>
<p>Search, download, or resume chat saves, automatic snapshots, and OpenRCT2 autosaves.</p></div>
<div class="grid three save-metrics"><article class="card stat"><div class="stat-label">SAVED GAMES</div><strong>{len(saved_games)}</strong><small>{human_size(sum(path.stat().st_size for path in saved_games))} total</small></article>
<article class="card stat"><div class="stat-label">AUTO SAVE</div><strong>Every {config['snapshot_minutes']} min</strong><small>Keeping {config['snapshot_keep']} copies</small></article>
<article class="card stat"><div class="stat-label">LATEST SAVE</div><strong>{datetime.fromtimestamp(saved_games[0].stat().st_mtime, timezone.utc).strftime('%-d %b, %H:%M') if saved_games else 'None'}</strong><small>{html.escape(saved_games[0].name) if saved_games else 'No saved games'}</small></article></div>
<section class="card"><div class="card-head"><div><h2>Save library</h2><p class="muted">Timestamps are UTC; original filenames are retained.</p></div></div>
<div class="tabs save-filters"><button type="button" class="active" data-save-filter="all">All saves</button><button type="button" data-save-filter="chat">Chat saves</button><button type="button" data-save-filter="automatic">Automatic</button><button type="button" data-save-filter="openrct2">OpenRCT2 autosaves</button></div>
<div class="toolbar"><input id="save-search" type="search" placeholder="Search saved games…"></div><div class="divider"></div><div class="save-list" id="all-saves">{all_save_rows}</div></section>
<section class="card"><h2>Automatic live snapshots</h2><p class="muted">The game saves a .park copy at the interval below while the park is active. If the game is paused, the copy is made when play resumes. Only manager-made snapshots count toward retention.</p>
<form method="post" action="/snapshot-settings">{token}<div class="fields">
<div><label for="minutes">Every how many minutes?</label><input id="minutes" type="number" name="minutes" min="0" max="1440" value="{config['snapshot_minutes']}" required>
<small>Use 0 to turn this off.</small></div>
<div><label for="keep">Number of snapshots to keep</label><input id="keep" type="number" name="keep" min="1" max="500" value="{config['snapshot_keep']}" required></div></div>
<div class="actions"><button>{icon('backups')} Save schedule</button></div></form>
<p class="fine">Schedule changes apply live without a restart. Snapshots stay on the server until you download them.</p>
<p class="fine">The unified library above includes these snapshots and all chat saves.</p></section>
<section class="card"><h2>Full server archive</h2>
<p class="muted">Includes uploaded parks, existing saves, OpenRCT2 user data and the manager selection/settings. A full archive briefly stops and restarts the game.</p>
<form method="post" action="/action">{token}<div class="actions"><button name="action" value="backup">{icon('backups')} Create full backup</button></div></form>
<h3>Archives ready to download</h3><ul class="file-list">{archive_rows}</ul>
<p class="fine">Download a copy to your computer and store another somewhere independent of this server. A server-only backup is not disaster recovery.</p></section>
<section class="card"><div class="card-head"><div><h2>Off-server backups</h2><p class="muted">Copy immutable full archives to infrastructure independent of this Lightsail instance.</p></div></div>
<div class="table-wrap"><table><thead><tr><th>Destination</th><th>Schedule</th><th>Keep</th><th>Last backup</th><th>Status</th><th>Actions</th></tr></thead><tbody>{destination_rows}</tbody></table></div>
<details class="destination-editor"><summary class="button secondary">Add destination</summary><form method="post" action="/backup-destination">{token}<input type="hidden" name="mode" value="create"><div class="form-grid">
<div><label>Name</label><input name="name" maxlength="64" placeholder="Home NAS" required></div><div><label>Type</label><select name="type"><option value="sftp">SFTP / SSH</option><option value="s3">AWS S3 / compatible</option><option value="rclone">Configured rclone remote</option></select></div>
<div><label>Schedule</label><select name="schedule"><option value="manual">Manual only</option><option value="after_backup">After every full backup</option><option value="daily">Every 24 hours</option><option value="weekly">Every 7 days</option></select></div><div><label>Remote archives to keep</label><input type="number" name="retention" min="1" max="1000" value="30"></div>
<div><label>SFTP host</label><input name="host" placeholder="nas.example.com"></div><div><label>SFTP port</label><input type="number" name="port" value="22" min="1" max="65535"></div>
<div><label>SFTP username</label><input name="username" placeholder="backup"></div><div><label>SFTP key filename</label><input name="identity" placeholder="backup_ed25519"><small class="help">Read from /etc/openrct2-manager/keys</small></div>
<div><label>S3 bucket</label><input name="bucket" placeholder="my-park-backups"></div><div><label>S3 prefix</label><input name="prefix" value="openrct2"></div>
<div><label>rclone remote</label><input name="remote" placeholder="b2"></div><div><label>Remote path</label><input name="remote_path" placeholder="/openrct2 or parks/openrct2"></div></div>
<div class="actions"><button>Add destination</button></div></form></details>
<p class="fine">SFTP enforces strict host keys. S3 uses the instance role or the AWS CLI's protected configuration; rclone uses an existing server-side remote. No cloud secret is stored in the portal database.</p></section>
<section class="card"><div class="card-head"><div><h2>Background jobs</h2><p class="muted">Archive and transfer work survives manager restarts and retries with exponential backoff.</p></div></div>
<div class="table-wrap"><table><thead><tr><th>Job</th><th>Type</th><th>Status</th><th>Attempts</th><th>Last error</th></tr></thead><tbody>{job_rows}</tbody></table></div></section>'''

        view = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get('view', ['chat'])[0]
        if view not in ('chat', 'console'):
            view = 'chat'
        feed = html.escape(activity_text(view)) if tab == 'activity' else ''
        activity = f'''
<div class="page-heading"><p class="eyebrow">LIVE ACTIVITY</p><h1>What is happening now</h1>
<p>Searchable server events, player chat, and portal actions refresh every five seconds.</p></div>
<section class="card"><h2>Send a message to players</h2>
<p class="muted">This posts a server announcement to everyone currently online. It does not run a console command.</p>
<form method="post" action="/chat">{token}<label for="chat-message">Message</label>
<input id="chat-message" name="message" maxlength="180" placeholder="Game night starts in five minutes…" required>
<div class="actions"><button>{icon('message')} Send to game chat</button></div></form></section>
<section class="card"><div class="card-head"><h2>Live feed</h2><div class="segmented">
<a href="/?tab=activity&amp;view=chat" {"aria-current=page" if view == 'chat' else ""}>Chat</a>
<a href="/?tab=activity&amp;view=console" {"aria-current=page" if view == 'console' else ""}>Server log</a></div></div>
<div class="toolbar"><input id="activity-search" type="search" placeholder="Search activity…"><a class="button secondary small" href="/activity-export.txt" download>{icon('download')} Export log</a></div>
<p class="fine">The server log is read-only. Arbitrary commands are deliberately not exposed in the web panel.</p>
<pre id="activity-feed" aria-live="polite">{feed}</pre></section>'''

        if MANAGER_DOMAIN:
            protection = ('HTTPS is configured for ' + html.escape(MANAGER_DOMAIN) +
                          '. Keep port ' + html.escape(str(PORT)) + ' closed to the public.')
        elif WEB_BIND == '127.0.0.1':
            protection = ('This panel listens on this server only. Use an SSH tunnel to reach port ' +
                          html.escape(str(PORT)) + ', or configure MANAGER_DOMAIN for HTTPS.')
        else:
            protection = ('HTTPS is not configured. Restrict web port ' + html.escape(str(PORT)) +
                          ' to your own IP immediately. Never open it to everyone.')
        settings_page = f'''
<div class="page-heading"><p class="eyebrow">SERVER CONFIGURATION</p><h1>Server settings</h1>
<p>Core OpenRCT2 multiplayer settings. Saving this section restarts the game server.</p></div>
<section class="card"><div class="card-head"><div><h2>Identity and discovery</h2><p class="muted">These details appear in the OpenRCT2 public server browser.</p></div><span class="pill good">IPv4 configured</span></div>
<form method="post" action="/server-settings">{token}<div class="form-grid">
<div><label>Server name</label><input name="server_name" maxlength="64" value="{html.escape(game['server_name'])}" required></div>
<div><label>Maximum players</label><input type="number" name="max_players" min="1" max="255" value="{game['max_players']}" required></div>
<div class="span-2"><label>Description</label><input name="server_description" maxlength="256" value="{html.escape(game['server_description'])}"></div>
<div class="span-2"><label>Greeting</label><input name="server_greeting" maxlength="256" value="{html.escape(game['server_greeting'])}"></div>
<div><label>Game port</label><input type="number" name="port" min="1" max="65535" value="{game['port']}" required></div>
<div><label>Advertise address</label><input name="advertise_address" value="{html.escape(game['advertise_address'])}" placeholder="203.0.113.10"></div>
<div><label>OpenRCT2 autosave interval</label><select name="autosave">{''.join(f'<option value="{value}" {"selected" if game["autosave"] == value else ""}>{value}</option>' for value in range(6))}</select></div>
<div><label>Autosaves to retain</label><input type="number" name="autosave_amount" min="1" max="1000" value="{game['autosave_amount']}" required></div>
<div><label class="switch"><input type="checkbox" name="advertise" value="yes" {"checked" if game['advertise'] else ""}><span class="switch-track"></span><span>List in public server browser</span></label></div>
<div><label class="switch"><input type="checkbox" name="pause_when_empty" value="yes" {"checked" if game['pause_when_empty'] else ""}><span class="switch-track"></span><span>Pause when empty</span></label></div>
<div><label>New game password</label><input type="password" name="game_password" maxlength="128" placeholder="Leave blank to keep current"><small class="help">Current password: {"set" if game['has_password'] else "not set"}</small></div>
<div><label>Confirm new password</label><input type="password" name="game_password_confirm" maxlength="128" placeholder="Repeat the new password"></div>
<div><label class="switch"><input type="checkbox" name="remove_password" value="yes"><span class="switch-track"></span><span>Remove game password</span></label></div>
</div><div class="actions"><button>Save &amp; restart server</button></div></form></section>
<section class="card"><h2>Message of the day</h2><p class="muted">Shown privately when a player joins and whenever they type <code>/motd</code>. Up to five lines.</p>
<form method="post" action="/motd">{token}<label for="motd">MOTD lines</label>
<textarea id="motd" name="motd" rows="5" maxlength="904" placeholder="Welcome to the park!">{html.escape(chr(10).join(motd_lines()))}</textarea>
<div class="actions"><button>Save MOTD</button></div></form></section>
<section class="card"><div class="card-head"><div><h2>Software version</h2><p class="muted">Checked against the official OpenRCT2 GitHub releases feed.</p></div><span class="pill {"good" if versions['latest'] == versions['installed'] else "warn"}">{"Up to date" if versions['latest'] == versions['installed'] else "Check recommended"}</span></div>
<div class="join-box"><span><strong>OpenRCT2 {html.escape(versions['installed'])}</strong><small>Latest stable: {html.escape(versions['latest'] or 'not checked')} · last check {html.escape(versions['checked_at'] or 'never')}</small></span>
<form method="post" action="/version-check">{token}<input type="hidden" name="return_tab" value="settings"><button class="secondary small">Check now</button></form></div></section>
<section class="card"><h2>Connection and security</h2><p>{protection}</p>
<p class="muted">Game address: <strong>{html.escape(join_address)}</strong>. The control and callback bridges are local-only on ports {CONTROL_PORT} and {CALLBACK_PORT}.</p>
<p class="fine">The web panel uses a password. Keep it private and use HTTPS for access over the internet.</p></section>
<section class="card"><h2>Where data is stored</h2><dl class="facts">
<dt>Parks</dt><dd><code>/var/lib/openrct2/scenarios</code></dd>
<dt>Saved games</dt><dd><code>/var/lib/openrct2/user-data/save</code></dd>
<dt>Player identities</dt><dd><code>/var/lib/openrct2/user-data/users.json</code></dd>
<dt>Full archives</dt><dd><code>/var/lib/openrct2/backups</code></dd></dl>
<p class="fine">Keep copies off the server. Download files from the Backups tab.</p></section>
<section class="card"><h2>Need to troubleshoot?</h2>
<p class="muted">If a park will not start, check that it uses a compatible OpenRCT2 version and all required objects are installed.</p>
<p class="fine">On the server, inspect recent events with <code>sudo journalctl -u openrct2 -n 100</code>. The Activity tab also shows a read-only log.</p></section>'''

        content = {'overview': overview, 'parks': parks, 'players': players, 'groups': groups_page, 'users': users_page,
                   'backups': backups_page, 'activity': activity, 'settings': settings_page}[tab]
        activity_poll = ''
        if tab == 'activity':
            activity_poll = f'''const feed = document.getElementById("activity-feed");
const activitySearch = document.getElementById("activity-search");
let activityRaw = feed.textContent;
function renderActivity() {{
  const query = activitySearch.value.toLowerCase();
  feed.textContent = activityRaw.split("\\n").filter(line => !query || line.toLowerCase().includes(query)).join("\\n") || "No matching activity.";
}}
activitySearch.addEventListener("input", renderActivity);
async function refreshFeed() {{
  try {{
    const response = await fetch("/activity.txt?mode={view}", {{cache:"no-store"}});
    if (response.ok) {{ activityRaw = await response.text(); renderActivity(); }}
  }} catch (error) {{}}
}}
setInterval(refreshFeed, 5000);'''
        script = f'''<script nonce="{nonce}">
const dock = document.getElementById("console-dock");
const dockFeed = document.getElementById("dock-feed");
const overviewFeed = document.getElementById("overview-feed");
const onlineCount = document.getElementById("online-count");
const onlineDetail = document.getElementById("online-detail");
const serverMode = document.getElementById("server-mode");
const serverPauseDetail = document.getElementById("server-pause-detail");
const sessionState = document.getElementById("session-state");
const sessionPauseDetail = document.getElementById("session-pause-detail");
const themeToggle = document.getElementById("theme-toggle");
function syncThemeButton() {{
  if (!themeToggle) return;
  const dark = document.documentElement.dataset.theme === "dark";
  themeToggle.querySelector("span").textContent = dark ? "Light mode" : "Dark mode";
  themeToggle.setAttribute("aria-pressed", dark ? "true" : "false");
}}
syncThemeButton();
if (themeToggle) themeToggle.addEventListener("click", () => {{
  const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  try {{ localStorage.setItem("openrct2-theme", next); }} catch (error) {{}}
  syncThemeButton();
}});
const copyAddress = document.getElementById("copy-address");
if (copyAddress) copyAddress.addEventListener("click", async () => {{
  try {{ await navigator.clipboard.writeText(copyAddress.dataset.address); copyAddress.textContent = "Copied"; }} catch (error) {{}}
}});
const saveSearch = document.getElementById("save-search");
let saveFilter = "all";
function filterSaves() {{
  if (!saveSearch) return;
  const query = saveSearch.value.toLowerCase();
  document.querySelectorAll(".filter-save").forEach(row => {{
    row.hidden = !(row.dataset.search.includes(query) && (saveFilter === "all" || row.dataset.type === saveFilter));
  }});
}}
if (saveSearch) saveSearch.addEventListener("input", filterSaves);
document.querySelectorAll("[data-save-filter]").forEach(button => button.addEventListener("click", () => {{
  document.querySelectorAll("[data-save-filter]").forEach(item => item.classList.remove("active"));
  button.classList.add("active"); saveFilter = button.dataset.saveFilter; filterSaves();
}}));
const scenarioSearch = document.getElementById("scenario-search");
const scenarioFormat = document.getElementById("scenario-format");
function filterScenarios() {{
  if (!scenarioSearch || !scenarioFormat) return;
  const query = scenarioSearch.value.toLowerCase(), format = scenarioFormat.value;
  document.querySelectorAll(".scenario-card").forEach(card => {{
    card.hidden = !(card.dataset.search.includes(query) && (format === "all" || card.dataset.format === format));
  }});
}}
if (scenarioSearch) scenarioSearch.addEventListener("input", filterScenarios);
if (scenarioFormat) scenarioFormat.addEventListener("change", filterScenarios);
if (dock) {{
  try {{ dock.open = localStorage.getItem("openrct2-console-open") === "1"; }} catch (error) {{}}
  dock.addEventListener("toggle", () => {{
    try {{ localStorage.setItem("openrct2-console-open", dock.open ? "1" : "0"); }} catch (error) {{}}
  }});
}}
async function refreshActivity() {{
  try {{
    const response = await fetch("/activity.txt?mode=dock", {{cache:"no-store"}});
    if (response.ok) {{
      const log = await response.text();
      if (dockFeed) {{ dockFeed.textContent = log; dockFeed.scrollTop = dockFeed.scrollHeight; }}
      if (overviewFeed) {{ overviewFeed.textContent = log; overviewFeed.scrollTop = overviewFeed.scrollHeight; }}
    }}
  }} catch (error) {{}}
}}
function applyLiveStatus(status) {{
  if (!onlineCount) return;
  onlineCount.textContent = status.players === null ? "—" : String(status.players);
  if (onlineDetail) onlineDetail.textContent = status.players === null ? "Waiting for live game data" :
    (status.players === 1 ? "player in the park" : "players in the park");
  const stateText = status.auto_paused ? "Auto-paused" : (status.paused ? "Paused" : (status.online ? "Running" : "Stopped"));
  [serverMode, sessionState].forEach(element => {{ if (element) {{ element.textContent = stateText; element.className = "pill " + (status.auto_paused ? "warn" : status.paused ? "neutral" : "good"); }} }});
  if (serverPauseDetail) serverPauseDetail.textContent = status.auto_paused ? "Verified paused with nobody online" : "Live game state verified";
  if (sessionPauseDetail) sessionPauseDetail.textContent = status.players + " player(s) connected · " +
    (status.auto_paused ? "verified auto-paused" : status.auto_pause_enabled ? "pause when empty enabled" : "pause when empty disabled");
}}
async function refreshStatus() {{
  if (!onlineCount) return;
  try {{
    const response = await fetch("/status.json", {{cache:"no-store"}});
    if (!response.ok) return;
    const status = await response.json();
    applyLiveStatus(status);
  }} catch (error) {{
    if (onlineDetail) onlineDetail.textContent = "Live count temporarily unavailable";
  }}
}}
refreshActivity();
refreshStatus();
if (window.EventSource) {{
  const liveEvents = new EventSource("/events");
  liveEvents.onmessage = event => {{
    try {{
      const update = JSON.parse(event.data); applyLiveStatus(update.status);
      if (dockFeed) dockFeed.textContent = update.activity;
      if (overviewFeed) overviewFeed.textContent = update.activity;
    }} catch (error) {{}}
  }};
}} else {{
  setInterval(refreshActivity, 5000); setInterval(refreshStatus, 5000);
}}
{activity_poll}
</script>'''
        dock_html = ''
        if tab != 'overview':
            dock_html = (f'<details class="console-dock" id="console-dock"><summary>'
                         '<span><strong>Live server activity</strong><small>Read-only events and chat · streamed live</small></span>'
                         '<span class="dock-toggle"><span class="show-label">Show log ↑</span>'
                         '<span class="hide-label">Hide log ↓</span></span></summary>'
                         f'<div class="dock-inner"><pre id="dock-feed" aria-live="off">{dock_feed}</pre>'
                         '<div class="dock-footer"><span>Read-only: use Activity to message players</span>'
                         '<a href="/?tab=activity&amp;view=console">Open full activity</a></div></div></details>')
        page = f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{tabs[tab]} · OpenRCT2 Server Manager</title>
<link rel="icon" type="image/png" href="{logo_url}">
<script nonce="{nonce}">try {{ document.documentElement.dataset.theme = localStorage.getItem("openrct2-theme") || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"); }} catch (error) {{ document.documentElement.dataset.theme = "light"; }}</script>
<style>
:root{{--ink:#17324c;--muted:#5c7084;--bg:#edf3f8;--card:#fff;--line:#d7e2ea;--navy:#102e4a;--mint:#d9edf8;--teal:#146da8;--red:#a63445}}
*{{box-sizing:border-box}}html{{scroll-behavior:smooth}}body{{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,-apple-system,sans-serif}}
a{{color:#126fa9}}a:hover{{text-decoration-thickness:2px}}button,input,select{{font:inherit}}button,.button{{background:#146da8;color:white;border:0;border-radius:999px;padding:10px 16px;font-weight:700;cursor:pointer;text-decoration:none;display:inline-flex;align-items:center;justify-content:center;gap:7px;min-height:42px}}
button:hover,.button:hover{{background:#0c578b;color:white}}button.light{{background:#e3edf5;color:#18496b}}button.ghost{{background:transparent;color:var(--teal);border:1px solid var(--line)}}button.danger{{background:#a63445;color:white}}button:disabled{{opacity:.6;cursor:not-allowed}}.icon{{width:19px;height:19px;vertical-align:-.22em;flex:none}}h2>.icon{{width:20px;height:20px;color:var(--teal);margin-right:5px}}
button:focus-visible,a:focus-visible,input:focus-visible,select:focus-visible{{outline:3px solid #f4a95b;outline-offset:2px}}
.shell{{min-height:100vh;display:grid;grid-template-columns:238px minmax(0,1fr)}}aside{{background:var(--navy);color:#e8f2f4;padding:25px 14px;display:flex;flex-direction:column;gap:24px;position:sticky;top:0;height:100vh;overflow-y:auto;align-self:start}}
.brand{{display:flex;align-items:center;gap:10px;padding:0 10px;color:white;text-decoration:none;font-weight:800;line-height:1.1}}.brand-image{{position:relative;display:block;width:52px;height:60px;border-radius:12px;overflow:hidden;background:#f7fbfe;flex:none;box-shadow:0 2px 8px #0003}}.brand-image img{{position:absolute;width:150px;height:auto;max-width:none;left:50%;top:50%;transform:translate(-50%,-50%)}}.brand small{{display:block;color:#aac8db;font-weight:500}}
nav{{display:grid;gap:4px}}nav a{{padding:10px 13px;border-radius:12px;color:#d9e9f2;text-decoration:none;font-weight:650;display:flex;align-items:center;gap:12px}}nav .icon{{color:#b1d7ed}}
nav a[aria-current=page],nav a:hover{{background:#274e70;color:white}}nav a[aria-current=page] .icon{{color:#fff}}.side-note{{margin-top:auto;padding:12px;color:#acc4cc;font-size:.82rem}}
main{{max-width:1480px;width:100%;margin:0 auto;padding:28px 32px 105px}}main.overview{{padding-bottom:32px}}.topbar{{display:flex;justify-content:space-between;align-items:center;gap:16px;margin-bottom:22px}}.topbar .muted{{font-size:.88rem}}
.page-heading{{margin:8px 0 24px}}h1{{font-size:clamp(1.9rem,4vw,2.7rem);line-height:1.14;letter-spacing:-.035em;margin:5px 0 10px}}h2{{font-size:1.15rem;margin:0 0 12px}}h3{{font-size:1rem;margin:23px 0 9px}}p{{margin:8px 0 13px}}.page-heading p:last-child{{color:var(--muted);max-width:72ch}}
.eyebrow{{font-size:.72rem!important;letter-spacing:.13em;text-transform:uppercase;font-weight:800;color:var(--teal)!important;margin:0 0 5px!important}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:23px;margin-bottom:18px;box-shadow:0 2px 8px #263c500d,0 12px 28px #263c5008}}.grid{{display:grid;gap:18px}}.grid.two{{grid-template-columns:repeat(2,minmax(0,1fr))}}.grid .card{{margin:0}}.card-head{{display:flex;align-items:center;justify-content:space-between;gap:10px}}
.overview-layout{{display:grid;grid-template-columns:minmax(0,1fr) minmax(370px,1fr);gap:18px;align-items:start}}.overview-main{{min-width:0}}.overview-layout .card{{margin-bottom:18px}}.overview-console{{position:sticky;top:20px;height:calc(100vh - 40px);min-height:480px;display:flex;flex-direction:column;min-width:0}}.overview-console .card-head{{align-items:start}}.overview-console pre{{flex:1;max-height:none;min-height:0;margin:8px 0 0}}.overview-console .fine{{margin:0 0 8px}}.metrics{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px}}.metric{{display:flex;flex-direction:column;gap:3px}}.metric span{{color:var(--muted);font-size:.84rem;font-weight:700}}.metric strong{{font-size:2rem;line-height:1.2}}.metric strong.running{{color:#116447}}.metric strong.stopped{{color:#9b283a}}.metric small{{font-size:.8rem}}.park-name{{font-size:1.1rem;font-weight:750;overflow-wrap:anywhere}}
.muted,.fine,small{{color:var(--muted)}}.fine{{font-size:.88rem;margin-top:14px}}.warning{{color:#965027}}.actions{{display:flex;gap:8px;flex-wrap:wrap;margin-top:15px}}.notice{{padding:12px 16px;background:#dff5e8;border-left:4px solid #087a69;border-radius:8px;margin-bottom:18px}}
.tag{{display:inline-block;border-radius:99px;padding:5px 11px;font-size:.78rem;font-weight:800;white-space:nowrap}}.tag.running,.tag.good{{background:#d9f2e7;color:#116447}}.tag.stopped,.tag.bad{{background:#fde8eb;color:#9b283a}}
label{{display:block;font-weight:700;margin:12px 0 6px}}input[type=file],input[type=number],input[type=text],input:not([type]),select,textarea{{padding:10px;border:1px solid #bfd0d8;border-radius:10px;background:white;width:100%;max-width:100%;color:var(--ink)}}textarea{{resize:vertical}}.check{{font-weight:500}}.check input{{margin-right:8px}}.fields,.explain-grid{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}}.explain-grid{{grid-template-columns:repeat(3,minmax(0,1fr));background:#f2f7f7;border-radius:10px;padding:10px 16px}}
.file-list{{list-style:none;padding:0;margin:8px 0 0}}.file-list li{{display:flex;align-items:center;gap:12px;border-top:1px solid var(--line);padding:11px 0;overflow-wrap:anywhere}}.file-list li>span{{flex:1;min-width:0}}.file-list .download{{font-weight:700;white-space:nowrap}}.file-list .empty{{color:var(--muted)}}.count{{font-size:.8rem;background:#e5eeee;border-radius:99px;padding:2px 8px}}
.table-wrap{{overflow-x:auto}}table{{width:100%;border-collapse:collapse;min-width:760px}}th,td{{padding:12px 10px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}}th{{font-size:.8rem;color:var(--muted)}}.key{{display:block;font-family:ui-monospace,monospace;font-weight:500}}.row-form{{display:flex;align-items:center;gap:6px}}.row-form select{{min-width:130px}}.row-form button{{white-space:nowrap;padding:9px 12px}}.mini-form{{display:inline}}.mini-form button{{padding:6px 9px;min-height:32px;font-size:.78rem}}.command-grid{{display:flex;gap:5px;flex-wrap:wrap}}.group-card summary{{display:flex;align-items:center;justify-content:space-between;cursor:pointer;gap:12px;list-style:none}}.group-card summary::-webkit-details-marker{{display:none}}.group-tools{{display:flex;gap:8px;flex-wrap:wrap;margin:18px 0}}.permission-list{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px 16px;margin-top:16px}}.permission-row{{display:flex;align-items:center;justify-content:space-between;gap:12px;border-top:1px solid var(--line);padding:8px 0}}.permission-row button{{min-width:58px;min-height:32px;padding:5px 10px;font-size:.8rem}}.empty{{color:var(--muted)}}.steps{{padding-left:22px}}.steps li{{margin:12px 0}}.facts{{display:grid;grid-template-columns:150px 1fr;gap:10px}}.facts dt{{font-weight:700}}.facts dd{{margin:0;overflow-wrap:anywhere}}code{{background:#e9f0f2;padding:2px 5px;border-radius:4px;font-size:.9em}}
.segmented{{display:flex;background:#edf3f4;border-radius:8px;padding:3px;gap:3px}}.segmented a{{padding:6px 10px;text-decoration:none;border-radius:6px;font-size:.85rem;font-weight:700}}.segmented a[aria-current=page]{{background:white;box-shadow:0 1px 3px #14303a22}}
pre{{background:#132638;color:#d9eff0;border-radius:10px;padding:16px;max-height:540px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;font:13px/1.5 ui-monospace,monospace}}
.console-dock{{position:fixed;left:238px;right:0;bottom:0;z-index:20;background:#14263d;color:#e9f5f1;border-top:2px solid #6dc9ad;box-shadow:0 -5px 20px #14263d22}}.console-dock summary{{padding:10px 20px;cursor:pointer;list-style:none;display:flex;justify-content:space-between;align-items:center;gap:16px}}.console-dock summary strong{{display:block}}.console-dock summary small{{display:block;color:#b9d8d5;font-size:.75rem}}.console-dock summary::-webkit-details-marker{{display:none}}.dock-toggle{{font-size:.83rem;font-weight:750;color:#b9d8d5;white-space:nowrap}}.hide-label,.console-dock[open] .show-label{{display:none}}.console-dock[open] .hide-label{{display:inline}}.console-dock .dock-inner{{padding:0 16px 14px}}.console-dock pre{{margin:0;max-height:230px;background:#0e1d2a;border:1px solid #345467}}.console-dock a{{color:#9debd3;font-size:.85rem}}.console-dock .dock-footer{{display:flex;justify-content:space-between;gap:10px;padding:8px 3px 0;color:#acc8c9;font-size:.8rem}}
.topbar-actions{{display:flex;align-items:center;gap:10px;flex-wrap:wrap;justify-content:flex-end}}.theme-toggle{{background:transparent;color:var(--ink);border:1px solid var(--line);border-radius:10px;padding:7px 11px;min-height:36px;font-size:.85rem}}.theme-toggle:hover{{background:var(--mint);color:var(--ink)}}
html[data-theme=dark]{{color-scheme:dark;--ink:#e8f0fa;--muted:#a9bbce;--bg:#101b2b;--card:#17283c;--line:#34475c;--navy:#0b1523;--mint:#25405a;--teal:#72c6ff}}
html[data-theme=dark] a{{color:#85cfff}}html[data-theme=dark] aside a,html[data-theme=dark] .console-dock a{{color:#d9e9f2}}
html[data-theme=dark] .card{{box-shadow:0 2px 12px #0003}}html[data-theme=dark] .explain-grid,html[data-theme=dark] .segmented{{background:#20364d}}
html[data-theme=dark] input[type=file],html[data-theme=dark] input[type=number],html[data-theme=dark] input[type=text],html[data-theme=dark] input:not([type]),html[data-theme=dark] select,html[data-theme=dark] textarea{{background:#102034;border-color:#536b82;color:var(--ink)}}
html[data-theme=dark] code{{background:#253a52;color:#dcecff}}html[data-theme=dark] .tag.running,html[data-theme=dark] .tag.good{{background:#174336;color:#aeefd4}}html[data-theme=dark] .tag.stopped,html[data-theme=dark] .tag.bad{{background:#522832;color:#ffb9c4}}
html[data-theme=dark] .metric strong.running{{color:#8fe6bf}}html[data-theme=dark] .metric strong.stopped{{color:#ffacb9}}html[data-theme=dark] .notice{{background:#164332;color:#ddf9e8}}
html[data-theme=dark] button.light{{background:#29445e;color:#e5f3ff}}html[data-theme=dark] .segmented a[aria-current=page]{{background:#375572;color:#f1f8ff}}html[data-theme=dark] .theme-toggle{{background:#20364d;color:#e8f0fa}}
html[data-theme=dark] .brand-image{{background:#dcecf7}}html[data-theme=dark] .warning{{color:#efbd91}}
/* v3 visual system — kept in sync with the approved local mock-up. */
:root{{--bg:#f4f7fb;--card:#fff;--ink:#172b3f;--muted:#63768a;--line:#dbe4ec;--navy:#10263a;--mint:#eef3f8;--teal:#0877b9;--shadow:0 1px 2px #10263a0a,0 10px 30px #10263a0d}}
html[data-theme=dark]{{--bg:#0c1724;--card:#132438;--ink:#e8f1fa;--muted:#a6b8ca;--line:#30465c;--navy:#08131f;--mint:#1b3045;--teal:#55b9f4;--shadow:0 1px 2px #0004,0 10px 30px #0003}}
body{{font:15px/1.5 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}.shell{{grid-template-columns:256px minmax(0,1fr)}}
aside{{padding:20px 14px;gap:0;background:var(--navy)}}.brand{{gap:12px;padding:4px 8px 20px;font-size:15px}}.brand-image{{width:54px;height:54px;border-radius:13px}}.brand-image img{{width:54px;height:54px;object-fit:cover;left:0;top:0;transform:none}}.brand strong{{display:block;line-height:1.2}}.brand small{{font-size:12px;color:#a9c6da}}.logout-form{{margin-top:10px}}.logout-form button{{width:100%;min-height:32px;padding:5px 9px;background:#ffffff0c;border:1px solid #ffffff20;color:#d9e9f2;font-size:12px}}
nav{{gap:4px}}nav a{{padding:10px 12px;border-radius:11px}}nav a[aria-current=page]{{background:#183b57;box-shadow:inset 3px 0 #62c5f8}}.side-note{{display:none}}.side-bottom{{margin-top:auto;padding:18px 8px 2px}}.side-status{{display:flex;align-items:center;gap:8px;font-size:12px;color:#b9d1df}}.dot{{width:8px;height:8px;background:#5dd5ab;border-radius:50%;box-shadow:0 0 0 4px #5dd5ab1f;display:inline-block}}.viewer{{display:flex;gap:10px;align-items:center;margin-top:15px;padding-top:14px;border-top:1px solid #ffffff17}}.avatar{{width:34px;height:34px;border-radius:50%;display:grid;place-items:center;background:#20608b;color:#fff;font-weight:800}}.viewer strong,.viewer small{{display:block}}.viewer small{{color:#a9c6da;font-size:11px}}
main,main.overview{{max-width:none;margin:0;padding:0;min-width:0}}.topbar{{height:68px;position:sticky;top:0;z-index:15;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(14px);border-bottom:1px solid var(--line);padding:0 30px;margin:0}}.crumb{{display:flex;align-items:center;gap:10px;color:var(--muted);font-size:13px}}.crumb strong{{color:var(--ink)}}.content{{max-width:1500px;margin:auto;padding:30px 34px 110px}}
.heading{{display:flex;align-items:flex-end;justify-content:space-between;gap:20px;margin-bottom:23px}}.heading h1{{font-size:30px;line-height:1.15;letter-spacing:-.035em;margin:0 0 7px}}.heading p{{margin:0;color:var(--muted);max-width:720px}}.heading-actions{{display:flex;gap:9px;flex-wrap:wrap}}.page-heading{{margin:0 0 23px}}.page-heading h1{{font-size:30px}}
.card{{border-radius:18px;padding:21px;box-shadow:var(--shadow)}}button,.button{{border-radius:11px;padding:10px 15px;min-height:42px;background:var(--teal)}}button.light,.button.secondary{{background:var(--card);border:1px solid var(--line);color:var(--ink)}}button.ghost{{border-radius:11px}}button.small,.button.small{{min-height:35px;padding:7px 11px;font-size:13px}}
.grid.three{{grid-template-columns:repeat(3,minmax(0,1fr))}}.grid.four{{grid-template-columns:repeat(4,minmax(0,1fr))}}.overview-stats,.save-metrics{{margin-bottom:18px}}.stat{{padding:18px;margin:0}}.stat-label{{display:flex;align-items:center;justify-content:space-between;color:var(--muted);font-weight:650;font-size:12px}}.stat strong{{display:block;font-size:26px;line-height:1.2;margin-top:10px;letter-spacing:-.025em}}.stat small{{color:var(--muted)}}.pill{{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:4px 9px;font-size:11px;font-weight:800;white-space:nowrap}}.pill.good{{background:#183c38;color:#77d9bf}}
.overview-layout{{grid-template-columns:minmax(0,1.38fr) minmax(350px,.82fr);gap:18px}}.overview-console{{top:86px;height:auto;min-height:0}}.console{{background:#0a1724;color:#d8eaf6;border-radius:13px;min-height:390px;max-height:590px;overflow:auto;padding:15px;font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace}}.join-box{{display:flex;align-items:center;justify-content:space-between;gap:14px;background:var(--mint);border-radius:13px;padding:13px 14px}}.join-address{{font:700 15px ui-monospace,SFMono-Regular,Menlo,monospace}}.join-box small{{display:block;color:var(--muted)}}.current-park h3{{font-size:19px;margin:0 0 3px}}.current-park p{{color:var(--muted);margin:0}}.server-actions{{display:flex;gap:8px;margin-top:15px;flex-wrap:wrap}}.save-list{{display:grid}}.save-row{{display:grid;grid-template-columns:minmax(0,1fr) 145px auto;align-items:center;gap:14px;padding:12px 0;border-top:1px solid var(--line)}}.save-row:first-child{{border-top:0;padding-top:0}}.file-title{{font-weight:720}}.file-meta{{display:flex;gap:7px;align-items:center;color:var(--muted);font-size:12px;margin-top:2px;flex-wrap:wrap}}.save-time{{font-size:13px;color:var(--muted)}}.row-actions{{display:flex;gap:6px}}.chat-form{{display:flex;gap:8px;margin-top:14px}}.chat-form input{{flex:1}}
.theme-toggle{{width:40px;height:40px;border-radius:11px;padding:0}}.theme-toggle span{{position:absolute;clip:rect(0 0 0 0);clip-path:inset(50%)}}.topbar-actions .tag{{display:none}}
.form-grid{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}}.span-2{{grid-column:span 2}}.help{{display:block;color:var(--muted);font-size:12px;margin-top:5px}}.switch{{display:inline-flex;align-items:center;gap:9px;font-weight:650;font-size:13px;margin:10px 0}}.switch input{{position:absolute;opacity:0}}.switch-track{{width:38px;height:22px;border-radius:99px;background:var(--mint);position:relative;flex:none}}.switch-track:after{{content:"";width:16px;height:16px;border-radius:50%;background:#fff;position:absolute;left:3px;top:3px;box-shadow:0 1px 3px #0004}}.switch input:checked + .switch-track{{background:var(--teal)}}.switch input:checked + .switch-track:after{{transform:translateX(16px)}}
.command{{display:grid;grid-template-columns:130px minmax(0,1fr) auto;gap:15px;align-items:center;padding:14px 0;border-top:1px solid var(--line)}}.command:first-of-type{{border-top:0}}.command p{{margin:0;color:var(--muted);font-size:13px}}.pill.neutral{{background:var(--mint);color:var(--muted)}}.pill.warn{{background:#493718;color:#ffc36c}}.request-row form{{display:flex;gap:6px}}
.override-editor{{position:relative}}.override-editor>summary{{list-style:none;cursor:pointer;white-space:nowrap}}.override-editor>summary::-webkit-details-marker{{display:none}}.override-popover{{position:absolute;right:0;top:42px;z-index:12;width:310px;padding:14px;background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:0 16px 45px #06162538}}.override-current{{list-style:none;margin:0 0 10px;padding:0}}.override-current li{{display:flex;justify-content:space-between;gap:8px;padding:5px 0;border-bottom:1px solid var(--line);font-size:12px}}.override-form label{{font-size:12px;margin-top:6px}}.override-form button{{margin-top:12px;width:100%}}
.tabs{{display:flex;gap:4px;border-bottom:1px solid var(--line);margin-bottom:18px;overflow:auto}}.tabs button,.tabs a{{border:0;background:transparent;padding:10px 13px;color:var(--muted);font-weight:700;cursor:pointer;border-bottom:2px solid transparent;border-radius:0;text-decoration:none;min-height:auto}}.tabs button.active{{color:var(--teal);border-color:var(--teal)}}.toolbar{{display:flex;gap:10px;align-items:center;flex-wrap:wrap}}.toolbar input{{flex:1;min-width:220px}}.divider{{height:1px;background:var(--line);margin:18px 0}}
.database{{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:13px}}.scenario-card{{border:1px solid var(--line);border-radius:15px;padding:16px;background:var(--card);display:flex;flex-direction:column;gap:13px;min-width:0}}.scenario-card.running{{border-color:#77d9bf;box-shadow:inset 0 0 0 1px #77d9bf}}.scenario-top,.scenario-foot{{display:flex;justify-content:space-between;align-items:center;gap:10px}}.scenario-icon{{width:40px;height:40px;border-radius:11px;background:var(--mint);color:var(--teal);display:grid;place-items:center}}.scenario-card h3{{font-size:15px;margin:0;overflow-wrap:anywhere}}.scenario-card p{{font-size:12px;color:var(--muted);margin:3px 0 0}}.scenario-foot{{margin-top:auto;padding-top:11px;border-top:1px solid var(--line)}}.tiny{{font-size:12px}}
@media(max-width:1080px){{.overview-layout{{grid-template-columns:1fr}}.overview-console{{position:static;height:420px;min-height:0}}}}
@media(max-width:820px){{.shell{{display:block}}aside{{position:static;height:auto;overflow:visible;padding:10px 14px;gap:9px}}.brand-image{{width:42px;height:42px}}.brand-image img{{width:42px;height:42px}}nav{{display:flex;overflow:auto}}nav a{{white-space:nowrap}}.side-bottom{{display:none}}main,main.overview{{padding:0}}.content{{padding:22px 16px 90px}}.topbar{{padding:0 16px}}.grid.two,.grid.four{{grid-template-columns:1fr}}.console-dock{{left:0}}}}
@media(max-width:580px){{.metrics{{grid-template-columns:1fr}}.fields,.explain-grid,.permission-list,.form-grid{{grid-template-columns:1fr}}.file-list li{{flex-wrap:wrap}}.file-list .download{{width:100%}}.topbar{{align-items:center}}.overview-console{{height:auto}}.heading{{align-items:flex-start;flex-direction:column}}.save-row{{grid-template-columns:1fr}}}}
</style></head><body><div class="shell"><aside>
<a class="brand" href="/"><span class="brand-image"><img src="{logo_url}" alt=""></span><span><strong>OpenRCT2</strong><small>Server Manager</small></span></a>
<nav aria-label="Main navigation">{nav}</nav><div class="side-bottom"><div class="side-status"><span class="dot"></span>Game server {status.lower()}</div><div class="viewer"><span class="avatar">{html.escape(''.join(x[:1] for x in self.portal_user['display_name'].split()[:2]).upper())}</span><span><strong>{html.escape(self.portal_user['display_name'])}</strong><small>{html.escape(self.portal_user['role'].title())}</small></span></div><form method="post" action="/logout" class="logout-form">{token}<button>Sign out</button></form></div></aside>
<main id="content" class="{tab}"><div class="topbar"><div class="crumb"><span>OpenRCT2 Manager</span><span>›</span><strong>{tabs[tab]}</strong></div><div class="topbar-actions"><span class="pill good"><span class="dot"></span>Live</span><button class="theme-toggle" id="theme-toggle" type="button" aria-label="Toggle dark mode" aria-pressed="false">{icon('theme')} <span>Dark mode</span></button></div></div>
<div class="content">{notice}{content}<p class="fine">OpenRCT2 Server Manager is an independent community project.</p></div></main></div>
{dock_html}
{script}</body></html>'''.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy',
                         f"default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; "
                         f"script-src 'nonce-{nonce}'; connect-src 'self'; form-action 'self'; "
                         f"base-uri 'none'; frame-ancestors 'none'")
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)

if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == '--init-setup-token':
        initialize_setup_token(sys.stdin.read().rstrip('\n'))
        print('One-time browser setup enabled.')
    elif len(sys.argv) == 2 and sys.argv[1] == '--setup':
        migrate_state()
        ensure_control_token()
        ensure_portal_owner()
        if not SETTINGS.exists():
            save_settings(DEFAULT_SETTINGS.copy())
        else:
            publish_helper(settings())
    elif len(sys.argv) == 2 and sys.argv[1] == '--prune':
        prune_snapshots()
    elif len(sys.argv) == 2 and sys.argv[1] == '--verify-audit':
        print(f'Audit chain verified: {verify_audit_log()} records')
    elif len(sys.argv) == 1:
        bind_address = WEB_BIND
        migrate_state()
        ensure_portal_owner()
        threading.Thread(target=callback_server, name='game-command-callback', daemon=True).start()
        threading.Thread(target=backup_scheduler, name='remote-backup-scheduler', daemon=True).start()
        threading.Thread(target=job_worker, name='backup-job-worker', daemon=True).start()
        server = ThreadingHTTPServer((bind_address, PORT), Handler)
        server.daemon_threads = True
        server.block_on_close = False
        print(f'OpenRCT2 manager listening on {bind_address}:{PORT}', flush=True)
        server.serve_forever()
    else:
        raise SystemExit('Usage: openrct2-manager.py [--init-setup-token|--setup|--prune|--verify-audit]')
PYAPP
chmod 0755 /usr/local/lib/openrct2-manager.py
cat > /usr/local/share/openrct2-manager/manager-helper.template.js <<'JSTEMPLATE'
/* OpenRCT2 Server Manager remote helper. Generated config values use __TOKENS__. */
var blockedHashes = __BLOCKED_HASHES__;
var roleOverrides = __ROLE_OVERRIDES__;
var commandAccess = __COMMAND_ACCESS__;
var snapshotMinutes = __SNAPSHOT_MINUTES__;
var autoPauseWhenEmpty = __PAUSE_WHEN_EMPTY__;
var controlPort = __CONTROL_PORT__;
var callbackPort = __CALLBACK_PORT__;
var controlToken = __CONTROL_TOKEN__;
var seen = {};
var lastActions = {};
var controlListener = null;
var ticksSincePlayerScan = 0;
var pendingSave = null;
var snapshotDue = false;
var nextSnapshotAt = snapshotMinutes > 0 ? Date.now() + snapshotMinutes * 60000 : 0;
var roleUpdateDue = false;
var lastCommandAt = {};
var motdLines = [];
var permissionRequests = {
    "chat": "PERMISSION_CHAT",
    "terraform": "PERMISSION_TERRAFORM",
    "water": "PERMISSION_SET_WATER_LEVEL",
    "rides": "PERMISSION_BUILD_RIDE",
    "ride-properties": "PERMISSION_RIDE_PROPERTIES",
    "scenery": "PERMISSION_SCENERY",
    "scenery-brush": "PERMISSION_TOGGLE_SCENERY_CLUSTER",
    "paths": "PERMISSION_PATH",
    "clear-landscape": "PERMISSION_CLEAR_LANDSCAPE",
    "staff": "PERMISSION_STAFF",
    "park": "PERMISSION_PARK_PROPERTIES",
    "funding": "PERMISSION_PARK_FUNDING",
    "kick": "PERMISSION_KICK_PLAYER",
    "groups": "PERMISSION_MODIFY_GROUPS",
    "cheats": "PERMISSION_CHEAT",
    "scenario": "PERMISSION_EDIT_SCENARIO_OPTIONS"
};
var knownCommands = ["help", "motd", "status", "players", "request", "save", "backup", "restart"];
var restrictedCommands = ["save", "backup", "restart"];
var callbackOutbox = [];
var callbackActive = false;
var callbackSequence = 0;
var autoPauseRequested = false;
var lastParkTick = date.ticksElapsed;
var lastParkTickChangedAt = Date.now();

function playerHash(player) {
    return player ? String(player.publicKeyHash || "").toLowerCase() : "";
}

function groupPermissions(player) {
    try { return network.getGroup(player.group).permissions || []; } catch (error) { return []; }
}

function canUse(player, command) {
    if (!player || !/^[0-9a-f]{40}$/.test(playerHash(player))) return false;
    if (restrictedCommands.indexOf(command) === -1) return true;
    var grants = commandAccess[playerHash(player)] || [];
    if (grants.indexOf("*") !== -1 || grants.indexOf(command) !== -1) return true;
    if (player.group === 0) return true;
    var permissions = groupPermissions(player);
    if (command === "save") return permissions.indexOf("park_properties") !== -1;
    return permissions.indexOf("modify_groups") !== -1;
}

function applyRoleOverrides() {
    for (var i = 0; i < network.players.length; i++) {
        var player = network.players[i];
        var hash = playerHash(player);
        if (!Object.prototype.hasOwnProperty.call(roleOverrides, hash) || player.group === roleOverrides[hash]) continue;
        try { player.group = roleOverrides[hash]; } catch (error) {
            console.log("[MANAGER] Could not apply saved group to " + hash.slice(0, 10) + ": " + error);
        }
    }
}

function drainCallbackOutbox() {
    if (callbackActive || callbackOutbox.length === 0) return;
    callbackActive = true;
    var item = callbackOutbox[0], socket = null, acknowledged = false, finished = false, buffer = "";
    function complete(success, reason) {
        if (finished) return; finished = true; callbackActive = false;
        if (success) {
            callbackOutbox.shift();
            context.setTimeout(drainCallbackOutbox, 1);
            return;
        }
        item.attempts++;
        var delay = Math.min(30000, 500 * Math.pow(2, Math.min(item.attempts, 6)));
        console.log("[MANAGER] Callback " + item.payload.action + " retry in " + delay + "ms: " + reason);
        context.setTimeout(drainCallbackOutbox, delay);
    }
    try {
        socket = network.createSocket(); socket.setNoDelay(true);
        socket.on("data", function (chunk) {
            buffer += chunk;
            if (buffer.length > 2048) { socket.destroy({}); complete(false, "oversized response"); return; }
            var end = buffer.indexOf("\n"); if (end < 0) return;
            try {
                var response = JSON.parse(buffer.slice(0, end));
                acknowledged = response.ok === true;
                socket.end();
                complete(acknowledged, response.status || "rejected");
            } catch (error) { socket.destroy({}); complete(false, "invalid response"); }
        });
        socket.on("error", function (error) { complete(false, String(error)); });
        socket.on("close", function () { if (!acknowledged) complete(false, "connection closed"); });
        socket.connect(callbackPort, "127.0.0.1", function () {
            socket.write(JSON.stringify(item.payload) + "\n");
        });
        context.setTimeout(function () {
            if (!finished) { try { socket.destroy({}); } catch (error) {} complete(false, "timeout"); }
        }, 3000);
    } catch (error) { complete(false, String(error)); }
}

function callbackManager(action, player, fields) {
    if (callbackOutbox.length >= 64) {
        console.log("[MANAGER] Callback outbox full; rejected " + action);
        return false;
    }
    callbackSequence++;
    var payload = { token: controlToken, action: action, player_id: player.id,
        player_name: player.name, public_key_hash: playerHash(player),
        event_id: playerHash(player).slice(0, 12) + "-" + Date.now() + "-" + callbackSequence };
    fields = fields || {};
    Object.keys(fields).forEach(function (key) { payload[key] = fields[key]; });
    callbackOutbox.push({ payload: payload, attempts: 0 });
    drainCallbackOutbox();
    return true;
}

function privateMessage(player, message) {
    if (player) network.sendMessage("Manager: " + message, [player.id]);
}

function validMotd(lines) {
    return Array.isArray(lines) && lines.length <= 5 && lines.every(function (line) {
        return typeof line === "string" && line.length > 0 && line.length <= 180 && !/[\r\n\x00-\x1f]/.test(line);
    });
}

function sendMotd(player) {
    if (!player) return;
    if (!motdLines.length) { privateMessage(player, "No message of the day has been set."); return; }
    motdLines.forEach(function (line) { network.sendMessage(line, [player.id]); });
}

function command(event, player, name, argument) {
    event.message = "";
    if (!canUse(player, name)) {
        privateMessage(player, "You do not have permission to use /" + name + ". Try /request or ask a portal administrator.");
        console.log("[MANAGER] Denied /" + name + " from " + (player ? player.name : "unknown"));
        return;
    }
    if (name === "request") {
        argument = String(argument || "").toLowerCase();
        if (argument === "help" || !argument) {
            privateMessage(player, "Requestable permissions: " + Object.keys(permissionRequests).join(", "));
            return;
        }
        if (!Object.prototype.hasOwnProperty.call(permissionRequests, argument)) {
            privateMessage(player, "Unknown permission. Use /request help to see the allowed names.");
            return;
        }
    }
    if (name === "save" && argument && !/^[a-z0-9][a-z0-9_-]{0,23}$/i.test(argument)) {
        privateMessage(player, "Save labels may use 1-24 letters, numbers, hyphens, or underscores.");
        return;
    }
    var cooldowns = { help: 2, motd: 5, status: 5, players: 5, request: 60, save: 30, backup: 300, restart: 300 };
    var key = playerHash(player) + ":" + name + (name === "request" ? ":" + argument : "");
    var waitSeconds = cooldowns[name] || 30;
    if (lastCommandAt[key] && Date.now() - lastCommandAt[key] < waitSeconds * 1000) {
        privateMessage(player, "Wait " + waitSeconds + " seconds before using /" + name + " again.");
        return;
    }
    lastCommandAt[key] = Date.now();
    if (name === "help") {
        privateMessage(player, "Commands: /motd, /status, /players, /request <permission>, /save [label], /backup, /restart");
    } else if (name === "motd") {
        sendMotd(player);
    } else if (name === "status") {
        privateMessage(player, "Server online; " + network.players.length + " player(s); park " +
            (context.paused ? "paused" : "running") + ".");
    } else if (name === "players") {
        var names = network.players.map(function (item) { return item.name; }).join(", ");
        privateMessage(player, network.players.length + " online: " + names.slice(0, 140));
    } else if (name === "request") {
        if (callbackManager("permission_request", player,
                { permission: permissionRequests[argument], permission_name: argument }))
            privateMessage(player, "Your request for " + argument + " was sent to the portal administrators.");
        else privateMessage(player, "The manager is busy; please try your request again shortly.");
    } else if (name === "save") {
        if (pendingSave) { privateMessage(player, "A save is already pending."); return; }
        var label = argument ? "-" + String(argument).toLowerCase() : "";
        pendingSave = { player: player, prefix: "chat-save" + label };
        privateMessage(player, "Saving a timestamped copy of the current park.");
    } else if (name === "backup") {
        if (callbackManager("backup", player)) privateMessage(player, "Full backup queued.");
        else privateMessage(player, "The manager is busy; the backup was not queued.");
    } else if (name === "restart") {
        // Save from a mutable game hook first. The external worker restarts only after receiving the callback.
        pendingSave = { player: player, prefix: "pre-restart", callback: "restart" };
        network.sendMessage("Manager: Saving now; the server will restart shortly.");
    }
    console.log("[MANAGER] " + player.name + " used /" + name);
}

function groupPayload() {
    return { ok: true, default_group: network.defaultGroup, groups: network.groups.map(function (group) {
        return { id: group.id, name: group.name,
            permissions: group.permissions.map(function (permission) { return "PERMISSION_" + permission.toUpperCase(); }) };
    }) };
}

function statusPayload() {
    var ownId = -1;
    try { ownId = network.currentPlayer.id; } catch (error) {}
    var players = network.players.filter(function (player) { return player.id !== ownId; }).map(function (player) {
        return { id: player.id, name: player.name, group: player.group, ping: player.ping,
            commands_ran: player.commandsRan, money_spent: player.moneySpent, ip_address: player.ipAddress,
            public_key_hash: playerHash(player), last_action: lastActions[player.id] || null };
    });
    var currentParkTick = date.ticksElapsed;
    if (currentParkTick !== lastParkTick) { lastParkTick = currentParkTick; lastParkTickChangedAt = Date.now(); }
    // OpenRCT2's native headless empty-server pause is not reflected by context.paused
    // on every release. No simulation tick movement for two seconds is the authoritative check.
    var tickVerifiedPaused = players.length === 0 && Date.now() - lastParkTickChangedAt >= 2000;
    return { ok: true, players: players, paused: context.paused === true || tickVerifiedPaused,
        auto_pause_enabled: autoPauseWhenEmpty,
        auto_paused: autoPauseWhenEmpty && players.length === 0 && (context.paused === true || tickVerifiedPaused),
        park_tick: currentParkTick };
}

function handleControl(request) {
    if (request.action === "status") return statusPayload();
    if (request.action === "groups") return groupPayload();
    if (request.action === "prepare_switch") {
        if (pendingSave) return { ok: false, error: "save_busy" };
        var switchStamp = new Date().toISOString().replace(/[-:.]/g, "");
        var switchFilename = "pre-switch-" + switchStamp;
        // A remote plugin can mutate state only in a custom action's execute
        // callback. This also runs while the empty headless server is paused.
        context.executeAction("openrct2manager-save", { filename: switchFilename }, function (result) {
            if (result && result.error) console.log("[MANAGER] Pre-switch save failed: " + result.errorMessage);
        });
        return { ok: true, filename: switchFilename + ".park" };
    }
    if (request.action === "chat" && typeof request.message === "string" && request.message.length > 0 &&
            request.message.length <= 180 && !/[\r\n\x00-\x1f]/.test(request.message)) {
        network.sendMessage("Manager: " + request.message); return { ok: true };
    }
    if (request.action === "set_motd" && validMotd(request.lines)) {
        motdLines = request.lines.slice();
        context.sharedStorage.set("openrct2-manager.motd", motdLines);
        return { ok: true, lines: motdLines.slice() };
    }
    if (request.action === "set_snapshot_config" && typeof request.minutes === "number" &&
            request.minutes >= 0 && request.minutes <= 1440 && Math.floor(request.minutes) === request.minutes) {
        snapshotMinutes = request.minutes;
        nextSnapshotAt = snapshotMinutes > 0 ? Date.now() + snapshotMinutes * 60000 : 0;
        return { ok: true };
    }
    if (request.action === "set_role" && /^[0-9a-f]{40}$/.test(String(request.hash || "")) &&
            typeof request.group === "number") {
        roleOverrides[String(request.hash).toLowerCase()] = request.group; roleUpdateDue = true; return { ok: true };
    }
    if (request.action === "set_command_access" && /^[0-9a-f]{40}$/.test(String(request.hash || "")) &&
            typeof request.allowed === "boolean") {
        var hash = String(request.hash).toLowerCase();
        var commandName = request.command === undefined ? "*" : String(request.command).toLowerCase();
        if (commandName !== "*" && restrictedCommands.indexOf(commandName) === -1) return { ok: false };
        var grants = commandAccess[hash] || []; var grantIndex = grants.indexOf(commandName);
        if (request.allowed && grantIndex < 0) grants.push(commandName);
        if (!request.allowed && grantIndex >= 0) grants.splice(grantIndex, 1);
        if (grants.length) commandAccess[hash] = grants; else delete commandAccess[hash];
        return { ok: true, commands: grants.slice() };
    }
    if (request.action === "set_blocked" && /^[0-9a-f]{40}$/.test(String(request.hash || "")) &&
            typeof request.blocked === "boolean") {
        var blockedHash = String(request.hash).toLowerCase(); var blockedIndex = blockedHashes.indexOf(blockedHash);
        if (request.blocked && blockedIndex < 0) blockedHashes.push(blockedHash);
        if (!request.blocked && blockedIndex >= 0) blockedHashes.splice(blockedIndex, 1);
        if (request.blocked) for (var bi = 0; bi < network.players.length; bi++)
            if (playerHash(network.players[bi]) === blockedHash) network.kickPlayer(network.players[bi].id);
        return { ok: true };
    }
    if (request.action === "kick" && typeof request.player_id === "number") {
        network.kickPlayer(request.player_id); return { ok: true };
    }
    if (request.action === "group_create" && typeof request.name === "string") {
        var before = network.groups.map(function (g) { return g.id; }); network.addGroup();
        var created = network.groups.filter(function (g) { return before.indexOf(g.id) < 0; })[0];
        if (!created) return { ok: false }; created.name = request.name; return groupPayload();
    }
    if (request.action === "group_rename" && request.group !== 0) {
        network.getGroup(request.group).name = request.name; return groupPayload();
    }
    if (request.action === "group_delete" && request.group !== 0) {
        network.removeGroup(request.group); return groupPayload();
    }
    if (request.action === "group_default") { network.defaultGroup = request.group; return groupPayload(); }
    if (request.action === "group_permission" && request.group !== 0 && typeof request.allowed === "boolean") {
        var group = network.getGroup(request.group);
        var permission = String(request.permission || "").replace(/^PERMISSION_/, "").toLowerCase();
        var permissions = group.permissions.slice(); var pi = permissions.indexOf(permission);
        if (request.allowed && pi < 0) permissions.push(permission);
        if (!request.allowed && pi >= 0) permissions.splice(pi, 1);
        group.permissions = permissions; return groupPayload();
    }
    return { ok: false };
}

function main() {
    if (network.mode !== "server") return;
    context.registerAction("openrct2manager-save", function (event) {
        var filename = event && event.args && event.args.filename;
        return typeof filename === "string" && /^pre-switch-[0-9TZ]+$/.test(filename)
            ? {} : { error: 1, errorMessage: "Invalid manager save filename" };
    }, function (event) {
        var filename = event.args.filename;
        context.saveGame({ filename: filename });
        console.log("[MANAGER] Saved " + filename + ".park before park switch");
        return {};
    });
    try {
        var storedMotd = context.sharedStorage.get("openrct2-manager.motd");
        if (validMotd(storedMotd)) motdLines = storedMotd.slice();
    } catch (error) { console.log("[MANAGER] Could not load MOTD: " + error); }
    context.subscribe("network.authenticate", function (event) {
        if (blockedHashes.indexOf(String(event.publicKeyHash || "").toLowerCase()) !== -1) event.cancel = true;
    });
    context.subscribe("network.chat", function (event) {
        var player = null; try { player = network.getPlayer(event.player); } catch (error) {}
        var original = String(event.message || "").trim();
        var match = /^\/([a-z][a-z0-9-]*)(?:\s+(.+))?$/i.exec(original);
        var name = match ? match[1].toLowerCase() : "";
        if (name === "autosave" || name === "snapshot") name = "save";
        if (name === "who") name = "players";
        if (name === "commands") name = "help";
        if (knownCommands.indexOf(name) !== -1) { command(event, player, name, match && match[2]); return; }
        console.log("[CHAT] " + (player ? player.name : "Player") + ": " + String(event.message || "").replace(/[\r\n\t]/g, " ").slice(0, 500));
    });
    context.subscribe("network.join", function (event) {
        context.setTimeout(function () {
            var player = null; try { player = network.getPlayer(event.player); } catch (error) {}
            sendMotd(player);
        }, 1500);
    });
    context.subscribe("action.execute", function (event) {
        if (typeof event.player === "number" && event.player >= 0) lastActions[event.player] = event.action;
    });
    context.subscribe("network.leave", function (event) {
        if (typeof event.player === "number") delete lastActions[event.player];
    });
    try {
        controlListener = network.createListener();
        controlListener.on("connection", function (socket) {
            var buffer = "", done = false;
            socket.on("data", function (chunk) {
                if (done) return; buffer += chunk;
                if (buffer.length > 8192) { done = true; socket.end('{"ok":false}'); return; }
                var end = buffer.indexOf("\n"); if (end < 0) return; done = true;
                try { var request = JSON.parse(buffer.slice(0, end));
                    if (request.token !== controlToken) { socket.end('{"ok":false}'); return; }
                    socket.end(JSON.stringify(handleControl(request)));
                } catch (error) { socket.end('{"ok":false}'); }
            });
        });
        controlListener.listen(controlPort, "127.0.0.1");
    } catch (error) { console.log("[MANAGER] Control bridge unavailable: " + error); }
    context.subscribe("interval.tick", function () {
        var ownId = -1;
        try { ownId = network.currentPlayer.id; } catch (error) {}
        var humanPlayers = network.players.filter(function (player) { return player.id !== ownId; }).length;
        // OpenRCT2 also has a native empty-server pause setting. Enforce it here as a
        // second line of defence and expose the verified state to the portal.
        if (autoPauseWhenEmpty && humanPlayers === 0 && context.paused !== true && !autoPauseRequested) {
            autoPauseRequested = true;
            context.executeAction("pausetoggle", {}, function (result) {
                autoPauseRequested = false;
                if (result && result.error) console.log("[MANAGER] Auto-pause failed: " + result.errorMessage);
            });
        }
        if (humanPlayers > 0 || context.paused === true) autoPauseRequested = false;
        if (pendingSave) {
            var request = pendingSave; pendingSave = null;
            var stamp = new Date().toISOString().replace(/[-:.]/g, "");
            var filename = request.filename || request.prefix + "-" + stamp;
            try { context.saveGame({ filename: filename });
                console.log("[MANAGER] Saved " + filename + ".park");
                network.sendMessage("Manager: Save ready: " + filename + ".park");
                if (request.callback) callbackManager(request.callback, request.player);
            } catch (error) { console.log("[MANAGER] Save failed: " + error); }
        }
        if (snapshotDue) {
            snapshotDue = false; var snapshotStamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
            try { context.saveGame({ filename: "manager-snapshot-" + snapshotStamp }); }
            catch (error) { console.log("[MANAGER] Snapshot failed: " + error); }
        }
        if (roleUpdateDue) { roleUpdateDue = false; applyRoleOverrides(); }
        if (snapshotMinutes > 0 && nextSnapshotAt > 0 && Date.now() >= nextSnapshotAt) {
            snapshotDue = true;
            nextSnapshotAt = Date.now() + snapshotMinutes * 60000;
        }
        ticksSincePlayerScan++; if (ticksSincePlayerScan < 40) return; ticksSincePlayerScan = 0; applyRoleOverrides();
        var now = Date.now();
        if (Object.keys(lastCommandAt).length > 4096) Object.keys(lastCommandAt).forEach(function (key) {
            if (now - lastCommandAt[key] > 86400000) delete lastCommandAt[key];
        });
        for (var i = 0; i < network.players.length; i++) {
            var player = network.players[i], hash = playerHash(player);
            if (!/^[0-9a-f]{40}$/.test(hash) || seen[hash]) continue;
            try { player.group = player.group; seen[hash] = true; } catch (error) {}
        }
    });
}

registerPlugin({ name:"OpenRCT2 Manager Helper", version:"3.0.0", authors:["OpenRCT2 Manager"],
    type:"remote", licence:"MIT", targetApiVersion:107, minApiVersion:107, main:main });
JSTEMPLATE
chmod 0644 /usr/local/share/openrct2-manager/manager-helper.template.js

setup_token_issued=false
portal_user_count=$(python3 - <<'PYUSERS'
import json
try:
    data = json.load(open('/var/lib/openrct2-manager/portal-users.json', encoding='utf-8'))
    print(len(data.get('users', [])) if isinstance(data, dict) else 0)
except (FileNotFoundError, OSError, ValueError):
    print(0)
PYUSERS
)
if [[ $existing_server_env == false ]] || \
   { [[ $portal_user_count == 0 ]] && grep -q ':!browser-first-run-disabled!$' /etc/openrct2-manager/web-credentials; }; then
  if [[ $existing_server_env == true ]]; then
    WEB_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')
  fi
  printf '%s\n' "$WEB_PASSWORD" | runuser -u openrct2 -- /usr/bin/python3 /usr/local/lib/openrct2-manager.py --init-setup-token
  setup_token_issued=true
fi
runuser -u openrct2 -- /usr/bin/python3 /usr/local/lib/openrct2-manager.py --setup

cat > /etc/systemd/system/openrct2-manager.service <<'SERVICE'
[Unit]
Description=OpenRCT2 web manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openrct2
Group=openrct2
ExecStart=/usr/bin/python3 /usr/local/lib/openrct2-manager.py
Restart=on-failure
RestartSec=3s
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/openrct2-manager
ReadWritePaths=/var/lib/openrct2 /var/lib/openrct2-manager
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
SERVICE

cat > /etc/systemd/system/openrct2-manager-prune.service <<'SERVICE'
[Unit]
Description=Remove old OpenRCT2 manager snapshots

[Service]
Type=oneshot
User=openrct2
Group=openrct2
ExecStart=/usr/bin/python3 /usr/local/lib/openrct2-manager.py --prune
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/openrct2-manager
ReadWritePaths=/var/lib/openrct2 /var/lib/openrct2-manager
NoNewPrivileges=true
SERVICE

cat > /etc/systemd/system/openrct2-manager-prune.timer <<'TIMER'
[Unit]
Description=Check OpenRCT2 manager snapshot retention

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

cat > /etc/sudoers.d/openrct2-manager <<'SUDOERS'
openrct2 ALL=(root) NOPASSWD: /usr/bin/systemctl start openrct2.service
openrct2 ALL=(root) NOPASSWD: /usr/bin/systemctl stop openrct2.service
openrct2 ALL=(root) NOPASSWD: /usr/bin/systemctl restart openrct2.service
openrct2 ALL=(root) NOPASSWD: /usr/local/sbin/openrct2-backup
SUDOERS
chmod 0440 /etc/sudoers.d/openrct2-manager
visudo -cf /etc/sudoers.d/openrct2-manager >/dev/null

if [[ -n $MANAGER_DOMAIN ]]; then
  echo "Installing Caddy for automatic HTTPS on $MANAGER_DOMAIN..."
  apt-get install -y --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https gnupg
  curl -1fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
    gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    -o /etc/apt/sources.list.d/caddy-stable.list
  chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y --no-install-recommends caddy
  cat > /etc/caddy/Caddyfile <<EOF
# Managed by OpenRCT2 Manager
${MANAGER_DOMAIN} {
    encode gzip
    reverse_proxy 127.0.0.1:${WEB_PORT}
}
EOF
  caddy validate --config /etc/caddy/Caddyfile >/dev/null
  systemctl enable --now caddy.service >/dev/null
  systemctl reload caddy.service
fi

systemctl daemon-reload
systemctl enable openrct2.service openrct2-manager.service openrct2-manager-prune.timer >/dev/null
systemctl start openrct2-manager-prune.timer
systemctl restart openrct2-manager.service
if systemctl is-active --quiet openrct2.service; then
  echo "Game service left running. Restart it from the panel when safe to activate player tracking, blocking, and snapshots."
fi

host=${PUBLIC_ADDRESS:-SERVER_PUBLIC_IP}
if [[ -n $MANAGER_DOMAIN ]]; then
  web_url="https://${MANAGER_DOMAIN}/"
elif [[ $WEB_BIND == 127.0.0.1 ]]; then
  web_url="http://127.0.0.1:${WEB_PORT}/ (from server or SSH tunnel)"
else
  web_url="http://${host}:${WEB_PORT}/"
fi

cat <<EOF

============================================================
 OpenRCT2 Server Manager is ready
============================================================

Server address: ${host}
Game address:   ${host}:${GAME_PORT}
Web setup:      ${web_url}

NEXT STEP 1 - Allow players through your firewall
  Cloud server (${CLOUD_PROVIDER}): open inbound TCP ${GAME_PORT} in the
  provider firewall/security group. Do not open UDP for OpenRCT2.
EOF
if [[ $CLOUD_PROVIDER == 'Amazon Web Services' ]]; then
  cat <<EOF
  AWS Lightsail: instance > Networking > IPv4 Firewall > Add rule >
  Custom, TCP, port ${GAME_PORT}. Restrict source addresses when practical.
  AWS EC2: add the same TCP port to the instance security group's inbound rules.
EOF
else
  cat <<EOF
  Other VPS: look for Firewall, Network, Security Group or Inbound Rules.
  Home server: forward TCP ${GAME_PORT} on your router to this machine's private
  LAN address, and allow TCP ${GAME_PORT} in the machine's own firewall.
EOF
fi
cat <<EOF

  Never expose TCP ${CONTROL_PORT}; it is a localhost-only control bridge.
  Keep TCP ${WEB_PORT} private unless it is protected by HTTPS.

NEXT STEP 2 - Open the web setup
EOF
if [[ -n $MANAGER_DOMAIN ]]; then
  echo "  - Open TCP 80 and 443 for HTTPS certificate issuance and web access."
  echo "  - Keep TCP ${WEB_PORT} closed externally; Caddy reaches it over localhost."
  echo "  - Point the DNS A/AAAA record for ${MANAGER_DOMAIN} at this server."
else
  if [[ $WEB_BIND == 127.0.0.1 ]]; then
    echo "  On your own computer, run:"
    echo "    ssh -L ${WEB_PORT}:127.0.0.1:${WEB_PORT} ubuntu@${host}"
    echo "  Keep that window open, then visit http://127.0.0.1:${WEB_PORT}/"
    echo "  Later, the browser guide can help you add a domain and HTTPS."
  else
    echo "  - Open TCP ${WEB_PORT} from YOUR IP ONLY (never from 0.0.0.0/0)."
    echo "  - HTTP Basic authentication is not encrypted without HTTPS; use a domain with MANAGER_DOMAIN or an SSH tunnel."
  fi
fi

if [[ $setup_token_issued == true ]]; then
  echo
  echo "NEXT STEP 3 - Create the first Owner"
  echo "  Suggested username: ${WEB_USER}"
  echo "  One-time setup password: ${WEB_PASSWORD}"
  echo "  Enter it in the browser guide and choose your permanent portal password."
  echo "  This one-time password stops working as soon as setup finishes."
elif [[ $generated_password == true || $existing_password == false ]]; then
  echo "Initial portal password: ${WEB_PASSWORD}"
  echo "Save this password now; it is stored in /etc/openrct2-manager/web-credentials."
else
  echo "Existing web password retained (not printed)."
fi
