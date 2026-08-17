#!/bin/bash

clear

# ==============================================================================
# 🛡️ PiTweaks Security & Network Watchdog Setup & Installer
# ==============================================================================

if [ -n "$SUDO_USER" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    CURRENT_USER="$SUDO_USER"
else
    REAL_HOME="$HOME"
    CURRENT_USER="$(whoami)"
fi

INSTALL_DIR="$REAL_HOME/PiTweaks"
SEC_DIR="$INSTALL_DIR/security"
CONFIG_FILE="$SEC_DIR/security_config.env"
MONITOR_SCRIPT="$SEC_DIR/sec_monitor.sh"
SERVICE_NAME="pitweaks-security-watch"

echo "=================================================="
echo " 🛡️ PiTweaks Security & Network Watchdog Setup"
echo "=================================================="
echo ""

mkdir -p "$SEC_DIR"

# 1. INTERACTIVE SETUP & CONFIGURATION EDITING WIZARD
if [ -f "$CONFIG_FILE" ]; then
    echo "🔍 Found existing security configuration."
    read -p "Do you want to edit your tracking values and toggles? [y/N]: " EDIT_CHOICE </dev/tty
    EDIT_CHOICE=${EDIT_CHOICE:-N}
    echo ""
    if [[ "$EDIT_CHOICE" =~ ^[yY]$ ]]; then
        source "$CONFIG_FILE"
        echo "⚙️  Let's update your settings (Press Enter to keep current values):"
        echo "--------------------------------------------------"
        
        read -p "Enable SSH Brute-Force & Success Tracking [Y/n] (Current: $TRACK_SSH): " input
        TRACK_SSH=${input:-${TRACK_SSH:-Y}}
        
        read -p "Enable Sudo Privilege Escalation Tracking [Y/n] (Current: $TRACK_SUDO): " input
        TRACK_SUDO=${input:-${TRACK_SUDO:-Y}}

        read -p "Enable UFW Firewall Port Probe Tracking [Y/n] (Current: $TRACK_UFW): " input
        TRACK_UFW=${input:-${TRACK_UFW:-Y}}

        read -p "Enable Pi-Hole Web Dashboard Login Tracking [Y/n] (Current: $TRACK_PIHOLE): " input
        TRACK_PIHOLE=${input:-${TRACK_PIHOLE:-Y}}

        read -p "Enable Bandwidth Traffic Spike Monitor [Y/n] (Current: $TRACK_BANDWIDTH): " input
        TRACK_BANDWIDTH=${input:-${TRACK_BANDWIDTH:-Y}}

        read -p "Bandwidth Spike Limit in MB/min (Current: ${BANDWIDTH_THRESHOLD_MB:-100}): " input
        BANDWIDTH_THRESHOLD_MB=${input:-${BANDWIDTH_THRESHOLD_MB:-100}}
    else
        source "$CONFIG_FILE"
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

# Save configuration file
cat << EOL > "$CONFIG_FILE"
TRACK_SSH="$TRACK_SSH"
TRACK_SUDO="$TRACK_SUDO"
TRACK_UFW="$TRACK_UFW"
TRACK_PIHOLE="$TRACK_PIHOLE"
TRACK_BANDWIDTH="$TRACK_BANDWIDTH"
BANDWIDTH_THRESHOLD_MB="$BANDWIDTH_THRESHOLD_MB"
EOL

chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
echo "✅ Security configuration saved."
echo ""

# ==============================================================================
# 2. WRITE THE REAL SECURITY MONITORING ENGINE ($MONITOR_SCRIPT)
# ==============================================================================
echo "📝 Writing security monitoring engine..."
cat << 'SCRIPT' > "$MONITOR_SCRIPT"
#!/bin/bash

CONFIG_FILE="/home/raspi3b/PiTweaks/security/security_config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

DISCORD_ALERT_CHAN="/tmp/pi_discord_alert_queue.txt"

# Helper function to query real IP geolocation
get_geo_info() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! "$ip" =~ ^192\.168\. ]] && [[ ! "$ip" =~ ^10\. ]]; then
        local response=$(curl -s --max-time 3 "http://ip-api.com/json/$ip?fields=country,regionName,isp")
        if [ $? -eq 0 ] && [ -n "$response" ]; then
            local country=$(echo "$response" | jq -r '.country // empty')
            local region=$(echo "$response" | jq -r '.regionName // empty')
            local isp=$(echo "$response" | jq -r '.isp // empty')
            if [ -n "$country" ]; then
                echo "• **Origin:** $region, $country ($isp)"
                return
            fi
        fi
    fi
    echo "• **Origin:** Local / Private Network or Unknown"
}

