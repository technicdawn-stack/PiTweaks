#!/bin/bash

clear

# ==============================================================================
# 🍓 PiTweaks All-in-One System & Discord Bot Installer
# ==============================================================================

if [ -n "$SUDO_USER" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    CURRENT_USER="$SUDO_USER"
else
    REAL_HOME="$HOME"
    CURRENT_USER="$(whoami)"
fi

INSTALL_DIR="$REAL_HOME/PiTweaks"
BOT_DIR="$INSTALL_DIR/discord_bot"
CONFIG_FILE="$BOT_DIR/config.env"
MONITOR_SCRIPT="$INSTALL_DIR/temp_monitor.sh"
BOT_SCRIPT="$BOT_DIR/bot.py"
SERVICE_NAME="pitweaks-discord-bot"

echo "=========================================="
echo " 🍓 PiTweaks System & Discord Bot Installer"
echo "=========================================="

mkdir -p "$BOT_DIR"

# 1. DEPENDENCY INSTALLATION
echo "📦 Installing required dependencies..."
sudo apt-get update -qq && sudo apt-get install -y jq python3 python3-pip stress-ng -qq
python3 -c "import discord" &> /dev/null || pip3 install discord.py --break-system-packages &> /dev/null || pip3 install discord.py

# 2. CONFIGURATION SETUP
USE_OLD_CONFIG=false
if [ -f "$CONFIG_FILE" ]; then
    read -p "Reuse saved Bot Token and User ID? [Y/n]: " REUSE_CHOICE </dev/tty
    REUSE_CHOICE=${REUSE_CHOICE:-Y}
    case "$REUSE_CHOICE" in
        [yY]|[yY][eE][sS])
            source "$CONFIG_FILE"
            USE_OLD_CONFIG=true
            ;;
    esac
fi

