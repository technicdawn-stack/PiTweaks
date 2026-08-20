#!/bin/bash
# Description: Measures network speed using official native Ookla Speedtest
set -eo pipefail

echo "=========================================="
echo " 🚀 Pi Network Speed Test (Ookla)"
echo "=========================================="

if ! command -v speedtest &> /dev/null || speedtest --version 2>&1 | grep -q "Python"; then
    echo "Installing official Ookla Speedtest binary..."
    
    # Detect CPU architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) OOKLA_ARCH="aarch64" ;;
        armv7l|armhf)   OOKLA_ARCH="armhf" ;;
        x86_64)        OOKLA_ARCH="x86_64" ;;
        *)             OOKLA_ARCH="armhf" ;;
    esac

    # Download direct binary from Ookla servers
    TEMP_DIR=$(mktemp -d)
    TAR_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${OOKLA_ARCH}.tgz"
    
    if curl -fsSL "$TAR_URL" -o "$TEMP_DIR/speedtest.tgz"; then
        tar -xzf "$TEMP_DIR/speedtest.tgz" -C "$TEMP_DIR"
        sudo mv "$TEMP_DIR/speedtest" /usr/local/bin/
        sudo chmod +x /usr/local/bin/speedtest
        rm -rf "$TEMP_DIR"
        echo "✅ Speedtest binary successfully installed to /usr/local/bin/speedtest"
    else
        echo "❌ Failed to download Ookla Speedtest binary."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
fi

echo "Running speed test..."
echo ""

# Run test non-interactively
speedtest --accept-license --accept-gdpr
