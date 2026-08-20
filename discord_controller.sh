#!/bin/bash

# ==============================================================================
# 🤖 PiTweaks - Discord Bot Setup with TUI Menu & Channel Restriction
# ==============================================================================

set -e

# Resolve execution user and paths
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
CLI_ALERT_CHANNEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token) CLI_BOT_TOKEN="$2"; shift 2 ;;
        --user-id) CLI_USER_ID="$2"; shift 2 ;;
        --channel) CLI_ALERT_CHANNEL="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        *) shift ;;
    esac
done

mkdir -p "$INSTALL_DIR"

# Step 1: Install System Dependencies
if ! command -v python3 &> /dev/null; then
    sudo apt update -qq && sudo apt install -y python3 python3-pip python3-discord -qq
fi

python3 -c "import discord" &> /dev/null || {
    pip3 install discord.py --break-system-packages &> /dev/null || pip3 install discord.py
}

# Step 2: Read Existing Config Values (Backwards Compatibility)
EXISTING_TOKEN=""
EXISTING_USER_ID=""
EXISTING_CHANNEL="alert"

if [ -f "$CONFIG_FILE" ]; then
    EXISTING_TOKEN=$(grep -E '^BOT_TOKEN=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' || true)
    EXISTING_USER_ID=$(grep -E '^USER_ID=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' || true)
    EXISTING_CHANNEL=$(grep -E '^ALERT_CHANNEL=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' || "alert")
fi

BOT_TOKEN="${CLI_BOT_TOKEN:-$EXISTING_TOKEN}"
USER_ID="${CLI_USER_ID:-$EXISTING_USER_ID}"
ALERT_CHANNEL="${CLI_ALERT_CHANNEL:-$EXISTING_CHANNEL}"

# Step 3: Native raspi-config Style Whiptail Menu
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
            --menu "Use ARROW keys to select an option and press ENTER:" 18 70 5 \
            "1 User ID" "Current: $USER_ID" \
            "2 Bot Token" "Current: $TOKEN_DISP" \
            "3 Channel" "Current: $ALERT_CHANNEL" \
            "4 Save" "Save settings and apply configuration" \
            "5 Cancel" "Exit setup without saving" 3>&1 1>&2 2>&3)

        exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "❌ Configuration cancelled."
            exit 0
        fi

        case "$CHOICE" in
            "1 User ID")
                NEW_ID=$(whiptail --inputbox "Enter Discord User ID (numeric):" 10 60 "$USER_ID" 3>&1 1>&2 2>&3)
                [ $? -eq 0 ] && USER_ID="$NEW_ID"
                ;;
            "2 Bot Token")
                NEW_TOK=$(whiptail --passwordbox "Enter Discord Bot Token:" 10 60 "$BOT_TOKEN" 3>&1 1>&2 2>&3)
                [ $? -eq 0 ] && BOT_TOKEN="$NEW_TOK"
                ;;
            "3 Channel")
                NEW_CHAN=$(whiptail --inputbox "Enter Alert Channel Name:" 10 60 "$ALERT_CHANNEL" 3>&1 1>&2 2>&3)
                [ $? -eq 0 ] && ALERT_CHANNEL="$NEW_CHAN"
                ;;
            "4 Save")
                MENU_ACTIVE=false
                ;;
            "5 Cancel")
                echo "❌ Configuration cancelled."
                exit 0
                ;;
        esac
    done
fi

# Step 4: Persist Settings to config.env
cat << EOL > "$CONFIG_FILE"
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
ALERT_CHANNEL="$ALERT_CHANNEL"
MONITOR_SCRIPT="$MONITOR_SCRIPT_PATH"
EOL

chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# Step 5: Write Hardened bot.py with Channel Check
cat << 'EOF' > "$INSTALL_DIR/bot.py"
import os
import sys
import discord
import subprocess

CONFIG_PATH = os.path.join(os.path.dirname(__file__), "config.env")
config = {}

if os.path.exists(CONFIG_PATH):
    with open(CONFIG_PATH, "r") as f:
        for line in f:
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                config[k] = v.strip('"\'')

BOT_TOKEN = config.get("BOT_TOKEN")
USER_ID = int(config.get("USER_ID", 0))
ALERT_CHANNEL = config.get("ALERT_CHANNEL", "alert")
MONITOR_SCRIPT = config.get("MONITOR_SCRIPT", os.path.expanduser("~/temp_monitor.sh"))

if not BOT_TOKEN or not USER_ID:
    print("❌ Missing credentials in config.env")
    sys.exit(1)

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

@client.event
async def on_ready():
    print(f'Logged in as {client.user.name}')
    try:
        user = await client.fetch_user(USER_ID)
        await user.send(f"🚀 **Raspberry Pi Online!**\nListening on channel: `{ALERT_CHANNEL}`")
    except Exception as e:
        print(f"DM Failed: {e}")

async def cmd_reboot(message, args):
    await message.channel.send("🔄 Rebooting Raspberry Pi...")
    subprocess.run(['sudo', 'reboot'])

async def cmd_shutdown(message, args):
    await message.channel.send("🛑 Shutting down Raspberry Pi...")
    subprocess.run(['sudo', 'shutdown', 'now'])

async def cmd_temp_report(message, args):
    await message.channel.send("📊 Generating system report...")
    try:
        result = subprocess.run(
            ['bash', MONITOR_SCRIPT, 'temp_report'],
            capture_output=True, text=True, timeout=30
        )
        output = result.stdout.strip() or result.stderr.strip() or "No output returned."
        if len(output) > 1900:
            output = output[:1900] + "\n[Output truncated...]"
        await message.channel.send(f"```text\n{output}\n```")
    except Exception as e:
        await message.channel.send(f"❌ Error: `{e}`")

COMMANDS = {
    "reboot": cmd_reboot,
    "shutdown": cmd_shutdown,
    "temp_report": cmd_temp_report
}

@client.event
async def on_message(message):
    if message.author == client.user or message.author.id != USER_ID:
        return

    # Restrict execution exclusively to configured channel or direct messages
    if isinstance(message.channel, discord.TextChannel) and message.channel.name != ALERT_CHANNEL:
        return

    if message.content.startswith("!"):
        parts = message.content[1:].split(" ", 1)
        cmd_name = parts[0].lower()
        args = parts[1].strip() if len(parts) > 1 else ""

        if cmd_name in COMMANDS:
            try:
                await COMMANDS[cmd_name](message, args)
            except Exception as e:
                await message.channel.send(f"❌ Error: `{e}`")

client.run(BOT_TOKEN)
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR/bot.py"

# Step 6: Systemd Unit Creation
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

echo "✅ Discord Bot configured and started!"
