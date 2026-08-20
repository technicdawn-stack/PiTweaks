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

# Step 3: Interactive TUI Menu (Arrow Keys & Space/Enter Selection)
if [ "$NON_INTERACTIVE" = false ]; then
    python3 - << EOF
import curses
import sys

def run_menu(stdscr):
    curses.curs_set(1)
    stdscr.keypad(True)
    
    fields = [
        {"label": "Discord User ID", "value": "$USER_ID"},
        {"label": "Bot Token      ", "value": "$BOT_TOKEN"},
        {"label": "Alert Channel  ", "value": "$ALERT_CHANNEL"}
    ]
    
    options = ["Save and Exit", "Exit Without Saving"]
    current_row = 0
    
    while True:
        stdscr.clear()
        stdscr.addstr(1, 2, "==========================================", curses.A_BOLD)
        stdscr.addstr(2, 2, " 🤖 PiTweaks Discord Bot Config Menu", curses.A_BOLD)
        stdscr.addstr(3, 2, "==========================================", curses.A_BOLD)
        stdscr.addstr(4, 2, "Use UP/DOWN arrows to navigate. Press ENTER to edit/select.")
        
        row_idx = 6
        for i, f in enumerate(fields):
            prefix = " > " if i == current_row else "   "
            attr = curses.A_REVERSE if i == current_row else curses.A_NORMAL
            val_display = f['value'] if i != 1 else ("*" * len(f['value']) if f['value'] else "")
            stdscr.addstr(row_idx, 2, f"{prefix}{f['label']}: [{val_display}]", attr)
            row_idx += 1
            
        row_idx += 1
        for i, opt in enumerate(options):
            opt_idx = len(fields) + i
            prefix = " > " if opt_idx == current_row else "   "
            attr = curses.A_REVERSE if opt_idx == current_row else curses.A_NORMAL
            stdscr.addstr(row_idx, 2, f"{prefix}[ {opt} ]", attr)
            row_idx += 1
            
        stdscr.refresh()
        key = stdscr.getch()
        
        if key == curses.KEY_UP and current_row > 0:
            current_row -= 1
        elif key == curses.KEY_DOWN and current_row < (len(fields) + len(options) - 1):
            current_row += 1
        elif key in [10, 13]: # Enter key
            if current_row < len(fields):
                # Edit field value
                stdscr.addstr(15, 2, f"Enter new value for {fields[current_row]['label'].strip()}: ")
                curses.echo()
                new_val = stdscr.getstr(15, 45).decode('utf-8').strip()
                curses.noecho()
                if new_val:
                    fields[current_row]['value'] = new_val
            elif current_row == len(fields): # Save and Exit
                with open("/tmp/pitweaks_tui.tmp", "w") as out:
                    out.write(f"USER_ID={fields[0]['value']}\n")
                    out.write(f"BOT_TOKEN={fields[1]['value']}\n")
                    out.write(f"ALERT_CHANNEL={fields[2]['value']}\n")
                sys.exit(0)
            elif current_row == len(fields) + 1: # Exit Without Saving
                sys.exit(1)

try:
    curses.wrapper(run_menu)
except KeyboardInterrupt:
    sys.exit(1)
EOF

    if [ -f "/tmp/pitweaks_tui.tmp" ]; then
        source /tmp/pitweaks_tui.tmp
        rm -f /tmp/pitweaks_tui.tmp
    else
        echo "❌ Configuration cancelled."
        exit 0
    fi
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
