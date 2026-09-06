#!/bin/bash

# ============================================================
# PiTweaks Installer
# UI V6
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
# Dependency checks
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
# Temporary directory
# ------------------------------------------------------------

TMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

INDEX_FILE="${TMP_DIR}/index.txt"

# ------------------------------------------------------------
# Download module index
# ------------------------------------------------------------

if ! curl -fsSL \
    "${INDEX_URL}?cachebuster=$(date +%s)" \
    -o "$INDEX_FILE"; then

    whiptail \
        --title "PiTweaks | Error" \
        --msgbox \
        "Unable to download the PiTweaks module index.

Please check your internet connection and try again." \
        11 68

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
# Current format:
#
# category|script|description
#
# Legacy format:
#
# script|description
# ------------------------------------------------------------

while IFS='|' read -r category script desc; do

    # Ignore blank lines
    [[ -z "$category" ]] && continue

    # Ignore comments
    [[ "$category" == \#* ]] && continue

    # --------------------------------------------------------
    # Legacy two-field compatibility
    # --------------------------------------------------------

    if [[ -z "$desc" && -n "$script" ]]; then

        desc="$script"
        script="$category"
        category="Uncategorized"

    elif [[ -z "$category" ]]; then

        category="Uncategorized"

    fi

    # Skip malformed entries
    [[ -z "$script" ]] && continue

    # --------------------------------------------------------
    # Metadata
    # --------------------------------------------------------

    version=$(extract_version "$desc")

    CATEGORIES["$category"]+="$script|$desc"$'\n'

    count="${CATEGORY_COUNTS["$category"]:-0}"
    count=$((count + 1))
    CATEGORY_COUNTS["$category"]="$count"

    SCRIPT_DESCRIPTIONS["$script"]="$desc"
    SCRIPT_CATEGORIES["$script"]="$category"
    SCRIPT_VERSIONS["$script"]="$version"

done < "$INDEX_FILE"

# ------------------------------------------------------------
# Sorted categories
# ------------------------------------------------------------

get_sorted_categories() {

    printf '%s\n' "${!CATEGORIES[@]}" | sort
}

# ------------------------------------------------------------
# Run selected script
#
# IMPORTANT:
# Once a script is launched, the installer does NOT return
# to the PiTweaks UI.
#
# This prevents temporary modules such as SysInfo from having
# their output cleared/replaced by the installer.
# ------------------------------------------------------------

run_script() {

    local category="$1"
    local script="$2"

    local selected="${TMP_DIR}/${script}"

    # --------------------------------------------------------
    # Download
    # --------------------------------------------------------

    clear

    echo
    echo "============================================================"
    echo " PiTweaks"
    echo "============================================================"
    echo
    echo " Category : ${category}"
    echo " Script   : ${script}"
    echo
    echo " Downloading module..."
    echo

    if ! curl -fsSL \
        "${BASE_URL}/${script}?cachebuster=$(date +%s)" \
        -o "$selected"; then

        whiptail \
            --title "PiTweaks | Download Error" \
            --msgbox \
            "Failed to download:

${script}

Please check your network connection or repository configuration." \
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
        echo
    fi

    echo "Launching ${script}..."
    echo
    echo "------------------------------------------------------------"
    echo

    # --------------------------------------------------------
    # Run module
    #
    # Do NOT clear afterwards.
    # Do NOT return to the installer.
    # --------------------------------------------------------

    bash "$selected"

    SCRIPT_EXIT_CODE=$?

    # --------------------------------------------------------
    # Remove downloaded temporary module
    # --------------------------------------------------------

    rm -f "$selected"

    # --------------------------------------------------------
    # Leave the terminal exactly where the script left it.
    #
    # The installer intentionally exits here.
    # --------------------------------------------------------

    exit "$SCRIPT_EXIT_CODE"
}

# ------------------------------------------------------------
# Script details
# ------------------------------------------------------------

show_script_details() {

    local category="$1"
    local script="$2"

    local description="${SCRIPT_DESCRIPTIONS["$script"]}"
    local version="${SCRIPT_VERSIONS["$script"]}"

    local persistence="Detected at runtime"

    while true; do

        local details=""

        details+="SCRIPT       ${script}"
        details+=$'\n'
        details+="CATEGORY     ${category}"
        details+=$'\n'
        details+="VERSION      ${version}"
        details+=$'\n'
        details+=$'\n'
        details+="DESCRIPTION"
        details+=$'\n'
        details+="${description}"
        details+=$'\n'
        details+=$'\n'
        details+="PERSISTENCE  ${persistence}"

        if whiptail \
            --title "PiTweaks | Script Information" \
            --ok-button "RUN" \
            --cancel-button "BACK" \
            --yesno "$details" \
            17 76; then

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
            "Search by script name or description.

Press ESC to return to the home screen." \
            11 72 \
            3>&1 1>&2 2>&3) || return

        [[ -z "$query" ]] && continue

        local results=()

        while IFS= read -r script; do

            [[ -z "$script" ]] && continue

            local description="${SCRIPT_DESCRIPTIONS["$script"]}"

            if [[ "${script,,}" == *"${query,,}"* ]] || \
               [[ "${description,,}" == *"${query,,}"* ]]; then

                results+=("$script")

            fi

        done < <(printf '%s\n' "${!SCRIPT_DESCRIPTIONS[@]}" | sort)

        # ----------------------------------------------------
        # No results
        # ----------------------------------------------------

        if (( ${#results[@]} == 0 )); then

            whiptail \
                --title "PiTweaks | Search" \
                --msgbox \
                "No scripts matched:

${query}" \
                10 60

            continue
        fi

        # ----------------------------------------------------
        # Build result menu
        # ----------------------------------------------------

        local menu_items=()

        for script in "${results[@]}"; do

            local category="${SCRIPT_CATEGORIES["$script"]}"
            local description="${SCRIPT_DESCRIPTIONS["$script"]}"

            menu_items+=(
                "$script"
                "${category} | ${description}"
            )

        done

        local selection

        selection=$(whiptail \
            --title "PiTweaks | Search Results" \
            --menu \
            "Results for: ${query}

Select a module to view its information." \
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
# Category menu
# ------------------------------------------------------------

show_category() {

    local category="$1"

    while true; do

        local menu_items=()

        # Back option
        menu_items+=(
            "__BACK__"
            "Return to PiTweaks home"
        )

        # ----------------------------------------------------
        # Add scripts
        # ----------------------------------------------------

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
            "MODULES

Select a module to view its information." \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            12 \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || return

        if [[ "$selection" == "__BACK__" ]]; then
            return
        fi

        [[ -z "$selection" ]] && return

        show_script_details \
            "$category" \
            "$selection"

    done
}

# ------------------------------------------------------------
# Home screen
# ------------------------------------------------------------

show_home() {

    while true; do

        local menu_items=()

        # ----------------------------------------------------
        # Search section
        # ----------------------------------------------------

        menu_items+=(
            "SEARCH"
            "Search all PiTweaks modules"
        )

        # ----------------------------------------------------
        # Category section
        # ----------------------------------------------------

        while IFS= read -r category; do

            [[ -z "$category" ]] && continue

            local count="${CATEGORY_COUNTS["$category"]:-0}"

            if (( count == 1 )); then
                count_text="1 module"
            else
                count_text="${count} modules"
            fi

            menu_items+=(
                "$category"
                "${count_text} | Browse category"
            )

        done < <(get_sorted_categories)

        # ----------------------------------------------------
        # Exit
        # ----------------------------------------------------

        menu_items+=(
            "EXIT"
            "Close PiTweaks"
        )

        # ----------------------------------------------------
        # Home prompt
        # ----------------------------------------------------

        local selection

        selection=$(whiptail \
            --backtitle "PiTweaks | Raspberry Pi Toolkit" \
            --title "PiTweaks" \
            --menu \
            "HOME

Manage and run your Raspberry Pi modules.

SEARCH
Find a module by name or description.

MODULES
Browse modules by category.

Choose an option below." \
            "$TERM_HEIGHT" \
            "$TERM_WIDTH" \
            15 \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || continue

        # ----------------------------------------------------
        # Selection
        # ----------------------------------------------------

        case "$selection" in

            SEARCH)
                show_search
                ;;

            EXIT)
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
# Start PiTweaks
# ------------------------------------------------------------

show_home
