bash
#!/bin/bash
# ==============================================================================
# Description: Raspberry Pi overclocking, stress testing and live diagnostics, V2.2.
# PERSISTENT: TRUE
# Category: Tools
#
# Runtime data: RAM only.
# No logs, state files or backups are created.
# config.txt is only modified when the user explicitly applies a setting.
# ==============================================================================

set -u

# ------------------------------------------------------------------------------
# ROOT / CONFIG
# ------------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo."
    exit 1
fi

CONFIG="/boot/firmware/config.txt"
[ -f "$CONFIG" ] || CONFIG="/boot/config.txt"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: config.txt not found."
    exit 1
fi

# ------------------------------------------------------------------------------
# COLOURS
# ------------------------------------------------------------------------------

if [ -t 1 ]; then
    R='\033[1;31m'
    G='\033[1;32m'
    Y='\033[1;33m'
    C='\033[1;36m'
    W='\033[1;37m'
    X='\033[0m'
else
    R=''; G=''; Y=''; C=''; W=''; X=''
fi

# ------------------------------------------------------------------------------
# HARDWARE
# ------------------------------------------------------------------------------

MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Raspberry Pi")
CORES=$(nproc 2>/dev/null || echo 1)

case "$MODEL" in
    *"Raspberry Pi 3 Model B Plus"*) FAMILY="Pi 3B+" ;;
    *"Raspberry Pi 3 Model B"*)      FAMILY="Pi 3B" ;;
    *"Raspberry Pi 4"*)              FAMILY="Pi 4" ;;
    *"Raspberry Pi 5"*)              FAMILY="Pi 5" ;;
    *)                               FAMILY="Other" ;;
esac

# ------------------------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------------------------

have() {
    command -v "$1" >/dev/null 2>&1
}

pause() {
    echo
    read -r -p "Press Enter to continue..." </dev/tty
}

temp() {
    local t
    if have vcgencmd; then
        t=$(vcgencmd measure_temp 2>/dev/null |
            grep -oE '[0-9]+([.][0-9]+)?' | head -1)
        [ -n "${t:-}" ] && echo "$t" && return
    fi

    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        awk '{printf "%.1f", $1/1000}' \
            /sys/class/thermal/thermal_zone0/temp
    else
        echo "N/A"
    fi
}

clock() {
    if have vcgencmd; then
        vcgencmd measure_clock "$1" 2>/dev/null |
            awk -F= 'NF==2 {printf "%.0f", $2/1000000; ok=1}
                     END {if(!ok) print "N/A"}'
    else
        echo "N/A"
    fi
}

voltage() {
    if have vcgencmd; then
        vcgencmd measure_volts core 2>/dev/null |
            cut -d= -f2
    else
        echo "N/A"
    fi
}

load() {
    awk '{print $1,$2,$3}' /proc/loadavg
}

ram() {
    awk '
    /MemTotal:/ {t=$2}
    /MemAvailable:/ {a=$2}
    END {
        if(t>0) {
            u=t-a
            printf "%d %d %.0f",u/1024,t/1024,u/t*100
        } else print "N/A N/A N/A"
    }' /proc/meminfo
}

bar() {
    local v="${1:-0}" w="${2:-20}" f e i
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    ((v<0)) && v=0
    ((v>100)) && v=100
    f=$((v*w/100))
    e=$((w-f))
    printf '['
    for ((i=0;i<f;i++)); do printf '█'; done
    for ((i=0;i<e;i++)); do printf '░'; done
    printf ']'
}

# ------------------------------------------------------------------------------
# CPU USAGE
# ------------------------------------------------------------------------------

