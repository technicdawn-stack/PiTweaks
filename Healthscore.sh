#!/bin/bash

# Description: Adaptive Raspberry Pi Health Scoring & Diagnostic Utility
# PERSISTENT: FALSE
# Category: Diagnostics
# Version: V1.6
#
# PiTweaks Healthscore
#
# V1.6 changes:
#   - Live Health Score
#   - Historical Health Score
#   - 30-day historical average
#   - Best / worst recorded scores
#   - Health trend
#   - Current vs historical issue separation
#   - Historical event ageing
#   - Expanded Raspberry Pi diagnostics
#   - Expanded service reliability checks
#   - Expanded kernel / boot diagnostics
#   - Expanded network / DNS diagnostics
#   - Expanded storage / filesystem diagnostics
#   - Expanded security diagnostics
#   - Adaptive applicability
#   - Confidence reporting
#   - Professional diagnostic interface
#
# IMPORTANT:
#   This module is diagnostic only.
#   It does not automatically modify system configuration.
# ============================================================

set -u
set -o pipefail

VERSION="1.6"

# ============================================================
# CONFIGURATION
# ============================================================

HISTORY_ROOT="/var/lib/pitweaks/healthscore"
USER_HISTORY_ROOT="${HOME}/.pitweaks/healthscore"

if [[ "${EUID}" -eq 0 ]]; then
    if mkdir -p "${HISTORY_ROOT}" 2>/dev/null; then
        HISTORY_DIR="${HISTORY_ROOT}"
    else
        HISTORY_DIR="${USER_HISTORY_ROOT}"
        mkdir -p "${HISTORY_DIR}" 2>/dev/null || true
    fi
else
    if [[ -d "${HISTORY_ROOT}" && -w "${HISTORY_ROOT}" ]]; then
        HISTORY_DIR="${HISTORY_ROOT}"
    elif sudo -n mkdir -p "${HISTORY_ROOT}" 2>/dev/null &&
         sudo -n chown "${USER}:${USER}" "${HISTORY_ROOT}" 2>/dev/null; then
        HISTORY_DIR="${HISTORY_ROOT}"
    else
        HISTORY_DIR="${USER_HISTORY_ROOT}"
        mkdir -p "${HISTORY_DIR}" 2>/dev/null || true
    fi
fi

HISTORY_FILE="${HISTORY_DIR}/history.csv"
EVENT_FILE="${HISTORY_DIR}/events.log"
LATEST_FILE="${HISTORY_DIR}/latest"

mkdir -p "${HISTORY_DIR}" 2>/dev/null || true

# ============================================================
# TEMPORARY DATA
# ============================================================

TMP_ROOT="$(mktemp -d /tmp/pitweaks-healthscore.XXXXXX 2>/dev/null || echo "/tmp/pitweaks-healthscore.$$")"
mkdir -p "${TMP_ROOT}" 2>/dev/null || true

