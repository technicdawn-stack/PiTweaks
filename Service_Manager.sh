#!/bin/bash

# ============================================================
# PiTweaks - Service Manager
# Service_Manager.sh
#
# PERSISTENT: TRUE
# Category: Administration
# Description: Friendly systemd service manager for viewing and controlling system services, custom scripts, startup settings, and logs. V1.2
# Friendly systemd service management for Raspberry Pi.
#
# Features:
#   - Running / stopped / failed service overview
#   - System and custom service separation
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
# ============================================================

set -e

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

TITLE="PiTweaks | Service Manager"

# ------------------------------------------------------------
# Dependency checks
# ------------------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then

    whiptail \
        --title "$TITLE | Error" \
        --msgbox \
        "systemctl was not found.

This system does not appear to be using systemd." \
        10 65

    exit 1
fi

if ! command -v whiptail >/dev/null 2>&1; then

    echo "whiptail is required."
    exit 1

fi

# ------------------------------------------------------------
# Terminal sizing
# ------------------------------------------------------------

TERM_HEIGHT=$(tput lines)
TERM_WIDTH=$(tput cols)

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
UNIT_FILE="${TMP_DIR}/unit_files.txt"
LOADED_FILE="${TMP_DIR}/loaded_services.txt"

# ------------------------------------------------------------
# Service metadata
# ------------------------------------------------------------

declare -A SERVICE_STATE
declare -A SERVICE_DESCRIPTION
declare -A SERVICE_ENABLED
declare -A SERVICE_CUSTOM

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
#
# This uses the common systemd locations directly rather than
# calling "systemctl show" for every service during startup.
# ------------------------------------------------------------

