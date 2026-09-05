#!/bin/bash

# Description: PiTweaks Security Event Monitor & Network Watchdog V1.1
# PERSISTENT: TRUE
# Category: Scripts

clear

# ==============================================================================
# PiTweaks Security Event Monitor & Network Watchdog
# Version 2.1.0
#
# Design goals:
#   - Portable across supported Raspberry Pi OS systems
#   - No developer-specific usernames, hostnames or URLs
#   - Minimal SD-card wear
#   - Runtime state stored only under /run
#   - No persistent security event database
#   - Low CPU/RAM usage
#   - systemd timer instead of cron
#   - Whiptail configuration interface
#   - Discord is optional and failure-safe
#   - Configuration is treated as DATA, never executable shell code
# ==============================================================================

set -u
set -o pipefail

MODULE_VERSION="2.1.0"

SERVICE_NAME="pitweaks-security.service"
TIMER_NAME="pitweaks-security.timer"

SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
TIMER_FILE="/etc/systemd/system/$TIMER_NAME"

# ------------------------------------------------------------------------------
# 0. REQUIRE ROOT
# ------------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "❌ This security module must be installed with sudo."
    echo
    echo "Run:"
    echo "  sudo bash security_module_upgrade.sh"
    echo
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
    exit 1
fi

INSTALL_DIR="$REAL_HOME/PiTweaks"
SEC_DIR="$INSTALL_DIR/security"

CONFIG_FILE="$SEC_DIR/security_config.env"
MONITOR_SCRIPT="$SEC_DIR/sec_monitor.sh"

STATE_DIR="/run/pitweaks-security"

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
"An existing PiTweaks Security Monitor installation was detected.

Installed files will be safely stopped before replacement.

What would you like to do?" \
        17 78 4 \
        "RECONFIGURE" "Keep monitor and change settings" \
        "REINSTALL" "Replace monitor, service and timer" \
        "STATUS" "View current installation status" \
        "CANCEL" "Exit without making changes" \
        3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        exit 0
    fi

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
            ENABLE_STATE="$(systemctl is-enabled "$TIMER_NAME" 2>/dev/null || true)"

            whiptail \
                --title "PiTweaks Security Monitor Status" \
                --msgbox \
"PiTweaks Security Monitor

Module version:
$MODULE_VERSION

Timer:
$TIMER_NAME
Active: ${TIMER_STATE:-unknown}
Enabled: ${ENABLE_STATE:-unknown}

Service:
$SERVICE_NAME
Active: ${SERVICE_STATE:-unknown}

Configuration:
$CONFIG_FILE

Monitor:
$MONITOR_SCRIPT

Runtime state:
$STATE_DIR" \
                21 78

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

# ------------------------------------------------------------------------------
# 5. CONFIGURATION READER
#
# Configuration is treated as DATA.
# It is never sourced as executable shell code.
# ------------------------------------------------------------------------------

