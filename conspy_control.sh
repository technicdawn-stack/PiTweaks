#!/bin/bash
# Description: Standalone Conspy screen mirroring controller and setup manager

# Ensure script runs interactively even if piped
exec < /dev/tty

# Check for whiptail (install if missing)
if ! command -v whiptail &> /dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y whiptail -qq
fi

# Config storage path for display settings
CONFIG_DIR="$HOME/.config"
CONFIG_FILE="$CONFIG_DIR/conspy_settings.conf"
mkdir -p "$CONFIG_DIR"

# Load existing configuration if available
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    AUTO_CONSPY="ON"
fi

# 1. WHIPTAIL MENU FOR CONSPY SETTINGS
CHOICES=$(whiptail --title "📺 Conspy Screen Mirroring Manager" \
    --checklist "Manage physical display mirroring options:" 15 65 2 \
    "CONSPY" "Enable/Auto-detect physical screen mirroring" "$AUTO_CONSPY" \
    3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    echo "Configuration cancelled."
    exit 0
fi

if [[ "$CHOICES" == *"CONSPY"* ]]; then
    AUTO_CONSPY="ON"
else
    AUTO_CONSPY="OFF"
fi

# Save configuration
echo "AUTO_CONSPY=\"$AUTO_CONSPY\"" > "$CONFIG_FILE"

# 2. DEPENDENCY CHECK (conspy)
if ! command -v conspy &> /dev/null; then
    echo "📦 Installing conspy package..."
    sudo apt-get update -qq && sudo apt-get install -y conspy -qq
fi

# 3. SCREEN DETECTION CHECK
SCREEN_STATUS_MSG="Conspy is disabled in settings."
if [ "$AUTO_CONSPY" = "ON" ]; then
    if [ -e /dev/tty1 ]; then
        SCREEN_STATUS_MSG="Physical display detected at /dev/tty1! Run 'conspy 1' to mirror your session."
    else
        SCREEN_STATUS_MSG="Conspy is enabled, but no physical screen (/dev/tty1) was found plugged in."
    fi
fi

# 4. FINAL STATUS POPUP
whiptail --title "✅ Conspy Status" --msgbox "$SCREEN_STATUS_MSG

Settings saved to: $CONFIG_FILE" 12 60
