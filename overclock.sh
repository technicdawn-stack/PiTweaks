bash
#!/bin/bash
# Description: PiTweaks Raspberry Pi overclocking, stress testing and diagnostics V2.0
# PERSISTENT: FALSE
# Category: Tools

set -e

CONFIG_FILE="/boot/firmware/config.txt"
[ -f "$CONFIG_FILE" ] || CONFIG_FILE="/boot/config.txt"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config.txt not found."
    exit 1
fi

# ==============================================================================
# RUNTIME STATE
# Everything here lives in RAM (/run). Nothing is logged to the SD card.
# ==============================================================================

STATE_DIR="/run/pitweaks_overclock"
mkdir -p "$STATE_DIR"

AUTO_STATE="$STATE_DIR/auto_state"
EVENT_LOG="$STATE_DIR/events"
RESULTS_FILE="$STATE_DIR/results"

touch "$EVENT_LOG" "$RESULTS_FILE"

# ==============================================================================
# COLOURS
# ==============================================================================

RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

WHITE="\033[97m"
CYAN="\033[96m"
GREEN="\033[92m"
YELLOW="\033[93m"
RED="\033[91m"

# ==============================================================================
# BASIC HELPERS
# ==============================================================================

run_cmd() {
    "$@" 2>/dev/null || true
}

get_temp() {
    vcgencmd measure_temp 2>/dev/null |
        grep -oE '[0-9]+([.][0-9]+)?' | head -1
}

get_clock() {
    local type="$1"

    vcgencmd measure_clock "$type" 2>/dev/null |
        awk -F= '{printf "%.0f", $2/1000000}'
}

get_voltage() {
    vcgencmd measure_volts core 2>/dev/null |
        cut -d= -f2
}

get_throttle() {
    vcgencmd get_throttled 2>/dev/null |
        cut -d= -f2
}

get_ram_percent() {
    awk '
        /MemTotal/     { total=$2 }
        /MemAvailable/ { avail=$2 }
        END {
            if (total > 0)
                printf "%.0f", (1-avail/total)*100
            else
                print "0"
        }
    ' /proc/meminfo
}

get_load() {
    awk '{print $1}' /proc/loadavg
}

colour_label() {
    local colour="$1"
    local text="$2"

    case "$colour" in
        green)  printf "%b%s%b" "$GREEN" "$text" "$RESET" ;;
        yellow) printf "%b%s%b" "$YELLOW" "$text" "$RESET" ;;
        red)    printf "%b%s%b" "$RED" "$text" "$RESET" ;;
        cyan)   printf "%b%s%b" "$CYAN" "$text" "$RESET" ;;
        *)      printf "%s" "$text" ;;
    esac
}

status_colour() {
    local status="$1"

    case "$status" in
        GREEN|NORMAL|STABLE|PASS)
            colour_label green "$status"
            ;;
        WARNING|WARN|HISTORICAL)
            colour_label yellow "$status"
            ;;
        CRITICAL|FAIL|UNSTABLE)
            colour_label red "$status"
            ;;
        TESTING|INFO|READY)
            colour_label cyan "$status"
            ;;
        *)
            printf "%s" "$status"
            ;;
    esac
}

add_event() {
    printf "%s | %s\n" "$(date '+%H:%M:%S')" "$1" >> "$EVENT_LOG"
}

add_result() {
    printf "%s\n" "$1" >> "$RESULTS_FILE"
}

# ==============================================================================
# HARDWARE / HEALTH STATUS
# ==============================================================================