read_config_value() {

    local key="$1"
    local file="$2"

    [ ! -f "$file" ] && return 0

    awk -v wanted="$key" '
        index($0, wanted "=") == 1 {

            line=$0

            sub("^[^=]*=", "", line)

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

    if whiptail \
        --title "Existing Settings Found" \
        --yesno \
"An existing configuration was found.

Would you like to keep your current settings?

YES:
• Monitoring choices retained
• Bandwidth threshold retained
• GeoIP setting retained
• Discord setting retained
• Discord webhook retained

You can still change everything afterward.

NO:
• Start with recommended defaults." \
        17 78; then

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
"Select the security monitoring features.

SPACE = toggle
ENTER = continue

The monitor is designed to use very little CPU and
avoid intentional persistent SD-card writes." \
    23 92 7 \
    "SSH" \
    "SSH login monitoring - failed and successful logins" \
    "$([ "$TRACK_SSH" = "Y" ] && echo ON || echo OFF)" \
    "SUDO" \
    "Sudo activity - monitors privileged command activity" \
    "$([ "$TRACK_SUDO" = "Y" ] && echo ON || echo OFF)" \
    "UFW" \
    "UFW blocks - detects connections rejected by firewall" \
    "$([ "$TRACK_UFW" = "Y" ] && echo ON || echo OFF)" \
    "PIHOLE" \
    "Pi-hole activity - monitors compatible admin logs" \
    "$([ "$TRACK_PIHOLE" = "Y" ] && echo ON || echo OFF)" \
    "BANDWIDTH" \
    "Bandwidth anomaly - detects unusually high traffic" \
    "$([ "$TRACK_BANDWIDTH" = "Y" ] && echo ON || echo OFF)" \
    "GEOIP" \
    "OPTIONAL - approximate location/ISP for public IPs" \
    "$([ "$ENABLE_GEOIP" = "Y" ] && echo ON || echo OFF)" \
    "DISCORD" \
    "OPTIONAL - send security alerts to Discord" \
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

[[ "$CHOICES" == *'"SSH"'* ]] && TRACK_SSH="Y"
[[ "$CHOICES" == *'"SUDO"'* ]] && TRACK_SUDO="Y"
[[ "$CHOICES" == *'"UFW"'* ]] && TRACK_UFW="Y"
[[ "$CHOICES" == *'"PIHOLE"'* ]] && TRACK_PIHOLE="Y"
[[ "$CHOICES" == *'"BANDWIDTH"'* ]] && TRACK_BANDWIDTH="Y"
[[ "$CHOICES" == *'"GEOIP"'* ]] && ENABLE_GEOIP="Y"
[[ "$CHOICES" == *'"DISCORD"'* ]] && ENABLE_DISCORD="Y"

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
"At least one actual monitoring feature must be selected.

Installation cancelled." \
        10 65

    exit 1
fi

# ------------------------------------------------------------------------------
# 10. BANDWIDTH CONFIGURATION
# ------------------------------------------------------------------------------

if [ "$TRACK_BANDWIDTH" = "Y" ]; then

    BANDWIDTH_THRESHOLD_MB=$(whiptail \
        --title "Bandwidth Monitor" \
        --inputbox \
"Alert when traffic exceeds approximately:

MB per minute

This is an anomaly warning, not proof of malicious activity.

Current value:
$BANDWIDTH_THRESHOLD_MB" \
        14 76 \
        "$BANDWIDTH_THRESHOLD_MB" \
        3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        exit 0
    fi

    if ! [[ "$BANDWIDTH_THRESHOLD_MB" =~ ^[0-9]+$ ]] ||
       [ "$BANDWIDTH_THRESHOLD_MB" -lt 1 ]; then

        whiptail \
            --title "Invalid Bandwidth Threshold" \
            --msgbox \
"The bandwidth threshold must be a positive whole number." \
            9 62

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

It is not required for security detection.

When enabled, public source IP addresses may be sent
to an external GeoIP service.

This can provide approximate:
• Country
• Region
• City
• ISP

This creates an external dependency and sends IP
information outside the Pi.

Enable GeoIP?" \
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

The URL will be stored root-only with permissions 600.

Leave blank to disable Discord." \
        12 82 \
        "$DISCORD_WEBHOOK_URL" \
        3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        exit 0
    fi

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        ENABLE_DISCORD="N"
    fi

    # Basic validation without exposing the secret.
    if [ "$ENABLE_DISCORD" = "Y" ] &&
       ! [[ "$DISCORD_WEBHOOK_URL" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/ ]]; then

        whiptail \
            --title "Invalid Discord Webhook" \
            --msgbox \
"The supplied value does not look like a standard Discord webhook URL.

Expected format:

https://discord.com/api/webhooks/...

Discord notifications have been disabled for this installation.

You can reconfigure the webhook later." \
            14 76

        ENABLE_DISCORD="N"
        DISCORD_WEBHOOK_URL=""
    fi
fi

# ------------------------------------------------------------------------------
# 13. OPTIONAL DISCORD TEST
# ------------------------------------------------------------------------------

if [ "$ENABLE_DISCORD" = "Y" ] &&
   [ -n "$DISCORD_WEBHOOK_URL" ]; then

    if whiptail \
        --title "Test Discord Webhook?" \
        --yesno \
"Would you like to send a temporary test message to Discord now?

This verifies that the webhook actually accepts messages.

The test message will say:

PiTweaks Security Monitor test - webhook working." \
        15 76; then

        if ! command -v curl >/dev/null 2>&1; then
            apt-get update
            apt-get install -y curl
        fi

        if ! command -v jq >/dev/null 2>&1; then
            apt-get update
            apt-get install -y jq
        fi

        TEST_PAYLOAD="$(jq -n \
            --arg content "🛡️ PiTweaks Security Monitor test — Discord webhook is working." \
            '{content:$content}')"

        TEST_HTTP_CODE="$(
            curl \
                -sS \
                -o /dev/null \
                -w '%{http_code}' \
                --connect-timeout 5 \
                --max-time 10 \
                -H "Content-Type: application/json" \
                -X POST \
                -d "$TEST_PAYLOAD" \
                "$DISCORD_WEBHOOK_URL" \
                2>/dev/null || echo "000"
        )"

        if [[ "$TEST_HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then

            whiptail \
                --title "Discord Test Successful" \
                --msgbox \
"Discord accepted the test message.

HTTP status:
$TEST_HTTP_CODE

Discord notifications will remain enabled." \
                11 68

        else

            if whiptail \
                --title "Discord Test Failed" \
                --yesno \
"Discord rejected the test message.

HTTP status:
$TEST_HTTP_CODE

This does NOT disable the security monitor.

Would you like to:
YES - keep Discord enabled and investigate later
NO  - disable Discord for now" \
                14 76; then

                :
            else
                ENABLE_DISCORD="N"
                DISCORD_WEBHOOK_URL=""
            fi
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 14. CONFIRM
# ------------------------------------------------------------------------------

SUMMARY="PiTweaks Security Monitor $MODULE_VERSION

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

✓ No persistent security event database
✓ Runtime state under /run
✓ No PiTweaks security log file
✓ No cron logging
✓ Approximately one monitor run per minute
✓ Discord failure does not stop monitoring

Installation mode:
$INSTALL_MODE

Continue?"

if ! whiptail \
    --title "Confirm Installation" \
    --yesno "$SUMMARY" \
    24 80; then

    echo "Installation cancelled."
    exit 0
fi

# ------------------------------------------------------------------------------
# 15. STOP EXISTING MONITOR
# ------------------------------------------------------------------------------

if [ "$EXISTING_INSTALL" = "Y" ]; then

    systemctl stop "$TIMER_NAME" 2>/dev/null || true
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 16. CREATE INSTALL DIRECTORY
# ------------------------------------------------------------------------------

mkdir -p "$SEC_DIR"

chown root:root "$INSTALL_DIR" 2>/dev/null || true
chown root:root "$SEC_DIR"

chmod 755 "$SEC_DIR"

# ------------------------------------------------------------------------------
# 17. BACK UP EXISTING CONFIG
# ------------------------------------------------------------------------------

if [ -f "$CONFIG_FILE" ]; then

    BACKUP_FILE="${CONFIG_FILE}.backup.$(date '+%Y%m%d_%H%M%S')"

    cp -p "$CONFIG_FILE" "$BACKUP_FILE"

    chown root:root "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
fi

# ------------------------------------------------------------------------------
# 18. WRITE CONFIGURATION
# ------------------------------------------------------------------------------

umask 077

TEMP_CONFIG="${CONFIG_FILE}.new"

cat > "$TEMP_CONFIG" <<EOF
# PiTweaks Security Monitor Configuration
# Module version: $MODULE_VERSION
#
# Configuration is treated as DATA.
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
# 19. WRITE MONITOR
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
# SELF DISCOVERY
# ==============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="$SCRIPT_DIR/security_config.env"

# ==============================================================================
# RAM-ONLY STATE
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
# ==============================================================================

get_config() {

    local key="$1"

    awk -v wanted="$key" '
        index($0, wanted "=") == 1 {

            line=$0

            sub("^[^=]*=", "", line)

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
# CONFIGURATION VALIDATION
# ==============================================================================

case "$TRACK_SSH" in
    Y|N) ;;
    *) TRACK_SSH="N" ;;
esac

case "$TRACK_SUDO" in
    Y|N) ;;
    *) TRACK_SUDO="N" ;;
esac

case "$TRACK_UFW" in
    Y|N) ;;
    *) TRACK_UFW="N" ;;
