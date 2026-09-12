#!/bin/bash

# Description: Ambiguous location deployment engine for worsetop.sh
# PERSISTENT: FALSE
# Category: Tools

# 1. Dynamically find out exactly where this script is running from
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_BIN="${CURRENT_DIR}/worsetop.sh"

echo "⚙️ Initializing Worsetop Ambiguous Installation Layout..."
echo "📂 Target Location Detected: ${CURRENT_DIR}"

# 2. Write the Worsetop Script directly into the same ambiguous directory
cat << 'EOF' > "$TARGET_BIN"
#!/bin/bash
clear

# Description: Advanced system telemetry and power physics simulator.
# PERSISTENT: TRUE
# Category: Tools

# Fetch Core Architecture Metrics
TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d'=' -f2 | tr -d "'C" || echo "0.0")
VOLTS_RAW=$(vcgencmd measure_volts core 2>/dev/null | cut -d'=' -f2 | tr -d "V" || echo "1.2000")
FREQ_HZ=$(vcgencmd measure_clock arm 2>/dev/null | cut -d'=' -f2 || echo "1200000000")
STATUS=$(vcgencmd get_throttled 2>/dev/null | cut -d'=' -f2 || echo "0x0")

# Math Processing for Frequency and Voltage
FREQ_MHZ=$(awk "BEGIN {print $FREQ_HZ / 1000000}")
LOAD_PCT=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1 * 100 / 4}')

# Dynamic Package Power Simulator Formula
EST_POWER=$(awk "BEGIN {
    base_idle = 1.45;
    c_constant = 1.55;
    v_factor = ($VOLTS_RAW / 1.20) ^ 2;
    f_factor = $FREQ_MHZ / 1200.0;
    l_factor = $LOAD_PCT / 100.0;
    
    dynamic_draw = c_constant * v_factor * f_factor * l_factor;
    total = base_idle + dynamic_draw;
    
    if (total > 5.5) total = 5.5;
    printf \"%.2f Watts\n\", total
}")

# Render the Worsetop Interface Dashboard Layout
echo "┌────────────────────────────────────────────────────────┐"
echo "│                    ░▒▓█ WORSETOP █▓▒░                  │"
echo "└────────────────────────────────────────────────────────┘"
echo "=========================================================="
echo " 📈 COMPUTE CORE ARRAYS"
echo "=========================================================="
echo "• CPU Total Load:   $(printf "%.1f%%\n" "$LOAD_PCT")"
echo "• Clock Frequency:  $FREQ_MHZ MHz"
echo "• Core Voltage:     $VOLTS_RAW V"
echo "• Load Average:    $(uptime | awk -F'load average:' '{print $2}' | xargs)"
echo ""
echo "=========================================================="
echo " 💾 STORAGE & HEALTH DIAGNOSTICS"
echo "=========================================================="
echo "• Core Temp:        $TEMP°C"
echo "• Hardware Status:  $STATUS"
echo "• System Uptime:    $(uptime -p)"
echo "• Memory Allocation:$(free -h | awk '/Mem:/ {print $3 " / " $2 " (" $5 " free)"}')"
echo "• Disk Utilization: $(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}')"
echo ""
echo "=========================================================="
echo " ⚡ SIMULATED PACKAGE ELECTRICAL FOOTPRINT"
echo "=========================================================="
echo "• EST. POWER DRAW:  $EST_POWER"
echo "=========================================================="
EOF

# 3. Grant Executable Permissions to the newly created worsetop.sh file
chmod +x "$TARGET_BIN"

echo "✅ Installation Complete! Launching worsetop.sh automatically..."
echo "----------------------------------------------------------"
sleep 1

# 4. Instantly launch worsetop.sh using watch so it loops automatically every 2 seconds
exec watch -n 2 "$TARGET_BIN"