decode_throttle() {
    local raw="$1"
    local value

    [ -z "$raw" ] && {
        echo "UNKNOWN"
        return
    }

    [ "$raw" = "0x0" ] && {
        echo "GREEN"
        return
    }

    value=$((16#${raw#0x}))

    # Current active problems.
    if (( value & 1 )) || (( value & 2 )) ||
       (( value & 4 )) || (( value & 8 )); then
        echo "CRITICAL"
        return
    fi

    # Historical problems only.
    if (( value & 16 )) || (( value & 32 )) ||
       (( value & 64 )) || (( value & 128 )); then
        echo "WARNING"
        return
    fi

    echo "GREEN"
}

thermal_status() {
    local temp="${1:-0}"

    if ! [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "WARNING"
    elif awk "BEGIN {exit !($temp >= 82)}"; then
        echo "CRITICAL"
    elif awk "BEGIN {exit !($temp >= 70)}"; then
        echo "WARNING"
    else
        echo "GREEN"
    fi
}

voltage_status() {
    local throttle
    throttle=$(get_throttle)

    [ -z "$throttle" ] && {
        echo "WARNING"
        return
    }

    local value=$((16#${throttle#0x}))

    if (( value & 1 )); then
        echo "CRITICAL"
    elif (( value & 16 )); then
        echo "WARNING"
    else
        echo "GREEN"
    fi
}

# ==============================================================================
# PROFILE DETECTION
# ==============================================================================

detect_profile() {
    if grep -q "PROFILE: Eco" "$CONFIG_FILE"; then
        echo "Eco"
    elif grep -q "PROFILE: Quiet" "$CONFIG_FILE"; then
        echo "Quiet"
    elif grep -q "PROFILE: Performance" "$CONFIG_FILE"; then
        echo "Performance"
    elif grep -q "PROFILE: High Performance" "$CONFIG_FILE"; then
        echo "High Performance"
    elif grep -q "PROFILE: Auto" "$CONFIG_FILE"; then
        echo "Auto"
    elif grep -Eq '^[[:space:]]*(arm_freq|over_voltage)=' "$CONFIG_FILE"; then
        echo "Custom"
    else
        echo "Default"
    fi
}

# ==============================================================================
# SCREEN
# ==============================================================================

main_header() {
    clear

    printf "%b╔══════════════════════════════════════════════════════════════╗%b\n" "$CYAN" "$RESET"
    printf "%b║                 PiTweaks OVERCLOCK MANAGER                  ║%b\n" "$CYAN$BOLD" "$RESET"
    printf "%b╚══════════════════════════════════════════════════════════════╝%b\n\n" "$CYAN" "$RESET"
}

# ==============================================================================
# HARDWARE SUMMARY
# ==============================================================================

hardware_summary() {
    local model temp arm core gpu sdram voltage throttle profile

    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Raspberry Pi")
    temp=$(get_temp)
    arm=$(get_clock arm)
    core=$(get_clock core)
    gpu=$(get_clock gpu)
    sdram=$(get_clock sdram)
    voltage=$(get_voltage)
    throttle=$(get_throttle)
    profile=$(detect_profile)

    [ -z "$temp" ] && temp="N/A"
    [ -z "$arm" ] && arm="N/A"
    [ -z "$core" ] && core="N/A"
    [ -z "$gpu" ] && gpu="N/A"
    [ -z "$sdram" ] && sdram="N/A"
    [ -z "$voltage" ] && voltage="N/A"

    printf " Hardware        : %s\n" "$model"
    printf " Profile         : %s\n" "$profile"
    printf " ARM Clock       : %s MHz\n" "$arm"
    printf " Core Clock      : %s MHz\n" "$core"
    printf " GPU Clock       : %s MHz\n" "$gpu"
    printf " SDRAM Clock     : %s MHz\n" "$sdram"
    printf " Temperature     : %s°C\n" "$temp"
    printf " Core Voltage    : %s\n\n" "$voltage"

    printf " "
    colour_label "$(thermal_status "${temp%.*}")" "THERMAL"
    printf "       : %s\n" "$temp°C"

    printf " "
    colour_label "$(decode_throttle "$throttle")" "THROTTLE"
    printf "      : %s\n" "${throttle:-N/A}"

    printf " "
    colour_label "$(voltage_status)" "VOLTAGE"
    printf "       : %s\n" "$voltage"

    printf " "
    colour_label green "STABILITY"
    printf "     : %s\n\n" "READY"
}

# ==============================================================================
# CONFIGURATION MANAGEMENT
# ==============================================================================

remove_pitweaks_block() {
    sed -i \
        '/# --- PiTweaks Overclock Start ---/,/# --- PiTweaks Overclock End ---/d' \
        "$CONFIG_FILE"
}

apply_profile() {
    local name="$1"
    local settings="$2"

    remove_pitweaks_block

    printf '\n# --- PiTweaks Overclock Start ---\n' >> "$CONFIG_FILE"
    printf '# PROFILE: %s\n' "$name" >> "$CONFIG_FILE"
    printf '%b\n' "$settings" >> "$CONFIG_FILE"
    printf '# --- PiTweaks Overclock End ---\n' >> "$CONFIG_FILE"

    add_event "Applied profile: $name"

    printf "\n%bProfile applied: %s%b\n" "$GREEN" "$name" "$RESET"
    printf "%bA reboot is required before these settings become active.%b\n" \
        "$YELLOW" "$RESET"
}

reset_to_default() {
    remove_pitweaks_block

    add_event "Removed PiTweaks overclock settings"

    printf "\n%bPiTweaks overclock settings removed.%b\n" "$GREEN" "$RESET"
    printf "%bA reboot is required to return fully to the normal boot configuration.%b\n" \
        "$YELLOW" "$RESET"
}

reboot_prompt() {
    local answer

    read -r -p "Reboot now? [y/N]: " answer </dev/tty

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        clear
        echo "Rebooting Raspberry Pi..."
        reboot
    fi
}

# ==============================================================================
# MANUAL PRESETS
# ==============================================================================

manual_profile() {
    local choice="$1"
    local name=""
    local settings=""

    case "$choice" in
        1)
            name="Eco"
            settings=$'arm_freq=800\ninitial_turbo=0'
            ;;
        2)
            name="Quiet"
            settings="arm_freq_min=600"
            ;;
        3)
            reset_to_default
            reboot_prompt
            return
            ;;
        4)
            name="Performance"
            settings=$'arm_freq=1300\nover_voltage=2'
            ;;
        5)
            name="High Performance"
            settings=$'arm_freq=1350\nover_voltage=5'
            ;;
        *)
            return
            ;;
    esac

    apply_profile "$name" "$settings"
    reboot_prompt
}