esac

case "$TRACK_PIHOLE" in
    Y|N) ;;
    *) TRACK_PIHOLE="N" ;;
esac

case "$TRACK_BANDWIDTH" in
    Y|N) ;;
    *) TRACK_BANDWIDTH="N" ;;
esac

case "$ENABLE_GEOIP" in
    Y|N) ;;
    *) ENABLE_GEOIP="N" ;;
esac

case "$ENABLE_DISCORD" in
    Y|N) ;;
    *) ENABLE_DISCORD="N" ;;
esac

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
# EVENT DEDUPLICATION
#
# Uses one small RAM state file.
# No persistent security database is created.
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

    if [ "$(wc -l < "$EVENT_STATE" 2>/dev/null || echo 0)" -gt 200 ]; then

        tail -n 200 "$EVENT_STATE" > "${EVENT_STATE}.tmp"

        mv -f "${EVENT_STATE}.tmp" "$EVENT_STATE"
    fi

    return 0
}

# ==============================================================================
# OPTIONAL GEOIP
#
# Cache is process-local only.
# No persistent GeoIP cache is written.
# ==============================================================================

declare -A GEO_CACHE

get_geo_info() {

    local ip="$1"

    [ "$ENABLE_GEOIP" != "Y" ] && return 0

    [ -z "$ip" ] && return 0

    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi

    if [[ "$ip" =~ ^10\. ]] ||
       [[ "$ip" =~ ^192\.168\. ]] ||
       [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] ||
       [[ "$ip" =~ ^127\. ]]; then
        return 0
    fi

    if [ "${GEO_CACHE[$ip]+isset}" = "isset" ]; then
        printf '%s' "${GEO_CACHE[$ip]}"
        return 0
    fi

    local response=""
    local result=""

    response="$(
        curl \
            -fsS \
            --connect-timeout 2 \
            --max-time 4 \
            "https://ipwho.is/$ip?fields=success,country,region,city,connection.isp" \
            2>/dev/null || true
    )"

    if [ -z "$response" ]; then
        GEO_CACHE[$ip]=""
        return 0
    fi

    if command -v jq >/dev/null 2>&1; then

        local success country region city isp

        success="$(
            printf '%s' "$response" |
                jq -r '.success // false' 2>/dev/null
        )"

        if [ "$success" != "true" ]; then
            GEO_CACHE[$ip]=""
            return 0
        fi

        country="$(
            printf '%s' "$response" |
                jq -r '.country // empty' 2>/dev/null
        )"

        region="$(
            printf '%s' "$response" |
                jq -r '.region // empty' 2>/dev/null
        )"

        city="$(
            printf '%s' "$response" |
                jq -r '.city // empty' 2>/dev/null
        )"

        isp="$(
            printf '%s' "$response" |
                jq -r '.connection.isp // empty' 2>/dev/null
        )"

        result="${city:-Unknown}, ${region:-Unknown}, ${country:-Unknown} (${isp:-Unknown})"

        GEO_CACHE[$ip]="$result"

        printf '%s' "$result"
    fi
}

