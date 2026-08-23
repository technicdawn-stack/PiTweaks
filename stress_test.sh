#!/bin/bash
# Description: PiTweaks All-in-One Continuous Stress Suite & Telemetry V1.8
# PERSISTENT: TRUE

set -e

INSTALL_DIR="$HOME/PiTweaks"
TARGET_SCRIPT="$INSTALL_DIR/pi_tui.py"

mkdir -p "$INSTALL_DIR"

# 1. Self-install core packages & python modules if missing
if ! command -v stress-ng &> /dev/null || ! command -v whiptail &> /dev/null; then
    echo "📦 Installing required system packages (stress-ng, whiptail)..."
    sudo apt-get update -qq && sudo apt-get install -y stress-ng whiptail -qq
fi

if ! python3 -c "import psutil" &> /dev/null; then
    echo "📦 Installing required Python module (psutil)..."
    sudo apt-get install -y python3-psutil -qq
fi

# 2. Write the Python TUI & Stopwatch Telemetry Core if it doesn't exist
if [ ! -f "$TARGET_SCRIPT" ]; then
    echo "📝 Writing Stop-Watch Telemetry Core..."
    cat << 'EOF' > "$TARGET_SCRIPT"
#!/usr/bin/env python3
import os
import sys
import time
import subprocess
import threading
import psutil

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

def make_bar(percentage, width=18):
    try:
        p = max(0.0, min(100.0, float(percentage)))
    except:
        p = 0.0
    filled = int(width * p / 100)
    bar = "█" * filled + "░" * (width - filled)
    color = GREEN if p < 70 else (YELLOW if p < 90 else RED)
    return f"{color}[{bar}]{RESET} {p:5.1f}%"

def get_hardware_stats():
    # Temperature
    temp_raw = run_cmd("vcgencmd measure_temp")
    temp_str = temp_raw.replace("temp=", "").replace("'C", "°C") if "temp=" in temp_raw else "N/A"
    
    temp_val = 0.0
    if "°C" in temp_str:
        try:
            temp_val = float(temp_str.replace("°C", "").replace("c", ""))
        except:
            pass

    # Clocks & Volts
    freq_raw = run_cmd("vcgencmd measure_clock arm")
    freq = f"{int(freq_raw.split('=')[1]) / 1000000:.0f} MHz" if "=" in freq_raw else "N/A"

    gpu_freq_raw = run_cmd("vcgencmd measure_clock core")
    gpu_freq = f"{int(gpu_freq_raw.split('=')[1]) / 1000000:.0f} MHz" if "=" in gpu_freq_raw else "N/A"

    volts = run_cmd("vcgencmd measure_volts core").replace("volt=", "")
    sdram_c = run_cmd("vcgencmd measure_volts sdram_c").replace("volt=", "")
    sdram_io = run_cmd("vcgencmd measure_volts sdram_i").replace("volt=", "")
    sdram_p = run_cmd("vcgencmd measure_volts sdram_p").replace("volt=", "")

    # RAM via psutil
    mem = psutil.virtual_memory()
    ram_perc = mem.percent
    ram_str = f"{int(mem.used / 1024 / 1024)}MB / {int(mem.total / 1024 / 1024)}MB"

    # Load Average
    load_avg_vals = os.getloadavg()
    load_avg = f"{load_avg_vals[0]:.2f} / {load_avg_vals[1]:.2f} / {load_avg_vals[2]:.2f}"

    # Per-Core CPU percentages using psutil
    core_usages = psutil.cpu_percent(interval=None, percpu=True)
    core_bars = [(i, usage) for i, usage in enumerate(core_usages)]

    return temp_str, temp_val, freq, gpu_freq, volts, sdram_c, sdram_io, sdram_p, ram_str, ram_perc, load_avg, core_bars

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

def show_diagnostic_page(test_type, elapsed_time, peak_temp_str, final_hex):
    level, issues = parse_throttle_status(final_hex)
    rating = "EXCELLENT (Fully Stable)" if level == "OPTIMAL" else ("MODERATE (Past Warnings)" if level == "WARNING" else "POOR / UNSTABLE")
    mins, secs = divmod(elapsed_time, 60)
    
    report = f"Test Performed   : {test_type.upper()}\n"
    report += f"Total Time Ran   : {mins:02d}m {secs:02d}s\n"
    report += f"Peak Temperature : {peak_temp_str}\n"
    report += f"System Rating    : {rating}\n--------------------------------------------------\nFindings:\n"
    report += " • No issues logged." if not issues else "\n".join([f" • {i}" for i in issues])

    subprocess.run(["whiptail", "--title", "PiTweaks Diagnostic Report", "--msgbox", report, "18", "65"])

