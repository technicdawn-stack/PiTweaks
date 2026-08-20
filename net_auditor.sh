#!/bin/bash
# Description: Comprehensive local network device, open port, and connection auditor using standard system tools
set -eo pipefail

echo "=========================================="
echo " 🔍 Pi Network & Port Auditor"
echo "=========================================="

# 1. Ensure required standard packages are installed via apt
MISSING_PACKAGES=""
for cmd in nmap ss ip arp; do
    if ! command -v "$cmd" &> /dev/null; then
        case "$cmd" in
            nmap) MISSING_PACKAGES="$MISSING_PACKAGES nmap" ;;
            ss|ip) MISSING_PACKAGES="$MISSING_PACKAGES iproute2" ;;
            arp) MISSING_PACKAGES="$MISSING_PACKAGES net-tools" ;;
        esac
    fi
done

if [ -n "$MISSING_PACKAGES" ]; then
    echo "📦 Installing missing system dependencies ($MISSING_PACKAGES)..."
    sudo apt-get update -y && sudo apt-get install -y $MISSING_PACKAGES
fi

echo ""
echo "--------------------------------------------------"
echo " 📡 1. Pi Network Interface & Gateway"
echo "--------------------------------------------------"
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
DEFAULT_GATEWAY=$(ip route show | awk '/default/ {print $3}' | head -n 1)
PUBLIC_IP=$(curl -s --max-time 3 https://ifconfig.me || echo "Unavailable")

echo "• Pi Local IP:     ${LOCAL_IP:-Unknown}"
echo "• Default Gateway: ${DEFAULT_GATEWAY:-Unknown}"
echo "• Public WAN IP:   ${PUBLIC_IP}"
echo ""

echo "--------------------------------------------------"
echo " 🛡️ 2. Raspberry Pi Open Listening Ports"
echo "--------------------------------------------------"
ss -tuln | awk 'NR==1 || /LISTEN/'
echo ""

echo "--------------------------------------------------"
echo " 🌐 3. Active Established Connections"
echo "--------------------------------------------------"
ss -tunap state established 2>/dev/null | head -n 10 || echo "No active established connections."
echo ""

echo "--------------------------------------------------"
echo " 🏠 4. Active Local Subnet Devices"
echo "--------------------------------------------------"
DEFAULT_SUBNET=$(echo "$DEFAULT_GATEWAY" | sed 's/\.[0-9]*$/.0\/24/')

if [ -n "$DEFAULT_SUBNET" ] && [ "$DEFAULT_SUBNET" != ".0/24" ]; then
    echo "Scanning subnet: $DEFAULT_SUBNET"
    echo ""
    nmap -sn "$DEFAULT_SUBNET" | grep -E "Nmap scan report for|MAC Address"
else
    echo "❌ Could not determine local subnet automatically."
fi

echo "=========================================="
echo " ✅ Full Audit Complete!"
echo "=========================================="
