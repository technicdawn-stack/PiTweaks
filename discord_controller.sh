#!/bin/bash

# Description: Discord bot installer
# PERSISTENT: FALSE
# Category: Scripts

# ==============================================================================
# 🤖 PiTweaks - Discord Bot Installer (Whiptail TUI & Dual-Channel Routing)
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

INSTALL_DIR="$REAL_HOME/PiTweaks/discord_bot"
CONFIG_FILE="$INSTALL_DIR/config.env"
SERVICE_NAME="pitweaks-discord-bot"
MONITOR_SCRIPT_PATH="$REAL_HOME/temp_monitor.sh"

NON_INTERACTIVE=false
CLI_BOT_TOKEN=""
CLI_USER_ID=""
CLI_LISTEN_CHANNEL=""
CLI_ALERT_CHANNEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token) CLI_BOT_TOKEN="$2"; shift 2 ;;
        --user-id) CLI_USER_ID="$2"; shift 2 ;;
        --listen-channel) CLI_LISTEN_CHANNEL="$2"; shift 2 ;;
        --alert-channel) CLI_ALERT_CHANNEL="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        *) shift ;;
    esac
done

mkdir -p "$INSTALL_DIR"

# Step 1: Install Dependencies
echo "🔍 Checking dependencies..."
if ! command -v python3 &> /dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y python3 python3-pip -qq
fi

python3 -c "import discord" &> /dev/null || {
    pip3 install discord.py --break-system-packages &> /dev/null || pip3 install discord.py
}

# Step 2: Load Existing Settings
EXISTING_TOKEN=""
EXISTING_USER_ID=""
EXISTING_LISTEN="general"
EXISTING_ALERT="alert"

if [ -f "$CONFIG_FILE" ]; then
    EXISTING_TOKEN=$(grep -E '^BOT_TOKEN=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' || true)
    EXISTING_USER_ID=$(grep -E '^USER_ID=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' || true)
    EXISTING_LISTEN=$(grep -E '^LISTEN_CHANNEL=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' || echo "general")
    EXISTING_ALERT=$(grep -E '^ALERT_CHANNEL=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' || echo "alert")
fi

BOT_TOKEN="${CLI_BOT_TOKEN:-$EXISTING_TOKEN}"
USER_ID="${CLI_USER_ID:-$EXISTING_USER_ID}"
LISTEN_CHANNEL="${CLI_LISTEN_CHANNEL:-$EXISTING_LISTEN}"
ALERT_CHANNEL="${CLI_ALERT_CHANNEL:-$EXISTING_ALERT}"

# Step 3: Whiptail Menu Interface
if [ "$NON_INTERACTIVE" = false ]; then
    if ! command -v whiptail &> /dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y whiptail -qq
    fi

    MENU_ACTIVE=true
    while $MENU_ACTIVE; do
        TOKEN_DISP="${BOT_TOKEN:0:6}..."
        [ -z "$BOT_TOKEN" ] && TOKEN_DISP="Not Set"

        CHOICE=$(whiptail --clear --backtitle "PiTweaks System Configuration" \
            --title "Discord Bot Settings" \
            --menu "Use ARROW keys to highlight an option and press ENTER:" 19 72 6 \
            "1" "Discord User ID  : [$USER_ID]" \
            "2" "Bot Token        : [$TOKEN_DISP]" \
            "3" "Listen Channel   : [$LISTEN_CHANNEL]" \
            "4" "Alert Channel    : [$ALERT_CHANNEL]" \
            "5" "Save and Apply Configuration" \
            "6" "Exit Without Saving" 3>&1 1>&2 2>&3)

        exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "❌ Configuration cancelled."
            exit 0
        fi

        case "$CHOICE" in
            1)
                NEW_ID=$(whiptail --inputbox "Enter Discord User ID (numeric):" 10 60 "$USER_ID" 3>&1 1>&2 2>&3)
                [ $? -eq 0 ] && USER_ID="$NEW_ID"
                ;;
            2)
                NEW_TOK=$(whiptail --passwordbox "Enter Discord Bot Token:" 10 60 "$BOT_TOKEN" 3>&1 1>&2 2>&3)
                [ $? -eq 0 ] && BOT_TOKEN="$NEW_TOK"
                ;;
            3)
                NEW_LISTEN=$(whiptail --inputbox "Enter Listen Channel Name (e.g. general):" 10 60 "$LISTEN_CHANNEL" 3>&1 1>&2 2>&3)
                [ $? -eq 0 ] && LISTEN_CHANNEL="$NEW_LISTEN"
                ;;
            4)
                NEW_ALERT=$(whiptail --inputbox "Enter Alert Channel Name (e.g. alert):" 10 60 "$ALERT_CHANNEL" 3>&1 1>&2 2>&3)
                [ $? -eq 0 ] && ALERT_CHANNEL="$NEW_ALERT"
                ;;
            5)
                MENU_ACTIVE=false
                ;;
            6)
                echo "❌ Configuration cancelled."
                exit 0
                ;;
        esac
    done
