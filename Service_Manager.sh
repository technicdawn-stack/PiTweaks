#!/bin/bash

# ============================================================
# PiTweaks - Service Manager
# Service_Manager.sh
#
# PERSISTENT: TRUE
# Category: Administration
# Description: Friendly systemd service manager for viewing and controlling system services, custom scripts, startup settings, and logs. V1.2.1
#
# Features:
#   - Running / stopped / failed service overview
#   - Custom service detection
#   - Service details
#   - Start / Stop / Restart
#   - Enable / Disable
#   - Service logs
#   - Refresh
#
# Requirements:
#   - bash
#   - whiptail
#   - systemctl
#   - journalctl
# ============================================================

set -e

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

TITLE="PiTweaks | Service Manager"

# ------------------------------------------------------------
# Dependency checks
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
# Terminal sizing
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
# Temporary storage
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

# ------------------------------------------------------------
# Service information helpers
# ------------------------------------------------------------

get_service_state() {

    local service="$1"

    systemctl is-active "$service" 2>/dev/null || true
}

get_service_enabled() {

    local service="$1"

    systemctl is-enabled "$service" 2>/dev/null || true
}

get_service_description() {

    local service="$1"

    systemctl show \
        "$service" \
        --property=Description \
        --value \
        --no-pager \
        2>/dev/null || true
}

# ------------------------------------------------------------
# Friendly state formatting
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

# ------------------------------------------------------------
# Determine whether a service is custom
# ------------------------------------------------------------