is_custom_service() {

    local service="$1"

    if [[ -e "/etc/systemd/system/${service}" ]] || \
       [[ -L "/etc/systemd/system/${service}" ]]; then
        return 0
    fi

    if [[ -e "/usr/local/lib/systemd/system/${service}" ]] || \
       [[ -L "/usr/local/lib/systemd/system/${service}" ]]; then
        return 0
    fi

    if [[ -e "/opt/${service}" ]] || \
       [[ -L "/opt/${service}" ]]; then
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Build service information
#
# Uses systemctl list commands once rather than repeatedly
# calling systemctl for every service.
# ------------------------------------------------------------

build_service_cache() {

    : > "$SERVICE_FILE"
    : > "$UNIT_FILE"
    : > "$LOADED_FILE"

    # --------------------------------------------------------
    # Get all known service unit files
    # --------------------------------------------------------

    systemctl list-unit-files \
        --type=service \
        --no-legend \
        --no-pager \
        2>/dev/null |
        awk '{print $1}' |
        grep '\.service$' |
        sort -u > "$UNIT_FILE" || true

    # --------------------------------------------------------
    # Get currently loaded services and their states
    # --------------------------------------------------------

    systemctl list-units \
        --type=service \
        --all \
        --no-legend \
        --no-pager \
        2>/dev/null |
        awk '
        {
            unit=$1
            load=$2
            active=$3
            sub=$4

            description=""

            for (i=5; i<=NF; i++) {
                description=description $i

                if (i<NF) {
                    description=description " "
                }
            }

            print unit "|" active "|" sub "|" description
        }' > "$LOADED_FILE" || true

    # --------------------------------------------------------
    # Reset metadata
    # --------------------------------------------------------

    SERVICE_STATE=()
    SERVICE_DESCRIPTION=()
    SERVICE_ENABLED=()
    SERVICE_CUSTOM=()

    # --------------------------------------------------------
    # Load enabled/disabled state
    # --------------------------------------------------------

    while IFS= read -r line; do

        [[ -z "$line" ]] && continue

        local service
        local enabled

        service=$(awk '{print $1}' <<< "$line")
        enabled=$(awk '{print $2}' <<< "$line")

        [[ -z "$service" ]] && continue

        SERVICE_ENABLED["$service"]="$enabled"

    done < <(
        systemctl list-unit-files \
            --type=service \
            --no-legend \
            --no-pager \
            2>/dev/null
    )

    # --------------------------------------------------------
    # Load active state and descriptions
    # --------------------------------------------------------

    while IFS='|' read -r service active sub description; do

        [[ -z "$service" ]] && continue

        SERVICE_STATE["$service"]="$active"

        if [[ -n "$description" ]]; then
            SERVICE_DESCRIPTION["$service"]="$description"
        else
            SERVICE_DESCRIPTION["$service"]="No description available"
        fi

    done < "$LOADED_FILE"

    # --------------------------------------------------------
    # Build complete service list
    # --------------------------------------------------------

    while IFS= read -r service; do

        [[ -z "$service" ]] && continue

        # Default state for units which are installed but not
        # currently loaded.
        if [[ -z "${SERVICE_STATE["$service"]+exists}" ]]; then
            SERVICE_STATE["$service"]="inactive"
        fi

        if [[ -z "${SERVICE_DESCRIPTION["$service"]+exists}" ]]; then
            SERVICE_DESCRIPTION["$service"]="No description available"
        fi

        if is_custom_service "$service"; then
            SERVICE_CUSTOM["$service"]="true"
        else
            SERVICE_CUSTOM["$service"]="false"
        fi

        echo "$service" >> "$SERVICE_FILE"

    done < "$UNIT_FILE"

    sort -u "$SERVICE_FILE" -o "$SERVICE_FILE"
}

# ------------------------------------------------------------
# Service statistics
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

        case "${SERVICE_STATE["$service"]:-unknown}" in

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

        if [[ "${SERVICE_CUSTOM["$service"]:-false}" == true ]]; then
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

        local details_file="${TMP_DIR}/details.txt"

        # ----------------------------------------------------
        # Query detailed information only when needed.
        # Multiple properties are retrieved in one systemctl
        # call instead of several separate calls.
        # ----------------------------------------------------

        local detail_data

        detail_data=$(systemctl show "$service" \
            --property=Description \
            --property=MainPID \
            --property=MemoryCurrent \
            --property=FragmentPath \
            --property=ActiveState \
            --property=UnitFileState \
            --value \
            2>/dev/null || true)

        local description
        local pid
        local memory
        local fragment
        local state
        local enabled

        description=$(systemctl show "$service" \
            --property=Description \
            --value \
            2>/dev/null || true)

        pid=$(systemctl show "$service" \
            --property=MainPID \
            --value \
            2>/dev/null || true)

        memory=$(systemctl show "$service" \
            --property=MemoryCurrent \
            --value \
            2>/dev/null || true)

        fragment=$(systemctl show "$service" \
            --property=FragmentPath \
            --value \
            2>/dev/null || true)

        state=$(systemctl show "$service" \
            --property=ActiveState \
            --value \
            2>/dev/null || true)

        enabled=$(systemctl show "$service" \
            --property=UnitFileState \
            --value \
            2>/dev/null || true)

        [[ -z "$description" ]] && \
            description="No description available"

        [[ -z "$pid" ]] && \
            pid="N/A"

        [[ "$pid" == "0" ]] && \
            pid="N/A"

        [[ -z "$memory" ]] && \
            memory="N/A"

        # ----------------------------------------------------
        # Memory formatting
        # ----------------------------------------------------

        local memory_display="N/A"

        if [[ "$memory" =~ ^[0-9]+$ ]] && (( memory > 0 )); then

            local memory_mb=$((memory / 1024 / 1024))

            if (( memory_mb >= 1 )); then
                memory_display="${memory_mb} MB"
            else
                memory_display="<1 MB"
            fi

        fi

        # ----------------------------------------------------
        # Enabled state
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
                enabled_display="${enabled:-UNKNOWN}"
                ;;

        esac

        # ----------------------------------------------------
        # Type
        # ----------------------------------------------------

        local type_display

        if [[ "${SERVICE_CUSTOM["$service"]:-false}" == true ]]; then
            type_display="CUSTOM"
        else
            type_display="SYSTEM"
        fi

        # ----------------------------------------------------
        # Status
        # ----------------------------------------------------

        local state_display
        state_display=$(friendly_state "$state")

        # ----------------------------------------------------
        # Create compact details display
        # ----------------------------------------------------

        local details=""

        details+="SERVICE      ${service}"
        details+=$'\n'
        details+="STATUS       ${state_display}"
        details+=$'\n'
        details+="TYPE         ${type_display}"
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
        # Service actions
        # ----------------------------------------------------

        local action

        action=$(whiptail \
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

    local output
    local exit_code=0

    output=$(
        sudo systemctl "$action" "$service" 2>&1
    ) || exit_code=$?

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
    # Update cached state immediately
    # --------------------------------------------------------

    case "$action" in

        start)
            SERVICE_STATE["$service"]="active"
            ;;

        stop)
            SERVICE_STATE["$service"]="inactive"
            ;;

        restart)
            SERVICE_STATE["$service"]="active"
            ;;

        enable)
            SERVICE_ENABLED["$service"]="enabled"
            ;;

        disable)
            SERVICE_ENABLED["$service"]="disabled"
            ;;

    esac

    whiptail \
        --title "$TITLE | Success" \
        --msgbox \
        "${action_name} completed successfully.

