#!/bin/bash

# ==============================================================================
#Description: PiTweaks - Whiptail Throttle Manager & Diagnostic Suite
# ==============================================================================

# ANSI Colors for the Live Dashboard
RED="\033[31m"
YELLOW="\033[33m"
GREEN="\033[32m"
CYAN="\033[36m"
RESET="\033[0m"

if ! command -v vcgencmd &> /dev/null; then
    echo "❌ Error: 'vcgencmd' not found. This must run on Raspberry Pi OS."
    exit 1
fi

if ! command -v whiptail &> /dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y whiptail -qq
fi

# Function to parse throttling bits with color coding
get_throttle_status() {
    local raw_hex=$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}')
    local dec_val=$((raw_hex))
    
    if [ "$dec_val" -eq 0 ]; then
        echo -e "${GREEN}🟢 Status: OPTIMAL (No Throttling Detected)${RESET}"
        return
    fi

    echo -e "${RED}⚠️ Status: THROTTLED / CAPPED DETECTED${RESET}"
    
    # Active / Major flags (Red)
    [ $(( (dec_val >> 0) & 1 )) -eq 1 ] && echo -e "${RED}  🔴 [MAJOR ACTIVE] Under-voltage detected! Check power supply.${RESET}"
    [ $(( (dec_val >> 1) & 1 )) -eq 1 ] && echo -e "${RED}  🔴 [MAJOR ACTIVE] ARM frequency capped due to thermal limits.${RESET}"
    [ $(( (dec_val >> 2) & 1 )) -eq 1 ] && echo -e "${RED}  🔴 [MAJOR ACTIVE] CPU actively being throttled!${RESET}"
    [ $(( (dec_val >> 3) & 1 )) -eq 1 ] && echo -e "${RED}  🔴 [MAJOR ACTIVE] Soft temperature limit active.${RESET}"
    
    # Historical / Minor flags (Yellow)
    [ $(( (dec_val >> 16) & 1 )) -eq 1 ] && echo -e "${YELLOW}  🟡 [MINOR / PAST] Under-voltage occurred since boot.${RESET}"
    [ $(( (dec_val >> 17) & 1 )) -eq 1 ] && echo -e "${YELLOW}  🟡 [MINOR / PAST] Frequency capping occurred since boot.${RESET}"
    [ $(( (dec_val >> 18) & 1 )) -eq 1 ] && echo -e "${YELLOW}  🟡 [MINOR / PAST] Throttling occurred since boot.${RESET}"
    [ $(( (dec_val >> 19) & 1 )) -eq 1 ] && echo -e "${YELLOW}  🟡 [MINOR / PAST] Soft temperature limit occurred since boot.${RESET}"
}

# Live UI Benchmark Function
run_benchmark() {
    local test_type="$1"
    local duration=30
    local elapsed=0

    case "$test_type" in
        cpu) stress-ng --cpu 4 --timeout ${duration}s &> /dev/null & ;;
        ram) stress-ng --vm 2 --vm-bytes 75% --timeout ${duration}s &> /dev/null & ;;
        gpu) 
            vcgencmd render_bar 1 &> /dev/null
            sleep ${duration}
            vcgencmd render_bar 0 &> /dev/null &
            ;;
        all) stress-ng --cpu 4 --vm 1 --timeout ${duration}s &> /dev/null & ;;
    esac

    while [ $elapsed -lt $duration ]; do
        clear
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "${CYAN} ⚡ PiTweaks Live Benchmark UI [Mode: ${test_type^^}]${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo " Time Remaining: $((duration - elapsed))s"
        echo ""
        
        TEMP=$(vcgencmd measure_temp | awk -F= '{print $2}')
        FREQ=$(vcgencmd measure_clock arm | awk -F= '{printf "%.0f MHz\n", $2/1000000}')
        VOLTS=$(vcgencmd measure_volts core | awk -F= '{print $2}')
        RAM_USAGE=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
        
        echo -e " 🔥 CPU Temperature : ${YELLOW}$TEMP${RESET}"
        echo -e " ⚡ CPU Frequency   : $FREQ"
        echo -e " 🔋 Core Voltage    : $VOLTS"
        echo -e " 💾 RAM Usage       : $RAM_USAGE"
        echo ""
        echo "--------------------------------------------------"
        echo " 📊 Active Throttle & Thermal Watcher:"
        echo "--------------------------------------------------"
        get_throttle_status
        echo "=================================================="
        echo -e "${CYAN} Press [Ctrl+C] to abort test early.${RESET}"
        
        sleep 2
        elapsed=$((elapsed + 2))
    done

    killall stress-ng 2>/dev/null || true
    echo ""
    echo -e "${GREEN}✅ Benchmark completed successfully!${RESET}"
}

