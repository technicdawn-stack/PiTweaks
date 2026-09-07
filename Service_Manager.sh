#!/bin/bash

# ============================================================
# PiTweaks - Service Manager
# Service_Manager.sh
#
# PERSISTENT: TRUE
# Category: Administration
# Description: Advanced systemd service manager with search, filtering, failed-service monitoring, service status, dependencies, startup analysis, resource usage, logs, and service control. V1.3
#
# Features:
#   - Running / stopped / failed service overview
#   - Search services by name or description
#   - Service filters
#   - Failed services dashboard
#   - Custom service detection
#   - Service details
#   - systemctl status viewer
#   - Service dependencies
#   - Start / Stop / Restart
#   - Enable / Disable
#   - Service logs
#   - CPU usage
#   - RAM usage
#   - Enabled / disabled service views
#   - Startup / boot analysis
#   - Refresh
#
# Requirements:
#   - bash
#   - whiptail
#   - systemctl
#   - journalctl
#   - awk
#   - grep
#   - sed
#   - find
# ============================================================

set -e

TITLE="PiTweaks | Service Manager"
BACKTITLE="PiTweaks | Raspberry Pi Toolkit"

# ------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------

if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail is required."
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    whiptail \
        --title "$TITLE | Error" \
        --msgbox \
        "systemctl was not found.

This system does not appear to be using systemd." \
        10 65
    exit 1
fi

if ! command -v journalctl >/dev/null 2>&1; then
    whiptail \
        --title "$TITLE | Error" \
        --msgbox \
        "journalctl was not found.

Service logs cannot be displayed." \
        10 65
    exit 1
fi

# ------------------------------------------------------------
# TERMINAL SIZE
# ------------------------------------------------------------

TERM_HEIGHT=$(tput lines 2>/dev/null || echo 24)
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

if (( TERM_HEIGHT < 20 )); then
    TERM_HEIGHT=20
fi

if (( TERM_WIDTH < 75 )); then
    TERM_WIDTH=75
fi

# ------------------------------------------------------------
# TEMPORARY FILES
# ------------------------------------------------------------

TMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

SERVICE_FILE="${TMP_DIR}/services.txt"
ACTIVE_FILE="${TMP_DIR}/active.txt"
ENABLED_FILE="${TMP_DIR}/enabled.txt"
CUSTOM_FILE="${TMP_DIR}/custom.txt"
SEARCH_FILE="${TMP_DIR}/search.txt"
STATUS_FILE="${TMP_DIR}/status.txt"
DEPENDENCY_FILE="${TMP_DIR}/dependencies.txt"
BOOT_FILE="${TMP_DIR}/boot.txt"

# ------------------------------------------------------------
# CURRENT FILTER / SEARCH
# ------------------------------------------------------------

CURRENT_FILTER="ALL"
CURRENT_SEARCH=""

# ------------------------------------------------------------
# BASIC HELPERS
# ------------------------------------------------------------

friendly_state() {
    local state="$1"

    case "$state" in
        active)
            echo "RUNNING"
            ;;
        inactive)
            echo "STOPPED"
            ;;
        failed)
            echo "FAILED"
            ;;
        activating)
            echo "STARTING"
            ;;
        deactivating)
            echo "STOPPING"
            ;;
        maintenance)
            echo "MAINTENANCE"
            ;;
        *)
            if [[ -n "$state" ]]; then
                echo "${state^^}"
            else
                echo "UNKNOWN"
            fi
            ;;
    esac
}

friendly_enabled() {
    local state="$1"

    case "$state" in
        enabled)
            echo "ENABLED"
            ;;
        disabled)
            echo "DISABLED"
            ;;
        static)
            echo "STATIC"
            ;;
        masked)
            echo "MASKED"
            ;;
        indirect)
            echo "INDIRECT"
            ;;
        generated)
            echo "GENERATED"
            ;;
        transient)
            echo "TRANSIENT"
            ;;
        *)
            if [[ -n "$state" ]]; then
                echo "${state^^}"
            else
                echo "UNKNOWN"
            fi
            ;;
    esac
}

# ------------------------------------------------------------
# CUSTOM SERVICE DETECTION
# ------------------------------------------------------------

