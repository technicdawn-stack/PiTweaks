#!/bin/bash

# ============================================================
# PiTweaks - Health Score
# Healthscore.sh
#
# Description: Adaptive Raspberry Pi Health Scoring & Diagnostic Utility V1.5
# PERSISTENT: FALSE
# Category: Diagnostics
#
# Features:
#   - Adaptive multi-category health scoring
#   - 100+ potential diagnostic checks
#   - CPU and frequency analysis
#   - Thermal and undervoltage analysis
#   - Memory and swap analysis
#   - Storage and filesystem health
#   - SMART and I/O diagnostics
#   - systemd/service reliability
#   - Service crash/restart history
#   - Boot and kernel health
#   - Network and packet-loss diagnostics
#   - DNS / Pi-hole / Unbound chain testing
#   - WireGuard diagnostics
#   - SSH and firewall security checks
#   - Package/update health
#   - Raspberry Pi hardware diagnostics
#   - Process reliability checks
#   - Application-aware diagnostics
#   - Historical/current issue distinction
#   - Severity-weighted scoring
#   - Adaptive applicability
#   - Confidence score
#   - "Why is my score X?" diagnostics
#   - Recommended corrective actions
#   - Whiptail interface
#
# Requirements:
#   - bash
#   - whiptail
#
# Optional:
#   - systemctl
#   - journalctl
#   - vcgencmd
#   - smartctl
#   - dig
#   - ping
#   - wg
#   - ufw
#   - nft
#   - iptables
#   - fail2ban-client
#   - docker
#   - caddy
#   - tailscale
#   - pihole
#   - unbound-control
# ============================================================

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

TITLE="PiTweaks | Health Score"
VERSION="1.5"

TMP_DIR=$(mktemp -d)

RESULT_FILE="${TMP_DIR}/results"
DETAIL_FILE="${TMP_DIR}/details"
CATEGORY_FILE="${TMP_DIR}/categories"
SUMMARY_FILE="${TMP_DIR}/summary"
ISSUE_FILE="${TMP_DIR}/issues"
SKIP_FILE="${TMP_DIR}/skipped"
SERVICE_FILE="${TMP_DIR}/services"

TOTAL_POSSIBLE=0
TOTAL_APPLICABLE=0
TOTAL_PASS=0
TOTAL_WARN=0
TOTAL_FAIL=0
TOTAL_SKIP=0

OVERALL_DEDUCTIONS=0
OVERALL_WEIGHT=0

CURRENT_CATEGORY=""

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# ------------------------------------------------------------
# Terminal sizing
# ------------------------------------------------------------

TERM_HEIGHT=$(tput lines 2>/dev/null || echo 24)
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

(( TERM_HEIGHT < 20 )) && TERM_HEIGHT=20
(( TERM_WIDTH < 75 )) && TERM_WIDTH=75

# ------------------------------------------------------------
# Dependency checks
# ------------------------------------------------------------

if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail is required."
    echo "Install it with:"
    echo "sudo apt install whiptail"
    exit 1
fi

# ------------------------------------------------------------
# Utility functions
# ------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

safe_int() {
    local value="$1"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    else
        echo "0"
    fi
}

show_message() {
    whiptail \
        --title "$TITLE" \
        --msgbox \
        "$1" \
        "${2:-12}" \
        "${3:-70}"
}

show_text() {
    local file="$1"
    local title="$2"

    whiptail \
        --title "$TITLE | $title" \
        --textbox \
        "$file" \
        "$TERM_HEIGHT" \
        "$TERM_WIDTH"
}

# ------------------------------------------------------------
# Result engine
# ------------------------------------------------------------

record_result() {
    local category="$1"
    local id="$2"
    local status="$3"
    local weight="$4"
    local deduction="$5"
    local title="$6"
    local explanation="$7"
    local recommendation="$8"

    TOTAL_POSSIBLE=$((TOTAL_POSSIBLE + weight))

    case "$status" in

        PASS)
            TOTAL_PASS=$((TOTAL_PASS + 1))
            TOTAL_APPLICABLE=$((TOTAL_APPLICABLE + 1))
            ;;

        WARN)
            TOTAL_WARN=$((TOTAL_WARN + 1))
            TOTAL_APPLICABLE=$((TOTAL_APPLICABLE + 1))
            OVERALL_DEDUCTIONS=$((OVERALL_DEDUCTIONS + deduction))
            OVERALL_WEIGHT=$((OVERALL_WEIGHT + weight))
            ;;

        FAIL)
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            TOTAL_APPLICABLE=$((TOTAL_APPLICABLE + 1))
            OVERALL_DEDUCTIONS=$((OVERALL_DEDUCTIONS + deduction))
            OVERALL_WEIGHT=$((OVERALL_WEIGHT + weight))
            ;;

        SKIP)
            TOTAL_SKIP=$((TOTAL_SKIP + 1))
            printf '%s|%s|%s\n' \
                "$category" \
                "$title" \
                "$explanation" >> "$SKIP_FILE"
            return
            ;;

    esac

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$category" \
        "$id" \
        "$status" \
        "$weight" \
        "$deduction" \
        "$title" \
        "$explanation" \
        "$recommendation" >> "$RESULT_FILE"

    if [[ "$status" != "PASS" ]]; then
        printf '%s|%s|%s|%s|%s|%s\n' \
            "$category" \
            "$status" \
            "$deduction" \
            "$title" \
            "$explanation" \
            "$recommendation" >> "$ISSUE_FILE"
    fi
}

check_pass() {
    record_result \
        "$1" "$2" PASS "$3" 0 "$4" "$5" "$6"
}

check_warn() {
    record_result \
        "$1" "$2" WARN "$3" "$4" "$5" "$6" "$7"
}

check_fail() {
    record_result \
        "$1" "$2" FAIL "$3" "$4" "$5" "$6" "$7"
}

check_skip() {
    record_result \
        "$1" "$2" SKIP 0 0 "$3" "$4" "$5"
}

# ------------------------------------------------------------
# Score calculation
# ------------------------------------------------------------

calculate_score() {

    if (( TOTAL_APPLICABLE == 0 )); then
        SCORE=0
    else
        SCORE=$((100 - OVERALL_DEDUCTIONS))

        (( SCORE < 0 )) && SCORE=0
        (( SCORE > 100 )) && SCORE=100
    fi

    if (( TOTAL_APPLICABLE > 0 )); then
        CONFIDENCE=$((TOTAL_APPLICABLE * 100 / TOTAL_POSSIBLE))
    else
        CONFIDENCE=0
    fi

    if (( CONFIDENCE > 100 )); then
        CONFIDENCE=100
    fi

    if (( SCORE >= 90 )); then
        GRADE="EXCELLENT"
    elif (( SCORE >= 80 )); then
        GRADE="GOOD"
    elif (( SCORE >= 70 )); then
        GRADE="FAIR"
    elif (( SCORE >= 60 )); then
        GRADE="POOR"
    else
        GRADE="CRITICAL"
    fi
}

# ------------------------------------------------------------
# Category helper
# ------------------------------------------------------------

category_score() {

    local category="$1"

    local possible=0
    local deductions=0
    local applicable=0

    while IFS='|' read -r cat id status weight deduction title explanation recommendation; do

        [[ "$cat" != "$category" ]] && continue

        case "$status" in
            PASS|WARN|FAIL)
                possible=$((possible + weight))
                applicable=$((applicable + 1))
                deductions=$((deductions + deduction))
                ;;
        esac

    done < "$RESULT_FILE"

    if (( possible == 0 )); then
        echo "N/A"
        return
    fi

    local result=$((100 - (deductions * 100 / possible)))

    (( result < 0 )) && result=0
    (( result > 100 )) && result=100

    echo "$result"
}

# ------------------------------------------------------------
# CPU
# ------------------------------------------------------------

