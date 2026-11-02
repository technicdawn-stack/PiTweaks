#!/bin/bash

# Description: Pi benchmarking tool using Prime number calulations.
# PERSISTENT: TRUE (Config only modified on explicit user action)
# Category: Tools

echo "=========================================="
echo "    PiTweaks Automated Benchmarker"
echo "=========================================="

# Fast dependency check for sysbench
if ! command -v sysbench &> /dev/null; then
    echo "[!] sysbench is not installed. Installing it now..."
    sudo apt update && sudo apt install -y sysbench
    
    if ! command -v sysbench &> /dev/null; then
        echo "Error: Failed to install sysbench automatically."
        echo "Please install it manually using: sudo apt install sysbench -y"
        exit 1
    fi
    echo "[✓] sysbench installed successfully!"
    echo ""
fi

# Check if this specific execution was run with root/sudo privileges (ignoring cache)
if [ "$EUID" -eq 0 ]; then
    USE_NICE=true
    # \e[1m = Bold, \e[32m = Green, \e[0m = Reset formatting
    echo -e "\e[1m\e[32m[✓] Priority boost enabled (nice -n -20 active).\e[0m"
else
    USE_NICE=false
    # \e[1m = Bold, \e[33m = Yellow, \e[0m = Reset formatting
    echo -e "\e[1m\e[33m[!] WARNING: Not run with sudo.\e[0m"
    echo -e "\e[33m[!] Benchmark will run at standard priority. (Run with 'sudo ./benchmark.sh' for max priority).\e[0m"
fi
echo ""

# Prompt for configuration parameters
read -p "Enter CPU Max Prime (default 10000): " MAX_PRIME
MAX_PRIME=${MAX_PRIME:-10000}

read -p "Enter number of runs per time slot (default 3): " NUM_RUNS
NUM_RUNS=${NUM_RUNS:-3}

# Prompt for custom time sweep configuration
read -p "Configure sweep times? (y/n, default n): " CONFIG_SWEEP
if [[ "$CONFIG_SWEEP" =~ ^[Yy]$ ]]; then
    read -p "Enter times in seconds separated by spaces (e.g. 1 2 5 10 30 60): " -a TIMES
    if [ ${#TIMES[@]} -eq 0 ]; then
        TIMES=(1 2 5 10 30 60)
    fi
else
    TIMES=(1 2 5 10 30 60)
fi

# Prompt whether to include the average column
read -p "Record average column? (y/n, default y): " RECORD_AVG
if [[ "$RECORD_AVG" =~ ^[Nn]$ ]]; then
    SHOW_AVG=false
else
    SHOW_AVG=true
fi

# Prompt whether to show time labels in the output table
read -p "Show time labels in table? (y/n, default y): " SHOW_TIMES_INPUT
if [[ "$SHOW_TIMES_INPUT" =~ ^[Nn]$ ]]; then
    SHOW_TIMES=false
else
    SHOW_TIMES=true
fi

# Calculate total estimated runtime
TOTAL_TIME=0
for t in "${TIMES[@]}"; do
    TOTAL_TIME=$((TOTAL_TIME + (t * NUM_RUNS)))
done

echo ""
echo "Configuration Set:"
echo " - Max Prime: $MAX_PRIME"
echo " - Runs per slot: $NUM_RUNS"
echo " - Time Sweep: ${TIMES[*]} seconds"
echo " - Record Average: $SHOW_AVG"
echo " - Show Time Labels: $SHOW_TIMES"
echo " - Est. Total Runtime: ~${TOTAL_TIME} seconds"
echo ""
read -p "Press Enter to start benchmark sweep..."

declare -A RESULTS

echo ""
echo "Running benchmarks... Please wait (do not run other apps)."
echo "------------------------------------------"

for t in "${TIMES[@]}"; do
    scores=()
    for ((r=1; r<=NUM_RUNS; r++)); do
        echo -n "[Testing] Time: ${t}s | Run $r/$NUM_RUNS ... "
        
        # Run with nice if available, otherwise fallback to standard execution
        if [ "$USE_NICE" = true ]; then
            output=$(sudo nice -n -20 sysbench cpu --threads=4 --max-time="$t" --cpu-max-prime="$MAX_PRIME" run 2>/dev/null)
        else
            output=$(sysbench cpu --threads=4 --max-time="$t" --cpu-max-prime="$MAX_PRIME" run 2>/dev/null)
        fi
        
        score=$(echo "$output" | awk '/events per second/ {print $NF}')
        
        if [ -z "$score" ]; then
            score="0"
        fi
        
        scores+=("$score")
        echo "Score: $score"
    done
    
    RESULTS[$t]="${scores[*]}"
done

echo ""
echo "=========================================="
echo " RESULTS (Copy & Paste ready for Sheets)"
echo "=========================================="

# Build header array dynamically
header_cols=()
if [ "$SHOW_TIMES" = true ]; then
    header_cols+=("Time")
fi
for ((r=1; r<=NUM_RUNS; r++)); do
    header_cols+=("Score $r")
done
if [ "$SHOW_AVG" = true ]; then
    header_cols+=("Average")
fi

IFS=$'\t' echo -e "${header_cols[*]}"

for t in "${TIMES[@]}"; do
    read -ra run_scores <<< "${RESULTS[$t]}"
    
    sum=0
    for ((i=0; i<NUM_RUNS; i++)); do
        val=${run_scores[$i]:-0}
        sum=$(awk -v s="$sum" -v v="$val" 'BEGIN {print s + v}')
    done
    
    avg=0
    if [ "$SHOW_AVG" = true ]; then
        avg=$(awk -v s="$sum" -v n="$NUM_RUNS" 'BEGIN {print s / n}')
    fi
    
    row_cols=()
    if [ "$SHOW_TIMES" = true ]; then
        row_cols+=("${t}s")
    fi
    for ((i=0; i<NUM_RUNS; i++)); do
        row_cols+=("${run_scores[$i]:-0}")
    done
    if [ "$SHOW_AVG" = true ]; then
        row_cols+=("$avg")
    fi
    
    IFS=$'\t' echo -e "${row_cols[*]}"
done
echo "=========================================="
