#!/bin/bash

# Description: Disk I/O telemetry with session-based process tracking.
# PERSISTENT: FALSE
# Category: Tools

# Configuration
INTERVAL=1          # Default refresh interval (1 second)
MAX_HISTORY=8       # Number of recent samples to show in the rolling table

# Color Definitions
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
NC="\033[0m" # No Color

# --- Cleanup & Initialization ---
cleanup() {
    tput cnorm # Restore cursor
    clear
    exit 0
}

# Trap Ctrl+C (SIGINT) to exit cleanly
trap cleanup SIGINT

# Initialize screen and hide cursor
clear
tput civis

# Automatically detect the root storage device (external SSD)
ROOT_DEV=$(df / | awk 'NR==2 {print $1}' | sed 's|/dev/||; s/[0-9]*$//')
if [[ "$ROOT_DEV" =~ ^mmcblk ]]; then
    ROOT_DEV=$(echo "$ROOT_DEV" | sed 's/p[0-9]*$//')
fi

# Arrays for rolling history logs
HISTORY_TIME=()
HISTORY_READ=()
HISTORY_WRITE=()
HISTORY_PROC=()

# Helper function to generate a solid ASCII progress bar
draw_ascii_bar() {
    local val=${1:-0}
    val=$((val))
    local width=12
    local filled=$(( val * width / 10000 ))
    [ $filled -gt $width ] && filled=$width
    [ $filled -lt 0 ] && filled=0
    
    if [ $val -gt 0 ] && [ $filled -eq 0 ]; then
        filled=1
    fi
    
    local empty=$(( width - filled ))
    local bar="["
    for ((i=0; i<filled; i++)); do bar+="#"; done
    for ((i=0; i<empty; i++)); do bar+="-"; done
    bar+="]"
    echo "$bar"
}

# Helper function to scan /proc/[pid]/io safely for active writers
get_top_writers() {
    for pdir in /proc/[0-9]*; do
        if [ -f "$pdir/io" ] && [ -r "$pdir/io" ]; then
            local comm=""
            [ -f "$pdir/comm" ] && comm=$(cat "$pdir/comm" 2>/dev/null)
            
            local wbytes=$(awk '/write_bytes:/ {print $2}' "$pdir/io" 2>/dev/null | tr -cd '0-9')
            
            if [[ "$wbytes" =~ ^[0-9]+$ ]] && [ "$wbytes" -gt 0 ]; then
                echo "$wbytes ${comm:-unknown}"
            fi
        fi
    done 2>/dev/null | sort -rn | head -n 3
}

# Print static header once at the very top
printf "\033[H"
printf "${CYAN}==========================================${NC}\033[K\n"
printf "${GREEN} Storage Telemetry (${ROOT_DEV}) [Interval: ${INTERVAL}s]${NC}\033[K\n"
printf "${CYAN}==========================================${NC}\033[K\n"