build_custom_service_list() {

    : > "$CUSTOM_FILE"

    local directory

    for directory in \
        "/etc/systemd/system" \
        "/usr/local/lib/systemd/system" \
        "/opt"
    do

        [[ -d "$directory" ]] || continue

        find "$directory" \
            -type f \
            -name "*.service" \
            -print 2>/dev/null

    done |
    while IFS= read -r path; do

        [[ -z "$path" ]] && continue

        basename "$path"

    done |
    sort -u > "$CUSTOM_FILE"
}

is_cached_custom_service() {

    local service="$1"

    grep -Fxq "$service" "$CUSTOM_FILE" 2>/dev/null
}

# ------------------------------------------------------------
# SERVICE LIST
# ------------------------------------------------------------

build_service_list() {

    : > "$SERVICE_FILE"

    systemctl list-unit-files \
        --type=service \
        --no-legend \
        --no-pager \
        2>/dev/null |
    while read -r service state rest; do

        [[ -z "$service" ]] && continue
        [[ "$service" != *.service ]] && continue

        echo "$service"

    done |
    sort -u > "$SERVICE_FILE"
}

# ------------------------------------------------------------
# ACTIVE SERVICE CACHE
# ------------------------------------------------------------

build_active_cache() {

    : > "$ACTIVE_FILE"

    systemctl list-units \
        --type=service \
        --all \
        --no-legend \
        --no-pager \
        2>/dev/null |
    while read -r unit load active sub description; do

        [[ -z "$unit" ]] && continue
        [[ "$unit" != *.service ]] && continue

        printf '%s|%s|%s\n' \
            "$unit" \
            "$active" \
            "$description"

    done > "$ACTIVE_FILE"
}

# ------------------------------------------------------------
# ENABLED CACHE
# ------------------------------------------------------------

build_enabled_cache() {

    : > "$ENABLED_FILE"

    systemctl list-unit-files \
        --type=service \
        --no-legend \
        --no-pager \
        2>/dev/null |
    while read -r service state rest; do

        [[ -z "$service" ]] && continue
        [[ "$service" != *.service ]] && continue

        printf '%s|%s\n' \
            "$service" \
            "$state"

    done > "$ENABLED_FILE"
}

# ------------------------------------------------------------
# FULL CACHE REFRESH
# ------------------------------------------------------------

refresh_service_cache() {

    build_service_list
    build_active_cache
    build_enabled_cache
    build_custom_service_list
}

# ------------------------------------------------------------
# CACHED DATA LOOKUPS
# ------------------------------------------------------------

get_cached_state() {

    local service="$1"
    local result

    result=$(
        grep -F "^${service}|" "$ACTIVE_FILE" 2>/dev/null |
        head -n 1 ||
        true
    )

    if [[ -n "$result" ]]; then
        echo "$result" | cut -d'|' -f2
    else
        echo "unknown"
    fi
}

get_cached_description() {

    local service="$1"
    local result

    result=$(
        grep -F "^${service}|" "$ACTIVE_FILE" 2>/dev/null |
        head -n 1 ||
        true
    )

    if [[ -n "$result" ]]; then
        echo "$result" | cut -d'|' -f3-
    else
        echo "No description"
    fi
}

get_cached_enabled() {

    local service="$1"
    local result

    result=$(
        grep -F "^${service}|" "$ENABLED_FILE" 2>/dev/null |
        head -n 1 ||
        true
    )

    if [[ -n "$result" ]]; then
        echo "$result" | cut -d'|' -f2
    else
        echo "unknown"
    fi
}

# ------------------------------------------------------------
# SERVICE STATISTICS
# ------------------------------------------------------------

get_service_statistics() {

    local total=0
    local running=0
    local stopped=0
    local failed=0
    local custom=0
    local enabled=0
    local disabled=0

    while IFS= read -r service; do

        [[ -z "$service" ]] && continue

        total=$((total + 1))

        local state
        local enabled_state

        state=$(get_cached_state "$service")
        enabled_state=$(get_cached_enabled "$service")

        case "$state" in
            active)
                running=$((running + 1))
                ;;
            failed)
                failed=$((failed + 1))
                ;;
            inactive)
                stopped=$((stopped + 1))
                ;;
        esac

        case "$enabled_state" in
            enabled)
                enabled=$((enabled + 1))
                ;;
            disabled)
                disabled=$((disabled + 1))
                ;;
        esac

        if is_cached_custom_service "$service"; then
            custom=$((custom + 1))
        fi

    done < "$SERVICE_FILE"

    echo "$total|$running|$stopped|$failed|$custom|$enabled|$disabled"
}

