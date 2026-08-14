#!/bin/bash
clear
echo "=========================================="
echo " 🚀 Pi Network Speed Test"
echo "=========================================="
if ! command -v speedtest-cli &> /dev/null; then
    echo "Installing speedtest-cli..."
    sudo apt-get update -qq && sudo apt-get install -y speedtest-cli -qq
fi

echo "Running speed test..."
echo ""
speedtest-cli --simple
