#!/bin/bash

# Ensure script is run with root/sudo if needed for nice priority, 
# though sysbench can run unprivileged. We will use the nice command as requested.

echo "=========================================="
echo "    PiTweaks Automated Benchmarker"
echo "=========================================="

# Prompt for configuration parameters
read -p "Enter CPU Max Prime (default 10000): " MAX_PRIME
MAX_PRIME=${MAX_PRIME:-10000}

read -p "Enter number of runs per time slot (default 3): " NUM_RUNS
NUM_RUNS=${NUM_RUNS:-3}

# Define time sweep array (in seconds)
TIMES=(1 2 5 10 30 60)

echo ""
echo "Configuration Set:"
echo " - Max Prime: $MAX_PRIME"
echo " - Runs per slot: $NUM_RUNS"
echo " - Time Sweep: ${TIMES[*]} seconds"
echo ""
read -p "Press Enter to start benchmark sweep..."

# Declare an associative array or parallel lists to store results
declare -A RESULTS

echo ""
echo "Running benchmarks... Please wait (do not run other apps)."
echo "------------------------------------------"

for t in "${TIMES[@]}"; do
    scores=()
    for ((r=1; r<=NUM_RUNS; r++)); do
        # Print status to terminal lightweight view
        echo -n "[Testing] Time: ${t}s | Run $r/$NUM_RUNS ... "
        
        # Run sysbench and extract the 'events per second' metric
        # (Change grep target if you prefer total time or another metric)
        output=$(sudo nice -n -20 sysbench cpu --threads=4 --time="$t" --cpu-max-prime="$MAX_PRIME" run 2>/dev/null)
        score=$(echo "$output" | grep "events per second:" | awk '{print $3}')
        
        if [ -z "$score" ]; then
            score="0"
        fi
        
        scores+=("$score")
        echo "Score: $score"
    done
    
    # Store scores for final summary
    RESULTS[$t]="${scores[*]}"
done

echo ""
echo "=========================================="
echo " RESULTS (Copy & Paste ready for Sheets)"
echo "=========================================="
echo -e "Time\tScore 1\tScore 2\tScore 3\tAverage"

for t in "${TIMES[@]}"; do
    read -ra run_scores <<< "${RESULTS[$t]}"
    
    s1=${run_scores[0]:-0}
    s2=${run_scores[1]:-0}
    s3=${run_scores[2]:-0}
    
    # Calculate average using awk to handle decimals safely
    avg=$(awk -v a="$s1" -v b="$s2" -v c="$s3" -v n="$NUM_RUNS" 'BEGIN {print (a + b + c) / n}')
    
    echo -e "${t}s\t$s1\t$s2\t$s3\t$avg"
done
echo "=========================================="
