#!/bin/bash

# ==============================================================================
# 🍓 PiTweaks - Interactive Throttle Manager & Diagnostic Suite
# ==============================================================================

# ANSI Colors
RED="\033[31m"
YELLOW="\033[33m"
GREEN="\033[32m"
CYAN="\033[36m"
RESET="\033[0m"

if ! command -v vcgencmd &> /dev/null; then
    echo -e "${RED}❌ Error: 'vcgencmd' not found. This must run on Raspberry Pi OS.${RESET}"
    exit 1
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
    local duration=30 # Test duration in seconds
    local elapsed=0

    # Start background stress workload
    case "$test_type" in
        cpu)
            stress-ng --cpu 4 --timeout ${duration}s &> /dev/null &
            ;;
        ram)
            stress-ng --vm 2 --vm-bytes 75% --timeout ${duration}s &> /dev/null &
            ;;
        gpu)
            vcgencmd render_bar 1 &> /dev/null
            sleep ${duration}
            vcgencmd render_bar 0 &> /dev/null &
            ;;
        all)
            stress-ng --cpu 4 --vm 1 --timeout ${duration}s &> /dev/null &
            ;;
    esac

    while [ $elapsed -lt $duration ]; do
        clear
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "${CYAN} ⚡ PiTweaks Live Benchmark UI [Mode: ${test_type^^}]${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo " Time Remaining: $((duration - elapsed))s"
        echo ""
        
        # Gather live system metrics
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

# Check if arguments were passed (for Discord Bot integration) or run interactive menu
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

# Interactive Terminal Menu
while true; do
    clear
    echo -e "${CYAN}==================================================${RESET}"
    echo -e "${CYAN} 🍓 PiTweaks - Throttle Manager & Diagnostic Menu${RESET}"
    echo -e "${CYAN}==================================================${RESET}"
    echo " 1) Check Throttling & Hardware Health"
    echo " 2) Run Performance Benchmark / Diagnostic Test"
    echo " 3) Exit"
    echo "--------------------------------------------------"
    read -p " Select an option [1-3]: " main_choice

    case "$main_choice" in
        1)
            show_throttling_check
            echo ""
            read -p "Press [Enter] to return to menu..."
            ;;
        2)
            clear
            echo -e "${CYAN}==================================================${RESET}"
            echo -e "${CYAN} 🧪 Select Diagnostic Test Type${RESET}"
            echo -e "${CYAN}==================================================${RESET}"
            echo " 1) CPU Stress Test"
            echo " 2) RAM Memory Test"
            echo " 3) GPU Render Test"
            echo " 4) All-At-Once Comprehensive Test"
            echo " 5) Back to Main Menu"
            echo "--------------------------------------------------"
            read -p " Select test mode [1-5]: " test_choice

            case "$test_choice" in
                1) run_benchmark "cpu";;
                2) run_benchmark "ram";;
                3) run_benchmark "gpu";;
                4) run_benchmark "all";;
                5) continue;;
                *) echo -e "${RED}Invalid option.${RESET}"; sleep 1;;
            esac
            echo ""
            read -p "Press [Enter] to return to menu..."
            ;;
        3)
            echo "Exiting PiTweaks Throttle Manager. Goodbye!"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid selection. Please choose 1, 2, or 3.${RESET}"
            sleep 1
            ;;
    esac
done
