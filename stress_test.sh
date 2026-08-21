#!/bin/bash

# ==============================================================================
# 🍓 PiTweaks TUI Installer - Throttle & Stability Diagnostic Suite (No-Sudo)
# ==============================================================================

set -e

REAL_HOME="$HOME"
INSTALL_DIR="$REAL_HOME/PiTweaks"
TARGET_SCRIPT="$INSTALL_DIR/pi_tui.py"
USER_BIN_DIR="$REAL_HOME/.local/bin"
WRAPPER_SCRIPT="$USER_BIN_DIR/pitweaks-tui"

mkdir -p "$INSTALL_DIR"
mkdir -p "$USER_BIN_DIR"

echo "🔍 Checking system dependencies..."
if ! command -v vcgencmd &> /dev/null; then
    echo "❌ Error: 'vcgencmd' not found. This tool must run on Raspberry Pi OS."
    exit 1
fi

UPDATE_MODE=false
if [ -f "$TARGET_SCRIPT" ]; then
    echo "🔄 Existing installation detected. Updating in place..."
    UPDATE_MODE=true
fi

echo "📝 Writing PiTweaks core script..."

cat << 'EOF' > "$TARGET_SCRIPT"
#!/usr/bin/env python3
import os
import sys
import time
import subprocess
import threading

def run_cmd(command):
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=2)
        return result.stdout.strip()
    except Exception:
        return "N/A"

def get_hardware_stats():
    temp_raw = run_cmd("vcgencmd measure_temp")
    temp = temp_raw.replace("temp=", "").replace("'C", "°C") if "temp=" in temp_raw else "N/A"

    freq_raw = run_cmd("vcgencmd measure_clock arm")
    if "=" in freq_raw:
        try:
            freq_hz = int(freq_raw.split("=")[1])
            freq = f"{freq_hz / 1000000:.0f} MHz"
        except Exception:
            freq = "N/A"
    else:
        freq = "N/A"

    volts_raw = run_cmd("vcgencmd measure_volts core")
    volts = volts_raw.replace("volt=", "") if "volt=" in volts_raw else "N/A"

    ram_raw = run_cmd("free -m | awk '/Mem:/ {print $3, $2}'")
    if ram_raw and "N/A" not in ram_raw:
        parts = ram_raw.split()
        if len(parts) == 2:
            used, total = int(parts[0]), int(parts[1])
            pct = (used / total) * 100
            ram = f"{used}MB / {total}MB ({pct:.1f}%)"
        else:
            ram = "N/A"
    else:
        ram = "N/A"

    load_raw = run_cmd("cat /proc/loadavg")
    loads = load_raw.split()[:3] if load_raw else ["N/A", "N/A", "N/A"]
    load_avg = f"{loads[0]} / {loads[1]} / {loads[2]}"

    return temp, freq, volts, ram, load_avg

def parse_throttle_status(raw_hex):
    if "throttled=" not in raw_hex:
        return "OPTIMAL", []
    
    try:
        hex_str = raw_hex.split("=")[1].strip()
        dec_val = int(hex_str, 16)
    except Exception:
        return "OPTIMAL", []

    if dec_val == 0:
        return "OPTIMAL", []

    issues = []
    has_active = False
    if (dec_val >> 0) & 1:
        issues.append("[CRITICAL ACTIVE] Under-voltage detected")
        has_active = True
    if (dec_val >> 1) & 1:
        issues.append("[CRITICAL ACTIVE] ARM frequency capped (Thermal)")
        has_active = True
    if (dec_val >> 2) & 1:
        issues.append("[CRITICAL ACTIVE] CPU actively throttled")
        has_active = True
    if (dec_val >> 3) & 1:
        issues.append("[CRITICAL ACTIVE] Soft temperature limit active")
        has_active = True

    if (dec_val >> 16) & 1:
        issues.append("[WARNING PAST] Under-voltage occurred since boot")
    if (dec_val >> 17) & 1:
        issues.append("[WARNING PAST] Frequency capping occurred since boot")
    if (dec_val >> 18) & 1:
        issues.append("[WARNING PAST] Throttling occurred since boot")

    status_level = "CRITICAL" if has_active else "WARNING"
    return status_level, issues

def start_stress_workload(test_type, duration):
    if test_type == "cpu":
        cmd = f"stress-ng --cpu 4 --timeout {duration}s"
    elif test_type == "ram":
        cmd = f"stress-ng --vm 4 --vm-bytes 85% --vm-method all --timeout {duration}s"
    elif test_type == "gpu":
        subprocess.run("vcgencmd render_bar 1", shell=True, capture_output=True)
        time.sleep(duration)
        subprocess.run("vcgencmd render_bar 0", shell=True, capture_output=True)
        return
    elif test_type == "all":
        cmd = f"stress-ng --cpu 4 --vm 2 --vm-bytes 75% --timeout {duration}s"
    else:
        return
    
    subprocess.run(cmd, shell=True, capture_output=True)

