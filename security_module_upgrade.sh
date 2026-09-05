#!/bin/bash

# Description: PiTweaks Security Event Monitor & Network Watchdog
# PERSISTENT: TRUE
# Category: Scripts

clear

# ==============================================================================
# 🛡️ PiTweaks Security Event Monitor & Network Watchdog
#
# Design goals:
#   - Portable across supported Raspberry Pi OS systems
#   - No developer-specific usernames or paths
#   - Minimal SD-card wear
#   - Runtime state stored in /run (normally tmpfs/RAM)
#   - No persistent security event database
#   - Low CPU/RAM usage
#   - systemd timer instead of cron
#   - Whiptail installation/reconfiguration interface
# ==============================================================================

set -u
set -o pipefail

MODULE_VERSION="2.0.0"

SERVICE_NAME="pitweaks-security.service"
TIMER_NAME="pitweaks-security.timer"

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
TIMER_FILE="/etc/systemd/system/$TIMER_NAME"

# ------------------------------------------------------------------------------
# 0. REQUIRE ROOT
# ------------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "❌ This security module must be installed with sudo."
    echo ""
    echo "Run:"
    echo "  sudo bash security_module_upgrade.sh"
    echo ""
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. DETERMINE REAL USER / HOME
# ------------------------------------------------------------------------------

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then

    CURRENT_USER="$SUDO_USER"
    REAL_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"

else

    CURRENT_USER="$(logname 2>/dev/null || true)"

    if [ -z "$CURRENT_USER" ]; then
        CURRENT_USER="$(whoami)"
    fi

    REAL_HOME="$(getent passwd "$CURRENT_USER" 2>/dev/null | cut -d: -f6)"

    if [ -z "$REAL_HOME" ]; then
        REAL_HOME="$HOME"
    fi
fi

if [ -z "$REAL_HOME" ] || [ ! -d "$REAL_HOME" ]; then

    echo "❌ Could not determine the PiTweaks user's home directory."
    echo ""
    exit 1
fi

INSTALL_DIR="$REAL_HOME/PiTweaks"
SEC_DIR="$INSTALL_DIR/security"

CONFIG_FILE="$SEC_DIR/security_config.env"
MONITOR_SCRIPT="$SEC_DIR/sec_monitor.sh"

STATE_DIR="/run/pitweaks-security"
EVENT_STATE="$STATE_DIR/events.state"
BW_STATE="$STATE_DIR/bandwidth.state"
LOCK_FILE="$STATE_DIR/monitor.lock"

# ------------------------------------------------------------------------------
# 2. INSTALL WHIPTAIL
# ------------------------------------------------------------------------------

if ! command -v whiptail >/dev/null 2>&1; then

    echo "📦 Whiptail is not installed."
    echo "Installing..."

    apt-get update
    apt-get install -y whiptail

    if ! command -v whiptail >/dev/null 2>&1; then
        echo "❌ Failed to install whiptail."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 3. EXISTING INSTALLATION DETECTION
# ------------------------------------------------------------------------------

EXISTING_INSTALL="N"

if [ -f "$CONFIG_FILE" ] ||
   [ -f "$MONITOR_SCRIPT" ] ||
   [ -f "$SERVICE_FILE" ] ||
   [ -f "$TIMER_FILE" ]; then

    EXISTING_INSTALL="Y"
fi

INSTALL_MODE="NEW"

if [ "$EXISTING_INSTALL" = "Y" ]; then

    ACTION=$(whiptail \
        --title "PiTweaks Security Monitor Detected" \
        --menu \
        "An existing security monitor installation was detected.

Current module version: $MODULE_VERSION

What would you like to do?" \
        16 75 4 \
        "RECONFIGURE" "Keep installation and change settings" \
        "REINSTALL" "Replace monitor and service files" \
        "STATUS" "View current installation status" \
        "CANCEL" "Exit without making changes" \
        3>&1 1>&2 2>&3)

    [ $? -ne 0 ] && exit 0

    case "$ACTION" in

        RECONFIGURE)
            INSTALL_MODE="RECONFIGURE"
            ;;

        REINSTALL)
            INSTALL_MODE="REINSTALL"
            ;;

        STATUS)

            TIMER_STATE="$(systemctl is-active "$TIMER_NAME" 2>/dev/null || true)"
            SERVICE_STATE="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"

            whiptail \
                --title "PiTweaks Security Monitor Status" \
                --msgbox \
"Installation detected.

Module version:
$MODULE_VERSION

Timer:
$TIMER_NAME
Status: ${TIMER_STATE:-unknown}

Service:
$SERVICE_NAME
Status: ${SERVICE_STATE:-unknown}

Configuration:
$CONFIG_FILE

Monitor:
$MONITOR_SCRIPT

Runtime state:
$STATE_DIR" \
                20 75

            exit 0
            ;;

        CANCEL)
            exit 0
            ;;

        *)
            exit 1
            ;;
    esac
fi