run_cpu_checks() {

    CURRENT_CATEGORY="CPU"

    local cores
    cores=$(nproc 2>/dev/null || echo 0)

    if (( cores > 0 )); then
        check_pass \
            "$CURRENT_CATEGORY" \
            "cpu_cores" \
            2 \
            "CPU cores detected" \
            "${cores} logical CPU cores detected." \
            "No action required."
    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "CPU core count" \
            "Unable to determine CPU core count." \
            "CPU information is unavailable."
    fi

    local model
    model=$(awk -F: '/Model|Hardware/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | xargs)

    if [[ -n "$model" ]]; then
        check_pass \
            "$CURRENT_CATEGORY" \
            "cpu_model" \
            2 \
            "CPU model identification" \
            "$model" \
            "No action required."
    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "CPU model" \
            "CPU model could not be identified." \
            "No reliable CPU model information was found."
    fi

    local arch
    arch=$(uname -m 2>/dev/null || true)

    if [[ -n "$arch" ]]; then
        check_pass \
            "$CURRENT_CATEGORY" \
            "cpu_arch" \
            2 \
            "CPU architecture" \
            "Architecture: $arch" \
            "No action required."
    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "CPU architecture" \
            "Architecture unavailable." \
            "uname did not return an architecture."
    fi

    local load
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)

    if [[ "$load" =~ ^[0-9.]+$ ]] && (( cores > 0 )); then

        local load10
        load10=$(awk -v l="$load" -v c="$cores" 'BEGIN { if (c>0) print l/c; else print 0 }')

        if awk -v l="$load10" 'BEGIN {exit !(l < 1)}'; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "cpu_load" \
                3 \
                "CPU load" \
                "Load average is $load across $cores logical CPU(s)." \
                "No action required."

        elif awk -v l="$load10" 'BEGIN {exit !(l < 2)}'; then

            check_warn \
                "$CURRENT_CATEGORY" \
                "cpu_load" \
                3 \
                2 \
                "Elevated CPU load" \
                "Load average is $load across $cores logical CPU(s)." \
                "Check the process list if high load is persistent."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "cpu_load" \
                3 \
                4 \
                "High CPU load" \
                "Load average is $load across $cores logical CPU(s)." \
                "Inspect top CPU-consuming processes."

        fi

    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "CPU load" \
            "Load average could not be evaluated." \
            "Required CPU information is unavailable."
    fi

    local governor=""
    for path in \
        /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor \
        /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
    do
        if [[ -r "$path" ]]; then
            governor=$(cat "$path")
            break
        fi
    done

    if [[ -n "$governor" ]]; then

        case "$governor" in
            powersave|schedutil|ondemand|performance|conservative)
                check_pass \
                    "$CURRENT_CATEGORY" \
                    "cpu_governor" \
                    2 \
                    "CPU governor" \
                    "CPU governor: $governor" \
                    "No action required."
                ;;
            *)
                check_warn \
                    "$CURRENT_CATEGORY" \
                    "cpu_governor" \
                    2 \
                    1 \
                    "Unusual CPU governor" \
                    "CPU governor is '$governor'." \
                    "Verify that this governor is intentional."
                ;;
        esac

    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "CPU governor" \
            "CPU frequency governor is unavailable." \
            "cpufreq information is not exposed."
    fi

    local cur_freq=""
    local min_freq=""
    local max_freq=""

    for base in \
        /sys/devices/system/cpu/cpu0/cpufreq \
        /sys/devices/system/cpu/cpufreq/policy0
    do

        [[ -z "$cur_freq" && -r "$base/scaling_cur_freq" ]] &&
            cur_freq=$(cat "$base/scaling_cur_freq")

        [[ -z "$min_freq" && -r "$base/scaling_min_freq" ]] &&
            min_freq=$(cat "$base/scaling_min_freq")

        [[ -z "$max_freq" && -r "$base/scaling_max_freq" ]] &&
            max_freq=$(cat "$base/scaling_max_freq")

    done

    if [[ -n "$cur_freq" ]]; then

        local cur_mhz=$((cur_freq / 1000))

        check_pass \
            "$CURRENT_CATEGORY" \
            "cpu_frequency" \
            2 \
            "Current CPU frequency" \
            "Current CPU frequency: ${cur_mhz} MHz." \
            "No action required."

    elif command_exists vcgencmd; then

        local freq
        freq=$(vcgencmd measure_clock arm 2>/dev/null | awk -F= '{print $2}')

        if [[ "$freq" =~ ^[0-9]+$ ]]; then

            local mhz=$((freq / 1000000))

            check_pass \
                "$CURRENT_CATEGORY" \
                "cpu_frequency" \
                2 \
                "Current CPU frequency" \
                "Current ARM frequency: ${mhz} MHz." \
                "No action required."

        else
            check_skip \
                "$CURRENT_CATEGORY" \
                "CPU frequency" \
                "Unable to read current CPU frequency." \
                "No compatible frequency interface was found."
        fi

    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "CPU frequency" \
            "Unable to read current CPU frequency." \
            "No compatible frequency interface was found."
    fi

    if [[ "$min_freq" =~ ^[0-9]+$ && "$max_freq" =~ ^[0-9]+$ ]]; then

        local min_mhz=$((min_freq / 1000))
        local max_mhz=$((max_freq / 1000))

        if (( max_freq > min_freq )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "cpu_frequency_range" \
                2 \
                "CPU frequency range" \
                "Configured frequency range: ${min_mhz}-${max_mhz} MHz." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "cpu_frequency_range" \
                2 \
                1 \
                "Restricted CPU frequency range" \
                "Minimum and maximum CPU frequencies are both ${max_mhz} MHz." \
                "Check whether CPU frequency has intentionally been locked."

        fi

    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "CPU frequency range" \
            "CPU frequency limits unavailable." \
            "cpufreq limits could not be read."
    fi

    local idle=""
    if [[ -r /proc/stat ]]; then
        idle=$(awk '/^cpu / {print $5; exit}' /proc/stat)

        if [[ "$idle" =~ ^[0-9]+$ ]]; then
            check_pass \
                "$CURRENT_CATEGORY" \
                "cpu_idle" \
                2 \
                "CPU idle availability" \
                "CPU idle counter is available and currently reports $idle ticks." \
                "No action required."
        else
            check_skip \
                "$CURRENT_CATEGORY" \
                "CPU idle" \
                "CPU idle statistics unavailable." \
                "The kernel did not expose usable CPU idle data."
        fi
    fi
}

# ------------------------------------------------------------
# Thermal / power
# ------------------------------------------------------------

run_power_checks() {

    CURRENT_CATEGORY="Power & Thermal"

    local temp=""

    if command_exists vcgencmd; then
        temp=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    fi

    if [[ -z "$temp" ]]; then
        for thermal in /sys/class/thermal/thermal_zone*/temp; do
            if [[ -r "$thermal" ]]; then
                local raw
                raw=$(cat "$thermal" 2>/dev/null)

                if [[ "$raw" =~ ^[0-9]+$ ]]; then
                    temp=$(awk -v t="$raw" 'BEGIN {printf "%.1f", t/1000}')
                    break
                fi
            fi
        done
    fi

    if [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]]; then

        if awk -v t="$temp" 'BEGIN {exit !(t < 70)}'; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "temperature" \
                4 \
                "CPU temperature" \
                "Current temperature: ${temp}°C." \
                "No action required."

        elif awk -v t="$temp" 'BEGIN {exit !(t < 80)}'; then

            check_warn \
                "$CURRENT_CATEGORY" \
                "temperature" \
                4 \
                3 \
                "High CPU temperature" \
                "Current temperature: ${temp}°C." \
                "Improve cooling or investigate sustained CPU load."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "temperature" \
                5 \
                5 \
                "Critical CPU temperature" \
                "Current temperature: ${temp}°C." \
                "Reduce load and investigate cooling immediately."

        fi

    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "CPU temperature" \
            "Temperature could not be read." \
            "No compatible thermal sensor was found."
    fi

    if command_exists vcgencmd; then

        local throttle
        throttle=$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}')

        if [[ "$throttle" =~ ^0x[0-9a-fA-F]+$ ]]; then

            if [[ "$throttle" == "0x0" ]]; then

                check_pass \
                    "$CURRENT_CATEGORY" \
                    "undervoltage" \
                    6 \
                    "Power / undervoltage state" \
                    "No current or historical throttling flags reported." \
                    "No action required."

            else

                local value
                value=$((throttle))

                local messages=""

                (( value & 0x1 )) && messages+="currently undervolted; "
                (( value & 0x2 )) && messages+="currently frequency capped; "
                (( value & 0x4 )) && messages+="currently throttled; "
                (( value & 0x8 )) && messages+="currently temperature limited; "
                (( value & 0x10000 )) && messages+="historical undervoltage detected; "
                (( value & 0x20000 )) && messages+="historical frequency capping detected; "
                (( value & 0x40000 )) && messages+="historical throttling detected; "
                (( value & 0x80000 )) && messages+="historical temperature limiting detected; "

                if (( value & 0x1 )); then

                    check_fail \
                        "$CURRENT_CATEGORY" \
                        "undervoltage_current" \
                        6 \
                        6 \
                        "Current undervoltage detected" \
                        "Firmware reports: ${messages}" \
                        "Check the power supply, USB load, cable quality and connector voltage drop."

                elif (( value & 0x10000 )); then

                    check_warn \
                        "$CURRENT_CATEGORY" \
                        "undervoltage_history" \
                        5 \
                        4 \
                        "Historical undervoltage detected" \
                        "Firmware reports previous power instability: ${messages}" \
                        "Use a suitable power supply and inspect the power cable."

                elif (( value & 0x4 )); then

                    check_warn \
                        "$CURRENT_CATEGORY" \
                        "throttle_history" \
                        4 \
                        2 \
                        "CPU throttling detected" \
                        "Firmware reports throttling: ${messages}" \
                        "Investigate temperature, power and CPU frequency limits."

                else

                    check_warn \
                        "$CURRENT_CATEGORY" \
                        "power_flags" \
                        4 \
                        2 \
                        "Power or thermal history detected" \
                        "Firmware flags: ${messages}" \
                        "Review power and cooling conditions."

                fi

            fi

        else
            check_skip \
                "$CURRENT_CATEGORY" \
                "Undervoltage status" \
                "vcgencmd returned no usable throttle state." \
                "Firmware throttle information is unavailable."
        fi

    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "Undervoltage status" \
            "vcgencmd is unavailable." \
            "This check requires Raspberry Pi firmware utilities."
    fi

    if [[ -r /proc/device-tree/model ]]; then

        local pi_model
        pi_model=$(tr -d '\0' < /proc/device-tree/model)

        check_pass \
            "$CURRENT_CATEGORY" \
            "pi_model" \
            2 \
            "Raspberry Pi model" \
            "$pi_model" \
            "No action required."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Raspberry Pi model" \
            "Device-tree model unavailable." \
            "The system does not expose Raspberry Pi model information."
    fi

    if command_exists vcgencmd; then

        local firmware
        firmware=$(vcgencmd version 2>/dev/null | head -1)

        if [[ -n "$firmware" ]]; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "firmware" \
                2 \
                "Firmware information" \
                "$firmware" \
                "No action required."

        else
            check_skip \
                "$CURRENT_CATEGORY" \
                "Firmware information" \
                "Firmware version unavailable." \
                "vcgencmd did not return firmware information."
        fi

    else
        check_skip \
            "$CURRENT_CATEGORY" \
            "Firmware information" \
            "vcgencmd unavailable." \
            "Raspberry Pi firmware tools are not installed."
    fi
}

# ------------------------------------------------------------
# Memory
# ------------------------------------------------------------

