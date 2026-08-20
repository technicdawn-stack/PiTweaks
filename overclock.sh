#!/bin/bash
# Description: Smart Raspberry Pi overclocking manager with live thermal monitoring and safe backups.
# ==============================================================================
# 🍓 PiTweaks - Smart Overclock & Power Manager
# ==============================================================================

# Ensure script is run with elevated privileges to edit boot files
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this script with sudo."
    exit 1
fi

# Locate the active Raspberry Pi boot config file
CONFIG_FILE="/boot/firmware/config.txt"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"

ORIG_BACKUP="${CONFIG_FILE}.original"
LAST_BACKUP="${CONFIG_FILE}.last"

# ------------------------------------------------------------------------------
# 1. HANDLE DUAL-STAGE BACKUPS
# ------------------------------------------------------------------------------
if [ ! -f "$ORIG_BACKUP" ]; then
    cp "$CONFIG_FILE" "$ORIG_BACKUP"
fi

cp "$CONFIG_FILE" "$LAST_BACKUP"

# ------------------------------------------------------------------------------
# 2. DETECT HARDWARE, THERMALS, & THROTTLE STATE
# ------------------------------------------------------------------------------
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Raspberry Pi")

LIVE_FREQ=$(vcgencmd measure_clock arm 2>/dev/null | awk -F= '{printf "%.0f MHz", $2/1000000}')
LIVE_VOLT=$(vcgencmd measure_volts core 2>/dev/null | cut -d= -f2)
TEMP_RAW=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9.]+' || echo "0")
TEMP=${TEMP_RAW%.*}

# Check for historical power or thermal throttling
THROTTLE_HEX=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
THROTTLE_STATUS="Normal (No throttling detected)"
if [ "$THROTTLE_HEX" != "0x0" ] && [ -n "$THROTTLE_HEX" ]; then
    THROTTLE_STATUS="⚠️ Throttled/Under-voltage detected! Code: $THROTTLE_HEX"
fi

if grep -q "PROFILE: Eco" "$CONFIG_FILE"; then
    ACTIVE_PRESET="Eco"
elif grep -q "PROFILE: Quiet" "$CONFIG_FILE"; then
    ACTIVE_PRESET="Quiet"
elif grep -q "PROFILE: Default" "$CONFIG_FILE"; then
    ACTIVE_PRESET="Default"
elif grep -q "PROFILE: Performance" "$CONFIG_FILE"; then
    ACTIVE_PRESET="Performance"
elif grep -q "PROFILE: High Performance" "$CONFIG_FILE"; then
    ACTIVE_PRESET="High Performance"
elif grep -q "arm_freq" "$CONFIG_FILE" || grep -q "over_voltage" "$CONFIG_FILE"; then
    ACTIVE_PRESET="Custom"
else
    ACTIVE_PRESET="Default (Factory Stock)"
fi

# ------------------------------------------------------------------------------
# 3. DISPLAY CURRENT STATE & RECOMMENDATIONS
# ------------------------------------------------------------------------------
clear
echo "=========================================="
echo " 📊 Current System State"
echo "=========================================="
echo "• Hardware Model:   $MODEL"
echo "• Active Clock:     ${LIVE_FREQ:-N/A}"
echo "• Core Voltage:     ${LIVE_VOLT:-N/A}"
echo "• Core Temp:        ${TEMP}°C"
echo "• Power/Throttle:   $THROTTLE_STATUS"
echo "• Active Preset:    [$ACTIVE_PRESET]"
echo "=========================================="
echo ""

echo "=========================================="
echo " 💡 Hardware Recommendation"
echo "=========================================="
if [ "$TEMP" -gt 65 ]; then
    echo "• Suggested Option: [1] Eco or [2] Quiet"
    echo "  Reason: Temps are warm (${TEMP}°C). Lower clocks prevent thermal throttling."
elif [ "$TEMP" -lt 45 ]; then
    echo "• Suggested Option: [4] Performance or [5] High Performance"
    echo "  Reason: Excellent thermal headroom (${TEMP}°C). Boosting is completely safe."
else
    echo "• Suggested Option: [3] Default or [4] Performance"
    echo "  Reason: Temperatures are normal (${TEMP}°C)."
fi
echo "=========================================="
echo ""

# ------------------------------------------------------------------------------
# 4. USER INTERFACE
# ------------------------------------------------------------------------------
echo "Select a preset or monitoring option:"
echo "  1) Eco (Low power & thermal priority)"
echo "  2) Quiet (Stock clock with low idle scaling)"
echo "  3) Default (Reset to stock factory settings)"
echo "  4) Performance (Safe mild boost)"
echo "  5) High Performance (Max safe clock - cooling required)"
echo "  ----------------------------------------"
echo "  6) Restore Last Preset State ($LAST_BACKUP)"
echo "  7) Restore Original Factory Config ($ORIG_BACKUP)"
echo "  8) Live Thermal & Clock Monitor Mode"
echo "  9) Exit"
echo ""

