#!/bin/bash
# Description: Raspberry Pi system resource monitor installer with auto-config preservation, automated Discord alerts, priority temperature tracking, and testing utilities.

# Clear screen
clear

DISCORD_URL=""

# 1. IMMEDIATE CHECK: SAFETY GUARD & CONFIG PRESERVATION
if [ -f "$HOME/temp_monitor.sh" ]; then
    echo "================================================="
    echo "🔍 Existing installation detected at ~/temp_monitor.sh!"
    echo "================================================="
    echo ""
    
    # Automatically extract the existing Discord Webhook URL from the old script
    EXISTING_URL=$(grep 'DISCORD_URL=' "$HOME/temp_monitor.sh" | head -n 1 | sed 's/.*DISCORD_URL=["\x27]\?//;s/["\x27]\?$//')
    
    if [ -n "$EXISTING_URL" ]; then
        echo "✔ Successfully found your existing Discord Webhook configuration!"
        echo ""
        read -p "Would you like to keep and reuse your existing configuration values? (y/n): " KEEP_CONFIG < /dev/tty
        case "$KEEP_CONFIG" in 
            [Yy]* ) 
                DISCORD_URL="$EXISTING_URL"
                echo "⚙️ Preserved existing webhook URL. Updating script, shortcuts, and cron..."
                ;;
            * ) 
                echo ""
                read -p "Enter your new Discord Webhook URL: " DISCORD_URL < /dev/tty
                ;;
        esac
    else
        echo "⚠️ Existing installation found, but could not auto-extract old URL."
        read -p "Enter your Discord Webhook URL: " DISCORD_URL < /dev/tty
    fi
else
    # 2. CONFIRMATION PROMPT FOR NEW INSTALLATION
    echo "=========================================="
    echo " 🍓 Raspberry Pi Discord Monitor Setup"
    echo "=========================================="
    echo ""
    read -p "Do you want to proceed with a fresh installation? (y/n): " PROCEED < /dev/tty
    case "$PROCEED" in 
        [Yy]* ) ;;
        * ) 
            echo "Installation cancelled."
            exit 0
            ;;
    esac

    echo ""
    read -p "Enter your Discord Webhook URL: " DISCORD_URL < /dev/tty
fi

if [ -z "$DISCORD_URL" ]; then
    echo "❌ Error: Webhook URL cannot be empty."
    exit 1
fi

# 3. DEPENDENCY INSTALLATION
echo ""
echo "📦 Checking and installing dependencies (jq)..."
sudo apt-get update -qq && sudo apt-get install -y jq -qq

# 4. WRITE THE MONITORING SCRIPT
echo "📝 Writing updated ~/temp_monitor.sh..."
cat << SCRIPT > ~/temp_monitor.sh
#!/bin/bash

# --- CONFIGURATION ---
DISCORD_URL="${DISCORD_URL}"
STATUS_FILE="/tmp/pi_system_status.txt"
CPU_THRESHOLD=90
RAM_THRESHOLD=90
DIVIDER="---------------------------------------"
# ---------------------

# Helper: Get top 3 CPU-consuming processes
get_top_cpu() {
    ps -eo comm,%cpu,%mem --sort=-%cpu | head -n 4 | tail -n 3 | awk '{printf "  • %s: CPU %s%% | RAM %s%%\n", \$1, \$2, \$3}'
}

# Helper: Get top 3 RAM-consuming processes
get_top_ram() {
    ps -eo comm,%cpu,%mem --sort=-%mem | head -n 4 | tail -n 3 | awk '{printf "  • %s: RAM %s%% | CPU %s%%\n", \$1, \$3, \$2}'
}

# 1. Fetch System Metrics
RAW_TEMP=\$(vcgencmd measure_temp | egrep -o '[0-9]*\.[0-9]*')
TEMP=\${RAW_TEMP%.*}

RAM_TOTAL=\$(free -m | awk '/Mem:/ {print \$2}')
RAM_USED=\$(free -m | awk '/Mem:/ {print \$3}')
RAM_PERC=\$(( RAM_USED * 100 / RAM_TOTAL ))

CPU_IDLE=\$(top -bn1 | grep "%Cpu" | awk '{print \$8}' | cut -d'.' -f1)
if [ -z "\$CPU_IDLE" ]; then
    CPU_IDLE=\$(top -bn1 | awk '/Cpu\(s\)/ {print \$8}' | cut -d'.' -f1)