cleanup() {
    rm -rf "${TMP_ROOT}" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 130' INT TERM

RESULT_FILE="${TMP_ROOT}/results"
ISSUE_FILE="${TMP_ROOT}/issues"
CURRENT_ISSUE_FILE="${TMP_ROOT}/current_issues"
HISTORICAL_ISSUE_FILE="${TMP_ROOT}/historical_issues"

: > "${RESULT_FILE}"
: > "${ISSUE_FILE}"
: > "${CURRENT_ISSUE_FILE}"
: > "${HISTORICAL_ISSUE_FILE}"

# ============================================================
# SCORE VARIABLES
# ============================================================

declare -a RESULT_CATEGORY
declare -a RESULT_TITLE
declare -a RESULT_STATUS
declare -a RESULT_DETAIL
declare -a RESULT_FIX
declare -a RESULT_POINTS
declare -a RESULT_MAX
declare -a RESULT_SCOPE

RESULT_COUNT=0
APPLICABLE_COUNT=0
SKIPPED_COUNT=0

LIVE_EARNED=0
LIVE_POSSIBLE=0

declare -A CAT_EARNED
declare -A CAT_POSSIBLE
declare -A CAT_CHECKS

LIVE_SCORE=0
HISTORICAL_SCORE=0
AVERAGE_SCORE=0
BEST_SCORE=0
WORST_SCORE=0
TREND_VALUE=0
CONFIDENCE=0

SCAN_TIMESTAMP=""
SCAN_EPOCH=0

# ============================================================
# GENERAL HELPERS
# ============================================================

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

num_or_zero() {
    local n="${1:-0}"

    if [[ "${n}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s' "${n}"
    else
        printf '0'
    fi
}

is_number() {
    [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

percent_used() {
    local used="${1:-0}"
    local total="${2:-0}"

    if [[ "${total}" -le 0 ]]; then
        echo 0
        return
    fi

    echo $((used * 100 / total))
}

safe_read() {
    local file="$1"

    [[ -r "${file}" ]] || return 1

    cat "${file}" 2>/dev/null
}

first_line() {
    printf '%s\n' "$1" | head -n1
}

# ============================================================
# PRIVILEGE HELPERS
# ============================================================

ROOT_AVAILABLE=false

if [[ "${EUID}" -eq 0 ]]; then
    ROOT_AVAILABLE=true
elif have_cmd sudo && sudo -n true >/dev/null 2>&1; then
    ROOT_AVAILABLE=true
fi

root_cmd() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
    elif have_cmd sudo && sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
    else
        return 1
    fi
}

# ============================================================
# WHIPTAIL
# ============================================================

if ! have_cmd whiptail; then
    echo "PiTweaks Healthscore requires whiptail."
    echo "Please install it with:"
    echo "  sudo apt install whiptail"
    exit 1
fi

ui_msg() {
    whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --msgbox "$1" \
        "${2:-18}" "${3:-72}"
}

ui_yesno() {
    whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --yesno "$1" \
        "${2:-16}" "${3:-70}"
}

# ============================================================
# CHECK ENGINE
# ============================================================

add_issue() {
    local scope="$1"
    local category="$2"
    local severity="$3"
    local title="$4"
    local detail="$5"
    local fix="$6"
    local points="$7"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${scope}" \
        "${category}" \
        "${severity}" \
        "${title}" \
        "${detail}" \
        "${fix}" \
        "${points}" >> "${ISSUE_FILE}"

    if [[ "${scope}" == "CURRENT" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${category}" \
            "${severity}" \
            "${title}" \
            "${detail}" \
            "${fix}" \
            "${points}" >> "${CURRENT_ISSUE_FILE}"
    else
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${category}" \
            "${severity}" \
            "${title}" \
            "${detail}" \
            "${fix}" \
            "${points}" >> "${HISTORICAL_ISSUE_FILE}"
    fi
}

check_result() {
    local category="$1"
    local title="$2"
    local max_points="$3"
    local status="$4"
    local detail="$5"
    local fix="$6"
    local scope="${7:-LIVE}"

    RESULT_CATEGORY[RESULT_COUNT]="${category}"
    RESULT_TITLE[RESULT_COUNT]="${title}"
    RESULT_STATUS[RESULT_COUNT]="${status}"
    RESULT_DETAIL[RESULT_COUNT]="${detail}"
    RESULT_FIX[RESULT_COUNT]="${fix}"
    RESULT_POINTS[RESULT_COUNT]="${max_points}"
    RESULT_MAX[RESULT_COUNT]="${max_points}"
    RESULT_SCOPE[RESULT_COUNT]="${scope}"

    RESULT_COUNT=$((RESULT_COUNT + 1))

    CAT_CHECKS["${category}"]=$(( ${CAT_CHECKS["${category}"]:-0} + 1 ))

    if [[ "${status}" == "SKIP" ]]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return
    fi

    APPLICABLE_COUNT=$((APPLICABLE_COUNT + 1))

    CAT_POSSIBLE["${category}"]=$(( ${CAT_POSSIBLE["${category}"]:-0} + max_points ))
    LIVE_POSSIBLE=$((LIVE_POSSIBLE + max_points))

    case "${status}" in
        PASS)
            CAT_EARNED["${category}"]=$(( ${CAT_EARNED["${category}"]:-0} + max_points ))
            LIVE_EARNED=$((LIVE_EARNED + max_points ))
            ;;
        WARN)
            local half=$((max_points / 2))
            CAT_EARNED["${category}"]=$(( ${CAT_EARNED["${category}"]:-0} + half ))
            LIVE_EARNED=$((LIVE_EARNED + half))
            ;;
        FAIL)
            ;;
    esac

    if [[ "${status}" == "WARN" || "${status}" == "FAIL" ]]; then
        local severity="WARNING"

        if [[ "${status}" == "FAIL" ]]; then
            severity="CRITICAL"
        fi

        local points_lost=$((max_points))

        add_issue \
            "${scope}" \
            "${category}" \
            "${severity}" \
            "${title}" \
            "${detail}" \
            "${fix}" \
            "${points_lost}"
    fi
}

skip_check() {
    local category="$1"
    local title="$2"
    local reason="${3:-Not applicable}"

    check_result \
        "${category}" \
        "${title}" \
        0 \
        "SKIP" \
        "${reason}" \
        "" \
        "LIVE"
}

# ============================================================
# SYSTEM INFORMATION
# ============================================================

PI_MODEL=""
PI_ARCH=""
KERNEL_VERSION=""
HOSTNAME_VALUE=""

get_system_info() {
    PI_MODEL="$(grep -m1 -E '^Model' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs 2>/dev/null || true)"

    if [[ -z "${PI_MODEL}" ]]; then
        PI_MODEL="$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0' || true)"
    fi

    PI_ARCH="$(uname -m 2>/dev/null || echo unknown)"
    KERNEL_VERSION="$(uname -r 2>/dev/null || echo unknown)"
    HOSTNAME_VALUE="$(hostname 2>/dev/null || echo unknown)"
}

# ============================================================
# CPU CHECKS
# ============================================================

run_cpu_checks() {

    local cores
    cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"

    if [[ "${cores}" -ge 2 ]]; then
        check_result \
            "CPU & Performance" \
            "CPU core availability" \
            2 \
            "PASS" \
            "${cores} CPU cores detected." \
            "" \
            "LIVE"
    else
        check_result \
            "CPU & Performance" \
            "CPU core availability" \
            2 \
            "WARN" \
            "Only one CPU core is available." \
            "Check CPU configuration and kernel settings." \
            "LIVE"
    fi

    local load
    load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"

    if is_number "${load}"; then
        local threshold
        threshold="$(awk -v c="${cores}" 'BEGIN { print c * 1.5 }')"

        if awk -v l="${load}" -v t="${threshold}" 'BEGIN { exit !(l > t) }'; then
            check_result \
                "CPU & Performance" \
                "CPU load" \
                3 \
                "WARN" \
                "Load average is ${load} across ${cores} CPU cores." \
                "Investigate processes causing sustained CPU load." \
                "LIVE"
        else
            check_result \
                "CPU & Performance" \
                "CPU load" \
                3 \
                "PASS" \
                "Current load average is ${load}." \
                "" \
                "LIVE"
        fi
    else
        skip_check "CPU & Performance" "CPU load" "Unable to read load average."
    fi

    local idle
    idle="$(awk '/^cpu / {print $5}' /proc/stat 2>/dev/null || echo 0)"

    if [[ "${idle}" =~ ^[0-9]+$ ]]; then
        check_result \
            "CPU & Performance" \
            "CPU idle availability" \
            2 \
            "PASS" \
            "Kernel CPU statistics are available." \
            "" \
            "LIVE"
    else
        skip_check "CPU & Performance" "CPU idle availability" "Kernel CPU statistics unavailable."
    fi

    local governor=""
    for g in /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor \
             /sys/devices/system/cpu/cpufreq/policy0/scaling_governor; do
        if [[ -r "${g}" ]]; then
            governor="$(cat "${g}" 2>/dev/null)"
            break
        fi
    done

    if [[ -n "${governor}" ]]; then
        case "${governor}" in
            powersave)
                check_result \
                    "CPU & Performance" \
                    "CPU frequency governor" \
                    2 \
                    "WARN" \
                    "CPU governor is set to powersave." \
                    "Use ondemand or another suitable governor if sustained performance is required." \
                    "LIVE"
                ;;
            *)
                check_result \
                    "CPU & Performance" \
                    "CPU frequency governor" \
                    2 \
                    "PASS" \
                    "CPU governor is ${governor}." \
                    "" \
                    "LIVE"
                ;;
        esac
    else
        skip_check "CPU & Performance" "CPU frequency governor" "CPU frequency governor is unavailable."
    fi

    local cur_freq=""
    for f in /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq \
             /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq; do
        if [[ -r "${f}" ]]; then
            cur_freq="$(cat "${f}" 2>/dev/null)"
            break
        fi
    done

    if [[ "${cur_freq}" =~ ^[0-9]+$ ]]; then
        local mhz=$((cur_freq / 1000))

        if [[ "${mhz}" -gt 0 ]]; then
            check_result \
                "CPU & Performance" \
                "Current CPU frequency" \
                2 \
                "PASS" \
                "Current CPU frequency is approximately ${mhz} MHz." \
                "" \
                "LIVE"
        else
            check_result \
                "CPU & Performance" \
                "Current CPU frequency" \
                2 \
                "WARN" \
                "CPU frequency appears unusually low." \
                "Check governor, thermal throttling and power conditions." \
                "LIVE"
        fi
    elif have_cmd vcgencmd; then
        local vcpu
        vcpu="$(vcgencmd measure_clock arm 2>/dev/null || true)"

        if [[ -n "${vcpu}" ]]; then
            check_result \
                "CPU & Performance" \
                "Current CPU frequency" \
                2 \
                "PASS" \
                "${vcpu}" \
                "" \
                "LIVE"
        else
            skip_check "CPU & Performance" "Current CPU frequency" "Frequency information unavailable."
        fi
    else
        skip_check "CPU & Performance" "Current CPU frequency" "Frequency information unavailable."
    fi

    if [[ -r /proc/cpuinfo ]]; then
        local model
        model="$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs || true)"

        if [[ -z "${model}" ]]; then
            model="${PI_MODEL:-Raspberry Pi CPU}"
        fi

        check_result \
            "CPU & Performance" \
            "CPU identification" \
            1 \
            "PASS" \
            "${model}" \
            "" \
            "LIVE"
    else
        skip_check "CPU & Performance" "CPU identification" "CPU information unavailable."
    fi
}

# ============================================================
# TEMPERATURE / POWER / THROTTLING
# ============================================================

get_temperature() {

    if have_cmd vcgencmd; then
        local t
        t="$(vcgencmd measure_temp 2>/dev/null | grep -o '[0-9.]*' | head -n1 || true)"

        if is_number "${t}"; then
            printf '%s' "${t}"
            return 0
        fi
    fi

    local thermal="/sys/class/thermal/thermal_zone0/temp"

    if [[ -r "${thermal}" ]]; then
        local raw
        raw="$(cat "${thermal}" 2>/dev/null || echo 0)"

        if [[ "${raw}" =~ ^[0-9]+$ ]]; then
            awk -v t="${raw}" 'BEGIN { printf "%.1f", t / 1000 }'
            return 0
        fi
    fi

    return 1
}

decode_throttled() {

    local value="$1"

    value=$((value))

    local current_uv=$((value & 1))
    local current_cap=$((value & 2))
    local current_throttle=$((value & 4))
    local current_temp=$((value & 8))

    local historical_uv=$((value & 65536))
    local historical_cap=$((value & 131072))
    local historical_throttle=$((value & 262144))
    local historical_temp=$((value & 524288))

    THROTTLE_CURRENT_UV="${current_uv}"
    THROTTLE_CURRENT_CAP="${current_cap}"
    THROTTLE_CURRENT_THROTTLE="${current_throttle}"
    THROTTLE_CURRENT_TEMP="${current_temp}"

    THROTTLE_HIST_UV="${historical_uv}"
    THROTTLE_HIST_CAP="${historical_cap}"
    THROTTLE_HIST_THROTTLE="${historical_throttle}"
    THROTTLE_HIST_TEMP="${historical_temp}"
}

THROTTLE_CURRENT_UV=0
THROTTLE_CURRENT_CAP=0
THROTTLE_CURRENT_THROTTLE=0
THROTTLE_CURRENT_TEMP=0

THROTTLE_HIST_UV=0
THROTTLE_HIST_CAP=0
THROTTLE_HIST_THROTTLE=0
THROTTLE_HIST_TEMP=0

run_power_checks() {

    local temp
    temp="$(get_temperature 2>/dev/null || true)"

    if is_number "${temp}"; then

        if awk -v t="${temp}" 'BEGIN { exit !(t >= 80) }'; then
            check_result \
                "Power & Thermal" \
                "CPU temperature" \
                6 \
                "FAIL" \
                "CPU temperature is ${temp}°C." \
                "Improve cooling and airflow immediately." \
                "LIVE"

        elif awk -v t="${temp}" 'BEGIN { exit !(t >= 70) }'; then
            check_result \
                "Power & Thermal" \
                "CPU temperature" \
                6 \
                "WARN" \
                "CPU temperature is ${temp}°C." \
                "Check cooling and airflow if this temperature is sustained." \
                "LIVE"

        else
            check_result \
                "Power & Thermal" \
                "CPU temperature" \
                6 \
                "PASS" \
                "CPU temperature is ${temp}°C." \
                "" \
                "LIVE"
        fi
    else
        skip_check "Power & Thermal" "CPU temperature" "Temperature sensor unavailable."
    fi

    if have_cmd vcgencmd; then

        local throttle
        throttle="$(vcgencmd get_throttled 2>/dev/null || true)"

        if [[ "${throttle}" =~ 0x([0-9a-fA-F]+) ]]; then
            local hex="${BASH_REMATCH[1]}"
            local decimal=$((16#${hex}))

            decode_throttled "${decimal}"

            if [[ "${THROTTLE_CURRENT_UV}" -ne 0 ||
                  "${THROTTLE_CURRENT_THROTTLE}" -ne 0 ||
                  "${THROTTLE_CURRENT_TEMP}" -ne 0 ]]; then

                check_result \
                    "Power & Thermal" \
                    "Current power / thermal state" \
                    7 \
                    "FAIL" \
                    "Current throttling or undervoltage condition detected (${throttle})." \
                    "Check PSU quality, cable voltage drop, cooling and sustained load." \
                    "LIVE"
            elif [[ "${THROTTLE_CURRENT_CAP}" -ne 0 ]]; then

                check_result \
                    "Power & Thermal" \
                    "Current CPU frequency cap" \
                    4 \
                    "WARN" \
                    "The CPU is currently frequency capped." \
                    "Check power and thermal conditions." \
                    "LIVE"
            else

                check_result \
                    "Power & Thermal" \
                    "Current power / thermal state" \
                    7 \
                    "PASS" \
                    "No current undervoltage or throttling condition detected." \
                    "" \
                    "LIVE"
            fi

            if [[ "${THROTTLE_HIST_UV}" -ne 0 ||
                  "${THROTTLE_HIST_THROTTLE}" -ne 0 ||
                  "${THROTTLE_HIST_CAP}" -ne 0 ||
                  "${THROTTLE_HIST_TEMP}" -ne 0 ]]; then

                local events=""

                [[ "${THROTTLE_HIST_UV}" -ne 0 ]] && events+="undervoltage, "
                [[ "${THROTTLE_HIST_THROTTLE}" -ne 0 ]] && events+="throttling, "
                [[ "${THROTTLE_HIST_CAP}" -ne 0 ]] && events+="frequency capping, "
                [[ "${THROTTLE_HIST_TEMP}" -ne 0 ]] && events+="thermal limiting, "

                events="${events%, }"

                add_issue \
                    "HISTORICAL" \
                    "Power & Thermal" \
                    "WARNING" \
                    "Historical power / thermal events" \
                    "Firmware reports previous ${events}." \
                    "Investigate the PSU, cable, cooling and sustained load if these events continue." \
                    2

            else
                check_result \
                    "Power & Thermal" \
                    "Historical power stability" \
                    3 \
                    "PASS" \
                    "No historical undervoltage or throttling events reported." \
                    "" \
                    "HISTORICAL"
            fi

        else
            skip_check "Power & Thermal" "Power / throttling state" "vcgencmd get_throttled did not return usable data."
        fi

        local volts
        volts="$(vcgencmd measure_volts core 2>/dev/null || true)"

        if [[ -n "${volts}" ]]; then
            check_result \
                "Power & Thermal" \
                "Core voltage reporting" \
                1 \
                "PASS" \
                "${volts}" \
                "" \
                "LIVE"
        else
            skip_check "Power & Thermal" "Core voltage reporting" "Voltage information unavailable."
        fi

    else
        skip_check "Power & Thermal" "Power / throttling state" "vcgencmd unavailable."
        skip_check "Power & Thermal" "Historical power stability" "Raspberry Pi firmware telemetry unavailable."
    fi
}

# ============================================================
# MEMORY
# ============================================================

run_memory_checks() {

    local mem_total
    local mem_available
    local swap_total
    local swap_free

    mem_total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    mem_available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_total="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_free="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

    if [[ "${mem_total}" -gt 0 ]]; then

        local mem_used_percent
        mem_used_percent="$(percent_used $((mem_total - mem_available)) "${mem_total}")"

        if [[ "${mem_used_percent}" -ge 95 ]]; then
            check_result \
                "Memory" \
                "Available memory" \
                5 \
                "FAIL" \
                "Approximately ${mem_used_percent}% of physical memory is currently in use." \
                "Stop unnecessary processes or investigate memory leaks." \
                "LIVE"

        elif [[ "${mem_used_percent}" -ge 85 ]]; then
            check_result \
                "Memory" \
                "Available memory" \
                5 \
                "WARN" \
                "Approximately ${mem_used_percent}% of physical memory is currently in use." \
                "Review memory-heavy processes." \
                "LIVE"

        else
            check_result \
                "Memory" \
                "Available memory" \
                5 \
                "PASS" \
                "Approximately ${mem_used_percent}% of physical memory is in use." \
                "" \
                "LIVE"
        fi
    else
        skip_check "Memory" "Available memory" "Unable to read /proc/meminfo."
    fi

    if [[ "${swap_total}" -gt 0 ]]; then

        local swap_used
        swap_used=$((swap_total - swap_free))

        local swap_percent
        swap_percent="$(percent_used "${swap_used}" "${swap_total}")"

        if [[ "${swap_percent}" -ge 80 ]]; then
            check_result \
                "Memory" \
                "Swap utilisation" \
                4 \
                "WARN" \
                "Swap is ${swap_percent}% utilised." \
                "Investigate memory pressure and processes using large amounts of RAM." \
                "LIVE"
        else
            check_result \
                "Memory" \
                "Swap utilisation" \
                4 \
                "PASS" \
                "Swap is ${swap_percent}% utilised." \
                "" \
                "LIVE"
        fi
    else
        skip_check "Memory" "Swap utilisation" "No swap device or file detected."
    fi

    if [[ -r /proc/meminfo ]]; then

        local corrupted
        corrupted="$(awk '/^HardwareCorrupted:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

        if [[ "${corrupted}" =~ ^[0-9]+$ && "${corrupted}" -gt 0 ]]; then
            check_result \
                "Memory" \
                "Hardware memory corruption" \
                6 \
                "FAIL" \
                "Kernel reports ${corrupted} kB of hardware-corrupted memory." \
                "Investigate RAM and hardware reliability." \
                "LIVE"
        else
            check_result \
                "Memory" \
                "Hardware memory corruption" \
                6 \
                "PASS" \
                "No hardware-corrupted memory is currently reported." \
                "" \
                "LIVE"
        fi
    fi

    if compgen -G "/sys/devices/system/edac_mc/mc*/uevent" >/dev/null 2>&1; then
        check_result \
            "Memory" \
            "EDAC memory monitoring" \
            2 \
            "PASS" \
            "EDAC memory monitoring is available." \
            "" \
            "LIVE"
    else
        skip_check "Memory" "EDAC memory monitoring" "EDAC is not available on this platform."
    fi

    if compgen -G "/dev/zram*" >/dev/null 2>&1 ||
       compgen -G "/sys/block/zram*" >/dev/null 2>&1; then

        check_result \
            "Memory" \
            "ZRAM availability" \
            2 \
            "PASS" \
            "ZRAM is available." \
            "" \
            "LIVE"
    else
        skip_check "Memory" "ZRAM availability" "ZRAM is not configured."
    fi

    if have_cmd vmstat; then
        local vm
        vm="$(vmstat 1 2 2>/dev/null | tail -n1 || true)"

        if [[ -n "${vm}" ]]; then
            local swap_in swap_out
            swap_in="$(awk '{print $(NF-1)}' <<< "${vm}" 2>/dev/null || echo 0)"
            swap_out="$(awk '{print $NF}' <<< "${vm}" 2>/dev/null || echo 0)"

            if [[ "${swap_in}" =~ ^[0-9]+$ &&
                  "${swap_out}" =~ ^[0-9]+$ &&
                  ( "${swap_in}" -gt 0 || "${swap_out}" -gt 0 ) ]]; then

                check_result \
                    "Memory" \
                    "Active swap movement" \
                    3 \
                    "WARN" \
                    "Swap activity was observed during the test." \
                    "Check for sustained memory pressure." \
                    "LIVE"
            else
                check_result \
                    "Memory" \
                    "Active swap movement" \
                    3 \
                    "PASS" \
                    "No significant swap movement was observed during the test." \
                    "" \
                    "LIVE"
            fi
        else
            skip_check "Memory" "Active swap movement" "vmstat returned no usable data."
        fi
    else
        skip_check "Memory" "Active swap movement" "vmstat is unavailable."
    fi
}

# ============================================================
# STORAGE / FILESYSTEM
# ============================================================

run_storage_checks() {

    local root_usage
    root_usage="$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}' || echo 0)"

    if [[ "${root_usage}" =~ ^[0-9]+$ ]]; then

        if [[ "${root_usage}" -ge 95 ]]; then
            check_result \
                "Storage & Filesystems" \
                "Root filesystem capacity" \
                7 \
                "FAIL" \
                "Root filesystem is ${root_usage}% full." \
                "Free storage space immediately." \
                "LIVE"

        elif [[ "${root_usage}" -ge 85 ]]; then
            check_result \
                "Storage & Filesystems" \
                "Root filesystem capacity" \
                7 \
                "WARN" \
                "Root filesystem is ${root_usage}% full." \
                "Consider removing unnecessary files or expanding storage." \
                "LIVE"

        else
            check_result \
                "Storage & Filesystems" \
                "Root filesystem capacity" \
                7 \
                "PASS" \
                "Root filesystem is ${root_usage}% full." \
                "" \
                "LIVE"
        fi
    else
        skip_check "Storage & Filesystems" "Root filesystem capacity" "Unable to read filesystem usage."
    fi

    local root_mount
    root_mount="$(findmnt -no FSTYPE / 2>/dev/null || true)"

    if [[ -n "${root_mount}" ]]; then
        check_result \
            "Storage & Filesystems" \
            "Root filesystem type" \
            2 \
            "PASS" \
            "Root filesystem type is ${root_mount}." \
            "" \
            "LIVE"
    else
        skip_check "Storage & Filesystems" "Root filesystem type" "findmnt unavailable."
    fi

    local root_options
    root_options="$(findmnt -no OPTIONS / 2>/dev/null || true)"

    if grep -qw "ro" <<< "${root_options}"; then
        check_result \
            "Storage & Filesystems" \
            "Root filesystem write state" \
            7 \
            "FAIL" \
            "Root filesystem is mounted read-only." \
            "Investigate filesystem errors and storage health before remounting read-write." \
            "LIVE"
    else
        check_result \
            "Storage & Filesystems" \
            "Root filesystem write state" \
            7 \
            "PASS" \
            "Root filesystem is mounted read-write." \
            "" \
            "LIVE"
    fi

    local inode_usage
    inode_usage="$(df -Pi / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}' || echo 0)"

    if [[ "${inode_usage}" =~ ^[0-9]+$ ]]; then

        if [[ "${inode_usage}" -ge 95 ]]; then
            check_result \
                "Storage & Filesystems" \
                "Root inode capacity" \
                4 \
                "FAIL" \
                "Root filesystem is ${inode_usage}% full on inodes." \
                "Remove excessive small files and investigate applications creating large file counts." \
                "LIVE"

        elif [[ "${inode_usage}" -ge 85 ]]; then
            check_result \
                "Storage & Filesystems" \
                "Root inode capacity" \
                4 \
                "WARN" \
                "Root filesystem is ${inode_usage}% full on inodes." \
                "Monitor inode usage." \
                "LIVE"

        else
            check_result \
                "Storage & Filesystems" \
                "Root inode capacity" \
                4 \
                "PASS" \
                "Root filesystem inode usage is ${inode_usage}%." \
                "" \
                "LIVE"
        fi
    fi

    if [[ -r /etc/fstab ]]; then

        if have_cmd findmnt; then
            local fstab_result
            fstab_result="$(findmnt --verify --verbose 2>&1 || true)"

            if grep -qiE "successfully verified|success" <<< "${fstab_result}" &&
               ! grep -qiE "error|failed" <<< "${fstab_result}"; then

                check_result \
                    "Storage & Filesystems" \
                    "Filesystem mount configuration" \
                    5 \
                    "PASS" \
                    "fstab verification completed without reported errors." \
                    "" \
                    "LIVE"
            elif grep -qiE "error|failed" <<< "${fstab_result}"; then

                check_result \
                    "Storage & Filesystems" \
                    "Filesystem mount configuration" \
                    5 \
                    "WARN" \
                    "Filesystem mount configuration reported a problem." \
                    "Review /etc/fstab and verify all expected mounts." \
                    "LIVE"
            else
                skip_check "Storage & Filesystems" "Filesystem mount configuration" "fstab verification returned ambiguous output."
            fi
        else
            skip_check "Storage & Filesystems" "Filesystem mount configuration" "findmnt unavailable."
        fi
    fi

    if have_cmd systemctl; then
        local failed_mounts
        failed_mounts="$(systemctl list-units --failed --type=mount --no-legend 2>/dev/null || true)"

        if [[ -n "${failed_mounts}" ]]; then
            check_result \
                "Storage & Filesystems" \
                "Failed filesystem mounts" \
                6 \
                "FAIL" \
                "One or more filesystem mount units have failed." \
                "Inspect the failed mount units and verify storage availability and fstab entries." \
                "LIVE"
        else
            check_result \
                "Storage & Filesystems" \
                "Failed filesystem mounts" \
                6 \
                "PASS" \
                "No failed filesystem mount units detected." \
                "" \
                "LIVE"
        fi
    fi

    local log_usage
    log_usage="$(du -sm /var/log 2>/dev/null | awk '{print $1}' || echo 0)"

    if [[ "${log_usage}" =~ ^[0-9]+$ ]]; then

        if [[ "${log_usage}" -ge 2048 ]]; then
            check_result \
                "Storage & Filesystems" \
                "System log storage" \
                3 \
                "WARN" \
                "/var/log is approximately ${log_usage} MB." \
                "Review persistent logs and log rotation." \
                "LIVE"
        else
            check_result \
                "Storage & Filesystems" \
                "System log storage" \
                3 \
                "PASS" \
                "/var/log is approximately ${log_usage} MB." \
                "" \
                "LIVE"
        fi
    fi

    if have_cmd lsblk; then
        local block_devices
        block_devices="$(lsblk -dn -o NAME,TYPE,SIZE 2>/dev/null || true)"

        if [[ -n "${block_devices}" ]]; then
            check_result \
                "Storage & Filesystems" \
                "Block device detection" \
                2 \
                "PASS" \
                "Storage devices detected successfully." \
                "" \
                "LIVE"
        else
            skip_check "Storage & Filesystems" "Block device detection" "lsblk returned no devices."
        fi
    else
        skip_check "Storage & Filesystems" "Block device detection" "lsblk unavailable."
    fi

    local io_errors=""

    if have_cmd dmesg; then
        io_errors="$(dmesg 2>/dev/null | tail -n 1000 | grep -Ei \
            'I/O error|blk_update_request|Buffer I/O|EXT4-fs error|mmc.*error|mmcblk.*error|ata.*error|read-only filesystem' \
            | tail -n 10 || true)"
    elif have_cmd journalctl; then
        io_errors="$(journalctl -k -b --no-pager 2>/dev/null | grep -Ei \
            'I/O error|blk_update_request|Buffer I/O|EXT4-fs error|mmc.*error|mmcblk.*error|ata.*error|read-only filesystem' \
            | tail -n 10 || true)"
    fi

    if [[ -n "${io_errors}" ]]; then
        check_result \
            "Storage & Filesystems" \
            "Storage I/O errors" \
            8 \
            "FAIL" \
            "Recent kernel/storage errors were detected." \
            "Investigate the SD card, SSD, USB connection and filesystem health." \
            "LIVE"
    else
        check_result \
            "Storage & Filesystems" \
            "Storage I/O errors" \
            8 \
            "PASS" \
            "No recent storage I/O errors were detected." \
            "" \
            "LIVE"
    fi

    if have_cmd smartctl; then

        local smart_devices
        smart_devices="$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}' || true)"

        if [[ -n "${smart_devices}" ]]; then

            local smart_found=false

            while read -r dev; do
                [[ -n "${dev}" ]] || continue

                case "${dev}" in
                    /dev/mmcblk*)
                        continue
                        ;;
                esac

                if root_cmd smartctl -H "${dev}" >/dev/null 2>&1; then
                    smart_found=true

                    local health
                    health="$(root_cmd smartctl -H "${dev}" 2>/dev/null | grep -Ei 'PASSED|FAILED|UNKNOWN' | head -n1 || true)"

                    if grep -qi "FAILED" <<< "${health}"; then
                        check_result \
                            "Storage & Filesystems" \
                            "SMART health ${dev}" \
                            8 \
                            "FAIL" \
                            "SMART reports a failing health state for ${dev}." \
                            "Back up data and replace the storage device." \
                            "LIVE"
                    else
                        check_result \
                            "Storage & Filesystems" \
                            "SMART health ${dev}" \
                            8 \
                            "PASS" \
                            "${health:-SMART health check completed for ${dev}}." \
                            "" \
                            "LIVE"
                    fi
                fi
            done <<< "${smart_devices}"

            if [[ "${smart_found}" == false ]]; then
                skip_check "Storage & Filesystems" "SMART health" "No SMART-capable non-SD storage device could be checked."
            fi
        else
            skip_check "Storage & Filesystems" "SMART health" "No suitable storage device detected."
        fi
    else
        skip_check "Storage & Filesystems" "SMART health" "smartctl is not installed."
    fi
}

# ============================================================
# SYSTEMD / SERVICES
# ============================================================

get_failed_services() {
    if have_cmd systemctl; then
        systemctl --failed --no-legend --plain 2>/dev/null || true
    fi
}

run_service_checks() {

    if ! have_cmd systemctl; then
        skip_check "Services & Boot" "System service manager" "systemctl unavailable."
        return
    fi

    local failed
    failed="$(get_failed_services)"

    if [[ -n "${failed}" ]]; then

        local count
        count="$(printf '%s\n' "${failed}" | grep -c '\.service' || true)"

        check_result \
            "Services & Boot" \
            "Currently failed services" \
            8 \
            "FAIL" \
            "${count} failed service unit(s) detected." \
            "Inspect failed services and use systemctl status/journalctl to determine the cause." \
            "LIVE"
    else
        check_result \
            "Services & Boot" \
            "Currently failed services" \
            8 \
            "PASS" \
            "No failed systemd services are currently reported." \
            "" \
            "LIVE"
    fi

    local activating
    activating="$(systemctl list-units --type=service --state=activating --no-legend 2>/dev/null || true)"

    if [[ -n "${activating}" ]]; then
        check_result \
            "Services & Boot" \
            "Services stuck activating" \
            4 \
            "WARN" \
            "One or more services remain in an activating state." \
            "Inspect services that take unusually long to start." \
            "LIVE"
    else
        check_result \
            "Services & Boot" \
            "Services stuck activating" \
            4 \
            "PASS" \
            "No services are currently stuck activating." \
            "" \
            "LIVE"
    fi

    local verify
    verify="$(systemd-analyze verify 2>&1 || true)"

    if grep -qiE "error|failed" <<< "${verify}"; then
        check_result \
            "Services & Boot" \
            "systemd configuration verification" \
            5 \
            "WARN" \
            "systemd-analyze verify reported configuration problems." \
            "Review the affected unit files." \
            "LIVE"
    else
        check_result \
            "Services & Boot" \
            "systemd configuration verification" \
            5 \
            "PASS" \
            "No systemd configuration errors were reported." \
            "" \
            "LIVE"
    fi

    local service_count
    service_count="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | wc -l || echo 0)"

    if [[ "${service_count}" -gt 0 ]]; then
        check_result \
            "Services & Boot" \
            "System service database" \
            2 \
            "PASS" \
            "${service_count} service unit definitions detected." \
            "" \
            "LIVE"
    else
        skip_check "Services & Boot" "System service database" "No service definitions were detected."
    fi

    # --------------------------------------------------------
    # Service restart / crash history
    # --------------------------------------------------------

    local service_list=""
    service_list="$(systemctl list-units --type=service --all --no-legend --plain 2>/dev/null |
        awk '{print $1}' | head -n 30 || true)"

    local repeated_services=0

    while read -r unit; do
        [[ -n "${unit}" ]] || continue

        local restarts
        restarts="$(systemctl show "${unit}" -p NRestarts --value 2>/dev/null || echo 0)"

        if [[ "${restarts}" =~ ^[0-9]+$ && "${restarts}" -ge 3 ]]; then
            repeated_services=$((repeated_services + 1))
        fi
    done <<< "${service_list}"

    if [[ "${repeated_services}" -gt 0 ]]; then
        add_issue \
            "HISTORICAL" \
            "Services & Boot" \
            "WARNING" \
            "Repeated service restarts detected" \
            "${repeated_services} service(s) report multiple recorded restarts." \
            "Review the affected services and their journal history." \
            3
    else
        check_result \
            "Services & Boot" \
            "Service restart history" \
            3 \
            "PASS" \
            "No repeated service restart pattern was detected in the sampled services." \
            "" \
            "HISTORICAL"
    fi

    if have_cmd journalctl; then

        local crash_events
        crash_events="$(journalctl --since "24 hours ago" --no-pager 2>/dev/null |
            grep -Ei \
            'Main process exited|Failed with result|Scheduled restart job|entered failed state' |
            wc -l || echo 0)"

        if [[ "${crash_events}" -ge 10 ]]; then
            add_issue \
                "HISTORICAL" \
                "Services & Boot" \
                "WARNING" \
                "Recent service crash activity" \
                "${crash_events} service crash/restart-related journal events were observed in the last 24 hours." \
                "Inspect service journals to identify recurring failures." \
                4

        elif [[ "${crash_events}" -gt 0 ]]; then
            add_issue \
                "HISTORICAL" \
                "Services & Boot" \
                "WARNING" \
                "Recent service restart activity" \
                "${crash_events} service failure/restart-related events were observed in the last 24 hours." \
                "Review the affected service logs if the events are unexpected." \
                2
        else
            check_result \
                "Services & Boot" \
                "Recent service reliability" \
                4 \
                "PASS" \
                "No service crash/restart pattern was detected in the last 24 hours." \
                "" \
                "HISTORICAL"
        fi
    else
        skip_check "Services & Boot" "Recent service reliability" "journalctl unavailable."
    fi
}