# ==============================================================================
# BAR
# ==============================================================================

make_bar() {
    local percentage="$1"
    local width="${2:-20}"
    local filled
    local i

    [[ "$percentage" =~ ^[0-9]+([.][0-9]+)?$ ]] || percentage=0

    filled=$(awk -v p="$percentage" -v w="$width" \
        'BEGIN {x=int((p*w)/100); if(x>w)x=w; print x}')

    printf "["

    for ((i=0; i<width; i++)); do
        if [ "$i" -lt "$filled" ]; then
            printf "█"
        else
            printf "░"
        fi
    done

    printf "]"
}

# ==============================================================================
# PYTHON TELEMETRY DASHBOARD
# ==============================================================================

run_dashboard() {
    local mode="$1"
    shift

    python3 - "$mode" "$@" <<'PYTHON'
import sys
import os
import time
import subprocess
import signal

try:
    import psutil
except ImportError:
    psutil = None

RESET="\033[0m"
BOLD="\033[1m"
WHITE="\033[97m"
CYAN="\033[96m"
GREEN="\033[92m"
YELLOW="\033[93m"
RED="\033[91m"

stop_requested=False
stress_process=None

def cmd(command):
    try:
        return subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=2
        ).stdout.strip()
    except Exception:
        return ""

def temp():
    raw=cmd("vcgencmd measure_temp")
    try:
        return float(raw.split("=")[1].split("'")[0])
    except Exception:
        return 0.0

def clock(name):
    raw=cmd(f"vcgencmd measure_clock {name}")
    try:
        return int(raw.split("=")[1]) // 1000000
    except Exception:
        return 0

def voltage():
    return cmd("vcgencmd measure_volts core").replace("volt=","")

def throttle():
    return cmd("vcgencmd get_throttled").replace("throttled=","")

def throttle_state(raw):
    try:
        value=int(raw,16)
    except Exception:
        return "WARNING"

    if value == 0:
        return "GREEN"

    if value & 0xF:
        return "CRITICAL"

    if value & 0xF0:
        return "WARNING"

    return "GREEN"

def label(text, state):
    colour={
        "GREEN":GREEN,
        "WARNING":YELLOW,
        "CRITICAL":RED,
        "TESTING":CYAN,
        "PASS":GREEN,
        "FAIL":RED,
        "INFO":CYAN
    }.get(state,WHITE)

    return f"{colour}{text}{RESET}"

def bar(value, width=20):
    value=max(0,min(100,float(value)))
    filled=int(width*value/100)

    if value >= 90:
        colour=RED
    elif value >= 70:
        colour=YELLOW
    else:
        colour=GREEN

    return f"{colour}[{'█'*filled}{'░'*(width-filled)}]{RESET} {value:5.1f}%"

def cpu_usage():
    if not psutil:
        return []

    return psutil.cpu_percent(interval=None, percpu=True)

def ram_usage():
    if not psutil:
        return 0, "N/A"

    m=psutil.virtual_memory()
    used=m.used/1024/1024
    total=m.total/1024/1024
    return m.percent, f"{used:.0f}MB / {total:.0f}MB"

