#!/bin/bash
# Description: PiTweaks Advanced Continuous Telemetry Suite Installer

set -e

REAL_HOME="$HOME"
INSTALL_DIR="$REAL_HOME/PiTweaks"
TARGET_SCRIPT="$INSTALL_DIR/pi_tui.py"
USER_BIN_DIR="$REAL_HOME/.local/bin"
WRAPPER_SCRIPT="$USER_BIN_DIR/pitweaks-tui"

mkdir -p "$INSTALL_DIR"
mkdir -p "$USER_BIN_DIR"

echo "📦 Installing required packages..."
sudo apt-get update -qq && sudo apt-get install -y stress-ng whiptail -qq

echo "📝 Writing Fresh Stop-Watch Telemetry Core..."

cat << 'EOF' > "$TARGET_SCRIPT"
#!/usr/bin/env python3
# Description: PiTweaks Continuous Hardware Telemetry and Stop-Watch Core Engine

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
    temp_raw = run_cmd("vcgencmd measure_temp")
    temp = temp_raw.replace("temp=", "").replace("'C", "°C") if "temp=" in temp_raw else "N/A"

    freq_raw = run_cmd("vcgencmd measure_clock arm")
    if "=" in freq_raw:
        try:
            freq = f"{int(freq_raw.split('=')[1]) / 1000000:.0f} MHz"
        except:
            freq = "N/A"
    else:
        freq = "N/A"

    gpu_freq_raw = run_cmd("vcgencmd measure_clock core")
    if "=" in gpu_freq_raw:
        try:
            gpu_freq = f"{int(gpu_freq_raw.split('=')[1]) / 1000000:.0f} MHz"
        except:
            gpu_freq = "N/A"
    else:
        gpu_freq = "N/A"

    volts = run_cmd("vcgencmd measure_volts core").replace("volt=", "")
    sdram_c = run_cmd("vcgencmd measure_volts sdram_c").replace("volt=", "")
    sdram_io = run_cmd("vcgencmd measure_volts sdram_i").replace("volt=", "")
    sdram_p = run_cmd("vcgencmd measure_volts sdram_p").replace("volt=", "")

    ram_raw = run_cmd("free -m | awk '/Mem:/ {print $3, $2}'")
    if ram_raw and "N/A" not in ram_raw:
        parts = ram_raw.split()
        if len(parts) == 2:
            used, total = int(parts[0]), int(parts[1])
            ram = f"{used}MB / {total}MB ({(used/total)*100:.1f}%)"
        else:
            ram = "N/A"
    else:
        ram = "N/A"

    load_raw = run_cmd("cat /proc/loadavg")
    loads = load_raw.split()[:3] if load_raw else ["N/A", "N/A", "N/A"]
    load_avg = f"{loads[0]} / {loads[1]} / {loads[2]}"

    return temp, freq, gpu_freq, volts, sdram_c, sdram_io, sdram_p, ram, load_avg

def parse_throttle_status(raw_hex):
    if "throttled=" not in raw_hex:
        return "OPTIMAL", []
    try:
        dec_val = int(raw_hex.split("=")[1].strip(), 16)
    except:
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
        issues.append("[WARNING PAST] Under-voltage since boot")
    if (dec_val >> 17) & 1:
        issues.append("[WARNING PAST] Frequency capping since boot")
    if (dec_val >> 18) & 1:
        issues.append("[WARNING PAST] Throttling since boot")
    if (dec_val >> 19) & 1:
        issues.append("[WARNING PAST] Soft temp limit since boot")

    return ("CRITICAL" if has_active else "WARNING"), issues

def format_throttle_display(raw_hex):
    level, issues = parse_throttle_status(raw_hex)
    if not issues:
        return f"{GREEN}  ✔ OPTIMAL: No throttling detected{RESET}"
    return "\n".join([f"{RED}  ✘ {i}{RESET}" if "CRITICAL" in i else f"{YELLOW}  ⚠ {i}{RESET}" for i in issues])

