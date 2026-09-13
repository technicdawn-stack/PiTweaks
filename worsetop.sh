#!/bin/bash

# Description: WORSETOP - Quite litterally a worse top... (V1.2)
# Category: Tools

# ANSI Color Codes
CYAN="\033[96m"
GREEN="\033[92m"
YELLOW="\033[93m"
RED="\033[91m"
BOLD="\033[1m"
RESET="\033[0m"

# Hide cursor and ensure cleanup on exit
printf "\033[?25l"
trap "printf '\033[?25h'; clear; exit" INT TERM EXIT

clear

# Function to generate a visual progress bar
draw_bar() {
    local val=$1
    local max=100
    local width=10
    local filled=$(awk -v v="$val" -v m="$max" -v w="$width" 'BEGIN { printf "%d", (v < 0 ? 0 : (v > m ? m : v)) * w / m }')
    local empty=$((width - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

while true; do
    # Reset cursor to top-left to avoid flicker
    printf "\033[H"

    # Fetch data values
    TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d'=' -f2 | tr -d "'C" || echo "0.0")
    VOLTS_RAW=$(vcgencmd measure_volts core 2>/dev/null | cut -d'=' -f2 | tr -d "V" || echo "1.2000")
    FREQ_HZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "1200000")
    FREQ_MHZ=$(awk "BEGIN {print $FREQ_HZ / 1000}")
    STATUS=$(vcgencmd get_throttled 2>/dev/null | cut -d'=' -f2 || echo "0x0")

    # Load and memory stats
    LOAD_PCT=$(awk '{print $1 * 100 / 4}' /proc/loadavg)
    UPTIME_STR=$(uptime -p)
    
    RAM_LINE=$(free -m | awk '/Mem:/ {print $3, $2, int($3/$2 * 100)}')
    read RAM_USED RAM_TOTAL RAM_PCT <<< "$RAM_LINE"
    
    DISK_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

    # Power calculation
    EST_POWER=$(awk -v v="$VOLTS_RAW" -v f="$FREQ_MHZ" -v l="$LOAD_PCT" 'BEGIN {
        base_idle = 1.45;
        c_constant = 1.55;
        v_factor = (v / 1.20) ^ 2;
        f_factor = f / 1200.0;
        l_factor = l / 100.0;
        total = base_idle + (c_constant * v_factor * f_factor * l_factor);
        if (total > 5.5) total = 5.5;
        printf "%.2f", total
    }')

    # Conditional color coding for temperature and status
    TEMP_VAL=${TEMP%.*}
    if [ "$TEMP_VAL" -ge 75 ]; then
        TEMP_COLOR="$RED"
    elif [ "$TEMP_VAL" -ge 60 ]; then
        TEMP_COLOR="$YELLOW"
    else
        TEMP_COLOR="$GREEN"
    fi

    if [ "$STATUS" = "0x0" ]; then
        STATUS_COLOR="$GREEN"
        STATUS_TEXT="NORMAL"
    else
        STATUS_COLOR="$RED"
        STATUS_TEXT="$STATUS (THROTTLED)"
    fi

    LOAD_BAR=$(draw_bar "$LOAD_PCT")

    printf "${CYAN}╔══════════════════════════════════════════════════════════╗\n"
    printf "║                    ${BOLD}░▒▓█ WORSETOP █▓▒░                    ${RESET}${CYAN}║\n"
    printf "╚══════════════════════════════════════════════════════════╝${RESET}\n"
    printf "${CYAN} 📈 COMPUTE CORE ARRAYS${RESET}\n"
    printf "────────────────────────────────────────────────────────────\n"
    printf " • CPU Total Load:    [%s] ${BOLD}%5.1f%%${RESET}\n" "$LOAD_BAR" "$LOAD_PCT"
    printf " • Clock Frequency:   ${BOLD}%s MHz${RESET}\n" "$FREQ_MHZ"
    printf " • Core Voltage:      ${BOLD}%s V${RESET}\n" "$VOLTS_RAW"
    printf "\n"
    printf "${CYAN} 💾 STORAGE & HEALTH DIAGNOSTICS${RESET}\n"
    printf "────────────────────────────────────────────────────────────\n"
    printf " • Core Temp:         ${TEMP_COLOR}${BOLD}%s°C${RESET}\n" "$TEMP"
    printf " • Hardware Status:   ${STATUS_COLOR}${BOLD}%s${RESET}\n" "$STATUS_TEXT"
    printf " • System Uptime:     %s\n" "$UPTIME_STR"
    printf " • Memory Allocation: %sMB / %sMB (${BOLD}%s%%${RESET})\n" "$RAM_USED" "$RAM_TOTAL" "$RAM_PCT"
    printf " • Disk Utilization:  ${BOLD}%s%%${RESET} used\n" "$DISK_PCT"
    printf "\n"
    printf "${CYAN} ⚡ SIMULATED PACKAGE ELECTRICAL FOOTPRINT${RESET}\n"
    printf "────────────────────────────────────────────────────────────\n"
    printf " • EST. POWER DRAW:   ${YELLOW}${BOLD}%s Watts${RESET}\n" "$EST_POWER"
    printf "════════════════════════════════════════════════════════════\n"
    printf " Press ${BOLD}[q]${RESET} or ${BOLD}[Ctrl + C]${RESET} to terminate.\n"

    # Non-blocking sleep with key check for 'q'
    read -t 2 -n 1 key
    if [[ $key = "q" || $key = "Q" ]]; then
        printf "\033[?25h"
        clear
        exit 0
    fi
done
