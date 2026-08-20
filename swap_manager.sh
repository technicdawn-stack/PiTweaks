#!/bin/bash
# Description: Safe memory and swap file manager with built-in safeguards
set -eo pipefail

# Visual formatting
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "=================================================="
echo -e " 🧠 ${BOLD}Raspberry Pi Memory & Swap Manager${NC}"
echo -e "=================================================="
echo ""

# Ensure required utility is installed
if ! command -v dphys-swapfile &>/dev/null; then
    echo "🔍 Installing dphys-swapfile package..."
    sudo apt-get update -qq && sudo apt-get install -y dphys-swapfile -qq
fi

# Fetch disk space details (in Megabytes)
FREE_DISK_MB=$(df -B-M / | awk 'NR==2 {print $4}' | tr -d 'M')
RAM_TOTAL_MB=$(free -m | awk '/Mem:/ {print $2}')

# Display current stats
echo -e "📊 ${BOLD}System Memory & Storage Status:${NC}"
free -h
echo ""
echo -e "💾 Available SD Card / Disk Space: ${BOLD}${FREE_DISK_MB} MB${NC}"
echo "--------------------------------------------------"
echo " What would you like to do?"
echo "--------------------------------------------------"
echo " 1) Resize Swap File"
echo " 2) Enable Swap"
echo " 3) Disable Swap"
echo " 4) Exit"
echo ""

read -p "Select an option [1-4]: " CHOICE </dev/tty

case "$CHOICE" in
    1)
        echo ""
        echo "💡 Recommended Sizes: 1024 (1GB) or 2048 (2GB)"
        read -p "Enter new swap size in MB: " NEW_SIZE </dev/tty

        # Safeguard 1: Ensure input is a valid positive number
        if ! [[ "$NEW_SIZE" =~ ^[0-9]+$ ]]; then
            echo "❌ Error: Invalid input. Please enter a positive integer."
            exit 1
        fi

        # Safeguard 2: Enforce minimum size to prevent broken configs
        if [ "$NEW_SIZE" -lt 100 ]; then
            echo "❌ Safety Triggered: Swap size must be at least 100 MB."
            exit 1
        fi

        # Safeguard 3: Prevent swap from exceeding available storage space
        if [ "$NEW_SIZE" -gt "$FREE_DISK_MB" ]; then
            echo "❌ Safety Triggered: $NEW_SIZE MB exceeds available disk space ($FREE_DISK_MB MB)."
            exit 1
        fi

        # Safeguard 4: Require user confirmation
        read -p "⚠️ Change swap size to ${NEW_SIZE} MB? [y/N]: " CONFIRM </dev/tty
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "Operation canceled."
            exit 0
        fi

        echo "🔄 Applying changes..."
        sudo systemctl stop dphys-swapfile || true
        sudo sed -i "s/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=$NEW_SIZE/" /etc/dphys-swapfile
        sudo dphys-swapfile setup
        sudo dphys-swapfile swapon

        echo -e "\n✅ Swap successfully resized to ${NEW_SIZE} MB!"
        echo ""
        free -h
        ;;

    2)
        echo "🟢 Enabling swap..."
        sudo dphys-swapfile swapon
        sudo systemctl enable dphys-swapfile
        echo "✅ Swap service is active."
        ;;

    3)
        read -p "⚠️ Are you sure you want to disable swap? (May cause Out-Of-Memory crashes if RAM fills up) [y/N]: " CONFIRM </dev/tty
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "Operation canceled."
            exit 0
        fi

        echo "🔴 Disabling swap..."
        sudo dphys-swapfile swapoff || true
        sudo systemctl disable dphys-swapfile
        echo "✅ Swap has been disabled."
        ;;

    4)
        echo "Exiting."
        exit 0
        ;;

    *)
        echo "❌ Invalid choice."
        exit 1
        ;;
esac

echo ""
echo "=================================================="
echo " ✅ Done!"
echo "=================================================="
