#!/bin/bash

# Description: Adaptive Raspberry Pi Health Scoring & Diagnostic Utility
# PERSISTENT: FALSE
# Category: Diagnostics

# PiTweaks - Health Score
# Healthscore.sh
#
# Runs a broad set of health, reliability, configuration, networking,
# storage, security, service, power and software diagnostics.
#
# The checker is adaptive:
#   - Tests are only scored when applicable.
#   - Missing optional software is not treated as a failure.
#   - Every deduction has a reason.
#   - Results are grouped by category.
#
# Requirements:
#   - bash
#   - whiptail
#   - common Linux utilities
#
# Optional utilities:
#   - vcgencmd
#   - smartctl
#   - ip
#   - ss
#   - systemctl
#   - journalctl
#   - timedatectl
#   - systemd-analyze
#   - ufw
#   - nft
#   - iptables
#   - fail2ban-client
#   - wg
#   - docker
#   - pihole
#   - unbound-checkconf
# ============================================================

set -u
export LC_ALL=C

SCRIPT_NAME="Pi Health Score"
VERSION="1.0"

TMP_DIR="/tmp/pitweaks_healthscore_$$"
RESULT_FILE="${TMP_DIR}/results"
DETAIL_FILE="${TMP_DIR}/details"
SKIP_FILE="${TMP_DIR}/skipped"

mkdir -p "$TMP_DIR"
touch "$RESULT_FILE" "$DETAIL_FILE" "$SKIP_FILE"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------

if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail is required."
    exit 1
fi

# ------------------------------------------------------------
# GLOBAL SCORE DATA
# ------------------------------------------------------------

TOTAL_POINTS=0
MAX_POINTS=0
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

CURRENT_CATEGORY="General"

# category totals
declare -A CAT_SCORE
declare -A CAT_MAX
declare -A CAT_PASS
declare -A CAT_WARN
declare -A CAT_FAIL

# ------------------------------------------------------------
# TERMINAL
# ------------------------------------------------------------

TERM_WIDTH=$(tput cols 2>/dev/null || echo 100)
TERM_HEIGHT=$(tput lines 2>/dev/null || echo 30)

(( TERM_WIDTH < 80 )) && TERM_WIDTH=80
(( TERM_HEIGHT < 24 )) && TERM_HEIGHT=24

# ------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

add_category() {
    local category="$1"

    [[ -z "${CAT_SCORE[$category]+x}" ]] && CAT_SCORE["$category"]=0
    [[ -z "${CAT_MAX[$category]+x}" ]] && CAT_MAX["$category"]=0
    [[ -z "${CAT_PASS[$category]+x}" ]] && CAT_PASS["$category"]=0
    [[ -z "${CAT_WARN[$category]+x}" ]] && CAT_WARN["$category"]=0
    [[ -z "${CAT_FAIL[$category]+x}" ]] && CAT_FAIL["$category"]=0
}

set_category() {
    CURRENT_CATEGORY="$1"
    add_category "$CURRENT_CATEGORY"
}

record_check() {
    local status="$1"
    local points="$2"
    local max_points="$3"
    local name="$4"
    local explanation="$5"

    (( MAX_POINTS += max_points ))

    local actual_points="$points"

    if (( points < 0 )); then
        actual_points=0
    fi

    (( TOTAL_POINTS += actual_points ))

    add_category "$CURRENT_CATEGORY"
    (( CAT_MAX["$CURRENT_CATEGORY"] += max_points ))
    (( CAT_SCORE["$CURRENT_CATEGORY"] += actual_points ))

    case "$status" in
        PASS)
            (( PASS_COUNT += 1 ))
            (( CAT_PASS["$CURRENT_CATEGORY"] += 1 ))
            ;;
        WARN)
            (( WARN_COUNT += 1 ))
            (( CAT_WARN["$CURRENT_CATEGORY"] += 1 ))
            ;;
        FAIL)
            (( FAIL_COUNT += 1 ))
            (( CAT_FAIL["$CURRENT_CATEGORY"] += 1 ))
            ;;
    esac

    printf '%s|%s|%s|%s|%s\n' \
        "$status" \
        "$CURRENT_CATEGORY" \
        "$actual_points" \
        "$max_points" \
        "$name" >> "$RESULT_FILE"

    printf '%s|%s|%s\n' \
        "$status" \
        "$name" \
        "$explanation" >> "$DETAIL_FILE"
}

skip_check() {
    local name="$1"
    local reason="$2"

    (( SKIP_COUNT += 1 ))
    printf '%s|%s\n' "$name" "$reason" >> "$SKIP_FILE"
}

pass() {
    record_check "PASS" "$2" "$2" "$1" "$3"
}

warn() {
    record_check "WARN" "$2" "$2" "$1" "$3"
}

fail() {
    record_check "FAIL" "$2" "$2" "$1" "$3"
}

partial() {
    record_check "WARN" "$2" "$3" "$1" "$4"
}

# ------------------------------------------------------------
# SYSTEM INFORMATION
# ------------------------------------------------------------

HOSTNAME_VALUE=$(hostname 2>/dev/null || echo "Unknown")
KERNEL_VERSION=$(uname -r 2>/dev/null || echo "Unknown")
ARCH=$(uname -m 2>/dev/null || echo "Unknown")

OS_NAME="Unknown"
OS_VERSION="Unknown"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-${NAME:-Unknown}}"
    OS_VERSION="${VERSION_ID:-Unknown}"
fi

# ------------------------------------------------------------
# CPU CHECKS
# ------------------------------------------------------------

run_cpu_checks() {
    set_category "CPU"

    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)

    if (( cpu_count >= 1 )); then
        pass "CPU cores detected" 2 \
            "${cpu_count} logical CPU core(s) detected."
    else
        fail "CPU core detection" 0 \
            "Unable to determine CPU core count."
    fi

    if [[ -r /proc/loadavg ]]; then
        local load1
        load1=$(awk '{print $1}' /proc/loadavg)

        if awk -v l="$load1" -v c="$cpu_count" 'BEGIN {exit !(l <= c)}'; then
            pass "Current CPU load" 2 \
                "1-minute load average is ${load1}; within available CPU capacity."
        elif awk -v l="$load1" -v c="$cpu_count" 'BEGIN {exit !(l <= c*2)}'; then
            warn "Current CPU load" 1 \
                "1-minute load average is ${load1}; CPU workload is elevated."
        else
            fail "Current CPU load" 0 \
                "1-minute load average is ${load1}; system is heavily loaded."
        fi
    else
        skip_check "Current CPU load" "/proc/loadavg unavailable."
    fi

    if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        local governor
        governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)

        case "$governor" in
            performance|schedutil|ondemand)
                pass "CPU scaling governor" 2 \
                    "CPU governor is ${governor}."
                ;;
            *)
                warn "CPU scaling governor" 1 \
                    "CPU governor is ${governor}; this may be intentional."
                ;;
        esac
    else
        skip_check "CPU scaling governor" "CPU frequency scaling information unavailable."
    fi

    if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
        local freq
        freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)

        if [[ "$freq" =~ ^[0-9]+$ ]] && (( freq > 0 )); then
            pass "CPU frequency control" 2 \
                "Current CPU frequency information is available."
        else
            warn "CPU frequency control" 1 \
                "CPU frequency information is present but could not be read normally."
        fi
    else
        skip_check "CPU frequency control" "Frequency scaling interface unavailable."
    fi

    if [[ -r /proc/cpuinfo ]]; then
        if grep -qiE 'Raspberry Pi|BCM|ARM' /proc/cpuinfo; then
            pass "CPU hardware identification" 2 \
                "Raspberry Pi/ARM hardware identified."
        else
            pass "CPU hardware identification" 2 \
                "Linux CPU information is available."
        fi
    else
        skip_check "CPU hardware identification" "/proc/cpuinfo unavailable."
    fi
}

