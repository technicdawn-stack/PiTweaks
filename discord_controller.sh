#!/bin/bash

# ==============================================================================
# 🤖 PiTweaks - Discord Bot Setup & Service Manager (v2 Hardened)
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

# Default flag options
NON_INTERACTIVE=false
CLI_BOT_TOKEN=""
CLI_USER_ID=""

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --token) CLI_BOT_TOKEN="$2"; shift 2 ;;
        --user-id) CLI_USER_ID="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        *) shift ;;
    esac
done

echo "=========================================="
echo " 🤖 Discord Bot Setup & Installer (v2)"
echo "=========================================="
echo ""

# Ensure Target Directory Exists
mkdir -p "$INSTALL_DIR"

# Step 1: Install System Dependencies
echo "🔍 Checking dependencies..."
if ! command -v python3 &> /dev/null; then
    sudo apt update -qq && sudo apt install -y python3 python3-pip python3-discord -qq
fi

# Fallback install for discord.py if APT package isn't present
python3 -c "import discord" &> /dev/null || {
    pip3 install discord.py --break-system-packages &> /dev/null || pip3 install discord.py
}

# Step 2: Load / Merge Configuration (Preserving Existing Credentials)
EXISTING_TOKEN=""
EXISTING_USER_ID=""

if [ -f "$CONFIG_FILE" ]; then
    echo "📄 Existing configuration detected."
    # Preserve legacy variables
    EXISTING_TOKEN=$(grep -E '^BOT_TOKEN=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' || true)
    EXISTING_USER_ID=$(grep -E '^USER_ID=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"' || true)
fi

# Resolve final settings using precedence: CLI Flags > Config File > Interactive Prompt
BOT_TOKEN="${CLI_BOT_TOKEN:-$EXISTING_TOKEN}"
USER_ID="${CLI_USER_ID:-$EXISTING_USER_ID}"

if [ "$NON_INTERACTIVE" = false ]; then
    if [ -n "$BOT_TOKEN" ]; then
        read -p "Reuse existing Bot Token? [Y/n]: " REUSE_TOK </dev/tty
        if [[ "$REUSE_TOK" =~ ^[nN] ]]; then BOT_TOKEN=""; fi
    fi
    
    if [ -z "$BOT_TOKEN" ]; then
        read -sp "Enter your Discord Bot Token: " BOT_TOKEN </dev/tty
        echo ""
    fi

    if [ -z "$USER_ID" ]; then
        read -p "Enter your Discord User ID (numeric): " USER_ID </dev/tty
    fi
fi

# Validate User ID
if ! [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: Discord User ID must be numeric."
    exit 1
fi

# Persist Secure Credentials
cat << EOL > "$CONFIG_FILE"
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
MONITOR_SCRIPT="$MONITOR_SCRIPT_PATH"
EOL

chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
echo "✅ Credentials securely saved to $CONFIG_FILE"

# Step 3: Write Hardened bot.py
cat << 'EOF' > "$INSTALL_DIR/bot.py"
import os
import sys
import shlex
import discord
import subprocess
import datetime

# Load Config File
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
MONITOR_SCRIPT = config.get("MONITOR_SCRIPT", os.path.expanduser("~/temp_monitor.sh"))

if not BOT_TOKEN or not USER_ID:
    print("❌ Critical Failure: Missing credentials in config.env")
    sys.exit(1)

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

@client.event
async def on_ready():
    print(f'Logged in as {client.user.name}')
    try:
        user = await client.fetch_user(USER_ID)
        await user.send("🚀 **Raspberry Pi Online!**\nSystem control daemon active.")
    except Exception as e:
        print(f"DM Notification Failed: {e}")

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
        await message.channel.send(f"❌ Error executing report: `{e}`")

async def cmd_test(message, args):
    parts = args.split(" ", 1)
    if len(parts) < 2 or parts[0].lower() not in ["cpu", "ram", "temp"]:
        await message.channel.send("❌ Usage: `!test <cpu|ram|temp> <num>`")
        return
    
    test_type = parts[0].lower()
    val_str = parts[1].strip()
    if not val_str.isdigit():
        await message.channel.send("❌ Value must be numeric.")
        return
        
    await message.channel.send(f"⚡ Executing {test_type} test with value {val_str}...")
    try:
        result = subprocess.run(
            ['bash', MONITOR_SCRIPT, f'test_{test_type}', val_str],
            capture_output=True, text=True, timeout=60
        )
        output = result.stdout.strip() or result.stderr.strip() or "Execution finished."
        if len(output) > 1500:
            output = output[:1500] + "\n[Output truncated...]"
        await message.channel.send(f"✅ Executed `test_{test_type}`:\n```text\n{output}\n```")
    except Exception as e:
        await message.channel.send(f"❌ Command Error: `{e}`")

COMMANDS = {
    "reboot": cmd_reboot,
    "shutdown": cmd_shutdown,
    "temp_report": cmd_temp_report,
    "test": cmd_test
}

@client.event
async def on_message(message):
    if message.author == client.user or message.author.id != USER_ID:
        return

    if message.content.startswith("!"):
        parts = message.content[1:].split(" ", 1)
        cmd_name = parts[0].lower()
        args = parts[1].strip() if len(parts) > 1 else ""

        if cmd_name in COMMANDS:
            try:
                await COMMANDS[cmd_name](message, args)
            except Exception as e:
                await message.channel.send(f"❌ Execution Error: `{e}`")

client.run(BOT_TOKEN)
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR/bot.py"

# Step 4: Systemd Service Registration
echo "⚙️ Configuring systemd daemon..."
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

echo "✅ Discord Bot Controller updated and running!"
