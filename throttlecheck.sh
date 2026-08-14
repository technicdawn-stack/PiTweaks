#!/bin/bash

# ==============================================================================
# 🍓 PiTweaks - Raspberry Pi Throttling & Temperature Monitor
# ==============================================================================

clear
echo "=================================================="
echo " 🌡️ Raspberry Pi Hardware Health & Throttling Check"
echo "=================================================="
echo ""

# 1. Check current CPU Temperature
TEMP=$(vcgencmd measure_temp | awk -F= '{print $2}')
echo "🔥 Current CPU Temperature: $TEMP"

# 2. Check current CPU Frequency
FREQ=$(vcgencmd measure_clock arm | awk -F= '{printf "%.0f MHz\n", $2/1000000}')
echo "⚡ Current CPU Frequency:   $FREQ"

echo ""
echo "--------------------------------------------------"
echo " 📊 Throttling & Power Status Flags:"
echo "--------------------------------------------------"

# 3. Query the vcgencmd get_throttled status
THROTTLED=$(vcgencmd get_throttled | awk -F= '{print $2}')

# Convert hex output to integer
THROTTLED_DEC=$((THROTTLED))

if [ "$THROTTLED_DEC" -eq 0 ]; then
    echo " ✅ All clear! No throttling or power issues detected (now or since boot)."
else
    echo " ⚠️ Warning: Throttling flags have been triggered!"
    echo " Raw status code: $THROTTLED"
    echo ""
    echo " Breakdown of active flags:"
    
    # Check individual bit flags
    # Bit 0: Under-voltage currently detected
    if [ $(( (THROTTLED_DEC >> 0) & 1 )) -eq 1 ]; then
        echo "   ❌ [ACTIVE NOW] Under-voltage detected! (Check your power supply/charger)"
    fi
    # Bit 1: Capped currently
    if [ $(( (THROTTLED_DEC >> 1) & 1 )) -eq 1 ]; then
        echo "   ❌ [ACTIVE NOW] Arm frequency capped due to thermal limits."
    fi
    # Bit 2: Throttled currently
    if [ $(( (THROTTLED_DEC >> 2) & 1 )) -eq 1 ]; then
        echo "   ❌ [ACTIVE NOW] CPU is actively being throttled!"
    fi
    # Bit 3: Soft temperature limit currently active
    if [ $(( (THROTTLED_DEC >> 3) & 1 )) -eq 1 ]; then
        echo "   ❌ [ACTIVE NOW] Soft temperature limit active."
    fi
    
    # Historical flags (since last reboot)
    if [ $(( (THROTTLED_DEC >> 16) & 1 )) -eq 1 ]; then
        echo "   ⚠️ [PAST EVENT] Under-voltage occurred since last reboot."
    fi
    if [ $(( (THROTTLED_DEC >> 17) & 1 )) -eq 1 ]; then
        echo "   ⚠️ [PAST EVENT] Arm frequency capping occurred since last reboot."
    fi
    if [ $(( (THROTTLED_DEC >> 18) & 1 )) -eq 1 ]; then
        echo "   ⚠️ [PAST EVENT] Throttling occurred since last reboot."
    fi
    if [ $(( (THROTTLED_DEC >> 19) & 1 )) -eq 1 ]; then
        echo "   ⚠️ [PAST EVENT] Soft temperature limit occurred since last reboot."
    fi
fi

echo ""
echo "=================================================="
echo " ✅ Check Complete!"
echo "=================================================="