# ==============================================================================
# JOURNAL TIME WINDOW
#
# A small overlap catches timer-boundary events.
# RAM-based hashes prevent duplicate notifications.
# ==============================================================================

SINCE_TIME="$(date -d '90 seconds ago' '+%Y-%m-%d %H:%M:%S')"

# ==============================================================================
# SSH MONITORING
# ==============================================================================

if [ "$TRACK_SSH" = "Y" ]; then

    LOGS="$(
        journalctl \
            _COMM=sshd \
            --since "$SINCE_TIME" \
            --no-pager \
            -o short-iso \
            2>/dev/null || true
    )"

    if [ -z "$LOGS" ]; then

        LOGS="$(
            journalctl \
                SYSLOG_IDENTIFIER=sshd \
                --since "$SINCE_TIME" \
                --no-pager \
                -o short-iso \
                2>/dev/null || true
        )"
    fi

    while IFS= read -r line; do

        [ -z "$line" ] && continue

        if printf '%s\n' "$line" | grep -q "Failed password"; then

            event_is_new "$line" || continue

            SRC_IP="$(
                printf '%s\n' "$line" |
                    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' |
                    tail -n 1
            )"

            USER_ATTEMPT="$(
                printf '%s\n' "$line" |
                    awk '{
                        for (i=1;i<=NF;i++)
                            if ($i=="for") print $(i+1)
                    }'
            )"

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

        elif printf '%s\n' "$line" |
             grep -qE "Accepted (publickey|password)"; then

            event_is_new "$line" || continue

            SRC_IP="$(
                printf '%s\n' "$line" |
                    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' |
                    tail -n 1
            )"

            USER_ATTEMPT="$(
                printf '%s\n' "$line" |
                    awk '{
                        for (i=1;i<=NF;i++)
                            if ($i=="for") print $(i+1)
                    }'
            )"

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
# SUDO MONITORING
# ==============================================================================

