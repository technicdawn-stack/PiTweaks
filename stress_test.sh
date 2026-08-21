#!/bin/bash

# Description: Live TUI stability testing suite with real-time hardware telemetry and throttle detection.

# ==============================================================================
# 🍓 PiTweaks TUI Installer - Throttle & Stability Diagnostic Suite
# ==============================================================================

set -e

# Resolve execution user and home directory
if [ -n "$SUDO_USER" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    CURRENT_USER="$SUDO_USER"
else
    REAL_HOME="$HOME"
    CURRENT_USER="$(whoami)"
fi

INSTALL_DIR="$REAL_HOME/PiTweaks"
mkdir -p "$INSTALL_DIR"

echo "🔍 Checking system dependencies..."
if ! command -v vcgencmd &> /dev/null; then
    echo "❌ Error: 'vcgencmd' not found. This tool must run on Raspberry Pi OS."
    exit 1
fi

if ! dpkg -s python3 stress-ng &> /dev/null; then
    echo "📦 Installing python3 and stress-ng..."
    sudo apt-get update -qq && sudo apt-get install -y python3 stress-ng -qq
fi

echo "📝 Generating PiTweaks TUI script..."

cat << 'EOF' > "$INSTALL_DIR/pi_tui.py"
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
    temp_raw = run_cmd("vcgencmd measure_temp")
    temp = temp_raw.replace("temp=", "").replace("'C", "°C") if "temp=" in temp_raw else "N/A"

    freq_raw = run_cmd("vcgencmd measure_clock arm")
    if "frequency=" in freq_raw:
        freq_hz = int(freq_raw.split("=")[1])
        freq = f"{freq_hz / 1000000:.0f} MHz"
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

    return temp, freq, volts, ram

def parse_throttle_status():
    raw_hex = run_cmd("vcgencmd get_throttled")
    if "throttled=" not in raw_hex:
        return f"{GREEN}🟢 OPTIMAL (No Throttling){RESET}"
    
    try:
        hex_str = raw_hex.split("=")[1].strip()
        dec_val = int(hex_str, 16)
    except Exception:
        return f"{GREEN}🟢 OPTIMAL{RESET}"

    if dec_val == 0:
        return f"{GREEN}🟢 OPTIMAL (No Throttling Detected){RESET}"

    statuses = []
    if (dec_val >> 0) & 1:
        statuses.append(f"{RED}  🔴 [ACTIVE] Under-voltage detected! (Power supply issue){RESET}")
    if (dec_val >> 1) & 1:
        statuses.append(f"{RED}  🔴 [ACTIVE] ARM frequency capped due to thermal limits.{RESET}")
    if (dec_val >> 2) & 1:
        statuses.append(f"{RED}  🔴 [ACTIVE] CPU actively being throttled!{RESET}")
    if (dec_val >> 3) & 1:
        statuses.append(f"{RED}  🔴 [ACTIVE] Soft temperature limit active.{RESET}")

    if (dec_val >> 16) & 1:
        statuses.append(f"{YELLOW}  🟡 [PAST] Under-voltage occurred since last reboot.{RESET}")
    if (dec_val >> 17) & 1:
        statuses.append(f"{YELLOW}  🟡 [PAST] Frequency capping occurred since last reboot.{RESET}")
    if (dec_val >> 18) & 1:
        statuses.append(f"{YELLOW}  🟡 [PAST] Throttling occurred since last reboot.{RESET}")
    if (dec_val >> 19) & 1:
        statuses.append(f"{YELLOW}  🟡 [PAST] Soft temperature limit occurred since last reboot.{RESET}")

    return "\n".join(statuses) if statuses else f"{GREEN}🟢 OPTIMAL{RESET}"

def start_stress_workload(test_type, duration):
    if test_type == "cpu":
        cmd = f"stress-ng --cpu 4 --timeout {duration}s"
    elif test_type == "ram":
        cmd = f"stress-ng --vm 2 --vm-bytes 75% --timeout {duration}s"
    elif test_type == "gpu":
        subprocess.run("vcgencmd render_bar 1", shell=True, capture_output=True)
        time.sleep(duration)
        subprocess.run("vcgencmd render_bar 0", shell=True, capture_output=True)
        return
    elif test_type == "all":
        cmd = f"stress-ng --cpu 4 --vm 1 --timeout {duration}s"
    else:
        return
    
    subprocess.run(cmd, shell=True, capture_output=True)

def main_dashboard(test_type):
    duration = 45 
    stress_thread = threading.Thread(target=start_stress_workload, args=(test_type, duration))
    stress_thread.daemon = True
    stress_thread.start()

    start_time = time.time()
    sys.stdout.write("\033[?25l")
    sys.stdout.flush()

    try:
        while True:
            elapsed = int(time.time() - start_time)
            remaining = max(0, duration - elapsed)
            
            if not stress_thread.is_alive() or remaining == 0:
                break

            temp, freq, volts, ram = get_hardware_stats()
            throttle_info = parse_throttle_status()

            os.system('clear')
            dashboard = f"""
{CYAN}╔══════════════════════════════════════════════════════════════╗
║                 🍓 PiTweaks STABILITY TESTER                 ║
╚══════════════════════════════════════════════════════════════╝{RESET}
 {BOLD}Active Test Mode:{RESET} {test_type.upper()}  |  {BOLD}Time Remaining:{RESET} {remaining}s

 {CYAN}┌─ HARDWARE TELEMETRY ────────────────────────────────────────┐{RESET}
   🔥 CPU Temperature : {YELLOW}{temp}{RESET}
   ⚡ CPU Frequency   : {freq}
   🔋 Core Voltage    : {volts}
   💾 RAM Usage       : {ram}

 {CYAN}┌─ ACTIVE THROTTLING & THERMAL WATCHER ───────────────────────┐{RESET}
{throttle_info}
{CYAN}└─────────────────────────────────────────────────────────────┘{RESET}
 {BOLD}[Ctrl+C] Abort Test & Return to Menu{RESET}
"""
            sys.stdout.write(dashboard)
            sys.stdout.flush()
            time.sleep(1.5)

    except KeyboardInterrupt:
        pass
    finally:
        subprocess.run("killall stress-ng 2>/dev/null", shell=True, capture_output=True)
        subprocess.run("vcgencmd render_bar 0 2>/dev/null", shell=True, capture_output=True)
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()
        print(f"\n{GREEN}✅ Test session ended successfully.{RESET}\n")

def menu_selector():
    while True:
        os.system('clear')
        print(f"{CYAN}=================================================={RESET}")
        print(f"{CYAN} 🍓 PiTweaks - Stability & Stress Test Suite      {RESET}")
        print(f"{CYAN}=================================================={RESET}")
        print(" Please select a benchmark test mode:")
        print("   1) CPU Stress Test")
        print("   2) RAM Memory Test")
        print("   3) GPU Render Test")
        print("   4) All-At-Once Comprehensive Test")
        print("   5) Exit")
        print("--------------------------------------------------")
        
        choice = input(" Select option [1-5]: ").strip()

        if choice == "1":
            main_dashboard("cpu")
            input("Press [Enter] to continue...")
        elif choice == "2":
            main_dashboard("ram")
            input("Press [Enter] to continue...")
        elif choice == "3":
            main_dashboard("gpu")
            input("Press [Enter] to continue...")
        elif choice == "4":
            main_dashboard("all")
            input("Press [Enter] to continue...")
        elif choice == "5":
            print("Exiting PiTweaks. Goodbye!")
            sys.exit(0)
        else:
            print(f"{RED}Invalid choice. Please select 1-5.{RESET}")
            time.sleep(1)

if __name__ == "__main__":
    menu_selector()
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR/pi_tui.py"
chmod +x "$INSTALL_DIR/pi_tui.py"

# Create a convenient global shortcut command 'pitweaks-tui'
sudo ln -sf "$INSTALL_DIR/pi_tui.py" /usr/local/bin/pitweaks-tui

echo "=================================================="
echo " ✅ Installation Complete!"
echo "=================================================="
echo " You can now launch the TUI tester from anywhere by typing:"
echo " 👉 pitweaks-tui"
echo "==================================================]"
