#!/bin/bash

# ==============================================================================
# 🍓 PiTweaks - Swap Memory Manager
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo (e.g., sudo bash swap_manager.sh)"
  exit 1
fi

clear
echo "=================================================="
echo " 🧠 Raspberry Pi Swap Memory Manager"
echo "=================================================="
echo ""

# 1. Show current memory and swap status
echo "📊 Current Memory & Swap Usage:"
free -h
echo ""

echo "--------------------------------------------------"
echo " What would you like to do?"
echo "--------------------------------------------------"
echo " 1) Resize Swap File (Recommended: 1024MB or 2048MB)"
echo " 2) Turn Swap ON"
echo " 3) Turn Swap OFF"
echo " 4) Exit"
echo ""

read -p "Select an option [1-4]: " choice </dev/tty

case $choice in
    1)
        echo ""
        read -p "Enter desired swap size in megabytes (e.g., 1024 for 1GB, 2048 for 2GB): " NEW_SIZE </dev/tty
        
        if ! [[ "$NEW_SIZE" =~ ^[0-9]+$ ]]; then
            echo "❌ Invalid number. Exiting."
            exit 1
        fi

        echo "🔄 Configuring new swap size ($NEW_SIZE MB)..."
        
        # Stop dphys-swapfile service
        systemctl stop dphys-swapfile
        
        # Modify the configuration file size
        sed -i "s/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=$NEW_SIZE/" /etc/dphys-swapfile
        
        # Set up and restart swap
        dphys-swapfile setup
        dphys-swapfile swapon
        
        echo "✅ Swap successfully resized and activated!"
        free -h
        ;;
    2)
        echo "🟢 Enabling swap..."
        dphys-swapfile swapon
        systemctl enable dphys-swapfile
        echo "✅ Swap is now ON."
        ;;
    3)
        echo "🔴 Disabling swap..."
        dphys-swapfile swapoff
        systemctl disable dphys-swapfile
        echo "✅ Swap is now OFF."
        ;;
    4)
        echo "Exiting."
        exit 0
        ;;
    *)
        echo "❌ Invalid option."
        exit 1
        ;;
esac

echo ""
echo "=================================================="
echo " ✅ Action Complete!"
echo "=================================================="
