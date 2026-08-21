#!/bin/bash

# ==============================================================================
# 🍓 PiTweaks TUI Installer - Advanced Telemetry & Stability Suite
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

if ! dpkg -s python3 stress-ng whiptail &> /dev/null; then
    echo "📦 Installing required packages (stress-ng, whiptail)..."
    sudo apt-get update -qq && sudo apt-get install -y stress-ng whiptail -qq
fi

UPDATE_MODE=false
if [ -f "$TARGET_SCRIPT" ]; then
    echo "🔄 Existing installation detected. Updating in place..."
    UPDATE_MODE=true
fi

echo "📝 Writing Advanced PiTweaks core telemetry script..."

cat << 'EOF' > "$TARGET_SCRIPT"
#!/usr/bin/env python3
import os
import sys
import time
import subprocess
import threading

RED = "\033[91m"
YELLOW = "\033[93m"
GREEN = "\033[92m"
CYAN = "\033[96m"
RESET = "\033[0m"
BOLD = "\033[1m"

def run_cmd(command):
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=2)
        return result.stdout.strip()
    except Exception:
        return "N/A"

def get_hardware_stats():
    # Temperature
    temp_raw = run_cmd("vcgencmd measure_temp")
    temp = temp_raw.replace("temp=", "").replace("'C", "°C") if "temp=" in temp_raw else "N/A"

    # CPU Clock Frequency
    freq_raw = run_cmd("vcgencmd measure_clock arm")
    if "=" in freq_raw:
        try:
            freq_hz = int(freq_raw.split("=")[1])
            freq = f"{freq_hz / 1000000:.0f} MHz"
        except Exception:
            freq = "N/A"
    else:
        freq = "N/A"

    # Core Voltage
    volts_raw = run_cmd("vcgencmd measure_volts core")
    volts = volts_raw.replace("volt=", "") if "volt=" in volts_raw else "N/A"

    # SDRAM Voltage
    sdram_raw = run_cmd("vcgencmd measure_volts sdram_c")
    sdram = sdram_raw.replace("volt=", "") if "volt=" in sdram_raw else "N/A"

    # RAM Usage Breakdown
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

    # Load Averages
    load_raw = run_cmd("cat /proc/loadavg")
    loads = load_raw.split()[:3] if load_raw else ["N/A", "N/A", "N/A"]
    load_avg = f"{loads[0]} / {loads[1]} / {loads[2]}"

    return temp, freq, volts, sdram, ram, load_avg

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
    
    # Active bits (0-3)
    if (dec_val >> 0) & 1:
        issues.append("[CRITICAL ACTIVE] Under-voltage detected (Power supply issue)")
        has_active = True
    if (dec_val >> 1) & 1:
        issues.append("[CRITICAL ACTIVE] ARM frequency capped due to thermal limits")
        has_active = True
    if (dec_val >> 2) & 1:
        issues.append("[CRITICAL ACTIVE] CPU actively being throttled")
        has_active = True
    if (dec_val >> 3) & 1:
        issues.append("[CRITICAL ACTIVE] Soft temperature limit active")
        has_active = True

    # Past bits / Sticky history (16-19)
    if (dec_val >> 16) & 1:
        issues.append("[WARNING PAST] Under-voltage occurred since last boot")
    if (dec_val >> 17) & 1:
        issues.append("[WARNING PAST] Frequency capping occurred since last boot")
    if (dec_val >> 18) & 1:
        issues.append("[WARNING PAST] Throttling occurred since last boot")
    if (dec_val >> 19) & 1:
        issues.append("[WARNING PAST] Soft temperature limit occurred since last boot")

    status_level = "CRITICAL" if has_active else "WARNING"
    return status_level, issues

def format_throttle_display(raw_hex):
    level, issues = parse_throttle_status(raw_hex)
    if not issues:
        return f"{GREEN}  ✔ OPTIMAL: No throttling detected{RESET}"
    
    formatted = []
    for issue in issues:
        if "CRITICAL" in issue:
            formatted.append(f"{RED}  ✘ {issue}{RESET}")
        else:
            formatted.append(f"{YELLOW}  ⚠ {issue}{RESET}")
    return "\n".join(formatted)

