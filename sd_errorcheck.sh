#!/bin/bash

# ==============================================================================
# 🍓 PiTweaks - SD Card Error Checker (Zero Write/Read Tests)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo."
  exit 1
fi

clear
echo "=========================================="
echo " 🔍 MicroSD Card Error & Kernel Health Check"
echo "=========================================="
echo ""

echo "1️⃣ Scanning kernel logs for hardware or I/O errors..."
echo ""

# Search dmesg and system logs for common SD card corruption indicators
ERRORS=$(dmesg | grep -iE "mmc0: error|I/O error|EXT4-fs error|corruption|readonly" || true)

if [ -z "$ERRORS" ]; then
    echo " ✅ Clean! No hardware I/O or file system corruption errors found in kernel logs."
else
    echo " ⚠️ Potential issues found in system logs:"
    echo "$ERRORS"
fi

echo ""
echo "=========================================="
echo " ✅ Diagnostic Complete!"
echo "=========================================="
