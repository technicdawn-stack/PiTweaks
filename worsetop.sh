#!/bin/bash

# Description: WORSETOP - Quite litterally a worse top...
# PERSISTENT: FALSE
# Category: Tools

# Hide cursor and ensure cleanup on exit
printf "\033[?25l"
trap "printf '\033[?25h'; clear; exit" INT TERM EXIT

clear

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

    echo "┌────────────────────────────────────────────────────────┐"
    echo "│                    ░▒▓█ WORSETOP █▓▒░                  │"
    echo "└────────────────────────────────────────────────────────┘"
    echo "=========================================================="
    echo " 📈 COMPUTE CORE ARRAYS"
    echo "=========================================================="
    echo "• CPU Total Load:    $(printf "%.1f%%\n" "$LOAD_PCT")"
    echo "• Clock Frequency:   $FREQ_MHZ MHz"
    echo "• Core Voltage:      $VOLTS_RAW V"
    echo ""
    echo "=========================================================="
    echo " 💾 STORAGE & HEALTH DIAGNOSTICS"
    echo "=========================================================="
    echo "• Core Temp:         $TEMP°C"
    echo "• Hardware Status:   $STATUS"
    echo "• System Uptime:     $UPTIME_STR"
    echo "• Memory Allocation: ${RAM_USED}MB / ${RAM_TOTAL}MB (${RAM_PCT}%)"
    echo "• Disk Utilization:  ${DISK_PCT}% used"
    echo ""
    echo "=========================================================="
    echo " ⚡ SIMULATED PACKAGE ELECTRICAL FOOTPRINT"
    echo "=========================================================="
    echo "• EST. POWER DRAW:   $EST_POWER Watts"
    echo "=========================================================="
    echo "Press [Ctrl + C] to terminate memory loop framework.      "

    sleep 2
done
