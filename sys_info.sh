#!/bin/bash
clear
echo "=========================================="
echo " 📊 Raspberry Pi System Information"
echo "=========================================="
echo "• OS Version:    $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
echo "• Kernel:        $(uname -r)"
echo "• Uptime:        $(uptime -p)"
echo "• Local IP:      $(hostname -I | awk '{print $1}')"
echo "• Temperature:   $(vcgencmd measure_temp 2>/dev/null || echo "N/A")"
echo "=========================================="
