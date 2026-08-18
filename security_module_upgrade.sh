#!/bin/bash

clear

# ==============================================================================
# 🛡️ PiTweaks Security & Network Watchdog Setup & Installer
# ==============================================================================

set -u

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
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    CURRENT_USER="$SUDO_USER"
else
    REAL_HOME="$HOME"
    CURRENT_USER="$(whoami)"
fi

if [ -z "$REAL_HOME" ] || [ ! -d "$REAL_HOME" ]; then
    echo "❌ Could not determine the PiTweaks user's home directory."
    exit 1
fi

INSTALL_DIR="$REAL_HOME/PiTweaks"
SEC_DIR="$INSTALL_DIR/security"
CONFIG_FILE="$SEC_DIR/security_config.env"
MONITOR_SCRIPT="$SEC_DIR/sec_monitor.sh"

echo "=================================================="
echo " 🛡️ PiTweaks Security & Network Watchdog Setup"
echo "=================================================="
echo ""
echo "👤 User:       $CURRENT_USER"
echo "🏠 Home:       $REAL_HOME"
echo "📁 PiTweaks:   $INSTALL_DIR"
echo ""

# ------------------------------------------------------------------------------
# 2. CREATE SECURITY DIRECTORY
# ------------------------------------------------------------------------------

mkdir -p "$SEC_DIR"

if [ ! -d "$SEC_DIR" ]; then
    echo "❌ Failed to create security directory."
    exit 1
fi

# Keep the directory protected because it contains privileged code.
chown root:root "$SEC_DIR"
chmod 755 "$SEC_DIR"

# ------------------------------------------------------------------------------
# 3. SAFE CONFIGURATION READER
# ------------------------------------------------------------------------------
#
# Never source an old configuration file before verifying it is trusted.
# Read only the known variables.
# ------------------------------------------------------------------------------

