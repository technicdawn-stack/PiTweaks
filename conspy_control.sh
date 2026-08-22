#!/bin/bash
# Description: Lightweight universal setup manager for Raspberry Pi Lite monitor & Discord alerts

# Ensure script runs interactively
exec < /dev/tty

# Check for whiptail (install if missing)
if ! command -v whiptail &> /dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y whiptail -qq
fi

# Config storage path
CONFIG_FILE="$HOME/.config/pi_monitor_settings.conf"
mkdir -p "$HOME/.config"

# Load existing configuration if available
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    WEBHOOK_URL=""
    AUTO_CONSPY="ON"
fi

# 1. MAIN CONFIGURATION MENU (Whiptail Toggles)
CHOICES=$(whiptail --title "🍓 Pi Lite Control & Monitor Setup" \
    --checklist "Use [SPACE] to toggle options, [UP/DOWN] to navigate, [ENTER] to confirm:" 18 70 3 \
    "CONSPY" "Auto-detect screen and enable conspy mirroring" "$AUTO_CONSPY" \
    3>&1 1>&2 2>&3)

# Exit if user cancelled
if [ $? -ne 0 ]; then
    echo "Setup cancelled."
    exit 0
fi

# Parse toggle choices
if [[ "$CHOICES" == *"CONSPY"* ]]; then
    AUTO_CONSPY="ON"
else
    AUTO_CONSPY="OFF"
fi

# 2. WEBHOOK INPUT PROMPT
WEBHOOK_URL=$(whiptail --title "Discord Webhook Integration" \
    --inputbox "Enter your Discord Webhook URL below:" 10 60 "$WEBHOOK_URL" \
    3>&1 1>&2 2>&3)

if [ -z "$WEBHOOK_URL" ]; then
    whiptail --title "Error" --msgbox "Webhook URL cannot be empty! Setup aborted." 8 40
    exit 1
fi

# Save settings
echo "WEBHOOK_URL=\"$WEBHOOK_URL\"" > "$CONFIG_FILE"
echo "AUTO_CONSPY=\"$AUTO_CONSPY\"" >> "$CONFIG_FILE"

# 3. DEPENDENCY INSTALLATION
{
    echo 10; sleep 1
    sudo apt-get update -qq
    echo 40
    sudo apt-get install -y jq conspy -qq
    echo 80
    sleep 1
    echo 100
} | whiptail --gauge "Installing required packages (jq, conspy)..." 6 50 0

# 4. WRITE THE MONITORING SCRIPT
cat << 'SCRIPT' > ~/temp_monitor.sh
#!/bin/bash

CONFIG_FILE="$HOME/.config/pi_monitor_settings.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

DISCORD_URL="${WEBHOOK_URL}"
STATUS_FILE="/tmp/pi_system_status.txt"
CPU_THRESHOLD=90
RAM_THRESHOLD=90
DIVIDER="---------------------------------------"

get_top_cpu() {
    ps -eo comm,%cpu,%mem --sort=-%cpu | head -n 4 | tail -n 3 | awk '{printf "  • %s: CPU %s%% | RAM %s%%\n", $1, $2, $3}'
}

get_top_ram() {
    ps -eo comm,%cpu,%mem --sort=-%mem | head -n 4 | tail -n 3 | awk '{printf "  • %s: RAM %s%% | CPU %s%%\n", $1, $3, $2}'
}

RAW_TEMP=$(vcgencmd measure_temp | egrep -o '[0-9]*\.[0-9]*')
TEMP=${RAW_TEMP%.*}

RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
RAM_PERC=$(( RAM_USED * 100 / RAM_TOTAL ))

CPU_IDLE=$(top -bn1 | grep "%Cpu" | awk '{print $8}' | cut -d'.' -f1)
[ -z "$CPU_IDLE" ] && CPU_IDLE=$(top -bn1 | awk '/Cpu\(s\)/ {print $8}' | cut -d'.' -f1)
CPU_USAGE=$(( 100 - CPU_IDLE ))