if [ "$TRACK_SUDO" = "Y" ]; then

    LOGS="$(
        journalctl \
            _COMM=sudo \
            --since "$SINCE_TIME" \
            --no-pager \
            -o short-iso \
            2>/dev/null || true
    )"

    while IFS= read -r line; do

        [ -z "$line" ] && continue

        if printf '%s\n' "$line" | grep -q "COMMAND="; then

            event_is_new "$line" || continue

            USER_SUDO="$(
                printf '%s\n' "$line" |
                    sed -n 's/.*USER=\([^ ]*\).*/\1/p' |
                    head -n 1
            )"

            CMD_RUN="$(
                printf '%s\n' "$line" |
                    sed -n 's/.*COMMAND=//p'
            )"

            add_alert "⚠️ SECURITY AUDIT: Sudo Command
• User: ${USER_SUDO:-Unknown}
• Command: ${CMD_RUN:-Unknown}
• Time: $(date '+%Y-%m-%d %H:%M:%S')"

        fi

    done <<< "$LOGS"
fi

# ==============================================================================
# UFW MONITORING
# ==============================================================================

if [ "$TRACK_UFW" = "Y" ]; then

    LOGS="$(
        journalctl \
            -k \
            --since "$SINCE_TIME" \
            --no-pager \
            -o short-iso \
            2>/dev/null |
            grep '\[UFW BLOCK\]' ||
            true
    )"

    while IFS= read -r line; do

        [ -z "$line" ] && continue

        event_is_new "$line" || continue

        SRC_IP="$(
            printf '%s\n' "$line" |
                sed -n 's/.*SRC=\([^ ]*\).*/\1/p' |
                head -n 1
        )"

        DST_PORT="$(
            printf '%s\n' "$line" |
                sed -n 's/.*DPT=\([^ ]*\).*/\1/p' |
                head -n 1
        )"

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
# PI-HOLE MONITORING
#
# This is deliberately conservative.
# It reports relevant admin/login activity rather than claiming
# every matching request is a successful login.
# ==============================================================================

if [ "$TRACK_PIHOLE" = "Y" ]; then

    TARGET_LOG=""

    if [ -f "/var/log/lighttpd/access.log" ]; then
        TARGET_LOG="/var/log/lighttpd/access.log"
    elif [ -f "/var/log/pihole/pihole-FTL.log" ]; then
        TARGET_LOG="/var/log/pihole/pihole-FTL.log"
    fi

    if [ -n "$TARGET_LOG" ]; then

        RECENT_LOGS="$(
            tail -n 100 "$TARGET_LOG" 2>/dev/null |
                grep -iE 'POST /admin|login' |
                tail -n 20 ||
                true
        )"

        while IFS= read -r line; do

            [ -z "$line" ] && continue

            event_is_new "$line" || continue

            SRC_IP="$(
                printf '%s\n' "$line" |
                    awk '{print $1}'
            )"

            add_alert "🌐 PI-HOLE ADMIN ACTIVITY