# ------------------------------------------------------------
# SERVICE FILTER
# ------------------------------------------------------------

service_matches_filter() {

    local service="$1"

    local state
    local enabled_state

    state=$(get_cached_state "$service")
    enabled_state=$(get_cached_enabled "$service")

    case "$CURRENT_FILTER" in

        ALL)
            return 0
            ;;

        RUNNING)
            [[ "$state" == "active" ]]
            ;;

        STOPPED)
            [[ "$state" == "inactive" ]]
            ;;

        FAILED)
            [[ "$state" == "failed" ]]
            ;;

        ENABLED)
            [[ "$enabled_state" == "enabled" ]]
            ;;

        DISABLED)
            [[ "$enabled_state" == "disabled" ]]
            ;;

        CUSTOM)
            is_cached_custom_service "$service"
            ;;

        SYSTEM)
            ! is_cached_custom_service "$service"
            ;;

        *)
            return 0
            ;;

    esac
}

# ------------------------------------------------------------
# SEARCH
# ------------------------------------------------------------

service_matches_search() {

    local service="$1"

    [[ -z "$CURRENT_SEARCH" ]] && return 0

    local description

    description=$(get_cached_description "$service")

    local service_lower
    local description_lower
    local search_lower

    service_lower=$(printf '%s' "$service" | tr '[:upper:]' '[:lower:]')
    description_lower=$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')
    search_lower=$(printf '%s' "$CURRENT_SEARCH" | tr '[:upper:]' '[:lower:]')

    [[ "$service_lower" == *"$search_lower"* ]] &&
        return 0

    [[ "$description_lower" == *"$search_lower"* ]]
}

# ------------------------------------------------------------
# FILTERED SERVICE LIST
# ------------------------------------------------------------

build_filtered_service_list() {

    : > "$SEARCH_FILE"

    while IFS= read -r service; do

        [[ -z "$service" ]] && continue

        service_matches_filter "$service" || continue
        service_matches_search "$service" || continue

        echo "$service"

    done < "$SERVICE_FILE"
}

# ------------------------------------------------------------
# SEARCH DIALOG
# ------------------------------------------------------------

search_services() {

    local search

    search=$(
        whiptail \
            --backtitle "$BACKTITLE" \
            --title "$TITLE | Search" \
            --inputbox \
            "Search service names and descriptions.

Examples:
  bluetooth
  ssh
  backup
  network

Leave empty to clear the search." \
            15 \
            70 \
            "$CURRENT_SEARCH" \
            3>&1 1>&2 2>&3
    ) || return

    CURRENT_SEARCH="$search"
}

# ------------------------------------------------------------
# FILTER MENU
# ------------------------------------------------------------

select_filter() {

    local selection

    selection=$(
        whiptail \
            --backtitle "$BACKTITLE" \
            --title "$TITLE | Filters" \
            --menu \
            "Select a service filter." \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            10 \
            "ALL" "All services" \
            "RUNNING" "Currently running" \
            "STOPPED" "Currently stopped" \
            "FAILED" "Failed services" \
            "ENABLED" "Enabled at boot" \
            "DISABLED" "Disabled at boot" \
            "CUSTOM" "Custom services" \
            "SYSTEM" "System services" \
            "BACK" "Return" \
            3>&1 1>&2 2>&3
    ) || return

    [[ "$selection" == "BACK" ]] && return

    CURRENT_FILTER="$selection"
}

# ------------------------------------------------------------
# SERVICE STATUS
# ------------------------------------------------------------

show_service_status() {

    local service="$1"

    local status_file="${TMP_DIR}/status_${service//\//_}.txt"

    systemctl status \
        "$service" \
        --no-pager \
        --full \
        > "$status_file" 2>&1 || true

    whiptail \
        --backtitle "$BACKTITLE" \
        --title "$TITLE | Status | $service" \
        --textbox \
        "$status_file" \
        "$TERM_HEIGHT" \
        "$TERM_WIDTH"
}

# ------------------------------------------------------------
# SERVICE DEPENDENCIES
# ------------------------------------------------------------