# ============================================================
# BOOT / RELIABILITY
# ============================================================

run_boot_checks() {

    if ! have_cmd systemd-analyze; then
        skip_check "Services & Boot" "Boot performance" "systemd-analyze unavailable."
    else

        local boot_time
        boot_time="$(systemd-analyze 2>/dev/null || true)"

        if [[ -n "${boot_time}" ]]; then
            check_result \
                "Services & Boot" \
                "Boot performance" \
                3 \
                "PASS" \
                "${boot_time}" \
                "" \
                "LIVE"
        else
            skip_check "Services & Boot" "Boot performance" "Unable to read boot timing."
        fi

        local blame
        blame="$(systemd-analyze blame 2>/dev/null | head -n 5 || true)"

        if [[ -n "${blame}" ]]; then
            check_result \
                "Services & Boot" \
                "Boot service analysis" \
                2 \
                "PASS" \
                "Boot service timing information is available." \
                "" \
                "LIVE"
        else
            skip_check "Services & Boot" "Boot service analysis" "No boot timing data available."
        fi
    fi

    if have_cmd journalctl; then

        local current_errors
        current_errors="$(journalctl -b -p err..alert --no-pager 2>/dev/null |
            tail -n 30 || true)"

        if [[ -n "${current_errors}" ]]; then
            local count
            count="$(printf '%s\n' "${current_errors}" | grep -c . || echo 0)"

            check_result \
                "Kernel & Reliability" \
                "Current boot errors" \
                6 \
                "WARN" \
                "${count} error-level journal entries were detected during the current boot." \
                "Review journalctl -b output and determine whether the errors are expected." \
                "LIVE"
        else
            check_result \
                "Kernel & Reliability" \
                "Current boot errors" \
                6 \
                "PASS" \
                "No error-level journal entries were detected during the current boot." \
                "" \
                "LIVE"
        fi

        local previous_errors
        previous_errors="$(journalctl -b -1 -p err..alert --no-pager 2>/dev/null |
            tail -n 30 || true)"

        if [[ -n "${previous_errors}" ]]; then
            add_issue \
                "HISTORICAL" \
                "Kernel & Reliability" \
                "WARNING" \
                "Previous boot errors" \
                "Error-level journal entries were detected during the previous boot." \
                "Review journalctl -b -1 to determine whether the problem was transient or recurring." \
                3
        else
            check_result \
                "Kernel & Reliability" \
                "Previous boot reliability" \
                3 \
                "PASS" \
                "No error-level entries were found for the previous boot." \
                "" \
                "HISTORICAL"
        fi

        local previous_kernel_errors
        previous_kernel_errors="$(journalctl -k -b -1 -p err..alert --no-pager 2>/dev/null |
            tail -n 20 || true)"

        if [[ -n "${previous_kernel_errors}" ]]; then
            add_issue \
                "HISTORICAL" \
                "Kernel & Reliability" \
                "WARNING" \
                "Previous boot kernel errors" \
                "Kernel error-level entries were found during the previous boot." \
                "Review the previous boot kernel journal for hardware or driver issues." \
                4
        else
            check_result \
                "Kernel & Reliability" \
                "Previous boot kernel reliability" \
                4 \
                "PASS" \
                "No previous-boot kernel error-level entries were detected." \
                "" \
                "HISTORICAL"
        fi
    else
        skip_check "Kernel & Reliability" "Current boot errors" "journalctl unavailable."
        skip_check "Kernel & Reliability" "Previous boot reliability" "journalctl unavailable."
        skip_check "Kernel & Reliability" "Previous boot kernel reliability" "journalctl unavailable."
    fi

    # Unexpected shutdown / reboot history

    if have_cmd last; then

        local reboot_count
        reboot_count="$(last -x 2>/dev/null |
            grep -E 'reboot|shutdown' |
            head -n 20 |
            wc -l || echo 0)"

        if [[ "${reboot_count}" -gt 0 ]]; then
            add_issue \
                "HISTORICAL" \
                "Kernel & Reliability" \
                "WARNING" \
                "Recent shutdown/reboot history" \
                "${reboot_count} recent reboot/shutdown records were found." \
                "Review the history if unexpected restarts have occurred." \
                2
        else
            check_result \
                "Kernel & Reliability" \
                "Shutdown history" \
                2 \
                "PASS" \
                "No unusual shutdown history was detected in the sampled records." \
                "" \
                "HISTORICAL"
        fi
    else
        skip_check "Kernel & Reliability" "Shutdown history" "last command unavailable."
    fi
}

