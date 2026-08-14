#!/bin/bash

# ==============================================================================
# 🍓 PiTweaks - Non-Destructive MicroSD Health & Speed Diagnostic
# ==============================================================================

clear
echo "=========================================="
echo " 🔍 MicroSD Card Health & Speed Check"
echo "=========================================="
echo ""

# 1. Scan kernel logs for I/O and MMC hardware errors
echo "1️⃣ Scanning kernel logs for drive errors..."
ERRORS=$(dmesg 2>/dev/null | grep -iE 'mmc0: error|I/O error|bcm2835-sdhost' | tail -n 5)

if [ -z "$ERRORS" ]; then
    echo "  ✅ No hardware I/O or MMC errors found in kernel logs."
else
    echo "  ⚠️ Warning: Potential SD card hardware errors detected:"
    echo "$ERRORS"
fi
echo ""

# 2. Zero-wear sequential read test (100 MB)
echo "2️⃣ Measuring Read Speed (Zero Wear)..."
READ_BENCH=$(dd if=/dev/mmcblk0 of=/dev/null bs=1M count=100 2>&1 | awk '/copied/ {print $(NF-1), $NF}')
echo "  🚀 Sequential Read Speed: ${READ_BENCH:-N/A}"
echo ""

# 3. Micro write latency test (10 MB)
echo "3️⃣ Measuring Write Speed (Minimal Wear - 10MB)..."
WRITE_BENCH=$(dd if=/dev/zero of=/tmp/sd_test_file bs=1M count=10 conv=fdatasync 2>&1 | awk '/copied/ {print $(NF-1), $NF}')
rm -f /tmp/sd_test_file
echo "  📝 Sequential Write Speed: ${WRITE_BENCH:-N/A}"

echo ""
echo "=========================================="
echo " Diagnostic Complete!"
echo "=========================================="
