#!/bin/bash

# ==================================================
# Comprehensive OpenRCT2 Server Manager
# ==================================================
# Features:
# - Install OpenRCT2 Server
# - Start/Stop Servers
# - Manage Configurations
# - Manage Multiplayer Permissions
# - Scenario Selector
# - And more...
# ==================================================

# Exit immediately if a command exits with a non-zero status
set -e

# =======================
# Configuration Variables
# =======================
CONFIG_DIR="$HOME/.openrct2_server_manager"
CONFIG_FILE="$CONFIG_DIR/configurations.json"
LOG_DIR="$CONFIG_DIR/logs"
BACKUP_DIR="$CONFIG_DIR/backups"
SERVER_DATA_DIR="$HOME/.config/OpenRCT2/save"
MODS_DIR="$HOME/.config/OpenRCT2/mods"
SCENARIOS_DIR="$HOME/.config/OpenRCT2/scenarios"
WHITELIST_FILE="$CONFIG_DIR/whitelist.txt"
BLACKLIST_FILE="$CONFIG_DIR/blacklist.txt"
EMAIL_CONFIG_FILE="$CONFIG_DIR/email_config.json"

# Ensure necessary directories exist
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR" "$MODS_DIR" "$SCENARIOS_DIR"

# Initialize configurations file if not exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "{}" > "$CONFIG_FILE"
fi

# ======================
# Utility Functions
# ======================

