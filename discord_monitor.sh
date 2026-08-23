#!/bin/bash

# --- CONFIGURATION ---
STATUS_FILE="/tmp/pi_system_status.txt"
CPU_THRESHOLD=90
RAM_THRESHOLD=90
DIVIDER="---------------------------------------"
# ---------------------

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

if [ "$1" = "temp_report" ]; then
    TOP_PROCS=$(get_top_cpu)
    MSG="${DIVIDER}
🟨 📝 **System Report**:
• **Temp:** ${RAW_TEMP}°C | **CPU:** ${CPU_USAGE}% | **RAM:** ${RAM_PERC}% (${RAM_USED}MB / ${RAM_TOTAL}MB)

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