show_dependencies() {

    local service="$1"

    local dependency_data

    dependency_data=$(
        systemctl show \
            "$service" \
            --property=Requires \
            --property=Wants \
            --property=After \
            --property=Before \
            --no-pager \
            2>/dev/null ||
            true
    )

    local requires
    local wants
    local after
    local before

    requires=$(printf '%s\n' "$dependency_data" |
        sed -n 's/^Requires=//p')

    wants=$(printf '%s\n' "$dependency_data" |
        sed -n 's/^Wants=//p')

    after=$(printf '%s\n' "$dependency_data" |
        sed -n 's/^After=//p')

    before=$(printf '%s\n' "$dependency_data" |
        sed -n 's/^Before=//p')

    [[ -z "$requires" ]] && requires="None"
    [[ -z "$wants" ]] && wants="None"
    [[ -z "$after" ]] && after="None"
    [[ -z "$before" ]] && before="None"

    local output=""

    output+="SERVICE: ${service}"$'\n'
    output+=$'\n'

    output+="REQUIRES"$'\n'
    output+="${requires}"$'\n'
    output+=$'\n'

    output+="WANTS"$'\n'
    output+="${wants}"$'\n'
    output+=$'\n'

    output+="STARTS AFTER"$'\n'
    output+="${after}"$'\n'
    output+=$'\n'

    output+="STARTS BEFORE"$'\n'
    output+="${before}"

    local dependency_file="${TMP_DIR}/dependencies.txt"

    printf '%s\n' "$output" > "$dependency_file"

    whiptail \
        --backtitle "$BACKTITLE" \
        --title "$TITLE | Dependencies | $service" \
        --textbox \
        "$dependency_file" \
        "$TERM_HEIGHT" \
        "$TERM_WIDTH"
}

# ------------------------------------------------------------
# SERVICE CPU USAGE
# ------------------------------------------------------------

get_service_cpu() {

    local service="$1"

    local pid

    pid=$(
        systemctl show \
            "$service" \
            --property=MainPID \
            --value \
            --no-pager \
            2>/dev/null ||
            true
    )

    if [[ ! "$pid" =~ ^[0-9]+$ ]] || (( pid == 0 )); then
        echo "N/A"
        return
    fi

    if [[ ! -r "/proc/$pid/stat" ]]; then
        echo "N/A"
        return
    fi

    local utime
    local stime

    read -r utime stime < <(
        awk '{
            print $14, $15
        }' "/proc/$pid/stat" 2>/dev/null
    )

    if [[ ! "$utime" =~ ^[0-9]+$ ]] ||
       [[ ! "$stime" =~ ^[0-9]+$ ]]; then

        echo "N/A"
        return
    fi

    local total_ticks

    total_ticks=$((utime + stime))

    local clock_ticks

    clock_ticks=$(getconf CLK_TCK 2>/dev/null || echo 100)

    if (( clock_ticks <= 0 )); then
        clock_ticks=100
    fi

    local cpu_seconds

    cpu_seconds=$(awk \
        -v ticks="$total_ticks" \
        -v hz="$clock_ticks" \
        'BEGIN { printf "%.1f", ticks / hz }')

    echo "${cpu_seconds}s"
}

# ------------------------------------------------------------
# SERVICE MEMORY
# ------------------------------------------------------------

get_service_memory() {

    local service="$1"

    local memory

    memory=$(
        systemctl show \
            "$service" \
            --property=MemoryCurrent \
            --value \
            --no-pager \
            2>/dev/null ||
            true
    )

    if [[ ! "$memory" =~ ^[0-9]+$ ]] ||
       (( memory <= 0 )); then

        echo "N/A"
        return
    fi

    local memory_mb

    memory_mb=$((memory / 1024 / 1024))

    if (( memory_mb < 1 )); then
        echo "<1 MB"
    else
        echo "${memory_mb} MB"
    fi
}

# ------------------------------------------------------------
# SERVICE DETAILS
# ------------------------------------------------------------