# ============================================================
# KERNEL HEALTH
# ============================================================

run_kernel_checks() {

    if [[ -n "${KERNEL_VERSION}" ]]; then
        check_result \
            "Kernel & Reliability" \
            "Kernel version" \
            2 \
            "PASS" \
            "${KERNEL_VERSION}" \
            "" \
            "LIVE"
    fi

    local kernel_errors=""

    if have_cmd journalctl; then
        kernel_errors="$(journalctl -k -b --no-pager 2>/dev/null |
            grep -Ei \
            'kernel panic|BUG:|Oops:|Call Trace:|I/O error|segfault|oom-killer|Out of memory|EXT4-fs error|mmc.*error|usb.*error|hardware error|watchdog|thermal.*error' |
            tail -n 20 || true)"
    elif have_cmd dmesg; then
        kernel_errors="$(dmesg 2>/dev/null |
            grep -Ei \
            'kernel panic|BUG:|Oops:|Call Trace:|I/O error|segfault|oom-killer|Out of memory|EXT4-fs error|mmc.*error|usb.*error|hardware error|watchdog|thermal.*error' |
            tail -n 20 || true)"
    fi

    if [[ -n "${kernel_errors}" ]]; then
        check_result \
            "Kernel & Reliability" \
            "Kernel error indicators" \
            8 \
            "FAIL" \
            "Kernel logs contain serious hardware, memory, storage, crash or watchdog indicators." \
            "Inspect the kernel journal and identify the underlying hardware or software fault." \
            "LIVE"
    else
        check_result \
            "Kernel & Reliability" \
            "Kernel error indicators" \
            8 \
            "PASS" \
            "No major kernel error indicators were detected." \
            "" \
            "LIVE"
    fi

    if have_cmd journalctl; then

        local oom
        oom="$(journalctl -k -b --no-pager 2>/dev/null |
            grep -Ei 'oom-killer|Out of memory|Killed process' |
            tail -n 10 || true)"

        if [[ -n "${oom}" ]]; then
            add_issue \
                "HISTORICAL" \
                "Memory" \
                "WARNING" \
                "Kernel memory pressure event" \
                "The kernel recorded an OOM-related event." \
                "Identify the process consuming memory and increase available memory if necessary." \
                4
        else
            check_result \
                "Memory" \
                "Kernel OOM history" \
                4 \
                "PASS" \
                "No OOM-killer activity was detected in the current boot journal." \
                "" \
                "HISTORICAL"
        fi

        local segfaults
        segfaults="$(journalctl -b --no-pager 2>/dev/null |
            grep -Ei 'segfault|general protection fault' |
            tail -n 10 || true)"

        if [[ -n "${segfaults}" ]]; then
            add_issue \
                "HISTORICAL" \
                "Kernel & Reliability" \
                "WARNING" \
                "Application crash indicators" \
                "Segmentation fault or general protection fault entries were detected." \
                "Identify the affected application and investigate repeated crashes." \
                3
        else
            check_result \
                "Kernel & Reliability" \
                "Application crash history" \
                3 \
                "PASS" \
                "No recent segmentation-fault indicators were detected." \
                "" \
                "HISTORICAL"
        fi
    fi
}

# ============================================================
# NETWORK
# ============================================================

get_default_interface() {
    ip route 2>/dev/null |
        awk '/default/ {print $5; exit}' || true
}

get_default_gateway() {
    ip route 2>/dev/null |
        awk '/default/ {print $3; exit}' || true
}

