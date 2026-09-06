#!/bin/bash

# ==============================================================================
# PI TWEAKS INSTALLER — SCRIPT LAUNCHER V5
# ==============================================================================
#
# Current index.txt format:
#
# category|script|description
#
# Example:
# 1st_Set|A_Test.sh|Loops the install url for faster and easier refreshing. V1.1
#
# Legacy two-field format is also supported:
#
# script|description
#
# ==============================================================================

set -eo pipefail

USER="technicdawn-stack"
REPO="PiTweaks"
BRANCH="main"

# ==============================================================================
# DEPENDENCIES
# ==============================================================================

if ! command -v curl &>/dev/null; then
    echo "curl is required but not installed."
    exit 1
fi

if ! command -v whiptail &>/dev/null; then
    echo "Installing whiptail..."
    sudo apt-get update -qq
    sudo apt-get install -y whiptail -qq
fi

# ==============================================================================
# FETCH INDEX
# ==============================================================================

INDEX_DATA=$(curl -fsSL \
    "https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/index.txt?cb=$(date +%s)" \
    2>/dev/null) || {
        echo "Could not load index.txt from GitHub."
        exit 1
    }

SEARCH_QUERY=""

# ==============================================================================
# TERMINAL SIZING
# ==============================================================================

get_terminal_size() {

    TERM_HEIGHT=$(stty size 2>/dev/null | awk '{print $1}')
    TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}')

    TERM_HEIGHT=${TERM_HEIGHT:-24}
    TERM_WIDTH=${TERM_WIDTH:-80}

    if (( TERM_HEIGHT < 15 )); then
        TERM_HEIGHT=15
    fi

    if (( TERM_WIDTH < 60 )); then
        TERM_WIDTH=60
    fi

    BOX_HEIGHT=$((TERM_HEIGHT - 2))
    BOX_WIDTH=$((TERM_WIDTH - 4))

    MENU_HEIGHT=$((BOX_HEIGHT - 8))

    if (( MENU_HEIGHT < 5 )); then
        MENU_HEIGHT=5
    fi
}

# ==============================================================================
# METADATA STORAGE
# ==============================================================================
#
# These arrays keep the UI data separate from the menu system.
#
# This gives us a clean place to add future metadata later without having to
# redesign the navigation system.
#
# Future possibilities:
#
# SCRIPT_VERSIONS
# SCRIPT_TYPES
# SCRIPT_REQUIREMENTS
# SCRIPT_SUDO
# SCRIPT_NETWORK
# SCRIPT_PERSISTENCE
#
# ==============================================================================

unset CATEGORIES
declare -A CATEGORIES
declare -A CATEGORY_COUNTS

declare -A SCRIPT_DESCRIPTIONS
declare -A SCRIPT_CATEGORIES
declare -A SCRIPT_VERSIONS

# ==============================================================================
# VERSION EXTRACTION
# ==============================================================================
#
# Extracts a trailing version such as:
#
# V1.1
# V1.3.7
# v2.0
#
# from the description.
#
# The complete description remains stored unchanged.
#
# ==============================================================================

extract_version() {

    local description="$1"
    local version=""

    if [[ "$description" =~ [[:space:]]([Vv][0-9]+([.][0-9]+)*)[[:space:]]*$ ]]; then
        version="${BASH_REMATCH[1]}"
    fi

    printf "%s" "$version"
}

# ==============================================================================
# PARSE INDEX.TXT
# ==============================================================================
#
# Supported:
#
# category|script|description
#
# Legacy:
#
# script|description
#
# Empty category:
#
# |script|description
#
# ==============================================================================