cpu_usage() {
    local -a bi bt ai at
    local cpu user nice sys idle io irq soft steal i total

    while read -r cpu user nice sys idle io irq soft steal _; do
        [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue
        i=${cpu#cpu}
        bi[$i]=$((idle+io))
        bt[$i]=$((user+nice+sys+idle+io+irq+soft+steal))
    done < /proc/stat

    sleep 0.2

    while read -r cpu user nice sys idle io irq soft steal _; do
        [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue
        i=${cpu#cpu}
        ai[$i]=$((idle+io))
        at[$i]=$((user+nice+sys+idle+io+irq+soft+steal))
    done < /proc/stat

    for ((i=0;i<CORES;i++)); do
        total=$((at[i]-bt[i]))
        if ((total>0)); then
            printf "%d " $(( (total-(ai[i]-bi[i]))*100/total ))
        else
            printf "0 "
        fi
    done
}

# ------------------------------------------------------------------------------
# THROTTLE
# ------------------------------------------------------------------------------

THROTTLE="0x0"
THROTTLE_DEC=0

read_throttle() {
    if have vcgencmd; then
        THROTTLE=$(vcgencmd get_throttled 2>/dev/null |
            cut -d= -f2)
    else
        THROTTLE="N/A"
    fi

    if [[ "$THROTTLE" =~ ^0x[0-9a-fA-F]+$ ]]; then
        THROTTLE_DEC=$((THROTTLE))
    else
        THROTTLE_DEC=0
    fi
}

bit() {
    (( THROTTLE_DEC & (1 << $1) ))
}

status() {
    local current="$1" history="$2"

    if bit "$current"; then
        printf "${R}● RED${X}"
    elif bit "$history"; then
        printf "${Y}● YELLOW${X}"
    else
        printf "${G}● GREEN${X}"
    fi
}

# ------------------------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------------------------

profile() {
    if grep -q '^# PROFILE: Eco$' "$CONFIG"; then
        echo "Eco"
    elif grep -q '^# PROFILE: Quiet$' "$CONFIG"; then
        echo "Quiet"
    elif grep -q '^# PROFILE: Default$' "$CONFIG"; then
        echo "Default"
    elif grep -q '^# PROFILE: Performance$' "$CONFIG"; then
        echo "Performance"
    elif grep -q '^# PROFILE: High Performance$' "$CONFIG"; then
        echo "High Performance"
    elif grep -q '^# PROFILE: AUTO' "$CONFIG"; then
        echo "Auto Overclock"
    elif grep -q '^arm_freq=' "$CONFIG"; then
        echo "Custom"
    else
        echo "Factory Stock"
    fi
}

config_value() {
    grep -E "^$1=" "$CONFIG" 2>/dev/null |
        tail -1 | cut -d= -f2
}

target_freq() {
    local f
    f=$(config_value arm_freq)

    if [[ "$f" =~ ^[0-9]+$ ]]; then
        echo "$f"
        return
    fi

    case "$FAMILY" in
        "Pi 3B")  echo 1200 ;;
        "Pi 3B+") echo 1400 ;;
        "Pi 4")   echo 1500 ;;
        "Pi 5")   echo 2400 ;;
        *)        echo 0 ;;
    esac
}

# ------------------------------------------------------------------------------
# PI 3 / 4 / 5 LIMITS
# These are search boundaries, NOT guarantees of safety.
# ------------------------------------------------------------------------------

case "$FAMILY" in
    "Pi 3B")
        BASE=1200
        REL_START=1250
        REL_STEP=25
        REL_MAX=1400
        MAX_START=1250
        MAX_STEP=50
        MAX_MAX=1500
        HARD_TEMP=82
        ;;
    "Pi 3B+")
        BASE=1400
        REL_START=1450
        REL_STEP=25
        REL_MAX=1550
        MAX_START=1450
        MAX_STEP=50
        MAX_MAX=1600
        HARD_TEMP=82
        ;;
    "Pi 4")
        BASE=1500
        REL_START=1550
        REL_STEP=25
        REL_MAX=1900
        MAX_START=1550
        MAX_STEP=50
        MAX_MAX=2000
        HARD_TEMP=82
        ;;
    "Pi 5")
        BASE=2400
        REL_START=2450
        REL_STEP=25
        REL_MAX=2800
        MAX_START=2450
        MAX_STEP=50
        MAX_MAX=3000
        HARD_TEMP=85
        ;;
    *)
        BASE=0
        REL_START=0
        REL_STEP=25
        REL_MAX=0
        MAX_START=0
        MAX_STEP=50
        MAX_MAX=0
        HARD_TEMP=80
        ;;
