#!/bin/bash
# Description: Pre Ping working version of temperature alerts, alert scheduling and resource testing with Instant Watchdog Triggers. V2.0
# PERSISTENT: TRUE

# --- CONFIGURATION & WEBHOOK SETUP ---
STATUS_FILE="/tmp/pi_system_status.txt"
CONFIG_FILE="discord_webhook.conf"
CPU_THRESHOLD=90
RAM_THRESHOLD=90
DIVIDER="---------------------------------------"

setup_webhook() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$DIVIDER"
        echo "⚠️ No Discord Webhook configuration file found."
        read -p "Would you like to configure your Discord Webhook URL now? (y/n): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            read -p "Enter your Discord Webhook URL: " webhook_input
            echo "DISCORD_WEBHOOK_URL=\"$webhook_input\"" > "$CONFIG_FILE"
            echo "✔ Webhook saved successfully to $CONFIG_FILE"
        else
            echo "DISCORD_WEBHOOK_URL=\"\"" > "$CONFIG_FILE"
            echo "⚠️ Proceeding without a webhook configured."
        fi
        echo "$DIVIDER"
    else
        source "$CONFIG_FILE"
        if [ "$1" = "install_notify" ] || [ -z "$1" ]; then
            echo "$DIVIDER"
            read -p "Do you want to re-configure your Discord Webhook URL? (y/n): " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                read -p "Enter your new Discord Webhook URL: " webhook_input
                echo "DISCORD_WEBHOOK_URL=\"$webhook_input\"" > "$CONFIG_FILE"
                echo "✔ Webhook updated and overwritten in $CONFIG_FILE"
            else
                echo "✔ Using existing Webhook configuration from $CONFIG_FILE"
            fi
            echo "$DIVIDER"
        fi
    fi
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

setup_cron() {
    local script_path
    script_path="$(realpath "$0")"
    
    if ! crontab -l 2>/dev/null | grep -q "$script_path temp_report"; then
        echo "$DIVIDER"
        read -p "Would you like to setup an automatic background cron job to monitor stats every minute? (y/n): " cron_choice
        if [[ "$cron_choice" =~ ^[Yy]$ ]]; then
            (crontab -l 2>/dev/null; echo "* * * * * /bin/bash $script_path temp_report >> /tmp/pi_monitor.log 2>&1") | crontab -
            echo "✔ Cron job installed successfully! Monitoring every 1 minute."
        else
            echo "⚠️ Skipped cron job setup."
        fi
        echo "$DIVIDER"
    fi
}

setup_webhook "$1"
[ -z "$1" ] || [ "$1" = "install_notify" ] && setup_cron

send_discord_webhook() {
    local message="$1"
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -H "Content-Type: application/json" \
             -X POST \
             -d "{\"content\": \"$message\"}" \
             "$DISCORD_WEBHOOK_URL" &>/dev/null
    fi
}

get_top_cpu() {
    ps -eo comm,%cpu,%mem --sort=-%cpu | head -n 4 | tail -n 3 | awk '{printf "  • %s: CPU %s%% | RAM %s%%\n", $1, $2, $3}'
}

get_top_ram() {
    ps -eo comm,%cpu,%mem --sort=-%mem | head -n 4 | tail -n 3 | awk '{printf "  • %s: RAM %s%% | CPU %s%%\n", $1, $3, $2}'
}

RAW_TEMP=$(vcgencmd measure_temp | egrep -o '[0-9]*\.[0-9]*') 2>/dev/null || echo "40.0"
TEMP=${RAW_TEMP%.*}

RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
RAM_PERC=$(( RAM_USED * 100 / RAM_TOTAL ))

CPU_IDLE=$(top -bn1 | grep "%Cpu" | awk '{print $8}' | cut -d'.' -f1)
if [ -z "$CPU_IDLE" ]; then
    CPU_IDLE=$(top -bn1 | awk '/Cpu\(s\)/ {print $8}' | cut -d'.' -f1)
fi
CPU_USAGE=$(( 100 - CPU_IDLE ))