fi

# Clean up channel string names (strip leading # or whitespace)
LISTEN_CHANNEL=$(echo "$LISTEN_CHANNEL" | sed 's/^#//' | xargs)
ALERT_CHANNEL=$(echo "$ALERT_CHANNEL" | sed 's/^#//' | xargs)

# Step 4: Write Config File
cat << EOL > "$CONFIG_FILE"
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
LISTEN_CHANNEL="$LISTEN_CHANNEL"
ALERT_CHANNEL="$ALERT_CHANNEL"
MONITOR_SCRIPT="$MONITOR_SCRIPT_PATH"
EOL

chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# Step 5: Write Bot Logic Script
cat << 'EOF' > "$INSTALL_DIR/bot.py"
import os
import sys
import discord
import subprocess
import datetime
import shlex

CONFIG_PATH = os.path.join(os.path.dirname(__file__), "config.env")
config = {}

if os.path.exists(CONFIG_PATH):
    with open(CONFIG_PATH, "r") as f:
        for line in f:
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                config[k] = v.strip('"\'')

BOT_TOKEN = config.get("BOT_TOKEN", "").strip()
USER_ID_STR = config.get("USER_ID", "0").strip()
USER_ID = int(USER_ID_STR) if USER_ID_STR.isdigit() else 0

LISTEN_CHANNEL = config.get("LISTEN_CHANNEL", "general").strip().lstrip('#').lower()
ALERT_CHANNEL = config.get("ALERT_CHANNEL", "alert").strip().lstrip('#').lower()
MONITOR_SCRIPT = os.path.expanduser(config.get("MONITOR_SCRIPT", "~/temp_monitor.sh"))

if not BOT_TOKEN or USER_ID == 0:
    print("❌ Invalid or missing BOT_TOKEN or USER_ID in config.env")
    sys.exit(1)

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

@client.event
async def on_ready():
    print(f'Logged in as {client.user.name}')
    try:
        user = await client.fetch_user(USER_ID)
        await user.send(
            f"🚀 **Raspberry Pi Online!**\n"
            f"• **Listen Channel:** `{LISTEN_CHANNEL}`\n"
            f"• **Alert Channel:** `{ALERT_CHANNEL}`"
        )
    except Exception as e:
        print(f"Could not send boot DM: {e}")

async def cmd_reboot(message, args):
    await message.channel.send("🔄 Rebooting Raspberry Pi...")
    subprocess.run(['sudo', 'reboot'])

async def cmd_shutdown(message, args):
    await message.channel.send("🛑 Shutting down Raspberry Pi...")
    subprocess.run(['sudo', 'shutdown', 'now'])

async def cmd_ping(message, args):
    latency = round(client.latency * 1000)
    await message.channel.send(f"🏓 Pong! Latency: `{latency}ms`")

async def cmd_sysinfo(message, args):
    status_msg = await message.channel.send("🖥️ Gathering system info...")
    try:
        cmd = "uname -a && uptime"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        output = result.stdout.strip() or "System info retrieved with no output."
        await status_msg.edit(content=f"```text\n{output}\n```")
    except Exception as e:
        await status_msg.edit(content=f"❌ Error getting system info: `{e}`")

async def cmd_temp_report(message, args):
    status_msg = await message.channel.send("📊 Generating temperature report...")
    try:
        cmd = f"bash {MONITOR_SCRIPT} temp_report"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        output = result.stdout.strip() or result.stderr.strip() or "Report generated with no output."
        if len(output) > 1900:
            output = output[:1900] + "\n[Output truncated...]"
        await status_msg.edit(content=f"```text\n{output}\n```")
    except Exception as e:
        await status_msg.edit(content=f"❌ Error running command: `{e}`")