# ------------------------------------------------------------------------------
# 4. DEFAULT SETTINGS
# ------------------------------------------------------------------------------

TRACK_SSH="Y"
TRACK_SUDO="Y"
TRACK_UFW="Y"
TRACK_PIHOLE="N"
TRACK_BANDWIDTH="Y"

ENABLE_GEOIP="N"
ENABLE_DISCORD="N"

BANDWIDTH_THRESHOLD_MB="100"
DISCORD_WEBHOOK_URL=""

KEEP_SETTINGS="N"

# ------------------------------------------------------------------------------
# 5. CONFIG READER
# ------------------------------------------------------------------------------
#
# Configuration is treated as DATA.
# It is deliberately never sourced as shell code.
# ------------------------------------------------------------------------------

read_config_value() {

    local key="$1"
    local file="$2"

    [ ! -f "$file" ] && return 0

    awk -v wanted="$key" '
        $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {

            line=$0

            sub("^[[:space:]]*" wanted "[[:space:]]*=[[:space:]]*", "", line)

            if (line ~ /^".*"$/) {
                sub(/^"/, "", line)
                sub(/"$/, "", line)
            }

            print line
            exit
        }
    ' "$file" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 6. LOAD EXISTING SETTINGS
# ------------------------------------------------------------------------------

if [ "$EXISTING_INSTALL" = "Y" ] &&
   [ -f "$CONFIG_FILE" ]; then

    EXISTING_SUMMARY="An existing configuration was found.

Do you want to keep your current settings?

If you select YES:
• Existing monitoring choices are retained
• Discord settings are retained
• Bandwidth threshold is retained

You can still change them afterward."

    if whiptail \
        --title "Existing Settings Found" \
        --yesno "$EXISTING_SUMMARY" \
        16 75; then

        KEEP_SETTINGS="Y"

        TRACK_SSH="$(read_config_value TRACK_SSH "$CONFIG_FILE")"
        TRACK_SUDO="$(read_config_value TRACK_SUDO "$CONFIG_FILE")"
        TRACK_UFW="$(read_config_value TRACK_UFW "$CONFIG_FILE")"
        TRACK_PIHOLE="$(read_config_value TRACK_PIHOLE "$CONFIG_FILE")"
        TRACK_BANDWIDTH="$(read_config_value TRACK_BANDWIDTH "$CONFIG_FILE")"

        ENABLE_GEOIP="$(read_config_value ENABLE_GEOIP "$CONFIG_FILE")"
        ENABLE_DISCORD="$(read_config_value ENABLE_DISCORD "$CONFIG_FILE")"

        BANDWIDTH_THRESHOLD_MB="$(read_config_value BANDWIDTH_THRESHOLD_MB "$CONFIG_FILE")"
        DISCORD_WEBHOOK_URL="$(read_config_value DISCORD_WEBHOOK_URL "$CONFIG_FILE")"

        TRACK_SSH="${TRACK_SSH:-Y}"
        TRACK_SUDO="${TRACK_SUDO:-Y}"
        TRACK_UFW="${TRACK_UFW:-Y}"
        TRACK_PIHOLE="${TRACK_PIHOLE:-N}"
        TRACK_BANDWIDTH="${TRACK_BANDWIDTH:-Y}"

        ENABLE_GEOIP="${ENABLE_GEOIP:-N}"
        ENABLE_DISCORD="${ENABLE_DISCORD:-N}"

        BANDWIDTH_THRESHOLD_MB="${BANDWIDTH_THRESHOLD_MB:-100}"
        DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

    fi
fi

# ------------------------------------------------------------------------------
# 7. MAIN FEATURE SELECTION
# ------------------------------------------------------------------------------

CHOICES=$(whiptail \
    --title "PiTweaks Security Monitor - Features" \
    --checklist \
"Select the security monitoring features you want.

SPACE = toggle
ENTER = continue

Only selected features will be monitored." \
    23 90 7 \
    "SSH" \
    "SSH login monitoring - failed and successful logins" \
    "$([ "$TRACK_SSH" = "Y" ] && echo ON || echo OFF)" \
    "SUDO" \
    "Sudo activity - records privileged command activity" \
    "$([ "$TRACK_SUDO" = "Y" ] && echo ON || echo OFF)" \
    "UFW" \
    "UFW blocks - detects connections rejected by UFW" \
    "$([ "$TRACK_UFW" = "Y" ] && echo ON || echo OFF)" \
    "PIHOLE" \
    "Pi-hole activity - checks compatible web/admin logs" \
    "$([ "$TRACK_PIHOLE" = "Y" ] && echo ON || echo OFF)" \
    "BANDWIDTH" \
    "Bandwidth anomaly - detects unusually high traffic rates" \
    "$([ "$TRACK_BANDWIDTH" = "Y" ] && echo ON || echo OFF)" \
    "GEOIP" \
    "OPTIONAL - adds approximate IP country/ISP information" \
    "$([ "$ENABLE_GEOIP" = "Y" ] && echo ON || echo OFF)" \
    "DISCORD" \
    "OPTIONAL - sends security alerts to Discord" \
    "$([ "$ENABLE_DISCORD" = "Y" ] && echo ON || echo OFF)" \
    3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    echo "Installation cancelled."
    exit 0
fi

# ------------------------------------------------------------------------------
# 8. PARSE FEATURES
# ------------------------------------------------------------------------------

TRACK_SSH="N"
TRACK_SUDO="N"
TRACK_UFW="N"
TRACK_PIHOLE="N"
TRACK_BANDWIDTH="N"
ENABLE_GEOIP="N"
ENABLE_DISCORD="N"

[[ "$CHOICES" == *'"SSH"'* ]] &&
    TRACK_SSH="Y"

[[ "$CHOICES" == *'"SUDO"'* ]] &&
    TRACK_SUDO="Y"

[[ "$CHOICES" == *'"UFW"'* ]] &&
    TRACK_UFW="Y"

[[ "$CHOICES" == *'"PIHOLE"'* ]] &&
    TRACK_PIHOLE="Y"

[[ "$CHOICES" == *'"BANDWIDTH"'* ]] &&
    TRACK_BANDWIDTH="Y"

[[ "$CHOICES" == *'"GEOIP"'* ]] &&
    ENABLE_GEOIP="Y"

[[ "$CHOICES" == *'"DISCORD"'* ]] &&
    ENABLE_DISCORD="Y"

# ------------------------------------------------------------------------------
# 9. REQUIRE ONE MONITOR
# ------------------------------------------------------------------------------

if [ "$TRACK_SSH" = "N" ] &&
   [ "$TRACK_SUDO" = "N" ] &&
   [ "$TRACK_UFW" = "N" ] &&
   [ "$TRACK_PIHOLE" = "N" ] &&
   [ "$TRACK_BANDWIDTH" = "N" ]; then

    whiptail \
        --title "No Monitoring Selected" \
        --msgbox \
"At least one monitoring feature must be selected.

Installation cancelled." \
        9 60

    exit 1
fi

# ------------------------------------------------------------------------------
# 10. BANDWIDTH CONFIGURATION
# ------------------------------------------------------------------------------

if [ "$TRACK_BANDWIDTH" = "Y" ]; then

    BANDWIDTH_THRESHOLD_MB=$(whiptail \
        --title "Bandwidth Monitor" \
        --inputbox \
"Alert when traffic exceeds approximately this rate.

Unit: MB/minute

This is an anomaly warning, NOT proof of malicious activity.

Current/default:
$BANDWIDTH_THRESHOLD_MB" \
        14 75 \
        "$BANDWIDTH_THRESHOLD_MB" \
        3>&1 1>&2 2>&3)

    [ $? -ne 0 ] && exit 0

    if ! [[ "$BANDWIDTH_THRESHOLD_MB" =~ ^[0-9]+$ ]] ||
       [ "$BANDWIDTH_THRESHOLD_MB" -lt 1 ]; then

        whiptail \
            --title "Invalid Value" \
            --msgbox \
"The bandwidth threshold must be a positive whole number." \
            9 60

        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 11. GEOIP EXPLANATION
# ------------------------------------------------------------------------------

if [ "$ENABLE_GEOIP" = "Y" ]; then

    if ! whiptail \
        --title "Optional GeoIP Feature" \
        --yesno \
"GeoIP is OPTIONAL.

It is not required to detect attacks.

When enabled, public source IPs may be sent to an external GeoIP service to obtain approximate:

• Country
• Region
• City
• ISP

This introduces an external network dependency and sends IP information outside your Pi.

Do you want to continue with GeoIP enabled?" \
        18 78; then

        ENABLE_GEOIP="N"
    fi
fi

# ------------------------------------------------------------------------------
# 12. DISCORD CONFIGURATION
# ------------------------------------------------------------------------------

if [ "$ENABLE_DISCORD" = "Y" ]; then

    DISCORD_WEBHOOK_URL=$(whiptail \
        --title "Discord Notifications" \
        --passwordbox \
"Enter the Discord webhook URL.

It will be stored root-only with permissions 600.

Leave blank to disable Discord notifications." \
        12 80 \
        "$DISCORD_WEBHOOK_URL" \
        3>&1 1>&2 2>&3)

    [ $? -ne 0 ] && exit 0

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        ENABLE_DISCORD="N"
    fi
fi

# ------------------------------------------------------------------------------
# 13. CONFIRM
# ------------------------------------------------------------------------------

SUMMARY="PiTweaks Security Monitor

Selected features:

"

[ "$TRACK_SSH" = "Y" ] &&
    SUMMARY+="✓ SSH login monitoring
"

[ "$TRACK_SUDO" = "Y" ] &&
    SUMMARY+="✓ Sudo activity monitoring
"

[ "$TRACK_UFW" = "Y" ] &&
    SUMMARY+="✓ UFW blocked connection monitoring
"

[ "$TRACK_PIHOLE" = "Y" ] &&
    SUMMARY+="✓ Pi-hole activity monitoring
"

[ "$TRACK_BANDWIDTH" = "Y" ] &&
    SUMMARY+="✓ Bandwidth monitoring: ${BANDWIDTH_THRESHOLD_MB} MB/min
"

[ "$ENABLE_GEOIP" = "Y" ] &&
    SUMMARY+="✓ OPTIONAL GeoIP
"

[ "$ENABLE_DISCORD" = "Y" ] &&
    SUMMARY+="✓ OPTIONAL Discord alerts
"

SUMMARY+="
SD-card protection:
• No persistent security event database
• Runtime state stored under /run
• No continuous security log written by this module
• Monitor runs approximately once per minute

Installation mode: $INSTALL_MODE

Continue?"

if ! whiptail \
    --title "Confirm Installation" \
    --yesno "$SUMMARY" \
    22 78; then

    echo "Installation cancelled."
    exit 0
fi

# ------------------------------------------------------------------------------
# 14. STOP EXISTING MONITOR
# ------------------------------------------------------------------------------

if [ "$EXISTING_INSTALL" = "Y" ]; then

    systemctl stop "$TIMER_NAME" 2>/dev/null || true
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

fi

# ------------------------------------------------------------------------------
# 15. BACK UP EXISTING CONFIG
# ------------------------------------------------------------------------------

if [ -f "$CONFIG_FILE" ]; then

    BACKUP_FILE="${CONFIG_FILE}.backup.$(date '+%Y%m%d_%H%M%S')"

    cp -p "$CONFIG_FILE" "$BACKUP_FILE"

    chown root:root "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"

fi

# ------------------------------------------------------------------------------
# 16. CREATE INSTALL DIRECTORY
# ------------------------------------------------------------------------------

mkdir -p "$SEC_DIR"

chown root:root "$SEC_DIR"
chmod 755 "$SEC_DIR"

# ------------------------------------------------------------------------------
# 17. WRITE CONFIGURATION
# ------------------------------------------------------------------------------

umask 077

TEMP_CONFIG="${CONFIG_FILE}.new"

cat > "$TEMP_CONFIG" <<EOF
# PiTweaks Security Monitor Configuration
# Module version: $MODULE_VERSION
#
# This file contains configuration data only.
# It is never sourced as executable shell code.

TRACK_SSH="$TRACK_SSH"
TRACK_SUDO="$TRACK_SUDO"
TRACK_UFW="$TRACK_UFW"
TRACK_PIHOLE="$TRACK_PIHOLE"
TRACK_BANDWIDTH="$TRACK_BANDWIDTH"

ENABLE_GEOIP="$ENABLE_GEOIP"
ENABLE_DISCORD="$ENABLE_DISCORD"

BANDWIDTH_THRESHOLD_MB="$BANDWIDTH_THRESHOLD_MB"

DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL"
EOF

chown root:root "$TEMP_CONFIG"
chmod 600 "$TEMP_CONFIG"

mv -f "$TEMP_CONFIG" "$CONFIG_FILE"

# ------------------------------------------------------------------------------
# 18. WRITE MONITOR
# ------------------------------------------------------------------------------

TEMP_MONITOR="${MONITOR_SCRIPT}.new"

cat > "$TEMP_MONITOR" <<'SCRIPT'
#!/bin/bash

# Description: PiTweaks Security Monitoring Engine
# PERSISTENT: TRUE
# Category: Scripts

set -u
set -o pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ==============================================================================
# SELF-DISCOVERY
# ==============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="$SCRIPT_DIR/security_config.env"

# ==============================================================================
# RAM-ONLY RUNTIME STATE
#
# /run is normally tmpfs on Raspberry Pi OS.
# Nothing here is intended to survive a reboot.
# ==============================================================================

STATE_DIR="/run/pitweaks-security"

EVENT_STATE="$STATE_DIR/events.state"
BW_STATE="$STATE_DIR/bandwidth.state"
LOCK_FILE="$STATE_DIR/monitor.lock"

mkdir -p "$STATE_DIR"

chmod 700 "$STATE_DIR"

# ==============================================================================
# SINGLE INSTANCE LOCK
# ==============================================================================

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    exit 0
fi

# ==============================================================================
# CONFIGURATION READER
#
# Configuration is treated as DATA, not executable shell.
# ==============================================================================

get_config() {

    local key="$1"

    awk -v wanted="$key" '
        $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {

            line=$0

            sub("^[[:space:]]*" wanted "[[:space:]]*=[[:space:]]*", "", line)

            if (line ~ /^".*"$/) {
                sub(/^"/, "", line)
                sub(/"$/, "", line)
            }

            print line
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null
}

if [ ! -r "$CONFIG_FILE" ]; then
    exit 1
fi

TRACK_SSH="$(get_config TRACK_SSH)"
TRACK_SUDO="$(get_config TRACK_SUDO)"
TRACK_UFW="$(get_config TRACK_UFW)"
TRACK_PIHOLE="$(get_config TRACK_PIHOLE)"
TRACK_BANDWIDTH="$(get_config TRACK_BANDWIDTH)"

ENABLE_GEOIP="$(get_config ENABLE_GEOIP)"
ENABLE_DISCORD="$(get_config ENABLE_DISCORD)"

BANDWIDTH_THRESHOLD_MB="$(get_config BANDWIDTH_THRESHOLD_MB)"
DISCORD_WEBHOOK_URL="$(get_config DISCORD_WEBHOOK_URL)"

# ==============================================================================
# BASIC VALIDATION
# ==============================================================================

case "$TRACK_SSH" in Y|N) ;; *) TRACK_SSH="N" ;; esac
case "$TRACK_SUDO" in Y|N) ;; *) TRACK_SUDO="N" ;; esac
case "$TRACK_UFW" in Y|N) ;; *) TRACK_UFW="N" ;; esac
case "$TRACK_PIHOLE" in Y|N) ;; *) TRACK_PIHOLE="N" ;; esac
case "$TRACK_BANDWIDTH" in Y|N) ;; *) TRACK_BANDWIDTH="N" ;; esac

