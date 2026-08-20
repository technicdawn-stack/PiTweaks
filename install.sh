#!/bin/bash

# ==============================================================================
# 🍓 DYNAMIC RASPBERRY PI SCRIPT INSTALLER (WHIPTAIL + DESCRIPTIONS)
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

# Fetch list of .sh files dynamically from GitHub API
API_URL="https://api.github.com/repos/${USER}/${REPO}/contents?ref=${BRANCH}"
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" "$API_URL")
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [ "$HTTP_STATUS" -ne 200 ]; then
    whiptail --title "Error" --msgbox "Failed to fetch repository contents (HTTP status: $HTTP_STATUS)." 10 60
    exit 1
fi

RAW_FILES=$(echo "$HTTP_BODY" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep '\.sh$' | grep -v 'install.sh' || true)

SCRIPTS=()
while IFS= read -r line; do
    [ -n "$line" ] && SCRIPTS+=("$line")
done <<< "$RAW_FILES"

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    whiptail --title "No Scripts Found" --msgbox "No available installer scripts found in the repository." 8 50
    exit 1
fi

MENU_OPTIONS=()

# Process each script
for script in "${SCRIPTS[@]}"; do
    SCRIPT_RAW_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${script}"
    
    # 1-second connect timeout to prevent freeze
    HEADER=$(curl -sSL --connect-timeout 1 --max-time 2 "$SCRIPT_RAW_URL" | head -n 10 || true)
    
    # Extract line starting with '# Description:'
    DESC=$(echo "$HEADER" | grep -m1 -i '^# Description:' | cut -d':' -f2- | xargs || true)
    
    # Fallback string
    if [ -z "$DESC" ]; then
        DESC="No description provided"
    fi
    
    MENU_OPTIONS+=("$script" "$DESC")
done

# Dynamically calculate window dimensions based on terminal size
TERM_HEIGHT=$(tws 2>/dev/null || stty size 2>/dev/null | awk '{print $1}' || echo 20)
TERM_WIDTH=$(tws 2>/dev/null || stty size 2>/dev/null | awk '{print $2}' || echo 80)

BOX_HEIGHT=$(( TERM_HEIGHT - 4 ))
BOX_WIDTH=$(( TERM_WIDTH - 6 ))
MENU_HEIGHT=$(( BOX_HEIGHT - 8 ))

# Launch Whiptail TUI Menu
SELECTED_SCRIPT=$(whiptail --clear \
    --backtitle "PiTweaks Script Manager" \
    --title "Script Selection Menu" \
    --menu "Select a script to execute:" "$BOX_HEIGHT" "$BOX_WIDTH" "$MENU_HEIGHT" \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3) || {
        clear
        echo "Cancelled."
        exit 0
    }

SCRIPT_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED_SCRIPT}"
TEMP_EXEC="/tmp/runner_${SELECTED_SCRIPT}"

if curl -fsSL "$SCRIPT_URL" -o "$TEMP_EXEC"; then
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