show_service_details() {

    local service="$1"

    while true; do

        local detail_data

        detail_data=$(
            systemctl show \
                "$service" \
                --property=Description \
                --property=MainPID \
                --property=MemoryCurrent \
                --property=FragmentPath \
                --property=ActiveState \
                --property=SubState \
                --property=UnitFileState \
                --property=ActiveEnterTimestamp \
                --no-pager \
                2>/dev/null ||
                true
        )

        local description
        local pid
        local memory
        local fragment
        local state
        local substate
        local enabled
        local active_time

        description=$(printf '%s\n' "$detail_data" |
            sed -n 's/^Description=//p')

        pid=$(printf '%s\n' "$detail_data" |
            sed -n 's/^MainPID=//p')

        memory=$(printf '%s\n' "$detail_data" |
            sed -n 's/^MemoryCurrent=//p')

        fragment=$(printf '%s\n' "$detail_data" |
            sed -n 's/^FragmentPath=//p')

        state=$(printf '%s\n' "$detail_data" |
            sed -n 's/^ActiveState=//p')

        substate=$(printf '%s\n' "$detail_data" |
            sed -n 's/^SubState=//p')

        enabled=$(printf '%s\n' "$detail_data" |
            sed -n 's/^UnitFileState=//p')

        active_time=$(printf '%s\n' "$detail_data" |
            sed -n 's/^ActiveEnterTimestamp=//p')

        [[ -z "$description" ]] &&
            description="No description available"

        [[ -z "$pid" || "$pid" == "0" ]] &&
            pid="N/A"

        local memory_display="N/A"

        if [[ "$memory" =~ ^[0-9]+$ ]] &&
           (( memory > 0 )); then

            local memory_mb

            memory_mb=$((memory / 1024 / 1024))

            if (( memory_mb < 1 )); then
                memory_display="<1 MB"
            else
                memory_display="${memory_mb} MB"
            fi
        fi

        local enabled_display

        enabled_display=$(friendly_enabled "$enabled")

        local type_display

        if is_cached_custom_service "$service"; then
            type_display="CUSTOM"
        else
            type_display="SYSTEM"
        fi

        local state_display

        state_display=$(friendly_state "$state")

        local cpu_display

        cpu_display=$(get_service_cpu "$service")

        local details=""

        details+="SERVICE      ${service}"$'\n'
        details+="TYPE         ${type_display}"$'\n'
        details+="STATUS       ${state_display}"$'\n'
        details+="SUBSTATE     ${substate:-N/A}"$'\n'
        details+="ENABLED      ${enabled_display}"$'\n'
        details+="PID          ${pid}"$'\n'
        details+="MEMORY       ${memory_display}"$'\n'
        details+="CPU TIME     ${cpu_display}"$'\n'

        if [[ -n "$active_time" ]]; then
            details+="STARTED      ${active_time}"$'\n'
        fi

        details+=$'\n'
        details+="DESCRIPTION"$'\n'
        details+="${description}"$'\n'
        details+=$'\n'
        details+="UNIT FILE"$'\n'
        details+="${fragment:-Unknown}"

        local action

        action=$(
            whiptail \
                --backtitle "$BACKTITLE" \
                --title "$TITLE | ${service}" \
                --menu \
                "$details" \
                "$TERM_HEIGHT" \
                "$TERM_WIDTH" \
                14 \
                "START" "Start service" \
                "STOP" "Stop service" \
                "RESTART" "Restart service" \
                "ENABLE" "Enable at boot" \
                "DISABLE" "Disable at boot" \
                "STATUS" "View systemctl status" \
                "DEPENDENCIES" "View service dependencies" \
                "LOGS" "View recent logs" \
                "REFRESH" "Refresh information" \
                "BACK" "Return to services" \
                3>&1 1>&2 2>&3
        ) || return

        case "$action" in

            START)
                manage_service "$service" "start"
                ;;

            STOP)
                manage_service "$service" "stop"
                ;;

            RESTART)
                manage_service "$service" "restart"
                ;;

            ENABLE)
                manage_service "$service" "enable"
                ;;

            DISABLE)
                manage_service "$service" "disable"
                ;;

            STATUS)
                show_service_status "$service"
                ;;

            DEPENDENCIES)
                show_dependencies "$service"
                ;;

            LOGS)
                show_service_logs "$service"
                ;;

            REFRESH)
                refresh_service_cache
                ;;

            BACK)
                return
                ;;

        esac

    done
}

# ------------------------------------------------------------
# SERVICE CONTROL
# ------------------------------------------------------------