• Source IP: ${SRC_IP:-Unknown}
• Log: $TARGET_LOG
• Time: $(date '+%Y-%m-%d %H:%M:%S')"

        done <<< "$RECENT_LOGS"
    fi
fi

# ==============================================================================
# BANDWIDTH MONITORING
# ==============================================================================

if [ "$TRACK_BANDWIDTH" = "Y" ]; then

    DEFAULT_IFACE="$(
        ip route show default 2>/dev/null |
            awk '/default/ {print $5}' |
            head -n 1
    )"

    if [ -n "$DEFAULT_IFACE" ]; then

        CURRENT_BYTES="$(
            awk -v iface="$DEFAULT_IFACE" '
                $1 == iface ":" {
                    print $2 + $10
                }
            ' /proc/net/dev 2>/dev/null
        )"

        CURRENT_TIME="$(date +%s)"

        if [[ "$CURRENT_BYTES" =~ ^[0-9]+$ ]]; then

            LAST_BYTES=""
            LAST_TIME=""
            LAST_ALERT_TIME="0"

            if [ -f "$BW_STATE" ]; then
                read -r LAST_BYTES LAST_TIME LAST_ALERT_TIME < "$BW_STATE" || true
            fi

            if [[ "${LAST_BYTES:-}" =~ ^[0-9]+$ ]] &&
               [[ "${LAST_TIME:-}" =~ ^[0-9]+$ ]]; then

                BYTES_DIFF=$((CURRENT_BYTES - LAST_BYTES))
                TIME_DIFF=$((CURRENT_TIME - LAST_TIME))

                if [ "$BYTES_DIFF" -ge 0 ] &&
                   [ "$TIME_DIFF" -gt 0 ]; then

                    BYTES_PER_SEC=$((BYTES_DIFF / TIME_DIFF))
                    MB_PER_MIN=$((BYTES_PER_SEC * 60 / 1024 / 1024))

                    # Do not repeatedly alert every minute for one
                    # continuously high traffic condition.
                    ALERT_COOLDOWN=300

                    if [ "$MB_PER_MIN" -gt "$BANDWIDTH_THRESHOLD_MB" ] &&
                       { [ "$LAST_ALERT_TIME" = "0" ] ||
                         [ $((CURRENT_TIME - LAST_ALERT_TIME)) -ge "$ALERT_COOLDOWN" ]; }; then

                        EVENT="BANDWIDTH|$DEFAULT_IFACE|$MB_PER_MIN|$BANDWIDTH_THRESHOLD_MB"

                        if event_is_new "$EVENT"; then

                            add_alert "📈 TRAFFIC SPIKE WARNING
• Interface: $DEFAULT_IFACE
• Usage Rate: ~${MB_PER_MIN} MB/min
• Threshold: ${BANDWIDTH_THRESHOLD_MB} MB/min
• Time: $(date '+%Y-%m-%d %H:%M:%S')"

                            LAST_ALERT_TIME="$CURRENT_TIME"
                        fi
                    fi
                fi
            fi

            printf '%s %s %s\n' \
                "$CURRENT_BYTES" \
                "$CURRENT_TIME" \
                "${LAST_ALERT_TIME:-0}" > "$BW_STATE"
        fi
    fi
fi

# ==============================================================================
# DISCORD NOTIFICATIONS
#
# IMPORTANT:
# Discord is an OPTIONAL OUTPUT.
#
# A Discord failure MUST NEVER cause this security monitor
# to return a failure status.
# ==============================================================================