# ------------------------------------------------------------
# TEMPERATURE / POWER
# ------------------------------------------------------------

run_power_checks() {
    set_category "Power & Thermal"

    local temp=""
    local temp_c=""

    if command_exists vcgencmd; then
        temp=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)

        if [[ -n "$temp" ]]; then
            temp_c="$temp"

            if awk -v t="$temp" 'BEGIN {exit !(t < 70)}'; then
                pass "CPU temperature" 4 \
                    "Temperature is ${temp}°C."
            elif awk -v t="$temp" 'BEGIN {exit !(t < 80)}'; then
                warn "CPU temperature" 2 \
                    "Temperature is ${temp}°C; elevated but not immediately critical."
            else
                fail "CPU temperature" 0 \
                    "Temperature is ${temp}°C; thermal conditions are poor."
            fi
        fi
    fi

    if [[ -z "$temp_c" && -r /sys/class/thermal/thermal_zone0/temp ]]; then
        local raw_temp
        raw_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)

        if [[ "$raw_temp" =~ ^[0-9]+$ ]] && (( raw_temp > 0 )); then
            temp_c=$(awk -v t="$raw_temp" 'BEGIN {printf "%.1f",t/1000}')

            if awk -v t="$temp_c" 'BEGIN {exit !(t < 70)}'; then
                pass "CPU temperature" 4 \
                    "Temperature is ${temp_c}°C."
            elif awk -v t="$temp_c" 'BEGIN {exit !(t < 80)}'; then
                warn "CPU temperature" 2 \
                    "Temperature is ${temp_c}°C; elevated."
            else
                fail "CPU temperature" 0 \
                    "Temperature is ${temp_c}°C; excessive."
            fi
        fi
    fi

    if [[ -z "$temp_c" ]]; then
        skip_check "CPU temperature" "No compatible temperature source detected."
    fi

    if command_exists vcgencmd; then
        local throttle
        throttle=$(vcgencmd get_throttled 2>/dev/null | grep -oE '0x[0-9a-fA-F]+' | head -n1 || true)

        if [[ "$throttle" == "0x0" ]]; then
            pass "Undervoltage / throttling" 5 \
                "Firmware reports no current or historical throttling flags."
        elif [[ -n "$throttle" ]]; then
            local value
            value=$((throttle))

            local current_uv=$(( value & 0x1 ))
            local current_throttle=$(( (value >> 2) & 0x1 ))
            local historical_uv=$(( (value >> 16) & 0x1 ))
            local historical_throttle=$(( (value >> 18) & 0x1 ))

            if (( current_uv || current_throttle )); then
                fail "Current undervoltage / throttling" 0 \
                    "Firmware reports an active power or throttling condition (${throttle})."
            elif (( historical_uv || historical_throttle )); then
                warn "Historical undervoltage / throttling" 3 \
                    "Firmware reports previous undervoltage or throttling events (${throttle})."
            else
                warn "Firmware throttle flags" 3 \
                    "Firmware reports non-zero throttle flags (${throttle})."
            fi
        else
            skip_check "Undervoltage / throttling" "vcgencmd returned no usable result."
        fi
    else
        skip_check "Undervoltage / throttling" "vcgencmd is unavailable."
    fi

    if dmesg >/dev/null 2>&1; then
        if dmesg 2>/dev/null | grep -qiE 'under-voltage|undervoltage|throttl'; then
            warn "Kernel power / throttle messages" 2 \
                "Kernel logs contain power or throttling related messages."
        else
            pass "Kernel power / throttle messages" 2 \
                "No obvious undervoltage or throttling messages found."
        fi
    else
        skip_check "Kernel power / throttle messages" "Kernel log access unavailable."
    fi
}

# ------------------------------------------------------------
# MEMORY
# ------------------------------------------------------------

run_memory_checks() {
    set_category "Memory"

    if [[ -r /proc/meminfo ]]; then
        local total available used_percent

        total=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
        available=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)

        if [[ "$total" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
            used_percent=$(( (total - available) * 100 / total ))

            if (( used_percent < 80 )); then
                pass "RAM utilisation" 3 \
                    "Approximately ${used_percent}% of RAM is currently in use."
            elif (( used_percent < 90 )); then
                warn "RAM utilisation" 2 \
                    "Approximately ${used_percent}% of RAM is currently in use."
            else
                fail "RAM utilisation" 0 \
                    "Approximately ${used_percent}% of RAM is currently in use."
            fi
        fi

        local swap_total swap_free

        swap_total=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)
        swap_free=$(awk '/SwapFree:/ {print $2}' /proc/meminfo)

        if [[ "$swap_total" =~ ^[0-9]+$ && "$swap_total" -gt 0 ]]; then
            local swap_used=$((swap_total - swap_free))
            local swap_percent=$((swap_used * 100 / swap_total))

            if (( swap_percent < 50 )); then
                pass "Swap usage" 2 \
                    "Swap usage is approximately ${swap_percent}%."
            elif (( swap_percent < 80 )); then
                warn "Swap usage" 1 \
                    "Swap usage is approximately ${swap_percent}%."
            else
                fail "Swap usage" 0 \
                    "Swap usage is approximately ${swap_percent}%."
            fi
        else
            pass "Swap configuration" 2 \
                "No active swap usage detected."
        fi
    else
        skip_check "RAM utilisation" "/proc/meminfo unavailable."
        skip_check "Swap usage" "/proc/meminfo unavailable."
    fi

    if dmesg >/dev/null 2>&1; then
        if dmesg 2>/dev/null | grep -qiE 'out of memory|oom-killer|killed process'; then
            fail "OOM events" 0 \
                "Kernel logs contain out-of-memory events."
        else
            pass "OOM events" 3 \
                "No obvious OOM-killer events found in the available kernel log."
        fi
    else
        skip_check "OOM events" "Kernel log access unavailable."
    fi

    if command_exists swapon; then
        if swapon --show --noheadings 2>/dev/null | grep -q .; then
            pass "Swap subsystem" 2 \
                "Swap is configured and visible."
        else
            warn "Swap subsystem" 1 \
                "No active swap device/file is visible."
        fi
    else
        skip_check "Swap subsystem" "swapon unavailable."
    fi
}