is_custom_service() {

    local service="$1"
    local path=""

    path=$(systemctl show \
        "$service" \
        --property=FragmentPath \
        --value \
        --no-pager \
        2>/dev/null || true)

    case "$path" in

        /etc/systemd/system/*)
            return 0
            ;;

        /usr/local/lib/systemd/system/*)
            return 0
            ;;

        /opt/*)
            return 0
            ;;

        *)
            return 1
            ;;

    esac
}

# ------------------------------------------------------------
# Detect custom services from known locations
#
# This is used for the initial cache so we don't have to call
# systemctl show for every service.
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

# ------------------------------------------------------------
# Check whether service exists in custom cache
# ------------------------------------------------------------

is_cached_custom_service() {

    local service="$1"

    grep -Fxq "$service" "$CUSTOM_FILE"
}

# ------------------------------------------------------------
# Build service list
#
# Uses systemctl list-unit-files rather than repeatedly calling
# systemctl for every service.
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
# Build active service cache
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
# Build enabled cache
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
# Refresh all cached information
# ------------------------------------------------------------

refresh_service_cache() {

    build_service_list
    build_active_cache
    build_enabled_cache
    build_custom_service_list
}

# ------------------------------------------------------------
# Get cached active state
# ------------------------------------------------------------

get_cached_state() {

    local service="$1"
    local result

    result=$(grep -F "^${service}|" "$ACTIVE_FILE" 2>/dev/null | head -n 1 || true)

    if [[ -n "$result" ]]; then
        echo "$result" | cut -d'|' -f2
    else
        echo "unknown"
    fi
}

# ------------------------------------------------------------
# Get cached description
# ------------------------------------------------------------

get_cached_description() {

    local service="$1"
    local result

    result=$(grep -F "^${service}|" "$ACTIVE_FILE" 2>/dev/null | head -n 1 || true)

    if [[ -n "$result" ]]; then
        echo "$result" | cut -d'|' -f3-
    else
        echo "No description"
    fi
}

# ------------------------------------------------------------
# Get cached enabled state
# ------------------------------------------------------------

get_cached_enabled() {

    local service="$1"
    local result

    result=$(grep -F "^${service}|" "$ENABLED_FILE" 2>/dev/null | head -n 1 || true)

    if [[ -n "$result" ]]; then
        echo "$result" | cut -d'|' -f2
    else
        echo "unknown"
    fi
}

# ------------------------------------------------------------
# Get service PID
# ------------------------------------------------------------

get_service_pid() {

    local service="$1"

    systemctl show \
        "$service" \
        --property=MainPID \
        --value \
        --no-pager \
        2>/dev/null || true
}

# ------------------------------------------------------------
# Get service memory usage
# ------------------------------------------------------------

get_service_memory() {

    local service="$1"

    systemctl show \
        "$service" \
        --property=MemoryCurrent \
        --value \
        --no-pager \
        2>/dev/null || true
}

# ------------------------------------------------------------
# Get service unit file
# ------------------------------------------------------------

get_service_fragment() {

    local service="$1"

    systemctl show \
        "$service" \
        --property=FragmentPath \
        --value \
        --no-pager \
        2>/dev/null || true
}

# ------------------------------------------------------------
# Service statistics
#
# Uses cached information rather than running systemctl for
# every service.
# ------------------------------------------------------------

get_service_statistics() {

    local total=0
    local running=0
    local stopped=0
    local failed=0
    local custom=0

    while IFS= read -r service; do

        [[ -z "$service" ]] && continue

        total=$((total + 1))

        local state
        state=$(get_cached_state "$service")

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

        if is_cached_custom_service "$service"; then
            custom=$((custom + 1))
        fi

    done < "$SERVICE_FILE"

    echo "$total|$running|$stopped|$failed|$custom"
}

# ------------------------------------------------------------
# Service details
# ------------------------------------------------------------

show_service_details() {

    local service="$1"

    while true; do

        # ----------------------------------------------------
        # Fetch detailed information in one systemctl call
        # ----------------------------------------------------

        local detail_data

        detail_data=$(systemctl show \
            "$service" \
            --property=Description \
            --property=MainPID \
            --property=MemoryCurrent \
            --property=FragmentPath \
            --property=ActiveState \
            --property=UnitFileState \
            --no-pager \
            2>/dev/null || true)

        local description
        local pid
        local memory
        local fragment
        local state
        local enabled

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

        enabled=$(printf '%s\n' "$detail_data" |
            sed -n 's/^UnitFileState=//p')

        # ----------------------------------------------------
        # Defaults
        # ----------------------------------------------------

        [[ -z "$description" ]] &&
            description="No description available"

        [[ -z "$pid" || "$pid" == "0" ]] &&
            pid="N/A"

        # ----------------------------------------------------
        # Memory formatting
        # ----------------------------------------------------

        local memory_display="N/A"

        if [[ "$memory" =~ ^[0-9]+$ ]] && (( memory > 0 )); then

            local memory_mb

            memory_mb=$((memory / 1024 / 1024))

            if (( memory_mb < 1 )); then
                memory_display="<1 MB"
            else
                memory_display="${memory_mb} MB"
            fi

        fi

        # ----------------------------------------------------
        # Enabled formatting
        # ----------------------------------------------------

        local enabled_display

        case "$enabled" in

            enabled)
                enabled_display="YES"
                ;;

            disabled)
                enabled_display="NO"
                ;;

            static)
                enabled_display="STATIC"
                ;;

            masked)
                enabled_display="MASKED"
                ;;

            *)
                enabled_display="${enabled^^}"

                [[ -z "$enabled_display" ]] &&
                    enabled_display="UNKNOWN"

                ;;

        esac

        # ----------------------------------------------------
        # Service type
        # ----------------------------------------------------

        local type_display

        if is_cached_custom_service "$service"; then
            type_display="CUSTOM"
        else
            type_display="SYSTEM"
        fi

        # ----------------------------------------------------
        # Friendly status
        # ----------------------------------------------------

        local state_display

        state_display=$(friendly_state "$state")

        # ----------------------------------------------------
        # Details display
        # ----------------------------------------------------

        local details=""

        details+="SERVICE      ${service}"
        details+=$'\n'

        details+="TYPE         ${type_display}"
        details+=$'\n'

        details+="STATUS       ${state_display}"
        details+=$'\n'

        details+="ENABLED      ${enabled_display}"
        details+=$'\n'

        details+="PID          ${pid}"
        details+=$'\n'

        details+="MEMORY       ${memory_display}"
        details+=$'\n'

        details+=$'\n'

        details+="DESCRIPTION"
        details+=$'\n'

        details+="${description}"
        details+=$'\n'

        details+=$'\n'

        details+="UNIT FILE"
        details+=$'\n'

        details+="${fragment:-Unknown}"

        # ----------------------------------------------------
        # Action menu
        # ----------------------------------------------------

        local action

        action=$(whiptail \
            --backtitle "PiTweaks | Raspberry Pi Toolkit" \
            --title "$TITLE | ${service}" \
            --menu \
            "$details" \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            10 \
            "START" \
            "Start service" \
            "STOP" \
            "Stop service" \
            "RESTART" \
            "Restart service" \
            "ENABLE" \
            "Enable at boot" \
            "DISABLE" \
            "Disable at boot" \
            "LOGS" \
            "View recent logs" \
            "REFRESH" \
            "Refresh service information" \
            "BACK" \
            "Return to services" \
            3>&1 1>&2 2>&3) || return

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
# Service actions
# ------------------------------------------------------------

manage_service() {

    local service="$1"
    local action="$2"

    local action_name="${action^}"

    # --------------------------------------------------------
    # Confirmation
    # --------------------------------------------------------

    if ! whiptail \
        --title "$TITLE | Confirm" \
        --yesno \
        "${action_name} service?

${service}

Are you sure?" \
        10 60; then

        return
    fi

    # --------------------------------------------------------
    # Execute action
    # --------------------------------------------------------

    local output
    local exit_code=0

    output=$(
        sudo systemctl "$action" "$service" 2>&1
    ) || exit_code=$?

    # --------------------------------------------------------
    # Failure
    # --------------------------------------------------------

    if (( exit_code != 0 )); then

        whiptail \
            --title "$TITLE | Error" \
            --msgbox \
            "Failed to ${action}:

${service}

${output}" \
            14 70

        return
    fi

    # --------------------------------------------------------
    # Success
    # --------------------------------------------------------

    whiptail \
        --title "$TITLE | Success" \
        --msgbox \
        "${action_name} completed successfully.

${service}" \
        9 60

    # --------------------------------------------------------
    # Refresh cache after modifying service
    # --------------------------------------------------------

    refresh_service_cache
}

# ------------------------------------------------------------
# Service logs
# ------------------------------------------------------------

show_service_logs() {

    local service="$1"

    local log_file="${TMP_DIR}/service_logs.txt"

    if ! journalctl \
        -u "$service" \
        -n 80 \
        --no-pager \
        > "$log_file" 2>&1; then

        whiptail \
            --title "$TITLE | Logs" \
            --msgbox \
            "Unable to retrieve logs for:

${service}" \
            10 60

        return
    fi

    if [[ ! -s "$log_file" ]]; then

        whiptail \
            --title "$TITLE | Logs" \
            --msgbox \
            "No journal entries were found for:

${service}" \
            10 60

        return
    fi

    whiptail \
        --title "$TITLE | Logs | ${service}" \
        --textbox \
        "$log_file" \
        "$TERM_HEIGHT" \
        "$TERM_WIDTH"
}

# ------------------------------------------------------------
# Build friendly service menu
# ------------------------------------------------------------

show_services() {

    while true; do

        # ----------------------------------------------------
        # Statistics
        # ----------------------------------------------------

        local statistics

        statistics=$(get_service_statistics)

        IFS='|' read -r \
            total \
            running \
            stopped \
            failed \
            custom <<< "$statistics"

        # ----------------------------------------------------
        # Header
        # ----------------------------------------------------

        local header=""

        header+="SERVICES  ${total}"
        header+=$'\n'

        header+="RUNNING   ${running}"
        header+=$'\n'

        header+="STOPPED   ${stopped}"
        header+=$'\n'

        header+="FAILED    ${failed}"
        header+=$'\n'

        header+="CUSTOM    ${custom}"
        header+=$'\n'

        header+=$'\n'

        header+="Select a service."

        # ----------------------------------------------------
        # Build menu
        # ----------------------------------------------------

        local menu_items=()

        menu_items+=(
            "__REFRESH__"
            "Refresh service list"
        )

        menu_items+=(
            "__BACK__"
            "Return to PiTweaks"
        )

        # ----------------------------------------------------
        # System services first
        # ----------------------------------------------------

        local system_services=()
        local custom_services=()

        while IFS= read -r service; do

            [[ -z "$service" ]] && continue

            if is_cached_custom_service "$service"; then
                custom_services+=("$service")
            else
                system_services+=("$service")
            fi

        done < "$SERVICE_FILE"

        # ----------------------------------------------------
        # Add system services
        # ----------------------------------------------------

        local service

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
        # Add custom services
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
        # Service menu
        # ----------------------------------------------------

        local selection

        selection=$(whiptail \
            --backtitle "PiTweaks | Raspberry Pi Toolkit" \
            --title "$TITLE" \
            --menu \
            "$header" \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            14 \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || return

        # ----------------------------------------------------
        # Selection handling
        # ----------------------------------------------------

        case "$selection" in

            "__REFRESH__")

                refresh_service_cache

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
# Initial cache
# ------------------------------------------------------------

refresh_service_cache

# ------------------------------------------------------------
# No services found
# ------------------------------------------------------------

if [[ ! -s "$SERVICE_FILE" ]]; then

    whiptail \
        --title "$TITLE" \
        --msgbox \
        "No systemd services were found on this system." \
        10 65

    exit 0
fi

# ------------------------------------------------------------
# Main interface
# ------------------------------------------------------------

show_services

clear
exit 0