manage_service() {

    local service="$1"
    local action="$2"

    local action_name="${action^}"

    if ! whiptail \
        --backtitle "$BACKTITLE" \
        --title "$TITLE | Confirm" \
        --yesno \
        "${action_name} service?

${service}

Are you sure?" \
        10 \
        60; then

        return
    fi

    local output
    local exit_code=0

    output=$(
        sudo systemctl "$action" "$service" 2>&1
    ) || exit_code=$?

    if (( exit_code != 0 )); then

        whiptail \
            --backtitle "$BACKTITLE" \
            --title "$TITLE | Error" \
            --msgbox \
            "Failed to ${action}:

${service}

${output}" \
            14 \
            70

        return
    fi

    whiptail \
        --backtitle "$BACKTITLE" \
        --title "$TITLE | Success" \
        --msgbox \
        "${action_name} completed successfully.

${service}" \
        9 \
        60

    refresh_service_cache
}

# ------------------------------------------------------------
# SERVICE LOGS
# ------------------------------------------------------------

show_service_logs() {

    local service="$1"

    local log_file="${TMP_DIR}/service_logs.txt"

    if ! journalctl \
        -u "$service" \
        -n 100 \
        --no-pager \
        > "$log_file" \
        2>&1; then

        whiptail \
            --backtitle "$BACKTITLE" \
            --title "$TITLE | Logs" \
            --msgbox \
            "Unable to retrieve logs for:

${service}" \
            10 \
            60

        return
    fi

    if [[ ! -s "$log_file" ]]; then

        whiptail \
            --backtitle "$BACKTITLE" \
            --title "$TITLE | Logs" \
            --msgbox \
            "No journal entries were found for:

${service}" \
            10 \
            60

        return
    fi

    whiptail \
        --backtitle "$BACKTITLE" \
        --title "$TITLE | Logs | ${service}" \
        --textbox \
        "$log_file" \
        "$TERM_HEIGHT" \
        "$TERM_WIDTH"
}

# ------------------------------------------------------------
# FAILED SERVICES DASHBOARD
# ------------------------------------------------------------

show_failed_services() {

    while true; do

        local failed_count=0
        local menu_items=()

        menu_items+=(
            "__REFRESH__"
            "Refresh failed services"
        )

        menu_items+=(
            "__BACK__"
            "Return to Service Manager"
        )

        while IFS= read -r service; do

            [[ -z "$service" ]] && continue

            local state

            state=$(get_cached_state "$service")

            if [[ "$state" != "failed" ]]; then
                continue
            fi

            failed_count=$((failed_count + 1))

            local description

            description=$(get_cached_description "$service")

            [[ -z "$description" ]] &&
                description="No description"

            menu_items+=(
                "$service"
                "FAILED | ${description}"
            )

        done < "$SERVICE_FILE"

        if (( failed_count == 0 )); then

            whiptail \
                --backtitle "$BACKTITLE" \
                --title "$TITLE | Failed Services" \
                --msgbox \
                "No failed services were detected.

The systemd service manager currently reports no failed services." \
                11 \
                70

            return
        fi

        local selection

        selection=$(
            whiptail \
                --backtitle "$BACKTITLE" \
                --title "$TITLE | Failed Services" \
                --menu \
                "FAILED SERVICES: ${failed_count}

Select a failed service to investigate it." \
                "$TERM_HEIGHT" \
                "$TERM_WIDTH" \
                12 \
                "${menu_items[@]}" \
                3>&1 1>&2 2>&3
        ) || return

        case "$selection" in

            "__REFRESH__")
                refresh_service_cache
                ;;

            "__BACK__")
                return
                ;;

            *)
                show_service_details "$selection"
                ;;

        esac

    done
}

# ------------------------------------------------------------
# BOOT / STARTUP ANALYSIS
# ------------------------------------------------------------

