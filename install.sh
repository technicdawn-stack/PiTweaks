#!/bin/bash

# Clear terminal screen
clear

echo "=========================================="
echo " 🍓 Raspberry Pi Modular Setup Menu"
echo "=========================================="
echo ""
echo "Select what you want to install on this Pi:"
echo "  1) Full Setup (Discord Monitor + Commands + Cron)"
echo "  2) Discord Monitor Only (No Cron / No Aliases)"
echo "  3) Terminal Aliases / Shortcuts Only"
echo "  4) Exit"
echo ""

read -p "Enter your choice [1-4]: " CHOICE

case "$CHOICE" in
    1)
        echo ""
        echo "🚀 Starting Full Setup..."
        # Downloads and runs your full setup script from your repo
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/YourUsername/YourRepo/main/monitor_discord.sh)"
        ;;
    2)
        echo ""
        echo "📡 Installing Discord Monitor script only..."
        read -p "Enter Discord Webhook URL: " DISCORD_URL
        # Pulls just the raw monitor script and places it in ~
        curl -fsSL https://raw.githubusercontent.com/YourUsername/YourRepo/main/temp_monitor.sh -o ~/temp_monitor.sh
        sed -i "s|DISCORD_URL=.*|DISCORD_URL=\"$DISCORD_URL\"|" ~/temp_monitor.sh
        chmod +x ~/temp_monitor.sh
        echo "✅ Installed ~/temp_monitor.sh!"
        ;;
    3)
        echo ""
        echo "⚡ Setting up terminal aliases..."
        grep -qF "alias temp_report" ~/.bashrc || echo "alias temp_report='~/temp_monitor.sh temp_report'" >> ~/.bashrc
        grep -qF "alias test_cpu" ~/.bashrc || echo "alias test_cpu='~/temp_monitor.sh test_cpu'" >> ~/.bashrc
        grep -qF "alias test_ram" ~/.bashrc || echo "alias test_ram='~/temp_monitor.sh test_ram'" >> ~/.bashrc
        grep -qF "alias test_temp" ~/.bashrc || echo "alias test_temp='~/temp_monitor.sh test_temp'" >> ~/.bashrc
        echo "✅ Aliases added to ~/.bashrc!"
        ;;
    4)
        echo "Cancelled."
        exit 0
        ;;
    *)
        echo "❌ Invalid option."
        exit 1
        ;;
esac
