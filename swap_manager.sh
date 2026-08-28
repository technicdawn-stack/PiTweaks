#!/bin/bash
# Description: Smart memory and swap manager with auto-detection and recommendations
# Category: Tools

set -eo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "=================================================="
echo -e " 🧠 ${BOLD}Raspberry Pi Smart Memory Manager${NC}"
echo -e "=================================================="
echo ""

# Ensure required utility is installed
if ! command -v dphys-swapfile &>/dev/null; then
    echo "🔍 Installing dphys-swapfile package..."
    sudo apt-get update -qq && sudo apt-get install -y dphys-swapfile -qq
fi

# ------------------------------------------------------------------------------
# 1. Hardware & Disk Analysis (Robust parsing)
# ------------------------------------------------------------------------------
# Fetch free space in KB and calculate MB directly to avoid df flag inconsistencies
FREE_DISK_KB=$(df / --output=avail | tail -n1 | tr -d ' ')
FREE_DISK_MB=$(( FREE_DISK_KB / 1024 ))

RAM_TOTAL_MB=$(free -m | awk '/Mem:/ {print $2}')
RAM_TOTAL_GB=$(awk -v ram="$RAM_TOTAL_MB" 'BEGIN {printf "%.1f", ram/1024}')

CURRENT_SWAP_MB=$(free -m | awk '/Swap:/ {print $2}')

# ------------------------------------------------------------------------------
# 2. 5-Second Real-Time Usage Sampling
# ------------------------------------------------------------------------------
echo -n "⏳ Monitoring RAM usage over 5 seconds"
SUM_PCT=0
SAMPLES=5

for i in $(seq 1 $SAMPLES); do
    PCT=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
    SUM_PCT=$((SUM_PCT + PCT))
    echo -n "."
    sleep 1
done
echo -e " Done!\n"

AVG_RAM_PCT=$((SUM_PCT / SAMPLES))

# ------------------------------------------------------------------------------
# 3. Dynamic Recommendation Engine
# ------------------------------------------------------------------------------
RECOMMENDED_SWAP=1024
REASON=""

if [ "$RAM_TOTAL_MB" -ge 8000 ]; then
    if [ "$AVG_RAM_PCT" -gt 85 ]; then
        RECOMMENDED_SWAP=2048
        REASON="High system RAM detected (${RAM_TOTAL_GB} GB), but load is high (~${AVG_RAM_PCT}%). A 2GB swap is suggested."
    else
        RECOMMENDED_SWAP=512
        REASON="Large system RAM detected (${RAM_TOTAL_GB} GB) with low load (${AVG_RAM_PCT}%). A minimal 512MB swap is sufficient."
    fi
elif [ "$RAM_TOTAL_MB" -ge 2000 ]; then
    if [ "$AVG_RAM_PCT" -gt 75 ]; then
        RECOMMENDED_SWAP=2048
        REASON="System has ${RAM_TOTAL_GB} GB RAM under high load (${AVG_RAM_PCT}%). Recommending 2048MB swap."
    else
        RECOMMENDED_SWAP=1024
        REASON="System has ${RAM_TOTAL_GB} GB RAM with stable usage (${AVG_RAM_PCT}%). Standard 1024MB swap recommended."
    fi
else
    if [ "$AVG_RAM_PCT" -gt 60 ]; then
        RECOMMENDED_SWAP=2048
        REASON="Low hardware RAM detected (${RAM_TOTAL_GB} GB) under high load (${AVG_RAM_PCT}%). Recommending 2048MB swap."
    else
        RECOMMENDED_SWAP=1024
        REASON="Low hardware RAM detected (${RAM_TOTAL_GB} GB). A 1024MB swap is recommended."
    fi
fi

SAFE_DISK_LIMIT=$((FREE_DISK_MB / 2))
if [ "$RECOMMENDED_SWAP" -gt "$SAFE_DISK_LIMIT" ]; then
    RECOMMENDED_SWAP=$SAFE_DISK_LIMIT
    REASON="${REASON} (Capped to ${SAFE_DISK_LIMIT} MB to protect storage space)."