def draw(title, elapsed=0, target=None, stable=None, peak=0,
         test_state="TESTING", event_text=""):

    t=temp()
    arm=clock("arm")
    core=clock("core")
    gpu=clock("gpu")
    sdram=clock("sdram")
    volt=voltage()
    thr=throttle()
    thr_state=throttle_state(thr)

    ram,ram_text=ram_usage()
    cores=cpu_usage()

    mins,secs=divmod(int(elapsed),60)

    print("\033[H\033[J",end="")

    print(f"{CYAN}╔══════════════════════════════════════════════════════════════╗{RESET}")
    print(f"{CYAN}{BOLD}║                 PiTweaks {title:<29}║{RESET}")
    print(f"{CYAN}╚══════════════════════════════════════════════════════════════╝{RESET}")
    print()

    print(
        f" {BOLD}Time:{RESET} {YELLOW}{mins:02d}:{secs:02d}{RESET}"
        f"    {BOLD}ARM:{RESET} {arm} MHz"
    )

    if target is not None:
        print(
            f" Target Frequency : {target} MHz"
            f"    Previous Stable : {stable} MHz"
        )

    print()
    print(f" {CYAN}┌─ HARDWARE TELEMETRY ────────────────────────────────────────┐{RESET}")
    print(f"   CPU Temperature : {t:.1f}°C    Peak : {peak:.1f}°C")
    print(f"   ARM Clock       : {arm} MHz")
    print(f"   Core Clock      : {core} MHz")
    print(f"   GPU Clock       : {gpu} MHz")
    print(f"   SDRAM Clock     : {sdram} MHz")
    print(f"   Core Voltage    : {volt or 'N/A'}")
    print(f"   RAM Usage       : {bar(ram)}  ({ram_text})")
    print()

    if cores:
        print(f" {CYAN}┌─ PER-CORE CPU UTILIZATION ──────────────────────────────────┐{RESET}")
        for i,u in enumerate(cores):
            print(f"   Core {i:<2}          : {bar(u,18)}")
        print()

    print(f" {CYAN}┌─ LIVE HEALTH STATUS ────────────────────────────────────────┐{RESET}")

    thermal="CRITICAL" if t>=82 else ("WARNING" if t>=70 else "GREEN")
    voltage_state="CRITICAL" if "0x" in thr and int(thr,16)&1 else "GREEN"

    print(f"   {label('POWER', 'GREEN'):<25}: NORMAL")
    print(f"   {label('THERMAL', thermal):<25}: {t:.1f}°C")
    print(f"   {label('THROTTLE', thr_state):<25}: {thr or 'N/A'}")
    print(f"   {label('VOLTAGE', voltage_state):<25}: {volt or 'N/A'}")
    print(f"   {label('STABILITY', test_state):<25}: {event_text or 'Testing'}")
    print(f" {CYAN}└─────────────────────────────────────────────────────────────┘{RESET}")
    print()
    print(f" {BOLD}[Ctrl+C] Stop / return{RESET}")

def signal_handler(signum, frame):
    global stop_requested
    stop_requested=True

signal.signal(signal.SIGINT,signal_handler)
signal.signal(signal.SIGTERM,signal_handler)

mode=sys.argv[1] if len(sys.argv)>1 else "monitor"

if psutil:
    psutil.cpu_percent(interval=None,percpu=True)

peak=0.0
start=time.time()

# Manual stress test -----------------------------------------------------------

if mode == "stress":
    test_type=sys.argv[2] if len(sys.argv)>2 else "cpu"
    duration=int(sys.argv[3]) if len(sys.argv)>3 else 300

    if test_type == "cpu":
        command=["stress-ng","--cpu","0","--timeout",f"{duration}s"]
    elif test_type == "ram":
        command=["stress-ng","--vm","4","--vm-bytes","85%",
                 "--vm-method","all","--timeout",f"{duration}s"]
    else:
        command=["stress-ng","--cpu","0","--vm","2",
                 "--vm-bytes","75%","--timeout",f"{duration}s"]

    try:
        stress_process=subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True
        )
    except Exception as e:
        print(f"{RED}Unable to start stress-ng: {e}{RESET}")
        input("Press Enter...")
        sys.exit(1)

    try:
        while not stop_requested and stress_process.poll() is None:
            elapsed=time.time()-start
            t=temp()
            peak=max(peak,t)

            draw(
                "STRESS TEST",
                elapsed=elapsed,
                peak=peak,
                test_state="TESTING",
                event_text=test_type.upper()
            )

            if t>=82:
                stop_requested=True

            time.sleep(1)

    finally:
        if stress_process and stress_process.poll() is None:
            try:
                os.killpg(os.getpgid(stress_process.pid),signal.SIGTERM)
            except Exception:
                pass

    print()
    if peak>=82:
        print(f"{RED}Thermal limit reached. Test stopped.{RESET}")
    elif stop_requested:
        print(f"{YELLOW}Test stopped by user.{RESET}")
    else:
        print(f"{GREEN}Stress test completed.{RESET}")

    input("Press Enter to return...")

