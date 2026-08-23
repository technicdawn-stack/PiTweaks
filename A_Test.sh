#!/bin/bash
while true; do
    clear
    echo "🔄 Pulling latest version from GitHub..."
    
    # Download the latest script directly to your local file
    curl -fsSL "https://raw.githubusercontent.com/technicdawn-stack/PiTweaks/main/stress_test.sh" -o "$HOME/PiTweaks/stress_test.sh"
    chmod +x "$HOME/PiTweaks/stress_test.sh"
    
    echo "🚀 Launching PiTweaks..."
    # Run it normally so whiptail keeps its interactive terminal input
    bash "$HOME/PiTweaks/stress_test.sh"
    
    # If you exit the menu, ask if you want to pull and refresh again or quit
    read -p "Press [Enter] to refresh and restart, or Ctrl+C to exit..."
done
