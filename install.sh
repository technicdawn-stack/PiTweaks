#!/bin/bash

# Clear screen for a clean UI
clear

# ==============================================================================
# 🍓 RASPBERRY PI MODULAR INSTALLER
# ==============================================================================
# HOW TO ADD NEW SCRIPTS IN THE FUTURE:
# 1. Add your script title to the OPTIONS array below.
# 2. Add a matching case block inside the choice section.
# ==============================================================================

# --- MENU OPTIONS LIST ---
OPTIONS=(
    "Full Discord Monitoring Setup (Script + Cron + Aliases)"
    "Discord Monitor Script Only (No Cron / No Aliases)"
    "Future Tool #1 (Placeholder)"
    "Future Tool #2 (Placeholder)"
)

# ------------------------------------------------------------------------------
# DISPLAY MENU (Dynamically Numbers Everything)
# ------------------------------------------------------------------------------
echo "=========================================="
echo " 🍓 Raspberry Pi Modular Setup Menu"
echo "=========================================="
echo ""

NUM_OPTIONS=${#OPTIONS[@]}

for i in "${!OPTIONS[@]}"; do
    echo "  $((i+1))) ${OPTIONS[$i]}"
done

# Set Exit option dynamically as the last number
EXIT_NUM=$((NUM_OPTIONS + 1))
echo "  ${EXIT_NUM}) Exit"
echo ""

read -p "Enter your choice [1-${EXIT_NUM}]: " CHOICE

# ------------------------------------------------------------------------------
# EXECUTE SELECTED CHOICE
# ------------------------------------------------------------------------------
case "$CHOICE" in
    1)
        echo ""
        echo "🚀 Running Full Discord Monitoring Setup..."
        # Runs discord_monitor.sh from your GitHub repo
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/YourUsername/YourRepo/main/discord_monitor.sh)"
        ;;

    2)
        echo ""
        echo "📡 Installing Discord Monitor script only..."
        read -p "Enter Discord Webhook URL: " DISCORD_URL
        if [ -z "$DISCORD_URL" ]; then
            echo "❌ Error: Webhook URL cannot be empty."
            exit 1
        fi
        
        # Pulls only the monitoring script file into home directory
        curl -fsSL https://raw.githubusercontent.com/YourUsername/YourRepo/main/temp_monitor.sh -o ~/temp_monitor.sh
        sed -i "s|DISCORD_URL=.*|DISCORD_URL=\"$DISCORD_URL\"|" ~/temp_monitor.sh
        chmod +x ~/temp_monitor.sh
        echo "✅ Installed ~/temp_monitor.sh! (No cron or aliases were added)"
        ;;

    3)
        echo ""
        echo "🛠️ Placeholder for Future Script #1..."
        ;;

    4)
        echo ""
        echo "🛠️ Placeholder for Future Script #2..."
        ;;

    "$EXIT_NUM")
        echo "Cancelled. Exiting menu."
        exit 0
        ;;

    *)
        echo "❌ Invalid selection."
        exit 1
        ;;
esac