esac

# ------------------------------------------------------------------------------
# WRITE ONLY WHEN USER EXPLICITLY CHANGES CONFIG
# No backup/state/log files are created.
# ------------------------------------------------------------------------------

write_profile() {
    local name="$1"
    local body="$2"
    local tmp

    tmp=$(mktemp)

    sed \
        '/^# --- PiTweaks Overclock Start ---$/,/^# --- PiTweaks Overclock End ---$/d' \
        "$CONFIG" > "$tmp"

    {
        printf '\n# --- PiTweaks Overclock Start ---\n'
        printf '# PROFILE: %s\n' "$name"
        printf '%b\n' "$body"
        printf '# --- PiTweaks Overclock End ---\n'
    } >> "$tmp"

    cp "$tmp" "$CONFIG"
    rm -f "$tmp"

    echo
    echo "${G}Configuration applied: $name${X}"
    echo "${Y}A reboot is required.${X}"
}

remove_profile() {
    local tmp
    tmp=$(mktemp)

    sed \
        '/^# --- PiTweaks Overclock Start ---$/,/^# --- PiTweaks Overclock End ---$/d' \
        "$CONFIG" > "$tmp"

    cp "$tmp" "$CONFIG"
    rm -f "$tmp"

    echo
    echo "${G}PiTweaks overclock settings removed.${X}"
    echo "${Y}Reboot required to return to normal firmware settings.${X}"
}

reboot_prompt() {
    local a
    read -r -p "Reboot now? [y/N]: " a </dev/tty
    [[ "$a" =~ ^[Yy]$ ]] && reboot
}

# ------------------------------------------------------------------------------
# STATUS STRIP
# ------------------------------------------------------------------------------