if [ "$1" = "temp_report" ]; then
    TOP_PROCS=$(get_top_cpu)
    MSG="${DIVIDER}
🟨 📝 **System Report**:
• **Temp:** ${RAW_TEMP}°C | **CPU:** ${CPU_USAGE}% | **RAM:** ${RAM_PERC}% (${RAM_USED}MB / ${RAM_TOTAL}MB)

**Top Processes (CPU):**
${TOP_PROCS}
${DIVIDER}"
    PAYLOAD=$(jq -n --arg content "$MSG" '{content: $content}')
    curl -H "Content-Type: application/json" -X POST -d "$PAYLOAD" "$DISCORD_URL" > /dev/null 2>&1
    exit 0
fi

# State tracking & threshold safety checks...
if [ -f "$STATUS_FILE" ]; then
    LAST_PRIORITY=$(sed -n '1p' "$STATUS_FILE")
    CPU_COUNT=$(sed -n '2p' "$STATUS_FILE")
    RAM_COUNT=$(sed -n '3p' "$STATUS_FILE")
else
    LAST_PRIORITY=0; CPU_COUNT=0; RAM_COUNT=0
fi

LAST_PRIORITY=${LAST_PRIORITY:-0}
CPU_COUNT=${CPU_COUNT:-0}
RAM_COUNT=${RAM_COUNT:-0}

if [ "$TEMP" -ge 80 ]; then PRIORITY=4
elif [ "$TEMP" -ge 70 ]; then PRIORITY=3
elif [ "$TEMP" -ge 60 ]; then PRIORITY=2
elif [ "$TEMP" -ge 50 ]; then PRIORITY=1
else PRIORITY=0; fi

if [ "$PRIORITY" -gt "$LAST_PRIORITY" ]; then
    TOP_PROCS=$(get_top_cpu)
    MSG="${DIVIDER}
🟥 🌡️ **TEMP WARNING**: CPU reached ${RAW_TEMP}°C!
• **Temp:** ${RAW_TEMP}°C | **CPU:** ${CPU_USAGE}% | **RAM:** ${RAM_PERC}%

**Top CPU Processes:**
${TOP_PROCS}
${DIVIDER}"
    PAYLOAD=$(jq -n --arg content "$MSG" '{content: $content}')
    curl -H "Content-Type: application/json" -X POST -d "$PAYLOAD" "$DISCORD_URL" > /dev/null 2>&1
fi
LAST_PRIORITY=$PRIORITY

printf "%s\n%s\n%s\n" "$LAST_PRIORITY" "$CPU_COUNT" "$RAM_COUNT" > "$STATUS_FILE"
SCRIPT

chmod +x ~/temp_monitor.sh

# 5. CONSPY SCREEN CHECK & SETUP
SCREEN_STATUS_MSG="Conspy screen mirroring is disabled."
if [ "$AUTO_CONSPY" = "ON" ]; then
    if tty | grep -q "/dev/tty"; then
        SCREEN_STATUS_MSG="Active screen detected! You can view session mirroring via 'conspy 1'."
    else
        SCREEN_STATUS_MSG="Enabled in config, but no active physical tty detected right now."
    fi
fi

# 6. SETUP ALIASES & CRON
grep -qF "alias temp_report" ~/.bashrc || echo "alias temp_report='~/temp_monitor.sh temp_report'" >> ~/.bashrc
(crontab -l 2>/dev/null | grep -v "temp_monitor.sh"; echo "* * * * * ~/temp_monitor.sh > /dev/null 2>&1") | crontab -

whiptail --title "✅ Setup Complete!" --msgbox "Configuration saved successfully!

• Background monitor scheduled via cron.
• Shortcut 'temp_report' registered.
• $SCREEN_STATUS_MSG

Run './conspy_control.sh' anytime to change your settings." 14 65