# ------------------------------------------------------------
# STORAGE
# ------------------------------------------------------------

run_storage_checks() {
    set_category "Storage"

    local root_line root_usage
    root_line=$(df -P / 2>/dev/null | tail -n1 || true)

    if [[ -n "$root_line" ]]; then
        root_usage=$(echo "$root_line" | awk '{gsub("%","",$5); print $5}')

        if [[ "$root_usage" =~ ^[0-9]+$ ]]; then
            if (( root_usage < 70 )); then
                pass "Root filesystem usage" 4 \
                    "Root filesystem is ${root_usage}% full."
            elif (( root_usage < 85 )); then
                warn "Root filesystem usage" 2 \
                    "Root filesystem is ${root_usage}% full."
            elif (( root_usage < 95 )); then
                warn "Root filesystem usage" 1 \
                    "Root filesystem is ${root_usage}% full; space is becoming limited."
            else
                fail "Root filesystem usage" 0 \
                    "Root filesystem is ${root_usage}% full."
            fi
        fi
    else
        skip_check "Root filesystem usage" "df could not inspect the root filesystem."
    fi

    if command_exists df; then
        local readonly_fs
        readonly_fs=$(df -P -T 2>/dev/null | awk 'NR>1 && $7 !~ /^$/ {print $7}' | while read -r mount; do
            mountpoint -q "$mount" 2>/dev/null || continue
            findmnt -no OPTIONS "$mount" 2>/dev/null | grep -qw ro && echo "$mount"
        done)

        if [[ -z "$readonly_fs" ]]; then
            pass "Read-only filesystem detection" 2 \
                "No mounted filesystem was detected as read-only."
        else
            fail "Read-only filesystem detection" 0 \
                "Read-only filesystem(s) detected: $readonly_fs"
        fi
    else
        skip_check "Read-only filesystem detection" "df unavailable."
    fi

    if [[ -r /proc/mounts ]]; then
        pass "Mounted filesystem table" 2 \
            "Linux mount information is available."
    else
        skip_check "Mounted filesystem table" "/proc/mounts unavailable."
    fi

    if command_exists df; then
        local inode_usage
        inode_usage=$(df -Pi / 2>/dev/null | tail -n1 | awk '{gsub("%","",$5); print $5}')

        if [[ "$inode_usage" =~ ^[0-9]+$ ]]; then
            if (( inode_usage < 80 )); then
                pass "Root inode usage" 2 \
                    "Root filesystem inode usage is ${inode_usage}%."
            elif (( inode_usage < 95 )); then
                warn "Root inode usage" 1 \
                    "Root filesystem inode usage is ${inode_usage}%."
            else
                fail "Root inode usage" 0 \
                    "Root filesystem inode usage is ${inode_usage}%."
            fi
        fi
    fi

    if dmesg >/dev/null 2>&1; then
        if dmesg 2>/dev/null | grep -qiE 'I/O error|Buffer I/O error|EXT4-fs error|mmc.*error|ata.*error|blk_update_request'; then
            fail "Storage kernel errors" 0 \
                "Kernel logs contain storage or I/O error messages."
        else
            pass "Storage kernel errors" 3 \
                "No obvious storage I/O errors found in the available kernel log."
        fi
    else
        skip_check "Storage kernel errors" "Kernel log access unavailable."
    fi

    if [[ -d /var/log ]]; then
        local log_size
        log_size=$(du -sm /var/log 2>/dev/null | awk '{print $1}')

        if [[ "$log_size" =~ ^[0-9]+$ ]]; then
            if (( log_size < 500 )); then
                pass "Log directory size" 2 \
                    "/var/log is approximately ${log_size} MB."
            elif (( log_size < 1500 )); then
                warn "Log directory size" 1 \
                    "/var/log is approximately ${log_size} MB."
            else
                warn "Log directory size" 0 \
                    "/var/log is approximately ${log_size} MB and may deserve cleanup."
            fi
        fi
    else
        skip_check "Log directory size" "/var/log is unavailable."
    fi

    if command_exists smartctl && command_exists lsblk; then
        local smart_found=0
        local smart_bad=0

        while read -r disk; do
            [[ -z "$disk" ]] && continue
            smart_found=1

            if ! sudo -n smartctl -H "/dev/$disk" >/dev/null 2>&1; then
                # Try without sudo if already permitted.
                smartctl -H "/dev/$disk" >/dev/null 2>&1 || continue
            fi

            local health
            health=$(sudo -n smartctl -H "/dev/$disk" 2>/dev/null || smartctl -H "/dev/$disk" 2>/dev/null || true)

            if echo "$health" | grep -qiE 'PASSED|OK'; then
                :
            elif echo "$health" | grep -qiE 'FAILED|FAILING'; then
                smart_bad=1
            fi
        done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

        if (( smart_found == 0 )); then
            skip_check "SMART health" "No suitable SMART-capable disks detected."
        elif (( smart_bad )); then
            fail "SMART health" 0 \
                "At least one disk reported an unhealthy SMART status."
        else
            pass "SMART health" 3 \
                "No failing SMART health status was detected."
        fi
    else
        skip_check "SMART health" "smartctl or lsblk unavailable."
    fi
}

# ------------------------------------------------------------
# SERVICES
# ------------------------------------------------------------

