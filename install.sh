#!/bin/bash

clear

# ==============================================================================
# 🍓 DYNAMIC RASPBERRY PI SCRIPT INSTALLER
# ==============================================================================
USER="technicdawn-stack"
REPO="PiTweaks"
BRANCH="main"

echo "=========================================="
echo " 🍓 Raspberry Pi Script Installer"
echo "=========================================="
echo "🔍 Fetching available scripts from GitHub..."
echo ""

# Fetch list of .sh files from GitHub API (excluding install.sh itself)
API_URL="https://api.github.com/repos/${USER}/${REPO}/contents?ref=${BRANCH}"
RAW_FILES=$(curl -s "$API_URL" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep '\.sh$' | grep -v 'install.sh')

# Convert fetched files into an array
SCRIPTS=()
while IFS= read -r line; do
    [ -n "$line" ] && SCRIPTS+=("$line")
done <<< "$RAW_FILES"

NUM_SCRIPTS=${#SCRIPTS[@]}

if [ "$NUM_SCRIPTS" -eq 0 ]; then
    echo "❌ No available installer scripts found in repository."
    exit 1
fi

# Display dynamic menu
for i in "${!SCRIPTS[@]}"; do
    echo "  $((i+1))) ${SCRIPTS[$i]}"
done

EXIT_NUM=$((NUM_SCRIPTS + 1))
echo "  ${EXIT_NUM}) Exit"
echo ""

# Read keyboard input safely
read -p "Select a script to run [1-${EXIT_NUM}]: " CHOICE </dev/tty

# Validate input safely
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    echo "❌ Invalid selection. Please enter a number."
    exit 1
fi

# Handle user selection
if [ "$CHOICE" -eq "$EXIT_NUM" ]; then
    echo "Cancelled."
    exit 0
elif [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$NUM_SCRIPTS" ]; then
    SELECTED_SCRIPT="${SCRIPTS[$((CHOICE-1))]}"
    SCRIPT_URL="https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED_SCRIPT}"
    
    echo ""
    echo "🚀 Fetching ${SELECTED_SCRIPT}..."
    
    # Download the script to a temp location, make executable, and run cleanly
    TEMP_EXEC="/tmp/runner_$SELECTED_SCRIPT"
    curl -fsSL "$SCRIPT_URL" -o "$TEMP_EXEC"
    chmod +x "$TEMP_EXEC"
    
    # Execute with full terminal control
    "$TEMP_EXEC"
    
    # Clean up temp runner
    rm -f "$TEMP_EXEC"
else
    echo "❌ Invalid selection."
    exit 1
fi