status_strip() {
    read_throttle

    local t
    t=$(temp)

    printf "POWER     "
    status 0 16
    echo

    printf "THERMAL   "
    status 3 19
    echo

    printf "THROTTLE  "
    status 2 18
    echo

    printf "VOLTAGE   "
    status 0 16
    echo

    if bit 0 || bit 1 || bit 2 || bit 3; then
        printf "STABILITY ${R}● RED${X}\n"
    elif bit 16 || bit 17 || bit 18 || bit 19; then
        printf "STABILITY ${Y}● YELLOW${X}\n"
    elif [[ "$t" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
         awk "BEGIN{exit !($t >= $HARD_TEMP)}"; then
        printf "STABILITY ${R}● RED${X}\n"
    else
        printf "STABILITY ${G}● GREEN${X}\n"
    fi
}

# ------------------------------------------------------------------------------
# LIVE MONITOR
# ------------------------------------------------------------------------------

monitor() {
    trap 'trap - INT; return' INT

    while true; do
        clear

        local t a c s v u total pct l1 l5 l15

        t=$(temp)
        a=$(clock arm)
        c=$(clock core)
        s=$(clock sdram)
        v=$(voltage)

        read -r u total pct <<< "$(ram)"
        read -r l1 l5 l15 <<< "$(load)"

        echo "${C}╔══════════════════════════════════════════════════════╗${X}"
        echo "${C}║              PiTweaks LIVE MONITOR                 ║${X}"
        echo "${C}╠══════════════════════════════════════════════════════╣${X}"
        printf "║ Hardware : %-43s ║\n" "$FAMILY"
        printf "║ Profile  : %-43s ║\n" "$(profile)"
        echo "${C}╠══════════════════════════════════════════════════════╣${X}"
        printf "║ ARM      : %6s MHz                              ║\n" "$a"
        printf "║ CORE     : %6s MHz                              ║\n" "$c"
        printf "║ SDRAM    : %6s MHz                              ║\n" "$s"
        printf "║ Voltage  : %-43s ║\n" "$v"
        printf "║ Temp     : %6s°C  " "$t"
        if [[ "$t" =~ ^[0-9] ]]; then
            bar "$(( ${t%.*} * 100 / 85 ))" 16
        else
            bar 0 16
        fi
        echo " ║"
        printf "║ RAM      : %4s / %4s MB  " "$u" "$total"
        bar "$pct" 16
        echo " ║"
        printf "║ Load     : %-43s ║\n" "$l1 / $l5 / $l15"
        echo "${C}╠══════════════════════════════════════════════════════╣${X}"
        status_strip
        echo "${C}╠══════════════════════════════════════════════════════╣${X}"
        echo "║ Ctrl+C = return                                      ║"
        echo "${C}╚══════════════════════════════════════════════════════╝${X}"

        sleep 1
    done

    trap - INT
}

# ------------------------------------------------------------------------------
# STRESS-NG
# ------------------------------------------------------------------------------

ensure_stress() {
    if have stress-ng; then
        return 0
    fi

    echo "stress-ng is not installed."
    read -r -p "Install it now? [Y/n]: " a </dev/tty

    [[ "$a" =~ ^[Nn]$ ]] && return 1

    apt-get update || return 1
    apt-get install -y stress-ng || return 1

    have stress-ng
}

# ------------------------------------------------------------------------------
# STRESS TEST
# ------------------------------------------------------------------------------

stress_test() {
    ensure_stress || {
        echo "stress-ng unavailable."
        pause
        return
    }

    clear

    echo "${C}PiTweaks Stress Test${X}"
    echo
    echo "1) CPU"
    echo "2) RAM"
    echo "3) CPU + RAM"
    echo "4) Return"
    echo

    local c mode duration choice

    read -r -p "Workload [1-4]: " c </dev/tty

    case "$c" in
        1) mode="CPU" ;;
        2) mode="RAM" ;;
        3) mode="COMBINED" ;;
        4) return ;;
        *) return ;;
    esac

    echo
    echo "1) 2 minutes"
    echo "2) 5 minutes"
    echo "3) 10 minutes"
    echo "4) 30 minutes"
    echo "5) Custom"
    echo

    read -r -p "Duration [1-5]: " c </dev/tty

    case "$c" in
        1) duration=120 ;;
        2) duration=300 ;;
        3) duration=600 ;;
        4) duration=1800 ;;
        5)
            read -r -p "Seconds: " duration </dev/tty
            [[ "$duration" =~ ^[0-9]+$ ]] || return
            ((duration<10)) && return
            ;;
        *) return ;;
    esac

    run_stress "$mode" "$duration"
}

