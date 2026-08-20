#!/bin/bash
# Description: Measures network speed using official native Ookla Speedtest
set -eo pipefail

echo "=========================================="
echo " 🚀 Pi Network Speed Test (Ookla)"
echo "=========================================="

# Check if official Ookla 'speedtest' binary is installed
if ! command -v speedtest &> /dev/null || speedtest --version 2>&1 | grep -q "Python"; then
    echo "Installing official Ookla Speedtest CLI..."
    
    # Add official Ookla repository
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
    
    # Fix for Debian/Raspbian Trixie: substitute codename with 'bookworm'
    if [ -f /etc/apt/sources.list.d/ookla_speedtest-cli.list ]; then
        sudo sed -i 's/trixie/bookworm/g' /etc/apt/sources.list.d/ookla_speedtest-cli.list
    fi
    
    sudo apt-get update -qq
    sudo apt-get install -y speedtest -qq
fi

echo "Running speed test..."
echo ""

# Run test non-interactively
speedtest --accept-license --accept-gdpr
