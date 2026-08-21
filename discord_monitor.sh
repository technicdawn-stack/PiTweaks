#!/bin/bash
# Description: Revert 3
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
MONITOR_SCRIPT="$REAL_HOME/temp_monitor.sh"
BOT_SCRIPT="$BOT_DIR/bot.py"
SERVICE_NAME="pitweaks-discord-bot"

echo "=========================================="
echo " 🍓 PiTweaks All-in-One Setup & Installer"
echo "=========================================="
echo ""

# 1. INTELLIGENT AUTO-DETECTION OF EXISTING FILES
MISSING_ITEMS=""
PRESENT_ITEMS=""

[ -f "$MONITOR_SCRIPT" ] && PRESENT_ITEMS="$PRESENT_ITEMS temp_monitor.sh" \vert{}\vert{} MISSING_ITEMS="$MISSING_ITEMS temp_monitor.sh"
[ -f "$BOT_SCRIPT" ] && PRESENT_ITEMS="$PRESENT_ITEMS bot.py" \vert{}\vert{} MISSING_ITEMS="$MISSING_ITEMS bot.py"
[ -f "$CONFIG_FILE" ] && PRESENT_ITEMS="$PRESENT_ITEMS config.env" \vert{}\vert{} MISSING_ITEMS="$MISSING_ITEMS config.env"

if [ -n "$PRESENT_ITEMS" ]; then
    echo "🔍 **Status Check:** Found existing components:$PRESENT_ITEMS"
    if [ -n "$MISSING_ITEMS" ]; then
        echo "⚠️  **Missing components:**$MISSING_ITEMS"
    fi
    echo ""
    read -p "Do you want to repair/update existing scripts or perform a clean reinstall? [U]pdate/Repair / [F]resh Install / [Q]uit: " INSTALL_CHOICE </dev/tty
    echo ""
    case "$INSTALL_CHOICE" in
        [qQ]* )
            echo "❌ Installation cancelled by user."
            exit 0
            ;;
        [fF]* )
            echo "🔄 Performing fresh installation (overwriting everything)..."
            echo ""
            ;;
        * )
            echo "⚙️ Proceeding with smart update/repair mode..."
            echo ""
            ;;
    esac
else
    echo "🆕 No existing installation detected. Starting fresh setup..."
    echo ""
fi

# 2. DEPENDENCY INSTALLATION
echo "📦 Installing required system dependencies (jq, python3)..."
sudo apt-get update -qq && sudo apt-get install -y jq python3 python3-pip -qq

echo "📦 Verifying python library (discord.py)..."
python3 -c "import discord" &> /dev/null || pip3 install discord.py --break-system-packages &> /dev/null || pip3 install discord.py

echo ""

# 3. CONFIGURATION SETUP
USE_OLD_CONFIG=false
if [ -f "$CONFIG_FILE" ]; then
    read -p "Do you want to reuse your saved Bot Token and User ID? [Y/n]: " REUSE_CHOICE </dev/tty
    REUSE_CHOICE=${REUSE_CHOICE:-Y}
    echo ""
    case "$REUSE_CHOICE" in
        [yY]|[yY][eE][sS])
            source "$CONFIG_FILE"
            USE_OLD_CONFIG=true
            echo "✅ Loaded saved configuration credentials."
            ;;
    esac
fi