run_stress() {
    local mode="$1" duration="$2"
    local pid start now elapsed remain
    local t peak=0 a c s v u total pct l1 l5 l15
    local cpus avg failure=""

    case "$mode" in
        CPU)
            stress-ng --cpu 0 --timeout "${duration}s" >/dev/null 2>&1 &
            ;;
        RAM)
            stress-ng --vm 2 --vm-bytes 70% --timeout "${duration}s" >/dev/null 2>&1 &
            ;;
        COMBINED)
            stress-ng --cpu 0 --vm 2 --vm-bytes 70% \
                --timeout "${duration}s" >/dev/null 2>&1 &
            ;;
    esac

    pid=$!
    start=$(date +%s)

    cleanup() {
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    }

    trap cleanup INT TERM

    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$((now-start))
        remain=$((duration-elapsed))
        ((remain<0)) && remain=0

        t=$(temp)
        a=$(clock arm)
        c=$(clock core)
        s=$(clock sdram)
        v=$(voltage)

        read -r u total pct <<< "$(ram)"
        read -r l1 l5 l15 <<< "$(load)"
        cpus=$(cpu_usage)

        if [[ "$t" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            awk "BEGIN{exit !($t>$peak)}" && peak="$t"

            if awk "BEGIN{exit !($t>=$HARD_TEMP)}"; then
                failure="Hard temperature limit reached"
            fi
        fi

        read_throttle

        if bit 0; then
            failure="Under-voltage detected"
        elif bit 2; then
            failure="CPU throttling detected"
        elif bit 3; then
            failure="Thermal throttling detected"
        fi

        avg=$(awk '{
            s=0;n=0
            for(i=1;i<=NF;i++)
                if($i~/^[0-9]+$/){s+=$i;n++}
        } END{
            if(n) printf "%.0f",s/n; else print 0
        }' <<< "$cpus")

        clear

        echo "${C}╔══════════════════════════════════════════════════════╗${X}"
        echo "${C}║              PiTweaks STRESS TEST                  ║${X}"
        echo "${C}╠══════════════════════════════════════════════════════╣${X}"
        printf "║ Mode       : %-39s ║\n" "$mode"
        printf "║ Time       : %4ss / %4ss                         ║\n" "$elapsed" "$duration"
        printf "║ Remaining  : %4ss                                ║\n" "$remain"
        echo "${C}╠══════════════════════════════════════════════════════╣${X}"
        echo "║ CPU USAGE                                             ║"

        local i=0
        for x in $cpus; do
            printf "║ Core %-2s    %3s%% " "$i" "$x"
            bar "$x" 16
            echo " ║"
            i=$((i+1))
        done

        printf "║ Average    %3s%%                                  ║\n" "$avg"
        printf "║ Load       %-39s ║\n" "$l1 / $l5 / $l15"

        echo "${C}╠══════════════════════════════════════════════════════╣${X}"
        printf "║ ARM        : %6s MHz                              ║\n" "$a"
        printf "║ CORE       : %6s MHz                              ║\n" "$c"
        printf "║ SDRAM      : %6s MHz                              ║\n" "$s"
        printf "║ Voltage    : %-39s ║\n" "$v"
        printf "║ Temp       : %6s°C  " "$t"
        if [[ "$t" =~ ^[0-9] ]]; then
            bar "$(( ${t%.*} * 100 / 85 ))" 16
        else
            bar 0 16
        fi
        echo " ║"
        printf "║ Peak       : %6s°C                              ║\n" "$peak"
        printf "║ RAM        : %4s / %4s MB  " "$u" "$total"
        bar "$pct" 16
        echo " ║"

        echo "${C}╠══════════════════════════════════════════════════════╣${X}"
        status_strip

        if [ -n "$failure" ]; then
            echo "${C}╠══════════════════════════════════════════════════════╣${X}"
            printf "║ ${R}FAIL: %-46s${X} ║\n" "$failure"
        fi

        echo "${C}╚══════════════════════════════════════════════════════╝${X}"

        [ -n "$failure" ] && break
        ((remain<=0)) && break

        sleep 1
    done

    cleanup
    trap - INT TERM

    echo
    echo "${G}Stress test complete.${X}"
    echo "Mode             : $mode"
    echo "Duration         : ${elapsed:-0}s"
    echo "Peak temperature : ${peak}°C"

    if [ -n "$failure" ]; then
        echo "Result           : ${R}FAIL${X}"
        echo "Reason           : $failure"
    else
        echo "Result           : ${G}PASS${X}"
    fi

    pause
}

# ------------------------------------------------------------------------------
# AUTO OVERCLOCK
#
# No persistent state is stored.
# The current arm_freq in config.txt determines the current test point.
# ------------------------------------------------------------------------------

auto_overclock() {
    [ "$FAMILY" = "Other" ] && {
        echo "Unsupported Raspberry Pi."
        pause
        return
    }

    clear

    echo "${C}PiTweaks Automatic Overclock${X}"
    echo
    echo "1) Reliable Overclock"
    echo "   25 MHz steps, stability-first"
    echo
    echo "2) Maximum Performance"
    echo "   Larger steps, benchmark-oriented"
    echo
    echo "3) Return"
    echo

    local choice mode step limit start current next temp

    read -r -p "Mode [1-3]: " choice </dev/tty

    case "$choice" in
        1)
            mode="RELIABLE"
            step="$REL_STEP"
            limit="$REL_MAX"
            start="$REL_START"
            ;;
        2)
            mode="MAXIMUM"
            step="$MAX_STEP"
            limit="$MAX_MAX"
            start="$MAX_START"
            ;;
        3) return ;;
        *) return ;;
    esac

    current=$(target_freq)

    temp=$(temp)

    if [[ "$temp" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
       awk "BEGIN{exit !($temp>=65)}"; then
        echo
        echo "${Y}Temperature is already ${temp}°C.${X}"
        echo "Cool the Pi before automatic overclocking."
        pause
        return
    fi

    read_throttle

    if bit 0 || bit 2 || bit 3; then
        echo
        echo "${R}Active power/thermal throttling detected.${X}"
        pause
        return
    fi

    next="$start"

    # If already above starting point, test the next step.
    if ((current>=next)); then
        next=$((current+step))
    fi

    if ((next>limit)); then
        echo "Current frequency is already at the selected limit."
        pause
        return
    fi

    clear

    echo "${C}AUTO OVERCLOCK${X}"
    echo
    echo "Hardware       : $FAMILY"
    echo "Mode           : $mode"
    echo "Current target : ${current} MHz"
    echo "Next target    : ${next} MHz"
    echo "Maximum        : ${limit} MHz"
    echo "Step           : ${step} MHz"
    echo
    echo "${Y}Each frequency change requires a reboot.${X}"
    echo "No automatic state or log files will be created."
    echo
    echo "After reboot, launch PiTweaks again."
    echo "The current config frequency will be detected automatically."
    echo

    read -r -p "Apply ${next} MHz? [y/N]: " choice </dev/tty
    [[ "$choice" =~ ^[Yy]$ ]] || return

    local settings

    case "$FAMILY" in
        "Pi 3B"|"Pi 3B+")
            settings="arm_freq=$next
core_freq=400"
            ;;
        "Pi 4")
            settings="arm_freq=$next
