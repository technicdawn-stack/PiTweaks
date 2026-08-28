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

# 2. Parse index.txt and group items alphabetically by Category (Fallback: Uncategorized)
declare -A CATEGORIES

while IFS='|' read -r category script desc; do
    # Strip leading/trailing whitespaces and carriage returns
    category=$(echo "$category" | tr -d '\r' | xargs)
    script=$(echo "$script" | tr -d '\r' | xargs)
    desc=$(echo "$desc" | tr -d '\r' | xargs)

    [[ -z "$script" || "$script" =~ ^# ]] && continue

    # If the format only provided 2 columns (Script|Desc), shift values and use fallback
    if [[ -z "$desc" && -n "$script" ]]; then
        desc="$script"
        script="$category"
        category="Uncategorized"
    elif [[ -z "$category" ]]; then
        category="Uncategorized"
    fi

    # Append to the category's item pool
    CATEGORIES["$category"]+="$script|$desc"$'\n'
done <<< "$INDEX_DATA"

# 3. Build whiptail menu options with prominent visual breaks and headers
MENU_OPTIONS=()

sorted_categories=$(printf "%s\n" "${!CATEGORIES[@]}" | sort)

for cat in $sorted_categories; do
    # Add prominent separator lines before categories (except the first one)
    if [ "${#MENU_OPTIONS[@]}" -gt 0 ]; then
        MENU_OPTIONS+=("========================================" "")
    fi

    # Enhanced prominent header block
    MENU_OPTIONS+=("▶ [ ${cat^^} ]" "")
    
    # Sort scripts within this category alphabetically
    sorted_scripts=$(printf "%s" "${CATEGORIES[$cat]}" | sort)
    
    while IFS='|' read -r script desc; do
        [[ -z "$script" ]] && continue
        MENU_OPTIONS+=("└─ $script" "- ${desc:-No description provided}")
    done <<< "$sorted_scripts"
done

if [ "${#MENU_OPTIONS[@]}" -eq 0 ]; then
    echo "❌ No valid scripts found in index.txt."
    exit 1
fi

# 4. Get terminal size for responsive menu
TERM_HEIGHT=$(stty size 2>/dev/null | awk '{print $1}' || echo 20)
TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}' || echo 80)

BOX_HEIGHT=$(( TERM_HEIGHT - 4 ))
BOX_WIDTH=$(( TERM_WIDTH - 6 ))
MENU_HEIGHT=$(( BOX_HEIGHT - 8 ))

# 5. Launch Whiptail TUI loop to handle category header selections gracefully
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

    # Prevent selection of category headers or prominent breaks
    if [[ "$SELECTED" == "▶"* || "$SELECTED" == "="* ]]; then
        whiptail --title "Notice" --msgbox "Please select an actual script, not a header or separator line." 8 50
        continue
    fi

    # Clean up the └─ prefix from the user's selection so it matches the raw filename on GitHub
    SELECTED=$(echo "$SELECTED" | sed 's/^└─ *//')

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