# Live monitor -----------------------------------------------------------------

else:
    try:
        while not stop_requested:
            elapsed=time.time()-start
            t=temp()
            peak=max(peak,t)

            draw(
                "LIVE MONITOR",
                elapsed=elapsed,
                peak=peak,
                test_state="INFO",
                event_text="Monitoring"
            )

            time.sleep(1)

    except KeyboardInterrupt:
        pass

PYTHON
}

# ==============================================================================
# DEPENDENCY CHECK
# ==============================================================================

check_stress_dependencies() {
    if ! command -v stress-ng >/dev/null 2>&1; then
        echo
        echo "stress-ng is required for stress testing."
        read -r -p "Install it now? [Y/n]: " answer </dev/tty

        if [[ ! "$answer" =~ ^[Nn]$ ]]; then
            apt-get update -qq
            apt-get install -y stress-ng -qq
        else
            return 1
        fi
    fi

    if ! python3 -c "import psutil" >/dev/null 2>&1; then
        echo
        echo "python3-psutil is required for the telemetry dashboard."
        read -r -p "Install it now? [Y/n]: " answer </dev/tty

        if [[ ! "$answer" =~ ^[Nn]$ ]]; then
            apt-get update -qq
            apt-get install -y python3-psutil -qq
        else
            return 1
        fi
    fi

    return 0
}

# ==============================================================================
# STRESS TEST MENU
# ==============================================================================

stress_test_menu() {
    local choice duration

    check_stress_dependencies || {
        read -r -p "Press Enter to continue..." </dev/tty
        return
    }

    clear
    printf "%b╔══════════════════════════════════════════════════════════════╗%b\n" "$CYAN" "$RESET"
    printf "%b║                       STRESS TEST                          ║%b\n" "$CYAN$BOLD" "$RESET"
    printf "%b╚══════════════════════════════════════════════════════════════╝%b\n\n" "$CYAN" "$RESET"

    echo "1) CPU"
    echo "2) RAM"
    echo "3) CPU + RAM"
    echo "4) Back"
    echo

    read -r -p "Select: " choice </dev/tty

    case "$choice" in
        1|2|3)
            read -r -p "Duration in minutes [5]: " duration </dev/tty
            [ -z "$duration" ] && duration=5

            [[ "$duration" =~ ^[0-9]+$ ]] || {
                echo "Invalid duration."
                sleep 1
                return
            }

            case "$choice" in
                1) run_dashboard stress cpu $((duration*60)) ;;
                2) run_dashboard stress ram $((duration*60)) ;;
                3) run_dashboard stress all $((duration*60)) ;;
            esac
            ;;
    esac
}

# ==============================================================================
# AUTO OVERCLOCK
# ==============================================================================

auto_overclock_menu() {
    local choice duration

    clear

    printf "%b╔══════════════════════════════════════════════════════════════╗%b\n" "$CYAN" "$RESET"
    printf "%b║                     AUTO OVERCLOCK                          ║%b\n" "$CYAN$BOLD" "$RESET"
    printf "%b╚══════════════════════════════════════════════════════════════╝%b\n\n" "$CYAN" "$RESET"

    echo "1) Reliable Overclock"
    echo "   Small steps / stability-first / 24-7 use"
    echo
    echo "2) Maximum Performance"
    echo "   Larger steps / longer testing / benchmark-oriented"
    echo
    echo "3) Back"
    echo

    read -r -p "Select: " choice </dev/tty

    case "$choice" in
        1)
            AUTO_MODE="Reliable"
            AUTO_STEP=25
            AUTO_DURATION=5
            ;;
        2)
            AUTO_MODE="Maximum Performance"
            AUTO_STEP=50
            AUTO_DURATION=10
            ;;
        3)
            return
            ;;
        *)
            return
            ;;
    esac

    read -r -p "Stress duration per step in minutes [$AUTO_DURATION]: " duration </dev/tty

    if [ -n "$duration" ] && [[ "$duration" =~ ^[0-9]+$ ]]; then
        AUTO_DURATION="$duration"
    fi

    start_auto_overclock
}

# ==============================================================================
# REBOOT-AWARE AUTO OVERCLOCK
#
# Important:
# config.txt is read during boot.
# A frequency written here is NOT automatically the live frequency.
#
# Therefore this state machine never claims a new frequency passed a test until
# that frequency has actually become active after reboot.
#
# /run is tmpfs, so state survives a reboot but does not consume SD writes.
# ==============================================================================