core_freq=500"
            ;;
        "Pi 5")
            settings="arm_freq=$next"
            ;;
    esac

    write_profile "AUTO $mode $next MHz" "$settings"

    echo
    echo "Reboot and run PiTweaks again."
    echo
    echo "If ${next} MHz is stable, choose Auto Overclock again."
    echo "The next frequency will automatically be:"
    echo "${next} + ${step} = $((next+step)) MHz"
    echo
    echo "If ${next} MHz is unstable, select High Performance/Default"
    echo "or manually restore the previous known-good frequency."
    reboot_prompt
}

# ------------------------------------------------------------------------------
# PRESET MENU
# ------------------------------------------------------------------------------

menu() {
    clear

    echo "${C}╔══════════════════════════════════════════════════════╗${X}"
    echo "${C}║             PiTweaks OVERCLOCK MANAGER             ║${X}"
    echo "${C}╚══════════════════════════════════════════════════════╝${X}"
    echo
    echo "Hardware     : $FAMILY"
    echo "Temperature  : $(temp)°C"
    echo "ARM clock    : $(clock arm) MHz"
    echo "Target       : $(target_freq) MHz"
    echo "Profile      : $(profile)"
    echo
    echo "1) Eco"
    echo "2) Quiet"
    echo "3) Default"
    echo "4) Performance"
    echo "5) High Performance"
    echo
    echo "6) Restore Last Preset"
    echo "7) Restore Original Factory Config"
    echo "8) Live Monitor"
    echo "9) Auto Overclock"
    echo "10) Stress Test"
    echo "11) Diagnostics"
    echo "12) Exit"
    echo

    local c settings

    read -r -p "Selection [1-12]: " c </dev/tty

    case "$c" in

        1)
            write_profile "Eco" \
                "arm_freq=800
