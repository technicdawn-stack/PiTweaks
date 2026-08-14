#!/bin/bash
clear
echo "=========================================="
echo " 🧹 Raspberry Pi Quick Disk Cleaner"
echo "=========================================="
echo "Cleaning package cache and unused dependencies..."
echo ""
sudo apt-get autoremove -y
sudo apt-get autoclean -y
echo ""
echo "✅ Disk cleanup complete! Current disk usage:"
df -h /