case "$ENABLE_GEOIP" in Y|N) ;; *) ENABLE_GEOIP="N" ;; esac
case "$ENABLE_DISCORD" in Y|N) ;; *) ENABLE_DISCORD="N" ;; esac

if ! [[ "$BANDWIDTH_THRESHOLD_MB" =~ ^[0-9]+$ ]]; then
    BANDWIDTH_THRESHOLD_MB="100"
fi

# ==============================================================================
# ALERT BUFFER
# ==============================================================================

ALERT_BUFFER=""

add_alert() {

    local message="$1"

    if [ -n "$ALERT_BUFFER" ]; then
        ALERT_BUFFER+=$'\n\n---\n\n'
    fi

    ALERT_BUFFER+="$message"
}

# ==============================================================================
# LIGHTWEIGHT EVENT DEDUPLICATION
#
# One compact RAM state file instead of one file per event.
# ==============================================================================

event_is_new() {

    local event="$1"
    local hash

    hash="$(printf '%s' "$event" | sha256sum | awk '{print $1}')"

    if [ -f "$EVENT_STATE" ] &&
       grep -qF "$hash" "$EVENT_STATE" 2>/dev/null; then

        return 1
    fi

    printf '%s\n' "$hash" >> "$EVENT_STATE"

    # Keep only the newest 200 hashes.
    if [ "$(wc -l < "$EVENT_STATE" 2>/dev/null || echo 0)" -gt 200 ]; then
        tail -n 200 "$EVENT_STATE" > "${EVENT_STATE}.tmp"
        mv -f "${EVENT_STATE}.tmp" "$EVENT_STATE"
    fi

    return 0
}

