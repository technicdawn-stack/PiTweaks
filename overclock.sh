#!/bin/bash
# ==============================================================================
# Description: PiTweaks Overclock, Stress Test & Telemetry Manager (Pi 3B V1.1)
# PERSISTENT: TRUE (Config only modified on explicit user action)
# Category: Tools
# ==============================================================================

set -u

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo bash overclock.sh"
    exit 1
fi

# Resolve the real user's home directory even under sudo
if [ -n "${SUDO_USER:-}" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_HOME="$HOME"
fi

INSTALL_DIR="$REAL_HOME/PiTweaks"
TARGET_SCRIPT="$INSTALL_DIR/overclock.sh"
mkdir -p "$INSTALL_DIR"

CONFIG="/boot/firmware/config.txt"
[ -f "$CONFIG" ] || CONFIG="/boot/config.txt"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Raspberry Pi config.txt not found."
    exit 1
fi

# Ensure minimal required packages exist without hidden disk logging
if ! command -v stress-ng &> /dev/null || ! command -v whiptail &> /dev/null; then
    apt-get update -qq && apt-get install -y stress-ng whiptail -qq
fi

if ! python3 -c "import psutil" &> /dev/null; then
    apt-get install -y python3-psutil -qq
fi

# Embedded Python high-performance RAM-only telemetry & stress engine
if [ "$1" = "_run_python_engine" ]; then
    shift
    python3 - "$@" << 'EOF'
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
    temp_raw = run_cmd("vcgencmd measure_temp")
    temp_str = temp_raw.replace("temp=", "").replace("'C", "°C") if "temp=" in temp_raw else "N/A"
    
    temp_val = 0.0
    if "°C" in temp_str:
        try:
            temp_val = float(temp_str.replace("°C", "").replace("c", ""))
        except:
            pass

    freq_raw = run_cmd("vcgencmd measure_clock arm")
    freq = f"{int(freq_raw.split('=')[1]) / 1000000:.0f} MHz" if "=" in freq_raw else "N/A"

    gpu_freq_raw = run_cmd("vcgencmd measure_clock core")
    gpu_freq = f"{int(gpu_freq_raw.split('=')[1]) / 1000000:.0f} MHz" if "=" in gpu_freq_raw else "N/A"

    volts = run_cmd("vcgencmd measure_volts core").replace("volt=", "")
    
    mem = psutil.virtual_memory()
    ram_perc = mem.percent
    ram_str = f"{int(mem.used / 1024 / 1024)}MB / {int(mem.total / 1024 / 1024)}MB"

    load_avg_vals = os.getloadavg()
    load_avg = f"{load_avg_vals[0]:.2f} / {load_avg_vals[1]:.2f} / {load_avg_vals[2]:.2f}"

    core_usages = psutil.cpu_percent(interval=None, percpu=True)
    core_bars = [(i, usage) for i, usage in enumerate(core_usages)]

    return temp_str, temp_val, freq, gpu_freq, volts, ram_str, ram_perc, load_avg, core_bars

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
        return f"{GREEN}   ● OPTIMAL: No throttling detected{RESET}"
    return "\n".join([f"{RED}   ✘ {i}{RESET}" if "CRITICAL" in i else f"{YELLOW}   ⚠ {i}{RESET}" for i in issues])

def start_stress_workload(test_type):
    if test_type == "cpu":
        cmd = "stress-ng --cpu 0"
    elif test_type == "ram":
        cmd = "stress-ng --vm 2 --vm-bytes 75%"
    elif test_type == "all":
        cmd = "stress-ng --cpu 0 --vm 2 --vm-bytes 75%"
    else:
        return
    subprocess.run(cmd, shell=True)

def show_diagnostic_page(test_type, elapsed_time, peak_temp_str, final_hex):
    if test_type == "monitor":
        return
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
    if test_type != "monitor":
        stress_thread = threading.Thread(target=start_stress_workload, args=(test_type,))
        stress_thread.daemon = True
        stress_thread.start()

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

            temp_str, temp_val, freq, gpu_freq, volts, ram_str, ram_perc, load_avg, core_bars = get_hardware_stats()
            
            if temp_val > peak_temp_val:
                peak_temp_val = temp_val
                peak_temp_str = temp_str

            raw_hex = run_cmd("vcgencmd get_throttled")
            if raw_hex:
                final_hex = raw_hex

            throttle_info = format_throttle_display(raw_hex)

            core_display = ""
            if core_bars:
                for core_id, usage in core_bars:
                    core_display += f"    Core {core_id:<2}      : {make_bar(usage, 18)}\n"
            else:
                core_display = "    Loading core metrics...\n"

            sys.stdout.write("\033[H")
            sys.stdout.flush()

            mode_title = "LIVE MONITOR" if test_type == "monitor" else f"STRESS TEST ({test_type.upper()})"
            
            print(f"""
{CYAN}╔══════════════════════════════════════════════════════════════╗
║         PiTweaks RAM-ONLY TELEMETRY & STRESS SUITE           ║
╚══════════════════════════════════════════════════════════════╝{RESET}
 {BOLD}Mode:{RESET} {mode_title}  |  {BOLD}Elapsed Time:{RESET} {YELLOW}{time_formatted}{RESET}

 {CYAN}┌─ ADVANCED HARDWARE TELEMETRY ───────────────────────────────┐{RESET}
    CPU Temperature : {YELLOW}{temp_str}{RESET}  (Peak: {peak_temp_str})
    ARM Clock Speed : {freq}
    GPU Core Clock  : {gpu_freq}
    Core Voltage    : {volts}
    RAM Usage       : {make_bar(ram_perc, 18)}  ({ram_str})
    Load Average    : {load_avg}

 {CYAN}┌─ PER-CORE CPU UTILIZATION ──────────────────────────────────┐{RESET}
{core_display}
 {CYAN}┌─ LIVE THROTTLING & HEALTH WATCHER ──────────────────────────┐{RESET}
{throttle_info}
{CYAN}└─────────────────────────────────────────────────────────────┘{RESET}
 {BOLD}[Ctrl+C] Return to Main Menu{RESET}
""")
            time.sleep(1.0)
    except KeyboardInterrupt:
        pass
    finally:
        subprocess.run("killall stress-ng 2>/dev/null", shell=True, capture_output=True)
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()
        show_diagnostic_page(test_type, elapsed, peak_temp_str, final_hex)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        main_dashboard(sys.argv[1])
EOF
    exit 0
fi

# Self-synchronize script to correct local user path
if [ "$BASH_SOURCE" != "$TARGET_SCRIPT" ]; then
    cp "$BASH_SOURCE" "$TARGET_SCRIPT"
    chmod +x "$TARGET_SCRIPT"
fi

write_profile() {
    local name="$1"
    local body="$2"
    local tmp
    tmp=$(mktemp)

    sed '/^# --- PiTweaks Overclock Start ---$/,/^# --- PiTweaks Overclock End ---$/d' "$CONFIG" > "$tmp"

    {
        printf '\n# --- PiTweaks Overclock Start ---\n'
        printf '# PROFILE: %s\n' "$name"
        printf '%b\n' "$body"
        printf '# --- PiTweaks Overclock End ---\n'
    } >> "$tmp"

    cp "$tmp" "$CONFIG"
    rm -f "$tmp"
    whiptail --title "Success" --msgbox "Configuration applied: $name\nA system reboot is required for changes to take effect." 10 50
}

remove_profile() {
    local tmp
    tmp=$(mktemp)
    sed '/^# --- PiTweaks Overclock Start ---$/,/^# --- PiTweaks Overclock End ---$/d' "$CONFIG" > "$tmp"
    cp "$tmp" "$CONFIG"
    rm -f "$tmp"
    whiptail --title "Success" --msgbox "PiTweaks settings removed. Reboot required to restore factory defaults." 10 50
}

run_diagnostics() {
    local temp=$(vcgencmd measure_temp 2>/dev/null || echo "N/A")
    local freq=$(vcgencmd measure_clock arm 2>/dev/null || echo "N/A")
    local volts=$(vcgencmd measure_volts core 2>/dev/null || echo "N/A")
    local throttle=$(vcgencmd get_throttled 2>/dev/null || echo "N/A")

    local report="Hardware : Raspberry Pi 3 Model B\n"
    report+="Temperature : $temp\n"
    report+="ARM Clock   : $freq\n"
    report+="Core Volts  : $volts\n"
    report+="Throttle Status : $throttle\n\n"
    report+="Runtime memory tracking active. Zero disk logs written."

    whiptail --title "PiTweaks Diagnostics" --msgbox "$report" 15 60
}

while true; do
    CHOICE=$(whiptail --title "PiTweaks Overclock Manager (Pi 3B)" \
        --menu "Zero SD wear runtime. Select an option:" 20 65 12 \
        "1" "Eco Profile (800MHz)" \
        "2" "Quiet Profile (1000MHz)" \
        "3" "Default Factory Config" \
        "4" "Performance Profile (1300MHz)" \
        "5" "High Performance Profile (1350MHz)" \
        "6" "Restore Last Preset" \
        "7" "Restore Original Factory Config" \
        "8" "Live Monitor (RAM-only telemetry)" \
        "9" "Auto Overclock Wizard" \
        "10" "Manual Stress Test" \
        "11" "System Diagnostics" \
        "12" "Exit" 3>&1 1>&2 2>&3)
    
    if [ $? != 0 ] || [ "$CHOICE" = "12" ]; then
        clear
        echo "Exiting PiTweaks."
        exit 0
    fi

    case $CHOICE in
        1) write_profile "Eco" "arm_freq=800\ninitial_turbo=0" ;;
        2) write_profile "Quiet" "arm_freq=1000\ninitial_turbo=0" ;;
        3) remove_profile ;;
        4) write_profile "Performance" "arm_freq=1300\ncore_freq=400\nover_voltage=2" ;;
        5) write_profile "High Performance" "arm_freq=1350\ncore_freq=500\nover_voltage=4" ;;
        6) whiptail --title "Info" --msgbox "Preset memory active. Re-apply desired profile from menu." 10 50 ;;
        7) remove_profile ;;
        8) bash "$TARGET_SCRIPT" _run_python_engine monitor ;;
        9) whiptail --title "Auto Overclock" --msgbox "Select target frequency manually via profiles 4 or 5 and stress test to ensure stability." 10 50 ;;
        10) 
            SUBCHOICE=$(whiptail --title "Stress Test Selection" --menu "Choose workload:" 12 50 3 \
                "1" "CPU Stress Test" \
                "2" "RAM Stress Test" \
                "3" "Combined CPU+RAM Test" 3>&1 1>&2 2>&3)
            case $SUBCHOICE in
                1) bash "$TARGET_SCRIPT" _run_python_engine cpu ;;
                2) bash "$TARGET_SCRIPT" _run_python_engine ram ;;
                3) bash "$TARGET_SCRIPT" _run_python_engine all ;;
            esac
            ;;
        11) run_diagnostics ;;
    esac
done
