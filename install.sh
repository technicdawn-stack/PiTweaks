#!/bin/bash

clear

# ==============================================================================
# 🍓 DYNAMIC RASPBERRY PI SCRIPT INSTALLER (FULLY AUTOMATED)
# ==============================================================================
USER="technicdawn-stack"
REPO="PiTweaks"
BRANCH="main"

echo "=========================================="
echo " 🍓 Raspberry Pi Script Installer"
echo "=========================================="
echo "🔍 Fetching available scripts from GitHub..."
echo ""

# Fetch list of .sh files dynamically from GitHub API
API_URL="https://api.github.com/repos/${USER}/${REPO}/contents?ref=${BRANCH}"
RAW_FILES=$(curl -s "$API_URL" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep '\.sh$' | grep -v 'install.sh')

SCRIPTS=()
while IFS= read -r line; do
    [ -n "$line" ] && SCRIPTS+=("$line")
done <<< "$RAW_FILES"

NUM_SCRIPTS=${#SCRIPTS[@]}

if [ "$NUM_SCRIPTS" -eq 0 ]; then
    echo "❌ No available installer scripts found in repository."
    exit 1
fi

# Display menu dynamically
for i in "${!SCRIPTS[@]}"; do
    echo "  $((i+1))) ${SCRIPTS[$i]}"
done

EXIT_NUM=$((NUM_SCRIPTS + 1))
echo "  ${EXIT_NUM}) Exit"
echo ""

read -p "Select a script to run [1-${EXIT_NUM}]: " CHOICE </dev/tty

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    echo "❌ Invalid selection."
    exit 1
fi

if [ "$CHOICE" -eq "$EXIT_NUM" ]; then
    echo "Cancelled."
    exit 0
elif [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$NUM_SCRIPTS" ]; then
    SELECTED_SCRIPT="${SCRIPTS[$((CHOICE-1))]}"
    SCRIPT_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED_SCRIPT}"
    
    echo ""
    echo "🚀 Fetching ${SELECTED_SCRIPT}..."
    
    TEMP_EXEC="/tmp/runner_$SELECTED_SCRIPT"
    curl -fsSL "$SCRIPT_URL" -o "$TEMP_EXEC"
    chmod +x "$TEMP_EXEC"
    
    # 🧠 SMART AUTO-DETECTION:
    # Check if the downloaded script contains a root restriction check (e.g., EUID -ne 0)
    if grep -qE "EUID.*-ne 0|id -u.*-ne 0" "$TEMP_EXEC" && [ "$EUID" -ne 0 ]; then
        echo "⚠️  This script requires administrator privileges."
        echo "🔄 Automatically escalating to sudo..."
        sudo bash "$TEMP_EXEC"
    else
        # Run it normally (either it doesn't need root, or user is already root)
        "$TEMP_EXEC"
    fi
    
    rm -f "$TEMP_EXEC"
else
    echo "❌ Invalid selection."
    exit 1
fi