# ==============================================================================
# OPTIONAL GEOIP
# ==============================================================================

get_geo_info() {

    local ip="$1"

    [ "$ENABLE_GEOIP" != "Y" ] && return 0

    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi

    # Ignore private/local addresses.
    if [[ "$ip" =~ ^10\. ]] ||
       [[ "$ip" =~ ^192\.168\. ]] ||
       [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] ||
       [[ "$ip" =~ ^127\. ]]; then
        return 0
    fi

    local response

    response=$(curl \
        -fsS \
        --connect-timeout 2 \
        --max-time 4 \
        "https://ipwho.is/$ip?fields=success,country,region,city,connection.isp" \
        2>/dev/null || true)

    [ -z "$response" ] && return 0

    if command -v jq >/dev/null 2>&1; then

        local success country region city isp

        success=$(printf '%s' "$response" |
            jq -r '.success // false' 2>/dev/null)

        [ "$success" != "true" ] && return 0

        country=$(printf '%s' "$response" |
            jq -r '.country // empty' 2>/dev/null)

        region=$(printf '%s' "$response" |
            jq -r '.region // empty' 2>/dev/null)

        city=$(printf '%s' "$response" |
            jq -r '.city // empty' 2>/dev/null)

        isp=$(printf '%s' "$response" |
            jq -r '.connection.isp // empty' 2>/dev/null)

        printf '%s, %s, %s (%s)' \
            "${city:-Unknown}" \
            "${region:-Unknown}" \
            "${country:-Unknown}" \
            "${isp:-Unknown}"
    fi
}

