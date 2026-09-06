#!/bin/bash

# ============================================================
# PiTweaks Installer
# UI-focused version
# ============================================================

set -e

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

USER="technicdawn-stack"
REPO="PiTweaks"
BRANCH="main"

BASE_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}"

INDEX_URL="${BASE_URL}/index.txt"

# ------------------------------------------------------------
# Terminal sizing
# ------------------------------------------------------------

TERM_HEIGHT=$(tput lines)
TERM_WIDTH=$(tput cols)

if (( TERM_HEIGHT < 20 )); then
    TERM_HEIGHT=20
fi

if (( TERM_WIDTH < 70 )); then
    TERM_WIDTH=70
fi

# ------------------------------------------------------------
# Dependency check
# ------------------------------------------------------------

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required."
    echo "Installing curl..."

    sudo apt-get update
    sudo apt-get install -y curl
fi

if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail is required."
    echo "Installing whiptail..."

    sudo apt-get update
    sudo apt-get install -y whiptail
fi

# ------------------------------------------------------------
# Temporary files
# ------------------------------------------------------------

TMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

INDEX_FILE="${TMP_DIR}/index.txt"

# ------------------------------------------------------------
# Download index
# ------------------------------------------------------------

if ! curl -fsSL \
    "${INDEX_URL}?cachebuster=$(date +%s)" \
    -o "$INDEX_FILE"; then

    whiptail \
        --title "PiTweaks" \
        --msgbox \
        "Unable to download the PiTweaks module index.\n\nPlease check your internet connection and try again." \
        10 60

    exit 1
fi

# ------------------------------------------------------------
# Data storage
# ------------------------------------------------------------

declare -A CATEGORIES
declare -A CATEGORY_COUNTS

declare -A SCRIPT_DESCRIPTIONS
declare -A SCRIPT_CATEGORIES
declare -A SCRIPT_VERSIONS

# ------------------------------------------------------------
# Version extraction
# ------------------------------------------------------------

extract_version() {
    local description="$1"
    local version=""

    if [[ "$description" =~ ([Vv][0-9]+([.][0-9]+)*)[[:space:]]*$ ]]; then
        version="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$version" ]]; then
        echo "$version"
    else
        echo "Not specified"
    fi
}

# ------------------------------------------------------------
# Parse index
#
# Supported:
#
# category|script|description
#
# Legacy:
#
# script|description
# ------------------------------------------------------------