# --- INSTANT WATCHDOG & THRESHOLD CHECK LOGIC ---
check_watchdog_alerts() {
    local t=$TEMP
    local c=$CPU_USAGE
    local r=$RAM_PERC
    local alert_sent=false

    # Temperature Ladder Checks (Immediate Trigger)
    if [ "$t" -ge 80 ]; then
        send_discord_webhook "🚨 **CRITICAL TEMP ALERT**: Temperature reached ${t}°C (Hit 80°C Ladder Limit!)"
        alert_sent=true
    elif [ "$t" -ge 70 ]; then
        send_discord_webhook "⚠️ **HIGH TEMP WARNING**: Temperature reached ${t}°C (Hit 70°C Ladder Limit)"
        alert_sent=true
    elif [ "$t" -ge 60 ]; then
        send_discord_webhook "🟨 **ELEVATED TEMP NOTICE**: Temperature reached ${t}°C (Hit 60°C Ladder Limit)"
        alert_sent=true
    fi

    # Sustained Load Checks (3-Minute Timer Logic)
    TIME_FILE="/tmp/pi_high_load_timer.txt"
    CURRENT_TIME=$(date +%s)
    
    if [ "$c" -ge "$CPU_THRESHOLD" ] || [ "$r" -ge "$RAM_THRESHOLD" ]; then
        if [ ! -f "$TIME_FILE" ]; then
            echo "$CURRENT_TIME" > "$TIME_FILE"
        else
            START_TIME=$(cat "$TIME_FILE")
            ELAPSED=$(( CURRENT_TIME - START_TIME ))
            if [ "$ELAPSED" -ge 180 ]; then
                send_discord_webhook "⚡ **SUSTAINED LOAD ALERT**: CPU at ${c}% / RAM at ${r}% maintained for over 3 minutes!"
                alert_sent=true
            fi
        fi
    else
        rm -f "$TIME_FILE"
    fi
}

# --- COMMAND ROUTER ---
if [ "$1" = "install_notify" ] || [ -z "$1" ]; then
    echo "$DIVIDER"
    echo "🟢 SUCCESS: Script compiled, config saved, and executed safely."
    echo "🟢 STATUS: discord_monitor.sh (V1.76) setup complete!"
    echo "$DIVIDER"
    WEBHOOK_MSG="🟢 **PiTweaks Status**: `discord_monitor.sh` (V1.76) installed successfully. Instant Watchdog active!"
    send_discord_webhook "$WEBHOOK_MSG"
    exit 0

elif [ "$1" = "temp_report" ]; then
    # Run the background watchdog check (fires instant alerts if thresholds breached)
    check_watchdog_alerts
    
    # Optional: If you still want a periodic status recap or log entry, it handles normally here
    exit 0

elif [ "$1" = "test_cpu" ] && [ -n "$2" ]; then
    SIM_CPU=$2
    TOP_PROCS=$(get_top_cpu)
    MSG="${DIVIDER}
🟦 ⚡ **HIGH CPU ALERT (TEST SIMULATION)**: Load sustained at ${SIM_CPU}% for 3 mins!
• **Temp:** ${RAW_TEMP}°C | **CPU:** ${SIM_CPU}% | **RAM:** ${RAM_PERC}%

**Top CPU Processes:**
${TOP_PROCS}
${DIVIDER}"
    send_discord_webhook "$MSG"
    echo "$MSG"
    exit 0

elif [ "$1" = "test_ram" ] && [ -n "$2" ]; then
    SIM_RAM=$2
    TOP_PROCS=$(get_top_ram)
    MSG="${DIVIDER}
🟦 📊 **HIGH RAM ALERT (TEST SIMULATION)**: Usage sustained at ${SIM_RAM}% for 3 mins!
• **Temp:** ${RAW_TEMP}°C | **CPU:** ${CPU_USAGE}% | **RAM:** ${SIM_RAM}%

**Top RAM Processes:**
${TOP_PROCS}
${DIVIDER}"
    send_discord_webhook "$MSG"
    echo "$MSG"
    exit 0

elif [ "$1" = "test_temp" ] && [ -n "$2" ]; then
    SIM_TEMP=$2
    TOP_PROCS=$(get_top_cpu)
    MSG="${DIVIDER}
🟦 🌡️ **TEMP WARNING (TEST SIMULATION)**: CPU reached ${SIM_TEMP}°C!
• **Temp:** ${SIM_TEMP}°C | **CPU:** ${CPU_USAGE}% | **RAM:** ${RAM_PERC}%

**Top CPU Processes:**
${TOP_PROCS}
${DIVIDER}"
    send_discord_webhook "$MSG"
    echo "$MSG"
    exit 0
fi