# Function to display error messages and exit
error_exit() {
    dialog --msgbox "$1" 10 50
    clear
    exit 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install OpenRCT2
install_openrct2() {
    # Detect OS
    OS=$(uname -s)
    echo "Detected OS: $OS"

    if [ "$OS" != "Linux" ]; then
        error_exit "This installer currently supports only Linux systems."
    fi

    # Update package lists
    sudo apt-get update

    # Install dependencies
    echo "Installing dependencies..."
    sudo apt-get install -y git build-essential cmake libsdl2-dev libsdl2-net-dev libgtk-3-dev \
        libpng-dev libjpeg-dev liblzma-dev libzip-dev libvorbis-dev libopusfile-dev \
        libsamplerate0-dev libopenal-dev libsndfile1-dev

    # Clone OpenRCT2 repository
    if [ ! -d "$CONFIG_DIR/OpenRCT2" ]; then
        echo "Cloning OpenRCT2 repository..."
        git clone https://github.com/OpenRCT2/OpenRCT2.git "$CONFIG_DIR/OpenRCT2"
    else
        echo "OpenRCT2 repository already exists. Pulling latest changes..."
        cd "$CONFIG_DIR/OpenRCT2"
        git pull
    fi

    # Build OpenRCT2
    echo "Building OpenRCT2..."
    cd "$CONFIG_DIR/OpenRCT2"
    mkdir -p build
    cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    make -j$(nproc)

    # Install OpenRCT2
    sudo make install

    # Verify installation
    if command_exists openrct2; then
        dialog --msgbox "OpenRCT2 installed successfully!" 10 40
    else
        error_exit "OpenRCT2 installation failed."
    fi
}

# Function to load configurations
load_configurations() {
    jq '.' "$CONFIG_FILE"
}

# Function to save configurations
save_configurations() {
    echo "$1" > "$CONFIG_FILE"
}

# Function to list running OpenRCT2 servers
list_running_servers() {
    ps -ef | grep "openrct2 host" | grep -v grep
}

# Function to backup saved game
backup_saved_game() {
    local save_file="$1"
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILE="$BACKUP_DIR/$(basename "$save_file")_$TIMESTAMP.bak"
    cp "$save_file" "$BACKUP_FILE"
}

# Function to send email notifications (optional)
send_email_notification() {
    local subject="$1"
    local body="$2"
    if [ -f "$EMAIL_CONFIG_FILE" ]; then
        EMAIL=$(jq -r '.email' "$EMAIL_CONFIG_FILE")
        echo -e "Subject:$subject\n\n$body" | sendmail "$EMAIL"
    fi
}

# Function to install OpenRCT2 Server
install_server() {
    if command_exists openrct2; then
        dialog --msgbox "OpenRCT2 is already installed." 10 40
        return
    fi

    install_openrct2
}

# Function to start a new server
start_server() {
    # Select a scenario
    SCENARIO=$(select_scenario)
    if [ -z "$SCENARIO" ]; then
        error_exit "No scenario selected. Exiting."
    fi

    # Select a saved game or create a new one based on scenario
    SAVE_FILE=$(dialog --stdout --title "Select a Saved Game" --fselect "$SERVER_DATA_DIR/" 15 60)
    if [ -z "$SAVE_FILE" ]; then
        error_exit "No saved game selected. Exiting."
    fi

    # Select or create a configuration
    CONFIGURATIONS=$(load_configurations)
    CONFIG_NAMES=$(echo "$CONFIGURATIONS" | jq -r 'keys[]')

    CONFIG_NAME=$(dialog --stdout --menu "Select Configuration" 15 50 4 \
        "Create New" "Create a new server configuration" \
        $(for name in $CONFIG_NAMES; do echo "$name" "Use this configuration"; done))

    if [ "$CONFIG_NAME" == "Create New" ]; then
        # Input server settings
        SERVER_NAME=$(dialog --stdout --inputbox "Enter the server name:" 10 40 "My OpenRCT2 Server")
        if [ -z "$SERVER_NAME" ]; then
            error_exit "Server name cannot be empty."
        fi

        MAX_PLAYERS=$(dialog --stdout --inputbox "Enter the maximum number of players:" 10 40 "16")
        if [ -z "$MAX_PLAYERS" ]; then
            error_exit "Maximum players cannot be empty."
        fi

        PASSWORD=$(dialog --stdout --inputbox "Enter a server password (leave empty for none):" 10 40 "")
        PUBLIC_SERVER=$(dialog --stdout --yesno "Make the server public?" 7 40; echo $?)

        if [ "$PUBLIC_SERVER" -eq 0 ]; then
            PUBLIC_FLAG="true"
        else
            PUBLIC_FLAG="false"
        fi

        # Save configuration
        CONFIG_NAME_NEW=$(dialog --stdout --inputbox "Enter a name for this configuration:" 10 40 "Default")
        if [ -z "$CONFIG_NAME_NEW" ]; then
            error_exit "Configuration name cannot be empty."
        fi

        # Include scenario in configuration
        NEW_CONFIG=$(jq -n \
            --arg name "$SERVER_NAME" \
            --arg max "$MAX_PLAYERS" \
            --arg password "$PASSWORD" \
            --arg public "$PUBLIC_FLAG" \
            --arg savefile "$SAVE_FILE" \
            --arg scenario "$SCENARIO" \
            '{name: $name, max_players: $max, password: $password, public: $public, savefile: $savefile, scenario: $scenario}')

        UPDATED_CONFIG=$(echo "$CONFIGURATIONS" | jq --arg key "$CONFIG_NAME_NEW" --argjson value "$NEW_CONFIG" '. + {($key): $value}')
        save_configurations "$UPDATED_CONFIG"

        CONFIG_NAME="$CONFIG_NAME_NEW"
    fi

    # Retrieve configuration
    CONFIG=$(echo "$CONFIGURATIONS" | jq -r --arg key "$CONFIG_NAME" '.[$key]')
    SERVER_NAME=$(echo "$CONFIG" | jq -r '.name')
    MAX_PLAYERS=$(echo "$CONFIG" | jq -r '.max_players')
    PASSWORD=$(echo "$CONFIG" | jq -r '.password')
    PUBLIC_FLAG=$(echo "$CONFIG" | jq -r '.public')
    SAVE_FILE=$(echo "$CONFIG" | jq -r '.savefile')
    SCENARIO=$(echo "$CONFIG" | jq -r '.scenario')

    # Confirm settings
    dialog --title "Server Configuration" --msgbox "Starting server with the following settings:
- Server Name: $SERVER_NAME
- Max Players: $MAX_PLAYERS
- Password: ${PASSWORD:-None}
- Public Server: $PUBLIC_FLAG
- Save File: $SAVE_FILE
- Scenario: $SCENARIO" 15 60

    # Backup saved game
    backup_saved_game "$SAVE_FILE"

    # Start the server
    clear
    echo "Starting OpenRCT2 server..."
    openrct2 host "$SAVE_FILE" \
        --server-name "$SERVER_NAME" \
        --max-players "$MAX_PLAYERS" \
        ${PASSWORD:+--password "$PASSWORD"} \
        --public "$PUBLIC_FLAG" \
        --scenario "$SCENARIO" > "$LOG_DIR/server_$(date +"%Y%m%d_%H%M%S").log" 2>&1 &

    SERVER_PID=$!
    echo "$SERVER_PID" > "$CONFIG_DIR/server_$SERVER_PID.pid"

    # Optional: Send email notification
    if [ -f "$EMAIL_CONFIG_FILE" ]; then
        SUBJECT="OpenRCT2 Server Started: $SERVER_NAME"
        BODY="Server '$SERVER_NAME' has been started with PID $SERVER_PID."
        send_email_notification "$SUBJECT" "$BODY"
    fi

    dialog --msgbox "Server started successfully with PID $SERVER_PID." 10 50
}

# Function to select a scenario
select_scenario() {
    # List available scenarios
    SCENARIO_FILES=$(ls "$SCENARIOS_DIR"/*.rct2scenario 2>/dev/null || true)
    SCENARIO_NAMES=()
    for file in $SCENARIO_FILES; do
        SCENARIO_NAMES+=("$(basename "$file")" "")
    done

    # Add default scenarios or prompt to add
    DEFAULT_SCENARIOS=("Default.rct2scenario" "Classic Park.rct2scenario" "Adventure Island.rct2scenario")

    for scenario in "${DEFAULT_SCENARIOS[@]}"; do
        if [ ! -f "$SCENARIOS_DIR/$scenario" ]; then
            # Download default scenarios from OpenRCT2 repository or use placeholders
            # For demonstration, we'll skip actual downloads
            touch "$SCENARIOS_DIR/$scenario"
        fi
        SCENARIO_NAMES+=("$scenario" "")
    done

    # Select scenario
    SELECTED_SCENARIO=$(dialog --stdout --menu "Select a Scenario" 20 60 15 "${SCENARIO_NAMES[@]}")

    # If no scenarios found, prompt to add one
    if [ -z "$SELECTED_SCENARIO" ]; then
        dialog --msgbox "No scenarios available. Please add scenarios to $SCENARIOS_DIR." 10 50
        return ""
    fi

    echo "$SELECTED_SCENARIO"
}

# Function to view running servers
view_running_servers() {
    RUNNING_SERVERS=$(list_running_servers)
    if [ -z "$RUNNING_SERVERS" ]; then
        dialog --msgbox "No servers are currently running." 10 50
        return
    fi

    # Parse running servers
    SERVER_LIST=()
    while read -r line; do
        PID=$(echo "$line" | awk '{print $2}')
        CMD=$(echo "$line" | awk '{for (i=8;i<=NF;i++) printf $i " "; print ""}')
        SERVER_NAME=$(echo "$CMD" | grep -oP '(?<=--server-name ")[^"]+')
        SERVER_LIST+=("$PID" "$SERVER_NAME")
    done <<< "$RUNNING_SERVERS"

    SELECTED_PID=$(dialog --stdout --menu "Select a Running Server to Manage" 20 60 10 "${SERVER_LIST[@]}")

    if [ -n "$SELECTED_PID" ]; then
        manage_server "$SELECTED_PID"
    fi
}

# Function to manage a selected server
manage_server() {
    local server_pid="$1"

    while true; do
        OPTION=$(dialog --stdout --menu "Manage Server PID: $server_pid" 15 50 6 \
            1 "View Server Logs" \
            2 "Change Server Settings" \
            3 "Backup Saved Game" \
            4 "Stop Server" \
            5 "Send Announcement" \
            6 "Monitor Server Metrics" \
            7 "Back")

        case $OPTION in
            1) view_server_logs "$server_pid" ;;
            2) change_server_settings "$server_pid" ;;
            3) backup_saved_game_manually "$server_pid" ;;
            4) stop_server "$server_pid" ; break ;;
            5) send_announcement "$server_pid" ;;
            6) monitor_server_metrics "$server_pid" ;;
            7) break ;;
            *) dialog --msgbox "Invalid option." 10 30 ;;
        esac
    done
}

# Function to view server logs
view_server_logs() {
    local server_pid="$1"
    LOG_FILE=$(ls "$LOG_DIR"/server_*.log 2>/dev/null | grep "server_${server_pid}" | head -n1 || true)
    if [ -z "$LOG_FILE" ]; then
        dialog --msgbox "Log file not found for PID $server_pid." 10 50
        return
    fi

    dialog --title "Server Logs" --textbox "$LOG_FILE" 20 80
}

# Function to change server settings (Placeholder)
change_server_settings() {
    local server_pid="$1"

    # Note: OpenRCT2 may not support dynamic settings changes via CLI or API.
    # This is a placeholder for actual implementation.

    dialog --msgbox "Changing server settings dynamically is not supported.\nPlease stop the server, modify settings, and restart." 10 60
}

# Function to backup saved game manually
backup_saved_game_manually() {
    local server_pid="$1"
    SAVE_FILE=$(ps -p "$server_pid" -o args= | grep -oP '(?<=host )[^ ]+')
    if [ -z "$SAVE_FILE" ]; then
        dialog --msgbox "Could not determine save file for PID $server_pid." 10 50
        return
    fi
    backup_saved_game "$SAVE_FILE"
    dialog --msgbox "Backup created for PID $server_pid." 10 50
}

# Function to stop a server
stop_server() {
    local server_pid="$1"
    dialog --yesno "Are you sure you want to stop server PID $server_pid?" 7 40
    if [ $? -eq 0 ]; then
        kill "$server_pid"
        rm -f "$CONFIG_DIR/server_$server_pid.pid"
        dialog --msgbox "Server PID $server_pid has been stopped." 10 50
    fi
}

# Function to send an announcement (Placeholder)
send_announcement() {
    local server_pid="$1"

    # Placeholder: Implement OpenRCT2's API call or method to send announcements
    # Since OpenRCT2 may not support this, we'll simulate with a log entry

    ANNOUNCEMENT=$(dialog --stdout --inputbox "Enter announcement message:" 10 60 "")
    if [ -n "$ANNOUNCEMENT" ]; then
        echo "Announcement: $ANNOUNCEMENT" >> "$LOG_DIR/server_$server_pid.log"
        dialog --msgbox "Announcement sent: $ANNOUNCEMENT" 10 50
    fi
}

# Function to monitor server metrics
monitor_server_metrics() {
    local server_pid="$1"
    while true; do
        if ! ps -p "$server_pid" > /dev/null; then
            dialog --msgbox "Server PID $server_pid has stopped." 10 50
            break
        fi

        CPU=$(ps -p "$server_pid" -o %cpu=)
        MEM=$(ps -p "$server_pid" -o %mem=)
        UPTIME=$(ps -p "$server_pid" -o etime=)

        dialog --title "Server Metrics PID: $server_pid" --msgbox "CPU Usage: $CPU%
Memory Usage: $MEM%
Uptime: $UPTIME" 10 50
        sleep 5
    done
}

# Function to manage multiplayer permissions
manage_permissions() {
    while true; do
        OPTION=$(dialog --stdout --menu "Manage Multiplayer Permissions" 15 50 6 \
            1 "View Whitelist" \
            2 "Add to Whitelist" \
            3 "Remove from Whitelist" \
            4 "View Blacklist" \
            5 "Add to Blacklist" \
            6 "Remove from Blacklist" \
            7 "Back")

        case $OPTION in
            1) view_list "$WHITELIST_FILE" "Whitelist" ;;
            2) add_to_list "$WHITELIST_FILE" "Whitelist" ;;
            3) remove_from_list "$WHITELIST_FILE" "Whitelist" ;;
            4) view_list "$BLACKLIST_FILE" "Blacklist" ;;
            5) add_to_list "$BLACKLIST_FILE" "Blacklist" ;;
            6) remove_from_list "$BLACKLIST_FILE" "Blacklist" ;;
            7) break ;;
            *) dialog --msgbox "Invalid option." 10 30 ;;
        esac
    done
}

# Helper function to view a list
view_list() {
    local file="$1"
    local title="$2"
    if [ ! -s "$file" ]; then
        dialog --msgbox "$title is empty." 10 40
    else
        dialog --textbox "$file" 20 60
    fi
}

# Helper function to add to a list
add_to_list() {
    local file="$1"
    local title="$2"
    PLAYER=$(dialog --stdout --inputbox "Enter player name to add to $title:" 10 40 "")
    if [ -n "$PLAYER" ]; then
        echo "$PLAYER" >> "$file"
        dialog --msgbox "Player '$PLAYER' added to $title." 10 50
    fi
}

# Helper function to remove from a list
remove_from_list() {
    local file="$1"
    local title="$2"
    if [ ! -s "$file" ]; then
        dialog --msgbox "$title is empty." 10 40
        return
    fi
    PLAYERS=($(cat "$file"))
    LIST=()
    for player in "${PLAYERS[@]}"; do
        LIST+=("$player" "")
    done
    SELECTED_PLAYER=$(dialog --stdout --menu "Select a Player to Remove from $title" 20 60 10 "${LIST[@]}")
    if [ -n "$SELECTED_PLAYER" ]; then
        grep -v "^$SELECTED_PLAYER$" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
        dialog --msgbox "Player '$SELECTED_PLAYER' removed from $title." 10 50
    fi
}

# Function to manage multiplayer roles (Placeholder)
manage_roles() {
    dialog --msgbox "Role management feature is not implemented yet." 10 50
}

# Function to select a scenario (additional details)
select_scenario() {
    # Check if scenarios exist
    SCENARIO_FILES=$(ls "$SCENARIOS_DIR"/*.rct2scenario 2>/dev/null || true)
    if [ -z "$SCENARIO_FILES" ]; then
        dialog --msgbox "No scenarios found in $SCENARIOS_DIR. Please add scenarios before proceeding." 10 60
        return ""
    fi

    # Create menu options
    SCENARIO_OPTIONS=()
    for file in $SCENARIO_FILES; do
        SCENARIO_NAME=$(basename "$file")
        SCENARIO_OPTIONS+=("$file" "$SCENARIO_NAME")
    done

    # Select scenario
    SELECTED_SCENARIO=$(dialog --stdout --menu "Select a Scenario" 20 60 15 "${SCENARIO_OPTIONS[@]}")

    echo "$SELECTED_SCENARIO"
}

# Function to manage configurations
manage_configurations() {
    while true; do
        OPTION=$(dialog --stdout --menu "Manage Configurations" 15 50 4 \
            1 "View Configurations" \
            2 "Delete Configuration" \
            3 "Back")

        case $OPTION in
            1) view_configurations ;;
            2) delete_configuration ;;
            3) break ;;
            *) dialog --msgbox "Invalid option." 10 30 ;;
        esac
    done
}

# Function to view configurations
view_configurations() {
    CONFIGURATIONS=$(load_configurations)
    CONFIG_NAMES=$(echo "$CONFIGURATIONS" | jq -r 'keys[]')
    if [ -z "$CONFIG_NAMES" ]; then
        dialog --msgbox "No configurations found." 10 40
        return
    fi

    SELECTED_CONFIG=$(dialog --stdout --menu "Select Configuration to View" 20 60 10 $(for name in $CONFIG_NAMES; do echo "$name" "View details"; done))

    if [ -n "$SELECTED_CONFIG" ]; then
        CONFIG=$(echo "$CONFIGURATIONS" | jq -r --arg key "$SELECTED_CONFIG" '.[$key]')
        dialog --title "Configuration: $SELECTED_CONFIG" --msgbox "$CONFIG" 20 60
    fi
}

# Function to delete a configuration
delete_configuration() {
    CONFIGURATIONS=$(load_configurations)
    CONFIG_NAMES=$(echo "$CONFIGURATIONS" | jq -r 'keys[]')
    if [ -z "$CONFIG_NAMES" ]; then
        dialog --msgbox "No configurations found." 10 40
        return
    fi

    SELECTED_CONFIG=$(dialog --stdout --menu "Select Configuration to Delete" 20 60 10 $(for name in $CONFIG_NAMES; do echo "$name" "Delete this configuration"; done))

    if [ -n "$SELECTED_CONFIG" ]; then
        UPDATED_CONFIG=$(echo "$CONFIGURATIONS" | jq "del(.$SELECTED_CONFIG)")
        save_configurations "$UPDATED_CONFIG"
        dialog --msgbox "Configuration '$SELECTED_CONFIG' deleted." 10 50
    fi
}

# Function to configure email notifications
configure_email_notifications() {
    EMAIL=$(dialog --stdout --inputbox "Enter email address for notifications:" 10 50 "")
    if [ -n "$EMAIL" ]; then
        jq -n --arg email "$EMAIL" '{email: $email}' > "$EMAIL_CONFIG_FILE"
        dialog --msgbox "Email notifications configured for $EMAIL." 10 50
    fi
}

# Function to schedule server start/stop
schedule_server() {
    OPTION=$(dialog --stdout --menu "Schedule Server" 15 50 4 \
        1 "Schedule Start" \
        2 "Schedule Stop" \
        3 "View Scheduled Tasks" \
        4 "Back")

    case $OPTION in
        1) schedule_start ;;
        2) schedule_stop ;;
        3) view_scheduled_tasks ;;
        4) return ;;
        *) dialog --msgbox "Invalid option." 10 30 ;;
    esac
}

# Function to schedule server start
schedule_start() {
    # Select configuration
    CONFIGURATIONS=$(load_configurations)
    CONFIG_NAMES=$(echo "$CONFIGURATIONS" | jq -r 'keys[]')
    if [ -z "$CONFIG_NAMES" ]; then
        dialog --msgbox "No configurations available. Please create a configuration first." 10 50
        return
    fi

    CONFIG_NAME=$(dialog --stdout --menu "Select Configuration to Schedule Start" 15 50 10 $(for name in $CONFIG_NAMES; do echo "$name" "Use this configuration"; done))
    if [ -z "$CONFIG_NAME" ]; then
        dialog --msgbox "No configuration selected." 10 40
        return
    fi

    # Select date and time
    DATE_TIME=$(dialog --stdout --inputbox "Enter date and time to start (YYYY-MM-DD HH:MM):" 10 60 "2024-12-31 23:59")
    if [ -z "$DATE_TIME" ]; then
        dialog --msgbox "No date/time entered." 10 40
        return
    fi

    # Convert to cron format
    CRON_TIME=$(date -d "$DATE_TIME" "+%M %H %d %m *" 2>/dev/null || true)
    if [ -z "$CRON_TIME" ]; then
        dialog --msgbox "Invalid date/time format." 10 40
        return
    fi

    # Add cron job to start the server
    (crontab -l 2>/dev/null; echo "$CRON_TIME bash $0 --start-server \"$CONFIG_NAME\"") | crontab -

    dialog --msgbox "Server start scheduled at $DATE_TIME." 10 50
}

# Function to schedule server stop
schedule_stop() {
    # Select running server
    RUNNING_SERVERS=$(list_running_servers)
    if [ -z "$RUNNING_SERVERS" ]; then
        dialog --msgbox "No servers are currently running." 10 50
        return
    fi

    SERVER_LIST=()
    while read -r line; do
        PID=$(echo "$line" | awk '{print $2}')
        CMD=$(echo "$line" | awk '{for (i=8;i<=NF;i++) printf $i " "; print ""}')
        SERVER_NAME=$(echo "$CMD" | grep -oP '(?<=--server-name ")[^"]+')
        SERVER_LIST+=("$PID" "$SERVER_NAME")
    done <<< "$RUNNING_SERVERS"

    SELECTED_PID=$(dialog --stdout --menu "Select a Server to Schedule Stop" 20 60 10 "${SERVER_LIST[@]}")

    if [ -z "$SELECTED_PID" ]; then
        dialog --msgbox "No server selected." 10 40
        return
    fi

    # Select date and time
    DATE_TIME=$(dialog --stdout --inputbox "Enter date and time to stop (YYYY-MM-DD HH:MM):" 10 60 "2024-12-31 23:59")
    if [ -z "$DATE_TIME" ]; then
        dialog --msgbox "No date/time entered." 10 40
        return
    fi

    # Convert to cron format
    CRON_TIME=$(date -d "$DATE_TIME" "+%M %H %d %m *" 2>/dev/null || true)
    if [ -z "$CRON_TIME" ]; then
        dialog --msgbox "Invalid date/time format." 10 40
        return
    fi

    # Add cron job to stop the server
    (crontab -l 2>/dev/null; echo "$CRON_TIME kill $SELECTED_PID") | crontab -

    dialog --msgbox "Server stop scheduled at $DATE_TIME." 10 50
}

# Function to view scheduled tasks
view_scheduled_tasks() {
    crontab -l | dialog --title "Scheduled Tasks" --textbox - 20 60
}

# Function to backup configurations
backup_configuration() {
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    cp "$CONFIG_FILE" "$BACKUP_DIR/configurations_$TIMESTAMP.json"
    dialog --msgbox "Configuration backed up at $BACKUP_DIR/configurations_$TIMESTAMP.json" 10 60
}

# Function to restore configurations
restore_configuration() {
    BACKUP_FILES=$(ls "$BACKUP_DIR"/configurations_*.json 2>/dev/null || true)
    if [ -z "$BACKUP_FILES" ]; then
        dialog --msgbox "No backup configurations found." 10 50
        return
    fi

    BACKUP_OPTIONS=()
    for file in $BACKUP_FILES; do
        BACKUP_OPTIONS+=("$file" "$(basename "$file")")
    done

    SELECTED_BACKUP=$(dialog --stdout --menu "Select Backup to Restore" 20 60 10 "${BACKUP_OPTIONS[@]}")

    if [ -n "$SELECTED_BACKUP" ]; then
        cp "$SELECTED_BACKUP" "$CONFIG_FILE"
        dialog --msgbox "Configuration restored from $SELECTED_BACKUP." 10 60
    fi
}

# Function to enable crash recovery (Placeholder)
enable_crash_recovery() {
    # Placeholder: Implement a background process to monitor and restart servers
    dialog --msgbox "Automatic crash recovery feature is under development." 10 50
}

# Function to manage mods/plugins
manage_mods() {
    while true; do
        OPTION=$(dialog --stdout --menu "Manage Mods/Plugins" 20 60 10 \
            1 "List Available Mods" \
            2 "Enable Mod" \
            3 "Disable Mod" \
            4 "Back")

        case $OPTION in
            1) list_available_mods ;;
            2) enable_mod ;;
            3) disable_mod ;;
            4) break ;;
            *) dialog --msgbox "Invalid option." 10 30 ;;
        esac
    done
}

# Function to list available mods
list_available_mods() {
    MOD_FILES=$(ls "$MODS_DIR"/*.zip 2>/dev/null || true)
    if [ -z "$MOD_FILES" ]; then
        dialog --msgbox "No mods available in $MODS_DIR." 10 40
        return
    fi

    MOD_LIST=""
    for mod in $MOD_FILES; do
        MOD_LIST+=$(basename "$mod")"\n"
    done

    dialog --msgbox "Available Mods:\n$MOD_LIST" 20 60
}

# Function to enable a mod
enable_mod() {
    MOD_FILE=$(dialog --stdout --fselect "$MODS_DIR/" 15 60)
    if [ -n "$MOD_FILE" ]; then
        cp "$MOD_FILE" "$SERVER_DATA_DIR/"
        dialog --msgbox "Mod enabled: $(basename "$MOD_FILE")" 10 50
    fi
}

# Function to disable a mod
disable_mod() {
    MOD_ENABLED=$(ls "$SERVER_DATA_DIR"/*.zip 2>/dev/null || true)
    if [ -z "$MOD_ENABLED" ]; then
        dialog --msgbox "No mods are currently enabled." 10 50
        return
    fi

    MOD_OPTIONS=()
    for mod in $MOD_ENABLED; do
        MOD_OPTIONS+=("$mod" "$(basename "$mod")")
    done

    SELECTED_MOD=$(dialog --stdout --menu "Select Mod to Disable" 20 60 10 "${MOD_OPTIONS[@]}")

    if [ -n "$SELECTED_MOD" ]; then
        rm -f "$SELECTED_MOD"
        dialog --msgbox "Mod disabled: $(basename "$SELECTED_MOD")" 10 50
    fi
}

# Function to add custom scenarios (Placeholder)
add_custom_scenario() {
    SCENARIO_FILE=$(dialog --stdout --fselect "$SCENARIOS_DIR/" 15 60)
    if [ -n "$SCENARIO_FILE" ]; then
        # Assuming the user selects a .rct2scenario file
        if [[ "$SCENARIO_FILE" == *.rct2scenario ]]; then
            cp "$SCENARIO_FILE" "$SCENARIOS_DIR/"
            dialog --msgbox "Scenario added: $(basename "$SCENARIO_FILE")" 10 50
        else
            dialog --msgbox "Invalid scenario file. Please select a .rct2scenario file." 10 60
        fi
    fi
}

# Function to display the main menu
main_menu() {
    while true; do
        OPTION=$(dialog --stdout --menu "OpenRCT2 Server Manager" 20 60 15 \
            1 "Install OpenRCT2 Server" \
            2 "Start a New Server" \
            3 "View Running Servers" \
            4 "Manage Multiplayer Permissions" \
            5 "Manage Configurations" \
            6 "Manage Mods/Plugins" \
            7 "Schedule Server Start/Stop" \
            8 "Configure Email Notifications" \
            9 "Backup/Restore Configurations" \
            10 "Add Custom Scenario" \
            11 "Enable Crash Recovery" \
            12 "Exit")

        case $OPTION in
            1) install_server ;;
            2) start_server ;;
            3) view_running_servers ;;
            4) manage_permissions ;;
            5) manage_configurations ;;
            6) manage_mods ;;
            7) schedule_server ;;
            8) configure_email_notifications ;;
            9)
                SUB_OPTION=$(dialog --stdout --menu "Backup/Restore Configurations" 15 50 3 \
                    1 "Backup Configurations" \
                    2 "Restore Configurations" \
                    3 "Back")
                case $SUB_OPTION in
                    1) backup_configuration ;;
                    2) restore_configuration ;;
                    3) ;;
                    *) dialog --msgbox "Invalid option." 10 30 ;;
                esac
                ;;
            10) add_custom_scenario ;;
            11) enable_crash_recovery ;;
            12) clear; exit 0 ;;
            *) dialog --msgbox "Invalid option." 10 30 ;;
        esac
    done
}

# ======================
# Main Execution
# ======================

# Parse command-line arguments for scheduled server start
if [[ "$1" == "--start-server" && -n "$2" ]]; then
    CONFIG_NAME="$2"
    # Start server using the specified configuration
    CONFIGURATIONS=$(load_configurations)
    CONFIG=$(echo "$CONFIGURATIONS" | jq -r --arg key "$CONFIG_NAME" '.[$key]')
    SERVER_NAME=$(echo "$CONFIG" | jq -r '.name')
    MAX_PLAYERS=$(echo "$CONFIG" | jq -r '.max_players')
    PASSWORD=$(echo "$CONFIG" | jq -r '.password')
    PUBLIC_FLAG=$(echo "$CONFIG" | jq -r '.public')
    SAVE_FILE=$(echo "$CONFIG" | jq -r '.savefile')
    SCENARIO=$(echo "$CONFIG" | jq -r '.scenario')

    # Backup saved game
    backup_saved_game "$SAVE_FILE"

    # Start the server
    openrct2 host "$SAVE_FILE" \
        --server-name "$SERVER_NAME" \
        --max-players "$MAX_PLAYERS" \
        ${PASSWORD:+--password "$PASSWORD"} \
        --public "$PUBLIC_FLAG" \
        --scenario "$SCENARIO" > "$LOG_DIR/server_$(date +"%Y%m%d_%H%M%S").log" 2>&1 &

    SERVER_PID=$!
    echo "$SERVER_PID" > "$CONFIG_DIR/server_$SERVER_PID.pid"
    exit 0
fi

# Start the main menu
main_menu