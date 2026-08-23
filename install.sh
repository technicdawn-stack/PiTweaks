#!/bin/bash

# ==============================================================================
# 🍓 PI TWEAKS INSTALLER (SMART PERSISTENCE & AUTO-OVERWRITE)
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

# 2. Build menu options inside memory
MENU_OPTIONS=()
while IFS='|' read -r script desc; do
    [[ -z "$script" || "$script" =~ ^# ]] && continue
    MENU_OPTIONS+=("$script" "${desc:-No description provided}")
done <<< "$INDEX_DATA"

if [ "${#MENU_OPTIONS[@]}" -eq 0 ]; then
    echo "❌ No scripts found in index.txt."
    exit 1
fi

# 3. Get terminal size for responsive menu
TERM_HEIGHT=$(stty size 2>/dev/null | awk '{print $1}' || echo 20)
TERM_WIDTH=$(stty size 2>/dev/null | awk '{print $2}' || echo 80)

BOX_HEIGHT=$(( TERM_HEIGHT - 4 ))
BOX_WIDTH=$(( TERM_WIDTH - 6 ))
MENU_HEIGHT=$(( BOX_HEIGHT - 8 ))

# 4. Launch Whiptail TUI
SELECTED=$(whiptail --clear \
    --backtitle "PiTweaks Script Manager" \
    --title "Script Selection Menu" \
    --menu "Select a script to execute:" "$BOX_HEIGHT" "$BOX_WIDTH" "$MENU_HEIGHT" \
    "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3) || {
        clear
        echo "Cancelled."
        exit 0
    }

clear
echo "🚀 Downloading and preparing ${SELECTED}..."
echo "=========================================="
echo ""

# 5. Download script to disk using raw URL (automatically overwrites old versions safely)
curl -fsSL "https://raw.githubusercontent.com/${USER}/${REPO}/${BRANCH}/${SELECTED}?cb=$(date +%s)" -o "${SELECTED}"

# 6. Make it executable
chmod +x "${SELECTED}"

# 7. Check if the script requires persistence (e.g., contains `# PERSISTENT: TRUE` or 'monitor' in name)
IS_PERSISTENT=false
if grep -qi "# PERSISTENT: TRUE" "${SELECTED}" || [[ "${SELECTED}" == *"monitor"* ]]; then
    IS_PERSISTENT=true
fi

# 8. Run locally so interactive prompts (like webhooks or configurations) work properly
./"${SELECTED}"

# 9. Smart Cleanup: Delete only if it's NOT a persistent background tool
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
