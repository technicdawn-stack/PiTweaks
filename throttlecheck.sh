#!/bin/bash

# ==============================================================================
# 🍓 PiTweaks - Raspberry Pi Throttle & Benchmark Monitor (ThrottleStop Style)
# ==============================================================================

# Ensure vcgencmd exists
if ! command -v vcgencmd &> /dev/null; then
    echo "❌ Error: 'vcgencmd' not found. This must run on Raspberry Pi OS."
    exit 1
fi

# Function to parse throttling bits into readable status
get_throttle_status() {
    local raw_hex=$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}')
    local dec_val=$((raw_hex))
    
    if [ "$dec_val" -eq 0 ]; then
        echo "🟢 Status: OPTIMAL (No Throttling)"
        return
    fi

    echo "⚠️ Status: THROTTLED / CAPPED"
    [ $(( (dec_val >> 0) & 1 )) -eq 1 ] && echo "  🔴 Under-voltage NOW!"
    [ $(( (dec_val >> 1) & 1 )) -eq 1 ] && echo "  🔴 Freq Capped (Thermal) NOW!"
    [ $(( (dec_val >> 2) & 1 )) -eq 1 ] && echo "  🔴 Throttling Active NOW!"
    [ $(( (dec_val >> 3) & 1 )) -eq 1 ] && echo "  🔴 Soft Limit Active NOW!"
    [ $(( (dec_val >> 16) & 1 )) -eq 1 ] && echo "  🟡 Under-voltage (Past)"
    [ $(( (dec_val >> 17) & 1 )) -eq 1 ] && echo "  🟡 Freq Capped (Past)"
    [ $(( (dec_val >> 18) & 1 )) -eq 1 ] && echo "  🟡 Throttling (Past)"
}

# Run a live benchmark UI loop
run_benchmark() {
    local test_type="$1"
    local duration=30 # default test length in seconds
    local elapsed=0

    # Start background stress workload based on selection
    case "$test_type" in
        cpu)
            stress-ng --cpu 4 --timeout ${duration}s &> /dev/null &
            ;;
        ram)
            stress-ng --vm 2 --vm-bytes 75% --timeout ${duration}s &> /dev/null &
            ;;
        gpu)
            # Simulated GPU load or standard GPU stress if available
            vcgencmd render_bar 1 &> /dev/null
            sleep ${duration}
            vcgencmd render_bar 0 &> /dev/null &
            ;;
        all)
            stress-ng --cpu 4 --vm 1 --timeout ${duration}s &> /dev/null &
            ;;
        *)
            echo "Unknown test type."
            exit 1
            ;;
    esac

    # Live UI Dashboard Loop
    while [ $elapsed -lt $duration ]; do
        clear
        echo "=================================================="
        echo " ⚡ PiTweaks Live Benchmark UI [Mode: ${test_type^^}]"
        echo "=================================================="
        echo " Time Remaining: $((duration - elapsed))s"
        echo ""
        
        # Live Stats
        TEMP=$(vcgencmd measure_temp | awk -F= '{print $2}')
        FREQ=$(vcgencmd measure_clock arm | awk -F= '{printf "%.0f MHz\n", $2/1000000}')
        VOLTS=$(vcgencmd measure_volts core | awk -F= '{print $2}')
        RAM_USAGE=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
        
        echo " 🔥 CPU Temperature : $TEMP"
        echo " ⚡ CPU Frequency   : $FREQ"
        echo " 🔋 Core Voltage    : $VOLTS"
        echo " 💾 RAM Usage       : $RAM_USAGE"
        echo ""
        echo "--------------------------------------------------"
        echo " 📊 Live Throttle & Thermal Watcher:"
        echo "--------------------------------------------------"
        get_throttle_status
        echo "=================================================="
        echo " Press [Ctrl+C] to abort test early."
        
        sleep 2
        elapsed=$((elapsed + 2))
    done

    # Clean up any lingering background stress tasks
    killall stress-ng 2>/dev/null || true
    echo ""
    echo "✅ Benchmark completed successfully!"
}

# CLI Argument Router
case "$1" in
    temp_report)
        clear
        echo "=================================================="
        echo " 🌡️ PiTweaks System Health Report"
        echo "=================================================="
        echo "🔥 Temperature: $(vcgencmd measure_temp | awk -F= '{print $2}')"
        echo "⚡ Frequency:   $(vcgencmd measure_clock arm | awk -F= '{printf "%.0f MHz\n", $2/1000000}')"
        echo "🔋 Voltage:     $(vcgencmd measure_volts core | awk -F= '{print $2}')"
        echo ""
        echo "--------------------------------------------------"
        get_throttle_status
        echo "=================================================="
        ;;
    test_cpu)
        run_benchmark "cpu"
        ;;
    test_ram)
        run_benchmark "ram"
        ;;
    test_temp|test_gpu)
        run_benchmark "gpu"
        ;;
    test_all)
        run_benchmark "all"
        ;;
    *)
        clear
        echo "Usage: bash temp_monitor.sh [temp_report | test_cpu | test_ram | test_gpu | test_all]"
        ;;
esac