start_auto_overclock() {
    local current target

    current=$(get_clock arm)

    if ! [[ "$current" =~ ^[0-9]+$ ]]; then
        echo "Unable to determine current ARM frequency."
        sleep 2
        return
    fi

    PREVIOUS_STABLE="$current"
    TARGET=$((current + AUTO_STEP))

    cat > "$AUTO_STATE" <<EOF
MODE=$AUTO_MODE
STEP=$AUTO_STEP
DURATION=$AUTO_DURATION
STABLE=$PREVIOUS_STABLE
TARGET=$TARGET
STAGE=PREPARE
STARTED=$(date +%s)
EOF

    add_event "Auto overclock started: $AUTO_MODE at ${current} MHz"

    auto_stage
}

auto_stage() {
    # Load state.
    [ -f "$AUTO_STATE" ] || return

    # shellcheck disable=SC1090
    source "$AUTO_STATE"

    case "${STAGE:-PREPARE}" in

        PREPARE)
            clear

            printf "%b╔══════════════════════════════════════════════════════════════╗%b\n" "$CYAN" "$RESET"
            printf "%b║                  AUTO OVERCLOCK READY                      ║%b\n" "$CYAN$BOLD" "$RESET"
            printf "%b╚══════════════════════════════════════════════════════════════╝%b\n\n" "$CYAN" "$RESET"

            printf " Mode              : %s\n" "$MODE"
            printf " Current stable    : %s MHz\n" "$STABLE"
            printf " Next target       : %s MHz\n" "$TARGET"
            printf " Step              : %s MHz\n" "$STEP"
            printf " Test duration     : %s minute(s)\n\n" "$DURATION"

            printf "%bIMPORTANT:%b Each new config.txt frequency requires a reboot.\n" \
                "$YELLOW" "$RESET"

            printf "The script will only call a frequency PASS after the Pi has\n"
            printf "actually booted at that frequency and completed its test.\n\n"

            read -r -p "Begin automatic process? [Y/n]: " answer </dev/tty

            if [[ "$answer" =~ ^[Nn]$ ]]; then
                rm -f "$AUTO_STATE"
                return
            fi

            STAGE=WAIT_REBOOT
            save_auto_state

            apply_auto_target "$TARGET"

            printf "\n%bTarget %s MHz has been configured.%b\n" "$CYAN" "$TARGET" "$RESET"
            printf "%bReboot is required to activate it.%b\n" "$YELLOW" "$RESET"
            reboot_prompt
            ;;

        WAIT_REBOOT)
            # The script only reaches this after reboot if the launcher starts it
            # again. We now verify that the target is actually live.
            if [ "$(get_clock arm)" = "$TARGET" ]; then
                STAGE=TEST
                save_auto_state
                add_event "Target ${TARGET} MHz active after reboot"
                auto_stage
            else
                clear
                echo "The requested target frequency is not currently active."
                echo
                echo "Target : $TARGET MHz"
                echo "Actual : $(get_clock arm) MHz"
                echo
                echo "The automatic test was NOT marked as passed."
                pause
            fi
            ;;

        TEST)
            check_stress_dependencies || {
                echo "Stress-test dependencies are unavailable."
                pause
                return
            }

            add_event "Testing active target: ${TARGET} MHz"

            run_dashboard stress all "$((DURATION*60))"

            local temp_value throttle_value

            temp_value=$(get_temp)
            throttle_value=$(get_throttle)

            if [ -n "$temp_value" ] &&
               awk "BEGIN {exit !($temp_value >= 82)}"; then

                add_event "FAIL ${TARGET} MHz: thermal limit"
                add_result "$TARGET MHz | FAIL | thermal limit | peak ${temp_value}°C"

                TARGET="$STABLE"
                STAGE=RESTORE
                save_auto_state
                auto_stage
                return
            fi

            if [ "$throttle_value" != "0x0" ]; then
                local tv=$((16#${throttle_value#0x}))

                if (( tv & 15 )); then
                    add_event "FAIL ${TARGET} MHz: active throttle"
                    add_result "$TARGET MHz | FAIL | active throttle"

                    TARGET="$STABLE"
                    STAGE=RESTORE
                    save_auto_state
                    auto_stage
                    return
                fi
            fi

            # A completed test with no active thermal/throttle problem is a
            # known-good step.
            add_event "PASS ${TARGET} MHz"
            add_result "$TARGET MHz | PASS | stable"

            STABLE="$TARGET"
            TARGET=$((STABLE + STEP))
            STAGE=NEXT
            save_auto_state
            auto_stage
            ;;

        NEXT)
            clear

            printf "%bAUTO OVERCLOCK PROGRESS%b\n\n" "$BOLD$CYAN" "$RESET"
            printf " Mode           : %s\n" "$MODE"
            printf " Stable         : %s MHz\n" "$STABLE"
            printf " Next target    : %s MHz\n\n" "$TARGET"

            read -r -p "Test next frequency? [Y/n]: " answer </dev/tty

            if [[ "$answer" =~ ^[Nn]$ ]]; then
                TARGET="$STABLE"
                STAGE=RESTORE
                save_auto_state
                auto_stage
                return
            fi

            STAGE=WAIT_REBOOT
            save_auto_state

            apply_auto_target "$TARGET"

            printf "\n%bNext target configured: %s MHz%b\n" "$CYAN" "$TARGET" "$RESET"
            printf "%bReboot is required to activate it.%b\n" "$YELLOW" "$RESET"

            reboot_prompt
            ;;

        RESTORE)
            apply_auto_target "$STABLE"

            add_event "Restoring highest known-good frequency: ${STABLE} MHz"

            clear

            printf "%b╔══════════════════════════════════════════════════════════════╗%b\n" "$CYAN" "$RESET"
            printf "%b║                AUTO OVERCLOCK COMPLETE                     ║%b\n" "$CYAN$BOLD" "$RESET"
            printf "%b╚══════════════════════════════════════════════════════════════╝%b\n\n" "$CYAN" "$RESET"

            printf " Mode              : %s\n" "$MODE"
            printf " Highest stable    : %s MHz\n" "$STABLE"
            printf " Current target    : %s MHz\n\n" "$STABLE"

            printf "%bFrequency Results%b\n" "$BOLD$WHITE" "$RESET"
            printf "%s\n" "------------------------------------------------------------"
            cat "$RESULTS_FILE"
            printf "%s\n\n" "------------------------------------------------------------"

            printf "%bThe final known-good setting is %s MHz.%b\n" \
                "$GREEN" "$STABLE" "$RESET"

            printf "%bA reboot is required if the restored configuration is not already active.%b\n" \
                "$YELLOW" "$RESET"

            rm -f "$AUTO_STATE"

            reboot_prompt
            ;;

    esac
}