# 1. SSH TRACKER
if [[ "${TRACK_SSH^^}" =~ ^Y ]]; then
    AUTH_LOG="/var/log/auth.log"
    STATE_FILE="/tmp/pi_sec_auth_line.txt"
    if [ -f "$AUTH_LOG" ]; then
        [ ! -f "$STATE_FILE" ] && wc -l < "$AUTH_LOG" > "$STATE_FILE"
        LAST_LINE=$(cat "$STATE_FILE")
        CURRENT_LINE=$(wc -l < "$AUTH_LOG")
        if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
            NEW_LOGS=$(tail -n +$((LAST_LINE + 1)) "$AUTH_LOG")
            while IFS=read -r line; do
                if echo "$line" | grep -q "Failed password"; then
                    SRC_IP=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)
                    USER_ATTEMPT=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="for") print $(i+1)}')
                    GEO=$(get_geo_info "$SRC_IP")
                    MSG="🚨 **SECURITY ALERT: Failed SSH Login**\n• **User:** ${USER_ATTEMPT:-Unknown}\n• **Source IP:** ${SRC_IP:-Unknown}\n$GEO\n• **Time:** $(date '+%Y-%m-%d %H:%M:%S')"
                    echo "$MSG" >> "$DISCORD_ALERT_CHAN"
                elif echo "$line" | grep -q "Accepted publickey" || echo "$line" | grep -q "Accepted password"; then
                    SRC_IP=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)
                    USER_ATTEMPT=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="for") print $(i+1)}')
                    GEO=$(get_geo_info "$SRC_IP")
                    MSG="🔓 **SECURITY NOTICE: Successful SSH Login**\n• **User:** ${USER_ATTEMPT:-Unknown}\n• **Source IP:** ${SRC_IP:-Unknown}\n$GEO\n• **Time:** $(date '+%Y-%m-%d %H:%M:%S')"
                    echo "$MSG" >> "$DISCORD_ALERT_CHAN"
                fi
            done <<< "$NEW_LOGS"
            echo "$CURRENT_LINE" > "$STATE_FILE"
        fi
    fi
fi

# 2. SUDO ESCALATION TRACKER
if [[ "${TRACK_SUDO^^}" =~ ^Y ]]; then
    AUTH_LOG="/var/log/auth.log"
    SUDO_STATE="/tmp/pi_sec_sudo_line.txt"
    if [ -f "$AUTH_LOG" ]; then
        [ ! -f "$SUDO_STATE" ] && wc -l < "$AUTH_LOG" > "$SUDO_STATE"
        LAST_LINE=$(cat "$SUDO_STATE")
        CURRENT_LINE=$(wc -l < "$AUTH_LOG")
        if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
            NEW_LOGS=$(tail -n +$((LAST_LINE + 1)) "$AUTH_LOG")
            while IFS=read -r line; do
                if echo "$line" | grep -q "COMMAND="; then
                    USER_SUDO=$(echo "$line" | grep -oP '(?<=USER=)[^ ]+' | head -n 1)
                    CMD_RUN=$(echo "$line" | grep -oP '(?<=COMMAND=).*')
                    MSG="⚠️ **SECURITY AUDIT: Sudo Command Executed**\n• **User:** ${USER_SUDO:-Unknown}\n• **Command:** \`${CMD_RUN:-Unknown}\`\n• **Time:** $(date '+%Y-%m-%d %H:%M:%S')"
                    echo "$MSG" >> "$DISCORD_ALERT_CHAN"
                fi
            done <<< "$NEW_LOGS"
            echo "$CURRENT_LINE" > "$SUDO_STATE"
        fi
    fi
fi

# 3. UFW FIREWALL PROBE TRACKER
if [[ "${TRACK_UFW^^}" =~ ^Y ]]; then
    UFW_LOG="/var/log/ufw.log"
    UFW_STATE="/tmp/pi_sec_ufw_line.txt"
    if [ -f "$UFW_LOG" ]; then
        [ ! -f "$UFW_STATE" ] && wc -l < "$UFW_LOG" > "$UFW_STATE"
        LAST_LINE=$(cat "$UFW_STATE")
        CURRENT_LINE=$(wc -l < "$UFW_LOG")
        if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
            NEW_LOGS=$(tail -n +$((LAST_LINE + 1)) "$UFW_LOG")
            while IFS=read -r line; do
                if echo "$line" | grep -q "BLOCK"; then
                    SRC_IP=$(echo "$line" | grep -oP '(?<=SRC=)[^ ]+' | head -n 1)
                    DST_PORT=$(echo "$line" | grep -oP '(?<=DPT=)[^ ]+' | head -n 1)
                    MSG="🛡️ **FIREWALL BLOCK: External Probe Detected**\n• **Blocked IP:** ${SRC_IP:-Unknown}\n• **Target Port:** ${DST_PORT:-Unknown}\n• **Time:** $(date '+%Y-%m-%d %H:%M:%S')"
                    echo "$MSG" >> "$DISCORD_ALERT_CHAN"
                fi
            done <<< "$NEW_LOGS"
            echo "$CURRENT_LINE" > "$UFW_STATE"
        fi
    fi
