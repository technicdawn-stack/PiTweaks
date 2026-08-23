#!/bin/bash
# Description: PiTweaks Interactive Whiptail Menu Launcher v1.2

INSTALL_DIR="$PWD"
TARGET_SCRIPT="$INSTALL_DIR/pi_tui.py"

# Ensure the core python telemetry script exists
if [ ! -f "$TARGET_SCRIPT" ]; then
    echo "❌ Error: pi_tui.py not found in current directory!"
    exit 1
fi

while true; do
    CHOICE=$(whiptail --title "PiTweaks - Continuous Stress Suite" \
        --menu "Select a test mode (Press Ctrl+C to stop anytime):" 15 65 5 \
        "1" "CPU Stress Test (Continuous)" \
        "2" "RAM Memory Stress Test (Continuous)" \
        "3" "GPU Render Stress Test (Continuous)" \
        "4" "All-At-Once Comprehensive Test" \
        "5" "Exit" 3>&1 1>&2 2>&3)
    
    if [ $? != 0 ] || [ "$CHOICE" = "5" ]; then
        clear
        echo "Exiting PiTweaks. Goodbye!"
        exit 0
    fi

    case $CHOICE in
        1) python3 "$TARGET_SCRIPT" cpu ;;
        2) python3 "$TARGET_SCRIPT" ram ;;
        3) python3 "$TARGET_SCRIPT" gpu ;;
        4) python3 "$TARGET_SCRIPT" all ;;
    esac
done