fi
CPU_USAGE=\$(( 100 - CPU_IDLE ))

# 2. SIMULATION & TEST COMMANDS
if [ "\$1" = "temp_report" ]; then
    TOP_PROCS=\$(get_top_cpu)
    MSG="\${DIVIDER}
🟨 📝 **System Report**:
• **Temp:** \${RAW_TEMP}°C | **CPU:** \${CPU_USAGE}% | **RAM:** \${RAM_PERC}% (\${RAM_USED}MB / \${RAM_TOTAL}MB)

**Top Processes (CPU):**
\${TOP_PROCS}
\${DIVIDER}"
    PAYLOAD=\$(jq -n --arg content "\$MSG" '{content: \$content}')
    curl -H "Content-Type: application/json" -X POST -d "\$PAYLOAD" "\$DISCORD_URL" > /dev/null 2>&1
    exit 0

elif [ "\$1" = "test_cpu" ] && [ -n "\$2" ]; then
    SIM_CPU=\$2
    TOP_PROCS=\$(get_top_cpu)
    MSG="\${DIVIDER}
🟦 ⚡ **HIGH CPU ALERT (TEST SIMULATION)**: Load sustained at \${SIM_CPU}% for 3 mins!
• **Temp:** \${RAW_TEMP}°C | **CPU:** \${SIM_CPU}% | **RAM:** \${RAM_PERC}%

**Top CPU Processes:**
\${TOP_PROCS}
\${DIVIDER}"
    PAYLOAD=\$(jq -n --arg content "\$MSG" '{content: \$content}')
    curl -H "Content-Type: application/json" -X POST -d "\$PAYLOAD" "\$DISCORD_URL" > /dev/null 2>&1
    echo "Simulated CPU alert sent (\${SIM_CPU}%)."
    exit 0

elif [ "\$1" = "test_ram" ] && [ -n "\$2" ]; then
    SIM_RAM=\$2
    TOP_PROCS=\$(get_top_ram)
    MSG="\${DIVIDER}
🟦 📊 **HIGH RAM ALERT (TEST SIMULATION)**: Usage sustained at \${SIM_RAM}% for 3 mins!
• **Temp:** \${RAW_TEMP}°C | **CPU:** \${CPU_USAGE}% | **RAM:** \${SIM_RAM}%

**Top RAM Processes:**
\${TOP_PROCS}
\${DIVIDER}"
    PAYLOAD=\$(jq -n --arg content "\$MSG" '{content: \$content}')
    curl -H "Content-Type: application/json" -X POST -d "\$PAYLOAD" "\$DISCORD_URL" > /dev/null 2>&1
    echo "Simulated RAM alert sent (\${SIM_RAM}%)."
    exit 0

elif [ "\$1" = "test_temp" ] && [ -n "\$2" ]; then
    SIM_TEMP=\$2
    TOP_PROCS=\$(get_top_cpu)
    MSG="\${DIVIDER}
🟦 🌡️ **TEMP WARNING (TEST SIMULATION)**: CPU reached \${SIM_TEMP}°C!
• **Temp:** \${SIM_TEMP}°C | **CPU:** \${CPU_USAGE}% | **RAM:** \${RAM_PERC}%

**Top CPU Processes:**
\${TOP_PROCS}
\${DIVIDER}"
    PAYLOAD=\$(jq -n --arg content "\$MSG" '{content: \$content}')
    curl -H "Content-Type: application/json" -X POST -d "\$PAYLOAD" "\$DISCORD_URL" > /dev/null 2>&1
    echo "Simulated Temp alert sent (\${SIM_TEMP}°C)."
    exit 0
fi

# 3. Read Saved State
if [ -f "\$STATUS_FILE" ]; then
    LAST_PRIORITY=\$(sed -n '1p' "\$STATUS_FILE")
    CPU_COUNT=\$(sed -n '2p' "\$STATUS_FILE")
    RAM_COUNT=\$(sed -n '3p' "\$STATUS_FILE")
else
    LAST_PRIORITY=0
    CPU_COUNT=0
    RAM_COUNT=0
fi

LAST_PRIORITY=\${LAST_PRIORITY:-0}
CPU_COUNT=\${CPU_COUNT:-0}
RAM_COUNT=\${RAM_COUNT:-0}