run_service_checks() {
    set_category "Services"

    if ! command_exists systemctl; then
        skip_check "Failed systemd services" "systemctl unavailable."
        return
    fi

    local failed_services
    failed_services=$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}')

    if [[ -z "$failed_services" ]]; then
        pass "Failed systemd services" 5 \
            "No failed systemd units were detected."
    else
        local count
        count=$(echo "$failed_services" | grep -c . || true)

        if (( count == 1 )); then
            fail "Failed systemd services" 0 \
                "1 failed systemd service/unit detected: $failed_services"
        else
            fail "Failed systemd services" 0 \
                "${count} failed systemd services/units detected."
        fi
    fi

    local activating
    activating=$(systemctl list-units --type=service --state=activating --no-legend --no-pager 2>/dev/null | wc -l)

    if (( activating == 0 )); then
        pass "Services stuck activating" 2 \
            "No services are currently stuck in the activating state."
    else
        warn "Services stuck activating" 1 \
            "${activating} service(s) are currently activating."
    fi

    local services_total
    services_total=$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | wc -l)

    if (( services_total > 0 )); then
        pass "Systemd service database" 2 \
            "${services_total} service unit definitions are visible."
    else
        warn "Systemd service database" 1 \
            "No service definitions were returned."
    fi

    if command_exists systemd-analyze; then
        if systemd-analyze verify /etc/systemd/system/*.service >/dev/null 2>&1; then
            pass "Systemd configuration verification" 2 \
                "Systemd service configuration verification completed without obvious errors."
        else
            warn "Systemd configuration verification" 1 \
                "Systemd verification reported an issue or no matching local service files."
        fi
    else
        skip_check "Systemd configuration verification" "systemd-analyze unavailable."
    fi

    if command_exists journalctl; then
        local crash_messages
        crash_messages=$(journalctl --since "24 hours ago" --no-pager 2>/dev/null |
            grep -ciE 'segfault|core dumped|failed with result|main process exited|status=[0-9]+/|code=dumped' || true)

        if (( crash_messages == 0 )); then
            pass "Recent service/process crash indicators" 4 \
                "No obvious service crash indicators found in the last 24 hours."
        elif (( crash_messages < 5 )); then
            warn "Recent service/process crash indicators" 2 \
                "${crash_messages} possible crash/failure message(s) found in the last 24 hours."
        else
            fail "Recent service/process crash indicators" 0 \
                "${crash_messages} possible crash/failure messages found in the last 24 hours."
        fi
    else
        skip_check "Recent service/process crash indicators" "journalctl unavailable."
    fi
}

# ------------------------------------------------------------
# BOOT
# ------------------------------------------------------------

run_boot_checks() {
    set_category "Boot & Reliability"

    if command_exists systemd-analyze; then
        local boot_time
        boot_time=$(systemd-analyze 2>/dev/null | head -n1 || true)

        if [[ -n "$boot_time" ]]; then
            pass "Boot analysis available" 2 \
                "$boot_time"
        else
            skip_check "Boot analysis available" "systemd-analyze returned no result."
        fi

        local failed_boot
        failed_boot=$(journalctl -b -p err --no-pager 2>/dev/null | wc -l)

        if (( failed_boot == 0 )); then
            pass "Current boot errors" 4 \
                "No error-priority journal entries found for the current boot."
        elif (( failed_boot < 10 )); then
            warn "Current boot errors" 2 \
                "${failed_boot} error-priority journal entries found for the current boot."
        else
            fail "Current boot errors" 0 \
                "${failed_boot} error-priority journal entries found for the current boot."
        fi
    else
        skip_check "Boot analysis available" "systemd-analyze unavailable."
        skip_check "Current boot errors" "systemd-analyze unavailable."
    fi

    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        pass "Boot identity" 1 \
            "Current boot ID is available."
    else
        skip_check "Boot identity" "Kernel boot ID unavailable."
    fi

    if command_exists last; then
        local reboot_count
        reboot_count=$(last reboot -n 20 2>/dev/null | grep -c reboot || true)

        if (( reboot_count < 10 )); then
            pass "Recent reboot frequency" 2 \
                "${reboot_count} reboot record(s) found in the recent login history."
        else
            warn "Recent reboot frequency" 1 \
                "${reboot_count} recent reboot record(s) found; investigate unexpected restarts if applicable."
        fi
    else
        skip_check "Recent reboot frequency" "last command unavailable."
    fi
}

# ------------------------------------------------------------
# NETWORK
# ------------------------------------------------------------

run_network_checks() {
    set_category "Network"

    if ! command_exists ip; then
        skip_check "Network interface state" "ip command unavailable."
        return
    fi

    local interfaces
    interfaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$' || true)

    if [[ -n "$interfaces" ]]; then
        pass "Network interfaces detected" 2 \
            "Detected network interface(s): $(echo "$interfaces" | tr '\n' ' ')."
    else
        fail "Network interfaces detected" 0 \
            "No non-loopback network interfaces were detected."
    fi

    local up_count
    up_count=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$' | wc -l)

    if (( up_count > 0 )); then
        pass "Active network interface" 3 \
            "${up_count} non-loopback interface(s) are currently up."
    else
        fail "Active network interface" 0 \
            "No non-loopback network interface is currently up."
    fi

    if ip route show default 2>/dev/null | grep -q '^default'; then
        pass "Default gateway" 2 \
            "A default network route is configured."
    else
        warn "Default gateway" 1 \
            "No default gateway is currently configured."
    fi

    if command_exists getent; then
        if getent hosts example.com >/dev/null 2>&1; then
            pass "DNS resolution" 4 \
                "DNS resolution is working."
        else
            fail "DNS resolution" 0 \
                "DNS resolution failed."
        fi
    else
        skip_check "DNS resolution" "getent unavailable."
    fi

    if command_exists ping; then
        local gateway
        gateway=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')

        if [[ -n "$gateway" ]]; then
            if ping -c1 -W2 "$gateway" >/dev/null 2>&1; then
                pass "Gateway reachability" 3 \
                    "Default gateway ${gateway} responded."
            else
                fail "Gateway reachability" 0 \
                    "Default gateway ${gateway} did not respond."
            fi
        else
            skip_check "Gateway reachability" "No default gateway detected."
        fi

        if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
            pass "Internet connectivity" 3 \
                "External connectivity test succeeded."
        else
            warn "Internet connectivity" 1 \
                "External connectivity test failed."
        fi
    else
        skip_check "Gateway reachability" "ping unavailable."
        skip_check "Internet connectivity" "ping unavailable."
    fi

    if command_exists ss; then
        local listen_count
        listen_count=$(ss -lntu 2>/dev/null | tail -n +2 | wc -l)

        if (( listen_count < 25 )); then
            pass "Listening socket count" 2 \
                "${listen_count} listening TCP/UDP socket(s) detected."
        elif (( listen_count < 50 )); then
            warn "Listening socket count" 1 \
                "${listen_count} listening TCP/UDP socket(s) detected."
        else
            warn "Listening socket count" 0 \
                "${listen_count} listening TCP/UDP socket(s) detected; review if unexpected."
        fi
    else
        skip_check "Listening socket count" "ss unavailable."
    fi
}

# ------------------------------------------------------------
# DNS SERVICES
# ------------------------------------------------------------

run_dns_checks() {
    set_category "DNS / Pi-hole / Unbound"

    if command_exists pihole; then
        if pihole status >/dev/null 2>&1; then
            pass "Pi-hole service" 4 \
                "Pi-hole command reports an operational installation."
        else
            warn "Pi-hole service" 2 \
                "Pi-hole is installed but its status command reported a problem."
        fi

        if command_exists dig; then
            if dig @127.0.0.1 example.com +short +time=2 >/dev/null 2>&1; then
                pass "Local DNS query" 3 \
                    "A local DNS query completed successfully."
            else
                fail "Local DNS query" 0 \
                    "A local DNS query failed."
            fi
        else
            skip_check "Local DNS query" "dig unavailable."
        fi
    else
        skip_check "Pi-hole service" "Pi-hole is not installed/detected."
        skip_check "Local DNS query" "Pi-hole not detected."
    fi

    if command_exists unbound-checkconf; then
        if unbound-checkconf >/dev/null 2>&1; then
            pass "Unbound configuration" 4 \
                "Unbound configuration passed validation."
        else
            fail "Unbound configuration" 0 \
                "Unbound configuration validation failed."
        fi
    elif command_exists systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^unbound\.service'; then
        if systemctl is-active --quiet unbound; then
            pass "Unbound service" 3 \
                "Unbound service is active."
        else
            fail "Unbound service" 0 \
                "Unbound service is installed but not active."
        fi
    else
        skip_check "Unbound" "Unbound is not detected."
    fi
}

# ------------------------------------------------------------
# WIREGUARD
# ------------------------------------------------------------

run_wireguard_checks() {
    set_category "VPN / WireGuard"

    if ! command_exists wg; then
        skip_check "WireGuard installation" "WireGuard is not detected."
        return
    fi

    pass "WireGuard installation" 2 \
        "WireGuard tooling is installed."

    local interfaces
    interfaces=$(wg show interfaces 2>/dev/null || true)

    if [[ -n "$interfaces" ]]; then
        pass "WireGuard interface" 3 \
            "WireGuard interface(s) detected: $interfaces"

        local peer_count
        peer_count=$(wg show all peers 2>/dev/null | wc -l)

        if (( peer_count > 0 )); then
            pass "WireGuard peers" 2 \
                "${peer_count} WireGuard peer(s) detected."
        else
            warn "WireGuard peers" 1 \
                "WireGuard is configured but no peers were detected."
        fi

        local handshakes
        handshakes=$(wg show all latest-handshakes 2>/dev/null | awk '$2 > 0 {print $2}')

        if [[ -n "$handshakes" ]]; then
            local now newest age
            now=$(date +%s)
            newest=$(echo "$handshakes" | sort -nr | head -n1)
            age=$((now - newest))

            if (( age < 86400 )); then
                pass "Recent WireGuard handshake" 3 \
                    "At least one peer has communicated within the last 24 hours."
            elif (( age < 604800 )); then
                warn "Recent WireGuard handshake" 1 \
                    "Newest recorded handshake is more than 24 hours old."
            else
                warn "Recent WireGuard handshake" 0 \
                    "No WireGuard handshake has been seen within the last 7 days."
            fi
        else
            warn "Recent WireGuard handshake" 0 \
                "No peer handshake timestamp was available."
        fi
    else
        warn "WireGuard interface" 1 \
            "WireGuard is installed but no active interface was detected."
    fi
}

# ------------------------------------------------------------
# SECURITY
# ------------------------------------------------------------

run_security_checks() {
    set_category "Security"

    if command_exists ss; then
        local ssh_listen
        ssh_listen=$(ss -lnt 2>/dev/null | grep -E ':(22|2222)[[:space:]]' || true)

        if [[ -n "$ssh_listen" ]]; then
            pass "SSH listening state" 2 \
                "SSH appears to be listening."
        else
            pass "SSH exposure" 2 \
                "No SSH listener detected on common ports 22/2222."
        fi

        local exposed
        exposed=$(ss -lnt 2>/dev/null | awk '$4 ~ /^0\.0\.0\.0:/ || $4 ~ /^\[::\]:/ {print $4}' | wc -l)

        if (( exposed < 10 )); then
            pass "Public interface listeners" 3 \
                "${exposed} TCP listener(s) appear bound to all interfaces."
        elif (( exposed < 20 )); then
            warn "Public interface listeners" 1 \
                "${exposed} TCP listener(s) appear bound to all interfaces."
        else
            warn "Public interface listeners" 0 \
                "${exposed} TCP listeners appear bound to all interfaces; review exposure."
        fi
    else
        skip_check "SSH listening state" "ss unavailable."
        skip_check "Public interface listeners" "ss unavailable."
    fi

    if [[ -f /etc/ssh/sshd_config ]]; then
        local root_login password_auth

        root_login=$(grep -Ei '^[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | tail -n1 || true)
        password_auth=$(grep -Ei '^[[:space:]]*PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | tail -n1 || true)

        if echo "$root_login" | grep -qiE 'yes|without-password|prohibit-password'; then
            warn "SSH root login configuration" 1 \
                "SSH root login is explicitly permitted or not fully disabled."
        else
            pass "SSH root login configuration" 2 \
                "SSH root login does not appear explicitly enabled."
        fi

        if echo "$password_auth" | grep -qiE 'yes'; then
            warn "SSH password authentication" 1 \
                "SSH password authentication appears enabled."
        else
            pass "SSH password authentication" 2 \
                "SSH password authentication does not appear explicitly enabled."
        fi
    else
        skip_check "SSH root login configuration" "sshd_config unavailable."
        skip_check "SSH password authentication" "sshd_config unavailable."
    fi

    if command_exists ufw; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null || true)

        if echo "$ufw_status" | grep -qi '^Status: active'; then
            pass "UFW firewall" 4 \
                "UFW is active."
        else
            warn "UFW firewall" 2 \
                "UFW is installed but inactive."
        fi
    elif command_exists nft; then
        if nft list ruleset >/dev/null 2>&1 && [[ -n "$(nft list ruleset 2>/dev/null)" ]]; then
            pass "nftables firewall" 4 \
                "An nftables ruleset is present."
        else
            warn "nftables firewall" 2 \
                "nftables is available but no ruleset was detected."
        fi
    elif command_exists iptables; then
        local policy
        policy=$(iptables -S 2>/dev/null || true)

        if [[ -n "$policy" ]]; then
            pass "iptables firewall" 3 \
                "iptables rules are present."
        else
            warn "iptables firewall" 1 \
                "iptables is available but no rules were detected."
        fi
    else
        warn "Firewall detection" 0 \
            "No supported firewall management tool was detected."
    fi

    if command_exists fail2ban-client; then
        if fail2ban-client ping >/dev/null 2>&1; then
            pass "Fail2ban" 2 \
                "Fail2ban is installed and responding."
        else
            warn "Fail2ban" 1 \
                "Fail2ban is installed but not responding."
        fi
    else
        skip_check "Fail2ban" "Fail2ban is not installed."
    fi

    if command_exists journalctl; then
        local auth_failures
        auth_failures=$(journalctl --since "24 hours ago" --no-pager 2>/dev/null |
            grep -ciE 'Failed password|authentication failure|Invalid user' || true)

        if (( auth_failures == 0 )); then
            pass "Recent authentication failures" 3 \
                "No obvious failed authentication attempts found in the last 24 hours."
        elif (( auth_failures < 10 )); then
            warn "Recent authentication failures" 2 \
                "${auth_failures} failed authentication event(s) found in the last 24 hours."
        else
            fail "Recent authentication failures" 0 \
                "${auth_failures} failed authentication events found in the last 24 hours."
        fi
    else
        skip_check "Recent authentication failures" "journalctl unavailable."
    fi
}

# ------------------------------------------------------------
# SOFTWARE / PACKAGE HEALTH
# ------------------------------------------------------------

run_software_checks() {
    set_category "Software & Updates"

    if command_exists dpkg; then
        local broken
        broken=$(dpkg --audit 2>/dev/null | wc -l)

        if (( broken == 0 )); then
            pass "Package database integrity" 4 \
                "dpkg reports no obvious package audit problems."
        else
            warn "Package database integrity" 1 \
                "dpkg audit returned ${broken} line(s) requiring review."
        fi
    else
        skip_check "Package database integrity" "dpkg unavailable."
    fi

    if command_exists apt-get && command_exists apt; then
        local updates
        updates=$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -v '^$' | wc -l)

        if (( updates == 0 )); then
            pass "Available package updates" 4 \
                "No available package updates were detected."
        elif (( updates < 10 )); then
            warn "Available package updates" 3 \
                "${updates} package update(s) are available."
        elif (( updates < 50 )); then
            warn "Available package updates" 2 \
                "${updates} package updates are available."
        else
            fail "Available package updates" 0 \
                "${updates} package updates are available."
        fi
    else
        skip_check "Available package updates" "APT package manager unavailable."
    fi

    if [[ -f /var/run/reboot-required ]]; then
        warn "Reboot required" 1 \
            "The system indicates that a reboot is required."
    else
        pass "Reboot required" 2 \
            "No reboot-required marker was detected."
    fi

    if command_exists timedatectl; then
        local sync
        sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)

        if [[ "$sync" == "yes" ]]; then
            pass "Time synchronisation" 2 \
                "System clock is synchronised."
        else
            warn "Time synchronisation" 1 \
                "System clock does not report as synchronised."
        fi
    else
        skip_check "Time synchronisation" "timedatectl unavailable."
    fi

    if command_exists uname; then
        pass "Kernel identification" 2 \
            "Running kernel: ${KERNEL_VERSION}."
    else
        skip_check "Kernel identification" "uname unavailable."
    fi
}

# ------------------------------------------------------------
# PROCESS / CRASH CHECKS
# ------------------------------------------------------------

run_process_checks() {
    set_category "Processes & Reliability"

    if command_exists ps; then
        local process_count
        process_count=$(ps -e --no-headers 2>/dev/null | wc -l)

        if (( process_count < 300 )); then
            pass "Process count" 2 \
                "${process_count} running process(es) detected."
        elif (( process_count < 500 )); then
            warn "Process count" 1 \
                "${process_count} running processes detected."
        else
            warn "Process count" 0 \
                "${process_count} running processes detected; review if unexpected."
        fi

        local zombie_count
        zombie_count=$(ps -eo stat= 2>/dev/null | grep -c '^Z' || true)

        if (( zombie_count == 0 )); then
            pass "Zombie processes" 3 \
                "No zombie processes detected."
        elif (( zombie_count < 5 )); then
            warn "Zombie processes" 1 \
                "${zombie_count} zombie process(es) detected."
        else
            fail "Zombie processes" 0 \
                "${zombie_count} zombie processes detected."
        fi
    else
        skip_check "Process count" "ps unavailable."
        skip_check "Zombie processes" "ps unavailable."
    fi

    if command_exists journalctl; then
        local segfaults
        segfaults=$(journalctl --since "7 days ago" --no-pager 2>/dev/null |
            grep -ciE 'segfault|core dumped' || true)

        if (( segfaults == 0 )); then
            pass "Recent segmentation faults" 3 \
                "No segmentation fault/core dump indicators found in the last 7 days."
        elif (( segfaults < 5 )); then
            warn "Recent segmentation faults" 1 \
                "${segfaults} segmentation fault/core dump indicator(s) found."
        else
            fail "Recent segmentation faults" 0 \
                "${segfaults} segmentation fault/core dump indicators found."
        fi
    else
        skip_check "Recent segmentation faults" "journalctl unavailable."
    fi
}

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

run_configuration_checks() {
    set_category "Configuration"

    if [[ -n "$HOSTNAME_VALUE" ]]; then
        pass "Hostname configuration" 2 \
            "Hostname is ${HOSTNAME_VALUE}."
    else
        fail "Hostname configuration" 0 \
            "Hostname could not be determined."
    fi

    if [[ -f /etc/fstab ]]; then
        if findmnt --verify >/dev/null 2>&1; then
            pass "fstab validation" 4 \
                "Mounted filesystem configuration passed findmnt verification."
        else
            warn "fstab validation" 1 \
                "findmnt reported a possible filesystem configuration problem."
        fi
    else
        skip_check "fstab validation" "/etc/fstab unavailable."
    fi

    if [[ -d /etc/systemd/system ]]; then
        pass "Local systemd configuration directory" 1 \
            "/etc/systemd/system exists."
    else
        skip_check "Local systemd configuration directory" "Directory unavailable."
    fi

    if [[ -f /etc/hostname ]]; then
        pass "Hostname file" 1 \
            "/etc/hostname exists."
    else
        warn "Hostname file" 0 \
            "/etc/hostname is missing."
    fi

    if [[ -f /etc/resolv.conf ]]; then
        pass "DNS resolver configuration" 2 \
            "/etc/resolv.conf exists."
    else
        fail "DNS resolver configuration" 0 \
            "/etc/resolv.conf is missing."
    fi
}

# ------------------------------------------------------------
# APPLICATION-SPECIFIC CHECKS
# ------------------------------------------------------------

run_application_checks() {
    set_category "Detected Applications"

    if command_exists docker; then
        if docker info >/dev/null 2>&1; then
            pass "Docker daemon" 3 \
                "Docker is installed and responding."
        else
            warn "Docker daemon" 1 \
                "Docker is installed but the daemon is not responding."
        fi

        local containers
        containers=$(docker ps -a --format '{{.ID}}' 2>/dev/null | wc -l)

        if (( containers > 0 )); then
            local stopped
            stopped=$(docker ps -a --filter status=exited --format '{{.ID}}' 2>/dev/null | wc -l)

            if (( stopped == 0 )); then
                pass "Docker container state" 2 \
                    "${containers} container(s) detected and none are exited."
            else
                warn "Docker container state" 1 \
                    "${containers} container(s) detected; ${stopped} are exited."
            fi
        else
            skip_check "Docker container state" "Docker is installed but no containers exist."
        fi
    else
        skip_check "Docker daemon" "Docker is not installed."
        skip_check "Docker container state" "Docker is not installed."
    fi

    if command_exists caddy; then
        if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
            pass "Caddy configuration" 3 \
                "Caddy configuration passed validation."
        else
            warn "Caddy configuration" 1 \
                "Caddy is installed but its configuration could not be validated."
        fi
    else
        skip_check "Caddy configuration" "Caddy is not installed."
    fi

    if command_exists tailscale; then
        if tailscale status >/dev/null 2>&1; then
            pass "Tailscale" 3 \
                "Tailscale is installed and responding."
        else
            warn "Tailscale" 1 \
                "Tailscale is installed but status could not be retrieved."
        fi
    else
        skip_check "Tailscale" "Tailscale is not installed."
    fi

    if command_exists mosquitto; then
        pass "MQTT software detection" 1 \
            "Mosquitto MQTT software is installed."
    else
        skip_check "MQTT software detection" "Mosquitto is not installed."
    fi
}

# ------------------------------------------------------------
# NETWORK CONFIGURATION / INTERFACE ERRORS
# ------------------------------------------------------------

run_network_error_checks() {
    set_category "Network Reliability"

    if command_exists ip; then
        local error_stats
        error_stats=$(ip -s link 2>/dev/null | awk '
            /^[0-9]+:/ {
                iface=$2
                sub(/:$/,"",iface)
            }
            /RX:/ {rx=1; next}
            /TX:/ {tx=1; next}
            rx && NF >= 8 {
                if ($1+0 > 0 || $3+0 > 0 || $4+0 > 0) errors++
                rx=0
            }
            tx && NF >= 8 {
                if ($1+0 > 0 || $3+0 > 0 || $4+0 > 0) errors++
                tx=0
            }
            END {print errors+0}
        ')

        if [[ "$error_stats" =~ ^[0-9]+$ ]]; then
            if (( error_stats == 0 )); then
                pass "Network interface errors" 3 \
                    "No obvious RX/TX error counters were detected."
            else
                warn "Network interface errors" 1 \
                    "Some interface error/drop counters may be non-zero."
            fi
        else
            skip_check "Network interface errors" "Interface statistics unavailable."
        fi
    else
        skip_check "Network interface errors" "ip unavailable."
    fi

    if [[ -r /proc/net/dev ]]; then
        pass "Network statistics" 2 \
            "Kernel network statistics are available."
    else
        skip_check "Network statistics" "/proc/net/dev unavailable."
    fi
}

# ------------------------------------------------------------
# FULL SCAN
# ------------------------------------------------------------

run_full_scan() {
    : > "$RESULT_FILE"
    : > "$DETAIL_FILE"
    : > "$SKIP_FILE"

    TOTAL_POINTS=0
    MAX_POINTS=0
    PASS_COUNT=0
    WARN_COUNT=0
    FAIL_COUNT=0
    SKIP_COUNT=0

    unset CAT_SCORE CAT_MAX CAT_PASS CAT_WARN CAT_FAIL
    declare -gA CAT_SCORE
    declare -gA CAT_MAX
    declare -gA CAT_PASS
    declare -gA CAT_WARN
    declare -gA CAT_FAIL

    run_cpu_checks
    run_power_checks
    run_memory_checks
    run_storage_checks
    run_service_checks
    run_boot_checks
    run_network_checks
    run_dns_checks
    run_wireguard_checks
    run_security_checks
    run_software_checks
    run_process_checks
    run_configuration_checks
    run_application_checks
    run_network_error_checks
}

# ------------------------------------------------------------
# SCORE
# ------------------------------------------------------------

get_score() {
    if (( MAX_POINTS <= 0 )); then
        echo 0
    else
        echo $(( TOTAL_POINTS * 100 / MAX_POINTS ))
    fi
}

score_label() {
    local score="$1"

    if (( score >= 95 )); then
        echo "EXCELLENT"
    elif (( score >= 85 )); then
        echo "VERY GOOD"
    elif (( score >= 75 )); then
        echo "GOOD"
    elif (( score >= 60 )); then
        echo "WARNING"
    elif (( score >= 40 )); then
        echo "POOR"
    else
        echo "CRITICAL"
    fi
}

# ------------------------------------------------------------
# RESULTS TEXT
# ------------------------------------------------------------

build_summary() {
    local score label
    score=$(get_score)
    label=$(score_label "$score")

    {
        echo "PI HEALTH SCORE"
        echo
        printf "Overall Score: %s / 100\n" "$score"
        printf "Condition:     %s\n" "$label"
        echo
        printf "Checks passed:   %s\n" "$PASS_COUNT"
        printf "Warnings:        %s\n" "$WARN_COUNT"
        printf "Failures:        %s\n" "$FAIL_COUNT"
        printf "Skipped:         %s\n" "$SKIP_COUNT"
        echo
        printf "Checks applicable: %s\n" "$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))"
        printf "Checks evaluated:  %s\n" "$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))"
        echo
        echo "SYSTEM"
        echo "------------------------------"
        printf "Hostname: %s\n" "$HOSTNAME_VALUE"
        printf "OS:       %s\n" "$OS_NAME"
        printf "Kernel:   %s\n" "$KERNEL_VERSION"
        printf "Arch:     %s\n" "$ARCH"
        echo
        echo "CATEGORY SCORES"
        echo "------------------------------"

        local cat
        for cat in "${!CAT_SCORE[@]}"; do
            local cscore="${CAT_SCORE[$cat]}"
            local cmax="${CAT_MAX[$cat]}"

            if (( cmax > 0 )); then
                printf "%-24s %3s / %-3s (%3s%%)\n" \
                    "$cat" \
                    "$cscore" \
                    "$cmax" \
                    "$((cscore * 100 / cmax))"
            fi
        done

        echo
        echo "STATUS"
        echo "------------------------------"
        echo "PASS = healthy"
        echo "WARN = attention recommended"
        echo "FAIL = issue detected"
        echo "Skipped checks are not included against the score."
    } > "${TMP_DIR}/summary"
}

# ------------------------------------------------------------
# ISSUE VIEW
# ------------------------------------------------------------

show_issues() {
    local output="${TMP_DIR}/issues"

    {
        echo "HEALTH ISSUES"
        echo "========================================"
        echo

        if [[ "$WARN_COUNT" -eq 0 && "$FAIL_COUNT" -eq 0 ]]; then
            echo "No warnings or failures were detected."
        else
            while IFS='|' read -r status name explanation; do
                case "$status" in
                    WARN)
                        echo "[WARNING] $name"
                        echo "  $explanation"
                        echo
                        ;;
                    FAIL)
                        echo "[CRITICAL] $name"
                        echo "  $explanation"
                        echo
                        ;;
                esac
            done < "$DETAIL_FILE"
        fi
    } > "$output"

    whiptail \
        --title "Health Issues" \
        --textbox "$output" \
        "$((TERM_HEIGHT - 4))" \
        "$((TERM_WIDTH - 8))"
}

# ------------------------------------------------------------
# CATEGORY DETAILS
# ------------------------------------------------------------

show_category() {
    local category="$1"
    local output="${TMP_DIR}/category"

    {
        echo "$category"
        echo "========================================"
        echo

        while IFS='|' read -r status cat points max name; do
            [[ "$cat" != "$category" ]] && continue

            case "$status" in
                PASS)
                    printf "[PASS] %-42s %s/%s\n" "$name" "$points" "$max"
                    ;;
                WARN)
                    printf "[WARN] %-42s %s/%s\n" "$name" "$points" "$max"
                    ;;
                FAIL)
                    printf "[FAIL] %-42s %s/%s\n" "$name" "$points" "$max"
                    ;;
            esac
        done < "$RESULT_FILE"

        echo
        echo "Explanations"
        echo "----------------------------------------"

        while IFS='|' read -r status name explanation; do
            while IFS='|' read -r _ cat _ _ result_name; do
                [[ "$cat" != "$category" ]] && continue
                [[ "$result_name" != "$name" ]] && continue

                printf "\n[%s] %s\n%s\n" "$status" "$name" "$explanation"
                break
            done < "$RESULT_FILE"
        done < "$DETAIL_FILE"

    } > "$output"

    whiptail \
        --title "$category" \
        --textbox "$output" \
        "$((TERM_HEIGHT - 4))" \
        "$((TERM_WIDTH - 8))"
}

# ------------------------------------------------------------
# SKIPPED CHECKS
# ------------------------------------------------------------

show_skipped() {
    local output="${TMP_DIR}/skipped"

    {
        echo "SKIPPED / NOT APPLICABLE CHECKS"
        echo "========================================"
        echo
        echo "These checks were not scored because the"
        echo "required hardware or software was not detected."
        echo

        while IFS='|' read -r name reason; do
            printf "%-42s\n  %s\n\n" "$name" "$reason"
        done < "$SKIP_FILE"

    } > "$output"

    whiptail \
        --title "Skipped Checks" \
        --textbox "$output" \
        "$((TERM_HEIGHT - 4))" \
        "$((TERM_WIDTH - 8))"
}

# ------------------------------------------------------------
# CATEGORY MENU
# ------------------------------------------------------------

show_categories() {
    local options=()
    local category

    for category in "${!CAT_SCORE[@]}"; do
        local score="${CAT_SCORE[$category]}"
        local max="${CAT_MAX[$category]}"

        [[ "$max" -eq 0 ]] && continue

        local percentage=$((score * 100 / max))

        options+=(
            "$category"
            "${percentage}%  (${score}/${max})"
        )
    done

    options+=(
        "BACK"
        "Return"
    )

    local selected

    selected=$(whiptail \
        --title "Health Categories" \
        --menu "Select a category:" \
        "$((TERM_HEIGHT - 4))" \
        "$((TERM_WIDTH - 8))" \
        12 \
        "${options[@]}" \
        3>&1 1>&2 2>&3) || return

    [[ "$selected" == "BACK" ]] && return

    show_category "$selected"
}

# ------------------------------------------------------------
# MAIN MENU
# ------------------------------------------------------------

main_menu() {
    while true; do
        build_summary

        local score label
        score=$(get_score)
        label=$(score_label "$score")

        local choice

        choice=$(whiptail \
            --title "Pi Health Score v${VERSION}" \
            --menu \
            "Score: ${score}/100 — ${label}\n\nChecks: $((PASS_COUNT + WARN_COUNT + FAIL_COUNT))  |  Warnings: ${WARN_COUNT}  |  Failures: ${FAIL_COUNT}\n\nSelect an option:" \
            "$((TERM_HEIGHT - 4))" \
            "$((TERM_WIDTH - 8))" \
            12 \
            "SUMMARY"    "Overall health summary" \
            "ISSUES"     "Warnings and failures" \
            "CATEGORIES" "Detailed category scores" \
            "CHECKS"     "All individual checks" \
            "SKIPPED"    "Show skipped/not applicable checks" \
            "RESCAN"     "Run complete health scan again" \
            "EXIT"       "Exit Health Score" \
            3>&1 1>&2 2>&3) || exit 0

        case "$choice" in
            SUMMARY)
                whiptail \
                    --title "Pi Health Score" \
                    --textbox "${TMP_DIR}/summary" \
                    "$((TERM_HEIGHT - 4))" \
                    "$((TERM_WIDTH - 8))"
                ;;

            ISSUES)
                show_issues
                ;;

            CATEGORIES)
                show_categories
                ;;

            CHECKS)
                whiptail \
                    --title "All Health Checks" \
                    --textbox "$RESULT_FILE" \
                    "$((TERM_HEIGHT - 4))" \
                    "$((TERM_WIDTH - 8))"
                ;;

            SKIPPED)
                show_skipped
                ;;

            RESCAN)
                run_scan_with_progress
                ;;

            EXIT)
                exit 0
                ;;
        esac
    done
}

# ------------------------------------------------------------
# SCAN PROGRESS
# ------------------------------------------------------------

run_scan_with_progress() {
    whiptail \
        --title "Pi Health Score" \
        --infobox \
        "Starting comprehensive health scan...

This may take a short while.

Checking system, power, storage,
services, networking, DNS, security,
software and reliability." \
        10 60

    run_full_scan

    sleep 0.3

    local score label
    score=$(get_score)
    label=$(score_label "$score")

    whiptail \
        --title "Scan Complete" \
        --msgbox \
        "Health scan complete.

Overall Score: ${score}/100
Condition: ${label}

Checks:   $((PASS_COUNT + WARN_COUNT + FAIL_COUNT))
Passed:   ${PASS_COUNT}
Warnings: ${WARN_COUNT}
Failures: ${FAIL_COUNT}
Skipped:  ${SKIP_COUNT}

Select SUMMARY or ISSUES for more information." \
        15 65
}

# ------------------------------------------------------------
# START
# ------------------------------------------------------------

clear

run_scan_with_progress
main_menu