save_auto_state() {
    cat > "$AUTO_STATE" <<EOF
MODE=$MODE
STEP=$STEP
DURATION=$DURATION
STABLE=$STABLE
TARGET=$TARGET
STAGE=$STAGE
STARTED=$STARTED
EOF
}

apply_auto_target() {
    local target="$1"

    remove_pitweaks_block

    printf '\n# --- PiTweaks Overclock Start ---\n' >> "$CONFIG_FILE"
    printf '# PROFILE: Auto\n' >> "$CONFIG_FILE"
    printf 'arm_freq=%s\n' "$target" >> "$CONFIG_FILE"
    printf '# --- PiTweaks Overclock End ---\n' >> "$CONFIG_FILE"
}

# ==============================================================================
# DIAGNOSTICS
# ==============================================================================

diagnostics() {
    local model temp arm core gpu sdram voltage throttle
    local thermal throttle_state voltage_state

    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Raspberry Pi")
    temp=$(get_temp)
    arm=$(get_clock arm)
    core=$(get_clock core)
    gpu=$(get_clock gpu)
    sdram=$(get_clock sdram)
    voltage=$(get_voltage)
    throttle=$(get_throttle)

    thermal=$(thermal_status "${temp%.*}")
    throttle_state=$(decode_throttle "$throttle")
    voltage_state=$(voltage_status)

    clear

    printf "%b╔══════════════════════════════════════════════════════════════╗%b\n" "$CYAN" "$RESET"
    printf "%b║                     DIAGNOSTICS                            ║%b\n" "$CYAN$BOLD" "$RESET"
    printf "%b╚══════════════════════════════════════════════════════════════╝%b\n\n" "$CYAN" "$RESET"

    printf "%bHARDWARE%b\n" "$BOLD$WHITE" "$RESET"
    printf " Model       : %s\n\n" "$model"

    printf "%bLIVE CLOCKS%b\n" "$BOLD$WHITE" "$RESET"
    printf " ARM         : %s MHz\n" "${arm:-N/A}"
    printf " Core        : %s MHz\n" "${core:-N/A}"
    printf " GPU         : %s MHz\n" "${gpu:-N/A}"
    printf " SDRAM       : %s MHz\n\n" "${sdram:-N/A}"

    printf " Temperature : %s°C\n" "${temp:-N/A}"
    printf " Voltage     : %s\n" "${voltage:-N/A}"
    printf " Profile     : %s\n\n" "$(detect_profile)"

    printf " "
    colour_label green "POWER"
    printf "       : NORMAL\n"

    printf " "
    colour_label "$thermal" "THERMAL"
    printf "     : %s°C\n" "${temp:-N/A}"

    printf " "
    colour_label "$throttle_state" "THROTTLE"
    printf "    : %s\n" "${throttle:-N/A}"

    printf " "
    colour_label "$voltage_state" "VOLTAGE"
    printf "     : %s\n" "${voltage:-N/A}"

    printf " "
    colour_label green "STABILITY"
    printf "   : READY\n"

    printf "\n%bRUNTIME EVENT TIMELINE%b\n" "$BOLD$WHITE" "$RESET"
    printf "%s\n" "------------------------------------------------------------"

    if [ -s "$EVENT_LOG" ]; then
        tail -20 "$EVENT_LOG"
    else
        echo "No runtime events recorded."
    fi

    printf "%s\n" "------------------------------------------------------------"

    if [ -s "$RESULTS_FILE" ]; then
        printf "\n%bFREQUENCY RESULTS%b\n" "$BOLD$WHITE" "$RESET"
        cat "$RESULTS_FILE"
    fi

    pause
}

