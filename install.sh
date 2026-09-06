#!/bin/bash

# ==============================================================================
# 🍓 PI TWEAKS INSTALLER — CATEGORY UI
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

# 1. Fetch index.txt straight into RAM with a cache-buster parameter
INDEX_DATA=$(curl -fsSL "https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/index.txt?cb=$(date +%s)" 2>/dev/null) || {
    echo "❌ Could not load index.txt from GitHub."
    exit 1
}

SEARCH_QUERY=""

# ==============================================================================
# UI HELPERS
# ==============================================================================

get_terminal_size() {
    TERM_HEIGHT=$(stty size 2>/dev/null | awk '{print $1}')
    TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}')

    TERM_HEIGHT=${TERM_HEIGHT:-24}
    TERM_WIDTH=${TERM_WIDTH:-80}

    # Keep Whiptail usable on smaller terminals
    (( TERM_HEIGHT < 15 )) && TERM_HEIGHT=15
    (( TERM_WIDTH < 60 )) && TERM_WIDTH=60

    BOX_HEIGHT=$((TERM_HEIGHT - 2))
    BOX_WIDTH=$((TERM_WIDTH - 4))
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

    # Legacy format compatibility
    if [[ -z "$desc" && -n "$script" ]]; then
        desc="$script"
        script="$category"
        category="Uncategorized"
    elif [[ -z "$category" ]]; then
        category="Uncategorized"
    fi

    CATEGORIES["$category"]+="$script|$desc"$'\n'
    ((CATEGORY_COUNTS["$category"]++)) || true

done <<< "$INDEX_DATA"

# ==============================================================================
# CATEGORY MENU
# ==============================================================================

while true; do

    get_terminal_size

    MENU_OPTIONS=()

    # --------------------------------------------------------------------------
    # Search
    # --------------------------------------------------------------------------

    if [[ -n "$SEARCH_QUERY" ]]; then
        MENU_OPTIONS+=(
            "SEARCH"
            "Current search: \"$SEARCH_QUERY\""
        )
    else
        MENU_OPTIONS+=(
            "SEARCH"
            "Search all scripts by name, description or category"
        )
    fi

    # --------------------------------------------------------------------------
    # Categories
    # --------------------------------------------------------------------------

    sorted_categories=$(printf "%s\n" "${!CATEGORIES[@]}" | sort -f)

    for cat in $sorted_categories; do
        count=${CATEGORY_COUNTS[$cat]}

        if (( count == 1 )); then
            label="1 script"
        else
            label="${count} scripts"
        fi

        MENU_OPTIONS+=(
            "$cat"
            "$label"
        )
    done

    MENU_OPTIONS+=(
        "EXIT"
        "Exit PiTweaks installer"
    )

    SELECTED=$(whiptail --clear \
        --backtitle "PiTweaks Script Manager" \
        --title "PiTweaks — Categories" \
        --menu "Select a category:" \
        "$BOX_HEIGHT" "$BOX_WIDTH" "$((BOX_HEIGHT - 8))" \
        "${MENU_OPTIONS[@]}" \
        3>&1 1>&2 2>&3) || {
            clear
            echo "Cancelled."
            exit 0
        }

    # ==============================================================================
    # SEARCH
    # ==============================================================================

    if [[ "$SELECTED" == "SEARCH" ]]; then

        SEARCH_QUERY=$(whiptail --clear \
            --backtitle "PiTweaks Script Manager" \
            --title "Search Scripts" \
            --inputbox \
            "Search by script name, description, or category:" \
            10 65 \
            "$SEARCH_QUERY" \
            3>&1 1>&2 2>&3) || {
                continue
            }

        SEARCH_QUERY=$(echo "$SEARCH_QUERY" | tr '[:upper:]' '[:lower:]' | xargs)

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

            if [[ -z "$desc" && -n "$script" ]]; then
                desc="$script"
                script="$category"
                category="Uncategorized"
            elif [[ -z "$category" ]]; then
                category="Uncategorized"
            fi

            combined_text=$(echo "$script $desc $category" | tr '[:upper:]' '[:lower:]')

            if [[ "$combined_text" == *"$SEARCH_QUERY"* ]]; then
                SEARCH_OPTIONS+=(
                    "$script"
                    "[$category] ${desc:-No description provided}"
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
                10 55

            SEARCH_QUERY=""
            continue
        fi

        # ----------------------------------------------------------------------
        # Search results menu
        # ----------------------------------------------------------------------

        get_terminal_size

        SEARCH_OPTIONS+=(
            "BACK"
            "Return to categories"
        )

        SELECTED=$(whiptail --clear \
            --backtitle "PiTweaks Script Manager" \
            --title "PiTweaks — Search Results" \
            --menu \
            "Search results for: \"$SEARCH_QUERY\"" \
            "$BOX_HEIGHT" "$BOX_WIDTH" "$((BOX_HEIGHT - 8))" \
            "${SEARCH_OPTIONS[@]}" \
            3>&1 1>&2 2>&3) || {
                continue
            }

        if [[ "$SELECTED" == "BACK" ]]; then
            continue
        fi

        break
    fi

    # ==============================================================================
    # EXIT
    # ==============================================================================

    if [[ "$SELECTED" == "EXIT" ]]; then
        clear
        echo "PiTweaks installer closed."
        exit 0
    fi

    # ==============================================================================
    # CATEGORY SELECTED
    # ==============================================================================

    CATEGORY="$SELECTED"

    while true; do

        get_terminal_size

        SCRIPT_OPTIONS=()

        SCRIPT_OPTIONS+=(
            "BACK"
            "Return to categories"
        )

        sorted_scripts=$(printf "%s" "${CATEGORIES[$CATEGORY]}" | sort -f)

        while IFS='|' read -r script desc; do

            [[ -z "$script" ]] && continue

            SCRIPT_OPTIONS+=(
                "$script"
                "${desc:-No description provided}"
            )

        done <<< "$sorted_scripts"

        SELECTED=$(whiptail --clear \
            --backtitle "PiTweaks Script Manager" \
            --title "PiTweaks — ${CATEGORY}" \
            --menu \
            "Select a script:" \
            "$BOX_HEIGHT" "$BOX_WIDTH" "$((BOX_HEIGHT - 8))" \
            "${SCRIPT_OPTIONS[@]}" \
            3>&1 1>&2 2>&3) || {
                break
            }

        if [[ "$SELECTED" == "BACK" ]]; then
            break
        fi

        # A real script has been selected
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