initial_turbo=0"
            reboot_prompt
            ;;

        2)
            write_profile "Quiet" \
                "arm_freq_min=600"
            reboot_prompt
            ;;

        3)
            remove_profile
            reboot_prompt
            ;;

        4)
            case "$FAMILY" in
                "Pi 3B")
                    settings="arm_freq=1300
core_freq=400
over_voltage=2"
                    ;;
                "Pi 3B+")
                    settings="arm_freq=1450
core_freq=400
over_voltage=2"
                    ;;
                "Pi 4")
                    settings="arm_freq=1800
core_freq=500"
                    ;;
                "Pi 5")
                    settings="arm_freq=2600"
                    ;;
                *)
                    echo "Unsupported hardware."
                    pause
                    return
                    ;;
            esac

            write_profile "Performance" "$settings"
            reboot_prompt
            ;;

        5)
            case "$FAMILY" in
                "Pi 3B")
                    settings="arm_freq=1350
core_freq=400
over_voltage=4"
                    ;;
                "Pi 3B+")
                    settings="arm_freq=1500
core_freq=500
over_voltage=4"
                    ;;
                "Pi 4")
                    settings="arm_freq=2000
core_freq=500
over_voltage=6"
                    ;;
                "Pi 5")
                    settings="arm_freq=2800"
                    ;;
                *)
                    echo "Unsupported hardware."
                    pause
                    return
                    ;;
            esac

            write_profile "High Performance" "$settings"
            reboot_prompt
            ;;

        6)
            echo
            echo "No persistent backup is maintained by this version."
            echo "This option intentionally performs no SD-card write."
            echo
            echo "Use Default to remove the PiTweaks overclock block."
            pause
            ;;

        7)
            echo
            echo "No factory backup is maintained by this version."
            echo "This option intentionally performs no SD-card write."
            echo
            echo "Use Default to remove the PiTweaks overclock block."
            pause
            ;;

        8)
            monitor
            ;;

        9)
            auto_overclock
            ;;

        10)
            stress_test
            ;;

        11)
            diagnostics
            ;;

        12)
            clear
            exit 0
            ;;

        *)
            echo "Invalid selection."
            sleep 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# DIAGNOSTICS
# ------------------------------------------------------------------------------

diagnostics() {
    clear

    local t a c s v u total pct l1 l5 l15

    t=$(temp)
    a=$(clock arm)
    c=$(clock core)
    s=$(clock sdram)
    v=$(voltage)

    read -r u total pct <<< "$(ram)"
    read -r l1 l5 l15 <<< "$(load)"

    read_throttle

    echo "${C}╔══════════════════════════════════════════════════════╗${X}"
    echo "${C}║                 PiTweaks DIAGNOSTICS               ║${X}"
    echo "${C}╠══════════════════════════════════════════════════════╣${X}"
    printf "║ Model       : %-39s ║\n" "$MODEL"
    printf "║ Family      : %-39s ║\n" "$FAMILY"
    printf "║ Cores       : %-39s ║\n" "$CORES"
    printf "║ Profile     : %-39s ║\n" "$(profile)"
    printf "║ ARM         : %6s MHz                            ║\n" "$a"
    printf "║ CORE        : %6s MHz                            ║\n" "$c"
    printf "║ SDRAM       : %6s MHz                            ║\n" "$s"
    printf "║ Voltage     : %-39s ║\n" "$v"
    printf "║ Temperature : %6s°C                            ║\n" "$t"
    printf "║ RAM         : %s / %s MB (%s%%)                  ║\n" \
        "$u" "$total" "$pct"
    printf "║ Load        : %-39s ║\n" "$l1 / $l5 / $l15"
    printf "║ Throttle    : %-39s ║\n" "$THROTTLE"
    echo "${C}╠══════════════════════════════════════════════════════╣${X}"
    status_strip
    echo "${C}╚══════════════════════════════════════════════════════╝${X}"

    pause
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

while true; do
    menu
done