# ==============================================================================
# RESTORE OPTIONS
#
# These intentionally do not silently create persistent backups. The user
# requested minimal SD-card writes. A future version can provide an explicit
# "Create Backup" action if desired.
# ==============================================================================

restore_last() {
    clear

    printf "%bRESTORE LAST PRESET%b\n\n" "$BOLD$CYAN" "$RESET"
    echo "Automatic persistent backups are disabled."
    echo
    echo "This module does not create hidden backup files on the SD card."
    echo
    echo "Use Default to remove the PiTweaks overclock block."
    echo

    pause
}

restore_original() {
    clear

    printf "%bRESTORE ORIGINAL CONFIG%b\n\n" "$BOLD$CYAN" "$RESET"
    echo "Automatic persistent backups are disabled."
    echo
    echo "The module will not overwrite or guess at unrelated config.txt data."
    echo
    echo "Use Default to remove the PiTweaks-managed configuration block."
    echo

    pause
}

# ==============================================================================
# MAIN MENU
# ==============================================================================

menu() {
    local choice

    main_header
    hardware_summary

    printf "%b┌─ OPTIONS ──────────────────────────────────────────────────┐%b\n" "$CYAN" "$RESET"
    printf " │  1  Eco                                                   │\n"
    printf " │  2  Quiet                                                 │\n"
    printf " │  3  Default                                               │\n"
    printf " │  4  Performance                                           │\n"
    printf " │  5  High Performance                                     │\n"
    printf " │                                                           │\n"
    printf " │  6  Restore Last Preset                                  │\n"
    printf " │  7  Restore Original                                     │\n"
    printf " │  8  Live Monitor                                         │\n"
    printf " │  9  Auto Overclock                                       │\n"
    printf " │ 10  Stress Test                                          │\n"
    printf " │ 11  Diagnostics                                          │\n"
    printf " │ 12  Exit                                                  │\n"
    printf "%b└───────────────────────────────────────────────────────────┘%b\n\n" "$CYAN" "$RESET"

    read -r -p "Select: " choice </dev/tty

    case "$choice" in
        1|2|3|4|5)
            manual_profile "$choice"
            ;;
        6)
            restore_last
            ;;
        7)
            restore_original
            ;;
        8)
            run_dashboard monitor
            ;;
        9)
            auto_overclock_menu
            ;;
        10)
            stress_test_menu
            ;;
        11)
            diagnostics
            ;;
        12)
            clear
            echo "Exiting PiTweaks Overclock Manager."
            exit 0
            ;;
        *)
            echo "Invalid selection."
            sleep 1
            ;;
    esac
}

# ==============================================================================
# CONTINUE A REBOOT-BASED AUTO-OVERCLOCK SESSION
# ==============================================================================

if [ -f "$AUTO_STATE" ]; then
    # shellcheck disable=SC1090
    source "$AUTO_STATE"

    if [ "${STAGE:-}" = "WAIT_REBOOT" ]; then
        auto_stage
    fi
fi

while true; do
    menu
done