while IFS='|' read -r category script desc; do

    # Ignore blank lines
    [[ -z "$category" ]] && continue

    # Ignore comments
    [[ "$category" == \#* ]] && continue

    # Legacy two-field format
    if [[ -z "$desc" && -n "$script" ]]; then
        desc="$script"
        script="$category"
        category="Uncategorized"
    elif [[ -z "$category" ]]; then
        category="Uncategorized"
    fi

    # Skip malformed entries
    [[ -z "$script" ]] && continue

    version=$(extract_version "$desc")

    CATEGORIES["$category"]+="$script|$desc"$'\n'

    CATEGORY_COUNTS["$category"]=$(
        printf '%s' "${CATEGORY_COUNTS["$category"]:-0}"
    )

    CATEGORY_COUNTS["$category"]=$(
        (
            count="${CATEGORY_COUNTS["$category"]:-0}"
            count=$((count + 1))
            echo "$count"
        )
    )

    SCRIPT_DESCRIPTIONS["$script"]="$desc"
    SCRIPT_CATEGORIES["$script"]="$category"
    SCRIPT_VERSIONS["$script"]="$version"

done < "$INDEX_FILE"

# ------------------------------------------------------------
# Get sorted categories
# ------------------------------------------------------------

get_sorted_categories() {
    printf '%s\n' "${!CATEGORIES[@]}" | sort
}

# ------------------------------------------------------------
# Run script
# ------------------------------------------------------------

run_script() {

    local category="$1"
    local script="$2"

    local selected="${TMP_DIR}/${script}"

    clear

    echo "============================================================"
    echo " PiTweaks"
    echo "============================================================"
    echo
    echo " Category : $category"
    echo " Script   : $script"
    echo
    echo " Downloading module..."
    echo

    if ! curl -fsSL \
        "${BASE_URL}/${script}?cachebuster=$(date +%s)" \
        -o "$selected"; then

        whiptail \
            --title "PiTweaks | Error" \
            --msgbox \
            "Failed to download:\n\n${script}\n\nPlease check your network connection or repository configuration." \
            12 70

        return
    fi

    chmod +x "$selected"

    # --------------------------------------------------------
    # Existing persistence detection
    # --------------------------------------------------------

    IS_PERSISTENT=false

    if grep -qi "# PERSISTENT: TRUE" "${selected}" || \
       [[ "${selected}" == *"monitor"* ]]; then
        IS_PERSISTENT=true
    fi

    echo "Module downloaded."
    echo

    if [[ "$IS_PERSISTENT" == true ]]; then
        echo "Persistent module detected."
    fi

    echo
    echo "Launching module..."
    echo

    bash "$selected"

    rm -f "$selected"
}

# ------------------------------------------------------------
# Script details screen
# ------------------------------------------------------------

show_script_details() {

    local category="$1"
    local script="$2"
    local description="${SCRIPT_DESCRIPTIONS["$script"]}"
    local version="${SCRIPT_VERSIONS["$script"]}"

    local persistence="Detected at runtime"

    while true; do

        local details=""

        details+="SCRIPT     ${script}"$'\n'
        details+="CATEGORY   ${category}"$'\n'
        details+="VERSION    ${version}"$'\n'
        details+=$'\n'
        details+="DESCRIPTION"$'\n'
        details+="${description}"$'\n'
        details+=$'\n'
        details+="PERSISTENCE   ${persistence}"

        if whiptail \
            --title "PiTweaks | Script Information" \
            --ok-button "RUN" \
            --cancel-button "BACK" \
            --yesno "$details" \
            18 76; then

            run_script "$category" "$script"

            return
        else
            return
        fi

    done
}

# ------------------------------------------------------------
# Search
# ------------------------------------------------------------

show_search() {

    while true; do

        local query

        query=$(whiptail \
            --title "PiTweaks | Search" \
            --inputbox \
            "Search scripts by name or description:" \
            10 70 \
            3>&1 1>&2 2>&3) || return

        [[ -z "$query" ]] && continue

        local results=()
        local seen=()

        for script in "${!SCRIPT_DESCRIPTIONS[@]}"; do

            local description="${SCRIPT_DESCRIPTIONS["$script"]}"

            if [[ "${script,,}" == *"${query,,}"* ]] || \
               [[ "${description,,}" == *"${query,,}"* ]]; then

                local category="${SCRIPT_CATEGORIES["$script"]}"

                results+=("$script")
                seen+=("$category|$script")
            fi

        done

        if (( ${#results[@]} == 0 )); then

            whiptail \
                --title "PiTweaks | Search" \
                --msgbox \
                "No scripts matched:\n\n${query}" \
                10 60

            continue
        fi

        local menu_items=()

        for entry in "${seen[@]}"; do

            IFS='|' read -r category script <<< "$entry"

            menu_items+=(
                "$script"
                "${category} — ${SCRIPT_DESCRIPTIONS["$script"]}"
            )

        done

        local selection

        selection=$(whiptail \
            --title "PiTweaks | Search Results" \
            --menu \
            "Search results for: ${query}" \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            12 \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || return

        [[ -z "$selection" ]] && return

        show_script_details \
            "${SCRIPT_CATEGORIES["$selection"]}" \
            "$selection"

    done
}

# ------------------------------------------------------------
# Category script menu
# ------------------------------------------------------------

show_category() {

    local category="$1"

    while true; do

        local menu_items=()

        menu_items+=(
            "__BACK__"
            "Return to categories"
        )

        while IFS= read -r entry; do

            [[ -z "$entry" ]] && continue

            local script
            local description

            IFS='|' read -r script description <<< "$entry"

            menu_items+=(
                "$script"
                "$description"
            )

        done <<< "${CATEGORIES["$category"]}"

        local selection

        selection=$(whiptail \
            --title "PiTweaks | ${category}" \
            --menu \
            "Select a script" \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            12 \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || return

        if [[ "$selection" == "__BACK__" ]]; then
            return
        fi

        [[ -z "$selection" ]] && return

        show_script_details "$category" "$selection"

    done
}

# ------------------------------------------------------------
# Main homepage
# ------------------------------------------------------------

show_home() {

    while true; do

        local menu_items=()

        # Search
        menu_items+=(
            "__SEARCH__"
            "Search all scripts"
        )

        # Categories
        while IFS= read -r category; do

            [[ -z "$category" ]] && continue

            local count="${CATEGORY_COUNTS["$category"]:-0}"

            menu_items+=(
                "$category"
                "${count} script(s)"
            )

        done < <(get_sorted_categories)

        # Exit
        menu_items+=(
            "__EXIT__"
            "Exit PiTweaks"
        )

        local selection

        selection=$(whiptail \
            --title "PiTweaks" \
            --menu \
            "Select an option" \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            14 \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || continue

        case "$selection" in

            "__SEARCH__")
                show_search
                ;;

            "__EXIT__")
                clear
                exit 0
                ;;

            "")
                continue
                ;;

            *)
                show_category "$selection"
                ;;

        esac

    done
}

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------

show_home