if [ "$ENABLE_DISCORD" = "Y" ] &&
   [ -n "$DISCORD_WEBHOOK_URL" ] &&
   [ -n "$ALERT_BUFFER" ]; then

    # If jq isn't installed, silently skip Discord.
    # Monitoring itself continues normally.
    if command -v jq >/dev/null 2>&1 &&
       command -v curl >/dev/null 2>&1; then

        JSON_PAYLOAD="$(
            jq -n \
                --arg content "$ALERT_BUFFER" \
                '{content:$content}' \
                2>/dev/null || true
        )"

        if [ -n "$JSON_PAYLOAD" ]; then

            HTTP_CODE="$(
                curl \
                    -sS \
                    -o /dev/null \
                    -w '%{http_code}' \
                    --connect-timeout 5 \
                    --max-time 15 \
                    -H "Content-Type: application/json" \
                    -X POST \
                    -d "$JSON_PAYLOAD" \
                    "$DISCORD_WEBHOOK_URL" \
                    2>/dev/null || echo "000"
            )"

            # Successful Discord response.
            if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
                :
            else
                # Deliberately do nothing.
                #
                # 401 / 403 / 404 / 429 / 5xx / network failure
                # must not break the security monitor.
                :
            fi
        fi
    fi
fi

# ==============================================================================
# NORMAL EXIT
# ==============================================================================

exit 0
SCRIPT

chown root:root "$TEMP_MONITOR"
chmod 755 "$TEMP_MONITOR"

mv -f "$TEMP_MONITOR" "$MONITOR_SCRIPT"

# ------------------------------------------------------------------------------
# 20. INSTALL REQUIRED DEPENDENCIES
# ------------------------------------------------------------------------------

PACKAGES=()

command -v curl >/dev/null 2>&1 ||
    PACKAGES+=("curl")

command -v flock >/dev/null 2>&1 ||
    PACKAGES+=("util-linux")

if [ "$ENABLE_DISCORD" = "Y" ] ||
   [ "$ENABLE_GEOIP" = "Y" ]; then
    command -v jq >/dev/null 2>&1 ||
        PACKAGES+=("jq")
fi

if [ "${#PACKAGES[@]}" -gt 0 ]; then

    apt-get update

    mapfile -t PACKAGES < <(
        printf '%s\n' "${PACKAGES[@]}" |
            sort -u
    )

    apt-get install -y "${PACKAGES[@]}"
fi

# ------------------------------------------------------------------------------
# 21. CREATE SYSTEMD SERVICE
# ------------------------------------------------------------------------------

TEMP_SERVICE="${SERVICE_FILE}.new"

cat > "$TEMP_SERVICE" <<EOF
[Unit]
Description=PiTweaks Security Event Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot

User=root
Group=root

ExecStart=$MONITOR_SCRIPT

# Security restrictions.
NoNewPrivileges=true
PrivateTmp=true

# Required access:
# - system journal
# - /proc/net
# - Pi-hole logs when enabled
ProtectSystem=full
ProtectHome=false

ReadOnlyPaths=/var/log
ReadOnlyPaths=/proc/net

# Runtime state is the only location intentionally written.
ReadWritePaths=$STATE_DIR

# Prevent privilege-changing behaviour.
RestrictSUIDSGID=true
LockPersonality=true

# No core dumps.
LimitCORE=0

# Avoid generating normal service output.
StandardOutput=null
StandardError=null
EOF

chmod 644 "$TEMP_SERVICE"

mv -f "$TEMP_SERVICE" "$SERVICE_FILE"

# ------------------------------------------------------------------------------
# 22. CREATE SYSTEMD TIMER
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

# Small scheduling tolerance reduces unnecessary wakeups.
AccuracySec=5s

# Do not perform catch-up runs after downtime.
# This is preferable for the low-wear monitoring design.
Persistent=false

[Install]
WantedBy=timers.target
EOF

chmod 644 "$TEMP_TIMER"

mv -f "$TEMP_TIMER" "$TIMER_FILE"

# ------------------------------------------------------------------------------
# 23. SYSTEMD RELOAD
# ------------------------------------------------------------------------------

