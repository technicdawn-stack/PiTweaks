#!/bin/bash

# ==============================================================================
# 🍓 DYNAMIC RASPBERRY PI SCRIPT INSTALLER (WHIPTAIL + DESCRIPTIONS)
# ==============================================================================
set -eo pipefail

USER="technicdawn-stack"
REPO="PiTweaks"
BRANCH="main"

# Check required commands
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

# Build Whiptail Menu Options with Dynamic Descriptions & Fallbacks
MENU_OPTIONS=()

for script in "${SCRIPTS[@]}"; do
    SCRIPT_RAW_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${script}"
    
    # Read the first 10 lines of the script with a 2-second timeout
    HEADER=$(curl -sSL --max-time 2 "$SCRIPT_RAW_URL" | head -n 10 || true)
    
    # Extract description comment
    DESC=$(echo "$HEADER" | grep -m1 -i '^# Description:' | cut -d':' -f2- | xargs || true)
    
    # Fallback if no description line exists
    if [ -z "$DESC" ]; then
        DESC="No description provided"
    fi
    
    MENU_OPTIONS+=("$script" "$DESC")
done

# Launch Whiptail TUI Menu
SELECTED_SCRIPT=$(whiptail --clear \
    --backtitle "PiTweaks Script Manager" \
    --title "Script Selection Menu" \
    --menu "Select a script to execute:" 20 78 10 \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3) || {
        clear
        echo "Cancelled."
        exit 0
    }

SCRIPT_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED_SCRIPT}"
TEMP_EXEC="/tmp/runner_${SELECTED_SCRIPT}"

# Download and execute selected script
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