def start_stress_workload(test_type, duration):
    if test_type == "cpu":
        cmd = f"stress-ng --cpu 0 --timeout {duration}s"
    elif test_type == "ram":
        cmd = f"stress-ng --vm 4 --vm-bytes 85% --vm-method all --timeout {duration}s"
    elif test_type == "gpu":
        subprocess.run("vcgencmd render_bar 1", shell=True, capture_output=True)
        time.sleep(duration)
        subprocess.run("vcgencmd render_bar 0", shell=True, capture_output=True)
        return
    elif test_type == "all":
        cmd = f"stress-ng --cpu 0 --vm 2 --vm-bytes 75% --timeout {duration}s"
    else:
        return
    
    subprocess.run(cmd, shell=True, capture_output=True)

def show_diagnostic_page(test_type, elapsed_time, peak_temp, final_hex):
    level, issues = parse_throttle_status(final_hex)
    
    if level == "OPTIMAL":
        rating = "EXCELLENT (Fully Stable)"
    elif level == "WARNING":
        rating = "MODERATE (Past warnings present, current run stable)"
    else:
        rating = "POOR / UNSTABLE (Active thermal/power limits hit)"

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
    sys.stdout.write("\033[?25l")
    sys.stdout.flush()

    peak_temp = "N/A"
    final_hex = "throttled=0x0"
    elapsed = 0

    try:
        while True:
            elapsed = int(time.time() - start_time)
            remaining = max(0, duration - elapsed)
            
            if not stress_thread.is_alive() or remaining == 0:
                break

            temp, freq, volts, sdram, ram, load_avg = get_hardware_stats()
            if temp != "N/A":
                peak_temp = temp

            raw_hex = run_cmd("vcgencmd get_throttled")
            if raw_hex:
                final_hex = raw_hex

            throttle_info = format_throttle_display(raw_hex)

            os.system('clear')
            dashboard = f"""
{CYAN}╔══════════════════════════════════════════════════════════════╗
║             PiTweaks ADVANCED TELEMETRY TESTER               ║
╚══════════════════════════════════════════════════════════════╝{RESET}
 {BOLD}Active Test:{RESET} {test_type.upper()}  |  {BOLD}Time Remaining:{RESET} {remaining}s

 {CYAN}┌─ HARDWARE METRICS ──────────────────────────────────────────┐{RESET}
   CPU Temperature : {YELLOW}{temp}{RESET}
   CPU Frequency   : {freq}
   Core Voltage    : {volts}  |  SDRAM: {sdram}
   RAM Usage       : {ram}
   Load Average    : {load_avg}

 {CYAN}┌─ LIVE THROTTLING & HEALTH WATCHER ──────────────────────────┐{RESET}
{throttle_info}
{CYAN}└─────────────────────────────────────────────────────────────┘{RESET}
 {BOLD}[Ctrl+C] Abort Test & View Report{RESET}
"""
            sys.stdout.write(dashboard)
            sys.stdout.flush()
            time.sleep(1.0)

    except KeyboardInterrupt:
        pass
    finally:
        subprocess.run("killall stress-ng 2>/dev/null", shell=True, capture_output=True)
        subprocess.run("vcgencmd render_bar 0 2>/dev/null", shell=True, capture_output=True)
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()
        show_diagnostic_page(test_type, elapsed, peak_temp, final_hex)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        main_dashboard(sys.argv[1])
EOF

chmod +x "$TARGET_SCRIPT"

echo "📝 Writing user selector wrapper..."
cat << EOF > "$WRAPPER_SCRIPT"
#!/bin/bash
TARGET_PY="$TARGET_SCRIPT"

while true; do
    CHOICE=\$(whiptail --title "PiTweaks - Stability & Stress Test Suite" \\
        --menu "Please select a benchmark test mode:" 15 60 5 \\
        "1" "CPU Stress Test (All Cores)" \\
        "2" "RAM Memory Stress Test" \\
        "3" "GPU Render Stress Test" \\
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
echo " ✅ PiTweaks Advanced Suite installed successfully!"
echo "=================================================="
echo "ℹ️ Launch anytime by running: pitweaks-tui"
echo "=================================================="

read -p "Do you want to launch the stability tester now? (y/n): " RUN_CHOICE
if [ "$RUN_CHOICE" = "y" ] || [ "$RUN_CHOICE" = "Y" ]; then
    echo "Launching pitweaks-tui..."
    exec "$WRAPPER_SCRIPT"
else
    echo "Installation finalized."
fi