# Standalone Throttling Check View
show_throttling_check() {
    clear
    echo "=================================================="
    echo -e " 🌡️ ${CYAN}PiTweaks Hardware Health & Throttling Check${RESET}"
    echo "=================================================="
    echo ""
    echo -e "🔥 Current CPU Temperature: ${YELLOW}$(vcgencmd measure_temp | awk -F= '{print $2}')${RESET}"
    echo -e "⚡ Current CPU Frequency:   $(vcgencmd measure_clock arm | awk -F= '{printf "%.0f MHz\n", $2/1000000}')"
    echo -e "🔋 Current Core Voltage:    $(vcgencmd measure_volts core | awk -F= '{print $2}')"
    echo ""
    echo "--------------------------------------------------"
    echo " 📊 Throttling & Power Status Breakdown:"
    echo "--------------------------------------------------"
    get_throttle_status
    echo "=================================================="
}

# Handle command-line arguments (for Discord Bot integration)
if [ "$1" == "temp_report" ]; then
    show_throttling_check
    exit 0
elif [ "$1" == "test_cpu" ]; then
    run_benchmark "cpu"
    exit 0
elif [ "$1" == "test_ram" ]; then
    run_benchmark "ram"
    exit 0
elif [ "$1" == "test_gpu" ] || [ "$1" == "test_temp" ]; then
    run_benchmark "gpu"
    exit 0
elif [ "$1" == "test_all" ]; then
    run_benchmark "all"
    exit 0
fi

# Whiptail Interactive Menu Loop (Runs when no arguments are passed)
while true; do
    MAIN_CHOICE=$(whiptail --clear --backtitle "PiTweaks System Manager" \
        --title "Throttle & Diagnostic Manager" \
        --menu "Choose an option:" 15 60 3 \
        "1" "Check Throttling & Hardware Health" \
        "2" "Run Performance Benchmark / Diagnostic" \
        "3" "Exit" 3>&1 1>&2 2>&3)

    exit_status=$?
    if [ $exit_status -ne 0 ] || [ "$MAIN_CHOICE" = "3" ]; then
        clear
        echo "Exiting PiTweaks Throttle Manager. Goodbye!"
        exit 0
    fi

    case "$MAIN_CHOICE" in
        1)
            show_throttling_check
            echo ""
            read -p "Press [Enter] to return to menu..."
            ;;
        2)
            TEST_CHOICE=$(whiptail --clear --backtitle "PiTweaks System Manager" \
                --title "Diagnostic Selector" \
                --menu "Select component to stress test:" 16 60 5 \
                "cpu" "CPU Stress Test" \
                "ram" "RAM Memory Test" \
                "gpu" "GPU Render Test" \
                "all" "All-At-Once Comprehensive Test" \
                "back" "Return to Main Menu" 3>&1 1>&2 2>&3)

            [ $? -ne 0 ] && continue

            case "$TEST_CHOICE" in
                cpu) run_benchmark "cpu" ;;
                ram) run_benchmark "ram" ;;
                gpu) run_benchmark "gpu" ;;
                all) run_benchmark "all" ;;
                back) continue ;;
            esac
            echo ""
            read -p "Press [Enter] to return to menu..."
            ;;
    esac
done