def main_dashboard(test_type):
    stress_thread = threading.Thread(target=start_stress_workload, args=(test_type,))
    stress_thread.daemon = True
    stress_thread.start()

    # Prime the psutil cpu percent calculation so it doesn't return empty on the first tick
    psutil.cpu_percent(interval=None, percpu=True)
    time.sleep(0.5)

    start_time = time.time()
    sys.stdout.write("\033[?25l")
    sys.stdout.flush()

    peak_temp_val = -1.0
    peak_temp_str = "N/A"
    final_hex = "throttled=0x0"
    elapsed = 0

    os.system('clear')

    try:
        while True:
            elapsed = int(time.time() - start_time)
            mins, secs = divmod(elapsed, 60)
            time_formatted = f"{mins:02d}:{secs:02d}"

            temp_str, temp_val, freq, gpu_freq, volts, sdram_c, sdram_io, sdram_p, ram_str, ram_perc, load_avg, core_bars = get_hardware_stats()
            
            if temp_val > peak_temp_val:
                peak_temp_val = temp_val
                peak_temp_str = temp_str

            raw_hex = run_cmd("vcgencmd get_throttled")
            if raw_hex:
                final_hex = raw_hex

            throttle_info = format_throttle_display(raw_hex)

            # Properly construct the core display block so it never vanishes
            core_display = ""
            if core_bars:
                for core_id, usage in core_bars:
                    core_display += f"   Core {core_id:<2}         : {make_bar(usage, 18)}\n"
            else:
                core_display = "   Loading core metrics...\n"

            sys.stdout.write("\033[H")
            sys.stdout.flush()

            print(f"""
{CYAN}╔══════════════════════════════════════════════════════════════╗
║        PiTweaks CONTINUOUS TELEMETRY & STRESS SUITE          ║
╚══════════════════════════════════════════════════════════════╝{RESET}
 {BOLD}Active Test:{RESET} {test_type.upper()}  |  {BOLD}Stop-Watch Time:{RESET} {YELLOW}{time_formatted}{RESET}

 {CYAN}┌─ ADVANCED HARDWARE TELEMETRY ───────────────────────────────┐{RESET}
   CPU Temperature : {YELLOW}{temp_str}{RESET}  (Peak: {peak_temp_str})
   CPU Clock Speed : {freq}
   GPU / Core Clock: {gpu_freq}
   Core Voltage    : {volts}
   SDRAM Volts     : Core: {sdram_c} | I/O: {sdram_io} | Phy: {sdram_p}
   RAM Usage       : {make_bar(ram_perc, 18)}  ({ram_str})
   Load Average    : {load_avg}

 {CYAN}┌─ PER-CORE CPU UTILIZATION ──────────────────────────────────┐{RESET}
{core_display.rstrip()}
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
        show_diagnostic_page(test_type, elapsed, peak_temp_str, final_hex)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        main_dashboard(sys.argv[1])
EOF
    chmod +x "$TARGET_SCRIPT"
fi

# 3. Launch Whiptail menu immediately on execution
while true; do
    CHOICE=$(whiptail --title "PiTweaks - Continuous Stress Suite" \
        --menu "Select a test mode (Press Ctrl+C to stop anytime):" 15 65 5 \
        "1" "CPU Stress Test (Continuous)" \
        "2" "RAM Memory Stress Test (Continuous)" \
        "3" "GPU Render Stress Test (Continuous)" \
        "4" "All-At-Once Comprehensive Test" \
        "5" "Exit" 3>&1 1>&2 2>&3)
    
    if [ $? != 0 ] || [ "$CHOICE" = "5" ]; then
        clear
        echo "Exiting PiTweaks. Goodbye!"
        exit 0
    fi

    case $CHOICE in
        1) python3 "$TARGET_SCRIPT" cpu ;;
        2) python3 "$TARGET_SCRIPT" ram ;;
        3) python3 "$TARGET_SCRIPT" gpu ;;
        4) python3 "$TARGET_SCRIPT" all ;;
    esac
done
