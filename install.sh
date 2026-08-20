#!/bin/bash

# ==============================================================================
# 🍓 DYNAMIC RASPBERRY PI SCRIPT INSTALLER (CACHE-BUSTING INDEX REFRESH)
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

# Function to pull fresh index and populate options
fetch_fresh_index() {
    # Append timestamp to URL to bypass GitHub CDN caching
    INDEX_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/index.txt?t=$(date +%s)"
    INDEX_DATA=$(curl -fsSL -H "Cache-Control: no-cache" "$INDEX_URL" 2>/dev/null || true)

    MENU_OPTIONS=()
    MENU_OPTIONS+=("REFRESH" "🔄 Refresh index file & reload descriptions")

    if [ -n "$INDEX_DATA" ]; then
        while IFS='|' read -r script desc; do
            [[ -z "$script" || "$script" =~ ^# ]] && continue
            [ -z "$desc" ] && desc="No description provided"
            MENU_OPTIONS+=("$script" "$desc")
        done <<< "$INDEX_DATA"
    else
        # Fallback if index.txt isn't available yet
        API_URL="https://api.github.com/repos/${USER}/${REPO}/contents?ref=${BRANCH}"
        HTTP_RESPONSE=$(curl -s -H "Cache-Control: no-cache" "$API_URL")
        RAW_FILES=$(echo "$HTTP_RESPONSE" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep '\.sh$' | grep -v 'install.sh' || true)

        for script in $RAW_FILES; do
            MENU_OPTIONS+=("$script" "No description provided (index.txt pending)")
        done
    fi
}

# Main Menu Loop
while true; do
    fetch_fresh_index

    # Calculate responsive dimensions
    TERM_HEIGHT=$(stty size 2>/dev/null | awk '{print $1}' || echo 20)
    TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}' || echo 80)

    BOX_HEIGHT=$(( TERM_HEIGHT - 4 ))
    BOX_WIDTH=$(( TERM_WIDTH - 6 ))
    MENU_HEIGHT=$(( BOX_HEIGHT - 8 ))

    SELECTED_SCRIPT=$(whiptail --clear \
        --backtitle "PiTweaks Script Manager" \
        --title "Script Selection Menu" \
        --menu "Select a script to execute:" "$BOX_HEIGHT" "$BOX_WIDTH" "$MENU_HEIGHT" \
        "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3) || {
            clear
            echo "Cancelled."
            exit 0
        }

    # If user hits REFRESH, loop back to re-fetch index.txt
    if [ "$SELECTED_SCRIPT" = "REFRESH" ]; then
        continue
    fi

    break
done

# Download and execute chosen script
SCRIPT_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED_SCRIPT}?t=$(date +%s)"
TEMP_EXEC="/tmp/runner_${SELECTED_SCRIPT}"

if curl -fsSL -H "Cache-Control: no-cache" "$SCRIPT_URL" -o "$TEMP_EXEC"; then
    chmod +x "$TEMP_EXEC"
    
    clear
    echo "🚀 Executing ${SELECTED_SCRIPT}..."
    echo "=========================================="
    echo ""
    
    "$TEMP_EXEC"
    rm -f "$TEMP_EXEC"
else
    whiptail --title "Download Error" --msgbox "Failed to download $SELECTED_SCRIPT from GitHub." 8 50
    exit 1
fi
