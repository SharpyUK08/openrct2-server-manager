#!/usr/bin/env bash
# Local interaction prototype only. This script never installs or changes services.
set -Eeuo pipefail

if [[ ! -t 0 ]]; then
  echo "Run this preview in an interactive terminal." >&2
  exit 2
fi

blue=$'\033[38;5;39m'; green=$'\033[38;5;42m'; dim=$'\033[2m'; bold=$'\033[1m'; reset=$'\033[0m'

ask() {
  local prompt=$1 default=$2 value
  read -r -p "${prompt} ${dim}[${default}]${reset}: " value
  printf '%s' "${value:-$default}"
}

yes_no() {
  local prompt=$1 default=$2 value
  read -r -p "${prompt} ${dim}[${default}]${reset}: " value
  value=${value:-$default}
  [[ ${value,,} == y || ${value,,} == yes ]]
}

clear
printf '%s\n' "${blue}${bold}OpenRCT2 Server Manager${reset}"
printf '%s\n\n' "Guided installer · local preview (nothing will be changed)"
printf '%s\n' "${green}✓${reset} Ubuntu 24.04 detected"
printf '%s\n' "${green}✓${reset} 38 GB free disk space"
printf '%s\n' "${green}✓${reset} TCP ports 80, 443 and 11753 available"
printf '%s\n\n' "${green}✓${reset} OpenRCT2 0.5.5 detected"

server_name=$(ask "Public server name" "My OpenRCT2 Server")
description=$(ask "Server description" "A friendly place to build together")
game_port=$(ask "Game port" "11753")
max_players=$(ask "Maximum players" "16")
if yes_no "List this server in the OpenRCT2 browser?" "Y"; then advertise=yes; else advertise=no; fi
public_address=$(ask "Advertised public address" "auto-detect")
if yes_no "Require a shared game password?" "Y"; then game_password="will be requested securely"; else game_password="none"; fi

printf '\n%s\n' "${bold}Initial portal owner${reset}"
owner_name=$(ask "Display name" "Server Owner")
owner_user=$(ask "Username" "admin")
printf '%s\n' "The real installer requests and confirms the password without echoing it."

printf '\n%s\n' "${bold}Remote backups${reset}"
if yes_no "Configure an off-server destination now?" "N"; then
  backup_type=$(ask "Destination (sftp, s3, or rclone)" "sftp")
  backup_schedule=$(ask "Schedule" "daily at 02:00")
else
  backup_type="not configured"
  backup_schedule="—"
fi

printf '\n%s\n' "${bold}Review${reset}"
printf '  %-22s %s\n' "Server name" "$server_name"
printf '  %-22s %s\n' "Description" "$description"
printf '  %-22s %s\n' "Join address" "$public_address:$game_port"
printf '  %-22s %s\n' "Player limit" "$max_players"
printf '  %-22s %s\n' "Server browser" "$advertise"
printf '  %-22s %s\n' "Game password" "$game_password"
printf '  %-22s %s (%s)\n' "Initial Owner" "$owner_name" "$owner_user"
printf '  %-22s %s · %s\n' "Remote backup" "$backup_type" "$backup_schedule"
printf '\n%s\n' "${blue}Preview complete.${reset} A production run would now ask for confirmation, install atomically,"
printf '%s\n' "run health checks, and print the portal URL plus recovery commands."
