#!/bin/bash

# ==============================================================================
# 🍓 DYNAMIC RASPBERRY PI SCRIPT INSTALLER (WHIPTAIL TUI)
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

# Auto-install whiptail if missing
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
    whiptail --title "Error" --msgbox "Failed to fetch repository contents (HTTP status: $HTTP_STATUS).\n\nGitHub API rate limit may have been exceeded." 10 60
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

# Build Whiptail menu arguments
MENU_OPTIONS=()
for i in "${!SCRIPTS[@]}"; do
    MENU_OPTIONS+=("$((i+1))" "${SCRIPTS[$i]}")
done

# Launch Whiptail TUI Menu
CHOICE=$(whiptail --clear \
    --backtitle "PiTweaks Script Manager" \
    --title "Script Selection Menu" \
    --menu "Use ARROW keys to select a script and press ENTER:" 18 65 8 \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3) || {
        clear
        echo "Cancelled."
        exit 0
    }

SELECTED_SCRIPT="${SCRIPTS[$((CHOICE-1))]}"
SCRIPT_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED_SCRIPT}"
TEMP_EXEC="/tmp/runner_${SELECTED_SCRIPT}"

# Download and execute
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