def show_diagnostic_page(test_type, elapsed_time, peak_temp, final_hex):
    level, issues = parse_throttle_status(final_hex)
    
    if level == "OPTIMAL":
        rating = "EXCELLENT (Fully Stable)"
    elif level == "WARNING":
        rating = "MODERATE (Past flags present, current run stable)"
    else:
        rating = "POOR / UNSTABLE (Active throttling occurred)"

    report = f"Test Performed   : {test_type.upper()}\n"
    report += f"Duration Run     : {elapsed_time} seconds\n"
    report += f"Peak Temperature : {peak_temp}\n"
    report += f"System Rating    : {rating}\n"
    report += "--------------------------------------------------\n"
    report += "Diagnostic Findings:\n"
    
    if not issues:
        report += " • No active or historical stability issues logged."
    else:
        for issue in issues:
            report += f" • {issue}\n"

    subprocess.run(["whiptail", "--title", "PiTweaks Diagnostic Report", "--msgbox", report, "18", "65"])

def main_dashboard(test_type):
    duration = 45 
    stress_thread = threading.Thread(target=start_stress_workload, args=(test_type, duration))
    stress_thread.daemon = True
    stress_thread.start()

    start_time = time.time()
    peak_temp = "N/A"
    final_hex = "throttled=0x0"
    elapsed = 0

    try:
        while True:
            elapsed = int(time.time() - start_time)
            remaining = max(0, duration - elapsed)
            
            if not stress_thread.is_alive() or remaining == 0:
                break

            temp, freq, volts, ram, load_avg = get_hardware_stats()
            if temp != "N/A":
                peak_temp = temp

            raw_hex = run_cmd("vcgencmd get_throttled")
            if raw_hex:
                final_hex = raw_hex

            os.system('clear')
            print(f"==================================================")
            print(f" PiTweaks STABILITY TESTER [{test_type.upper()}]")
            print(f" Time Remaining: {remaining}s (Press Ctrl+C to abort)")
            print(f"--------------------------------------------------")
            print(f" CPU Temperature : {temp}")
            print(f" CPU Frequency   : {freq}")
            print(f" Core Voltage    : {volts}")
            print(f" RAM Usage       : {ram}")
            print(f" Load Average    : {load_avg}")
            print(f"==================================================")
            time.sleep(1.5)

    except KeyboardInterrupt:
        pass
    finally:
        subprocess.run("killall stress-ng 2>/dev/null", shell=True, capture_output=True)
        subprocess.run("vcgencmd render_bar 0 2>/dev/null", shell=True, capture_output=True)
        show_diagnostic_page(test_type, elapsed, peak_temp, final_hex)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        main_dashboard(sys.argv[1])
EOF

chmod +x "$TARGET_SCRIPT"

echo "📝 Writing local user wrapper..."
cat << EOF > "$WRAPPER_SCRIPT"
#!/bin/bash
TARGET_PY="$TARGET_SCRIPT"

while true; do
    CHOICE=\$(whiptail --title "PiTweaks - Stability & Stress Test Suite" \\
        --menu "Please select a benchmark test mode:" 15 60 5 \\
        "1" "CPU Stress Test" \\
        "2" "RAM Memory Test" \\
        "3" "GPU Render Test" \\
        "4" "All-At-Once Comprehensive Test" \\
        "5" "Exit" 3>&1 1>&2 2>&3)
    
    EXIT_STATUS=\$?
    if [ \$EXIT_STATUS != 0 ] || [ "\$CHOICE" = "5" ]; then
        clear
        echo "Exiting PiTweaks. Goodbye!"
        exit 0
    fi

    case \$CHOICE in
        1) python3 "\$TARGET_PY" cpu ;;
        2) python3 "\$TARGET_PY" ram ;;
        3) python3 "\$TARGET_PY" gpu ;;
        4) python3 "\$TARGET_PY" all ;;
    esac
done
EOF

chmod +x "$WRAPPER_SCRIPT"

echo "=================================================="
if [ "$UPDATE_MODE" = true ]; then
    echo " ✅ PiTweaks TUI successfully updated in place!"
else
    echo " ✅ PiTweaks TUI successfully installed!"
fi
echo "=================================================="
echo "ℹ️ You can now run the menu anytime by typing: pitweaks-tui"
echo "=================================================="

read -p "Do you want to launch the stability tester now? (y/n): " RUN_CHOICE
if [ "$RUN_CHOICE" = "y" ] || [ "$RUN_CHOICE" = "Y" ]; then
    echo "Launching pitweaks-tui..."
    exec "$WRAPPER_SCRIPT"
else
    echo "Installation finalized."
fi