# ==============================================================================
# TIME WINDOW
#
# Small overlap catches events around timer boundaries.
# Deduplication prevents repeated alerts.
# ==============================================================================

SINCE_TIME="$(date -d '90 seconds ago' '+%Y-%m-%d %H:%M:%S')"

# ==============================================================================
# 1. SSH
# ==============================================================================

if [ "$TRACK_SSH" = "Y" ]; then

    LOGS=$(journalctl \
        _COMM=sshd \
        --since "$SINCE_TIME" \
        --no-pager \
        -o short-iso \
        2>/dev/null || true)

    while IFS= read -r line; do

        [ -z "$line" ] && continue

        if echo "$line" | grep -q "Failed password"; then

            event_is_new "$line" || continue

            SRC_IP=$(echo "$line" |
                grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' |
                tail -n 1)

            USER_ATTEMPT=$(echo "$line" |
                awk '{for(i=1;i<=NF;i++) if($i=="for") print $(i+1)}')

            GEO=""

            if [ "$ENABLE_GEOIP" = "Y" ]; then
                GEO="$(get_geo_info "$SRC_IP")"
            fi

            MSG="🚨 SECURITY ALERT: Failed SSH Login
• User: ${USER_ATTEMPT:-Unknown}
• Source IP: ${SRC_IP:-Unknown}"

            [ -n "$GEO" ] &&
                MSG="$MSG