systemctl daemon-reload

# ------------------------------------------------------------------------------
# 24. ENABLE TIMER
# ------------------------------------------------------------------------------

if ! systemctl enable "$TIMER_NAME" >/dev/null 2>&1; then

    whiptail \
        --title "Installation Error" \
        --msgbox \
"Failed to enable the PiTweaks security timer.

The monitor files were installed, but the timer could
not be enabled.

Check:

systemctl status $TIMER_NAME" \
        14 72

    exit 1
fi

# ------------------------------------------------------------------------------
# 25. START TIMER
# ------------------------------------------------------------------------------

if ! systemctl restart "$TIMER_NAME"; then

    whiptail \
        --title "Installation Error" \
        --msgbox \
"Failed to start the PiTweaks security timer.

Check:

systemctl status $TIMER_NAME
journalctl -u $TIMER_NAME" \
        14 72

    exit 1
fi

# ------------------------------------------------------------------------------
# 26. INITIAL MONITOR TEST
# ------------------------------------------------------------------------------

TEST_RESULT="FAILED"

if "$MONITOR_SCRIPT"; then
    TEST_RESULT="PASSED"
fi

# ------------------------------------------------------------------------------
# 27. VERIFY TIMER
# ------------------------------------------------------------------------------

TIMER_STATUS="$(
    systemctl is-active "$TIMER_NAME" 2>/dev/null || true
)"

TIMER_ENABLED="$(
    systemctl is-enabled "$TIMER_NAME" 2>/dev/null || true
)"

# ------------------------------------------------------------------------------
# 28. FINAL STATUS
# ------------------------------------------------------------------------------

if [ "$TEST_RESULT" = "PASSED" ] &&
   [ "$TIMER_STATUS" = "active" ] &&
   [ "$TIMER_ENABLED" = "enabled" ]; then

    DISCORD_STATUS="Disabled"

    if [ "$ENABLE_DISCORD" = "Y" ]; then
        DISCORD_STATUS="Enabled"
    fi

    whiptail \
        --title "🛡️ PiTweaks Security Monitor Installed" \
        --msgbox \
"Installation completed successfully.

PiTweaks Security Monitor:
Version $MODULE_VERSION

Timer:
ACTIVE + ENABLED

Schedule:
Approximately once per minute

Discord:
$DISCORD_STATUS

SD-card protection:

✓ No persistent security event database
✓ Runtime state stored under /run
✓ No PiTweaks security log
✓ No cron logging
✓ Low-overhead periodic monitoring
✓ Discord failure cannot stop monitoring

Configuration:
$CONFIG_FILE

Monitor:
$MONITOR_SCRIPT

Runtime state:
$STATE_DIR

The security monitor is now active." \
        25 82

else

    whiptail \
        --title "⚠️ Installation Verification Failed" \
        --msgbox \
"The files were installed, but final verification failed.

Timer active:
$TIMER_STATUS

Timer enabled:
$TIMER_ENABLED

Monitor test:
$TEST_RESULT

Check:

systemctl status $TIMER_NAME
systemctl status $SERVICE_NAME

For details:

journalctl -u $SERVICE_NAME" \
        20 78

    exit 1
fi

echo
echo "=================================================="
echo " 🛡️ PiTweaks Security Monitor $MODULE_VERSION"
echo "=================================================="
echo
echo "User:            $CURRENT_USER"
echo "Install dir:     $SEC_DIR"
echo "Configuration:   $CONFIG_FILE"
echo "Monitor:         $MONITOR_SCRIPT"
echo "Timer:           $TIMER_NAME"
echo "Timer status:    $TIMER_STATUS"
echo "Timer enabled:   $TIMER_ENABLED"
echo "Monitor test:    $TEST_RESULT"
echo
echo "RAM-only runtime state:"
echo "  $STATE_DIR"
echo
echo "Discord:         $ENABLE_DISCORD"
echo "GeoIP:           $ENABLE_GEOIP"
echo
echo "=================================================="