read -p "Enter selection [1-9]: " CHOICE </dev/tty

# Function to safely update config.txt and prompt for reboot
apply_settings() {
    local PROFILE_NAME="$1"
    local CONFIG_BODY="$2"

    sed -i '/# --- PiTweaks Overclock Start ---/,/# --- PiTweaks Overclock End ---/d' "$CONFIG_FILE"

    printf '\n# --- PiTweaks Overclock Start ---\n# PROFILE: %s\n%b\n# --- PiTweaks Overclock End ---\n' \
        "$PROFILE_NAME" "$CONFIG_BODY" >> "$CONFIG_FILE"

    echo ""
    echo "✅ Successfully applied [$PROFILE_NAME] profile!"
    
    read -p "Would you like to reboot now to apply changes? [y/N]: " REBOOT_CHOICE </dev/tty
    if [[ "$REBOOT_CHOICE" =~ ^[yY]$ ]]; then
        echo "🔄 Rebooting Raspberry Pi..."
        sudo reboot
    else
        echo "⚠️ Remember to reboot later for changes to take effect."
    fi
}

# ------------------------------------------------------------------------------
# 5. EXECUTE SELECTION
# ------------------------------------------------------------------------------
case "$CHOICE" in
    1)
        SETTINGS="arm_freq=800\ninitial_turbo=0"
        apply_settings "Eco" "$SETTINGS"
        ;;
    2)
        SETTINGS="arm_freq_min=600"
        apply_settings "Quiet" "$SETTINGS"
        ;;
    3)
        sed -i '/# --- PiTweaks Overclock Start ---/,/# --- PiTweaks Overclock End ---/d' "$CONFIG_FILE"
        echo ""
        echo "✅ Reset config back to stock Default settings!"
        read -p "Would you like to reboot now? [y/N]: " REBOOT_CHOICE </dev/tty
        [[ "$REBOOT_CHOICE" =~ ^[yY]$ ]] && sudo reboot
        ;;
    4)
        if [[ "$MODEL" =~ "Pi 5" ]]; then
            SETTINGS="arm_freq=2600"
        elif [[ "$MODEL" =~ "Pi 4" ]]; then
            SETTINGS="arm_freq=1800\nover_voltage=2"
        else
            SETTINGS="arm_freq=1300\nover_voltage=2"
        fi
        apply_settings "Performance" "$SETTINGS"
        ;;
    5)
        if [[ "$MODEL" =~ "Pi 5" ]]; then
            SETTINGS="arm_freq=2900\nover_voltage_delta=50000"
        elif [[ "$MODEL" =~ "Pi 4" ]]; then
            SETTINGS="arm_freq=2000\nover_voltage=6\ngpu_freq=750"
        else
            SETTINGS="arm_freq=1350\nover_voltage=5"
        fi
        apply_settings "High Performance" "$SETTINGS"
        ;;
    6)
        cp "$LAST_BACKUP" "$CONFIG_FILE"
        echo ""
        echo "🔄 Restored config from last state backup ($LAST_BACKUP)."
        read -p "Would you like to reboot now? [y/N]: " REBOOT_CHOICE </dev/tty
        [[ "$REBOOT_CHOICE" =~ ^[yY]$ ]] && sudo reboot
        ;;
    7)
        cp "$ORIG_BACKUP" "$CONFIG_FILE"
        echo ""
        echo "🔄 Restored original factory config ($ORIG_BACKUP)."
        read -p "Would you like to reboot now? [y/N]: " REBOOT_CHOICE </dev/tty
        [[ "$REBOOT_CHOICE" =~ ^[yY]$ ]] && sudo reboot
        ;;
    8)
        echo ""
        echo "📈 Entering Live Monitor Mode. Press [Ctrl+C] to exit."
        echo "--------------------------------------------------"
        while true; do
            LF=$(vcgencmd measure_clock arm 2>/dev/null | awk -F= '{printf "%.0f MHz", $2/1000000}')
            LV=$(vcgencmd measure_volts core 2>/dev/null | cut -d= -f2)
            TR=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9.]+' || echo "0")
            printf "\r🕒 Time: %s | 🌡️ Temp: %s°C | ⚡ Voltage: %s | 🚀 Clock: %s" "$(date +%T)" "$TR" "$LV" "$LF"
            sleep 2
        done
        ;;
    9)
        echo "Exiting without making changes."
        exit 0
        ;;
    *)
        echo "❌ Invalid choice."
        exit 1
        ;;
esac