# 4. Check Temperature Thresholds
if [ "\$TEMP" -ge 80 ]; then PRIORITY=4
elif [ "\$TEMP" -ge 70 ]; then PRIORITY=3
elif [ "\$TEMP" -ge 60 ]; then PRIORITY=2
elif [ "\$TEMP" -ge 50 ]; then PRIORITY=1
else PRIORITY=0; fi

if [ "\$PRIORITY" -gt "\$LAST_PRIORITY" ]; then
    TOP_PROCS=\$(get_top_cpu)
    MSG="\${DIVIDER}
🟥 🌡️ **TEMP WARNING**: CPU reached \${RAW_TEMP}°C!
• **Temp:** \${RAW_TEMP}°C | **CPU:** \${CPU_USAGE}% | **RAM:** \${RAM_PERC}%

**Top CPU Processes:**
\${TOP_PROCS}
\${DIVIDER}"
    PAYLOAD=\$(jq -n --arg content "\$MSG" '{content: \$content}')
    curl -H "Content-Type: application/json" -X POST -d "\$PAYLOAD" "\$DISCORD_URL" > /dev/null 2>&1
fi
LAST_PRIORITY=\$PRIORITY

# 5. Check CPU Usage
if [ "\$CPU_USAGE" -ge "\$CPU_THRESHOLD" ]; then
    CPU_COUNT=\$((CPU_COUNT + 1))
    if [ "\$CPU_COUNT" -eq 3 ]; then
        TOP_PROCS=\$(get_top_cpu)
        MSG="\${DIVIDER}
🟥 ⚡ **HIGH CPU ALERT**: Load sustained at \${CPU_USAGE}% for 3 mins!
• **Temp:** \${RAW_TEMP}°C | **CPU:** \${CPU_USAGE}% | **RAM:** \${RAM_PERC}%

**Top CPU Processes:**
\${TOP_PROCS}
\${DIVIDER}"
        PAYLOAD=\$(jq -n --arg content "\$MSG" '{content: \$content}')
        curl -H "Content-Type: application/json" -X POST -d "\$PAYLOAD" "\$DISCORD_URL" > /dev/null 2>&1
    fi
else
    CPU_COUNT=0
fi

# 6. Check RAM Usage
if [ "\$RAM_PERC" -ge "\$RAM_THRESHOLD" ]; then
    RAM_COUNT=\$((RAM_COUNT + 1))
    if [ "\$RAM_COUNT" -eq 3 ]; then
        TOP_PROCS=\$(get_top_ram)
        MSG="\${DIVIDER}
🟥 📊 **HIGH RAM ALERT**: Usage sustained at \${RAM_PERC}% (\${RAM_USED}MB) for 3 mins!
• **Temp:** \${RAW_TEMP}°C | **CPU:** \${CPU_USAGE}% | **RAM:** \${RAM_PERC}%

**Top RAM Processes:**
\${TOP_PROCS}
\${DIVIDER}"
        PAYLOAD=\$(jq -n --arg content "\$MSG" '{content: \$content}')
        curl -H "Content-Type: application/json" -X POST -d "\$PAYLOAD" "\$DISCORD_URL" > /dev/null 2>&1
    fi
else
    RAM_COUNT=0
fi

# 7. Save State
printf "%s\n%s\n%s\n" "\$LAST_PRIORITY" "\$CPU_COUNT" "\$RAM_COUNT" > "\$STATUS_FILE"
SCRIPT

chmod +x ~/temp_monitor.sh

# 5. ALIASES & CRON CONFIGURATION
echo "⚡ Setting up global terminal shortcuts..."
grep -qF "alias temp_report" ~/.bashrc || echo "alias temp_report='~/temp_monitor.sh temp_report'" >> ~/.bashrc
grep -qF "alias test_cpu" ~/.bashrc || echo "alias test_cpu='~/temp_monitor.sh test_cpu'" >> ~/.bashrc
grep -qF "alias test_ram" ~/.bashrc || echo "alias test_ram='~/temp_monitor.sh test_ram'" >> ~/.bashrc
grep -qF "alias test_temp" ~/.bashrc || echo "alias test_temp='~/temp_monitor.sh test_temp'" >> ~/.bashrc

echo "⏰ Scheduling automated cron job..."
(crontab -l 2>/dev/null | grep -v "temp_monitor.sh"; echo "* * * * * ~/temp_monitor.sh > /dev/null 2>&1") | crontab -

echo ""
echo "✅ Installation complete! Run 'source ~/.bashrc' or restart your terminal."
