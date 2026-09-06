#!/bin/bash

# ==============================================================================
# 🍓 PI TWEAKS INSTALLER — CATEGORY UI V3
# ==============================================================================
set -eo pipefail

USER="technicdawn-stack"
REPO="PiTweaks"
BRANCH="main"

if ! command -v curl &>/dev/null; then
    echo "❌ 'curl' is required but not installed."
    exit 1
fi

if ! command -v whiptail &>/dev/null; then
    echo "🔍 Installing whiptail dependency..."
    sudo apt-get update -qq && sudo apt-get install -y whiptail -qq
fi

# ==============================================================================
# FETCH INDEX
# ==============================================================================

INDEX_DATA=$(curl -fsSL \
    "https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/index.txt?cb=$(date +%s)" \
    2>/dev/null) || {
    echo "❌ Could not load index.txt from GitHub."
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

    # Use if statements so set -e cannot terminate the script
    # when these conditions are false.
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

    CATEGORIES["$category"]+="$script|$desc"$'\n'

    # Increment safely with set -e enabled
    CATEGORY_COUNTS["$category"]=$(( ${CATEGORY_COUNTS["$category"]:-0} + 1 ))

done <<< "$INDEX_DATA"

# ==============================================================================
# MAIN CATEGORY LOOP
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
            "Search active: \"$SEARCH_QUERY\""
        )
    else
        MENU_OPTIONS+=(
            "SEARCH"
            "Search all scripts"
        )
    fi

    # ==========================================================================
    # CATEGORIES
    # ==========================================================================

    while IFS= read -r cat; do

        [[ -z "$cat" ]] && continue

        count=${CATEGORY_COUNTS[$cat]:-0}

        if (( count == 1 )); then
            count_text="1 script"
        else
            count_text="${count} scripts"
        fi

        MENU_OPTIONS+=(
            "$cat"
            "$count_text"
        )

    done < <(printf "%s\n" "${!CATEGORIES[@]}" | sort -f)

    # ==========================================================================
    # EXIT
    # ==========================================================================

    MENU_OPTIONS+=(
        "EXIT"
        "Exit PiTweaks installer"
    )

    # ==========================================================================
    # CATEGORY MENU
    # ==========================================================================

    SELECTED=$(whiptail --clear \
        --backtitle "PiTweaks Script Manager" \
        --title "PiTweaks — Categories" \
        --menu \
        "Select a category:" \
        "$BOX_HEIGHT" \
        "$BOX_WIDTH" \
        "$MENU_HEIGHT" \
        "${MENU_OPTIONS[@]}" \
        3>&1 1>&2 2>&3) || {
            clear
            echo "Cancelled."
            exit 0
        }

    # ==========================================================================
    # SEARCH
    # ==========================================================================

    if [[ "$SELECTED" == "SEARCH" ]]; then

        NEW_SEARCH=$(whiptail --clear \
            --backtitle "PiTweaks Script Manager" \
            --title "Search Scripts" \
            --inputbox \
            "Search by script name, description, or category:" \
            10 \
            65 \
            "$SEARCH_QUERY" \
            3>&1 1>&2 2>&3) || {
                continue
            }

        SEARCH_QUERY=$(echo "$NEW_SEARCH" | tr '[:upper:]' '[:lower:]' | xargs)

        # Empty search = return to category screen
        if [[ -z "$SEARCH_QUERY" ]]; then
            continue
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

            # Legacy format compatibility
            if [[ -z "$desc" && -n "$script" ]]; then
                desc="$script"
                script="$category"
                category="Uncategorized"

            elif [[ -z "$category" ]]; then
                category="Uncategorized"
            fi

            combined_text=$(printf "%s %s %s" \
                "$script" "$desc" "$category" |
                tr '[:upper:]' '[:lower:]')

            if [[ "$combined_text" == *"$SEARCH_QUERY"* ]]; then

                short_desc="$desc"

                if (( ${#short_desc} > 60 )); then
                    short_desc="${short_desc:0:57}..."
                fi

                SEARCH_OPTIONS+=(
                    "$script"
                    "[$category] ${short_desc:-No description}"
                )
            fi

        done <<< "$INDEX_DATA"

        # ----------------------------------------------------------------------
        # No results
        # ----------------------------------------------------------------------

        if [[ "${#SEARCH_OPTIONS[@]}" -eq 0 ]]; then

            whiptail --clear \
                --title "No Results" \
                --msgbox \
                "No scripts matched:

\"$SEARCH_QUERY\"

Try another search term." \
                10 \
                55

            SEARCH_QUERY=""
            continue
        fi

        # ----------------------------------------------------------------------
        # Search results menu
        # ----------------------------------------------------------------------

        get_terminal_size

        SEARCH_SELECTED=$(whiptail --clear \
            --backtitle "PiTweaks Script Manager" \
            --title "PiTweaks — Search" \
            --menu \
            "Results for: \"$SEARCH_QUERY\"" \
            "$BOX_HEIGHT" \
            "$BOX_WIDTH" \
            "$MENU_HEIGHT" \
            "${SEARCH_OPTIONS[@]}" \
            3>&1 1>&2 2>&3) || {
                continue
            }

        SELECTED="$SEARCH_SELECTED"

        break
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

            # Keep the menu readable
            if (( ${#short_desc} > 65 )); then
                short_desc="${short_desc:0:62}..."
            fi

            SCRIPT_OPTIONS+=(
                "$script"
                "└─ ${short_desc:-No description provided}"
            )

        done < <(printf "%s" "${CATEGORIES[$CATEGORY]}" | sort -f)

        # ----------------------------------------------------------------------
        # Category script menu
        #
        # ESC = back to category list
        # ----------------------------------------------------------------------

        SCRIPT_SELECTED=$(whiptail --clear \
            --backtitle "PiTweaks Script Manager  |  ${CATEGORY}" \
            --title "PiTweaks — ${CATEGORY}" \
            --menu \
            "Select a script to run:" \
            "$BOX_HEIGHT" \
            "$BOX_WIDTH" \
            "$MENU_HEIGHT" \
            "${SCRIPT_OPTIONS[@]}" \
            3>&1 1>&2 2>&3) || {
                break
            }

        SELECTED="$SCRIPT_SELECTED"

        break 2

    done

done

# ==============================================================================
# EXISTING INSTALL / EXECUTION FLOW
# ==============================================================================

clear
echo "🚀 Downloading and preparing ${SELECTED}..."
echo "=========================================="
echo ""

# 6. Download script to disk using raw URL
curl -fsSL "https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED}?cb=$(date +%s)" -o "${SELECTED}"

# 7. Make it executable
chmod +x "${SELECTED}"

# 8. Check if the script requires persistence
IS_PERSISTENT=false
if grep -qi "# PERSISTENT: TRUE" "${SELECTED}" || [[ "${SELECTED}" == *"monitor"* ]]; then
    IS_PERSISTENT=true
fi

# 9. Run locally
./"${SELECTED}"

# 10. Smart Cleanup
if [ "$IS_PERSISTENT" = false ]; then
    rm -f "${SELECTED}"
    echo ""
    echo "=========================================="
    echo "✔ Temporary script executed and cleaned up."
else
    echo ""
    echo "=========================================="
    echo "✔ Persistent script installed and saved to disk (Cron/Daemon ready)!"
fi