${service}" \
        9 60
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
# Service menu
# ------------------------------------------------------------

show_services() {

    while true; do

        local statistics

        statistics=$(get_service_statistics)

        local total
        local running
        local stopped
        local failed
        local custom

        IFS='|' read -r total running stopped failed custom <<< "$statistics"

        # ----------------------------------------------------
        # Main menu
        # ----------------------------------------------------

        local menu_items=()

        menu_items+=(
            "__REFRESH__"
            "Refresh service information"
        )

        menu_items+=(
            "__BACK__"
            "Return to PiTweaks"
        )

        # ----------------------------------------------------
        # System services
        # ----------------------------------------------------

        while IFS= read -r service; do

            [[ -z "$service" ]] && continue

            if [[ "${SERVICE_CUSTOM["$service"]:-false}" == true ]]; then
                continue
            fi

            local state="${SERVICE_STATE["$service"]:-unknown}"
            local state_display

            state_display=$(friendly_state "$state")

            local short_name="${service%.service}"

            menu_items+=(
                "$service"
                "${state_display} | ${short_name}"
            )

        done < "$SERVICE_FILE"

        # ----------------------------------------------------
        # Custom services
        # ----------------------------------------------------

        while IFS= read -r service; do

            [[ -z "$service" ]] && continue

            if [[ "${SERVICE_CUSTOM["$service"]:-false}" != true ]]; then
                continue
            fi

            local state="${SERVICE_STATE["$service"]:-unknown}"
            local state_display

            state_display=$(friendly_state "$state")

            local short_name="${service%.service}"

            menu_items+=(
                "$service"
                "[CUSTOM] ${state_display} | ${short_name}"
            )

        done < "$SERVICE_FILE"

        # ----------------------------------------------------
        # Header
        # ----------------------------------------------------

        local header=""

        header+="SERVICES    ${total}"
        header+=$'\n'
        header+="RUNNING     ${running}"
        header+=$'\n'
        header+="STOPPED     ${stopped}"
        header+=$'\n'
        header+="FAILED      ${failed}"
        header+=$'\n'
        header+="CUSTOM      ${custom}"
        header+=$'\n'
        header+=$'\n'
        header+="SYSTEM SERVICES"
        header+=$'\n'
        header+="Custom services are shown at the bottom."
        header+=$'\n'
        header+=$'\n'
        header+="Select a service to manage it."

        # ----------------------------------------------------
        # Display
        # ----------------------------------------------------

        local selection

        selection=$(whiptail \
            --backtitle "PiTweaks | Raspberry Pi Toolkit" \
            --title "$TITLE" \
            --menu \
            "$header" \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            16 \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || return

        case "$selection" in

            "__REFRESH__")

                build_service_cache

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

build_service_cache

# ------------------------------------------------------------
# No services
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
# Start
# ------------------------------------------------------------

show_services

clear
exit 0