async def cmd_test(message, args):
    parts = args.split(" ", 1)
    if len(parts) < 2 or parts[0].lower() not in ["cpu", "ram", "temp"]:
        await message.channel.send("❌ Usage: `!test <cpu|ram|temp> <num>` (e.g., `!test cpu 99`).")
        return

    test_type = parts[0].lower()
    val_str = parts[1].strip()
    if not val_str.isdigit():
        await message.channel.send("❌ Please provide a valid numeric value.")
        return

    value = int(val_str)
    
    # Restored original execution header format
    initial_text = f"Executing {test_type} test with value {value}..."
    status_msg = await message.channel.send(initial_text)

    try:
        cmd = f"bash {MONITOR_SCRIPT} test_{test_type} {value}"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
        output = result.stdout.strip() or result.stderr.strip() or "Command executed successfully with no output."
        
        # Filter out unwanted lines from the monitor script
        clean_lines = [line for line in output.splitlines() if not line.startswith("Running Real")]
        output = "\n".join(clean_lines).strip()

        if len(output) > 1900:
            output = output[:1900] + "\n[Output truncated...]"
        
        # Combine the original header with the raw dashed simulation box
        final_content = f"{initial_text}\n\n{output}"
        await status_msg.edit(content=final_content)
    except Exception as e:
        await status_msg.edit(content=f"❌ Error executing terminal command: `{e}`")

# Explicit aliases for !test_cpu, !test_ram, !test_temp
async def cmd_test_cpu(message, args):
    await cmd_test(message, f"cpu {args}")

async def cmd_test_ram(message, args):
    await cmd_test(message, f"ram {args}")

async def cmd_test_temp(message, args):
    await cmd_test(message, f"temp {args}")

async def cmd_alert(message, args):
    try:
        parts = shlex.split(args)
    except Exception:
        parts = args.split()

    if not parts:
        await message.channel.send("❌ Usage examples:\n`!alert reboot 5`\n`!alert 5 15 \"Custom maintenance notice\"`")
        return

    target_channel = None
    if message.guild:
        for ch in message.guild.text_channels:
            if ch.name.lower() == ALERT_CHANNEL:
                target_channel = ch
                break

    if not target_channel:
        target_channel = message.channel

    now = datetime.datetime.now()

    if parts[0].lower() in ["reboot", "shutdown", "update", "interrupt"]:
        action = parts[0].lower()
        delay_mins = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 5
        start_time = now + datetime.timedelta(minutes=delay_mins)

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
            f"• **Event Classification:** {classification}\n\n"
            f"*{advice}*"
        )
        await target_channel.send(output_msg)

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
        await target_channel.send(output_msg)
    else:
        await message.channel.send("❌ Unknown alert format. Use presets (`reboot`, `shutdown`) or timed windows (`!alert 5 15 \"text\"`).")

async def cmd_help(message, args):
    help_text = (
        "🤖 **Raspberry Pi Bot Commands:**\n"
        "• `!temp_report` - Run system temperature report.\n"
        "• `!test <cpu|ram|temp> <num>` or `!test_cpu <num>` - Run diagnostic tests.\n"
        "• `!ping` - Check bot connection latency.\n"
        "• `!sysinfo` - Display kernel and system info.\n"
        "• `!alert <reboot|shutdown|update|interrupt> <mins>` - Broadcast preset alert to alert channel.\n"
        "• `!alert <delay> <dur> \"text\"` - Broadcast custom alert to alert channel.\n"
        "• `!reboot` - Restart the Raspberry Pi.\n"
        "• `!shutdown` - Shut down the Raspberry Pi.\n"
        "• `!help` - Display this menu."
    )
    await message.channel.send(help_text)

COMMANDS = {
    "reboot": cmd_reboot,
    "shutdown": cmd_shutdown,
    "ping": cmd_ping,
    "sysinfo": cmd_sysinfo,
    "temp_report": cmd_temp_report,
    "test": cmd_test,
    "test_cpu": cmd_test_cpu,
    "test_ram": cmd_test_ram,
    "test_temp": cmd_test_temp,
    "alert": cmd_alert,
    "help": cmd_help
}

@client.event
async def on_message(message):
    if message.author == client.user:
        return

    # User validation
    if message.author.id != USER_ID:
        return

    # Channel check (case-insensitive, ignore DMs)
    if isinstance(message.channel, discord.TextChannel):
        if message.channel.name.lower() != LISTEN_CHANNEL:
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

client.run(BOT_TOKEN)
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR/bot.py"

# Step 6: Reload Systemd Service
sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME.service" << EOL
[Unit]
Description=PiTweaks Discord Bot Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME.service"
sudo systemctl restart "$SERVICE_NAME.service"

echo "✅ Discord Bot updated with all commands restored and service restarted!"
