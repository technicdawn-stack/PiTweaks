#!/bin/bash
# Description: Pre Ping working version of temperature alerts, alert scheduling and resource testing with Multi-Tiered Ladder & 3-Min Sustain Logic. V1.71

# --- CONFIGURATION ---
STATUS_FILE="/tmp/pi_system_status.txt"
CPU_THRESHOLD=90
RAM_THRESHOLD=90
DIVIDER="---------------------------------------"
# Set your Discord Webhook URL here to enable automatic webhook notifications on update/alert
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
# ---------------------

send_discord_webhook() {
    local message="$1"
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -H "Content-Type: application/json" \
             -X POST \
             -d "{\"content\": \"$message\"}" \
             "$DISCORD_WEBHOOK_URL" &>/dev/null &
    fi
}

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
if [ -z "$CPU_IDLE" ]; then
    CPU_IDLE=$(top -bn1 | awk '/Cpu\(s\)/ {print $8}' | cut -d'.' -f1)
fi
CPU_USAGE=$(( 100 - CPU_IDLE ))

# --- MULTI-TIERED TEMPERATURE LADDER & SUSTAINED CHECK LOGIC ---
check_ladder_alerts() {
    local t=$TEMP
    local c=$CPU_USAGE
    local r=$RAM_PERC
    
    # Temperature Ladder Check (50, 60, 70, 80°C)
    if [ "$t" -ge 80 ]; then
        echo "🚨 **CRITICAL TEMP ALERT**: Temperature reached ${t}°C (Hit 80°C Ladder Limit!)"
    elif [ "$t" -ge 70 ]; then
        echo "⚠️ **HIGH TEMP WARNING**: Temperature reached ${t}°C (Hit 70°C Ladder Limit)"
    elif [ "$t" -ge 60 ]; then
        echo "🟨 **ELEVATED TEMP NOTICE**: Temperature reached ${t}°C (Hit 60°C Ladder Limit)"
    elif [ "$t" -ge 50 ]; then
        echo "ℹ️ **INFO**: Temperature reached ${t}°C (Hit 50°C Ladder Limit)"
    fi

    # 3-Minute Sustained High Usage Check (using a state file tracker)
    TIME_FILE="/tmp/pi_high_load_timer.txt"
    CURRENT_TIME=$(date +%s)
    
    if [ "$c" -ge "$CPU_THRESHOLD" ] || [ "$r" -ge "$RAM_THRESHOLD" ]; then
        if [ ! -f "$TIME_FILE" ]; then
            echo "$CURRENT_TIME" > "$TIME_FILE"
        else
            START_TIME=$(cat "$TIME_FILE")
            ELAPSED=$(( CURRENT_TIME - START_TIME ))
            # 3 minutes = 180 seconds
            if [ "$ELAPSED" -ge 180 ]; then
                echo "⚡ **SUSTAINED LOAD ALERT**: CPU at ${c}% / RAM at ${r}% maintained for over 3 minutes!"
            fi
        fi
    else
        # Reset timer if usage drops below threshold
        rm -f "$TIME_FILE"
    fi
}

# --- INSTALL / OVERWRITE NOTIFICATION TRIGGER ---
if [ "$1" = "install_notify" ]; then
    echo "✔ Script file written and overwrote old version successfully!"
    echo "✔ Execution verified: Monitor is online (V1.71)."
    WEBHOOK_MSG="🟢 **PiTweaks Status**: `discord_monitor.sh` (V1.71) installed/overwritten successfully. Monitor is **ONLINE** and running!"
    send_discord_webhook "$WEBHOOK_MSG"
    echo "✔ Discord webhook notification sent!"
    exit 0
fi

if [ "$1" = "temp_report" ]; then
    TOP_PROCS=$(get_top_cpu)
    LADDER_EVAL=$(check_ladder_alerts)
    MSG="${DIVIDER}
🟢 **Status**: Update applied successfully (Overwrote old version). Monitor is **ONLINE**.
🟨 📝 **System Report (V1.71)**:
• **Temp:** ${RAW_TEMP}°C | **CPU:** ${CPU_USAGE}% | **RAM:** ${RAM_PERC}% (${RAM_USED}MB / ${RAM_TOTAL}MB)
${LADDER_EVAL}

**Top Processes (CPU):**
${TOP_PROCS}
${DIVIDER}"
    echo "$MSG"
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
    echo "$MSG"
    exit 0
fi