run_memory_checks() {

    CURRENT_CATEGORY="Memory"

    if command_exists free; then

        local total used available swap_total swap_used

        total=$(free -m | awk '/^Mem:/ {print $2}')
        used=$(free -m | awk '/^Mem:/ {print $3}')
        available=$(free -m | awk '/^Mem:/ {print $7}')

        swap_total=$(free -m | awk '/^Swap:/ {print $2}')
        swap_used=$(free -m | awk '/^Swap:/ {print $3}')

        if [[ "$total" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]]; then

            local used_pct=$((used * 100 / total))

            if (( used_pct < 80 )); then

                check_pass \
                    "$CURRENT_CATEGORY" \
                    "ram_usage" \
                    5 \
                    "RAM usage" \
                    "${used} MB used of ${total} MB (${used_pct}%). ${available} MB available." \
                    "No action required."

            elif (( used_pct < 92 )); then

                check_warn \
                    "$CURRENT_CATEGORY" \
                    "ram_usage" \
                    5 \
                    3 \
                    "High RAM usage" \
                    "${used} MB used of ${total} MB (${used_pct}%)." \
                    "Check memory-heavy services and applications."

            else

                check_fail \
                    "$CURRENT_CATEGORY" \
                    "ram_usage" \
                    5 \
                    5 \
                    "Critical RAM usage" \
                    "${used} MB used of ${total} MB (${used_pct}%)." \
                    "Investigate memory-consuming processes and possible leaks."

            fi

        else

            check_skip \
                "$CURRENT_CATEGORY" \
                "RAM usage" \
                "RAM statistics unavailable." \
                "free did not return usable information."

        fi

        if [[ "$swap_total" =~ ^[0-9]+$ && "$swap_total" -gt 0 ]]; then

            local swap_pct=$((swap_used * 100 / swap_total))

            if (( swap_pct < 50 )); then

                check_pass \
                    "$CURRENT_CATEGORY" \
                    "swap_usage" \
                    3 \
                    "Swap usage" \
                    "${swap_used} MB of ${swap_total} MB swap used (${swap_pct}%)." \
                    "No action required."

            elif (( swap_pct < 85 )); then

                check_warn \
                    "$CURRENT_CATEGORY" \
                    "swap_usage" \
                    3 \
                    2 \
                    "Elevated swap usage" \
                    "${swap_used} MB of ${swap_total} MB swap used (${swap_pct}%)." \
                    "Check for memory pressure."

            else

                check_fail \
                    "$CURRENT_CATEGORY" \
                    "swap_usage" \
                    4 \
                    4 \
                    "Heavy swap usage" \
                    "${swap_used} MB of ${swap_total} MB swap used." \
                    "Investigate RAM pressure and memory-heavy processes."

            fi

        else

            check_skip \
                "$CURRENT_CATEGORY" \
                "Swap usage" \
                "No active swap device detected." \
                "This is not necessarily a problem if sufficient RAM is available."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Memory statistics" \
            "free command unavailable." \
            "Cannot read RAM statistics."

    fi

    if [[ -r /proc/pressure/memory ]]; then

        local psi
        psi=$(cat /proc/pressure/memory 2>/dev/null)

        if grep -q "avg10=0" <<< "$psi"; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "memory_pressure" \
                3 \
                "Memory pressure" \
                "No significant recent memory pressure reported." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "memory_pressure" \
                3 \
                2 \
                "Memory pressure detected" \
                "$psi" \
                "Check applications and processes consuming RAM."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Memory pressure" \
            "PSI memory statistics unavailable." \
            "Kernel pressure statistics are not exposed."

    fi

    if [[ -r /proc/zoneinfo ]]; then

        local oom_count
        oom_count=$(journalctl -k --since "24 hours ago" --no-pager 2>/dev/null |
            grep -Eic 'out of memory|oom-killer|killed process' || true)

        if (( oom_count == 0 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "oom_events" \
                5 \
                "OOM events" \
                "No OOM-killer events detected in the last 24 hours." \
                "No action required."

        elif (( oom_count < 3 )); then

            check_warn \
                "$CURRENT_CATEGORY" \
                "oom_events" \
                5 \
                3 \
                "Recent OOM events" \
                "$oom_count OOM-related event(s) detected in the last 24 hours." \
                "Investigate RAM usage and memory-heavy services."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "oom_events" \
                6 \
                6 \
                "Repeated OOM events" \
                "$oom_count OOM-related event(s) detected in the last 24 hours." \
                "Investigate memory leaks, workloads and available RAM."

        fi

    fi

    if [[ -d /sys/block/zram0 ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "zram" \
            2 \
            "zram detected" \
            "zram swap device is available." \
            "No action required."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "zram" \
            "zram is not configured." \
            "This is informational and is not automatically considered a failure."
    fi
}

# ------------------------------------------------------------
# Storage
# ------------------------------------------------------------

run_storage_checks() {

    CURRENT_CATEGORY="Storage"

    local root_usage
    root_usage=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')

    if [[ "$root_usage" =~ ^[0-9]+$ ]]; then

        if (( root_usage < 80 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "root_usage" \
                5 \
                "Root filesystem usage" \
                "Root filesystem is ${root_usage}% full." \
                "No action required."

        elif (( root_usage < 90 )); then

            check_warn \
                "$CURRENT_CATEGORY" \
                "root_usage" \
                5 \
                3 \
                "Root filesystem getting full" \
                "Root filesystem is ${root_usage}% full." \
                "Remove unnecessary files or expand storage."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "root_usage" \
                6 \
                6 \
                "Root filesystem critically full" \
                "Root filesystem is ${root_usage}% full." \
                "Free storage space immediately."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Root filesystem usage" \
            "Unable to determine root filesystem usage." \
            "df did not return usable information."
    fi

    local inode_usage
    inode_usage=$(df -Pi / | awk 'NR==2 {gsub("%","",$5); print $5}')

    if [[ "$inode_usage" =~ ^[0-9]+$ ]]; then

        if (( inode_usage < 80 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "inode_usage" \
                3 \
                "Root inode usage" \
                "Root filesystem inode usage is ${inode_usage}%." \
                "No action required."

        elif (( inode_usage < 95 )); then

            check_warn \
                "$CURRENT_CATEGORY" \
                "inode_usage" \
                3 \
                2 \
                "High inode usage" \
                "Root filesystem inode usage is ${inode_usage}%." \
                "Investigate directories containing very large numbers of small files."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "inode_usage" \
                4 \
                4 \
                "Critical inode usage" \
                "Root filesystem inode usage is ${inode_usage}%." \
                "Free files/inodes immediately."

        fi

    fi

    local fs_type
    fs_type=$(findmnt -n -o FSTYPE / 2>/dev/null || true)

    if [[ -n "$fs_type" ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "filesystem_type" \
            2 \
            "Root filesystem type" \
            "Root filesystem uses $fs_type." \
            "No action required."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Filesystem type" \
            "Unable to determine root filesystem type." \
            "findmnt is unavailable or returned no result."
    fi

    local readonly_test
    readonly_test=$(findmnt -n -o OPTIONS / 2>/dev/null | head -1 || true)

    if grep -qw ro <<< "$readonly_test"; then

        check_fail \
            "$CURRENT_CATEGORY" \
            "filesystem_readonly" \
            7 \
            7 \
            "Root filesystem is read-only" \
            "The root filesystem is mounted read-only." \
            "Investigate filesystem errors and storage health."

    else

        check_pass \
            "$CURRENT_CATEGORY" \
            "filesystem_readonly" \
            7 \
            "Root filesystem writable" \
            "The root filesystem is not mounted read-only." \
            "No action required."

    fi

    local mount_errors
    mount_errors=$(systemctl --failed --type=mount --no-legend 2>/dev/null | wc -l)

    if (( mount_errors == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "failed_mounts" \
            4 \
            "Failed mount units" \
            "No failed systemd mount units detected." \
            "No action required."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "failed_mounts" \
            5 \
            5 \
            "Failed mount units" \
            "$mount_errors failed mount unit(s) detected." \
            "Inspect systemctl status for failed mount units and check /etc/fstab."

    fi

    local fstab_errors=0

    if [[ -f /etc/fstab ]] && command_exists findmnt; then

        if ! findmnt --verify --verbose >/dev/null 2>&1; then
            fstab_errors=1
        fi

        if (( fstab_errors == 0 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "fstab" \
                4 \
                "Filesystem configuration" \
                "/etc/fstab verification completed without errors." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "fstab" \
                4 \
                3 \
                "Filesystem configuration issue" \
                "findmnt reported a problem while verifying /etc/fstab." \
                "Run 'findmnt --verify --verbose' and review /etc/fstab."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "fstab verification" \
            "Unable to verify /etc/fstab." \
            "Required filesystem tools or configuration are unavailable."
    fi

    local io_errors
    io_errors=$(journalctl -k --since "24 hours ago" --no-pager 2>/dev/null |
        grep -Eic 'I/O error|Buffer I/O error|EXT4-fs error|FAT-fs error|XFS.*error|blk_update_request' || true)

    if (( io_errors == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "storage_kernel_errors" \
            6 \
            "Storage kernel errors" \
            "No major storage I/O/filesystem errors detected in the last 24 hours." \
            "No action required."

    elif (( io_errors < 5 )); then

        check_warn \
            "$CURRENT_CATEGORY" \
            "storage_kernel_errors" \
            6 \
            4 \
            "Storage errors detected" \
            "$io_errors storage-related kernel event(s) detected in the last 24 hours." \
            "Check storage health, cables and filesystem logs."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "storage_kernel_errors" \
            7 \
            7 \
            "Repeated storage errors" \
            "$io_errors storage-related kernel events detected in the last 24 hours." \
            "Back up important data and investigate the storage device."

    fi

    if command_exists smartctl; then

        local smart_devices
        smart_devices=$(lsblk -dn -o NAME,TYPE 2>/dev/null |
            awk '$2=="disk" {print "/dev/"$1}')

        if [[ -n "$smart_devices" ]]; then

            local smart_bad=0
            local smart_checked=0

            while IFS= read -r device; do

                [[ -z "$device" ]] && continue

                smart_checked=$((smart_checked + 1))

                if ! smartctl -H "$device" >/dev/null 2>&1; then
                    continue
                fi

                if smartctl -H "$device" 2>/dev/null |
                    grep -Eqi 'PASSED|OK|result:.*passed'; then
                    :
                else
                    smart_bad=$((smart_bad + 1))
                fi

            done <<< "$smart_devices"

            if (( smart_checked > 0 && smart_bad == 0 )); then

                check_pass \
                    "$CURRENT_CATEGORY" \
                    "smart" \
                    6 \
                    "SMART health" \
                    "SMART health checks completed without a reported failure." \
                    "No action required."

            elif (( smart_bad > 0 )); then

                check_fail \
                    "$CURRENT_CATEGORY" \
                    "smart" \
                    7 \
                    7 \
                    "SMART health warning" \
                    "$smart_bad storage device(s) did not report a healthy SMART result." \
                    "Back up data and investigate the affected storage device."

            else

                check_skip \
                    "$CURRENT_CATEGORY" \
                    "SMART health" \
                    "SMART information could not be evaluated." \
                    "The detected devices may not expose SMART information."

            fi

        else

            check_skip \
                "$CURRENT_CATEGORY" \
                "SMART health" \
                "No physical disk devices detected." \
                "SMART requires a compatible storage device."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "SMART health" \
            "smartctl is not installed." \
            "Install smartmontools if SMART diagnostics are desired."
    fi

    local log_size
    if [[ -d /var/log ]]; then

        log_size=$(du -sm /var/log 2>/dev/null | awk '{print $1}')

        if [[ "$log_size" =~ ^[0-9]+$ ]]; then

            if (( log_size < 1024 )); then

                check_pass \
                    "$CURRENT_CATEGORY" \
                    "log_size" \
                    2 \
                    "Log directory size" \
                    "/var/log is ${log_size} MB." \
                    "No action required."

            elif (( log_size < 4096 )); then

                check_warn \
                    "$CURRENT_CATEGORY" \
                    "log_size" \
                    2 \
                    1 \
                    "Large log directory" \
                    "/var/log is ${log_size} MB." \
                    "Review log rotation and unusually large logs."

            else

                check_warn \
                    "$CURRENT_CATEGORY" \
                    "log_size" \
                    3 \
                    2 \
                    "Very large log directory" \
                    "/var/log is ${log_size} MB." \
                    "Investigate large logs and log rotation."

            fi

        fi

    fi
}

# ------------------------------------------------------------
# Services
# ------------------------------------------------------------

run_service_checks() {

    CURRENT_CATEGORY="Services"

    if ! command_exists systemctl; then

        check_skip \
            "$CURRENT_CATEGORY" \
            "systemd" \
            "systemctl is unavailable." \
            "This system does not appear to use systemd."

        return
    fi

    local failed_services
    failed_services=$(systemctl --failed --type=service --no-legend 2>/dev/null | wc -l)

    if (( failed_services == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "failed_services" \
            7 \
            "Failed services" \
            "No failed systemd services detected." \
            "No action required."

    elif (( failed_services < 3 )); then

        check_warn \
            "$CURRENT_CATEGORY" \
            "failed_services" \
            7 \
            4 \
            "Failed services detected" \
            "$failed_services failed service(s) detected." \
            "Inspect 'systemctl --failed' and review the affected service logs."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "failed_services" \
            8 \
            8 \
            "Multiple failed services" \
            "$failed_services failed service(s) detected." \
            "Investigate failed services and their journal logs."

    fi

    local activating
    activating=$(systemctl list-units --type=service --state=activating --no-legend 2>/dev/null | wc -l)

    if (( activating == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "activating_services" \
            3 \
            "Stuck activating services" \
            "No services appear stuck in the activating state." \
            "No action required."

    else

        check_warn \
            "$CURRENT_CATEGORY" \
            "activating_services" \
            4 \
            2 \
            "Services still activating" \
            "$activating service(s) are currently activating." \
            "Check these services if they remain stuck for an extended period."

    fi

    local failed_units
    failed_units=$(systemctl --failed --no-legend 2>/dev/null | wc -l)

    if (( failed_units == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "failed_units" \
            4 \
            "Systemd failed units" \
            "No failed systemd units detected." \
            "No action required."

    else

        check_warn \
            "$CURRENT_CATEGORY" \
            "failed_units" \
            4 \
            2 \
            "Failed systemd units" \
            "$failed_units failed unit(s) detected." \
            "Run 'systemctl --failed' to inspect them."

    fi

    if command_exists systemd-analyze; then

        local verify_output
        verify_output=$(systemd-analyze verify 2>&1 || true)

        if [[ -z "$verify_output" ]]; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "systemd_verify" \
                5 \
                "Systemd configuration" \
                "systemd-analyze verify reported no configuration errors." \
                "No action required."

        else

            local verify_lines
            verify_lines=$(printf '%s\n' "$verify_output" | wc -l)

            check_warn \
                "$CURRENT_CATEGORY" \
                "systemd_verify" \
                5 \
                3 \
                "Systemd configuration warnings" \
                "$verify_lines systemd verification message(s) were reported." \
                "Review 'systemd-analyze verify' output."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "systemd verification" \
            "systemd-analyze is unavailable." \
            "Cannot verify systemd unit configuration."
    fi

    local crash_count
    crash_count=$(journalctl --since "24 hours ago" --no-pager 2>/dev/null |
        grep -Eic 'failed with result|Main process exited|code=exited.*status=[1-9]|Start request repeated too quickly|Scheduled restart job' || true)

    if (( crash_count == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "service_crashes" \
            7 \
            "Service crash history" \
            "No obvious service crash/restart events detected in the last 24 hours." \
            "No action required."

    elif (( crash_count < 5 )); then

        check_warn \
            "$CURRENT_CATEGORY" \
            "service_crashes" \
            7 \
            4 \
            "Service failures detected" \
            "$crash_count service failure/restart event(s) detected in the last 24 hours." \
            "Inspect recent journal entries for the affected services."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "service_crashes" \
            8 \
            8 \
            "Repeated service failures" \
            "$crash_count service failure/restart event(s) detected in the last 24 hours." \
            "Identify repeatedly failing services and inspect their logs."

    fi

    local custom_count=0

    while IFS= read -r unit; do

        [[ -z "$unit" ]] && continue

        local fragment
        fragment=$(systemctl show "$unit" \
            --property=FragmentPath \
            --value 2>/dev/null || true)

        case "$fragment" in
            /etc/systemd/system/*|/usr/local/lib/systemd/system/*|/opt/*)
                custom_count=$((custom_count + 1))
                ;;
        esac

    done < <(
        systemctl list-unit-files \
            --type=service \
            --no-legend \
            --no-pager 2>/dev/null |
            awk '{print $1}'
    )

    check_pass \
        "$CURRENT_CATEGORY" \
        "custom_services" \
        2 \
        "Custom service discovery" \
        "$custom_count custom/local service definition(s) detected." \
        "No action required."
}

# ------------------------------------------------------------
# Boot / kernel
# ------------------------------------------------------------

run_boot_checks() {

    CURRENT_CATEGORY="Boot & Reliability"

    if command_exists systemd-analyze; then

        local boot_time
        boot_time=$(systemd-analyze 2>/dev/null | head -1)

        if [[ -n "$boot_time" ]]; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "boot_time" \
                4 \
                "Boot timing" \
                "$boot_time" \
                "No action required."

        else
            check_skip \
                "$CURRENT_CATEGORY" \
                "Boot timing" \
                "Boot timing unavailable." \
                "systemd-analyze did not return usable output."
        fi

        local blame_count
        blame_count=$(systemd-analyze blame 2>/dev/null |
            head -10 |
            grep -c . || true)

        if (( blame_count > 0 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "boot_services" \
                3 \
                "Boot service analysis" \
                "systemd-analyze can identify boot-time service cost." \
                "Use the BOOT analysis screen for detailed timing."

        else

            check_skip \
                "$CURRENT_CATEGORY" \
                "Boot service analysis" \
                "No boot timing information available." \
                "systemd-analyze did not provide service timing."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Boot analysis" \
            "systemd-analyze is unavailable." \
            "Boot timing cannot be evaluated."
    fi

    local kernel_errors
    kernel_errors=$(journalctl -k --since "24 hours ago" --no-pager 2>/dev/null |
        grep -Eic 'error|fail|critical|panic|oops|watchdog|segfault|BUG:' || true)

    if (( kernel_errors == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "kernel_errors" \
            7 \
            "Kernel errors" \
            "No obvious kernel error/critical events detected in the last 24 hours." \
            "No action required."

    elif (( kernel_errors < 10 )); then

        check_warn \
            "$CURRENT_CATEGORY" \
            "kernel_errors" \
            7 \
            4 \
            "Kernel warnings/errors" \
            "$kernel_errors kernel error-like event(s) detected in the last 24 hours." \
            "Review recent kernel journal entries."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "kernel_errors" \
            8 \
            8 \
            "Repeated kernel errors" \
            "$kernel_errors kernel error-like events detected in the last 24 hours." \
            "Investigate kernel logs and affected hardware/drivers."

    fi

    local segfaults
    segfaults=$(journalctl --since "24 hours ago" --no-pager 2>/dev/null |
        grep -Eic 'segfault|general protection fault|core dumped' || true)

    if (( segfaults == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "segfaults" \
            5 \
            "Application crashes" \
            "No obvious segmentation-fault/core-dump events detected in the last 24 hours." \
            "No action required."

    elif (( segfaults < 3 )); then

        check_warn \
            "$CURRENT_CATEGORY" \
            "segfaults" \
            5 \
            3 \
            "Application crash events" \
            "$segfaults segmentation-fault/core-dump event(s) detected." \
            "Identify the affected application from the journal."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "segfaults" \
            6 \
            6 \
            "Repeated application crashes" \
            "$segfaults segmentation-fault/core-dump events detected." \
            "Investigate the crashing software and possible hardware/memory problems."

    fi

    local watchdog_events
    watchdog_events=$(journalctl -k --since "7 days ago" --no-pager 2>/dev/null |
        grep -Eic 'watchdog|soft lockup|hard lockup' || true)

    if (( watchdog_events == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "watchdog" \
            4 \
            "Watchdog/lockup events" \
            "No watchdog or CPU lockup events detected in the last 7 days." \
            "No action required."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "watchdog" \
            6 \
            6 \
            "Watchdog/lockup events" \
            "$watchdog_events watchdog/lockup event(s) detected in the last 7 days." \
            "Investigate kernel, thermal, power and hardware stability."

    fi

    local emergency
    emergency=$(journalctl -b --no-pager 2>/dev/null |
        grep -Eic 'emergency mode|Entering emergency mode' || true)

    if (( emergency == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "emergency_mode" \
            4 \
            "Emergency mode" \
            "No emergency-mode event detected during the current boot." \
            "No action required."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "emergency_mode" \
            7 \
            7 \
            "Emergency mode detected" \
            "The current boot contains an emergency-mode event." \
            "Investigate failed mounts, filesystem errors and systemd dependencies."

    fi

    local reboot_events
    reboot_events=$(journalctl --list-boots --no-pager 2>/dev/null |
        tail -n +2 |
        wc -l)

    if (( reboot_events > 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "boot_history" \
            2 \
            "Boot history" \
            "$reboot_events previous boot record(s) are available to analyse." \
            "No action required."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Boot history" \
            "Boot history unavailable." \
            "The journal does not contain multiple boot records."
    fi

    local unexpected
    unexpected=$(journalctl --list-boots --no-pager 2>/dev/null |
        grep -Eic 'shutdown|crash' || true)

    if (( unexpected == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "unexpected_shutdown" \
            4 \
            "Unexpected shutdown indicators" \
            "No obvious shutdown/crash indicators were found in available boot history." \
            "No action required."

    else

        check_warn \
            "$CURRENT_CATEGORY" \
            "unexpected_shutdown" \
            5 \
            3 \
            "Possible unexpected shutdowns" \
            "$unexpected possible shutdown/crash indicator(s) found." \
            "Review previous boot logs for the cause."

    fi
}

# ------------------------------------------------------------
# Network
# ------------------------------------------------------------

run_network_checks() {

    CURRENT_CATEGORY="Network"

    if ! command_exists ip; then

        check_skip \
            "$CURRENT_CATEGORY" \
            "network_interfaces" \
            "ip command is unavailable." \
            "Network diagnostics require iproute2."

        return
    fi

    local interfaces
    interfaces=$(ip -o link show 2>/dev/null |
        awk -F': ' '{print $2}' |
        sed 's/@.*//' |
        grep -v '^lo$' || true)

    if [[ -n "$interfaces" ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "interfaces" \
            3 \
            "Network interfaces" \
            "Detected network interface(s): $(echo "$interfaces" | tr '\n' ' ')." \
            "No action required."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "interfaces" \
            5 \
            5 \
            "No network interface" \
            "No non-loopback network interface was detected." \
            "Check network hardware and configuration."
    fi

    local active_interface=""
    active_interface=$(ip route show default 2>/dev/null |
        awk '/default/ {print $5; exit}')

    if [[ -n "$active_interface" ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "active_interface" \
            4 \
            "Default network interface" \
            "Default route uses $active_interface." \
            "No action required."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "active_interface" \
            5 \
            5 \
            "No default network route" \
            "No default route was detected." \
            "Check network configuration and gateway availability."
    fi

    local gateway
    gateway=$(ip route show default 2>/dev/null |
        awk '/default/ {print $3; exit}')

    if [[ -n "$gateway" ]]; then

        if command_exists ping; then

            if ping -c 2 -W 2 "$gateway" >/dev/null 2>&1; then

                check_pass \
                    "$CURRENT_CATEGORY" \
                    "gateway" \
                    5 \
                    "Gateway reachability" \
                    "Default gateway $gateway responded to ICMP." \
                    "No action required."

            else

                check_fail \
                    "$CURRENT_CATEGORY" \
                    "gateway" \
                    6 \
                    6 \
                    "Gateway unreachable" \
                    "Default gateway $gateway did not respond to ICMP." \
                    "Check the LAN connection and router."
            fi

        else

            check_skip \
                "$CURRENT_CATEGORY" \
                "Gateway reachability" \
                "ping is unavailable." \
                "Cannot test gateway reachability."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Gateway reachability" \
            "No gateway was detected." \
            "There is no default route to test."
    fi

    if command_exists ping; then

        if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "internet" \
                5 \
                "Internet connectivity" \
                "External connectivity test succeeded." \
                "No action required."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "internet" \
                6 \
                6 \
                "Internet connectivity failure" \
                "External ICMP connectivity test failed." \
                "Check the gateway, WAN connection and firewall."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Internet connectivity" \
            "ping is unavailable." \
            "Cannot perform an external connectivity test."
    fi

    local error_total=0

    for iface in $interfaces; do

        local rx_err rx_drop tx_err tx_drop

        rx_err=$(cat "/sys/class/net/$iface/statistics/rx_errors" 2>/dev/null || echo 0)
        rx_drop=$(cat "/sys/class/net/$iface/statistics/rx_dropped" 2>/dev/null || echo 0)
        tx_err=$(cat "/sys/class/net/$iface/statistics/tx_errors" 2>/dev/null || echo 0)
        tx_drop=$(cat "/sys/class/net/$iface/statistics/tx_dropped" 2>/dev/null || echo 0)

        error_total=$((error_total + rx_err + rx_drop + tx_err + tx_drop))

    done

    if (( error_total == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "packet_errors" \
            5 \
            "Network interface errors" \
            "No RX/TX errors or drops are currently reported by network interfaces." \
            "No action required."

    elif (( error_total < 20 )); then

        check_warn \
            "$CURRENT_CATEGORY" \
            "packet_errors" \
            5 \
            2 \
            "Network packet errors" \
            "$error_total RX/TX error/drop counter(s) detected." \
            "Monitor the interface for increasing errors."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "packet_errors" \
            6 \
            5 \
            "High network error counters" \
            "$error_total RX/TX error/drop counter(s) detected." \
            "Investigate cables, Wi-Fi signal, USB adapters or network hardware."
    fi
}

# ------------------------------------------------------------
# DNS / Pi-hole / Unbound
# ------------------------------------------------------------

run_dns_checks() {

    CURRENT_CATEGORY="DNS"

    local resolver=""
    resolver=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)

    if [[ -n "$resolver" ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "resolver" \
            3 \
            "DNS resolver configuration" \
            "Configured resolver: $resolver." \
            "No action required."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "resolver" \
            5 \
            5 \
            "No DNS resolver configured" \
            "No nameserver was found in /etc/resolv.conf." \
            "Configure a working DNS resolver."
    fi

    if command_exists dig; then

        local dns_result
        dns_result=$(dig +time=3 +tries=1 example.com 2>/dev/null |
            awk '/^example.com\./ && $4=="A" {print $5; exit}')

        if [[ "$dns_result" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "dns_resolution" \
                5 \
                "DNS resolution" \
                "example.com successfully resolved to $dns_result." \
                "No action required."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "dns_resolution" \
                6 \
                6 \
                "DNS resolution failure" \
                "example.com could not be resolved successfully." \
                "Check Pi-hole, Unbound, upstream DNS and /etc/resolv.conf."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "DNS resolution" \
            "dig is not installed." \
            "Install dnsutils/bind-utils for detailed DNS testing."
    fi

    if command_exists pihole; then

        if pihole status >/dev/null 2>&1; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "pihole" \
                6 \
                "Pi-hole service" \
                "Pi-hole reports a healthy/active status." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "pihole" \
                6 \
                4 \
                "Pi-hole status issue" \
                "Pi-hole is installed but its status command reported a problem." \
                "Run 'pihole status' for details."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Pi-hole" \
            "Pi-hole was not detected." \
            "This check is skipped on systems without Pi-hole."
    fi

    if command_exists systemctl && systemctl list-unit-files unbound.service >/dev/null 2>&1; then

        if systemctl is-active --quiet unbound; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "unbound" \
                6 \
                "Unbound service" \
                "Unbound is active." \
                "No action required."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "unbound" \
                6 \
                6 \
                "Unbound inactive" \
                "Unbound is installed but not active." \
                "Check 'systemctl status unbound' and its logs."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Unbound" \
            "Unbound service was not detected." \
            "This check is skipped when Unbound is not installed."
    fi
}

# ------------------------------------------------------------
# WireGuard / VPN
# ------------------------------------------------------------

run_vpn_checks() {

    CURRENT_CATEGORY="VPN"

    if ! command_exists wg; then

        check_skip \
            "$CURRENT_CATEGORY" \
            "wireguard" \
            "WireGuard tools are not installed." \
            "This check is skipped when WireGuard is unavailable."

        return
    fi

    local interfaces
    interfaces=$(wg show interfaces 2>/dev/null || true)

    if [[ -n "$interfaces" ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "wireguard_interface" \
            5 \
            "WireGuard interface" \
            "WireGuard interface(s): $interfaces." \
            "No action required."

        local peer_count
        peer_count=$(wg show all latest-handshakes 2>/dev/null |
            awk 'NF >= 3 {print}' |
            wc -l)

        if (( peer_count == 0 )); then

            check_warn \
                "$CURRENT_CATEGORY" \
                "wireguard_peers" \
                4 \
                2 \
                "No WireGuard handshakes" \
                "WireGuard is configured but no peer handshake records were found." \
                "Check peer configuration and connectivity."

        else

            local now
            now=$(date +%s)

            local stale=0

            while read -r iface pubkey handshake; do

                [[ -z "$handshake" || "$handshake" == "0" ]] && continue

                local age=$((now - handshake))

                if (( age > 86400 )); then
                    stale=$((stale + 1))
                fi

            done < <(wg show all latest-handshakes 2>/dev/null)

            if (( stale == 0 )); then

                check_pass \
                    "$CURRENT_CATEGORY" \
                    "wireguard_handshakes" \
                    5 \
                    "WireGuard peer activity" \
                    "WireGuard peer handshakes appear recent." \
                    "No action required."

            else

                check_warn \
                    "$CURRENT_CATEGORY" \
                    "wireguard_handshakes" \
                    5 \
                    3 \
                    "Stale WireGuard peers" \
                    "$stale WireGuard peer(s) have not handshaken recently." \
                    "Check the affected peers and network connectivity."
            fi
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "WireGuard interface" \
            "No active WireGuard interface detected." \
            "WireGuard may be installed but inactive."
    fi
}

# ------------------------------------------------------------
# Security
# ------------------------------------------------------------

run_security_checks() {

    CURRENT_CATEGORY="Security"

    if command_exists sshd; then

        local ssh_config
        ssh_config=$(sshd -T 2>/dev/null || true)

        if grep -q '^permitrootlogin no' <<< "$ssh_config"; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "ssh_root" \
                5 \
                "SSH root login" \
                "SSH root login is disabled." \
                "No action required."

        elif grep -q '^permitrootlogin prohibit-password' <<< "$ssh_config"; then

            check_warn \
                "$CURRENT_CATEGORY" \
                "ssh_root" \
                5 \
                2 \
                "SSH root key login permitted" \
                "SSH root login is restricted but not fully disabled." \
                "Disable root SSH login unless it is specifically required."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "ssh_root" \
                6 \
                6 \
                "SSH root login enabled" \
                "SSH configuration allows root login." \
                "Set PermitRootLogin no unless root SSH access is intentionally required."
        fi

        if grep -q '^passwordauthentication no' <<< "$ssh_config"; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "ssh_password" \
                4 \
                "SSH password authentication" \
                "SSH password authentication is disabled." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "ssh_password" \
                4 \
                2 \
                "SSH password authentication enabled" \
                "SSH accepts password authentication." \
                "Consider disabling password authentication and using SSH keys."
        fi

        local ssh_port
        ssh_port=$(awk '$1=="port" {print $2; exit}' <<< "$ssh_config")

        if [[ "$ssh_port" == "22" ]]; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "ssh_port" \
                2 \
                "SSH port" \
                "SSH is configured on the standard port 22." \
                "Changing the port is optional and is not a replacement for proper authentication."

        elif [[ "$ssh_port" =~ ^[0-9]+$ ]]; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "ssh_port" \
                2 \
                "SSH port" \
                "SSH listens on port $ssh_port." \
                "No action required."

        else

            check_skip \
                "$CURRENT_CATEGORY" \
                "SSH port" \
                "Unable to determine SSH port." \
                "sshd configuration could not be parsed."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "SSH configuration" \
            "OpenSSH server was not detected." \
            "SSH checks are skipped when sshd is unavailable."
    fi

    if command_exists ufw; then

        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1)

        if grep -qi "active" <<< "$ufw_status"; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "firewall" \
                6 \
                "Firewall" \
                "UFW firewall is active." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "firewall" \
                6 \
                4 \
                "UFW firewall inactive" \
                "UFW is installed but does not report active." \
                "Enable an appropriate firewall if another firewall is not already protecting the host."
        fi

    elif command_exists nft; then

        local nft_rules
        nft_rules=$(nft list ruleset 2>/dev/null | wc -l)

        if (( nft_rules > 0 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "firewall" \
                6 \
                "Firewall rules" \
                "nftables has an active ruleset." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "firewall" \
                6 \
                4 \
                "No nftables rules detected" \
                "nft is installed but its ruleset appears empty." \
                "Verify whether another firewall is protecting the system."
        fi

    elif command_exists iptables; then

        local iptables_rules
        iptables_rules=$(iptables -S 2>/dev/null | wc -l)

        if (( iptables_rules > 1 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "firewall" \
                6 \
                "Firewall rules" \
                "iptables rules are present." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "firewall" \
                6 \
                4 \
                "Minimal firewall configuration" \
                "iptables has little or no filtering configuration." \
                "Verify whether another firewall is active."
        fi

    else

        check_warn \
            "$CURRENT_CATEGORY" \
            "firewall" \
            6 \
            4 \
            "No firewall tool detected" \
            "No supported firewall management tool was detected." \
            "Consider configuring a suitable firewall for exposed services."
    fi

    if command_exists fail2ban-client; then

        if fail2ban-client ping >/dev/null 2>&1; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "fail2ban" \
                4 \
                "Fail2ban" \
                "Fail2ban is responding." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "fail2ban" \
                4 \
                2 \
                "Fail2ban unavailable" \
                "Fail2ban is installed but not responding." \
                "Check the fail2ban service."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Fail2ban" \
            "Fail2ban is not installed." \
            "This is optional."
    fi

    local auth_failures
    auth_failures=$(journalctl --since "24 hours ago" --no-pager 2>/dev/null |
        grep -Eic 'authentication failure|Failed password|Invalid user|Failed publickey' || true)

    if (( auth_failures == 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "auth_failures" \
            5 \
            "Authentication failures" \
            "No obvious failed-authentication events were detected in the last 24 hours." \
            "No action required."

    elif (( auth_failures < 20 )); then

        check_warn \
            "$CURRENT_CATEGORY" \
            "auth_failures" \
            5 \
            2 \
            "Authentication failures detected" \
            "$auth_failures authentication failure event(s) detected in the last 24 hours." \
            "Check login sources and SSH exposure."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "auth_failures" \
            6 \
            6 \
            "High authentication failure activity" \
            "$auth_failures authentication failure event(s) detected in the last 24 hours." \
            "Investigate source addresses and secure externally exposed authentication."
    fi
}

# ------------------------------------------------------------
# Software / updates
# ------------------------------------------------------------

run_software_checks() {

    CURRENT_CATEGORY="Software & Updates"

    if command_exists dpkg; then

        local dpkg_errors
        dpkg_errors=$(dpkg --audit 2>/dev/null | wc -l)

        if (( dpkg_errors == 0 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "dpkg" \
                5 \
                "Package database" \
                "dpkg reports no incomplete package configuration." \
                "No action required."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "dpkg" \
                6 \
                6 \
                "Package database issue" \
                "dpkg --audit returned $dpkg_errors line(s) of output." \
                "Run 'sudo dpkg --configure -a' and resolve package issues."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Package database" \
            "dpkg is unavailable." \
            "This system may not be Debian-based."
    fi

    if command_exists apt; then

        local updates
        updates=$(apt list --upgradable 2>/dev/null |
            grep -v '^Listing' |
            grep -c '/' || true)

        if (( updates == 0 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "updates" \
                4 \
                "Available updates" \
                "No package updates are currently reported." \
                "No action required."

        elif (( updates < 20 )); then

            check_warn \
                "$CURRENT_CATEGORY" \
                "updates" \
                4 \
                2 \
                "Updates available" \
                "$updates package update(s) are available." \
                "Review and install updates when appropriate."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "updates" \
                5 \
                3 \
                "Many updates available" \
                "$updates package update(s) are available." \
                "Schedule system updates and reboot if required."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Package updates" \
            "apt is unavailable." \
            "Cannot determine Debian package updates."
    fi

    if [[ -f /var/run/reboot-required ]]; then

        check_warn \
            "$CURRENT_CATEGORY" \
            "reboot_required" \
            5 \
            3 \
            "Reboot required" \
            "The system has marked itself as requiring a reboot." \
            "Schedule a reboot when convenient."

    else

        check_pass \
            "$CURRENT_CATEGORY" \
            "reboot_required" \
            3 \
            "Reboot requirement" \
            "No reboot-required flag is present." \
            "No action required."
    fi

    local kernel
    kernel=$(uname -r 2>/dev/null || true)

    if [[ -n "$kernel" ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "kernel_version" \
            2 \
            "Kernel version" \
            "Running kernel: $kernel." \
            "No action required."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Kernel version" \
            "Kernel version unavailable." \
            "uname did not return a kernel version."
    fi

    if command_exists timedatectl; then

        local ntp
        ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)

        if [[ "$ntp" == "yes" ]]; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "time_sync" \
                4 \
                "Time synchronization" \
                "System clock is synchronized." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "time_sync" \
                4 \
                2 \
                "Clock not synchronized" \
                "timedatectl reports that the system clock is not synchronized." \
                "Check NTP/systemd-timesyncd/chrony configuration."
        fi

        local timezone
        timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)

        if [[ -n "$timezone" ]]; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "timezone" \
                2 \
                "Timezone configuration" \
                "Timezone: $timezone." \
                "No action required."

        else

            check_skip \
                "$CURRENT_CATEGORY" \
                "Timezone" \
                "Timezone unavailable." \
                "timedatectl did not provide timezone information."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Time synchronization" \
            "timedatectl is unavailable." \
            "Cannot inspect system time synchronization."
    fi
}

# ------------------------------------------------------------
# Processes
# ------------------------------------------------------------

run_process_checks() {

    CURRENT_CATEGORY="Processes & Reliability"

    if command_exists ps; then

        local process_count
        process_count=$(ps -e --no-headers 2>/dev/null | wc -l)

        if (( process_count > 0 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "process_count" \
                2 \
                "Process count" \
                "$process_count processes are currently running." \
                "No action required."

        else

            check_skip \
                "$CURRENT_CATEGORY" \
                "Process count" \
                "Unable to determine process count." \
                "ps returned no usable data."
        fi

        local zombies
        zombies=$(ps -eo stat= 2>/dev/null |
            grep -c '^Z' || true)

        if (( zombies == 0 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "zombies" \
                4 \
                "Zombie processes" \
                "No zombie processes detected." \
                "No action required."

        elif (( zombies < 5 )); then

            check_warn \
                "$CURRENT_CATEGORY" \
                "zombies" \
                4 \
                2 \
                "Zombie processes detected" \
                "$zombies zombie process(es) detected." \
                "Identify the parent processes and investigate why they are not reaping children."

        else

            check_fail \
                "$CURRENT_CATEGORY" \
                "zombies" \
                5 \
                5 \
                "Many zombie processes" \
                "$zombies zombie process(es) detected." \
                "Investigate parent processes and application behaviour."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Process analysis" \
            "ps is unavailable." \
            "Cannot inspect running processes."
    fi

    if [[ -r /proc/pressure/cpu ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "cpu_psi" \
            2 \
            "CPU pressure statistics" \
            "Kernel CPU pressure statistics are available." \
            "No action required."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "CPU pressure" \
            "CPU pressure statistics unavailable." \
            "Kernel PSI is not exposed."
    fi

    if command_exists systemctl; then

        local core_dump
        core_dump=$(journalctl --since "7 days ago" --no-pager 2>/dev/null |
            grep -Eic 'core dumped' || true)

        if (( core_dump == 0 )); then

            check_pass \
                "$CURRENT_CATEGORY" \
                "core_dumps" \
                5 \
                "Core dumps" \
                "No core-dump events detected in the last 7 days." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "core_dumps" \
                5 \
                3 \
                "Core dumps detected" \
                "$core_dump core-dump event(s) detected in the last 7 days." \
                "Identify the crashing process and investigate."
        fi

    fi
}

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

run_configuration_checks() {

    CURRENT_CATEGORY="Configuration"

    if [[ -n "$(hostname 2>/dev/null)" ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "hostname" \
            2 \
            "Hostname configuration" \
            "Hostname: $(hostname)." \
            "No action required."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Hostname" \
            "Hostname unavailable." \
            "hostname command did not return a value."
    fi

    if [[ -f /etc/resolv.conf ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "resolv_conf" \
            2 \
            "Resolver configuration file" \
            "/etc/resolv.conf exists." \
            "No action required."

    else

        check_fail \
            "$CURRENT_CATEGORY" \
            "resolv_conf" \
            4 \
            4 \
            "Missing resolver configuration" \
            "/etc/resolv.conf does not exist." \
            "Restore a valid resolver configuration."
    fi

    if [[ -f /etc/fstab ]]; then

        check_pass \
            "$CURRENT_CATEGORY" \
            "fstab_exists" \
            2 \
            "fstab configuration" \
            "/etc/fstab exists." \
            "No action required."

    else

        check_warn \
            "$CURRENT_CATEGORY" \
            "fstab_exists" \
            2 \
            1 \
            "Missing fstab" \
            "/etc/fstab does not exist." \
            "Verify whether this system intentionally uses another mount configuration mechanism."
    fi

    if [[ -d /etc/systemd/system ]]; then

        local custom_units
        custom_units=$(find /etc/systemd/system \
            -maxdepth 1 \
            -type f \
            -name '*.service' \
            2>/dev/null |
            wc -l)

        check_pass \
            "$CURRENT_CATEGORY" \
            "custom_unit_files" \
            2 \
            "Custom systemd configuration" \
            "$custom_units custom service file(s) found in /etc/systemd/system." \
            "No action required."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Custom systemd files" \
            "/etc/systemd/system is unavailable." \
            "Systemd configuration directory is missing."
    fi
}

# ------------------------------------------------------------
# Application-aware checks
# ------------------------------------------------------------

run_application_checks() {

    CURRENT_CATEGORY="Applications"

    if command_exists docker; then

        if systemctl is-active --quiet docker 2>/dev/null; then

            local containers
            containers=$(docker ps -a --format '{{.ID}}' 2>/dev/null | wc -l)

            check_pass \
                "$CURRENT_CATEGORY" \
                "docker" \
                4 \
                "Docker" \
                "Docker is active with $containers container(s)." \
                "No action required."

            local stopped
            stopped=$(docker ps -a --filter status=exited --format '{{.ID}}' 2>/dev/null | wc -l)

            if (( stopped == 0 )); then

                check_pass \
                    "$CURRENT_CATEGORY" \
                    "docker_containers" \
                    4 \
                    "Docker containers" \
                    "No exited Docker containers were detected." \
                    "No action required."

            else

                check_warn \
                    "$CURRENT_CATEGORY" \
                    "docker_containers" \
                    4 \
                    2 \
                    "Exited Docker containers" \
                    "$stopped exited container(s) detected." \
                    "Review whether exited containers are expected."

            fi

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "docker" \
                4 \
                3 \
                "Docker inactive" \
                "Docker is installed but its service is not active." \
                "Start Docker if it is expected to be running."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Docker" \
            "Docker was not detected." \
            "This check is skipped when Docker is not installed."
    fi

    if command_exists caddy; then

        if command_exists systemctl && systemctl is-active --quiet caddy 2>/dev/null; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "caddy" \
                4 \
                "Caddy" \
                "Caddy is installed and active." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "caddy" \
                4 \
                2 \
                "Caddy inactive" \
                "Caddy is installed but is not currently active." \
                "Check whether Caddy is intentionally stopped."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Caddy" \
            "Caddy was not detected." \
            "This check is skipped when Caddy is not installed."
    fi

    if command_exists tailscale; then

        if tailscale status >/dev/null 2>&1; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "tailscale" \
                4 \
                "Tailscale" \
                "Tailscale is responding normally." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "tailscale" \
                4 \
                2 \
                "Tailscale status issue" \
                "Tailscale is installed but did not return a healthy status." \
                "Check 'tailscale status' and the Tailscale service."

        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Tailscale" \
            "Tailscale was not detected." \
            "This check is skipped when Tailscale is not installed."
    fi

    if command_exists mosquitto_pub || command_exists mosquitto_sub; then

        if command_exists systemctl && systemctl is-active --quiet mosquitto 2>/dev/null; then

            check_pass \
                "$CURRENT_CATEGORY" \
                "mosquitto" \
                3 \
                "Mosquitto" \
                "Mosquitto appears to be active." \
                "No action required."

        else

            check_warn \
                "$CURRENT_CATEGORY" \
                "mosquitto" \
                3 \
                2 \
                "Mosquitto inactive" \
                "MQTT tooling is installed but the Mosquitto service is not active." \
                "Check whether Mosquitto is intentionally stopped."
        fi

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Mosquitto" \
            "Mosquitto tooling was not detected." \
            "This check is skipped when MQTT software is not installed."
    fi
}

# ------------------------------------------------------------
# Network interface reliability
# ------------------------------------------------------------

run_network_reliability_checks() {

    CURRENT_CATEGORY="Network Reliability"

    if ! command_exists ip; then

        check_skip \
            "$CURRENT_CATEGORY" \
            "Interface reliability" \
            "ip command unavailable." \
            "Cannot inspect network statistics."

        return
    fi

    local interfaces
    interfaces=$(ip -o link show 2>/dev/null |
        awk -F': ' '{print $2}' |
        sed 's/@.*//' |
        grep -v '^lo$' || true)

    local total_rx=0
    local total_tx=0

    for iface in $interfaces; do

        local rx_bytes tx_bytes

        rx_bytes=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
        tx_bytes=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)

        total_rx=$((total_rx + rx_bytes))
        total_tx=$((total_tx + tx_bytes))

    done

    if (( total_rx > 0 || total_tx > 0 )); then

        check_pass \
            "$CURRENT_CATEGORY" \
            "network_traffic" \
            2 \
            "Network traffic statistics" \
            "Network interfaces report RX=${total_rx} bytes and TX=${total_tx} bytes." \
            "No action required."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Network traffic" \
            "No network traffic counters were available." \
            "Interfaces may be inactive."
    fi

    if command_exists ss; then

        local listening
        listening=$(ss -lntu 2>/dev/null | tail -n +2 | wc -l)

        check_pass \
            "$CURRENT_CATEGORY" \
            "listening_sockets" \
            4 \
            "Listening sockets" \
            "$listening listening TCP/UDP socket(s) detected." \
            "Review the security screen for exposed services."

    else

        check_skip \
            "$CURRENT_CATEGORY" \
            "Listening sockets" \
            "ss is unavailable." \
            "Cannot inspect listening sockets."
    fi
}

# ------------------------------------------------------------
# Scan engine
# ------------------------------------------------------------

run_full_scan() {

    : > "$RESULT_FILE"
    : > "$ISSUE_FILE"
    : > "$SKIP_FILE"

    TOTAL_POSSIBLE=0
    TOTAL_APPLICABLE=0
    TOTAL_PASS=0
    TOTAL_WARN=0
    TOTAL_FAIL=0
    TOTAL_SKIP=0
    OVERALL_DEDUCTIONS=0
    OVERALL_WEIGHT=0

    (
        clear

        echo "PiTweaks Health Score V${VERSION}"
        echo
        echo "Running adaptive diagnostic scan..."
        echo
        echo "This may take a little while."
        echo
    )

    run_cpu_checks
    run_power_checks
    run_memory_checks
    run_storage_checks
    run_service_checks
    run_boot_checks
    run_network_checks
    run_dns_checks
    run_vpn_checks
    run_security_checks
    run_software_checks
    run_process_checks
    run_configuration_checks
    run_application_checks
    run_network_reliability_checks

    calculate_score

    generate_summary
}

# ------------------------------------------------------------
# Summary generation
# ------------------------------------------------------------

generate_summary() {

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "============================================================"
        echo " PiTweaks Health Score V${VERSION}"
        echo "============================================================"
        echo
        echo "DATE        : $now"
        echo "HOSTNAME    : $(hostname 2>/dev/null || echo Unknown)"
        echo "KERNEL      : $(uname -r 2>/dev/null || echo Unknown)"
        echo
        echo "OVERALL SCORE : ${SCORE}/100"
        echo "GRADE         : ${GRADE}"
        echo "CONFIDENCE    : ${CONFIDENCE}%"
        echo
        echo "PASS          : ${TOTAL_PASS}"
        echo "WARN          : ${TOTAL_WARN}"
        echo "FAIL          : ${TOTAL_FAIL}"
        echo "SKIP          : ${TOTAL_SKIP}"
        echo
        echo "APPLICABLE    : ${TOTAL_APPLICABLE}"
        echo "POTENTIAL     : ${TOTAL_POSSIBLE}"
        echo
        echo "------------------------------------------------------------"
        echo "CATEGORY SCORES"
        echo "------------------------------------------------------------"
        echo

        local categories=(
            "CPU"
            "Power & Thermal"
            "Memory"
            "Storage"
            "Services"
            "Boot & Reliability"
            "Network"
            "DNS"
            "VPN"
            "Security"
            "Software & Updates"
            "Processes & Reliability"
            "Configuration"
            "Applications"
            "Network Reliability"
        )

        for category in "${categories[@]}"; do
            printf '%-25s %s/100\n' \
                "$category" \
                "$(category_score "$category")"
        done

        echo
        echo "============================================================"

    } > "$SUMMARY_FILE"
}

# ------------------------------------------------------------
# Score display
# ------------------------------------------------------------

show_score() {

    calculate_score

    local bar=""
    local i

    for ((i=0; i<20; i++)); do

        if (( i * 5 < SCORE )); then
            bar+="#"
        else
            bar+="."
        fi

    done

    local message=""

    message+="OVERALL HEALTH SCORE
"
    message+="====================

"
    message+="SCORE       ${SCORE}/100
"
    message+="GRADE       ${GRADE}
"
    message+="CONFIDENCE  ${CONFIDENCE}%

"
    message+="[${bar}]

"
    message+="PASS        ${TOTAL_PASS}
"
    message+="WARN        ${TOTAL_WARN}
"
    message+="FAIL        ${TOTAL_FAIL}
"
    message+="SKIPPED     ${TOTAL_SKIP}

"

    if (( TOTAL_FAIL > 0 )); then
        message+="Critical failures detected.
Use WHY to see exactly what reduced the score."
    elif (( TOTAL_WARN > 0 )); then
        message+="Warnings detected.
Use WHY to review recommended improvements."
    else
        message+="No significant issues detected."
    fi

    show_message "$message" 22 70
}

# ------------------------------------------------------------
# Why score
# ------------------------------------------------------------

show_why() {

    if [[ ! -s "$ISSUE_FILE" ]]; then

        show_message \
            "No deductions were recorded.

Your current score has no WARN or FAIL deductions." \
            12 65

        return
    fi

    local why_file="${TMP_DIR}/why.txt"

    {
        echo "WHY IS MY SCORE ${SCORE}/100?"
        echo "========================================"
        echo
        echo "The following checks reduced the score:"
        echo

        while IFS='|' read -r category status deduction title explanation recommendation; do

            [[ -z "$title" ]] && continue

            echo "[$status] $title"
            echo "Category    : $category"
            echo "Deduction   : -${deduction} points"
            echo "Finding     : $explanation"
            echo "Recommendation:"
            echo "  $recommendation"
            echo
            echo "----------------------------------------"
            echo

        done < "$ISSUE_FILE"

        echo
        echo "The score is severity-weighted."
        echo "Critical problems receive larger deductions than informational warnings."

    } > "$why_file"

    show_text "$why_file" "Why?"
}

# ------------------------------------------------------------
# Category view
# ------------------------------------------------------------

show_categories() {

    local category_file="${TMP_DIR}/category_view.txt"

    {
        echo "CATEGORY HEALTH"
        echo "================"
        echo

        local categories=(
            "CPU"
            "Power & Thermal"
            "Memory"
            "Storage"
            "Services"
            "Boot & Reliability"
            "Network"
            "DNS"
            "VPN"
            "Security"
            "Software & Updates"
            "Processes & Reliability"
            "Configuration"
            "Applications"
            "Network Reliability"
        )

        for category in "${categories[@]}"; do

            local score
            score=$(category_score "$category")

            echo "$category"
            echo "Score: ${score}/100"
            echo

            while IFS='|' read -r cat id status weight deduction title explanation recommendation; do

                [[ "$cat" != "$category" ]] && continue

                case "$status" in
                    PASS)
                        echo "  [PASS] $title"
                        ;;
                    WARN)
                        echo "  [WARN] $title (-${deduction})"
                        ;;
                    FAIL)
                        echo "  [FAIL] $title (-${deduction})"
                        ;;
                esac

            done < "$RESULT_FILE"

            echo
            echo "----------------------------------------"
            echo

        done

    } > "$category_file"

    show_text "$category_file" "Categories"
}

# ------------------------------------------------------------
# Detailed results
# ------------------------------------------------------------

show_all_results() {

    local result_view="${TMP_DIR}/all_results.txt"

    {
        echo "FULL HEALTH CHECK RESULTS"
        echo "=========================="
        echo

        while IFS='|' read -r category id status weight deduction title explanation recommendation; do

            case "$status" in

                PASS)
                    echo "[PASS] $category | $title"
                    echo "       $explanation"
                    ;;

                WARN)
                    echo "[WARN] $category | $title"
                    echo "       Deduction: -${deduction}"
                    echo "       $explanation"
                    echo "       Fix: $recommendation"
                    ;;

                FAIL)
                    echo "[FAIL] $category | $title"
                    echo "       Deduction: -${deduction}"
                    echo "       $explanation"
                    echo "       Fix: $recommendation"
                    ;;

            esac

            echo

        done < "$RESULT_FILE"

    } > "$result_view"

    show_text "$result_view" "All Results"
}

# ------------------------------------------------------------
# Skipped checks
# ------------------------------------------------------------

show_skipped() {

    if [[ ! -s "$SKIP_FILE" ]]; then

        show_message \
            "No checks were skipped." \
            10 60

        return
    fi

    local skipped_file="${TMP_DIR}/skipped_view.txt"

    {
        echo "SKIPPED / NOT APPLICABLE CHECKS"
        echo "================================"
        echo
        echo "These checks were intentionally excluded because"
        echo "the required hardware, software or interface was absent."
        echo

        while IFS='|' read -r category title explanation; do

            echo "[$category]"
            echo "$title"
            echo "$explanation"
            echo
            echo "----------------------------------------"
            echo

        done < "$SKIP_FILE"

    } > "$skipped_file"

    show_text "$skipped_file" "Skipped Checks"
}

# ------------------------------------------------------------
# Boot analysis
# ------------------------------------------------------------

show_boot_analysis() {

    local boot_file="${TMP_DIR}/boot_analysis.txt"

    {
        echo "BOOT ANALYSIS"
        echo "============="
        echo

        if command_exists systemd-analyze; then

            echo "SYSTEMD ANALYZE"
            echo "---------------"
            systemd-analyze 2>&1
            echo

            echo "CRITICAL CHAIN"
            echo "--------------"
            systemd-analyze critical-chain 2>&1
            echo

            echo "SLOWEST SERVICES"
            echo "----------------"
            systemd-analyze blame 2>&1 | head -30
            echo

        else

            echo "systemd-analyze is unavailable."

        fi

    } > "$boot_file"

    show_text "$boot_file" "Boot Analysis"
}

# ------------------------------------------------------------
# Listening ports
# ------------------------------------------------------------

show_ports() {

    local port_file="${TMP_DIR}/ports.txt"

    {
        echo "LISTENING PORTS"
        echo "==============="
        echo

        if command_exists ss; then

            ss -lntup 2>&1

            echo
            echo "Interpretation:"
            echo "  127.0.0.1 / ::1 = local-only"
            echo "  0.0.0.0 / ::     = potentially externally reachable"
            echo
            echo "Review each exposed service and ensure it is intentional."

        else

            echo "ss is unavailable."

        fi

    } > "$port_file"

    show_text "$port_file" "Listening Ports"
}

# ------------------------------------------------------------
# Main menu
# ------------------------------------------------------------

main_menu() {

    while true; do

        calculate_score

        local failed_count="$TOTAL_FAIL"
        local warning_count="$TOTAL_WARN"

        local header=""

        header+="SCORE       ${SCORE}/100"
        header+=$'\n'
        header+="GRADE       ${GRADE}"
        header+=$'\n'
        header+="CONFIDENCE  ${CONFIDENCE}%"
        header+=$'\n'
        header+=$'\n'
        header+="PASS        ${TOTAL_PASS}"
        header+=$'\n'
        header+="WARN        ${warning_count}"
        header+=$'\n'
        header+="FAIL        ${failed_count}"
        header+=$'\n'
        header+="SKIP        ${TOTAL_SKIP}"
        header+=$'\n'
        header+=$'\n'

        if (( TOTAL_APPLICABLE == 0 )); then
            header+="No scan has been completed."
        else
            header+="Select an option."
        fi

        local selection

        selection=$(whiptail \
            --backtitle "PiTweaks | Raspberry Pi Toolkit" \
            --title "$TITLE V${VERSION}" \
            --menu \
            "$header" \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            12 \
            "SCAN" \
            "Run full adaptive health scan" \
            "SCORE" \
            "View overall score" \
            "WHY" \
            "See exactly what reduced the score" \
            "CATEGORIES" \
            "View category health scores" \
            "RESULTS" \
            "View every completed check" \
            "SKIPPED" \
            "View skipped/not-applicable checks" \
            "BOOT" \
            "Boot and systemd analysis" \
            "PORTS" \
            "View listening network ports" \
            "REFRESH" \
            "Run the scan again" \
            "EXIT" \
            "Exit Health Score" \
            3>&1 1>&2 2>&3) || break

        case "$selection" in

            SCAN)
                run_full_scan
                show_score
                ;;

            SCORE)
                if (( TOTAL_APPLICABLE == 0 )); then
                    show_message \
                        "No scan has been completed yet.

Select SCAN first." \
                        10 60
                else
                    show_score
                fi
                ;;

            WHY)
                if (( TOTAL_APPLICABLE == 0 )); then
                    show_message \
                        "No scan has been completed yet.

Select SCAN first." \
                        10 60
                else
                    show_why
                fi
                ;;

            CATEGORIES)
                if (( TOTAL_APPLICABLE == 0 )); then
                    show_message \
                        "No scan has been completed yet.

Select SCAN first." \
                        10 60
                else
                    show_categories
                fi
                ;;

            RESULTS)
                if (( TOTAL_APPLICABLE == 0 )); then
                    show_message \
                        "No scan has been completed yet.

Select SCAN first." \
                        10 60
                else
                    show_all_results
                fi
                ;;

            SKIPPED)
                if (( TOTAL_POSSIBLE == 0 )); then
                    show_message \
                        "No scan has been completed yet.

Select SCAN first." \
                        10 60
                else
                    show_skipped
                fi
                ;;

            BOOT)
                if command_exists systemd-analyze; then
                    show_boot_analysis
                else
                    show_message \
                        "systemd-analyze is unavailable on this system." \
                        10 65
                fi
                ;;

            PORTS)
                show_ports
                ;;

            REFRESH)
                run_full_scan
                show_score
                ;;

            EXIT)
                break
                ;;

        esac

    done
}

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------

main_menu

clear
exit 0
