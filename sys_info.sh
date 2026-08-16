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
echo "• Memory Usage:  $(free -h | awk '/Mem:/ {print $3 " / " $2}')"
echo "• Disk Usage:    $(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}')"
echo "=========================================="
echo ""
read -p "Would you like to view the Advanced system tab? [y/N]: " choice
case "$choice" in 
  [yY][eE][sS]|[yY])
    clear
    echo "=========================================="
    echo " ⚙️ Raspberry Pi Advanced Information"
    echo "=========================================="
    echo "• CPU Model:     $(grep -m 1 'Model' /proc/cpuinfo | cut -d ':' -f 2 | xargs)"
    echo "• Architecture:  $(uname -m)"
    echo "• Core Voltage:  $(vcgencmd measure_volts core 2>/dev/null || echo "N/A")"
    echo "• Clock Speed:   $(vcgencmd measure_clock arm 2>/dev/null | awk -F'=' '{printf "%.2f GHz\n", $2/1000000000}' || echo "N/A")"
    echo "• Available RAM: $(free -h | awk '/Mem:/ {print $4}')"
    echo "• Free Disk:     $(df -h / | awk 'NR==2 {print $4}')"
    echo "• Active Users:  $(who | wc -l)"
    echo "• Load Average:  $(uptime | awk -F'load average:' '{print $2}')"
    echo "=========================================="
    ;;
  *)
    echo "Exiting..."
    ;;
esac
