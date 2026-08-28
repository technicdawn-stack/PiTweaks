#!/bin/bash

# ==============================================================================
# 🍓 PI TWEAKS INSTALLER (SMART PERSISTENCE & CATEGORY GROUPING)
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

# 2. Parse index.txt with support for Category|Script|Desc or legacy Script|Desc
declare -A CATEGORIES

while IFS='|' read -r col1 col2 col3; do
    col1=$(echo "$col1" | tr -d '\r' | xargs)
    col2=$(echo "$col2" | tr -d '\r' | xargs)
    col3=$(echo "$col3" | tr -d '\r' | xargs)

    [[ -z "$col1" || "$col1" =~ ^# ]] && continue

    if [[ -z "$col3" ]]; then
        script="$col1"
        desc="$col2"
        category="General"
    else
        category="$col1"
        script="$col2"
        desc="$col3"
    fi

    CATEGORIES["$category"]+="$script|$desc"$'\n'
done <<< "$INDEX_DATA"

# 3. Build whiptail menu options grouped alphabetically by category with visual headers
MENU_OPTIONS=()
sorted_categories=$(printf "%s\n" "${!CATEGORIES[@]}" | sort)

for cat in $sorted_categories; do
    if [ "${#MENU_OPTIONS[@]}" -gt 0 ]; then
        MENU_OPTIONS+=("----------------------------------------" "")
    fi

    MENU_OPTIONS+=("► [ ${cat^^} ]" "")
    
    sorted_scripts=$(printf "%s" "${CATEGORIES[$cat]}" | sort)
    
    while IFS='|' read -r script desc; do
        [[ -z "$script" ]] && continue
        MENU_OPTIONS+=("$script" "    └─ ${desc:-No description provided}")
    done <<< "$sorted_scripts"
done

if [ "${#MENU_OPTIONS[@]}" -eq 0 ]; then
    echo "❌ No scripts found in index.txt."
    exit 1
fi

# 4. Get terminal size for responsive menu
TERM_HEIGHT=$(stty size 2>/dev/null | awk '{print $1}' || echo 20)
TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}' || echo 80)

BOX_HEIGHT=$(( TERM_HEIGHT - 4 ))
BOX_WIDTH=$(( TERM_WIDTH - 6 ))
MENU_HEIGHT=$(( BOX_HEIGHT - 8 ))

[ "$BOX_HEIGHT" -lt 10 ] && BOX_HEIGHT=10
[ "$BOX_WIDTH" -lt 40 ] && BOX_WIDTH=40
[ "$MENU_HEIGHT" -lt 5 ] && MENU_HEIGHT=5

# 5. Launch Whiptail TUI loop with validation against header selection
while true; do
    SELECTED=$(whiptail --clear \
        --backtitle "PiTweaks Script Manager" \
        --title "Script Selection Menu" \
        --menu "Select a script to execute:" "$BOX_HEIGHT" "$BOX_WIDTH" "$MENU_HEIGHT" \
        "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3) || {
            clear
            echo "Cancelled."
            exit 0
        }

    if [[ "$SELECTED" == "►"* || "$SELECTED" == "---"* ]]; then
        whiptail --title "Notice" --msgbox "Please select an actual script, not a category header or divider line." 8 50
        continue
    fi

    break
done

clear
echo "🚀 Downloading and preparing ${SELECTED}..."
echo "=========================================="
echo ""

# 6. Download script to disk using raw URL (automatically overwrites old versions safely)
curl -fsSL "https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED}?cb=$(date +%s)" -o "${SELECTED}"

# 7. Make it executable
chmod +x "${SELECTED}"

# 8. Check if the script requires persistence
IS_PERSISTENT=false
if grep -qi "# PERSISTENT: TRUE" "${SELECTED}" || [[ "${SELECTED}" == *"monitor"* ]]; then
    IS_PERSISTENT=true
fi

# 9. Run locally so interactive prompts work properly
./"${SELECTED}"

# 10. Smart Cleanup: Delete only if it's NOT a persistent background tool
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