while IFS='|' read -r category script desc; do

    category=$(echo "$category" | tr -d '\r' | xargs)
    script=$(echo "$script" | tr -d '\r' | xargs)
    desc=$(echo "$desc" | tr -d '\r' | xargs)

    # Skip blank lines and comments.
    [[ -z "$script" || "$script" =~ ^# ]] && continue

    # --------------------------------------------------------------------------
    # Legacy two-field compatibility
    #
    # Old:
    #
    # A_Test.sh|Description
    #
    # Becomes:
    #
    # Uncategorized|A_Test.sh|Description
    # --------------------------------------------------------------------------

    if [[ -z "$desc" && -n "$script" ]]; then

        desc="$script"
        script="$category"
        category="Uncategorized"

    elif [[ -z "$category" ]]; then

        category="Uncategorized"

    fi

    # --------------------------------------------------------------------------
    # Store script information
    # --------------------------------------------------------------------------

    CATEGORIES["$category"]+="$script|$desc"$'\n'

    CATEGORY_COUNTS["$category"]=$(
        printf "%s" "${CATEGORY_COUNTS["$category"]:-0}" |
        awk '{print $1 + 1}'
    )

    SCRIPT_DESCRIPTIONS["$script"]="$desc"
    SCRIPT_CATEGORIES["$script"]="$category"

    version=$(extract_version "$desc")

    if [[ -n "$version" ]]; then
        SCRIPT_VERSIONS["$script"]="$version"
    else
        SCRIPT_VERSIONS["$script"]=""
    fi

done <<< "$INDEX_DATA"

# ==============================================================================
# SCRIPT DETAILS SCREEN
# ==============================================================================
#
# Uses a msgbox for information and a separate menu for actions.
#
# This avoids the rendering problem from V4 where the information was supplied
# as a menu prompt.
#
# Return:
#
#   0 = RUN selected
#   1 = BACK / ESC selected
#
# ==============================================================================

show_script_details() {

    local script="$1"
    local category="$2"
    local description="$3"

    local version="${SCRIPT_VERSIONS[$script]:-}"
    local DETAILS_MESSAGE
    local DETAILS_SELECTED

    description="${description:-No description provided.}"

    # --------------------------------------------------------------------------
    # Version display
    # --------------------------------------------------------------------------

    if [[ -n "$version" ]]; then

        version_text="$version"

    else

        version_text="Not specified"

    fi

    # --------------------------------------------------------------------------
    # Persistence cannot safely be determined until the actual script is
    # downloaded. Keep this informational rather than guessing.
    # --------------------------------------------------------------------------

    persistence_text="Detected at runtime"

    # --------------------------------------------------------------------------
    # Build information panel
    # --------------------------------------------------------------------------

    DETAILS_MESSAGE="Script

${script}

Category

${category}

Version

${version_text}

Description

${description}

Persistence

${persistence_text}"

    get_terminal_size

    # --------------------------------------------------------------------------
    # Display information
    # --------------------------------------------------------------------------

    whiptail \
        --clear \
        --backtitle "PiTweaks  |  ${category}" \
        --title "Script Information" \
        --msgbox \
        "$DETAILS_MESSAGE" \
        "$BOX_HEIGHT" \
        "$BOX_WIDTH" || {
            # ESC = return to previous screen.
            return 1
        }

    # --------------------------------------------------------------------------
    # Action menu
    # --------------------------------------------------------------------------

    local DETAILS_OPTIONS=(
        "RUN"
        "Run this script"
        "BACK"
        "Return to the previous menu"
    )

    DETAILS_SELECTED=$(
        whiptail \
            --clear \
            --backtitle "PiTweaks  |  ${category}  |  ${script}" \
            --title "Script Actions" \
            --menu \
            "Choose an action:" \
            10 \
            60 \
            2 \
            "${DETAILS_OPTIONS[@]}" \
            3>&1 1>&2 2>&3
    ) || {
        # ESC = return to previous screen.
        return 1
    }

    if [[ "$DETAILS_SELECTED" == "RUN" ]]; then
        return 0
    fi

    return 1
}

# ==============================================================================
# SEARCH RESULTS
# ==============================================================================

show_search() {

    while true; do

        SEARCH_PROMPT="Search by script name, description, or category."

        if [[ -n "$SEARCH_QUERY" ]]; then

            SEARCH_PROMPT+="

Current search: $SEARCH_QUERY"

        fi

        NEW_SEARCH=$(
            whiptail \
                --clear \
                --backtitle "PiTweaks  |  Script Search" \
                --title "Search" \
                --inputbox \
                "$SEARCH_PROMPT" \
                12 \
                68 \
                "$SEARCH_QUERY" \
                3>&1 1>&2 2>&3
        ) || {
            # ESC = homepage.
            return 1
        }

        SEARCH_QUERY=$(
            echo "$NEW_SEARCH" |
            tr '[:upper:]' '[:lower:]' |
            xargs
        )

        if [[ -z "$SEARCH_QUERY" ]]; then
            return 1
        fi

        # ----------------------------------------------------------------------
        # Build search results
        # ----------------------------------------------------------------------

        SEARCH_OPTIONS=()

        while IFS='|' read -r category script desc; do

            category=$(echo "$category" | tr -d '\r' | xargs)
            script=$(echo "$script" | tr -d '\r' | xargs)
            desc=$(echo "$desc" | tr -d '\r' | xargs)

            [[ -z "$script" || "$script" =~ ^# ]] && continue

            # Legacy compatibility.
            if [[ -z "$desc" && -n "$script" ]]; then

                desc="$script"
                script="$category"
                category="Uncategorized"

            elif [[ -z "$category" ]]; then

                category="Uncategorized"

            fi

            combined_text=$(
                printf "%s %s %s" \
                    "$script" \
                    "$desc" \
                    "$category" |
                tr '[:upper:]' '[:lower:]'
            )

            if [[ "$combined_text" == *"$SEARCH_QUERY"* ]]; then

                short_desc="$desc"

                if (( ${#short_desc} > 62 )); then
                    short_desc="${short_desc:0:59}..."
                fi

                SEARCH_OPTIONS+=(
                    "$script"
                    "${category}: ${short_desc:-No description}"
                )

            fi

        done <<< "$INDEX_DATA"

        # ----------------------------------------------------------------------
        # No results
        # ----------------------------------------------------------------------

        if [[ "${#SEARCH_OPTIONS[@]}" -eq 0 ]]; then

            whiptail \
                --clear \
                --title "No Results" \
                --msgbox \
                "No scripts matched:

$SEARCH_QUERY

Try another search term." \
                10 \
                55

            continue
        fi

        # ----------------------------------------------------------------------
        # Navigation
        # ----------------------------------------------------------------------

        SEARCH_OPTIONS+=(
            "BACK"
            "Return to the PiTweaks homepage"
        )

        get_terminal_size

        SEARCH_SELECTED=$(
            whiptail \
                --clear \
                --backtitle "PiTweaks  |  Search: ${SEARCH_QUERY}" \
                --title "Search Results" \
                --menu \
                "Select a script:" \
                "$BOX_HEIGHT" \
                "$BOX_WIDTH" \
                "$MENU_HEIGHT" \
                "${SEARCH_OPTIONS[@]}" \
                3>&1 1>&2 2>&3
        ) || {
            # ESC = homepage.
            return 1
        }

        if [[ "$SEARCH_SELECTED" == "BACK" ]]; then
            return 1
        fi

        # ----------------------------------------------------------------------
        # Script selected
        # ----------------------------------------------------------------------

        SELECTED="$SEARCH_SELECTED"

        CATEGORY="${SCRIPT_CATEGORIES[$SELECTED]:-Uncategorized}"
        DESCRIPTION="${SCRIPT_DESCRIPTIONS[$SELECTED]:-No description provided.}"

        # ----------------------------------------------------------------------
        # Details screen
        # ----------------------------------------------------------------------

        if show_script_details \
            "$SELECTED" \
            "$CATEGORY" \
            "$DESCRIPTION"; then

            return 0

        fi

    done
}

# ==============================================================================
# MAIN HOME / CATEGORY MENU
# ==============================================================================

while true; do

    get_terminal_size

    MENU_OPTIONS=()

    # ==========================================================================
    # SEARCH
    # ==========================================================================

    if [[ -n "$SEARCH_QUERY" ]]; then

        MENU_OPTIONS+=(
            "SEARCH"
            "Search: ${SEARCH_QUERY}"
        )

    else

        MENU_OPTIONS+=(
            "SEARCH"
            "Find a script by name, category or description"
        )

    fi

    # ==========================================================================
    # CATEGORY LIST
    # ==========================================================================

    while IFS= read -r category; do

        [[ -z "$category" ]] && continue

        count=${CATEGORY_COUNTS[$category]:-0}

        if (( count == 1 )); then
            count_text="1 script"
        else
            count_text="${count} scripts"
        fi

        MENU_OPTIONS+=(
            "$category"
            "$count_text"
        )

    done < <(
        printf "%s\n" "${!CATEGORIES[@]}" |
        sort -f
    )

    # ==========================================================================
    # EXIT
    # ==========================================================================

    MENU_OPTIONS+=(
        "EXIT"
        "Close PiTweaks installer"
    )

    # ==========================================================================
    # HOME SCREEN
    # ==========================================================================

    SELECTED=$(
        whiptail \
            --clear \
            --backtitle "PiTweaks  |  Raspberry Pi Script Manager" \
            --title "PiTweaks" \
            --menu \
            "Browse and run PiTweaks scripts:" \
            "$BOX_HEIGHT" \
            "$BOX_WIDTH" \
            "$MENU_HEIGHT" \
            "${MENU_OPTIONS[@]}" \
            3>&1 1>&2 2>&3
    ) || {
        # ESC on homepage = stay on homepage.
        continue
    }

    # ==========================================================================
    # SEARCH
    # ==========================================================================

    if [[ "$SELECTED" == "SEARCH" ]]; then

        if show_search; then
            break
        fi

        continue
    fi

    # ==========================================================================
    # EXIT
    # ==========================================================================

    if [[ "$SELECTED" == "EXIT" ]]; then

        clear
        echo "PiTweaks installer closed."
        exit 0

    fi

    # ==========================================================================
    # CATEGORY SELECTED
    # ==========================================================================

    CATEGORY="$SELECTED"

    while true; do

        get_terminal_size

        SCRIPT_OPTIONS=()

        # ----------------------------------------------------------------------
        # Scripts in selected category
        # ----------------------------------------------------------------------

        while IFS='|' read -r script desc; do

            [[ -z "$script" ]] && continue

            short_desc="$desc"

            if (( ${#short_desc} > 68 )); then
                short_desc="${short_desc:0:65}..."
            fi

            SCRIPT_OPTIONS+=(
                "$script"
                "${short_desc:-No description provided}"
            )

        done < <(
            printf "%s" "${CATEGORIES[$CATEGORY]}" |
            sort -f
        )

        # ----------------------------------------------------------------------
        # Navigation
        # ----------------------------------------------------------------------

        SCRIPT_OPTIONS+=(
            "BACK"
            "Return to categories"
        )

        # ----------------------------------------------------------------------
        # Category screen
        # ----------------------------------------------------------------------

        SCRIPT_SELECTED=$(
            whiptail \
                --clear \
                --backtitle "PiTweaks  |  ${CATEGORY}" \
                --title "${CATEGORY}" \
                --menu \
                "Select a script:" \
                "$BOX_HEIGHT" \
                "$BOX_WIDTH" \
                "$MENU_HEIGHT" \
                "${SCRIPT_OPTIONS[@]}" \
                3>&1 1>&2 2>&3
        ) || {
            # ESC = homepage.
            break
        }

        if [[ "$SCRIPT_SELECTED" == "BACK" ]]; then
            break
        fi

        # ----------------------------------------------------------------------
        # Script selected
        # ----------------------------------------------------------------------

        SELECTED="$SCRIPT_SELECTED"

        DESCRIPTION="${SCRIPT_DESCRIPTIONS[$SELECTED]:-No description provided.}"

        # ----------------------------------------------------------------------
        # Script details
        # ----------------------------------------------------------------------

        if show_script_details \
            "$SELECTED" \
            "$CATEGORY" \
            "$DESCRIPTION"; then

            break 2

        fi

    done

done

# ==============================================================================
# EXISTING INSTALL / EXECUTION FLOW
# ==============================================================================
#
# This section deliberately remains functionally equivalent to the previous
# installer versions.
#
# ==============================================================================

clear

echo "Downloading and preparing ${SELECTED}..."
echo "=========================================="
echo ""

# ==============================================================================
# DOWNLOAD SCRIPT
# ==============================================================================

curl -fsSL \
    "https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED}?cb=$(date +%s)" \
    -o "${SELECTED}"

# ==============================================================================
# MAKE EXECUTABLE
# ==============================================================================

chmod +x "${SELECTED}"

# ==============================================================================
# CHECK PERSISTENCE
# ==============================================================================

IS_PERSISTENT=false

if grep -qi "# PERSISTENT: TRUE" "${SELECTED}" ||
   [[ "${SELECTED}" == *"monitor"* ]]; then

    IS_PERSISTENT=true

fi

# ==============================================================================
# RUN LOCALLY
# ==============================================================================

./"${SELECTED}"

# ==============================================================================
# SMART CLEANUP
# ==============================================================================

if [ "$IS_PERSISTENT" = false ]; then

    rm -f "${SELECTED}"

    echo ""
    echo "=========================================="
    echo "Temporary script executed and cleaned up."

else

    echo ""
    echo "=========================================="
    echo "Persistent script installed and saved to disk (Cron/Daemon ready!)."

fi
