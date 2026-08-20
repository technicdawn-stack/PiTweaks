#!/bin/bash
set -eo pipefail

echo "=========================================="
echo " 🚀 Pi Network Speed Test (Ookla)"
echo "=========================================="

# Check if official Ookla 'speedtest' binary is installed
if ! command -v speedtest &> /dev/null || speedtest --version 2>&1 | grep -q "Python"; then
    echo "Installing official Ookla Speedtest CLI..."
    
    # Add official Ookla repository script
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
    
    # Install official speedtest package
    sudo apt-get install -y speedtest -qq
fi

echo "Running speed test..."
echo ""

# --accept-license and --accept-gdpr prevent interactive prompts on first run
speedtest --accept-license --accept-gdpr