if [ "$USE_OLD_CONFIG" = false ]; then
    echo "⚙️  New Configuration Setup"
    echo "------------------------------------------"
    read -p "Enter your Discord Bot Token: " -s BOT_TOKEN
    echo ""
    read -p "Enter your Discord User ID (numeric): " USER_ID
    echo ""

    if ! [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
        echo "❌ Error: Discord User ID must be numbers only."
        exit 1
    fi

    mkdir -p "$BOT_DIR"
    cat << EOL > "$CONFIG_FILE"
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
EOL
    chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

mkdir -p "$BOT_DIR"

# ==============================================================================
# 4. WRITE THE MONITORING SCRIPT (~/temp_monitor.sh)
# ==============================================================================
echo "📝 Writing ~/temp_monitor.sh..."
cat << 'SCRIPT' > "$MONITOR_SCRIPT"
#!/bin/bash

# --- CONFIGURATION ---
STATUS_FILE="/tmp/pi_system_status.txt"
CPU_THRESHOLD=90
RAM_THRESHOLD=90
DIVIDER="---------------------------------------"
# ---------------------

get_top_cpu() {
    ps -eo comm,%cpu,%mem --sort=-%cpu | head -n 4 | tail -n 3 | awk '{printf "  • %s: CPU %s%% | RAM %s%%\n", \$1, \$2, \$3}'
}

get_top_ram() {
    ps -eo comm,%cpu,%mem --sort=-%mem | head -n 4 | tail -n 3 | awk '{printf "  • %s: RAM %s%% | CPU %s%%\n", \$1, \$3, \$2}'
}

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

if [ "\$1" = "temp_report" ]; then
    TOP_PROCS=\$(get_top_cpu)
    MSG="\${DIVIDER}
🟨 📝 **System Report**:
• **Temp:** \${RAW_TEMP}°C | **CPU:** \${CPU_USAGE}% | **RAM:** \${RAM_PERC}% (\${RAM_USED}MB / \${RAM_TOTAL}MB)

**Top Processes (CPU):**
\${TOP_PROCS}
\${DIVIDER}"
    echo "\$MSG"
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
    echo "\$MSG"
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
    echo "\$MSG"
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
    echo "\$MSG"
    exit 0
fi
SCRIPT

chmod +x "$MONITOR_SCRIPT"
chown "$CURRENT_USER:$CURRENT_USER" "$MONITOR_SCRIPT"

# ==============================================================================
# 5. WRITE THE DISCORD BOT SCRIPT ($BOT_DIR/bot.py)
# ==============================================================================
echo "📝 Writing Discord bot script..."
cat << 'EOF' > "$BOT_SCRIPT"
import discord
import subprocess
import datetime
import shlex

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

config = {}
with open("/home/raspi3b/PiTweaks/discord_bot/config.env") as f:
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
    try:
        user = await client.fetch_user(YOUR_DISCORD_USER_ID)
        await user.send("🚀 **Raspberry Pi Booted Successfully!**\nSystem control bot is online and ready.")
    except Exception as e:
        print(f"Could not send boot DM: {e}")

async def cmd_reboot(message, args):
    target_chan = get_target_channel(message.guild, "raspi3b") or message.channel
    await target_chan.send("🔄 Rebooting Raspberry Pi...")
    subprocess.run(['sudo', 'reboot'])

async def cmd_shutdown(message, args):
    target_chan = get_target_channel(message.guild, "raspi3b") or message.channel
    await target_chan.send("🛑 Shutting down Raspberry Pi...")
    subprocess.run(['sudo', 'shutdown', 'now'])

async def cmd_temp_report(message, args):
    target_chan = get_target_channel(message.guild, "raspi3b") or message.channel
    await target_chan.send("📊 Generating system report...")
    try:
        result = subprocess.run("stdbuf -oL bash ~/temp_monitor.sh temp_report", shell=True, capture_output=True, text=True, timeout=30)
        output = result.stdout.strip() or result.stderr.strip() or "Report generated with no output."
        if len(output) > 1900:
            output = output[:1900] + "\n[Output truncated...]"
        await target_chan.send(f"```text\n{output}\n```")
    except Exception as e:
        await target_chan.send(f"❌ Error running command: `{e}`")

async def cmd_test(message, args):
    target_chan = get_target_channel(message.guild, "raspi3b") or message.channel
    parts = args.split(" ", 1)
    if len(parts) < 2 or parts[0].lower() not in ["cpu", "ram", "temp"]:
        await target_chan.send("❌ Usage: `!test <cpu|ram|temp> <num>` (e.g., `!test cpu 99`).")
        return
    
    test_type = parts[0].lower()
    val_str = parts[1].strip()
    if not val_str.isdigit():
        await target_chan.send("❌ Please provide a valid numeric value.")
        return
        
    value = int(val_str)
    action_labels = {"cpu": "CPU test", "ram": "RAM test", "temp": "temp test"}
    await target_chan.send(f"⚡ Executing {action_labels[test_type]} with value {value}...")
    
    try:
        result = subprocess.run(f"stdbuf -oL bash ~/temp_monitor.sh test_{test_type} {value}", shell=True, capture_output=True, text=True, timeout=60)
        output = result.stdout.strip() or result.stderr.strip() or "Command executed successfully with no output."
        if len(output) > 1500:
            output = output[:1500] + "\n[Output truncated...]"
        await target_chan.send(f"✅ `test_{test_type} {value}` finished.\n```text\n{output}\n```")
    except Exception as e:
        await target_chan.send(f"❌ Error executing terminal command: `{e}`")

async def cmd_alert(message, args):
    target_chan = get_target_channel(message.guild, "alert") or message.channel
    try:
        parts = shlex.split(args)
    except Exception:
        parts = args.split()
        
    if not parts:
        await message.channel.send("❌ Usage examples:\n`!alert reboot 5` (notice only)\n`!alert reboot 5 10` (notice + duration)\n`!alert 5 15 \"Custom notice\"`")
        return

    now = datetime.datetime.now()
    if parts[0].lower() in ["reboot", "shutdown", "update", "interrupt"]:
        action = parts[0].lower()
        delay_mins = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 5
        
        has_duration = len(parts) > 2 and parts[2].isdigit()
        duration_mins = int(parts[2]) if has_duration else 5
        
        start_time = now + datetime.timedelta(minutes=delay_mins)
        end_time = start_time + datetime.timedelta(minutes=duration_mins)
        
        if action in ["reboot", "shutdown"]:
            title = f"PLANNED NETWORK DOWNTIME: {action.upper()}"
            classification = "Necessary Downtime (Guaranteed Event)"
            emoji = "🚨"
            advice = "Please save your work accordingly!"
        else:
            title = f"POTENTIAL SERVICE INTERRUPTION: {action.upper()}"
            classification = "Soft Event (Downtime Not Guaranteed)"
            emoji = "⚠️"
            advice = "Services may experience a brief blip."
        
        output_msg = (
            f"{emoji} **{title}** {emoji}\n"
            f"• **Action Type:** {action.capitalize()}\n"
            f"• **Notice Given At:** {now.strftime('%H:%M')}\n"
            f"• **Execution Time:** ~{start_time.strftime('%H:%M')} (In {delay_mins} mins)\n"
        )
        
        if has_duration:
            output_msg += f"• **Expected Length:** {duration_mins} minute(s) (Expected back ~{end_time.strftime('%H:%M')})\n"
            
        output_msg += (
            f"• **Event Classification:** {classification}\n\n"
            f"*{advice}*"
        )
        await target_chan.send(output_msg)
        
    elif parts[0].isdigit():
        delay_mins = int(parts[0])
        duration_mins = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 5
        custom_text_parts = parts[2:] if len(parts) > 2 and parts[1].isdigit() else parts[1:]
        custom_text = " ".join(custom_text_parts).strip("\"'")
        if not custom_text:
            custom_text = "Scheduled maintenance notification."
            
        start_time = now + datetime.timedelta(minutes=delay_mins)
        end_time = start_time + datetime.timedelta(minutes=duration_mins)
        
        output_msg = (
            f"🚨 **PLANNED NETWORK NOTICE: CUSTOM EVENT** 🚨\n"
            f"• **Custom Message:** {custom_text}\n"
            f"• **Notice Given At:** {now.strftime('%H:%M')}\n"
            f"• **Execution Time:** ~{start_time.strftime('%H:%M')} (In {delay_mins} mins)\n"
            f"• **Expected Length:** {duration_mins} minute(s) (Expected back ~{end_time.strftime('%H:%M')})\n\n"
            f"*Please save your work and log off if necessary.*"
        )
        await target_chan.send(output_msg)
    else:
        await message.channel.send("❌ Unknown alert command format.")

async def cmd_help(message, args):
    target_chan = get_target_channel(message.guild, "raspi3b") or message.channel
    help_text = (
        "🤖 **Raspberry Pi Bot Commands:**\n"
        "• `!temp_report` - Run system temperature report.\n"
        "• `!test <cpu|ram|temp> <num>` - Run hardware diagnostic tests.\n"
        "• `!alert reboot <delay> [dur]` - Broadcast preset reboot alert (duration optional).\n"
        "• `!alert shutdown <delay> [dur]` - Broadcast preset shutdown alert (duration optional).\n"
        "• `!alert update <delay> [dur]` - Broadcast preset update alert (duration optional).\n"
        "• `!alert interrupt <delay> [dur]` - Broadcast preset interruption alert (duration optional).\n"
        "• `!alert <delay> <dur> \"text\"` - Broadcast a custom timed alert.\n"
        "• `!reboot` - Safely restart the Raspberry Pi.\n"
        "• `!shutdown` - Safely shut down the Raspberry Pi.\n"
        "• `!help` - Display this command menu."
    )
    await target_chan.send(help_text)

COMMANDS = {
    "reboot": cmd_reboot,
    "shutdown": cmd_shutdown,
    "temp_report": cmd_temp_report,
    "test": cmd_test,
    "alert": cmd_alert,
    "help": cmd_help
}

@client.event
async def on_message(message):
    if message.author == client.user:
        return
    if message.author.id != YOUR_DISCORD_USER_ID:
        return
    if message.content.startswith("!"):
        parts = message.content[1:].split(" ", 1)
        cmd_name = parts[0].lower()
        args = parts[1].strip() if len(parts) > 1 else ""
        if cmd_name in COMMANDS:
            try:
                await COMMANDS[cmd_name](message, args)
            except Exception as e:
                await message.channel.send(f"❌ Error executing command: `{e}`")
        else:
            await message.channel.send(f"❌ Unknown command `!{cmd_name}`. Type `!help` for options.")

client.run(config.get("BOT_TOKEN"))
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$BOT_SCRIPT"

# ==============================================================================
# 6. SHORTCUTS, CRON & SYSTEMD SERVICE
# ==============================================================================
echo "⚡ Setting up terminal aliases in ~/.bashrc..."
grep -qF "alias temp_report" "$REAL_HOME/.bashrc" || echo "alias temp_report='~/temp_monitor.sh temp_report'" >> "$REAL_HOME/.bashrc"
grep -qF "alias test_cpu" "$REAL_HOME/.bashrc" || echo "alias test_cpu='~/temp_monitor.sh test_cpu'" >> "$REAL_HOME/.bashrc"
grep -qF "alias test_ram" "$REAL_HOME/.bashrc" || echo "alias test_ram='~/temp_monitor.sh test_ram'" >> "$REAL_HOME/.bashrc"
grep -qF "alias test_temp" "$REAL_HOME/.bashrc" || echo "alias test_temp='~/temp_monitor.sh test_temp'" >> "$REAL_HOME/.bashrc"

echo "⏰ Scheduling automated cron job..."
(crontab -l 2>/dev/null | grep -v "temp_monitor.sh"; echo "* * * * * ~/temp_monitor.sh > /dev/null 2>&1") | crontab -

echo "⚙️ Setting up systemd service for Discord Bot..."
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

echo ""
echo "✅ Installation complete! Both the monitor script and Discord bot are ready and running."