fi

# ------------------------------------------------------------------------------
# 4. Status Output & Recommendations
# ------------------------------------------------------------------------------
echo -e "📊 ${BOLD}System Diagnostic Summary:${NC}"
echo -e "   • Total System RAM : ${CYAN}${RAM_TOTAL_GB} GB${NC} (${RAM_TOTAL_MB} MB)"
echo -e "   • 5-Sec Avg Load   : ${CYAN}${AVG_RAM_PCT}%${NC}"
echo -e "   • Current Swap     : ${CYAN}${CURRENT_SWAP_MB} MB${NC}"
echo -e "   • Free Disk Space  : ${CYAN}${FREE_DISK_MB} MB${NC}"
echo ""
echo -e "💡 ${BOLD}${GREEN}Smart Recommendation:${NC}"
echo -e "   Suggested Swap Size: ${BOLD}${YELLOW}${RECOMMENDED_SWAP} MB${NC}"
echo -e "   Reason: ${REASON}"
echo ""

# ------------------------------------------------------------------------------
# 5. Interactive Selection Menu
# ------------------------------------------------------------------------------
echo "--------------------------------------------------"
echo " What would you like to do?"
echo "--------------------------------------------------"
echo " 1) Apply Recommended Swap (${RECOMMENDED_SWAP} MB)"
echo " 2) Set Custom Swap Size"
echo " 3) Enable Swap"
echo " 4) Disable Swap"
echo " 5) Exit"
echo ""

read -p "Select an option [1-5]: " CHOICE </dev/tty

case "$CHOICE" in
    1)
        NEW_SIZE=$RECOMMENDED_SWAP
        ;;
    2)
        echo ""
        read -p "Enter custom swap size in MB: " NEW_SIZE </dev/tty

        if ! [[ "$NEW_SIZE" =~ ^[0-9]+$ ]]; then
            echo "❌ Invalid number entered."
            exit 1
        fi

        if [ "$NEW_SIZE" -lt 100 ]; then
            echo "❌ Safety Guard: Minimum swap size is 100 MB."
            exit 1
        fi

        if [ "$NEW_SIZE" -gt "$FREE_DISK_MB" ]; then
            echo "❌ Safety Guard: $NEW_SIZE MB exceeds free disk space ($FREE_DISK_MB MB)."
            exit 1
        fi
        ;;
    3)
        echo "🟢 Enabling swap..."
        sudo dphys-swapfile swapon || true
        sudo systemctl enable dphys-swapfile || true
        echo "✅ Swap enabled."
        exit 0
        ;;
    4)
        read -p "⚠️ Disable swap? High RAM usage without swap may cause system crashes. [y/N]: " CONFIRM </dev/tty
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "Operation canceled."
            exit 0
        fi
        echo "🔴 Disabling swap..."
        sudo dphys-swapfile swapoff || true
        sudo systemctl disable dphys-swapfile || true
        echo "✅ Swap disabled."
        exit 0
        ;;
    5)
        echo "Exiting."
        exit 0
        ;;
    *)
        echo "❌ Invalid choice."
        exit 1
        ;;
esac

# Apply Swap Resize (Options 1 and 2)
read -p "⚠️ Configure swap size to ${NEW_SIZE} MB? [y/N]: " CONFIRM </dev/tty
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Operation canceled."
    exit 0
fi

echo "🔄 Applying swap changes..."
sudo systemctl stop dphys-swapfile || true
sudo sed -i "s/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=$NEW_SIZE/" /etc/dphys-swapfile
sudo dphys-swapfile setup
sudo dphys-swapfile swapon

echo -e "\n✅ Swap updated to ${NEW_SIZE} MB!"
echo ""
free -h

echo ""
echo "=================================================="
echo " ✅ Action Complete!"
echo "=================================================="
