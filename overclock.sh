```bash
#!/bin/bash
# ==============================================================================
# 🍓 PiTweaks - Smart Overclock & Power Manager V2.0
# ==============================================================================
# Description: Raspberry Pi overclocking, stress testing, telemetry and diagnostic manager V2.0.
# PERSISTENT: FALSE
# Category: Tools


# V2.0 FEATURES
#   • Preserves original Eco / Quiet / Default / Performance / High Performance
#   • Preserves Last Preset and Original Factory restoration
#   • Live thermal / clock / voltage monitoring
#   • Detailed throttle-state decoding
#   • CPU / RAM / Combined stress testing
#   • Reliable Auto Overclock mode
#   • Maximum Performance Auto Overclock mode
#   • Per-frequency PASS / FAIL history
#   • Failure diagnosis and event timeline
#   • Peak-temperature tracking
#   • Actual vs target frequency display
#   • Per-core CPU utilisation
#   • RAM utilisation
#   • Load-average monitoring
#   • SD-card-conscious operation
#   • No continuous telemetry logging
#   • No backup created merely by launching the script
#   • Config backup only when an actual configuration change is made
#
# IMPORTANT
#   Raspberry Pi config.txt frequency changes require a reboot.
#   Automatic overclocking therefore uses reboot-assisted test stages.
#
# ==============================================================================

set -u

VERSION="V2.0"

# ------------------------------------------------------------------------------
# ROOT CHECK
# ------------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this script with sudo."
    exit 1
fi

# ------------------------------------------------------------------------------
# PATHS
# ------------------------------------------------------------------------------

CONFIG_FILE="/boot/firmware/config.txt"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Could not locate Raspberry Pi config.txt."
    exit 1
fi

ORIG_BACKUP="${CONFIG_FILE}.original"
LAST_BACKUP="${CONFIG_FILE}.last"

# Runtime-only state.
# /run is normally tmpfs and therefore avoids SD writes.
RUNTIME_DIR="/run/pitweaks_overclock"
mkdir -p "$RUNTIME_DIR"

AUTO_STATE="$RUNTIME_DIR/auto_state"
EVENT_LOG="$RUNTIME_DIR/events"
RESULTS_FILE="$RUNTIME_DIR/results"

touch "$EVENT_LOG" "$RESULTS_FILE"

# ------------------------------------------------------------------------------
# TERMINAL COLOURS
# ------------------------------------------------------------------------------

if [ -t 1 ]; then
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[1;36m'
    BLUE='\033[1;34m'
    MAGENTA='\033[1;35m'
    WHITE='\033[1;37m'
    GREY='\033[0;37m'
    RESET='\033[0m'
    BOLD='\033[1m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BLUE=''
    MAGENTA=''
    WHITE=''
    GREY=''
    RESET=''
    BOLD=''
fi

# ------------------------------------------------------------------------------
# BASIC HELPERS
# ------------------------------------------------------------------------------

timestamp() {
    date '+%H:%M:%S'
}

log_event() {
    # Runtime-only diagnostic history.
    # Intentionally stored in /run, not the SD card.
    printf '%s | %s\n' "$(timestamp)" "$*" >> "$EVENT_LOG"
}

pause_screen() {
    echo
    read -r -p "Press Enter to continue..." </dev/tty
}

bar() {
    local value="${1:-0}"
    local width="${2:-25}"
    local filled empty i

    value=${value%.*}

    (( value < 0 )) && value=0
    (( value > 100 )) && value=100

    filled=$(( value * width / 100 ))
    empty=$(( width - filled ))

    printf '['

    for ((i=0; i<filled; i++)); do
        printf '█'
    done

    for ((i=0; i<empty; i++)); do
        printf '░'
    done

    printf ']'
}

status_colour() {
    local status="$1"

    case "$status" in
        GREEN|SAFE|PASS|OK)
            printf '%sGREEN%s' "$GREEN" "$RESET"
            ;;
        YELLOW|WARN|WARNING)
            printf '%sYELLOW%s' "$YELLOW" "$RESET"
            ;;
        RED|FAIL|CRITICAL)
            printf '%sRED%s' "$RED" "$RESET"
            ;;
        *)
            printf '%s%s%s' "$CYAN" "$status" "$RESET"
            ;;
    esac
}

clear_screen() {
    clear
}

# ------------------------------------------------------------------------------
# HARDWARE DETECTION
# ------------------------------------------------------------------------------

MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Raspberry Pi")
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || true)
CPU_CORES=$(nproc 2>/dev/null || echo "N/A")

if echo "$MODEL" | grep -qi "Raspberry Pi 3 Model B Plus"; then
    PI_FAMILY="Pi 3B+"
elif echo "$MODEL" | grep -qi "Raspberry Pi 3 Model B"; then
    PI_FAMILY="Pi 3B"
elif echo "$MODEL" | grep -qi "Raspberry Pi 4"; then
    PI_FAMILY="Pi 4"
elif echo "$MODEL" | grep -qi "Raspberry Pi 5"; then
    PI_FAMILY="Pi 5"
else
    PI_FAMILY="Other"
fi

# ------------------------------------------------------------------------------
# SAFE COMMAND WRAPPER
# ------------------------------------------------------------------------------

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# TELEMETRY
# ------------------------------------------------------------------------------

get_temp() {
    local value

    if have_cmd vcgencmd; then
        value=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+([.][0-9]+)?' | head -1)
        [ -n "${value:-}" ] && printf '%s' "$value" && return
    fi

    if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp
        return
    fi

    printf 'N/A'
}

get_arm_clock() {
    if have_cmd vcgencmd; then
        vcgencmd measure_clock arm 2>/dev/null |
            awk -F= 'NF==2 {printf "%.0f", $2/1000000; found=1} END {if(!found) print "N/A"}'
        return
    fi

    printf 'N/A'
}

get_core_clock() {
    if have_cmd vcgencmd; then
        vcgencmd measure_clock core 2>/dev/null |
            awk -F= 'NF==2 {printf "%.0f", $2/1000000; found=1} END {if(!found) print "N/A"}'
        return
    fi

    printf 'N/A'
}

get_sdram_clock() {
    if have_cmd vcgencmd; then
        vcgencmd measure_clock sdram 2>/dev/null |
            awk -F= 'NF==2 {printf "%.0f", $2/1000000; found=1} END {if(!found) print "N/A"}'
        return
    fi

    printf 'N/A'
}

get_core_voltage() {
    if have_cmd vcgencmd; then
        vcgencmd measure_volts core 2>/dev/null |
            cut -d= -f2
        return
    fi

    printf 'N/A'
}

get_ram_usage() {
    awk '
    /MemTotal:/     {total=$2}
    /MemAvailable:/ {avail=$2}
    END {
        if (total > 0) {
            used=total-avail
            printf "%d %d %.0f", used/1024, total/1024, used/total*100
        } else {
            print "0 0 0"
        }
    }' /proc/meminfo
}

get_load_average() {
    if [ -r /proc/loadavg ]; then
        awk '{print $1, $2, $3}' /proc/loadavg
    else
        printf 'N/A N/A N/A'
    fi
}

get_cpu_usage() {
    # Returns one percentage per CPU core.
    # Reads /proc/stat twice with a short interval.
    local before after
    local b_idle b_total a_idle a_total
    local line cpu user nice system idle iowait irq softirq steal
    local -a before_idle before_total
    local -a after_idle after_total

    while read -r cpu user nice system idle iowait irq softirq steal _; do
        [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue

        before_idle[${cpu#cpu}]=$((idle+iowait))
        before_total[${cpu#cpu}]=$((user+nice+system+idle+iowait+irq+softirq+steal))
    done < /proc/stat

    sleep 0.20

    while read -r cpu user nice system idle iowait irq softirq steal _; do
        [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue

        after_idle[${cpu#cpu}]=$((idle+iowait))
        after_total[${cpu#cpu}]=$((user+nice+system+idle+iowait+irq+softirq+steal))
    done < /proc/stat

    for ((i=0; i<CPU_CORES; i++)); do
        if [ -n "${before_total[$i]:-}" ] && [ -n "${after_total[$i]:-}" ]; then
            local total_diff=$((after_total[i]-before_total[i]))
            local idle_diff=$((after_idle[i]-before_idle[i]))

            if (( total_diff > 0 )); then
                printf '%d ' "$(( (total_diff-idle_diff)*100/total_diff ))"
            else
                printf '0 '
            fi
        else
            printf 'N/A '
        fi
    done
}

# ------------------------------------------------------------------------------
# THROTTLE DECODING
# ------------------------------------------------------------------------------

THROTTLE_HEX="0x0"
THROTTLE_DEC=0

read_throttle() {
    if have_cmd vcgencmd; then
        THROTTLE_HEX=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    else
        THROTTLE_HEX="N/A"
    fi

    if [[ "$THROTTLE_HEX" =~ ^0x[0-9a-fA-F]+$ ]]; then
        THROTTLE_DEC=$((THROTTLE_HEX))
    else
        THROTTLE_DEC=0
    fi
}

bit_set() {
    local bit="$1"
    (( (THROTTLE_DEC & (1 << bit)) != 0 ))
}

throttle_indicator() {
    local active_bit="$1"
    local historical_bit="$2"

    if bit_set "$active_bit"; then
        printf '%s● RED%s CURRENT' "$RED" "$RESET"
    elif bit_set "$historical_bit"; then
        printf '%s● YELLOW%s HISTORY' "$YELLOW" "$RESET"
    else
        printf '%s● GREEN%s NONE' "$GREEN" "$RESET"
    fi
}

get_overall_health() {
    read_throttle

    local temp
    temp=$(get_temp)

    if bit_set 0 || bit_set 1 || bit_set 2 || bit_set 3; then
        printf 'CRITICAL'
        return
    fi

    if bit_set 16 || bit_set 17 || bit_set 18 || bit_set 19; then
        printf 'WARNING'
        return
    fi

    if [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if awk "BEGIN {exit !($temp >= 80)}"; then
            printf 'WARNING'
            return
        fi
    fi

    printf 'SAFE'
}

# ------------------------------------------------------------------------------
# THROTTLE DETAIL
# ------------------------------------------------------------------------------

display_throttle_state() {
    read_throttle

    echo " POWER       $(throttle_indicator 0 16)"
    echo " FREQ CAP    $(throttle_indicator 1 17)"
    echo " THROTTLE    $(throttle_indicator 2 18)"
    echo " THERMAL     $(throttle_indicator 3 19)"
    echo " CODE        $THROTTLE_HEX"
}

# ------------------------------------------------------------------------------
# CONFIGURATION DETECTION
# ------------------------------------------------------------------------------

detect_profile() {
    if grep -q '^# PROFILE: Eco$' "$CONFIG_FILE"; then
        printf 'Eco'
    elif grep -q '^# PROFILE: Quiet$' "$CONFIG_FILE"; then
        printf 'Quiet'
    elif grep -q '^# PROFILE: Default$' "$CONFIG_FILE"; then
        printf 'Default'
    elif grep -q '^# PROFILE: Performance$' "$CONFIG_FILE"; then
        printf 'Performance'
    elif grep -q '^# PROFILE: High Performance$' "$CONFIG_FILE"; then
        printf 'High Performance'
    elif grep -q '^# PROFILE: AUTO-OVERCLOCK' "$CONFIG_FILE"; then
        printf 'Auto Overclock'
    elif grep -q '^arm_freq=' "$CONFIG_FILE" ||
         grep -q '^over_voltage=' "$CONFIG_FILE"; then
        printf 'Custom'
    else
        printf 'Default (Factory Stock)'
    fi
}

get_config_value() {
    local key="$1"

    grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null |
        tail -1 |
        cut -d= -f2
}

get_default_arm_freq() {
    case "$PI_FAMILY" in
        Pi\ 3B|Pi\ 3B+)
            echo 1200
            ;;
        Pi\ 4)
            echo 1500
            ;;
        Pi\ 5)
            echo 2400
            ;;
        *)
            echo 0
            ;;
    esac
}

get_current_target_freq() {
    local value
    value=$(get_config_value "arm_freq")

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        get_default_arm_freq
    fi
}

# ------------------------------------------------------------------------------
# HARDWARE-SPECIFIC OVERCLOCK LIMITS
# ------------------------------------------------------------------------------

# These are intentionally conservative boundaries.
# They are NOT guarantees that every individual board will reach them.

case "$PI_FAMILY" in

    "Pi 3B")
        BASE_FREQ=1200

        RELIABLE_START=1250
        RELIABLE_STEP=25
        RELIABLE_MAX=1400

        MAX_START=1250
        MAX_STEP=50
        MAX_LIMIT=1500

        SAFE_TEST_TEMP=75
        HARD_TEST_TEMP=82

        DEFAULT_CORE=400
        ;;
    
    "Pi 3B+")
        BASE_FREQ=1400

        RELIABLE_START=1450
        RELIABLE_STEP=25
        RELIABLE_MAX=1550

        MAX_START=1450
        MAX_STEP=50
        MAX_LIMIT=1600

        SAFE_TEST_TEMP=75
        HARD_TEST_TEMP=82

        DEFAULT_CORE=400
        ;;

    "Pi 4")
        BASE_FREQ=1500

        RELIABLE_START=1550
        RELIABLE_STEP=25
        RELIABLE_MAX=1900

        MAX_START=1550
        MAX_STEP=50
        MAX_LIMIT=2000

        SAFE_TEST_TEMP=75
        HARD_TEST_TEMP=82

        DEFAULT_CORE=500
        ;;

    "Pi 5")
        BASE_FREQ=2400

        RELIABLE_START=2450
        RELIABLE_STEP=25
        RELIABLE_MAX=2800

        MAX_START=2450
        MAX_STEP=50
        MAX_LIMIT=3000

        SAFE_TEST_TEMP=80
        HARD_TEST_TEMP=85

        DEFAULT_CORE=910
        ;;

    *)
        BASE_FREQ=0
        RELIABLE_START=0
        RELIABLE_STEP=25
        RELIABLE_MAX=0
        MAX_START=0
        MAX_STEP=50
        MAX_LIMIT=0
        SAFE_TEST_TEMP=70
        HARD_TEST_TEMP=80
        DEFAULT_CORE=0
        ;;
esac

# ------------------------------------------------------------------------------
# CONFIG BACKUP
# ------------------------------------------------------------------------------

backup_before_change() {

    # Do NOT create backups simply because the program was launched.
    # This function is only called immediately before an actual modification.

    if [ ! -f "$ORIG_BACKUP" ]; then
        cp -p "$CONFIG_FILE" "$ORIG_BACKUP"
        echo "📦 Created original configuration backup."
    fi

    cp -p "$CONFIG_FILE" "$LAST_BACKUP"
    echo "📦 Updated last-known configuration backup."
}

# ------------------------------------------------------------------------------
# REMOVE OUR OWN OVERRIDE BLOCK
# ------------------------------------------------------------------------------

remove_pitweaks_block() {
    sed -i \
        '/^# --- PiTweaks Overclock Start ---$/,/^# --- PiTweaks Overclock End ---$/d' \
        "$CONFIG_FILE"
}

# ------------------------------------------------------------------------------
# APPLY SETTINGS
# ------------------------------------------------------------------------------

apply_settings() {

    local PROFILE_NAME="$1"
    local CONFIG_BODY="$2"

    echo
    echo "Preparing configuration change..."
    echo "Profile: $PROFILE_NAME"

    backup_before_change

    remove_pitweaks_block

    {
        printf '\n'
        printf '# --- PiTweaks Overclock Start ---\n'
        printf '# PROFILE: %s\n' "$PROFILE_NAME"
        printf '# Applied by PiTweaks %s\n' "$VERSION"
        printf '%b\n' "$CONFIG_BODY"
        printf '# --- PiTweaks Overclock End ---\n'
    } >> "$CONFIG_FILE"

    echo
    echo "${GREEN}✅ Configuration successfully written.${RESET}"
    echo "${YELLOW}⚠️ Changes require a reboot.${RESET}"

    read -r -p "Reboot now? [y/N]: " REBOOT_CHOICE </dev/tty

    if [[ "$REBOOT_CHOICE" =~ ^[yY]$ ]]; then
        log_event "Reboot requested after profile $PROFILE_NAME"
        reboot
    fi
}

# ------------------------------------------------------------------------------
# SAFE CONFIG VALIDATION
# ------------------------------------------------------------------------------

validate_config() {

    local candidate="$1"
    local temp_file="$RUNTIME_DIR/config_test"

    cp "$CONFIG_FILE" "$temp_file"

    remove_pitweaks_block

    {
        printf '\n# --- PiTweaks Overclock Start ---\n'
        printf '# PROFILE: Validation\n'
        printf '%b\n' "$candidate"
        printf '# --- PiTweaks Overclock End ---\n'
    } >> "$CONFIG_FILE"

    # config.txt has no universal shell syntax validator.
    # We therefore validate our generated values structurally.

    local bad=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        if [[ "$line" =~ ^(arm_freq|core_freq|gpu_freq|sdram_freq|over_voltage|arm_freq_min|core_freq_min|gpu_freq_min|temp_limit|initial_turbo|force_turbo)=-?[0-9]+$ ]]; then
            continue
        fi

        echo "⚠️ Generated setting failed validation: $line"
        bad=1
    done <<< "$candidate"

    mv "$temp_file" "$CONFIG_FILE"

    return "$bad"
}

# ------------------------------------------------------------------------------
# PROFILE MENU
# ------------------------------------------------------------------------------

preset_menu() {

    clear_screen

    local temp
    temp=$(get_temp)

    echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║                 PiTweaks • POWER PROFILES                  ║${RESET}"
    echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo
    echo "Current profile : $(detect_profile)"
    echo "Current ARM     : $(get_arm_clock) MHz"
    echo "Temperature     : ${temp}°C"
    echo
    echo "  1) Eco"
    echo "  2) Quiet"
    echo "  3) Default"
    echo "  4) Performance"
    echo "  5) High Performance"
    echo
    echo "  6) Restore Last Preset State"
    echo "  7) Restore Original Factory Config"
    echo "  8) Live Thermal & Clock Monitor"
    echo "  9) Auto Overclock"
    echo " 10) Stress Test Suite"
    echo " 11) View Current Diagnostics"
    echo " 12) Exit"
    echo

    read -r -p "Enter selection [1-12]: " CHOICE </dev/tty

    case "$CHOICE" in

        1)
            apply_settings "Eco" \
                "arm_freq=800
initial_turbo=0"
            ;;

        2)
            apply_settings "Quiet" \
                "arm_freq_min=600"
            ;;

        3)
            backup_before_change
            remove_pitweaks_block

            echo
            echo "✅ PiTweaks overclock overrides removed."
            echo "The Raspberry Pi firmware will use its normal defaults."

            read -r -p "Reboot now? [y/N]: " REBOOT_CHOICE </dev/tty
            [[ "$REBOOT_CHOICE" =~ ^[yY]$ ]] && reboot
            ;;

        4)
            case "$PI_FAMILY" in
                "Pi 3B")
                    SETTINGS="arm_freq=1300
core_freq=400
over_voltage=2"
                    ;;
                "Pi 3B+")
                    SETTINGS="arm_freq=1450
core_freq=400
over_voltage=2"
                    ;;
                "Pi 4")
                    SETTINGS="arm_freq=1800
core_freq=500"
                    ;;
                "Pi 5")
                    SETTINGS="arm_freq=2600"
                    ;;
                *)
                    echo "❌ Unsupported hardware for automatic preset."
                    pause_screen
                    return
                    ;;
            esac

            apply_settings "Performance" "$SETTINGS"
            ;;

        5)
            case "$PI_FAMILY" in
                "Pi 3B")
                    SETTINGS="arm_freq=1350
core_freq=400
over_voltage=4"
                    ;;
                "Pi 3B+")
                    SETTINGS="arm_freq=1500
core_freq=500
over_voltage=4"
                    ;;
                "Pi 4")
                    SETTINGS="arm_freq=2000
core_freq=500
over_voltage=6"
                    ;;
                "Pi 5")
                    SETTINGS="arm_freq=2800"
                    ;;
                *)
                    echo "❌ Unsupported hardware for automatic preset."
                    pause_screen
                    return
                    ;;
            esac

            apply_settings "High Performance" "$SETTINGS"
            ;;

        6)
            if [ ! -f "$LAST_BACKUP" ]; then
                echo "❌ No last-state backup exists."
                pause_screen
                return
            fi

            backup_before_change
            cp -p "$LAST_BACKUP" "$CONFIG_FILE"

            echo "🔄 Restored last configuration."

            read -r -p "Reboot now? [y/N]: " REBOOT_CHOICE </dev/tty
            [[ "$REBOOT_CHOICE" =~ ^[yY]$ ]] && reboot
            ;;

        7)
            if [ ! -f "$ORIG_BACKUP" ]; then
                echo "❌ No original backup exists yet."
                pause_screen
                return
            fi

            cp -p "$CONFIG_FILE" "$LAST_BACKUP"
            cp -p "$ORIG_BACKUP" "$CONFIG_FILE"

            echo "🔄 Restored original factory configuration."

            read -r -p "Reboot now? [y/N]: " REBOOT_CHOICE </dev/tty
            [[ "$REBOOT_CHOICE" =~ ^[yY]$ ]] && reboot
            ;;

        8)
            live_monitor
            ;;

        9)
            auto_overclock_menu
            ;;

        10)
            stress_test_menu
            ;;

        11)
            diagnostic_dashboard
            ;;

        12)
            clear_screen
            echo "Exiting without changes."
            exit 0
            ;;

        *)
            echo "❌ Invalid selection."
            sleep 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# LIVE MONITOR
# ------------------------------------------------------------------------------

live_monitor() {

    trap 'printf "\n"; return' INT

    while true; do

        clear_screen

        local temp arm core sdram voltage ram_used ram_total ram_pct
        local load1 load5 load15 health

        temp=$(get_temp)
        arm=$(get_arm_clock)
        core=$(get_core_clock)
        sdram=$(get_sdram_clock)
        voltage=$(get_core_voltage)

        read -r ram_used ram_total ram_pct <<< "$(get_ram_usage)"
        read -r load1 load5 load15 <<< "$(get_load_average)"

        health=$(get_overall_health)

        echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
        echo "${CYAN}║                 🍓 PiTweaks • LIVE MONITOR                ║${RESET}"
        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
        printf "║ Hardware : %-47s ║\n" "$MODEL"
        printf "║ Profile  : %-47s ║\n" "$(detect_profile)"
        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
        printf "║ ARM      : %6s MHz                                      ║\n" "$arm"
        printf "║ CORE/GPU : %6s MHz                                      ║\n" "$core"
        printf "║ SDRAM    : %6s MHz                                      ║\n" "$sdram"
        printf "║ Voltage  : %-48s ║\n" "$voltage"
        echo
        printf "║ Temp     : %5s°C  " "$temp"
        bar "$(( ${temp%.*:-0} * 100 / 85 ))" 20
        echo " ║"
        printf "║ RAM      : %4s / %4s MB  " "$ram_used" "$ram_total"
        bar "$ram_pct" 20
        echo " ║"
        printf "║ Load     : %s / %s / %s                           ║\n" \
            "$load1" "$load5" "$load15"
        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
        echo "║ HEALTH                                                     ║"
        printf "║ Overall  : "
        status_colour "$health"
        echo "                                             ║"
        echo
        display_throttle_state
        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
        echo "║ Press Ctrl+C to return                                    ║"
        echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"

        sleep 1
    done
}

# ------------------------------------------------------------------------------
# STRESS-NG INSTALL
# ------------------------------------------------------------------------------

ensure_stress_ng() {

    if have_cmd stress-ng; then
        return 0
    fi

    echo
    echo "stress-ng is not installed."
    read -r -p "Install stress-ng now? [Y/n]: " answer </dev/tty

    if [[ ! "$answer" =~ ^[Nn]$ ]]; then
        apt-get update
        apt-get install -y stress-ng

        if ! have_cmd stress-ng; then
            echo "❌ stress-ng installation failed."
            return 1
        fi
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# STRESS PROCESS CLEANUP
# ------------------------------------------------------------------------------

STRESS_PID=""

cleanup_stress() {

    if [ -n "${STRESS_PID:-}" ] && kill -0 "$STRESS_PID" 2>/dev/null; then
        kill "$STRESS_PID" 2>/dev/null || true
        sleep 1

        kill -9 "$STRESS_PID" 2>/dev/null || true
    fi

    STRESS_PID=""
}

trap cleanup_stress EXIT

# ------------------------------------------------------------------------------
# STRESS START
# ------------------------------------------------------------------------------

start_stress() {

    local mode="$1"
    local duration="$2"

    case "$mode" in
        CPU)
            stress-ng --cpu 0 --timeout "${duration}s" --metrics-brief >/dev/null 2>&1 &
            ;;

        RAM)
            stress-ng --vm 2 --vm-bytes 70% --vm-method all \
                --timeout "${duration}s" --metrics-brief >/dev/null 2>&1 &
            ;;

        COMBINED)
            stress-ng --cpu 0 --vm 2 --vm-bytes 70% \
                --timeout "${duration}s" --metrics-brief >/dev/null 2>&1 &
            ;;

        *)
            return 1
            ;;
    esac

    STRESS_PID=$!
    log_event "Stress test started: $mode for ${duration}s"
}

# ------------------------------------------------------------------------------
# STRESS DASHBOARD
# ------------------------------------------------------------------------------

stress_dashboard() {

    local mode="$1"
    local duration="$2"

    local start_time now elapsed remaining
    local temp peak_temp="0"
    local arm core sdram voltage
    local ram_used ram_total ram_pct
    local load1 load5 load15
    local cpus avg_cpu
    local health
    local failure_reason=""

    start_time=$(date +%s)

    start_stress "$mode" "$duration" || {
        echo "❌ Failed to start stress test."
        return 1
    }

    while true; do

        now=$(date +%s)
        elapsed=$((now-start_time))
        remaining=$((duration-elapsed))

        [ "$remaining" -lt 0 ] && remaining=0

        temp=$(get_temp)
        arm=$(get_arm_clock)
        core=$(get_core_clock)
        sdram=$(get_sdram_clock)
        voltage=$(get_core_voltage)

        read -r ram_used ram_total ram_pct <<< "$(get_ram_usage)"
        read -r load1 load5 load15 <<< "$(get_load_average)"

        cpus=$(get_cpu_usage)

        avg_cpu=$(awk '
        {
            total=0;
            count=0;
            for(i=1;i<=NF;i++) {
                if ($i ~ /^[0-9]+$/) {
                    total += $i;
                    count++;
                }
            }
        }
        END {
            if(count>0) printf "%.1f", total/count;
            else print "N/A";
        }' <<< "$cpus")

        if [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            if awk "BEGIN {exit !($temp > $peak_temp)}"; then
                peak_temp="$temp"
            fi
        fi

        read_throttle
        health=$(get_overall_health)

        if bit_set 0; then
            failure_reason="Under-voltage detected"
        elif bit_set 2; then
            failure_reason="CPU throttling detected"
        elif bit_set 3; then
            failure_reason="Thermal limit detected"
        elif [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
             awk "BEGIN {exit !($temp >= $HARD_TEST_TEMP)}"; then
            failure_reason="Hard thermal safety limit reached"
        fi

        clear_screen

        echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
        printf "${CYAN}║              🍓 PiTweaks • STRESS TEST V2.0              ║${RESET}\n"
        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
        printf "║ TEST       : %-44s ║\n" "$mode"
        printf "║ ELAPSED    : %4ss / %4ss                              ║\n" "$elapsed" "$duration"
        printf "║ REMAINING  : %4ss                                     ║\n" "$remaining"
        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
        echo "║ CPU                                                        ║"

        local index=0
        for cpu in $cpus; do
            printf "║ Core %-2s    %3s%% " "$index" "$cpu"
            bar "${cpu:-0}" 20
            echo " ║"
            index=$((index+1))
        done

        printf "║ Average    %5s%%                                      ║\n" "$avg_cpu"
        printf "║ Load       %s / %s / %s                           ║\n" \
            "$load1" "$load5" "$load15"

        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
        echo "║ CLOCKS                                                     ║"
        printf "║ ARM        : %6s MHz                                      ║\n" "$arm"
        printf "║ CORE/GPU   : %6s MHz                                      ║\n" "$core"
        printf "║ SDRAM      : %6s MHz                                      ║\n" "$sdram"

        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
        echo "║ THERMALS / MEMORY                                         ║"
        printf "║ Temp       : %5s°C  " "$temp"
        bar "$(( ${temp%.*:-0} * 100 / 85 ))" 18
        echo " ║"
        printf "║ Peak       : %5s°C                                      ║\n" "$peak_temp"
        printf "║ RAM        : %4s / %4s MB  " "$ram_used" "$ram_total"
        bar "$ram_pct" 18
        echo " ║"
        printf "║ Voltage    : %-48s ║\n" "$voltage"

        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
        echo "║ HEALTH                                                     ║"
        printf "║ Overall    : "
        status_colour "$health"
        echo "                                             ║"
        display_throttle_state

        if [ -n "$failure_reason" ]; then
            echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
            printf "║ ${RED}⚠ FAILURE: %-48s${RESET} ║\n" "$failure_reason"
        fi

        echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"

        if [ -n "$failure_reason" ]; then
            log_event "STRESS FAILURE: $failure_reason"
            break
        fi

        if [ "$remaining" -le 0 ]; then
            log_event "Stress test completed successfully"
            break
        fi

        if ! kill -0 "$STRESS_PID" 2>/dev/null; then
            log_event "Stress process exited before requested duration"
            break
        fi

        sleep 1
    done

    cleanup_stress

    echo
    echo "${BOLD}Stress test complete.${RESET}"
    echo
    echo "Mode             : $mode"
    echo "Duration         : ${elapsed}s"
    echo "Peak temperature : ${peak_temp}°C"
    echo "Final ARM clock  : ${arm} MHz"
    echo "Final core clock : ${core} MHz"
    echo "Final SDRAM      : ${sdram} MHz"
    echo "Final voltage    : $voltage"
    echo "Throttle code    : $THROTTLE_HEX"

    if [ -n "$failure_reason" ]; then
        echo "Result           : ${RED}FAIL${RESET}"
        echo "Reason           : $failure_reason"
    else
        echo "Result           : ${GREEN}PASS${RESET}"
    fi

    pause_screen
}

# ------------------------------------------------------------------------------
# STRESS TEST MENU
# ------------------------------------------------------------------------------

stress_test_menu() {

    ensure_stress_ng || {
        pause_screen
        return
    }

    clear_screen

    echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║                  STRESS TEST SUITE                         ║${RESET}"
    echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo
    echo "Select workload:"
    echo
    echo "  1) CPU Stress"
    echo "  2) RAM Stress"
    echo "  3) CPU + RAM Combined"
    echo
    echo "  4) Return"
    echo

    read -r -p "Selection [1-4]: " TEST_CHOICE </dev/tty

    case "$TEST_CHOICE" in
        1) MODE="CPU" ;;
        2) MODE="RAM" ;;
        3) MODE="COMBINED" ;;
        4) return ;;
        *) echo "Invalid choice."; sleep 1; return ;;
    esac

    clear_screen

    echo "Test: $MODE"
    echo
    echo "  1) 2 minutes"
    echo "  2) 5 minutes"
    echo "  3) 10 minutes"
    echo "  4) 30 minutes"
    echo "  5) Custom"
    echo

    read -r -p "Duration [1-5]: " DURATION_CHOICE </dev/tty

    case "$DURATION_CHOICE" in
        1) DURATION=120 ;;
        2) DURATION=300 ;;
        3) DURATION=600 ;;
        4) DURATION=1800 ;;
        5)
            read -r -p "Duration in seconds: " DURATION </dev/tty

            if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [ "$DURATION" -lt 10 ]; then
                echo "❌ Invalid duration."
                pause_screen
                return
            fi
            ;;
        *)
            echo "Invalid choice."
            pause_screen
            return
            ;;
    esac

    stress_dashboard "$MODE" "$DURATION"
}

# ------------------------------------------------------------------------------
# AUTO-OVERCLOCK SAFETY CHECK
# ------------------------------------------------------------------------------

auto_safety_check() {

    local temp
    temp=$(get_temp)

    echo
    echo "Running pre-flight safety check..."
    echo

    echo "Hardware       : $MODEL"
    echo "Detected family: $PI_FAMILY"
    echo "Current ARM    : $(get_arm_clock) MHz"
    echo "Target base    : $(get_current_target_freq) MHz"
    echo "Temperature    : ${temp}°C"

    read_throttle

    if [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if awk "BEGIN {exit !($temp >= 65)}"; then
            echo "${YELLOW}⚠ Current temperature is already high.${RESET}"
        fi

        if awk "BEGIN {exit !($temp >= $SAFE_TEST_TEMP)}"; then
            echo "${RED}❌ Too hot to begin automatic overclocking.${RESET}"
            return 1
        fi
    fi

    if bit_set 0 || bit_set 1 || bit_set 2 || bit_set 3; then
        echo "${RED}❌ Active throttle condition detected.${RESET}"
        echo
        display_throttle_state
        return 1
    fi

    echo "${GREEN}✅ Pre-flight safety check passed.${RESET}"
    return 0
}

# ------------------------------------------------------------------------------
# AUTO OVERCLOCK CONFIG
# ------------------------------------------------------------------------------

generate_candidate_config() {

    local freq="$1"
    local mode="$2"
    local voltage="$3"

    case "$PI_FAMILY" in

        "Pi 3B")
            printf 'arm_freq=%s\ncore_freq=400\n' "$freq"

            if [ "$voltage" -gt 0 ]; then
                printf 'over_voltage=%s\n' "$voltage"
            fi
            ;;

        "Pi 3B+")
            printf 'arm_freq=%s\ncore_freq=400\n' "$freq"

            if [ "$voltage" -gt 0 ]; then
                printf 'over_voltage=%s\n' "$voltage"
            fi
            ;;

        "Pi 4")
            printf 'arm_freq=%s\ncore_freq=500\n' "$freq"

            if [ "$voltage" -gt 0 ]; then
                printf 'over_voltage=%s\n' "$voltage"
            fi
            ;;

        "Pi 5")
            printf 'arm_freq=%s\n' "$freq"
            ;;

        *)
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# AUTO OVERCLOCK STATE
# ------------------------------------------------------------------------------

save_auto_state() {

    local mode="$1"
    local current="$2"
    local stable="$3"
    local next="$4"
    local step="$5"
    local voltage="$6"

    cat > "$AUTO_STATE" <<EOF
MODE=$mode
CURRENT=$current
STABLE=$stable
NEXT=$next
STEP=$step
VOLTAGE=$voltage
MODEL=$PI_FAMILY
EOF
}

load_auto_state() {
    [ -f "$AUTO_STATE" ] || return 1
    # shellcheck disable=SC1090
    source "$AUTO_STATE"
}

clear_auto_state() {
    rm -f "$AUTO_STATE"
}

# ------------------------------------------------------------------------------
# AUTO OVERCLOCK TEST PLAN
# ------------------------------------------------------------------------------

run_auto_stage() {

    local mode="$1"
    local candidate="$2"
    local previous="$3"
    local duration="$4"
    local voltage="$5"

    clear_screen

    echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║                 🍓 AUTO OVERCLOCK V2.0                    ║${RESET}"
    echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
    printf "║ Mode             : %-41s ║\n" "$mode"
    printf "║ Previous Stable  : %-35s MHz ║\n" "$previous"
    printf "║ Candidate        : %-35s MHz ║\n" "$candidate"
    printf "║ Voltage Offset   : %-35s   ║\n" "$voltage"
    printf "║ Test Duration    : %-35ss ║\n" "$duration"
    echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo

    echo "${YELLOW}The candidate must be written to config.txt and rebooted.${RESET}"
    echo
    echo "After reboot, rerun this V2.0 module to continue the test."
    echo

    read -r -p "Apply $candidate MHz and reboot? [y/N]: " answer </dev/tty

    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Auto-overclock cancelled."
        clear_auto_state
        pause_screen
        return
    fi

    local settings
    settings=$(generate_candidate_config "$candidate" "$mode" "$voltage")

    if ! validate_config "$settings"; then
        echo "❌ Candidate failed validation."
        pause_screen
        return
    fi

    backup_before_change
    remove_pitweaks_block

    {
        printf '\n'
        printf '# --- PiTweaks Overclock Start ---\n'
        printf '# PROFILE: AUTO-OVERCLOCK %s\n' "$mode"
        printf '# Candidate: %s MHz\n' "$candidate"
        printf '# Previous Stable: %s MHz\n' "$previous"
        printf '# V2.0 reboot-assisted test stage\n'
        printf '%s\n' "$settings"
        printf '# --- PiTweaks Overclock End ---\n'
    } >> "$CONFIG_FILE"

    save_auto_state "$mode" "$candidate" "$previous" "$candidate" \
        "$RELIABLE_STEP" "$voltage"

    log_event "AUTO stage prepared: $candidate MHz"

    echo
    echo "${GREEN}Candidate applied.${RESET}"
    echo "${YELLOW}Rebooting to activate it...${RESET}"

    sleep 2
    reboot
}

# ------------------------------------------------------------------------------
# AUTO OVERCLOCK RESUME
# ------------------------------------------------------------------------------

auto_resume_if_needed() {

    [ -f "$AUTO_STATE" ] || return 0

    load_auto_state || return 0

    clear_screen

    echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║             AUTO OVERCLOCK TEST RESUMED                   ║${RESET}"
    echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo
    echo "Mode             : $MODE"
    echo "Candidate        : $CURRENT MHz"
    echo "Previous Stable  : $STABLE MHz"
    echo "Current ARM      : $(get_arm_clock) MHz"
    echo "Temperature      : $(get_temp)°C"
    echo

    local temp
    temp=$(get_temp)

    read_throttle

    local fail_reason=""

    if bit_set 0; then
        fail_reason="Under-voltage detected"
    elif bit_set 1; then
        fail_reason="ARM frequency capping detected"
    elif bit_set 2; then
        fail_reason="CPU throttling detected"
    elif bit_set 3; then
        fail_reason="Thermal throttling detected"
    elif [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
         awk "BEGIN {exit !($temp >= $HARD_TEST_TEMP)}"; then
        fail_reason="Temperature exceeded hard test limit"
    fi

    # --------------------------------------------------------------------------
    # Current candidate failed
    # --------------------------------------------------------------------------

    if [ -n "$fail_reason" ]; then

        log_event "AUTO candidate FAILED: $CURRENT MHz - $fail_reason"

        printf '%s|%s|FAIL|%s|%s|%s\n' \
            "$CURRENT" "$(get_temp)" "$fail_reason" "$MODE" "$(timestamp)" \
            >> "$RESULTS_FILE"

        echo "${RED}❌ Candidate FAILED${RESET}"
        echo
        echo "Frequency : $CURRENT MHz"
        echo "Reason    : $fail_reason"
        echo "Temp      : $(get_temp)°C"
        echo "Throttle  : $THROTTLE_HEX"
        echo
        echo "Reverting to last known-good: ${STABLE} MHz"

        local settings
        settings=$(generate_candidate_config "$STABLE" "$MODE" "$VOLTAGE")

        backup_before_change
        remove_pitweaks_block

        {
            printf '\n# --- PiTweaks Overclock Start ---\n'
            printf '# PROFILE: AUTO-OVERCLOCK %s\n' "$MODE"
            printf '# RESTORED LAST KNOWN GOOD\n'
            printf '%s\n' "$settings"
            printf '# --- PiTweaks Overclock End ---\n'
        } >> "$CONFIG_FILE"

        clear_auto_state

        echo
        echo "${GREEN}✅ Last known-good configuration restored.${RESET}"
        echo "${YELLOW}A reboot is required to activate the rollback.${RESET}"

        read -r -p "Reboot now? [Y/n]: " answer </dev/tty

        if [[ ! "$answer" =~ ^[Nn]$ ]]; then
            reboot
        fi

        return
    fi

    # --------------------------------------------------------------------------
    # Candidate passed basic post-boot check
    # --------------------------------------------------------------------------

    log_event "AUTO candidate passed post-boot check: $CURRENT MHz"

    printf '%s|%s|PASS|No immediate failure|%s|%s\n' \
        "$CURRENT" "$(get_temp)" "$MODE" "$(timestamp)" \
        >> "$RESULTS_FILE"

    echo "${GREEN}✅ Candidate survived reboot without immediate failure.${RESET}"
    echo
    echo "A real stress test is now required."

    read -r -p "Run stress validation now? [Y/n]: " answer </dev/tty

    if [[ ! "$answer" =~ ^[Nn]$ ]]; then
        ensure_stress_ng || {
            echo "❌ stress-ng unavailable."
            pause_screen
            return
        }

        local test_duration

        if [ "$MODE" = "RELIABLE" ]; then
            test_duration=300
        else
            test_duration=900
        fi

        stress_dashboard "COMBINED" "$test_duration"
    fi

    echo
    echo "Did the candidate remain stable throughout the test?"
    echo
    echo "  1) YES - mark PASS and continue"
    echo "  2) NO  - mark FAIL and revert"
    echo "  3) CANCEL auto-overclock"
    echo

    read -r -p "Selection [1-3]: " result </dev/tty

    case "$result" in

        1)
            STABLE="$CURRENT"

            if [ "$MODE" = "RELIABLE" ]; then
                STEP="$RELIABLE_STEP"
                NEXT=$((CURRENT+RELIABLE_STEP))

                if [ "$NEXT" -gt "$RELIABLE_MAX" ]; then
                    echo
                    echo "${GREEN}Maximum Reliable boundary reached.${RESET}"
                    clear_auto_state
                    pause_screen
                    return
                fi

            else
                STEP="$MAX_STEP"
                NEXT=$((CURRENT+MAX_STEP))

                if [ "$NEXT" -gt "$MAX_LIMIT" ]; then
                    echo
                    echo "${GREEN}Maximum Performance boundary reached.${RESET}"
                    clear_auto_state
                    pause_screen
                    return
                fi
            fi

            save_auto_state "$MODE" "$NEXT" "$STABLE" "$NEXT" "$STEP" "$VOLTAGE"

            echo
            echo "${GREEN}PASS: $CURRENT MHz${RESET}"
            echo "Next candidate: $NEXT MHz"
            echo
            echo "Continue to next frequency? [Y/n]"

            read -r -p "> " answer </dev/tty

            if [[ "$answer" =~ ^[Nn]$ ]]; then
                clear_auto_state
                pause_screen
                return
            fi

            local settings
            settings=$(generate_candidate_config "$NEXT" "$MODE" "$VOLTAGE")

            backup_before_change
            remove_pitweaks_block

            {
                printf '\n# --- PiTweaks Overclock Start ---\n'
                printf '# PROFILE: AUTO-OVERCLOCK %s\n' "$MODE"
                printf '# Candidate: %s MHz\n' "$NEXT"
                printf '# Last Stable: %s MHz\n' "$STABLE"
                printf '%s\n' "$settings"
                printf '# --- PiTweaks Overclock End ---\n'
            } >> "$CONFIG_FILE"

            log_event "AUTO next candidate prepared: $NEXT MHz"

            save_auto_state "$MODE" "$NEXT" "$STABLE" "$NEXT" "$STEP" "$VOLTAGE"

            echo
            echo "${YELLOW}Rebooting for next test stage...${RESET}"
            sleep 2
            reboot
            ;;

        2)
            log_event "AUTO candidate manually marked FAIL: $CURRENT MHz"

            echo
            echo "${RED}Candidate marked unstable.${RESET}"
            echo "Last known-good: $STABLE MHz"

            local settings
            settings=$(generate_candidate_config "$STABLE" "$MODE" "$VOLTAGE")

            backup_before_change
            remove_pitweaks_block

            {
                printf '\n# --- PiTweaks Overclock Start ---\n'
                printf '# PROFILE: AUTO-OVERCLOCK %s\n' "$MODE"
                printf '# RESTORED LAST KNOWN GOOD\n'
                printf '%s\n' "$settings"
                printf '# --- PiTweaks Overclock End ---\n'
            } >> "$CONFIG_FILE"

            clear_auto_state

            echo
            echo "${GREEN}Rollback prepared.${RESET}"

            read -r -p "Reboot now? [Y/n]: " answer </dev/tty
            [[ ! "$answer" =~ ^[Nn]$ ]] && reboot
            ;;

        3)
            clear_auto_state
            echo "Auto-overclock cancelled."
            pause_screen
            ;;

        *)
            echo "Invalid selection."
            pause_screen
            ;;
    esac
}

# ------------------------------------------------------------------------------
# AUTO OVERCLOCK MENU
# ------------------------------------------------------------------------------

auto_overclock_menu() {

    if [ "$PI_FAMILY" = "Other" ]; then
        echo "❌ Unsupported Raspberry Pi model."
        pause_screen
        return
    fi

    if [ -f "$AUTO_STATE" ]; then
        echo
        echo "${YELLOW}An automatic overclock test is currently staged.${RESET}"
        echo
        echo "Resume it?"
        echo
        echo "  1) Resume"
        echo "  2) Cancel"
        echo

        read -r -p "Selection [1-2]: " choice </dev/tty

        case "$choice" in
            1)
                auto_resume_if_needed
                return
                ;;
            2)
                clear_auto_state
                echo "Auto-overclock state cleared."
                pause_screen
                return
                ;;
            *)
                return
                ;;
        esac
    fi

    auto_safety_check || {
        pause_screen
        return
    }

    clear_screen

    echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║                  AUTO OVERCLOCK V2.0                      ║${RESET}"
    echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo
    echo "Hardware : $MODEL"
    echo "Current  : $(get_current_target_freq) MHz"
    echo
    echo "Select optimisation mode:"
    echo
    echo "  1) Reliable Overclock"
    echo "     • Stability first"
    echo "     • 24/7 oriented"
    echo "     • Smaller frequency increments"
    echo "     • 5 minute validation stages"
    echo
    echo "  2) Maximum Performance"
    echo "     • Performance first"
    echo "     • Larger frequency increments"
    echo "     • 15 minute validation stages"
    echo "     • Hard thermal safety limits remain"
    echo
    echo "  3) Cancel"
    echo

    read -r -p "Selection [1-3]: " MODE_CHOICE </dev/tty

    case "$MODE_CHOICE" in
        1)
            MODE="RELIABLE"
            START="$RELIABLE_START"
            STEP="$RELIABLE_STEP"
            MAX="$RELIABLE_MAX"
            VOLTAGE=0
            ;;

        2)
            MODE="MAXIMUM"
            START="$MAX_START"
            STEP="$MAX_STEP"
            MAX="$MAX_LIMIT"
            VOLTAGE=0
            ;;

        3)
            return
            ;;

        *)
            echo "Invalid choice."
            pause_screen
            return
            ;;
    esac

    local current stable next settings

    current=$(get_current_target_freq)

    if [ "$current" -ge "$START" ]; then
        START=$((current+STEP))
    fi

    stable="$current"
    next="$START"

    if [ "$next" -gt "$MAX" ]; then
        echo
        echo "Current configuration is already at or above the selected boundary."
        pause_screen
        return
    fi

    echo
    echo "${CYAN}AUTO OVERCLOCK PLAN${RESET}"
    echo
    echo "Mode             : $MODE"
    echo "Starting target  : $next MHz"
    echo "Step size        : $STEP MHz"
    echo "Maximum boundary : $MAX MHz"
    echo "Current stable   : $stable MHz"
    echo "Voltage offset   : $VOLTAGE"
    echo
    echo "${YELLOW}Every candidate requires a reboot because config.txt settings are boot-time settings.${RESET}"
    echo

    save_auto_state "$MODE" "$next" "$stable" "$next" "$STEP" "$VOLTAGE"

    settings=$(generate_candidate_config "$next" "$MODE" "$VOLTAGE")

    if ! validate_config "$settings"; then
        echo "❌ Generated configuration failed validation."
        clear_auto_state
        pause_screen
        return
    fi

    read -r -p "Begin automatic overclocking? [y/N]: " answer </dev/tty

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        run_auto_stage "$MODE" "$next" "$stable" \
            "$([ "$MODE" = "RELIABLE" ] && echo 300 || echo 900)" \
            "$VOLTAGE"
    else
        clear_auto_state
    fi
}

# ------------------------------------------------------------------------------
# DIAGNOSTIC DASHBOARD
# ------------------------------------------------------------------------------

diagnostic_dashboard() {

    clear_screen

    local temp arm core sdram voltage health
    temp=$(get_temp)
    arm=$(get_arm_clock)
    core=$(get_core_clock)
    sdram=$(get_sdram_clock)
    voltage=$(get_core_voltage)
    health=$(get_overall_health)

    echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║              🍓 PiTweaks • DIAGNOSTICS V2.0               ║${RESET}"
    echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
    printf "║ MODEL        : %-46s ║\n" "$MODEL"
    printf "║ FAMILY       : %-46s ║\n" "$PI_FAMILY"
    printf "║ CPU CORES    : %-46s ║\n" "$CPU_CORES"
    printf "║ PROFILE      : %-46s ║\n" "$(detect_profile)"
    echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
    printf "║ ARM CLOCK    : %6s MHz                                      ║\n" "$arm"
    printf "║ CORE/GPU     : %6s MHz                                      ║\n" "$core"
    printf "║ SDRAM        : %6s MHz                                      ║\n" "$sdram"
    printf "║ CORE VOLTAGE : %-48s ║\n" "$voltage"
    printf "║ TEMPERATURE  : %s°C                                         ║\n" "$temp"
    echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"
    echo "║ HEALTH                                                     ║"
    printf "║ Overall      : "
    status_colour "$health"
    echo "                                             ║"
    display_throttle_state
    echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"

    if [ -s "$RESULTS_FILE" ]; then
        echo "║ RECENT AUTO-OVERCLOCK RESULTS                             ║"
        echo "${CYAN}╠══════════════════════════════════════════════════════════════╣${RESET}"

        while IFS='|' read -r freq temp_result result reason mode time; do
            if [ "$result" = "PASS" ]; then
                printf "║ %5s MHz  ${GREEN}PASS${RESET}  %5s°C  %-20s ║\n" \
                    "$freq" "$temp_result" "$mode"
            else
                printf "║ %5s MHz  ${RED}FAIL${RESET}  %5s°C  %-20s ║\n" \
                    "$freq" "$temp_result" "$mode"
            fi
        done < "$RESULTS_FILE"
    else
        echo "║ No auto-overclock results in current session.             ║"
    fi

    echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo

    if [ -s "$EVENT_LOG" ]; then
        echo "${BOLD}EVENT TIMELINE${RESET}"
        echo "--------------------------------------------------------------"
        tail -20 "$EVENT_LOG"
    fi

    echo
    pause_screen
}

# ------------------------------------------------------------------------------
# STARTUP AUTO-RESUME
# ------------------------------------------------------------------------------

# If the script was manually run after an auto-overclock reboot,
# detect the staged state and offer continuation.
if [ -f "$AUTO_STATE" ]; then

    clear_screen

    echo "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo "${CYAN}║             PiTweaks • AUTO TEST DETECTED                 ║${RESET}"
    echo "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo
    echo "A previous automatic overclock test is staged."
    echo
    echo "  1) Resume"
    echo "  2) Enter normal menu"
    echo "  3) Cancel staged test"
    echo

    read -r -p "Selection [1-3]: " RESUME_CHOICE </dev/tty

    case "$RESUME_CHOICE" in
        1)
            auto_resume_if_needed
            ;;
        3)
            clear_auto_state
            ;;
    esac
fi

# ------------------------------------------------------------------------------
# MAIN LOOP
# ------------------------------------------------------------------------------

while true; do
    preset_menu
done
```
