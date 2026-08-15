#!/bin/bash

# ==============================================================================
# 🗄️ PiTweaks Advanced Disk & SD Card Health Monitor
# ==============================================================================

# Colors for output readability
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

clear
echo "=========================================="
echo " 🗄️ Raspberry Pi Storage & SD Health Report"
echo "=========================================="
echo ""

# 1. Disk usage stats for the root partition (/)
DISK_LINE=$(df -h / | tail -n 1)
TOTAL_SIZE=$(echo "$DISK_LINE" | awk '{print $2}')
USED_SPACE=$(echo "$DISK_LINE" | awk '{print $3}')
FREE_SPACE=$(echo "$DISK_LINE" | awk '{print $4}')
USE_PERCENT=$(echo "$DISK_LINE" | awk '{print $5}' | tr -d '%')

echo "📁 Partition: / (Root)"
echo "• Total Storage : $TOTAL_SIZE"
echo "• Used Space    : $USED_SPACE"
echo "• Free Space    : $FREE_SPACE"

if [ "$USE_PERCENT" -ge 85 ]; then
    echo -e "• Usage Level   : ${RED}${USE_PERCENT}% (Critical)${NC}"
elif [ "$USE_PERCENT" -ge 70 ]; then
    echo -e "• Usage Level   : ${YELLOW}${USE_PERCENT}% (Warning)${NC}"
else
    echo -e "• Usage Level   : ${GREEN}${USE_PERCENT}% (Healthy)${NC}"
fi

echo ""
echo "------------------------------------------"
echo "🔍 Top Space Consumers in Home Directory:"
du -h --max-depth=1 "$HOME" 2>/dev/null | sort -hr | head -n 5
echo "------------------------------------------"
echo ""

# 2. SD Card & Filesystem Health Check
echo " 🩺 SD Card & Filesystem Health Check"
echo "------------------------------------------"

# Check read-only mount status
ROOT_MOUNT=$(findmnt -n -o OPTIONS /)
if echo "$ROOT_MOUNT" | grep -q "ro"; then
    echo -e "• Filesystem Status : ${RED}CRITICAL - Mounted Read-Only (SD card corruption!)${NC}"
else
    echo -e "• Filesystem Status : ${GREEN}Healthy (Read/Write mode normal)${NC}"
fi

# Scan kernel ring buffer (dmesg) for hardware or I/O errors
SD_ERRORS=$(dmesg | grep -iE 'mmc0|sdhci|I/O error|EXT4-fs error' | tail -n 3)

if [ -n "$SD_ERRORS" ]; then
    echo -e "• Hardware Errors   : ${RED}Found potential SD card I/O issues!${NC}"
    echo "  Recent system log entries:"
    echo "$SD_ERRORS" | sed 's/^/    /'
else
    echo -e "• Hardware Errors   : ${GREEN}No recent SD card I/O errors found in kernel logs.${NC}"
fi
echo ""

# 3. Optional cleanup prompt if storage is filling up
if [ "$USE_PERCENT" -ge 70 ]; then
    echo "------------------------------------------"
    read -p "Storage usage is high. Do you want to clean apt cache and old logs? [y/N]: " CLEAN_CHOICE </dev/tty
    case "$CLEAN_CHOICE" in
        [yY]|[yY][eE][sS])
            echo "🧹 Cleaning package cache..."
            sudo apt clean
            echo "🧹 Vacuuming system journal logs..."
            sudo journalctl --vacuum-time=3d
            echo "✅ Cleanup completed!"
            ;;
        *)
            echo "ℹ️  Cleanup skipped."
            ;;
    esac
fi
echo ""