show_boot_analysis() {

    local boot_file="${BOOT_FILE}"

    {
        echo "PiTweaks | Service Manager"
        echo "Boot / Startup Analysis"
        echo
        echo "SYSTEM BOOT"
        echo "------------"

        systemd-analyze 2>/dev/null || true

        echo
        echo "BOOT CRITICAL-CHAIN"
        echo "-------------------"

        systemd-analyze critical-chain \
            --no-pager \
            2>/dev/null ||
            echo "Critical-chain information unavailable."

        echo
        echo "SERVICE STARTUP TIMES"
        echo "---------------------"

        systemd-analyze blame \
            --no-pager \
            2>/dev/null |
            head -n 30 ||
            echo "Startup timing information unavailable."

    } > "$boot_file"

    whiptail \
        --backtitle "$BACKTITLE" \
        --title "$TITLE | Boot Analysis" \
        --textbox \
        "$boot_file" \
        "$TERM_HEIGHT" \
        "$TERM_WIDTH"
}

# ------------------------------------------------------------
# ENABLED SERVICE VIEW
# ------------------------------------------------------------

show_startup_services() {

    while true; do

        local menu_items=()

        menu_items+=(
            "__REFRESH__"
            "Refresh startup services"
        )

        menu_items+=(
            "__BACK__"
            "Return"
        )

        while IFS= read -r service; do

            [[ -z "$service" ]] && continue

            local enabled

            enabled=$(get_cached_enabled "$service")

            [[ "$enabled" != "enabled" ]] && continue

            local state

            state=$(get_cached_state "$service")

            local description

            description=$(get_cached_description "$service")

            [[ -z "$description" ]] &&
                description="No description"

            menu_items+=(
                "$service"
                "$(friendly_state "$state") | ${description}"
            )

        done < "$SERVICE_FILE"

        local selection

        selection=$(
            whiptail \
                --backtitle "$BACKTITLE" \
                --title "$TITLE | Enabled at Boot" \
                --menu \
                "Services configured to start automatically." \
                "$TERM_HEIGHT" \
                "$TERM_WIDTH" \
                14 \
                "${menu_items[@]}" \
                3>&1 1>&2 2>&3
        ) || return

        case "$selection" in

            "__REFRESH__")
                refresh_service_cache
                ;;

            "__BACK__")
                return
                ;;

            *)
                show_service_details "$selection"
                ;;

        esac

    done
}

# ------------------------------------------------------------
# DISABLED SERVICE VIEW
# ------------------------------------------------------------

show_disabled_services() {

    while true; do

        local menu_items=()

        menu_items+=(
            "__REFRESH__"
            "Refresh disabled services"
        )

        menu_items+=(
            "__BACK__"
            "Return"
        )

        while IFS= read -r service; do

            [[ -z "$service" ]] && continue

            local enabled

            enabled=$(get_cached_enabled "$service")

            [[ "$enabled" != "disabled" ]] && continue

            local state

            state=$(get_cached_state "$service")

            local description

            description=$(get_cached_description "$service")

            [[ -z "$description" ]] &&
                description="No description"

            menu_items+=(
                "$service"
                "$(friendly_state "$state") | ${description}"
            )

        done < "$SERVICE_FILE"

        local selection

        selection=$(
            whiptail \
                --backtitle "$BACKTITLE" \
                --title "$TITLE | Disabled at Boot" \
                --menu \
                "Services configured not to start automatically." \
                "$TERM_HEIGHT" \
                "$TERM_WIDTH" \
                14 \
                "${menu_items[@]}" \
                3>&1 1>&2 2>&3
        ) || return

        case "$selection" in

            "__REFRESH__")
                refresh_service_cache
                ;;

            "__BACK__")
                return
                ;;

            *)
                show_service_details "$selection"
                ;;

        esac

    done
}

# ------------------------------------------------------------
# MAIN SERVICE LIST
# ------------------------------------------------------------

