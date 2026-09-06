#!/bin/bash

# ==============================================================================
# PI TWEAKS INSTALLER — SCRIPT LAUNCHER V4
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
# PARSE INDEX.TXT
# ==============================================================================

unset CATEGORIES
declare -A CATEGORIES
declare -A CATEGORY_COUNTS
declare -A SCRIPT_DESCRIPTIONS
declare -A SCRIPT_CATEGORIES

while IFS='|' read -r category script desc; do

    category=$(echo "$category" | tr -d '\r' | xargs)
    script=$(echo "$script" | tr -d '\r' | xargs)
    desc=$(echo "$desc" | tr -d '\r' | xargs)

    [[ -z "$script" || "$script" =~ ^# ]] && continue

    # --------------------------------------------------------------------------
    # Legacy index.txt compatibility
    # --------------------------------------------------------------------------

    if [[ -z "$desc" && -n "$script" ]]; then
        desc="$script"
        script="$category"
        category="Uncategorized"

    elif [[ -z "$category" ]]; then
        category="Uncategorized"
    fi

    # --------------------------------------------------------------------------
    # Store category/script information
    # --------------------------------------------------------------------------

    CATEGORIES["$category"]+="$script|$desc"$'\n'

    CATEGORY_COUNTS["$category"]=$(( ${CATEGORY_COUNTS["$category"]:-0} + 1 ))

    SCRIPT_DESCRIPTIONS["$script"]="$desc"
    SCRIPT_CATEGORIES["$script"]="$category"

done <<< "$INDEX_DATA"

# ==============================================================================
# SCRIPT INFORMATION SCREEN
# ==============================================================================

show_script_details() {

    local script="$1"
    local category="$2"
    local description="$3"

    description="${description:-No description provided.}"

    # --------------------------------------------------------------------------
    # Determine whether this script appears to be persistent.
    #
    # This is informational only at this stage.
    # The existing persistence check below remains authoritative.
    # --------------------------------------------------------------------------

    local persistence_status="Temporary"

    if [[ "$script" == *"monitor"* ]]; then
        persistence_status="Persistent"
    fi

    # --------------------------------------------------------------------------
    # Build information message
    # --------------------------------------------------------------------------

    local DETAILS_MESSAGE

    DETAILS_MESSAGE="Script

${script}

Category

${category}

Description

${description}

Type

${persistence_status}"

    get_terminal_size

    # --------------------------------------------------------------------------
    # Details menu
    # --------------------------------------------------------------------------

    local DETAILS_OPTIONS=(
        "RUN"
        "Run this script"
        "BACK"
        "Return to the previous menu"
    )

    local DETAILS_SELECTED

    DETAILS_SELECTED=$(
        whiptail \
            --clear \
            --backtitle "PiTweaks  |  ${category}" \
            --title "Script Information" \
            --menu \
            "$DETAILS_MESSAGE" \
            "$BOX_HEIGHT" \
            "$BOX_WIDTH" \
            "$MENU_HEIGHT" \
            "${DETAILS_OPTIONS[@]}" \
            3>&1 1>&2 2>&3
    ) || {
        # ESC = return to previous menu.
        return 1
    }

    if [[ "$DETAILS_SELECTED" == "RUN" ]]; then
        return 0
    fi

    return 1
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
                # ESC = back to homepage.
                break
            }

            SEARCH_QUERY=$(
                echo "$NEW_SEARCH" |
                tr '[:upper:]' '[:lower:]' |
                xargs
            )

            if [[ -z "$SEARCH_QUERY" ]]; then
                break
            fi

            # ------------------------------------------------------------------
            # Build search results
            # ------------------------------------------------------------------

            SEARCH_OPTIONS=()

            while IFS='|' read -r category script desc; do

                category=$(echo "$category" | tr -d '\r' | xargs)
                script=$(echo "$script" | tr -d '\r' | xargs)
                desc=$(echo "$desc" | tr -d '\r' | xargs)

                [[ -z "$script" || "$script" =~ ^# ]] && continue

                # Legacy format compatibility
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

            # ------------------------------------------------------------------
            # No results
            # ------------------------------------------------------------------

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

            # ------------------------------------------------------------------
            # Navigation
            # ------------------------------------------------------------------

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
                # ESC = back to homepage.
                break
            }

            if [[ "$SEARCH_SELECTED" == "BACK" ]]; then
                break
            fi

            # ------------------------------------------------------------------
            # Search result selected
            # ------------------------------------------------------------------

            SELECTED="$SEARCH_SELECTED"
            CATEGORY="${SCRIPT_CATEGORIES[$SELECTED]:-Uncategorized}"
            DESCRIPTION="${SCRIPT_DESCRIPTIONS[$SELECTED]:-No description provided.}"

            # ------------------------------------------------------------------
            # Show script details
            # ------------------------------------------------------------------

            if show_script_details \
                "$SELECTED" \
                "$CATEGORY" \
                "$DESCRIPTION"; then

                break 2

            else

                continue

            fi

        done

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
            # ESC = back to homepage.
            break
        }

        if [[ "$SCRIPT_SELECTED" == "BACK" ]]; then
            break
        fi

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

clear

echo "Downloading and preparing ${SELECTED}..."
echo "=========================================="
echo ""

# ==============================================================================
# DOWNLOAD
# ==============================================================================

curl -fsSL \
    "https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED}?cb=$(date +%s)" \
    -o "${SELECTED}"

# ==============================================================================
# MAKE EXECUTABLE
# ==============================================================================

chmod +x "${SELECTED}"

# ==============================================================================
# PERSISTENCE DETECTION
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
