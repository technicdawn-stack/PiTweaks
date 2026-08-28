#!/bin/bash

# ==============================================================================
# 🍓 PI TWEAKS INSTALLER (SMART PERSISTENCE & DYNAMIC HEADERS)
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

while true; do
    # 2. Parse index.txt and group items alphabetically by Category
    declare -A CATEGORIES

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

        # Filter by both script name and description if a search query exists
        if [[ -n "$SEARCH_QUERY" ]]; then
            combined_text=$(echo "$script $desc $category" | tr '[:upper:]' '[:lower:]')
            if [[ "$combined_text" != *"$SEARCH_QUERY"* ]]; then
                continue
            fi
        fi

        CATEGORIES["$category"]+="$script|$desc"$'\n'
    done <<< "$INDEX_DATA"

    # 3. Build whiptail menu options with a Search Action Button at the very top
    MENU_OPTIONS=()

    # Special interactive button item at the top
    if [[ -n "$SEARCH_QUERY" ]]; then
        MENU_OPTIONS+=("🔍 [CLEAR SEARCH: '$SEARCH_QUERY']" "Reset and view all available scripts")
    else
        MENU_OPTIONS+=("🔍 [SEARCH SCRIPTS...]" "Type a keyword to filter the menu list")
    fi
    MENU_OPTIONS+=("----------------------------------------" "")

    sorted_categories=$(printf "%s\n" "${!CATEGORIES[@]}" | sort)

    for cat in $sorted_categories; do
        MENU_OPTIONS+=("=== ${cat^^} ===" "")
        
        sorted_scripts=$(printf "%s" "${CATEGORIES[$cat]}" | sort)
        
        while IFS='|' read -r script desc; do
            [[ -z "$script" ]] && continue
            MENU_OPTIONS+=("$script" "    └─ ${desc:-No description provided}")
        done <<< "$sorted_scripts"
    done

    if [ "${#MENU_OPTIONS[@]}" -le 2 ]; then
        whiptail --title "Notice" --msgbox "No matching scripts found for your search query." 8 50
        SEARCH_QUERY=""
        continue
    fi

    # 4. Get terminal size for responsive menu
    TERM_HEIGHT=$(stty size 2>/dev/null | awk '{print $1}' || echo 20)
    TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}' || echo 80)

    BOX_HEIGHT=$(( TERM_HEIGHT - 4 ))
    BOX_WIDTH=$(( TERM_WIDTH - 6 ))
    MENU_HEIGHT=$(( BOX_HEIGHT - 8 ))

    # 5. Launch Whiptail TUI loop
    SELECTED=$(whiptail --clear \
        --backtitle "PiTweaks Script Manager" \
        --title "Script Selection Menu" \
        --menu "Select a script to execute:" "$BOX_HEIGHT" "$BOX_WIDTH" "$MENU_HEIGHT" \
        "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3) || {
            clear
            echo "Cancelled."
            exit 0
        }

    # Handle Search Button action
    if [[ "$SELECTED" == "🔍 [SEARCH SCRIPTS...]" ]]; then
        SEARCH_QUERY=$(whiptail --clear \
            --backtitle "PiTweaks Script Manager" \
            --title "Search Scripts" \
            --inputbox "Enter keyword to search names or descriptions:" 10 60 3>&1 1>&2 2>&3) || SEARCH_QUERY=""
        SEARCH_QUERY=$(echo "$SEARCH_QUERY" | tr '[:upper:]' '[:lower:]' | xargs)
        continue
    fi

    # Handle Clear Search action
    if [[ "$SELECTED" == "🔍 [CLEAR SEARCH"* ]]; then
        SEARCH_QUERY=""
        continue
    fi

    # Prevent selection of headers or divider lines
    if [[ "$SELECTED" == "==="%* || "$SELECTED" == "---"* ]]; then
        whiptail --title "Notice" --msgbox "Please select an actual script or the search option." 8 45
        continue
    fi

    break
done

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