fi

# 4. PI-HOLE WEB DASHBOARD LOGIN TRACKER
if [[ "${TRACK_PIHOLE^^}" =~ ^Y ]]; then
    LIGHTTPD_LOG="/var/log/lighttpd/access.log"
    PIHOLE_STATE="/tmp/pi_sec_pihole_line.txt"
    if [ -f "$LIGHTTPD_LOG" ]; then
        [ ! -f "$PIHOLE_STATE" ] && wc -l < "$LIGHTTPD_LOG" > "$PIHOLE_STATE"
        LAST_LINE=$(cat "$PIHOLE_STATE")
        CURRENT_LINE=$(wc -l < "$LIGHTTPD_LOG")
        if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
            NEW_LOGS=$(tail -n +$((LAST_LINE + 1)) "$LIGHTTPD_LOG")
            while IFS=read -r line; do
                if echo "$line" | grep -q "POST /admin" || echo "$line" | grep -q "login"; then
                    SRC_IP=$(echo "$line" | awk '{print $1}')
                    MSG="🌐 **WEB ADMIN NOTICE: Pi-Hole Dashboard Activity**\n• **Source IP:** ${SRC_IP:-Unknown}\n• **Action:** Admin Panel Authentication / Request\n• **Time:** $(date '+%Y-%m-%d %H:%M:%S')"
                    echo "$MSG" >> "$DISCORD_ALERT_CHAN"
                fi
            done <<< "$NEW_LOGS"
            echo "$CURRENT_LINE" > "$PIHOLE_STATE"
        fi
    fi
fi

# 5. BANDWIDTH TRAFFIC SPIKE MONITOR
if [[ "${TRACK_BANDWIDTH^^}" =~ ^Y ]]; then
    BW_STATE="/tmp/pi_sec_bw_state.txt"
    DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
    if [ -n "$DEFAULT_IFACE" ]; then
        CURRENT_BYTES=$(awk -v iface="$DEFAULT_IFACE" '$1 == iface":" {print $2 + $10}' /proc/net/dev)
        CURRENT_TIME=$(date +%s)
        if [ -f "$BW_STATE" ]; then
            read LAST_BYTES LAST_TIME < "$BW_STATE"
            BYTES_DIFF=$(( CURRENT_BYTES - LAST_BYTES ))
            TIME_DIFF=$(( CURRENT_TIME - LAST_TIME ))
            if [ "$TIME_DIFF" -gt 0 ] && [ "$BYTES_DIFF" -gt 0 ]; then
                BYTES_PER_SEC=$(( BYTES_DIFF / TIME_DIFF ))
                MB_PER_MIN=$(( BYTES_PER_SEC * 60 / 1024 / 1024 ))
                THRESHOLD=${BANDWIDTH_THRESHOLD_MB:-100}
                if [ "$MB_PER_MIN" -gt "$THRESHOLD" ]; then
                    MSG="📈 **TRAFFIC SPIKE WARNING**\n• **Interface:** $DEFAULT_IFACE\n• **Usage Rate:** ~${MB_PER_MIN} MB/min (Threshold: ${THRESHOLD} MB/min)\n• **Time:** $(date '+%Y-%m-%d %H:%M:%S')"
                    echo "$MSG" >> "$DISCORD_ALERT_CHAN"
                fi
            fi
        fi
        echo "$CURRENT_BYTES $CURRENT_TIME" > "$BW_STATE"
    fi
fi
SCRIPT

chmod +x "$MONITOR_SCRIPT"
chown "$CURRENT_USER:$CURRENT_USER" "$MONITOR_SCRIPT"

# ==============================================================================
# 3. CRON JOB INTEGRATION
# ==============================================================================
echo "⏰ Scheduling security watchdog cron job..."
(crontab -l 2>/dev/null | grep -v "sec_monitor.sh"; echo "* * * * * sudo $MONITOR_SCRIPT > /dev/null 2>&1") | crontab -

echo ""
echo "✅ Security & Network Watchdog installed and scheduled successfully!"