run_network_checks() {

    if ! have_cmd ip; then
        skip_check "Network" "Network interface state" "ip command unavailable."
        return
    fi

    local interfaces
    interfaces="$(ip -br link 2>/dev/null | awk '$1!="lo" {print $1}' || true)"

    if [[ -n "${interfaces}" ]]; then
        check_result \
            "Network" \
            "Network interfaces" \
            3 \
            "PASS" \
            "Network interfaces detected successfully." \
            "" \
            "LIVE"
    else
        check_result \
            "Network" \
            "Network interfaces" \
            3 \
            "FAIL" \
            "No non-loopback network interfaces were detected." \
            "Check network hardware and kernel drivers." \
            "LIVE"
    fi

    local iface
    iface="$(get_default_interface)"

    if [[ -n "${iface}" ]]; then
        check_result \
            "Network" \
            "Default network interface" \
            3 \
            "PASS" \
            "Default interface is ${iface}." \
            "" \
            "LIVE"
    else
        check_result \
            "Network" \
            "Default network interface" \
            5 \
            "FAIL" \
            "No default network interface is configured." \
            "Check DHCP/static routing configuration." \
            "LIVE"
    fi

    local gateway
    gateway="$(get_default_gateway)"

    if [[ -n "${gateway}" ]]; then

        if have_cmd ping && ping -c 1 -W 2 "${gateway}" >/dev/null 2>&1; then
            check_result \
                "Network" \
                "Default gateway reachability" \
                5 \
                "PASS" \
                "Default gateway ${gateway} responded successfully." \
                "" \
                "LIVE"
        else
            check_result \
                "Network" \
                "Default gateway reachability" \
                6 \
                "FAIL" \
                "Default gateway ${gateway} did not respond." \
                "Check the local network connection and gateway." \
                "LIVE"
        fi
    else
        skip_check "Network" "Default gateway reachability" "No default gateway configured."
    fi

    if have_cmd ping; then

        if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
            check_result \
                "Network" \
                "Internet connectivity" \
                5 \
                "PASS" \
                "Internet connectivity test succeeded." \
                "" \
                "LIVE"
        else
            check_result \
                "Network" \
                "Internet connectivity" \
                7 \
                "FAIL" \
                "Internet connectivity test failed." \
                "Check routing, firewall and upstream connectivity." \
                "LIVE"
        fi

        local ping_result
        ping_result="$(ping -c 5 -W 2 1.1.1.1 2>/dev/null || true)"

        if grep -qE 'packet loss' <<< "${ping_result}"; then
            local loss
            loss="$(grep -oE '[0-9.]+% packet loss' <<< "${ping_result}" | head -n1 || true)"

            if [[ "${loss}" != "0% packet loss" ]]; then
                check_result \
                    "Network" \
                    "Internet packet loss" \
                    4 \
                    "WARN" \
                    "Packet loss was reported: ${loss}." \
                    "Check Wi-Fi signal, Ethernet cabling, switch/router health and upstream connectivity." \
                    "LIVE"
            else
                check_result \
                    "Network" \
                    "Internet packet loss" \
                    4 \
                    "PASS" \
                    "No packet loss was observed in the test." \
                    "" \
                    "LIVE"
            fi
        else
            skip_check "Network" "Internet packet loss" "Ping statistics unavailable."
        fi
    else
        skip_check "Network" "Internet connectivity" "ping unavailable."
        skip_check "Network" "Internet packet loss" "ping unavailable."
    fi

    # Interface error/drop statistics

    local error_total=0

    for iface_path in /sys/class/net/*; do

        [[ -d "${iface_path}" ]] || continue

        local n
        n="$(basename "${iface_path}")"

        [[ "${n}" == "lo" ]] && continue

        local rxerr txerr rxd txd

        rxerr="$(cat "${iface_path}/statistics/rx_errors" 2>/dev/null || echo 0)"
        txerr="$(cat "${iface_path}/statistics/tx_errors" 2>/dev/null || echo 0)"
        rxd="$(cat "${iface_path}/statistics/rx_dropped" 2>/dev/null || echo 0)"
        txd="$(cat "${iface_path}/statistics/tx_dropped" 2>/dev/null || echo 0)"

        error_total=$((error_total + rxerr + txerr + rxd + txd))
    done

    if [[ "${error_total}" -gt 100 ]]; then
        check_result \
            "Network" \
            "Network interface errors" \
            5 \
            "WARN" \
            "${error_total} cumulative interface errors/drops were reported." \
            "Check the affected interface and network hardware." \
            "LIVE"
    else
        check_result \
            "Network" \
            "Network interface errors" \
            5 \
            "PASS" \
            "No significant cumulative interface error/drop count was detected." \
            "" \
            "LIVE"
    fi

    if have_cmd ethtool && [[ -n "${iface}" ]]; then
        local speed
        speed="$(ethtool "${iface}" 2>/dev/null | grep -E '^Speed:' | head -n1 || true)"

        if [[ -n "${speed}" ]]; then
            check_result \
                "Network" \
                "Network link information" \
                2 \
                "PASS" \
                "${speed}" \
                "" \
                "LIVE"
        else
            skip_check "Network" "Network link information" "Link speed unavailable."
        fi
    else
        skip_check "Network" "Network link information" "ethtool unavailable."
    fi
}

# ============================================================
# DNS / PI-HOLE / UNBOUND
# ============================================================

run_dns_checks() {

    if [[ -r /etc/resolv.conf ]]; then

        local nameservers
        nameservers="$(grep -E '^nameserver ' /etc/resolv.conf | awk '{print $2}' | paste -sd ', ' - || true)"

        if [[ -n "${nameservers}" ]]; then
            check_result \
                "DNS & Network Services" \
                "DNS resolver configuration" \
                3 \
                "PASS" \
                "Configured DNS servers: ${nameservers}" \
                "" \
                "LIVE"
        else
            check_result \
                "DNS & Network Services" \
                "DNS resolver configuration" \
                4 \
                "WARN" \
                "No nameserver entries were found in /etc/resolv.conf." \
                "Check system DNS configuration." \
                "LIVE"
        fi
    else
        skip_check "DNS & Network Services" "DNS resolver configuration" "/etc/resolv.conf unavailable."
    fi

    if have_cmd dig; then

        if dig +time=2 +tries=1 example.com @127.0.0.1 >/dev/null 2>&1; then
            check_result \
                "DNS & Network Services" \
                "Local DNS resolver" \
                5 \
                "PASS" \
                "DNS resolution through 127.0.0.1 succeeded." \
                "" \
                "LIVE"
        else
            check_result \
                "DNS & Network Services" \
                "Local DNS resolver" \
                5 \
                "WARN" \
                "DNS resolution through 127.0.0.1 failed." \
                "Check the local DNS service and resolver configuration." \
                "LIVE"
        fi
    else
        skip_check "DNS & Network Services" "Local DNS resolver" "dig is not installed."
    fi

    # Pi-hole

    if systemctl list-unit-files 2>/dev/null |
       grep -q '^pihole-FTL.service'; then

        if systemctl is-active --quiet pihole-FTL.service; then
            check_result \
                "DNS & Network Services" \
                "Pi-hole service" \
                6 \
                "PASS" \
                "Pi-hole FTL is active." \
                "" \
                "LIVE"

            if have_cmd dig; then
                if dig +time=2 +tries=1 example.com @127.0.0.1 >/dev/null 2>&1; then
                    check_result \
                        "DNS & Network Services" \
                        "Pi-hole DNS resolution" \
                        5 \
                        "PASS" \
                        "DNS resolution through the local Pi-hole endpoint succeeded." \
                        "" \
                        "LIVE"
                else
                    check_result \
                        "DNS & Network Services" \
                        "Pi-hole DNS resolution" \
                        5 \
                        "FAIL" \
                        "Pi-hole appears active but local DNS queries failed." \
                        "Check Pi-hole FTL, DNS configuration and port 53." \
                        "LIVE"
                fi
            fi
        else
            check_result \
                "DNS & Network Services" \
                "Pi-hole service" \
                6 \
                "FAIL" \
                "Pi-hole FTL is installed but not active." \
                "Inspect pihole-FTL.service and its journal." \
                "LIVE"
        fi
    else
        skip_check "DNS & Network Services" "Pi-hole service" "Pi-hole FTL is not installed."
    fi

    # Unbound

    local unbound_detected=false

    if systemctl list-unit-files 2>/dev/null |
       grep -q '^unbound.service'; then
        unbound_detected=true
    elif [[ -d /etc/unbound ]]; then
        unbound_detected=true
    fi

    if [[ "${unbound_detected}" == true ]]; then

        if have_cmd systemctl && systemctl is-active --quiet unbound.service; then
            check_result \
                "DNS & Network Services" \
                "Unbound service" \
                6 \
                "PASS" \
                "Unbound is active." \
                "" \
                "LIVE"
        else
            check_result \
                "DNS & Network Services" \
                "Unbound service" \
                6 \
                "FAIL" \
                "Unbound is detected but is not active." \
                "Inspect the Unbound service and configuration." \
                "LIVE"
        fi

        if have_cmd dig; then

            if dig +time=2 +tries=1 example.com @127.0.0.1 -p 5335 >/dev/null 2>&1; then
                check_result \
                    "DNS & Network Services" \
                    "Unbound recursive DNS" \
                    5 \
                    "PASS" \
                    "Unbound responded successfully on port 5335." \
                    "" \
                    "LIVE"
            else
                check_result \
                    "DNS & Network Services" \
                    "Unbound recursive DNS" \
                    5 \
                    "WARN" \
                    "Unbound did not respond on 127.0.0.1:5335." \
                    "Verify the configured Unbound listening port." \
                    "LIVE"
            fi
        fi
    else
        skip_check "DNS & Network Services" "Unbound service" "Unbound is not detected."
    fi
}

# ============================================================
# WIREGUARD / VPN
# ============================================================

run_wireguard_checks() {

    local wg_found=false

    if have_cmd wg; then
        if wg show >/dev/null 2>&1; then
            wg_found=true
        fi
    elif [[ -d /sys/class/net && -n "$(ls /sys/class/net 2>/dev/null | grep '^wg' || true)" ]]; then
        wg_found=true
    fi

    if [[ "${wg_found}" == false ]]; then
        skip_check "Network" "WireGuard" "WireGuard is not detected."
        return
    fi

    if have_cmd wg; then

        local interfaces
        interfaces="$(wg show interfaces 2>/dev/null || true)"

        if [[ -n "${interfaces}" ]]; then
            check_result \
                "Network" \
                "WireGuard interface" \
                5 \
                "PASS" \
                "WireGuard interface(s): ${interfaces}" \
                "" \
                "LIVE"

            local recent=false
            local peer_lines

            peer_lines="$(wg show all latest-handshakes 2>/dev/null || true)"

            while read -r iface pubkey handshake; do
                [[ -n "${iface}" ]] || continue

                if [[ "${handshake}" =~ ^[0-9]+$ && "${handshake}" -gt 0 ]]; then

                    local now
                    now="$(date +%s)"

                    local age=$((now - handshake))

                    if [[ "${age}" -le 300 ]]; then
                        recent=true
                    fi
                fi
            done <<< "${peer_lines}"

            if [[ "${recent}" == true ]]; then
                check_result \
                    "Network" \
                    "WireGuard peer activity" \
                    4 \
                    "PASS" \
                    "At least one recent WireGuard peer handshake was detected." \
                    "" \
                    "LIVE"
            else
                check_result \
                    "Network" \
                    "WireGuard peer activity" \
                    4 \
                    "WARN" \
                    "No recent WireGuard peer handshake was detected." \
                    "Verify that expected peers are connected and traffic is flowing." \
                    "LIVE"
            fi
        else
            check_result \
                "Network" \
                "WireGuard interface" \
                5 \
                "WARN" \
                "WireGuard is installed but no active interface was found." \
                "Check WireGuard configuration and service state." \
                "LIVE"
        fi
    else
        skip_check "Network" "WireGuard peer activity" "wg command unavailable."
    fi
}

# ============================================================
# NETWORK EXPOSURE
# ============================================================

run_exposure_checks() {

    if ! have_cmd ss; then
        skip_check "Security" "Listening service exposure" "ss is unavailable."
        return
    fi

    local listeners
    listeners="$(ss -lntup 2>/dev/null || true)"

    if [[ -z "${listeners}" ]]; then
        check_result \
            "Security" \
            "Listening service exposure" \
            4 \
            "PASS" \
            "No listening sockets were returned by ss." \
            "" \
            "LIVE"
        return
    fi

    local broad
    broad="$(printf '%s\n' "${listeners}" |
        grep -E '0\.0\.0\.0:|\[::\]:' |
        tail -n +2 || true)"

    local broad_count
    broad_count="$(printf '%s\n' "${broad}" | grep -c . || echo 0)"

    if [[ "${broad_count}" -ge 8 ]]; then
        check_result \
            "Security" \
            "Network service exposure" \
            6 \
            "WARN" \
            "${broad_count} listening sockets are bound broadly to IPv4/IPv6 interfaces." \
            "Review listening services and restrict unnecessary services to trusted interfaces." \
            "LIVE"

    elif [[ "${broad_count}" -gt 0 ]]; then
        check_result \
            "Security" \
            "Network service exposure" \
            6 \
            "PASS" \
            "${broad_count} listening sockets are exposed on broad interfaces. Review them if not expected." \
            "" \
            "LIVE"
    else
        check_result \
            "Security" \
            "Network service exposure" \
            6 \
            "PASS" \
            "No broadly bound listening sockets were detected." \
            "" \
            "LIVE"
    fi

    printf '%s\n' "${listeners}" > "${TMP_ROOT}/listeners"
}

# ============================================================
# SSH SECURITY
# ============================================================

run_ssh_checks() {

    local ssh_detected=false

    if have_cmd sshd; then
        ssh_detected=true
    elif [[ -f /etc/ssh/sshd_config ]]; then
        ssh_detected=true
    fi

    if [[ "${ssh_detected}" == false ]]; then
        skip_check "Security" "SSH configuration" "OpenSSH server is not detected."
        return
    fi

    if have_cmd systemctl &&
       systemctl list-unit-files 2>/dev/null | grep -q '^ssh.service'; then

        if systemctl is-active --quiet ssh.service; then
            check_result \
                "Security" \
                "SSH service state" \
                4 \
                "PASS" \
                "SSH service is active." \
                "" \
                "LIVE"
        else
            skip_check "Security" "SSH service state" "SSH server is installed but inactive."
        fi
    fi

    local ssh_config=""

    if have_cmd sshd; then
        ssh_config="$(sshd -T 2>/dev/null || true)"
    fi

    if [[ -n "${ssh_config}" ]]; then

        local permit_root
        permit_root="$(awk '$1=="permitrootlogin" {print $2; exit}' <<< "${ssh_config}" || true)"

        case "${permit_root}" in
            yes)
                check_result \
                    "Security" \
                    "SSH root login" \
                    6 \
                    "FAIL" \
                    "SSH permits direct root login." \
                    "Set PermitRootLogin to no or prohibit-password where appropriate." \
                    "LIVE"
                ;;
            *)
                check_result \
                    "Security" \
                    "SSH root login" \
                    6 \
                    "PASS" \
                    "Direct SSH root login is restricted." \
                    "" \
                    "LIVE"
                ;;
        esac

        local password_auth
        password_auth="$(awk '$1=="passwordauthentication" {print $2; exit}' <<< "${ssh_config}" || true)"

        if [[ "${password_auth}" == "yes" ]]; then
            check_result \
                "Security" \
                "SSH password authentication" \
                4 \
                "WARN" \
                "SSH password authentication is enabled." \
                "Prefer key-based authentication where practical." \
                "LIVE"
        else
            check_result \
                "Security" \
                "SSH password authentication" \
                4 \
                "PASS" \
                "SSH password authentication is disabled." \
                "" \
                "LIVE"
        fi

        local empty_passwords
        empty_passwords="$(awk '$1=="permitemptypasswords" {print $2; exit}' <<< "${ssh_config}" || true)"

        if [[ "${empty_passwords}" == "yes" ]]; then
            check_result \
                "Security" \
                "SSH empty passwords" \
                5 \
                "FAIL" \
                "SSH permits empty passwords." \
                "Disable PermitEmptyPasswords." \
                "LIVE"
        else
            check_result \
                "Security" \
                "SSH empty passwords" \
                5 \
                "PASS" \
                "Empty SSH passwords are not permitted." \
                "" \
                "LIVE"
        fi

        local ssh_port
        ssh_port="$(awk '$1=="port" {print $2; exit}' <<< "${ssh_config}" || true)"

        if [[ -n "${ssh_port}" ]]; then
            check_result \
                "Security" \
                "SSH listening port" \
                1 \
                "PASS" \
                "SSH is configured for port ${ssh_port}." \
                "" \
                "LIVE"
        fi
    else
        skip_check "Security" "SSH configuration" "sshd -T did not return usable configuration."
    fi

    if [[ -f "${HOME}/.ssh/authorized_keys" ]]; then

        local key_mode
        key_mode="$(stat -c '%a' "${HOME}/.ssh/authorized_keys" 2>/dev/null || echo unknown)"

        if [[ "${key_mode}" =~ ^[0-9]+$ && "${key_mode}" -le 644 ]]; then
            check_result \
                "Security" \
                "SSH authorized key permissions" \
                3 \
                "PASS" \
                "authorized_keys permissions are ${key_mode}." \
                "" \
                "LIVE"
        else
            check_result \
                "Security" \
                "SSH authorized key permissions" \
                3 \
                "WARN" \
                "authorized_keys permissions appear to be ${key_mode}." \
                "Restrict authorized_keys permissions." \
                "LIVE"
        fi
    else
        skip_check "Security" "SSH authorized key permissions" "No user authorized_keys file detected."
    fi
}

# ============================================================
# FIREWALL
# ============================================================

run_firewall_checks() {

    local firewall_found=false
    local firewall_active=false

    if have_cmd ufw; then
        firewall_found=true

        if ufw status 2>/dev/null | grep -qi "Status: active"; then
            firewall_active=true
        fi
    fi

    if have_cmd nft; then
        firewall_found=true

        if nft list ruleset 2>/dev/null | grep -qE 'table (inet|ip|ip6)'; then
            firewall_active=true
        fi
    fi

    if have_cmd iptables; then
        firewall_found=true

        if iptables -S 2>/dev/null | grep -qE '^-A '; then
            firewall_active=true
        fi
    fi

    if [[ "${firewall_active}" == true ]]; then
        check_result \
            "Security" \
            "Firewall state" \
            6 \
            "PASS" \
            "An active firewall rule set was detected." \
            "" \
            "LIVE"
    elif [[ "${firewall_found}" == true ]]; then
        check_result \
            "Security" \
            "Firewall state" \
            6 \
            "WARN" \
            "Firewall tooling is installed but no clearly active ruleset was detected." \
            "Review firewall configuration, especially if services are exposed." \
            "LIVE"
    else
        check_result \
            "Security" \
            "Firewall state" \
            6 \
            "WARN" \
            "No active firewall was detected." \
            "Consider a firewall if the Pi exposes services beyond trusted networks." \
            "LIVE"
    fi
}

# ============================================================
# FAIL2BAN / AUTH LOGS
# ============================================================

run_auth_checks() {

    if have_cmd systemctl &&
       systemctl list-unit-files 2>/dev/null | grep -q '^fail2ban.service'; then

        if systemctl is-active --quiet fail2ban.service; then
            check_result \
                "Security" \
                "Fail2ban service" \
                4 \
                "PASS" \
                "Fail2ban is active." \
                "" \
                "LIVE"
        else
            check_result \
                "Security" \
                "Fail2ban service" \
                4 \
                "WARN" \
                "Fail2ban is installed but inactive." \
                "Start and configure Fail2ban if it is intended to protect exposed services." \
                "LIVE"
        fi
    else
        skip_check "Security" "Fail2ban service" "Fail2ban is not installed."
    fi

    local auth_failures=""

    if have_cmd journalctl; then
        auth_failures="$(journalctl --since "24 hours ago" --no-pager 2>/dev/null |
            grep -Ei 'Failed password|authentication failure|Invalid user' |
            tail -n 20 || true)"
    elif [[ -f /var/log/auth.log ]]; then
        auth_failures="$(tail -n 5000 /var/log/auth.log 2>/dev/null |
            grep -Ei 'Failed password|authentication failure|Invalid user' |
            tail -n 20 || true)"
    fi

    if [[ -n "${auth_failures}" ]]; then
        local count
        count="$(printf '%s\n' "${auth_failures}" | grep -c . || echo 0)"

        add_issue \
            "HISTORICAL" \
            "Security" \
            "WARNING" \
            "Recent authentication failures" \
            "${count} authentication failure indicators were observed in recent logs." \
            "Review source addresses and ensure SSH is appropriately restricted." \
            3
    else
        check_result \
            "Security" \
            "Authentication failure history" \
            3 \
            "PASS" \
            "No recent authentication failure pattern was detected." \
            "" \
            "HISTORICAL"
    fi
}

# ============================================================
# PACKAGE / UPDATE HEALTH
# ============================================================

run_update_checks() {

    if ! have_cmd dpkg; then
        skip_check "Software & Updates" "Package database" "dpkg unavailable."
        return
    fi

    local audit
    audit="$(dpkg --audit 2>/dev/null || true)"

    if [[ -n "${audit}" ]]; then
        check_result \
            "Software & Updates" \
            "Package consistency" \
            5 \
            "WARN" \
            "dpkg reports packages requiring attention." \
            "Review dpkg --audit and complete any interrupted package operations." \
            "LIVE"
    else
        check_result \
            "Software & Updates" \
            "Package consistency" \
            5 \
            "PASS" \
            "dpkg reports no incomplete package state." \
            "" \
            "LIVE"
    fi

    if have_cmd apt; then

        local updates
        updates="$(apt list --upgradable 2>/dev/null |
            tail -n +2 |
            grep -v '^Listing' || true)"

        local update_count
        update_count="$(printf '%s\n' "${updates}" | grep -c . || echo 0)"

        if [[ "${update_count}" -ge 20 ]]; then
            check_result \
                "Software & Updates" \
                "Available software updates" \
                4 \
                "WARN" \
                "${update_count} package updates are available." \
                "Review and install updates during an appropriate maintenance window." \
                "LIVE"
        elif [[ "${update_count}" -gt 0 ]]; then
            check_result \
                "Software & Updates" \
                "Available software updates" \
                2 \
                "WARN" \
                "${update_count} package updates are available." \
                "Install updates when convenient." \
                "LIVE"
        else
            check_result \
                "Software & Updates" \
                "Available software updates" \
                2 \
                "PASS" \
                "No package updates are currently reported." \
                "" \
                "LIVE"
        fi
    else
        skip_check "Software & Updates" "Available software updates" "apt unavailable."
    fi

    if [[ -f /var/run/reboot-required ]]; then
        check_result \
            "Software & Updates" \
            "Reboot requirement" \
            4 \
            "WARN" \
            "The system reports that a reboot is required." \
            "Schedule a reboot during a suitable maintenance window." \
            "LIVE"
    else
        check_result \
            "Software & Updates" \
            "Reboot requirement" \
            4 \
            "PASS" \
            "No reboot-required marker is present." \
            "" \
            "LIVE"
    fi

    if have_cmd unattended-upgrade || have_cmd unattended-upgrades; then
        check_result \
            "Software & Updates" \
            "Automatic update tooling" \
            2 \
            "PASS" \
            "Automatic update tooling is installed." \
            "" \
            "LIVE"
    else
        skip_check "Software & Updates" "Automatic update tooling" "Unattended upgrades are not installed."
    fi
}

# ============================================================
# TIME / CLOCK
# ============================================================

run_time_checks() {

    if have_cmd timedatectl; then

        local sync
        sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"

        if [[ "${sync}" == "yes" ]]; then
            check_result \
                "System Reliability" \
                "Network time synchronisation" \
                4 \
                "PASS" \
                "System time is synchronised." \
                "" \
                "LIVE"
        elif [[ "${sync}" == "no" ]]; then
            check_result \
                "System Reliability" \
                "Network time synchronisation" \
                4 \
                "WARN" \
                "System time is not currently synchronised." \
                "Check the configured NTP/time synchronisation service." \
                "LIVE"
        else
            skip_check "System Reliability" "Network time synchronisation" "NTP state unavailable."
        fi

        local timezone
        timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"

        if [[ -n "${timezone}" ]]; then
            check_result \
                "System Reliability" \
                "Timezone configuration" \
                1 \
                "PASS" \
                "Timezone is ${timezone}." \
                "" \
                "LIVE"
        fi
    else
        skip_check "System Reliability" "Network time synchronisation" "timedatectl unavailable."
    fi
}

# ============================================================
# PROCESS / RELIABILITY
# ============================================================

run_process_checks() {

    local process_count
    process_count="$(ps -e --no-headers 2>/dev/null | wc -l || echo 0)"

    if [[ "${process_count}" -gt 0 ]]; then
        check_result \
            "System Reliability" \
            "Process table" \
            2 \
            "PASS" \
            "${process_count} processes are currently running." \
            "" \
            "LIVE"
    fi

    local zombies
    zombies="$(ps -eo stat= 2>/dev/null | grep -c 'Z' || echo 0)"

    if [[ "${zombies}" -ge 5 ]]; then
        check_result \
            "System Reliability" \
            "Zombie processes" \
            4 \
            "WARN" \
            "${zombies} zombie processes were detected." \
            "Identify the parent processes and investigate applications failing to reap children." \
            "LIVE"
    else
        check_result \
            "System Reliability" \
            "Zombie processes" \
            4 \
            "PASS" \
            "${zombies} zombie process(es) detected." \
            "" \
            "LIVE"
    fi

    if have_cmd coredumpctl; then

        local dumps
        dumps="$(coredumpctl list --no-legend 2>/dev/null | wc -l || echo 0)"

        if [[ "${dumps}" -gt 0 ]]; then
            add_issue \
                "HISTORICAL" \
                "System Reliability" \
                "WARNING" \
                "Application core dumps" \
                "${dumps} core dump record(s) were detected." \
                "Identify applications producing repeated core dumps." \
                3
        else
            check_result \
                "System Reliability" \
                "Application core dump history" \
                3 \
                "PASS" \
                "No core dump records were detected." \
                "" \
                "HISTORICAL"
        fi
    else
        skip_check "System Reliability" "Application core dump history" "coredumpctl unavailable."
    fi
}

# ============================================================
# RASPBERRY PI HARDWARE
# ============================================================

run_pi_hardware_checks() {

    if [[ -n "${PI_MODEL}" ]]; then
        check_result \
            "Raspberry Pi Hardware" \
            "Hardware model detection" \
            2 \
            "PASS" \
            "${PI_MODEL}" \
            "" \
            "LIVE"
    else
        skip_check "Raspberry Pi Hardware" "Hardware model detection" "Raspberry Pi model could not be identified."
    fi

    if have_cmd vcgencmd; then

        local firmware
        firmware="$(vcgencmd version 2>/dev/null || true)"

        if [[ -n "${firmware}" ]]; then
            check_result \
                "Raspberry Pi Hardware" \
                "Firmware information" \
                2 \
                "PASS" \
                "$(first_line "${firmware}")" \
                "" \
                "LIVE"
        else
            skip_check "Raspberry Pi Hardware" "Firmware information" "Firmware version unavailable."
        fi

        local gpu_mem
        gpu_mem="$(vcgencmd get_mem gpu 2>/dev/null || true)"

        if [[ -n "${gpu_mem}" ]]; then
            check_result \
                "Raspberry Pi Hardware" \
                "GPU memory configuration" \
                1 \
                "PASS" \
                "${gpu_mem}" \
                "" \
                "LIVE"
        else
            skip_check "Raspberry Pi Hardware" "GPU memory configuration" "GPU memory information unavailable."
        fi

        if vcgencmd bootloader_version >/dev/null 2>&1; then
            local bootloader
            bootloader="$(vcgencmd bootloader_version 2>/dev/null || true)"

            check_result \
                "Raspberry Pi Hardware" \
                "Bootloader information" \
                1 \
                "PASS" \
                "$(first_line "${bootloader}")" \
                "" \
                "LIVE"
        else
            skip_check "Raspberry Pi Hardware" "Bootloader information" "Bootloader information is unavailable on this Pi."
        fi
    else
        skip_check "Raspberry Pi Hardware" "Firmware information" "vcgencmd unavailable."
        skip_check "Raspberry Pi Hardware" "GPU memory configuration" "vcgencmd unavailable."
        skip_check "Raspberry Pi Hardware" "Bootloader information" "vcgencmd unavailable."
    fi

    if [[ -r /proc/cmdline ]]; then
        local boot_params
        boot_params="$(cat /proc/cmdline 2>/dev/null || true)"

        if [[ -n "${boot_params}" ]]; then
            check_result \
                "Raspberry Pi Hardware" \
                "Boot configuration" \
                1 \
                "PASS" \
                "Kernel boot configuration is readable." \
                "" \
                "LIVE"
        fi
    fi

    local wifi=false
    local bluetooth=false
    local ethernet=false

    [[ -d /sys/class/net/wlan0 ]] && wifi=true
    [[ -d /sys/class/bluetooth ]] && bluetooth=true
    [[ -d /sys/class/net/eth0 ]] && ethernet=true

    if [[ "${wifi}" == true ]]; then
        check_result \
            "Raspberry Pi Hardware" \
            "Wireless interface detection" \
            1 \
            "PASS" \
            "Wi-Fi interface detected." \
            "" \
            "LIVE"
    else
        skip_check "Raspberry Pi Hardware" "Wireless interface detection" "No wlan0 interface detected."
    fi

    if [[ "${ethernet}" == true ]]; then
        check_result \
            "Raspberry Pi Hardware" \
            "Ethernet interface detection" \
            1 \
            "PASS" \
            "Ethernet interface detected." \
            "" \
            "LIVE"
    else
        skip_check "Raspberry Pi Hardware" "Ethernet interface detection" "No eth0 interface detected."
    fi

    if [[ "${bluetooth}" == true ]]; then
        check_result \
            "Raspberry Pi Hardware" \
            "Bluetooth interface detection" \
            1 \
            "PASS" \
            "Bluetooth subsystem detected." \
            "" \
            "LIVE"
    else
        skip_check "Raspberry Pi Hardware" "Bluetooth interface detection" "Bluetooth subsystem unavailable."
    fi
}

# ============================================================
# APPLICATION DETECTION
# ============================================================

check_application() {

    local name="$1"
    local service="$2"
    local category="$3"

    if have_cmd systemctl &&
       systemctl list-unit-files 2>/dev/null | grep -q "^${service}"; then

        if systemctl is-active --quiet "${service}"; then
            check_result \
                "Applications" \
                "${name} service" \
                4 \
                "PASS" \
                "${name} is active." \
                "" \
                "LIVE"
        else
            check_result \
                "Applications" \
                "${name} service" \
                4 \
                "FAIL" \
                "${name} is installed but not active." \
                "Inspect the ${service} service and its logs." \
                "LIVE"
        fi
    else
        skip_check "Applications" "${name} service" "${name} is not installed."
    fi
}

run_application_checks() {

    check_application "Caddy" "caddy.service" "Web"
    check_application "Docker" "docker.service" "Containers"
    check_application "Tailscale" "tailscaled.service" "VPN"
    check_application "Mosquitto" "mosquitto.service" "MQTT"
    check_application "Pi-hole" "pihole-FTL.service" "DNS"
}

# ============================================================
# APPLICATION / CONFIGURATION HEALTH
# ============================================================

run_configuration_checks() {

    if [[ -r /etc/hostname ]]; then
        local host
        host="$(cat /etc/hostname 2>/dev/null | head -n1)"

        if [[ -n "${host}" ]]; then
            check_result \
                "Configuration" \
                "Hostname configuration" \
                1 \
                "PASS" \
                "Hostname is ${host}." \
                "" \
                "LIVE"
        else
            check_result \
                "Configuration" \
                "Hostname configuration" \
                2 \
                "WARN" \
                "Hostname is empty." \
                "Set a useful system hostname." \
                "LIVE"
        fi
    fi

    if [[ -r /etc/fstab ]]; then
        check_result \
            "Configuration" \
            "fstab availability" \
            1 \
            "PASS" \
            "/etc/fstab is present." \
            "" \
            "LIVE"
    else
        check_result \
            "Configuration" \
            "fstab availability" \
            3 \
            "WARN" \
            "/etc/fstab is missing." \
            "Verify the system storage configuration." \
            "LIVE"
    fi

    if [[ -L /etc/resolv.conf ]]; then
        local target
        target="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"

        check_result \
            "Configuration" \
            "Resolver configuration ownership" \
            1 \
            "PASS" \
            "/etc/resolv.conf is linked to ${target:-a managed resolver file}." \
            "" \
            "LIVE"
    else
        check_result \
            "Configuration" \
            "Resolver configuration ownership" \
            1 \
            "WARN" \
            "/etc/resolv.conf is not a symbolic link." \
            "Verify that DNS configuration is intentionally managed this way." \
            "LIVE"
    fi
}

# ============================================================
# HISTORICAL SCORE ENGINE
# ============================================================

ensure_history_file() {

    if [[ ! -f "${HISTORY_FILE}" ]]; then
        printf 'timestamp,epoch,live,historical,confidence,warnings,critical\n' > "${HISTORY_FILE}"
    fi
}

count_current_issues() {
    grep -c . "${CURRENT_ISSUE_FILE}" 2>/dev/null || echo 0
}

count_historical_issues() {
    grep -c . "${HISTORICAL_ISSUE_FILE}" 2>/dev/null || echo 0
}

calculate_live_score() {

    if [[ "${LIVE_POSSIBLE}" -gt 0 ]]; then
        LIVE_SCORE=$((LIVE_EARNED * 100 / LIVE_POSSIBLE))
    else
        LIVE_SCORE=0
    fi

    if [[ "${LIVE_SCORE}" -gt 100 ]]; then
        LIVE_SCORE=100
    fi
}

calculate_historical_score() {

    ensure_history_file

    local now
    now="$(date +%s)"

    local weighted_sum=0
    local weight_total=0

    while IFS=',' read -r timestamp epoch live historical confidence warnings critical; do

        [[ "${epoch}" =~ ^[0-9]+$ ]] || continue
        [[ "${historical}" =~ ^[0-9]+$ ]] || continue

        local age=$((now - epoch))

        # Ignore records older than 30 days for the rolling historical score.
        [[ "${age}" -le 2592000 ]] || continue

        # Recent scans have more influence.
        local weight=1

        if [[ "${age}" -le 86400 ]]; then
            weight=5
        elif [[ "${age}" -le 259200 ]]; then
            weight=4
        elif [[ "${age}" -le 604800 ]]; then
            weight=3
        elif [[ "${age}" -le 1296000 ]]; then
            weight=2
        else
            weight=1
        fi

        weighted_sum=$((weighted_sum + historical * weight))
        weight_total=$((weight_total + weight))

    done < "${HISTORY_FILE}"

    if [[ "${weight_total}" -gt 0 ]]; then
        HISTORICAL_SCORE=$((weighted_sum / weight_total))
    else
        # If there is no history yet, historical health follows live health.
        HISTORICAL_SCORE="${LIVE_SCORE}"
    fi

    if [[ "${HISTORICAL_SCORE}" -gt 100 ]]; then
        HISTORICAL_SCORE=100
    fi
}

calculate_average() {

    ensure_history_file

    local now
    now="$(date +%s)"

    local total=0
    local count=0

    while IFS=',' read -r timestamp epoch live historical confidence warnings critical; do

        [[ "${epoch}" =~ ^[0-9]+$ ]] || continue
        [[ "${live}" =~ ^[0-9]+$ ]] || continue

        local age=$((now - epoch))

        [[ "${age}" -le 2592000 ]] || continue

        total=$((total + live))
        count=$((count + 1))

    done < "${HISTORY_FILE}"

    # Include current scan in the displayed average.
    total=$((total + LIVE_SCORE))
    count=$((count + 1))

    if [[ "${count}" -gt 0 ]]; then
        AVERAGE_SCORE=$((total / count))
    else
        AVERAGE_SCORE="${LIVE_SCORE}"
    fi
}

calculate_best_worst() {

    ensure_history_file

    BEST_SCORE="${LIVE_SCORE}"
    WORST_SCORE="${LIVE_SCORE}"

    while IFS=',' read -r timestamp epoch live historical confidence warnings critical; do

        [[ "${live}" =~ ^[0-9]+$ ]] || continue

        if [[ "${live}" -gt "${BEST_SCORE}" ]]; then
            BEST_SCORE="${live}"
        fi

        if [[ "${live}" -lt "${WORST_SCORE}" ]]; then
            WORST_SCORE="${live}"
        fi

    done < "${HISTORY_FILE}"
}

calculate_trend() {

    ensure_history_file

    local now
    now="$(date +%s)"

    local recent_total=0
    local recent_count=0

    local old_total=0
    local old_count=0

    while IFS=',' read -r timestamp epoch live historical confidence warnings critical; do

        [[ "${epoch}" =~ ^[0-9]+$ ]] || continue
        [[ "${live}" =~ ^[0-9]+$ ]] || continue

        local age=$((now - epoch))

        if [[ "${age}" -le 604800 ]]; then
            recent_total=$((recent_total + live))
            recent_count=$((recent_count + 1))

        elif [[ "${age}" -le 1209600 ]]; then
            old_total=$((old_total + live))
            old_count=$((old_count + 1))
        fi

    done < "${HISTORY_FILE}"

    if [[ "${recent_count}" -gt 0 && "${old_count}" -gt 0 ]]; then

        local recent_avg=$((recent_total / recent_count))
        local old_avg=$((old_total / old_count))

        TREND_VALUE=$((recent_avg - old_avg))

    elif [[ "${recent_count}" -gt 0 ]]; then
        TREND_VALUE=0
    else
        TREND_VALUE=0
    fi
}

save_history() {

    ensure_history_file

    local warnings
    local critical

    warnings="$(grep -c $'\tWARNING\t' "${ISSUE_FILE}" 2>/dev/null || true)"
    critical="$(grep -c $'\tCRITICAL\t' "${ISSUE_FILE}" 2>/dev/null || true)"

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "${SCAN_TIMESTAMP}" \
        "${SCAN_EPOCH}" \
        "${LIVE_SCORE}" \
        "${HISTORICAL_SCORE}" \
        "${CONFIDENCE}" \
        "${warnings}" \
        "${critical}" >> "${HISTORY_FILE}"

    printf '%s|LIVE|%s|%s\n' \
        "${SCAN_TIMESTAMP}" \
        "${LIVE_SCORE}" \
        "${HOSTNAME_VALUE}" > "${LATEST_FILE}"
}

# ============================================================
# CONFIDENCE
# ============================================================

calculate_confidence() {

    local total=$((APPLICABLE_COUNT + SKIPPED_COUNT))

    if [[ "${total}" -gt 0 ]]; then
        CONFIDENCE=$((APPLICABLE_COUNT * 100 / total))
    else
        CONFIDENCE=0
    fi
}

# ============================================================
# SCAN
# ============================================================

reset_results() {

    RESULT_CATEGORY=()
    RESULT_TITLE=()
    RESULT_STATUS=()
    RESULT_DETAIL=()
    RESULT_FIX=()
    RESULT_POINTS=()
    RESULT_MAX=()
    RESULT_SCOPE=()

    RESULT_COUNT=0
    APPLICABLE_COUNT=0
    SKIPPED_COUNT=0

    LIVE_EARNED=0
    LIVE_POSSIBLE=0

    CAT_EARNED=()
    CAT_POSSIBLE=()
    CAT_CHECKS=()

    : > "${RESULT_FILE}"
    : > "${ISSUE_FILE}"
    : > "${CURRENT_ISSUE_FILE}"
    : > "${HISTORICAL_ISSUE_FILE}"
}

run_scan() {

    reset_results

    SCAN_EPOCH="$(date +%s)"
    SCAN_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

    get_system_info

    (
        echo 10
        echo "Running CPU diagnostics..."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Preparing scan..." 8 70 0

    run_cpu_checks

    (
        echo 20
        echo "Running power and thermal diagnostics..."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Scanning..." 8 70 20

    run_power_checks

    (
        echo 30
        echo "Checking memory..."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Scanning..." 8 70 30

    run_memory_checks

    (
        echo 40
        echo "Checking storage and filesystems..."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Scanning..." 8 70 40

    run_storage_checks

    (
        echo 50
        echo "Checking services and boot reliability..."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Scanning..." 8 70 50

    run_service_checks
    run_boot_checks
    run_kernel_checks

    (
        echo 65
        echo "Checking network..."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Scanning..." 8 70 65

    run_network_checks
    run_dns_checks
    run_wireguard_checks

    (
        echo 75
        echo "Checking security..."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Scanning..." 8 70 75

    run_exposure_checks
    run_ssh_checks
    run_firewall_checks
    run_auth_checks

    (
        echo 85
        echo "Checking software and configuration..."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Scanning..." 8 70 85

    run_update_checks
    run_time_checks
    run_process_checks
    run_configuration_checks

    (
        echo 95
        echo "Checking Raspberry Pi hardware and applications..."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Scanning..." 8 70 95

    run_pi_hardware_checks
    run_application_checks

    calculate_live_score
    calculate_confidence
    calculate_historical_score
    calculate_average
    calculate_best_worst
    calculate_trend
    save_history

    (
        echo 100
        echo "Health scan complete."
    ) | whiptail \
        --title "PiTweaks Healthscore V${VERSION}" \
        --gauge "Complete." 8 70 100
}

# ============================================================
# SCORE LABELS
# ============================================================

score_label() {

    local score="$1"

    if [[ "${score}" -ge 95 ]]; then
        echo "EXCELLENT"
    elif [[ "${score}" -ge 85 ]]; then
        echo "GOOD"
    elif [[ "${score}" -ge 70 ]]; then
        echo "FAIR"
    elif [[ "${score}" -ge 50 ]]; then
        echo "NEEDS ATTENTION"
    else
        echo "CRITICAL"
    fi
}

trend_label() {

    local value="$1"

    if [[ "${value}" -ge 5 ]]; then
        echo "IMPROVING"
    elif [[ "${value}" -le -5 ]]; then
        echo "DECLINING"
    else
        echo "STABLE"
    fi
}

# ============================================================
# HEALTH DASHBOARD
# ============================================================

show_dashboard() {

    local current_issues
    local historical_issues

    current_issues="$(count_current_issues)"
    historical_issues="$(count_historical_issues)"

    local trend
    trend="$(trend_label "${TREND_VALUE}")"

    local trend_symbol="→"

    if [[ "${TREND_VALUE}" -ge 5 ]]; then
        trend_symbol="↑"
    elif [[ "${TREND_VALUE}" -le -5 ]]; then
        trend_symbol="↓"
    fi

    local text

    text=$(
        cat <<EOF
PI HEALTH SCORE

LIVE HEALTH
${LIVE_SCORE}/100 — $(score_label "${LIVE_SCORE}")

HISTORICAL HEALTH
${HISTORICAL_SCORE}/100 — $(score_label "${HISTORICAL_SCORE}")

30-DAY AVERAGE
${AVERAGE_SCORE}/100

TREND
${trend_symbol} ${trend}

BEST RECORDED
${BEST_SCORE}/100

WORST RECORDED
${WORST_SCORE}/100

────────────────────────────────

CURRENT ISSUES       ${current_issues}
HISTORICAL ISSUES    ${historical_issues}

CHECKS EVALUATED     ${APPLICABLE_COUNT}
NOT APPLICABLE       ${SKIPPED_COUNT}
CONFIDENCE           ${CONFIDENCE}%

Last scan:
${SCAN_TIMESTAMP}

Hostname:
${HOSTNAME_VALUE}
EOF
    )

    whiptail \
        --title "PiTweaks Healthscore V${VERSION} — Health Summary" \
        --msgbox "${text}" \
        27 74
}

# ============================================================
# CURRENT ISSUES
# ============================================================

show_current_issues() {

    if [[ ! -s "${CURRENT_ISSUE_FILE}" ]]; then
        ui_msg "CURRENT ISSUES

No current health issues were detected.

The current system state is healthy according to the evaluated checks." 18 72
        return
    fi

    local output=""
    local index=1

    while IFS=$'\t' read -r category severity title detail fix points; do

        output+="[${severity}] ${title}\n"
        output+="Category: ${category}\n"
        output+="${detail}\n"

        if [[ -n "${fix}" ]]; then
            output+="Recommended action: ${fix}\n"
        fi

        output+="\n"

        index=$((index + 1))

    done < "${CURRENT_ISSUE_FILE}"

    whiptail \
        --title "PiTweaks Healthscore V${VERSION} — Current Issues" \
        --scrolltext \
        --msgbox "$(printf '%b' "${output}")" \
        28 80
}

# ============================================================
# HISTORICAL ISSUES
# ============================================================

show_historical_issues() {

    if [[ ! -s "${HISTORICAL_ISSUE_FILE}" ]]; then
        ui_msg "HISTORICAL ISSUES

No historical health issues were detected by the current scan.

Historical events are recorded separately from current conditions." 18 72
        return
    fi

    local output=""

    while IFS=$'\t' read -r category severity title detail fix points; do

        output+="[${severity}] ${title}\n"
        output+="Category: ${category}\n"
        output+="${detail}\n"

        if [[ -n "${fix}" ]]; then
            output+="Recommended action: ${fix}\n"
        fi

        output+="\n"

    done < "${HISTORICAL_ISSUE_FILE}"

    whiptail \
        --title "PiTweaks Healthscore V${VERSION} — Historical Issues" \
        --scrolltext \
        --msgbox "$(printf '%b' "${output}")" \
        28 80
}

# ============================================================
# SCORE BREAKDOWN
# ============================================================

show_score_breakdown() {

    local output="LIVE SCORE BREAKDOWN\n\n"

    local categories=(
        "CPU & Performance"
        "Power & Thermal"
        "Memory"
        "Storage & Filesystems"
        "Services & Boot"
        "Network"
        "DNS & Network Services"
        "Security"
        "Software & Updates"
        "System Reliability"
        "Kernel & Reliability"
        "Raspberry Pi Hardware"
        "Applications"
        "Configuration"
    )

    for category in "${categories[@]}"; do

        local possible="${CAT_POSSIBLE["${category}"]:-0}"
        local earned="${CAT_EARNED["${category}"]:-0}"
        local checks="${CAT_CHECKS["${category}"]:-0}"

        if [[ "${possible}" -gt 0 ]]; then
            local score=$((earned * 100 / possible))

            output+="$(printf '%-26s %3s/100  (%s checks)\n' \
                "${category}" \
                "${score}" \
                "${checks}")"
        fi
    done

    output+="\nOverall live health: ${LIVE_SCORE}/100\n"
    output+="Confidence: ${CONFIDENCE}%\n"

    whiptail \
        --title "PiTweaks Healthscore V${VERSION} — Score Breakdown" \
        --scrolltext \
        --msgbox "${output}" \
        26 78
}

# ============================================================
# HEALTH HISTORY
# ============================================================

show_history() {

    ensure_history_file

    local output="HEALTH HISTORY\n\n"
    output+="DATE / TIME              LIVE   HIST   TREND\n"
    output+="──────────────────────────────────────────────\n"

    local count=0

    while IFS=',' read -r timestamp epoch live historical confidence warnings critical; do

        [[ "${epoch}" =~ ^[0-9]+$ ]] || continue

        output+="$(printf '%-23s %3s    %3s    %s\n' \
            "${timestamp}" \
            "${live}" \
            "${historical}" \
            "${warnings}W/${critical}C")"

        count=$((count + 1))

    done < <(tail -n 20 "${HISTORY_FILE}")

    if [[ "${count}" -eq 0 ]]; then
        output+="No previous health scans recorded.\n"
    fi

    output+="\n30-day average: ${AVERAGE_SCORE}/100"
    output+="\nBest: ${BEST_SCORE}/100"
    output+="\nWorst: ${WORST_SCORE}/100"
    output+="\nTrend: $(trend_label "${TREND_VALUE}")"

    whiptail \
        --title "PiTweaks Healthscore V${VERSION} — Health History" \
        --scrolltext \
        --msgbox "${output}" \
        28 82
}

# ============================================================
# CATEGORY VIEW
# ============================================================

show_categories() {

    local categories=(
        "CPU & Performance"
        "Power & Thermal"
        "Memory"
        "Storage & Filesystems"
        "Services & Boot"
        "Network"
        "DNS & Network Services"
        "Security"
        "Software & Updates"
        "System Reliability"
        "Kernel & Reliability"
        "Raspberry Pi Hardware"
        "Applications"
        "Configuration"
    )

    local menu_items=()

    for category in "${categories[@]}"; do

        local possible="${CAT_POSSIBLE["${category}"]:-0}"
        local earned="${CAT_EARNED["${category}"]:-0}"

        if [[ "${possible}" -gt 0 ]]; then
            local score=$((earned * 100 / possible))

            menu_items+=(
                "${category}"
                "${score}/100"
            )
        fi
    done

    if [[ "${#menu_items[@]}" -eq 0 ]]; then
        ui_msg "No category results are currently available.

Run a health scan first."
        return
    fi

    local selected

    selected="$(
        whiptail \
            --title "PiTweaks Healthscore V${VERSION} — Health Categories" \
            --menu "Select a category:" \
            22 76 12 \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3
    )" || return

    local output=""

    for ((i=0; i<RESULT_COUNT; i++)); do

        if [[ "${RESULT_CATEGORY[i]}" == "${selected}" ]]; then

            output+="[${RESULT_STATUS[i]}] ${RESULT_TITLE[i]}\n"
            output+="${RESULT_DETAIL[i]}\n"

            if [[ -n "${RESULT_FIX[i]}" ]]; then
                output+="Recommended action: ${RESULT_FIX[i]}\n"
            fi

            output+="\n"
        fi
    done

    whiptail \
        --title "PiTweaks Healthscore V${VERSION} — ${selected}" \
        --scrolltext \
        --msgbox "$(printf '%b' "${output}")" \
        28 82
}

# ============================================================
# NOT APPLICABLE
# ============================================================

show_not_applicable() {

    local output=""

    for ((i=0; i<RESULT_COUNT; i++)); do

        if [[ "${RESULT_STATUS[i]}" == "SKIP" ]]; then

            output+="• ${RESULT_TITLE[i]}\n"
            output+="  ${RESULT_DETAIL[i]}\n\n"
        fi
    done

    if [[ -z "${output}" ]]; then
        output="All available checks were applicable."
    fi

    whiptail \
        --title "PiTweaks Healthscore V${VERSION} — Not Applicable" \
        --scrolltext \
        --msgbox "$(printf '%b' "${output}")" \
        28 82
}

# ============================================================
# DIAGNOSTIC DETAILS
# ============================================================

show_diagnostic_details() {

    local output="SYSTEM INFORMATION\n\n"

    output+="Hostname: ${HOSTNAME_VALUE}\n"
    output+="Model: ${PI_MODEL:-Unknown}\n"
    output+="Architecture: ${PI_ARCH}\n"
    output+="Kernel: ${KERNEL_VERSION}\n"
    output+="Version: ${VERSION}\n\n"

    output+="HEALTH\n\n"
    output+="Live: ${LIVE_SCORE}/100\n"
    output+="Historical: ${HISTORICAL_SCORE}/100\n"
    output+="30-day average: ${AVERAGE_SCORE}/100\n"
    output+="Confidence: ${CONFIDENCE}%\n"
    output+="Trend: $(trend_label "${TREND_VALUE}")\n"

    whiptail \
        --title "PiTweaks Healthscore V${VERSION} — System Information" \
        --msgbox "${output}" \
        22 74
}

# ============================================================
# MAIN MENU
# ============================================================

main_menu() {

    if [[ ! -s "${LATEST_FILE}" ]]; then
        run_scan
    else
        # Recalculate displayed historical values from stored history.
        get_system_info
        calculate_live_score
        calculate_confidence
        calculate_historical_score
        calculate_average
        calculate_best_worst
        calculate_trend
    fi

    while true; do

        local current_issues
        current_issues="$(count_current_issues)"

        local historical_issues
        historical_issues="$(count_historical_issues)"

        local choice

        choice="$(
            whiptail \
                --title "PiTweaks Healthscore V${VERSION}" \
                --menu \
                "Live: ${LIVE_SCORE}/100   Historical: ${HISTORICAL_SCORE}/100   Average: ${AVERAGE_SCORE}/100" \
                24 78 12 \
                "SUMMARY" "Health summary and current status" \
                "CURRENT" "Current system issues" \
                "HISTORY" "Historical health and trend" \
                "HISTORICAL" "Past/recovered health issues" \
                "BREAKDOWN" "Detailed score breakdown" \
                "CATEGORIES" "Category health results" \
                "NOT_APPLICABLE" "Checks not applicable to this system" \
                "SYSTEM" "System and hardware information" \
                "RESCAN" "Run a new health scan" \
                "EXIT" "Exit Healthscore" \
                3>&1 1>&2 2>&3
        )" || break

        case "${choice}" in

            SUMMARY)
                show_dashboard
                ;;

            CURRENT)
                show_current_issues
                ;;

            HISTORY)
                show_history
                ;;

            HISTORICAL)
                show_historical_issues
                ;;

            BREAKDOWN)
                show_score_breakdown
                ;;

            CATEGORIES)
                show_categories
                ;;

            NOT_APPLICABLE)
                show_not_applicable
                ;;

            SYSTEM)
                show_diagnostic_details
                ;;

            RESCAN)
                if ui_yesno "Run a new complete health scan?

This may briefly use additional CPU while diagnostics are performed." 12 72; then
                    run_scan
                fi
                ;;

            EXIT)
                break
                ;;

        esac
    done
}

# ============================================================
# START
# ============================================================

main_menu

exit 0