show_services() {

    while true; do

        build_filtered_service_list

        local statistics

        statistics=$(get_service_statistics)

        local total
        local running
        local stopped
        local failed
        local custom
        local enabled
        local disabled

        IFS='|' read -r \
            total \
            running \
            stopped \
            failed \
            custom \
            enabled \
            disabled <<< "$statistics"

        local visible_count

        visible_count=$(wc -l < "$SEARCH_FILE" |
            tr -d ' ')

        local header=""

        header+="SERVICES   ${total}"$'\n'
        header+="RUNNING    ${running}"$'\n'
        header+="STOPPED    ${stopped}"$'\n'
        header+="FAILED     ${failed}"$'\n'
        header+="CUSTOM     ${custom}"$'\n'
        header+="ENABLED    ${enabled}"$'\n'
        header+="DISABLED   ${disabled}"$'\n'
        header+=$'\n'

        header+="FILTER     ${CURRENT_FILTER}"$'\n'

        if [[ -n "$CURRENT_SEARCH" ]]; then
            header+="SEARCH     ${CURRENT_SEARCH}"$'\n'
        else
            header+="SEARCH     None"$'\n'
        fi

        header+="VISIBLE    ${visible_count}"$'\n'
        header+=$'\n'
        header+="Select a service."

        # ----------------------------------------------------
        # MENU
        # ----------------------------------------------------

        local menu_items=()

        menu_items+=(
            "__SEARCH__"
            "Search services"
        )

        menu_items+=(
            "__FILTER__"
            "Filter services"
        )

        menu_items+=(
            "__FAILED__"
            "View failed services"
        )

        menu_items+=(
            "__STARTUP__"
            "View enabled startup services"
        )

        menu_items+=(
            "__DISABLED__"
            "View disabled services"
        )

        menu_items+=(
            "__BOOT__"
            "Boot / startup analysis"
        )

        menu_items+=(
            "__REFRESH__"
            "Refresh service data"
        )

        menu_items+=(
            "__CLEAR__"
            "Clear search / filter"
        )

        menu_items+=(
            "__BACK__"
            "Return to PiTweaks"
        )

        local system_services=()
        local custom_services=()

        local service

        while IFS= read -r service; do

            [[ -z "$service" ]] && continue

            if is_cached_custom_service "$service"; then
                custom_services+=("$service")
            else
                system_services+=("$service")
            fi

        done < "$SEARCH_FILE"

        # ----------------------------------------------------
        # SYSTEM SERVICES
        # ----------------------------------------------------

        for service in "${system_services[@]}"; do

            local state
            local state_display
            local description

            state=$(get_cached_state "$service")
            state_display=$(friendly_state "$state")

            description=$(get_cached_description "$service")

            [[ -z "$description" ]] &&
                description="No description"

            menu_items+=(
                "$service"
                "${state_display} | ${description}"
            )

        done

        # ----------------------------------------------------
        # CUSTOM SERVICES
        # ----------------------------------------------------

        for service in "${custom_services[@]}"; do

            local state
            local state_display
            local description

            state=$(get_cached_state "$service")
            state_display=$(friendly_state "$state")

            description=$(get_cached_description "$service")

            [[ -z "$description" ]] &&
                description="No description"

            menu_items+=(
                "$service"
                "[CUSTOM] ${state_display} | ${description}"
            )

        done

        # ----------------------------------------------------
        # DISPLAY MENU
        # ----------------------------------------------------

        local selection

        selection=$(
            whiptail \
                --backtitle "$BACKTITLE" \
                --title "$TITLE" \
                --menu \
                "$header" \
                "$TERM_HEIGHT" \
                "$TERM_WIDTH" \
                16 \
                "${menu_items[@]}" \
                3>&1 1>&2 2>&3
        ) || return

        case "$selection" in

            "__SEARCH__")
                search_services
                ;;

            "__FILTER__")
                select_filter
                ;;

            "__FAILED__")
                show_failed_services
                ;;

            "__STARTUP__")
                show_startup_services
                ;;

            "__DISABLED__")
                show_disabled_services
                ;;

            "__BOOT__")
                show_boot_analysis
                ;;

            "__REFRESH__")
                refresh_service_cache
                ;;

            "__CLEAR__")
                CURRENT_SEARCH=""
                CURRENT_FILTER="ALL"
                ;;

            "__BACK__")
                return
                ;;

            "")
                return
                ;;

            *)
                show_service_details "$selection"
                ;;

        esac

    done
}

# ------------------------------------------------------------
# INITIAL REFRESH
# ------------------------------------------------------------

refresh_service_cache

# ------------------------------------------------------------
# NO SERVICES
# ------------------------------------------------------------

if [[ ! -s "$SERVICE_FILE" ]]; then

    whiptail \
        --backtitle "$BACKTITLE" \
        --title "$TITLE" \
        --msgbox \
        "No systemd services were found on this system." \
        10 \
        65

    exit 0
fi

# ------------------------------------------------------------
# MAIN PROGRAM
# ------------------------------------------------------------

show_services

clear

exit 0