• Approx. Origin: $GEO"

            MSG="$MSG
• Time: $(date '+%Y-%m-%d %H:%M:%S')"

            add_alert "$MSG"

        elif echo "$line" |
            grep -qE "Accepted (publickey|password)"; then

            event_is_new "$line" || continue

            SRC_IP=$(echo "$line" |
                grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' |
                tail -n 1)

            USER_ATTEMPT=$(echo "$line" |
                awk '{for(i=1;i<=NF;i++) if($i=="for") print $(i+1)}')

            GEO=""

            if [ "$ENABLE_GEOIP" = "Y" ]; then
                GEO="$(get_geo_info "$SRC_IP")"
            fi

            MSG="🔓 SECURITY NOTICE: Successful SSH Login
• User: ${USER_ATTEMPT:-Unknown}
• Source IP: ${SRC_IP:-Unknown}"

            [ -n "$GEO" ] &&
                MSG="$MSG
• Approx. Origin: $GEO"

            MSG="$MSG
• Time: $(date '+%Y-%m-%d %H:%M:%S')"

            add_alert "$MSG"
        fi

    done <<< "$LOGS"
fi

# ==============================================================================
# 2. SUDO
# ==============================================================================

if [ "$TRACK_SUDO" = "Y" ]; then

    LOGS=$(journalctl \
        _COMM=sudo \
        --since "$SINCE_TIME" \
        --no-pager \
        -o short-iso \
        2>/dev/null || true)

    while IFS= read -r line; do

        [ -z "$line" ] && continue

        if echo "$line" | grep -q "COMMAND="; then

            event_is_new "$line" || continue

            USER_SUDO=$(echo "$line" |
                grep -oP '(?<=USER=)[^ ]+' |
                head -n 1)

            CMD_RUN=$(echo "$line" |
                grep -oP '(?<=COMMAND=).*')

            add_alert "⚠️ SECURITY AUDIT: Sudo Command
• User: ${USER_SUDO:-Unknown}
• Command: ${CMD_RUN:-Unknown}
• Time: $(date '+%Y-%m-%d %H:%M:%S')"
        fi

    done <<< "$LOGS"
fi

# ==============================================================================
# 3. UFW
# ==============================================================================

if [ "$TRACK_UFW" = "Y" ]; then

    LOGS=$(journalctl \
        -k \
        --since "$SINCE_TIME" \
        --no-pager \
        -o short-iso \
        2>/dev/null |
        grep '\[UFW BLOCK\]' || true)

    while IFS= read -r line; do

        [ -z "$line" ] && continue

        event_is_new "$line" || continue

        SRC_IP=$(echo "$line" |
            grep -oP '(?<=SRC=)[^ ]+' |
            head -n 1)

        DST_PORT=$(echo "$line" |
            grep -oP '(?<=DPT=)[^ ]+' |
            head -n 1)

        GEO=""

        if [ "$ENABLE_GEOIP" = "Y" ]; then
            GEO="$(get_geo_info "$SRC_IP")"
        fi

        MSG="🛡️ FIREWALL BLOCK: Connection Blocked
• Source IP: ${SRC_IP:-Unknown}
• Target Port: ${DST_PORT:-Unknown}"

        [ -n "$GEO" ] &&
            MSG="$MSG
• Approx. Origin: $GEO"

        MSG="$MSG
• Time: $(date '+%Y-%m-%d %H:%M:%S')"

        add_alert "$MSG"

    done <<< "$LOGS"
fi

# ==============================================================================
# 4. PI-HOLE
# ==============================================================================

if [ "$TRACK_PIHOLE" = "Y" ]; then

    TARGET_LOG=""

    if [ -f "/var/log/lighttpd/access.log" ]; then
        TARGET_LOG="/var/log/lighttpd/access.log"
    elif [ -f "/var/log/pihole/pihole-FTL.log" ]; then
        TARGET_LOG="/var/log/pihole/pihole-FTL.log"
    fi

    if [ -n "$TARGET_LOG" ]; then

        RECENT_LOGS=$(tail -n 100 "$TARGET_LOG" 2>/dev/null |
            grep -iE 'POST /admin|login' |
            tail -n 20 || true)

        while IFS= read -r line; do

            [ -z "$line" ] && continue

            event_is_new "$line" || continue

            SRC_IP=$(echo "$line" |
                awk '{print $1}')

            add_alert "🌐 PI-HOLE WEB ACTIVITY
