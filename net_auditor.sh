#!/bin/bash
# Description: Combined network utility featuring an interactive menu to choose between the official Ookla Speed Test and the local network/port auditor.
set -eo pipefail

clear
echo "=========================================="
echo " 🚀 Pi Network Diagnostics & Auditor"
echo "=========================================="
echo ""
echo "Select an option:"
echo "  1) Run Ookla Speed Test Only"
echo "  2) Run Local Network & Port Audit Only"
echo "  3) Run Both"
echo "  4) Exit"
echo ""

read -p "Enter selection [1-4]: " CHOICE </dev/tty
CHOICE=${CHOICE:-4}

case "$CHOICE" in
    1|3)
        echo ""
        echo "--------------------------------------------------"
        echo " 🚀 Running Ookla Speed Test..."
        echo "--------------------------------------------------"
        if ! command -v speedtest &> /dev/null || speedtest --version 2>&1 | grep -q "Python"; then
            echo "Installing official Ookla Speedtest binary..."
            ARCH=$(uname -m)
            case "$ARCH" in
                aarch64|arm64) OOKLA_ARCH="aarch64" ;;
                armv7l|armhf)   OOKLA_ARCH="armhf" ;;
                x86_64)        OOKLA_ARCH="x86_64" ;;
                *)             OOKLA_ARCH="armhf" ;;
            esac
            TEMP_DIR=$(mktemp -d)
            TAR_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${OOKLA_ARCH}.tgz"
            if curl -fsSL "$TAR_URL" -o "$TEMP_DIR/speedtest.tgz"; then
                tar -xzf "$TEMP_DIR/speedtest.tgz" -C "$TEMP_DIR"
                sudo mv "$TEMP_DIR/speedtest" /usr/local/bin/
                sudo chmod +x /usr/local/bin/speedtest
                rm -rf "$TEMP_DIR"
                echo "✅ Installed /usr/local/bin/speedtest"
            else
                echo "❌ Download failed."
                rm -rf "$TEMP_DIR"
            fi
        fi
        speedtest --accept-license --accept-gdpr
        echo ""
        ;;
esac

case "$CHOICE" in
    2|3)
        echo ""
        echo "--------------------------------------------------"
        echo " 🔍 Running Local Network & Port Audit..."
        echo "--------------------------------------------------"
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
        echo "📡 1. Pi Network Interface & Gateway"
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
        echo ""
        ;;
    4)
        echo "Exiting."
        exit 0
        ;;
esac

echo "=========================================="
echo " ✅ Diagnostics Complete!"
echo "=========================================="