read_config_value() {
    local key="$1"
    local file="$2"
    local value=""

    if [ ! -f "$file" ]; then
        return 0
    fi

    value=$(awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", $0)

            if ($0 ~ /^".*"$/) {
                sub(/^"/, "", $0)
                sub(/"$/, "", $0)
            }
            else if ($0 ~ /^'\''.*'\''$/) {
                sub(/^'\''/, "", $0)
                sub(/'\''$/, "", $0)
            }

            print
            exit
        }
    ' "$file")

    printf '%s' "$value"
}

# ------------------------------------------------------------------------------
# 4. LOAD EXISTING CONFIGURATION SAFELY
# ------------------------------------------------------------------------------

TRACK_SSH=""
TRACK_SUDO=""
TRACK_UFW=""
TRACK_PIHOLE=""
TRACK_BANDWIDTH=""
BANDWIDTH_THRESHOLD_MB=""

if [ -f "$CONFIG_FILE" ]; then

    echo "🔍 Found existing security configuration."
    echo ""

    OLD_TRACK_SSH=$(read_config_value "TRACK_SSH" "$CONFIG_FILE")
    OLD_TRACK_SUDO=$(read_config_value "TRACK_SUDO" "$CONFIG_FILE")
    OLD_TRACK_UFW=$(read_config_value "TRACK_UFW" "$CONFIG_FILE")
    OLD_TRACK_PIHOLE=$(read_config_value "TRACK_PIHOLE" "$CONFIG_FILE")
    OLD_TRACK_BANDWIDTH=$(read_config_value "TRACK_BANDWIDTH" "$CONFIG_FILE")
    OLD_BANDWIDTH_THRESHOLD_MB=$(read_config_value "BANDWIDTH_THRESHOLD_MB" "$CONFIG_FILE")

    TRACK_SSH="${OLD_TRACK_SSH:-Y}"
    TRACK_SUDO="${OLD_TRACK_SUDO:-Y}"
    TRACK_UFW="${OLD_TRACK_UFW:-Y}"
    TRACK_PIHOLE="${OLD_TRACK_PIHOLE:-Y}"
    TRACK_BANDWIDTH="${OLD_TRACK_BANDWIDTH:-Y}"
    BANDWIDTH_THRESHOLD_MB="${OLD_BANDWIDTH_THRESHOLD_MB:-100}"

    read -p "Do you want to edit your tracking values and toggles? [y/N]: " EDIT_CHOICE </dev/tty
    EDIT_CHOICE=${EDIT_CHOICE:-N}

    echo ""

    if [[ "$EDIT_CHOICE" =~ ^[yY]$ ]]; then

        echo "⚙️  Let's update your settings (Press Enter to keep current values):"
        echo "--------------------------------------------------"

        read -p "Enable SSH Brute-Force & Success Tracking [Y/n] (Current: $TRACK_SSH): " input
        TRACK_SSH=${input:-$TRACK_SSH}

        read -p "Enable Sudo Privilege Escalation Tracking [Y/n] (Current: $TRACK_SUDO): " input
        TRACK_SUDO=${input:-$TRACK_SUDO}

        read -p "Enable UFW Firewall Port Probe Tracking [Y/n] (Current: $TRACK_UFW): " input
        TRACK_UFW=${input:-$TRACK_UFW}

        read -p "Enable Pi-Hole Web Dashboard Login Tracking [Y/n] (Current: $TRACK_PIHOLE): " input
        TRACK_PIHOLE=${input:-$TRACK_PIHOLE}

        read -p "Enable Bandwidth Traffic Spike Monitor [Y/n] (Current: $TRACK_BANDWIDTH): " input
        TRACK_BANDWIDTH=${input:-$TRACK_BANDWIDTH}

        read -p "Bandwidth Spike Limit in MB/min (Current: $BANDWIDTH_THRESHOLD_MB): " input
        BANDWIDTH_THRESHOLD_MB=${input:-$BANDWIDTH_THRESHOLD_MB}

    else
        echo "✅ Keeping existing security configuration values."
    fi

else

    echo "⚙️  New Security Configuration Setup"
    echo "--------------------------------------------------"

    read -p "Enable SSH Brute-Force & Success Tracking [Y/n]: " TRACK_SSH
    TRACK_SSH=${TRACK_SSH:-Y}

    read -p "Enable Sudo Privilege Escalation Tracking [Y/n]: " TRACK_SUDO
    TRACK_SUDO=${TRACK_SUDO:-Y}

    read -p "Enable UFW Firewall Port Probe Tracking [Y/n]: " TRACK_UFW
    TRACK_UFW=${TRACK_UFW:-Y}

    read -p "Enable Pi-Hole Web Dashboard Login Tracking [Y/n]: " TRACK_PIHOLE
    TRACK_PIHOLE=${TRACK_PIHOLE:-Y}

    read -p "Enable Bandwidth Traffic Spike Monitor [Y/n]: " TRACK_BANDWIDTH
    TRACK_BANDWIDTH=${TRACK_BANDWIDTH:-Y}

    read -p "Enter Bandwidth Spike Limit in MB/min [Default: 100]: " BANDWIDTH_THRESHOLD_MB
    BANDWIDTH_THRESHOLD_MB=${BANDWIDTH_THRESHOLD_MB:-100}

fi

# ------------------------------------------------------------------------------
# 5. BACK UP EXISTING CONFIGURATION
# ------------------------------------------------------------------------------

if [ -f "$CONFIG_FILE" ]; then

    BACKUP_FILE="${CONFIG_FILE}.backup.$(date '+%Y%m%d_%H%M%S')"

    if cp -p "$CONFIG_FILE" "$BACKUP_FILE"; then
        chown root:root "$BACKUP_FILE"
        chmod 600 "$BACKUP_FILE"

        echo "💾 Existing configuration backed up:"
        echo "   $BACKUP_FILE"
    else
        echo "⚠️ Warning: Could not create configuration backup."
    fi

fi

# ------------------------------------------------------------------------------
# 6. WRITE CONFIGURATION
# ------------------------------------------------------------------------------

echo ""
echo "🔐 Installing protected security configuration..."

cat > "$CONFIG_FILE" << EOL
TRACK_SSH="$TRACK_SSH"
TRACK_SUDO="$TRACK_SUDO"
TRACK_UFW="$TRACK_UFW"
TRACK_PIHOLE="$TRACK_PIHOLE"
TRACK_BANDWIDTH="$TRACK_BANDWIDTH"
BANDWIDTH_THRESHOLD_MB="$BANDWIDTH_THRESHOLD_MB"
EOL

if [ $? -ne 0 ]; then
    echo "❌ Failed to write security configuration."
    exit 1
fi

chown root:root "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo "✅ Security configuration installed as root:root."
echo "   Permissions: 600"
echo ""

# ==============================================================================
# 7. WRITE SECURITY MONITOR
# ==============================================================================
#
# IMPORTANT:
#
# The old version contained:
#
#   CONFIG_FILE="/home/raspi3b/PiTweaks/security/security_config.env"
#
# This version injects the actual path calculated above.
#
# Because this heredoc is NOT quoted, $CONFIG_FILE is expanded NOW by the
# installer. Variables belonging to the monitor itself are escaped with \$
# so they remain variables when sec_monitor.sh runs.
# ==============================================================================

echo "📝 Writing security monitoring engine..."

cat > "$MONITOR_SCRIPT" << SCRIPT
#!/bin/bash

# ==============================================================================
# PiTweaks Security & Network Watchdog
# ==============================================================================

CONFIG_FILE="$CONFIG_FILE"

if [ -f "\$CONFIG_FILE" ]; then
    source "\$CONFIG_FILE"
fi

DISCORD_ALERT_CHAN="/tmp/pi_discord_alert_queue.txt"

# ------------------------------------------------------------------------------
# Helper function to query real IP geolocation
# ------------------------------------------------------------------------------

get_geo_info() {
    local ip="\$1"

    if [[ "\$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
       [[ ! "\$ip" =~ ^192\.168\. ]] &&
       [[ ! "\$ip" =~ ^10\. ]]; then

        local response
        response=\$(curl -s --max-time 3 "http://ip-api.com/json/\$ip?fields=country,regionName,isp")

        if [ \$? -eq 0 ] && [ -n "\$response" ]; then

            local country
            local region
            local isp

            country=\$(echo "\$response" | jq -r '.country // empty')
            region=\$(echo "\$response" | jq -r '.regionName // empty')
            isp=\$(echo "\$response" | jq -r '.isp // empty')

            if [ -n "\$country" ]; then
                echo "• **Origin:** \$region, \$country (\$isp)"
                return
            fi
        fi
    fi

    echo "• **Origin:** Local / Private Network or Unknown"
}

# ==============================================================================
# 1. SSH TRACKER
# ==============================================================================

if [[ "\${TRACK_SSH^^}" =~ ^Y ]]; then

    AUTH_LOG="/var/log/auth.log"
    STATE_FILE="/tmp/pi_sec_auth_line.txt"

    if [ -f "\$AUTH_LOG" ]; then

        [ ! -f "\$STATE_FILE" ] && wc -l < "\$AUTH_LOG" > "\$STATE_FILE"

        LAST_LINE=\$(cat "\$STATE_FILE")
        CURRENT_LINE=\$(wc -l < "\$AUTH_LOG")

        if [ "\$CURRENT_LINE" -gt "\$LAST_LINE" ]; then

            NEW_LOGS=\$(tail -n +\$((LAST_LINE + 1)) "\$AUTH_LOG")

            while IFS= read -r line; do

                if echo "\$line" | grep -q "Failed password"; then

                    SRC_IP=\$(echo "\$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)

                    USER_ATTEMPT=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="for") print \$(i+1)}')

                    GEO=\$(get_geo_info "\$SRC_IP")

                    MSG=\$'[ALERT]🚨 **SECURITY ALERT: Failed SSH Login**\n• **User:** '"\${USER_ATTEMPT:-Unknown}"\$'\n• **Source IP:** '"\${SRC_IP:-Unknown}"\$'\n'" \$GEO "\$'\n• **Time:** '"\$(date '+%Y-%m-%d %H:%M:%S')"

                    echo "\$MSG" >> "\$DISCORD_ALERT_CHAN"

                elif echo "\$line" | grep -q "Accepted publickey" ||
                     echo "\$line" | grep -q "Accepted password"; then

                    SRC_IP=\$(echo "\$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)

                    USER_ATTEMPT=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="for") print \$(i+1)}')

                    GEO=\$(get_geo_info "\$SRC_IP")

                    MSG=\$'[NOTICE]🔓 **SECURITY NOTICE: Successful SSH Login**\n• **User:** '"\${USER_ATTEMPT:-Unknown}"\$'\n• **Source IP:** '"\${SRC_IP:-Unknown}"\$'\n'" \$GEO "\$'\n• **Time:** '"\$(date '+%Y-%m-%d %H:%M:%S')"

                    echo "\$MSG" >> "\$DISCORD_ALERT_CHAN

                fi

            done <<< "\$NEW_LOGS"

            echo "\$CURRENT_LINE" > "\$STATE_FILE"
        fi
    fi
fi

# ==============================================================================
# 2. SUDO ESCALATION TRACKER
# ==============================================================================

if [[ "\${TRACK_SUDO^^}" =~ ^Y ]]; then

    AUTH_LOG="/var/log/auth.log"
    SUDO_STATE="/tmp/pi_sec_sudo_line.txt"

    if [ -f "\$AUTH_LOG" ]; then

        [ ! -f "\$SUDO_STATE" ] && wc -l < "\$AUTH_LOG" > "\$SUDO_STATE"

        LAST_LINE=\$(cat "\$SUDO_STATE")
        CURRENT_LINE=\$(wc -l < "\$AUTH_LOG")

        if [ "\$CURRENT_LINE" -gt "\$LAST_LINE" ]; then

            NEW_LOGS=\$(tail -n +\$((LAST_LINE + 1)) "\$AUTH_LOG")

            while IFS= read -r line; do

                if echo "\$line" | grep -q "COMMAND="; then

                    USER_SUDO=\$(echo "\$line" | grep -oP '(?<=USER=)[^ ]+' | head -n 1)

                    CMD_RUN=\$(echo "\$line" | grep -oP '(?<=COMMAND=).*')

                    MSG=\$'[AUDIT]⚠️ **SECURITY AUDIT: Sudo Command Executed**\n• **User:** '"\${USER_SUDO:-Unknown}"\$'\n• **Command:** `'"\${CMD_RUN:-Unknown}"\$'`\n• **Time:** '"\$(date '+%Y-%m-%d %H:%M:%S')"

                    echo "\$MSG" >> "\$DISCORD_ALERT_CHAN"
                fi

            done <<< "\$NEW_LOGS"

            echo "\$CURRENT_LINE" > "\$SUDO_STATE"
        fi
    fi
fi

# ==============================================================================
# 3. UFW FIREWALL PROBE TRACKER
# ==============================================================================

if [[ "\${TRACK_UFW^^}" =~ ^Y ]]; then

    UFW_LOG="/var/log/ufw.log"
    UFW_STATE="/tmp/pi_sec_ufw_line.txt"

    if [ -f "\$UFW_LOG" ]; then

        [ ! -f "\$UFW_STATE" ] && wc -l < "\$UFW_LOG" > "\$UFW_STATE"

        LAST_LINE=\$(cat "\$UFW_STATE")
        CURRENT_LINE=\$(wc -l < "\$UFW_LOG")

        if [ "\$CURRENT_LINE" -gt "\$LAST_LINE" ]; then

            NEW_LOGS=\$(tail -n +\$((LAST_LINE + 1)) "\$UFW_LOG")

            while IFS= read -r line; do

                if echo "\$line" | grep -q "BLOCK"; then

                    SRC_IP=\$(echo "\$line" | grep -oP '(?<=SRC=)[^ ]+' | head -n 1)

                    DST_PORT=\$(echo "\$line" | grep -oP '(?<=DPT=)[^ ]+' | head -n 1)

                    MSG=\$'[FIREWALL]🛡️ **FIREWALL BLOCK: External Probe Detected**\n• **Blocked IP:** '"\${SRC_IP:-Unknown}"\$'\n• **Target Port:** '"\${DST_PORT:-Unknown}"\$'\n• **Time:** '"\$(date '+%Y-%m-%d %H:%M:%S')"

                    echo "\$MSG" >> "\$DISCORD_ALERT_CHAN"
                fi

            done <<< "\$NEW_LOGS"

            echo "\$CURRENT_LINE" > "\$UFW_STATE"
        fi
    fi
fi

# ==============================================================================
# 4. PI-HOLE WEB DASHBOARD LOGIN TRACKER
# ==============================================================================

if [[ "\${TRACK_PIHOLE^^}" =~ ^Y ]]; then

    LIGHTTPD_LOG="/var/log/lighttpd/access.log"
    PIHOLE_STATE="/tmp/pi_sec_pihole_line.txt"

    if [ -f "\$LIGHTTPD_LOG" ]; then

        [ ! -f "\$PIHOLE_STATE" ] && wc -l < "\$LIGHTTPD_LOG" > "\$PIHOLE_STATE"

        LAST_LINE=\$(cat "\$PIHOLE_STATE")
        CURRENT_LINE=\$(wc -l < "\$LIGHTTPD_LOG")

        if [ "\$CURRENT_LINE" -gt "\$LAST_LINE" ]; then

            NEW_LOGS=\$(tail -n +\$((LAST_LINE + 1)) "\$LIGHTTPD_LOG")

            while IFS= read -r line; do

                if echo "\$line" | grep -q "POST /admin" ||
                   echo "\$line" | grep -q "login"; then

                    SRC_IP=\$(echo "\$line" | awk '{print \$1}')

                    MSG=\$'[WEB]🌐 **WEB ADMIN NOTICE: Pi-Hole Dashboard Activity**\n• **Source IP:** '"\${SRC_IP:-Unknown}"\$'\n• **Action:** Admin Panel Authentication / Request\n• **Time:** '"\$(date '+%Y-%m-%d %H:%M:%S')"

                    echo "\$MSG" >> "\$DISCORD_ALERT_CHAN"
                fi

            done <<< "\$NEW_LOGS"

            echo "\$CURRENT_LINE" > "\$PIHOLE_STATE"
        fi
    fi
fi

# ==============================================================================
# 5. BANDWIDTH TRAFFIC SPIKE MONITOR
# ==============================================================================

if [[ "\${TRACK_BANDWIDTH^^}" =~ ^Y ]]; then

    BW_STATE="/tmp/pi_sec_bw_state.txt"

    DEFAULT_IFACE=\$(ip route show default | awk '/default/ {print \$5}' | head -n 1)

    if [ -n "\$DEFAULT_IFACE" ]; then

        CURRENT_BYTES=\$(awk -v iface="\$DEFAULT_IFACE" '\$1 == iface":" {print \$2 + \$10}' /proc/net/dev)

        CURRENT_TIME=\$(date +%s)

        if [ -f "\$BW_STATE" ]; then

            read LAST_BYTES LAST_TIME < "\$BW_STATE"

            BYTES_DIFF=\$(( CURRENT_BYTES - LAST_BYTES ))

            TIME_DIFF=\$(( CURRENT_TIME - LAST_TIME ))

            if [ "\$TIME_DIFF" -gt 0 ] && [ "\$BYTES_DIFF" -gt 0 ]; then

                BYTES_PER_SEC=\$(( BYTES_DIFF / TIME_DIFF ))

                MB_PER_MIN=\$(( BYTES_PER_SEC * 60 / 1024 / 1024 ))

                THRESHOLD=\${BANDWIDTH_THRESHOLD_MB:-100}

                if [ "\$MB_PER_MIN" -gt "\$THRESHOLD" ]; then

                    MSG=\$'[BANDWIDTH]📈 **TRAFFIC SPIKE WARNING**\n• **Interface:** '"\$DEFAULT_IFACE"\$'\n• **Usage Rate:** ~'"\${MB_PER_MIN}"\$' MB/min (Threshold: '" "\${THRESHOLD}" "\$' MB/min)\n• **Time:** '"\$(date '+%Y-%m-%d %H:%M:%S')"

                    echo "\$MSG" >> "\$DISCORD_ALERT_CHAN"
                fi
            fi
        fi

        echo "\$CURRENT_BYTES \$CURRENT_TIME" > "\$BW_STATE"
    fi
fi
SCRIPT

if [ $? -ne 0 ]; then
    echo "❌ Failed to write security monitoring engine."
    exit 1
fi

# ------------------------------------------------------------------------------
# 8. PROTECT MONITOR
# ------------------------------------------------------------------------------

chown root:root "$MONITOR_SCRIPT"
chmod 755 "$MONITOR_SCRIPT"

echo "🔐 Security monitor installed as root:root."
echo "   Permissions: 755"
echo ""

# ------------------------------------------------------------------------------
# 9. VERIFY PATHS
# ------------------------------------------------------------------------------

EXPECTED_CONFIG_LINE="CONFIG_FILE=\"$CONFIG_FILE\""

ACTUAL_CONFIG_LINE=$(grep '^CONFIG_FILE=' "$MONITOR_SCRIPT" 2>/dev/null || true)

if [ "$ACTUAL_CONFIG_LINE" != "$EXPECTED_CONFIG_LINE" ]; then
    echo "❌ Generated monitor path verification failed."
    echo ""
    echo "Expected:"
    echo "  $EXPECTED_CONFIG_LINE"
    echo ""
    echo "Found:"
    echo "  ${ACTUAL_CONFIG_LINE:-<missing>}"
    echo ""
    exit 1
fi

# Make absolutely sure the old hard-coded username isn't present.
if grep -q "/home/raspi3b/" "$MONITOR_SCRIPT"; then
    echo "❌ Old hard-coded /home/raspi3b path detected."
    exit 1
fi

echo "✅ Dynamic configuration path verified."
echo "   $CONFIG_FILE"
echo ""

# ------------------------------------------------------------------------------
# 10. VERIFY PRIVILEGED FILE OWNERSHIP
# ------------------------------------------------------------------------------

MONITOR_OWNER=$(stat -c '%U:%G' "$MONITOR_SCRIPT" 2>/dev/null || echo "unknown")
MONITOR_PERMS=$(stat -c '%a' "$MONITOR_SCRIPT" 2>/dev/null || echo "unknown")

CONFIG_OWNER=$(stat -c '%U:%G' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
CONFIG_PERMS=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo "unknown")

if [ "$MONITOR_OWNER" != "root:root" ] || [ "$MONITOR_PERMS" != "755" ]; then
    echo "❌ Security monitor permission verification failed."
    echo "   Owner: $MONITOR_OWNER"
    echo "   Mode:  $MONITOR_PERMS"
    exit 1
fi

if [ "$CONFIG_OWNER" != "root:root" ] || [ "$CONFIG_PERMS" != "600" ]; then
    echo "❌ Security configuration permission verification failed."
    echo "   Owner: $CONFIG_OWNER"
    echo "   Mode:  $CONFIG_PERMS"
    exit 1
fi

echo "✅ Privileged file verification passed."
echo ""

# ------------------------------------------------------------------------------
# 11. CRON JOB
# ------------------------------------------------------------------------------
#
# Keep cron for now.
# Systemd migration is a later upgrade.
# ------------------------------------------------------------------------------

echo "⏰ Scheduling security watchdog cron job..."

CURRENT_CRONTAB=$(crontab -l 2>/dev/null || true)

CLEAN_CRONTAB=$(printf '%s\n' "$CURRENT_CRONTAB" | grep -v "sec_monitor.sh" || true)

printf '%s\n' "$CLEAN_CRONTAB" \
    | sed '/^[[:space:]]*$/d' \
    | {
        cat
        echo "* * * * * sudo $MONITOR_SCRIPT > /dev/null 2>&1"
    } \
    | crontab -

if [ $? -ne 0 ]; then
    echo "❌ Failed to install security watchdog cron job."
    exit 1
fi

echo "✅ Security watchdog scheduled."
echo ""

# ------------------------------------------------------------------------------
# 12. FINAL VERIFICATION
# ------------------------------------------------------------------------------

echo "=================================================="
echo " 🔐 Security Installation Verification"
echo "=================================================="
echo ""
echo "Monitor:"
echo "  Path:  $MONITOR_SCRIPT"
echo "  Owner: $MONITOR_OWNER"
echo "  Mode:  $MONITOR_PERMS"
echo ""
echo "Config:"
echo "  Path:  $CONFIG_FILE"
echo "  Owner: $CONFIG_OWNER"
echo "  Mode:  $CONFIG_PERMS"
echo ""
echo "Cron:"
echo "  * * * * * sudo $MONITOR_SCRIPT"
echo ""

echo "=================================================="
echo " ✅ Security & Network Watchdog installed safely"
echo "=================================================="
echo ""
echo "Existing configuration values were preserved."
echo "The watchdog now uses the dynamically detected"
echo "PiTweaks installation path."
echo ""