• Source IP: ${SRC_IP:-Unknown}
• Log: $TARGET_LOG
• Time: $(date '+%Y-%m-%d %H:%M:%S')"

        done <<< "$RECENT_LOGS"
    fi
fi

# ==============================================================================
# 5. BANDWIDTH
# ==============================================================================

if [ "$TRACK_BANDWIDTH" = "Y" ]; then

    DEFAULT_IFACE=$(ip route show default 2>/dev/null |
        awk '/default/ {print $5}' |
        head -n 1)

    if [ -n "$DEFAULT_IFACE" ]; then

        CURRENT_BYTES=$(awk -v iface="$DEFAULT_IFACE" '
            $1 == iface ":" {
                print $2 + $10
            }
        ' /proc/net/dev 2>/dev/null)

        CURRENT_TIME=$(date +%s)

        if [[ "$CURRENT_BYTES" =~ ^[0-9]+$ ]]; then

            if [ -f "$BW_STATE" ]; then

                read -r LAST_BYTES LAST_TIME < "$BW_STATE" || true

                if [[ "${LAST_BYTES:-}" =~ ^[0-9]+$ ]] &&
                   [[ "${LAST_TIME:-}" =~ ^[0-9]+$ ]]; then

                    BYTES_DIFF=$((CURRENT_BYTES - LAST_BYTES))
                    TIME_DIFF=$((CURRENT_TIME - LAST_TIME))

                    if [ "$BYTES_DIFF" -ge 0 ] &&
                       [ "$TIME_DIFF" -gt 0 ]; then

                        BYTES_PER_SEC=$((BYTES_DIFF / TIME_DIFF))
                        MB_PER_MIN=$((BYTES_PER_SEC * 60 / 1024 / 1024))

                        if [ "$MB_PER_MIN" -gt "$BANDWIDTH_THRESHOLD_MB" ]; then

                            EVENT="BANDWIDTH|$DEFAULT_IFACE|$MB_PER_MIN|$CURRENT_TIME"

                            if event_is_new "$EVENT"; then

                                add_alert "📈 TRAFFIC SPIKE WARNING
• Interface: $DEFAULT_IFACE
• Usage Rate: ~${MB_PER_MIN} MB/min
• Threshold: ${BANDWIDTH_THRESHOLD_MB} MB/min
• Time: $(date '+%Y-%m-%d %H:%M:%S')"

                            fi
                        fi
                    fi
                fi
            fi

            printf '%s %s\n' \
                "$CURRENT_BYTES" \
                "$CURRENT_TIME" > "$BW_STATE"
        fi
    fi
fi

# ==============================================================================
# 6. DISCORD
# ==============================================================================

if [ "$ENABLE_DISCORD" = "Y" ] &&
   [ -n "$DISCORD_WEBHOOK_URL" ] &&
   [ -n "$ALERT_BUFFER" ]; then

    if ! command -v jq >/dev/null 2>&1; then

        logger -t pitweaks-security \
            "Discord enabled but jq is unavailable."

        exit 1
    fi

    JSON_PAYLOAD=$(jq -n \
        --arg content "$ALERT_BUFFER" \
        '{content: $content}')

    HTTP_CODE=$(curl \
        -sS \
        -o /dev/null \
        -w '%{http_code}' \
        --connect-timeout 5 \
        --max-time 15 \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$JSON_PAYLOAD" \
        "$DISCORD_WEBHOOK_URL" \
        2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then

        exit 0

    else

        logger -t pitweaks-security \
            "Discord notification failed with HTTP status $HTTP_CODE"

        exit 1
    fi
fi

exit 0
SCRIPT

chown root:root "$TEMP_MONITOR"
chmod 755 "$TEMP_MONITOR"

mv -f "$TEMP_MONITOR" "$MONITOR_SCRIPT"

# ------------------------------------------------------------------------------
# 19. INSTALL DEPENDENCIES
# ------------------------------------------------------------------------------

PACKAGES=()

command -v curl >/dev/null 2>&1 ||
    PACKAGES+=("curl")

command -v jq >/dev/null 2>&1 ||
    PACKAGES+=("jq")

command -v flock >/dev/null 2>&1 ||
    PACKAGES+=("util-linux")

if [ "${#PACKAGES[@]}" -gt 0 ]; then

    apt-get update

    mapfile -t PACKAGES < <(
        printf '%s\n' "${PACKAGES[@]}" |
        sort -u
    )

    apt-get install -y "${PACKAGES[@]}"
fi

# ------------------------------------------------------------------------------
# 20. CREATE SYSTEMD SERVICE
# ------------------------------------------------------------------------------

TEMP_SERVICE="${SERVICE_FILE}.new"

cat > "$TEMP_SERVICE" <<EOF
[Unit]
Description=PiTweaks Security Event Monitor
Documentation=https://github.com/technicdawn-stack/PiTweaks
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$MONITOR_SCRIPT

User=root
Group=root

# Security restrictions.
NoNewPrivileges=true
PrivateTmp=true

# The monitor must inspect system logs and network statistics.
ProtectSystem=full
ProtectHome=false

ReadOnlyPaths=/var/log
ReadOnlyPaths=/proc/net
ReadWritePaths=$STATE_DIR

# Prevent unexpected privilege changes.
RestrictSUIDSGID=true
LockPersonality=true

# Do not allow the process to create a persistent core dump.
LimitCORE=0
EOF

chmod 644 "$TEMP_SERVICE"

mv -f "$TEMP_SERVICE" "$SERVICE_FILE"

# ------------------------------------------------------------------------------
# 21. CREATE SYSTEMD TIMER
# ------------------------------------------------------------------------------

TEMP_TIMER="${TIMER_FILE}.new"

cat > "$TEMP_TIMER" <<EOF
[Unit]
Description=PiTweaks Security Monitor Timer

[Timer]

# Start shortly after boot.
OnBootSec=30s

# Run approximately once per minute.
OnUnitActiveSec=60s

AccuracySec=5s

# If the Pi was temporarily powered off, run once after returning.
Persistent=true

[Install]
WantedBy=timers.target
EOF

chmod 644 "$TEMP_TIMER"

mv -f "$TEMP_TIMER" "$TIMER_FILE"

# ------------------------------------------------------------------------------
# 22. RELOAD SYSTEMD
# ------------------------------------------------------------------------------

systemctl daemon-reload

# ------------------------------------------------------------------------------
# 23. ENABLE TIMER
# ------------------------------------------------------------------------------

if ! systemctl enable "$TIMER_NAME" >/dev/null 2>&1; then

    whiptail \
        --title "Installation Error" \
        --msgbox \
"Failed to enable the PiTweaks security timer.

The configuration files were installed, but the watchdog is not active.

Check:

systemctl status $TIMER_NAME" \
        13 70

    exit 1
fi

if ! systemctl restart "$TIMER_NAME"; then

    whiptail \
        --title "Installation Error" \
        --msgbox \
"Failed to start the PiTweaks security timer.

Check:

systemctl status $TIMER_NAME
journalctl -u $TIMER_NAME" \
        13 70

    exit 1
fi

# ------------------------------------------------------------------------------
# 24. INITIAL MONITOR TEST
# ------------------------------------------------------------------------------

TEST_RESULT="FAILED"

if "$MONITOR_SCRIPT"; then
    TEST_RESULT="PASSED"
fi

# ------------------------------------------------------------------------------
# 25. VERIFY TIMER
# ------------------------------------------------------------------------------

TIMER_STATUS="$(systemctl is-active "$TIMER_NAME" 2>/dev/null || true)"

# ------------------------------------------------------------------------------
# 26. FINAL STATUS
# ------------------------------------------------------------------------------

if [ "$TEST_RESULT" = "PASSED" ] &&
   [ "$TIMER_STATUS" = "active" ]; then

    whiptail \
        --title "🛡️ PiTweaks Security Monitor Installed" \
        --msgbox \
"Installation completed successfully.

Module:
PiTweaks Security Monitor $MODULE_VERSION

Timer:
ACTIVE

Runs:
Approximately once per minute

SD-card protection:
✓ No persistent security event database
✓ Runtime state stored in /run
✓ No continuous security log generated
✓ Low-overhead periodic monitoring

Configuration:
$CONFIG_FILE

Monitor:
$MONITOR_SCRIPT

Systemd timer:
$TIMER_NAME

The monitor is now active." \
        22 78

else

    whiptail \
        --title "⚠️ Installation Verification Failed" \
        --msgbox \
"The files were installed, but the final verification did not pass.

Timer status:
$TIMER_STATUS

Monitor test:
$TEST_RESULT

Useful commands:

systemctl status $TIMER_NAME
systemctl status $SERVICE_NAME
journalctl -u $SERVICE_NAME" \
        18 78

    exit 1
fi

echo ""
echo "=================================================="
echo " 🛡️ PiTweaks Security Monitor $MODULE_VERSION"
echo "=================================================="
echo ""
echo "User:           $CURRENT_USER"
echo "Install dir:    $SEC_DIR"
echo "Configuration:  $CONFIG_FILE"
echo "Monitor:        $MONITOR_SCRIPT"
echo "Timer:          $TIMER_NAME"
echo "Status:         $TIMER_STATUS"
echo "Test:           $TEST_RESULT"
echo ""
echo "SD-card friendly runtime state:"
echo "  $STATE_DIR"
echo ""
echo "=================================================="