while true; do
    # Move cursor back to line 4 (flicker-free update)
    printf "\033[4H"

    # Capture live timestamp
    CURRENT_TIME=$(date +"%T")

    # Fetch initial cumulative stats from /proc/diskstats
    STATS1=$(grep -w "$ROOT_DEV" /proc/diskstats)
    if [ -n "$STATS1" ]; then
        R1=$(echo $STATS1 | awk '{print $6}')
        W1=$(echo $STATS1 | awk '{print $10}')
        
        HIST_READ_MB=$(( R1 * 512 / 1024 / 1024 ))
        HIST_WRITE_MB=$(( W1 * 512 / 1024 / 1024 ))
        
        if [ $HIST_READ_MB -gt 1024 ]; then
            HIST_READ=$(awk "BEGIN {printf \"%.2f GB\", $HIST_READ_MB/1024}")
        else
            HIST_READ="${HIST_READ_MB} MB"
        fi

        if [ $HIST_WRITE_MB -gt 1024 ]; then
            HIST_WRITE=$(awk "BEGIN {printf \"%.2f GB\", $HIST_WRITE_MB/1024}")
        else
            HIST_WRITE="${HIST_WRITE_MB} MB"
        fi
    else
        HIST_READ="N/A"
        HIST_WRITE="N/A"
    fi

    # Print baseline metrics with line-wiping codes
    printf "• Time / Device:     ${CYAN}%s${NC} | ${YELLOW}%s${NC}\033[K\n" "$CURRENT_TIME" "$ROOT_DEV"
    printf "• Historical Read:   ${GREEN}%s${NC}\033[K\n" "${HIST_READ:-N/A}"
    printf "• Historical Write:  ${RED}%s${NC}\033[K\n" "${HIST_WRITE:-N/A}"
    printf "\033[K\n"
    printf "${CYAN}==========================================${NC}\033[K\n"
    printf " Live Throughput & Activity Bars\033[K\n"
    printf "${CYAN}==========================================${NC}\033[K\n"

    # Take second sample based on the interval
    sleep "$INTERVAL"
    STATS2=$(grep -w "$ROOT_DEV" /proc/diskstats)
    if [ -n "$STATS2" ]; then
        R2=$(echo $STATS2 | awk '{print $6}')
        W2=$(echo $STATS2 | awk '{print $10}')
        
        DIFF_R_KB=$(( ((R2 - R1) * 512 / 1024) / INTERVAL ))
        DIFF_W_KB=$(( ((W2 - W1) * 512 / 1024) / INTERVAL ))
        
        READ_BAR=$(draw_ascii_bar "$DIFF_R_KB")
        WRITE_BAR=$(draw_ascii_bar "$DIFF_W_KB")
        
        if [ "$DIFF_W_KB" -eq 0 ]; then
            CURRENT_WRITER="-"
        else
            RAW_TOP=$(get_top_writers | head -n 1)
            CURRENT_WRITER=$(echo "$RAW_TOP" | awk '{print $2}')
            [ -z "$CURRENT_WRITER" ] && CURRENT_WRITER="Kernel/IO"
        fi
        
        # Update rolling history arrays
        HISTORY_TIME+=("$CURRENT_TIME")
        HISTORY_READ+=("$DIFF_R_KB")
        HISTORY_WRITE+=("$DIFF_W_KB")
        HISTORY_PROC+=("$CURRENT_WRITER")
        
        if [ ${#HISTORY_TIME[@]} -gt $MAX_HISTORY ]; then
            HISTORY_TIME=("${HISTORY_TIME[@]:1}")
            HISTORY_READ=("${HISTORY_READ[@]:1}")
            HISTORY_WRITE=("${HISTORY_WRITE[@]:1}")
            HISTORY_PROC=("${HISTORY_PROC[@]:1}")
        fi
        
        printf "• Read:  ${GREEN}%-6s KB/s${NC} %s\033[K\n" "$DIFF_R_KB" "$READ_BAR"
        printf "• Write: ${RED}%-6s KB/s${NC} %s\033[K\n" "$DIFF_W_KB" "$WRITE_BAR"
    else
        printf "• Current Rate:       ${YELLOW}N/A${NC}\033[K\n"
    fi
    
    printf "${CYAN}==========================================${NC}\033[K\n"
    printf " Top Writing Processes (Active Session)\033[K\n"
    printf "${CYAN}==========================================${NC}\033[K\n"
    
    # Render top active writers cleanly
    TOP_WRITERS_OUTPUT=$(get_top_writers)
    if [ -n "$TOP_WRITERS_OUTPUT" ]; then
        while IFS= read -r line; do
            w_bytes=$(echo "$line" | awk '{print $1}' | tr -cd '0-9')
            w_comm=$(echo "$line" | awk '{print $2}')
            if [[ "$w_bytes" =~ ^[0-9]+$ ]]; then
                # Show in MB or KB relative to scale
                w_mb=$(( w_bytes / 1024 / 1024 ))
                if [ "$w_mb" -gt 0 ]; then
                    printf " • %-15s (%s MB total)\033[K\n" "$w_comm" "$w_mb"
                else
                    w_kb=$(( w_bytes / 1024 ))
                    printf " • %-15s (%s KB total)\033[K\n" "$w_comm" "$w_kb"
                fi
            fi
        done <<< "$TOP_WRITERS_OUTPUT"
    else
        printf " • Monitoring disk I/O metrics...\033[K\n"
    fi
    
    printf "${CYAN}==========================================${NC}\033[K\n"
    printf " Activity Log (Last ${MAX_HISTORY} Samples)\033[K\n"
    printf "${CYAN}==========================================${NC}\033[K\n"
    printf " Time     | R (KB/s) | W (KB/s) | Top Writer\033[K\n"
    printf -- "----------+----------+----------+-------------\033[K\n"
    
    # Print rolling history table rows cleanly
    len=${#HISTORY_TIME[@]}
    for (( i=0; i<len; i++ )); do
        printf " %-8s | %-8s | %-8s | %-12s\033[K\n" "${HISTORY_TIME[$i]}" "${HISTORY_READ[$i]}" "${HISTORY_WRITE[$i]}" "${HISTORY_PROC[$i]}"
    done
    
    # Fill remaining table rows if history hasn't filled up yet
    for (( i=len; i<MAX_HISTORY; i++ )); do
        printf "          |          |          |             \033[K\n"
    done
    printf "${CYAN}==========================================${NC}\033[K\n"
done
