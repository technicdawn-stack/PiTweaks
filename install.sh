#!/bin/bash

# ==============================================================================
# 🍓 DYNAMIC RASPBERRY PI SCRIPT INSTALLER (WITH SELF-UPDATE & INDEX FALLBACK)
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

# Function: Self-Update Installer Script
self_update() {
    clear
    echo "🔄 Checking for installer updates..."
    UPDATE_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/install.sh"
    
    if curl -fsSL "$UPDATE_URL" -o "$0"; then
        chmod +x "$0"
        echo "✅ Installer updated successfully! Restarting..."
        sleep 1
        exec "$0" "$@"
    else
        echo "❌ Update failed."
        exit 1
    fi
}

# Fetch index.txt from GitHub
INDEX_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/index.txt"
INDEX_DATA=$(curl -fsSL "$INDEX_URL" 2>/dev/null || true)

MENU_OPTIONS=()

# Always add "Update Installer" as the first choice
MENU_OPTIONS+=("UPDATE" "🔄 Update this installer script to latest version")

if [ -n "$INDEX_DATA" ]; then
    # Parse index.txt if available
    while IFS='|' read -r script desc; do
        [[ -z "$script" || "$script" =~ ^# ]] && continue
        [ -z "$desc" ] && desc="No description provided"
        MENU_OPTIONS+=("$script" "$desc")
    done <<< "$INDEX_DATA"
else
    # FALLBACK: If index.txt doesn't exist yet, build listing from GitHub API
    API_URL="https://api.github.com/repos/${USER}/${REPO}/contents?ref=${BRANCH}"
    HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" "$API_URL")
    HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
    RAW_FILES=$(echo "$HTTP_BODY" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep '\.sh$' | grep -v 'install.sh' || true)

    for script in $RAW_FILES; do
        MENU_OPTIONS+=("$script" "No description provided (index.txt pending)")
    done
fi

if [ "${#MENU_OPTIONS[@]}" -le 2 ]; then
    whiptail --title "No Scripts Found" --msgbox "No scripts available in repository." 8 50
    exit 1
fi

# Calculate responsive dimensions
TERM_HEIGHT=$(stty size 2>/dev/null | awk '{print $1}' || echo 20)
TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}' || echo 80)

BOX_HEIGHT=$(( TERM_HEIGHT - 4 ))
BOX_WIDTH=$(( TERM_WIDTH - 6 ))
MENU_HEIGHT=$(( BOX_HEIGHT - 8 ))

# Launch Whiptail Menu
SELECTED_SCRIPT=$(whiptail --clear \
    --backtitle "PiTweaks Script Manager" \
    --title "Script Selection Menu" \
    --menu "Select an action or script:" "$BOX_HEIGHT" "$BOX_WIDTH" "$MENU_HEIGHT" \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3) || {
        clear
        echo "Cancelled."
        exit 0
    }

# Handle Self-Update selection
if [ "$SELECTED_SCRIPT" = "UPDATE" ]; then
    self_update
fi

# Download and execute selected script
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