if [ "$USE_OLD_CONFIG" = false ]; then
    read -p "Enter Discord Bot Token: " -s BOT_TOKEN
    echo ""
    read -p "Enter Discord User ID (numeric): " USER_ID
    echo ""

    if ! [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
        echo "❌ Error: User ID must be numeric."
        exit 1
    fi

    cat << EOL > "$CONFIG_FILE"
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
EOL
    chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

# 3. WRITE THE MONITORING SCRIPT
cat << 'SCRIPT' > "$MONITOR_SCRIPT"
#!/bin/bash

DIVIDER="---------------------------------------"

get_temp() {
    if command -v vcgencmd &>/dev/null; then
        vcgencmd measure_temp | egrep -o '[0-9]*\.[0-9]*'
    elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp
    else
        echo "N/A"
    fi
}

get_throttled_status() {
    if command -v vcgencmd &>/dev/null; then
        STATUS=$(vcgencmd get_throttled | cut -d'=' -f2)
        if [ "$STATUS" = "0x0" ]; then
            echo "OK (No Throttling)"
        else
            echo "⚠️ Throttled ($STATUS)"
        fi
    else
        echo "N/A"
    fi
}

get_top_cpu() {
    ps -eo comm,%cpu,%mem --sort=-%cpu | head -n 4 | tail -n 3 | awk '{printf "  • %s: CPU %s%% | RAM %s%%\n", $1, $2, $3}'
}

RAW_TEMP=$(get_temp)
THROTTLE_STAT=$(get_throttled_status)

RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
RAM_PERC=$(( RAM_USED * 100 / RAM_TOTAL ))

CPU_IDLE=$(top -bn1 | awk '/Cpu\(s\)/ {print $8}' | cut -d'.' -f1)
CPU_USAGE=$(( 100 - ${CPU_IDLE:-0} ))

if [ "$1" = "temp_report" ]; then
    TOP_PROCS=$(get_top_cpu)
    echo "${DIVIDER}"
    echo "📊 **System Diagnostic Report**:"
    echo "• **Temp:** ${RAW_TEMP}°C | **Throttling:** ${THROTTLE_STAT}"
    echo "• **CPU Usage:** ${CPU_USAGE}% | **RAM Usage:** ${RAM_PERC}% (${RAM_USED}MB / ${RAM_TOTAL}MB)"
    echo ""
    echo "**Top CPU Processes:**"
    echo "${TOP_PROCS}"
    echo "${DIVIDER}"
    exit 0

elif [ "$1" = "test_cpu" ] && [ -n "$2" ]; then
    echo "⚡ Running Real CPU Stress Test for 10 seconds..."
    stress-ng --cpu 2 --timeout 10s &>/dev/null &
    sleep 2
    NEW_TEMP=$(get_temp)
    echo "${DIVIDER}"
    echo "⚡ **CPU Stress Test Active**"
    echo "• **Peak Temp:** ${NEW_TEMP}°C | **Target Load:** $2%"
    echo "${DIVIDER}"
    exit 0

elif [ "$1" = "test_ram" ] && [ -n "$2" ]; then
    echo "📊 Running Real RAM Stress Test for 10 seconds..."
    stress-ng --vm 1 --vm-bytes 50% --timeout 10s &>/dev/null &
    sleep 2
    echo "${DIVIDER}"
    echo "📊 **RAM Stress Test Active**"
    echo "• **Simulated Target:** $2% RAM Load"
    echo "${DIVIDER}"
    exit 0

elif [ "$1" = "test_temp" ] && [ -n "$2" ]; then
    echo "${DIVIDER}"
    echo "🌡️ **Thermal Warning Simulation**"
    echo "• **Simulated Core Temp:** $2°C (Actual: ${RAW_TEMP}°C)"
    echo "${DIVIDER}"
    exit 0
fi
SCRIPT

chmod +x "$MONITOR_SCRIPT"
chown "$CURRENT_USER:$CURRENT_USER" "$MONITOR_SCRIPT"

# 4. WRITE THE DISCORD BOT SCRIPT
cat << 'EOF' > "$BOT_SCRIPT"
import discord
import subprocess
import datetime
import os

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.env")
MONITOR_PATH = os.path.abspath(os.path.join(BASE_DIR, "../temp_monitor.sh"))

config = {}
if os.path.exists(CONFIG_PATH):
    with open(CONFIG_PATH) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                config[k] = v.strip('"\'')

YOUR_DISCORD_USER_ID = int(config.get("USER_ID", 0))

def get_target_channel(guild, channel_name):
    if not guild:
        return None
    return discord.utils.get(guild.text_channels, name=channel_name)

@client.event
async def on_ready():
    print(f'Logged in as {client.user.name}')

async def cmd_temp_report(message, args):
    target_chan = get_target_channel(message.guild, "raspi3b") or message.channel
    try:
        result = subprocess.run(f"bash {MONITOR_PATH} temp_report", shell=True, capture_output=True, text=True, timeout=30)
        output = result.stdout.strip() or result.stderr.strip() or "No output returned."
        await target_chan.send(output[:1900])
    except Exception as e:
        await target_chan.send(f"❌ Error: `{e}`")

async def cmd_reboot(message, args):
    await message.channel.send("🔄 Rebooting Raspberry Pi...")
    subprocess.run(['sudo', 'reboot'])

COMMANDS = {
    "temp_report": cmd_temp_report,
    "reboot": cmd_reboot
}

@client.event
async def on_message(message):
    if message.author == client.user or message.author.id != YOUR_DISCORD_USER_ID:
        return
    if message.content.startswith("!"):
        parts = message.content[1:].split(" ", 1)
        cmd_name = parts[0].lower()
        args = parts[1].strip() if len(parts) > 1 else ""
        if cmd_name in COMMANDS:
            await COMMANDS[cmd_name](message, args)

client.run(config.get("BOT_TOKEN"))
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$BOT_SCRIPT"

# 5. SERVICE SETUP
sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME.service" << EOL
[Unit]
Description=PiTweaks Discord Bot
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/usr/bin/python3 $BOT_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME.service"
sudo systemctl restart "$SERVICE_NAME.service"

echo "✅ Setup Complete!"