def start_stress_workload(test_type):
    if test_type == "cpu":
        cmd = "stress-ng --cpu 0"
    elif test_type == "ram":
        cmd = "stress-ng --vm 4 --vm-bytes 85% --vm-method all"
    elif test_type == "gpu":
        subprocess.run("vcgencmd render_bar 1", shell=True, capture_output=True)
        return
    elif test_type == "all":
        cmd = "stress-ng --cpu 0 --vm 2 --vm-bytes 75%"
    else:
        return
    subprocess.run(cmd, shell=True)

def show_diagnostic_page(test_type, elapsed_time, peak_temp, final_hex):
    level, issues = parse_throttle_status(final_hex)
    rating = "EXCELLENT (Fully Stable)" if level == "OPTIMAL" else ("MODERATE (Past Warnings)" if level == "WARNING" else "POOR / UNSTABLE")
    mins, secs = divmod(elapsed_time, 60)
    
    report = f"Test Performed   : {test_type.upper()}\n"
    report += f"Total Time Ran   : {mins:02d}m {secs:02d}s\n"
    report += f"Peak Temperature : {peak_temp}\n"
    report += f"System Rating    : {rating}\n--------------------------------------------------\nFindings:\n"
    report += " • No issues logged." if not issues else "\n".join([f" • {i}" for i in issues])

    subprocess.run(["whiptail", "--title", "PiTweaks Diagnostic Report", "--msgbox", report, "18", "65"])

def main_dashboard(test_type):
    stress_thread = threading.Thread(target=start_stress_workload, args=(test_type,))
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
            mins, secs = divmod(elapsed, 60)
            time_formatted = f"{mins:02d}:{secs:02d}"

            temp, freq, gpu_freq, volts, sdram_c, sdram_io, sdram_p, ram, load_avg = get_hardware_stats()
            if temp != "N/A":
                peak_temp = temp

            raw_hex = run_cmd("vcgencmd get_throttled")
            if raw_hex:
                final_hex = raw_hex

            throttle_info = format_throttle_display(raw_hex)

            os.system('clear')
            print(f"""
{CYAN}╔══════════════════════════════════════════════════════════════╗
║        PiTweaks CONTINUOUS TELEMETRY & STRESS SUITE          ║
╚══════════════════════════════════════════════════════════════╝{RESET}
 {BOLD}Active Test:{RESET} {test_type.upper()}  |  {BOLD}Stop-Watch Time:{RESET} {YELLOW}{time_formatted}{RESET}

 {CYAN}┌─ ADVANCED HARDWARE TELEMETRY ───────────────────────────────┐{RESET}
   CPU Temperature : {YELLOW}{temp}{RESET}  (Peak: {peak_temp})
   CPU Clock Speed : {freq}
   GPU / Core Clock: {gpu_freq}
   Core Voltage    : {volts}
   SDRAM Volts     : Core: {sdram_c} | I/O: {sdram_io} | Phy: {sdram_p}
   RAM Usage       : {ram}
   Load Average    : {load_avg}

 {CYAN}┌─ LIVE THROTTLING & HEALTH WATCHER ──────────────────────────┐{RESET}
{throttle_info}
{CYAN}└─────────────────────────────────────────────────────────────┘{RESET}
 {BOLD}[Ctrl+C] Stop Test & View Diagnostic Report{RESET}
""")
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

echo "📝 Writing Launcher Wrapper..."
cat << EOF > "$WRAPPER_SCRIPT"
#!/bin/bash
# Description: PiTweaks Interactive Whiptail Menu Launcher
TARGET_PY="$TARGET_SCRIPT"

while true; do
    CHOICE=\$(whiptail --title "PiTweaks - Continuous Stress Suite" \\
        --menu "Select a test mode (Press Ctrl+C to stop anytime):" 15 65 5 \\
        "1" "CPU Stress Test (Continuous)" \\
        "2" "RAM Memory Stress Test (Continuous)" \\
        "3" "GPU Render Stress Test (Continuous)" \\
        "4" "All-At-Once Comprehensive Test" \\
        "5" "Exit" 3>&1 1>&2 2>&3)
    
    if [ \$? != 0 ] || [ "\$CHOICE" = "5" ]; then
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
echo " ✅ Clean installation complete!"
echo "=================================================="
echo "ℹ️ Run your fresh tool via: pitweaks-tui"
echo "=================================================="
