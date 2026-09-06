#!/bin/bash

# ============================================================
# PiTweaks - Service Manager
# Service_Manager.sh

# Category: Administration
# Description:
# Friendly systemd service management for Raspberry Pi.
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
        2>/dev/null || true
}

get_service_pid() {

    local service="$1"

    systemctl show \
        "$service" \
        --property=MainPID \
        --value \
        2>/dev/null || true
}

get_service_memory() {

    local service="$1"

    systemctl show \
        "$service" \
        --property=MemoryCurrent \
        --value \
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

        *)
            echo "${state^^}"
            ;;

    esac
}

# ------------------------------------------------------------
# Determine whether a service is likely custom
# ------------------------------------------------------------

is_custom_service() {

    local service="$1"

    local path

    path=$(systemctl show \
        "$service" \
        --property=FragmentPath \
        --value \
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
# Build service list
# ------------------------------------------------------------

build_service_list() {

    local output_file="$1"

    : > "$output_file"

    systemctl list-unit-files \
        --type=service \
        --no-legend \
        --no-pager \
        2>/dev/null |
    awk '{print $1}' |
    grep '\.service$' |
    sort -u > "$output_file"

}

# ------------------------------------------------------------
# Service statistics
# ------------------------------------------------------------

get_service_statistics() {

    local service_file="$1"

    local total=0
    local running=0
    local stopped=0
    local failed=0
    local custom=0

    while IFS= read -r service; do

        [[ -z "$service" ]] && continue

        total=$((total + 1))

        local state
        state=$(get_service_state "$service")

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

        if is_custom_service "$service"; then
            custom=$((custom + 1))
        fi

    done < "$service_file"

    echo "$total|$running|$stopped|$failed|$custom"
}

# ------------------------------------------------------------
# Service details
# ------------------------------------------------------------

show_service_details() {

    local service="$1"

    while true; do

        local state
        local enabled
        local description
        local pid
        local memory
        local fragment

        state=$(get_service_state "$service")
        enabled=$(get_service_enabled "$service")
        description=$(get_service_description "$service")
        pid=$(get_service_pid "$service")
        memory=$(get_service_memory "$service")

        fragment=$(systemctl show \
            "$service" \
            --property=FragmentPath \
            --value \
            2>/dev/null || true)

        [[ -z "$description" ]] && description="No description available"
        [[ -z "$pid" ]] && pid="N/A"
        [[ "$pid" == "0" ]] && pid="N/A"
        [[ -z "$memory" ]] && memory="N/A"

        if [[ "$memory" =~ ^[0-9]+$ ]] && (( memory > 0 )); then
            memory_mb=$((memory / 1024 / 1024))
            memory_display="${memory_mb} MB"
        else
            memory_display="N/A"
        fi

        case "$enabled" in
            enabled)
                enabled_display="YES"
                ;;
            disabled)
                enabled_display="NO"
                ;;
            *)
                enabled_display="${enabled^^}"
                ;;
        esac

        if is_custom_service "$service"; then
            type_display="CUSTOM"
        else
            type_display="SYSTEM"
        fi

        local state_display
        state_display=$(friendly_state "$state")

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
        if [[ "$action" == "enable" || "$action" == "disable" ]]; then
            sudo systemctl "$action" "$service" 2>&1
        else
            sudo systemctl "$action" "$service" 2>&1
        fi
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
# Build friendly service menu
# ------------------------------------------------------------

show_services() {

    local service_file="$1"

    while true; do

        local menu_items=()

        # ----------------------------------------------------
        # Statistics
        # ----------------------------------------------------

        local statistics
        statistics=$(get_service_statistics "$service_file")

        IFS='|' read -r total running stopped failed custom <<< "$statistics"

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
        # Back
        # ----------------------------------------------------

        menu_items+=(
            "__BACK__"
            "Return to PiTweaks"
        )

        # ----------------------------------------------------
        # Service entries
        # ----------------------------------------------------

        while IFS= read -r service; do

            [[ -z "$service" ]] && continue

            local state
            local description
            local state_display

            state=$(get_service_state "$service")
            state_display=$(friendly_state "$state")

            description=$(get_service_description "$service")

            [[ -z "$description" ]] && description="No description"

            local prefix=""

            if is_custom_service "$service"; then
                prefix="[CUSTOM] "
            fi

            menu_items+=(
                "$service"
                "${prefix}${state_display} | ${description}"
            )

        done < "$service_file"

        # ----------------------------------------------------
        # Menu
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

        case "$selection" in

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
# Main
# ------------------------------------------------------------

SERVICE_FILE="${TMP_DIR}/services.txt"

build_service_list "$SERVICE_FILE"

if [[ ! -s "$SERVICE_FILE" ]]; then

    whiptail \
        --title "$TITLE" \
        --msgbox \
        "No systemd services were found on this system." \
        10 65

    exit 0
fi

show_services "$SERVICE_FILE"

clear
exit 0
