#!/bin/bash

clear

# ==============================================================================
# 🤖 Discord Bot Interactive Installer & Setup
# ==============================================================================
# Automatically resolve the correct user home directory (even if run with sudo)
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

echo "=========================================="
echo " 🤖 Discord Bot Setup & Installer"
echo "=========================================="
echo ""

# Check if already installed (Repair/Upgrade mode)
if [ -f "$INSTALL_DIR/bot.py" ]; then
    echo "⚠️  An existing Discord bot installation was found at:"
    echo "    $INSTALL_DIR"
    echo ""
    read -p "Do you want to upgrade or reconfigure it? [y/N]: " REINSTALL_CHOICE </dev/tty
    echo ""
    
    case "$REINSTALL_CHOICE" in
        [yY]|[yY][eE][sS])
            echo "🔄 Proceeding with upgrade/reconfiguration..."
            echo ""
            ;;
        *)
            echo "❌ Installation cancelled by user."
            exit 0
            ;;
    esac
fi

# ==============================================================================
# 📦 Dependency Checks & Auto-Install / Upgrade
# ==============================================================================
echo "🔍 Checking dependencies..."

if ! command -v python3 &> /dev/null; then
    echo "📦 Python3 not found. Installing..."
    sudo apt update && sudo apt install -y python3
else
    echo "✅ Python3 is installed."
fi

if ! command -v pip3 &> /dev/null; then
    echo "📦 Python3-pip not found. Installing..."
    sudo apt update && sudo apt install -y python3-pip
else
    echo "✅ Pip3 is installed."
fi

echo "📦 Verifying python library (discord.py)..."
python3 -c "import discord" &> /dev/null
if [ $? -ne 0 ]; then
    echo "📦 Installing discord.py..."
    pip3 install discord.py --break-system-packages &> /dev/null || pip3 install discord.py
else
    echo "🔄 Checking for discord.py updates..."
    pip3 install --upgrade discord.py --break-system-packages &> /dev/null || pip3 install --upgrade discord.py
fi

echo ""

# ==============================================================================
# ⚙️ Configuration Setup (With Option to Reuse Old Values)
# ==============================================================================
USE_OLD_CONFIG=false

if [ -f "$CONFIG_FILE" ]; then
    echo "📄 Existing configuration found at: $CONFIG_FILE"
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

    mkdir -p "$INSTALL_DIR"
    cat << EOL > "$CONFIG_FILE"
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
EOL
    chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

mkdir -p "$INSTALL_DIR"

echo "📝 Generating bot script..."

cat << 'EOF' > "$INSTALL_DIR/bot.py"
import discord
import subprocess
import datetime
import shlex

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

# Load config values manually
config = {}
with open("/home/raspi3b/PiTweaks/discord_bot/config.env") as f:
    for line in f:
        if "=" in line:
            k, v = line.strip().split("=", 1)
            config[k] = v.strip('"\'')

YOUR_DISCORD_USER_ID = int(config.get("USER_ID", 0))

# Helper to find a specific channel by name in the server
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
        await message.channel.send("❌ Usage examples:\n`!alert reboot 5`\n`!alert 5 15 \"Custom maintenance notice\"`")
        return

    now = datetime.datetime.now()
    
    # Preset Action Logic
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
        await target_chan.send(output_msg)
        
    # Custom Timed Window Logic
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
        await message.channel.send("❌ Unknown alert command format. Use presets (`reboot`, `shutdown`, `update`, `interrupt`) or timed windows (`!alert 5 15 \"text\"`).")

async def cmd_help(message, args):
    target_chan = get_target_channel(message.guild, "raspi3b") or message.channel
    help_text = (
        "🤖 **Raspberry Pi Bot Commands:**\n"
        "• `!temp_report` - Run system temperature report.\n"
        "• `!test <cpu|ram|temp> <num>` - Run hardware diagnostic tests.\n"
        "• `!alert (reboot|shutdown|update|interrupt) <mins>` - Broadcast a preset alert.\n"
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

chown "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR/bot.py"

# ==============================================================================
# 🔄 Auto-Start on Reboot Configuration (Systemd Service)
# ==============================================================================
echo ""
read -p "Do you want the bot to automatically start on system reboot? [y/N]: " AUTOSTART_CHOICE </dev/tty
echo ""

case "$AUTOSTART_CHOICE" in
    [yY]|[yY][eE][sS])
        echo "⚙️  Setting up background systemd service..."
        
        sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME.service" << EOL
[Unit]
Description=PiTweaks Discord Bot
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/usr/bin/python3 $INSTALL_DIR/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

        sudo systemctl daemon-reload
        sudo systemctl enable $SERVICE_NAME.service
        echo "✅ Auto-start enabled successfully!"
        ;;
    *)
        echo "ℹ️  Skipped auto-start configuration."
        ;;
esac

# ==============================================================================
# 🚀 Service Restart / Launch Prompt
# ==============================================================================
echo ""
read -p "Do you want to restart/start the Discord bot service now? [Y/n]: " RESTART_SERVICE_CHOICE </dev/tty
RESTART_SERVICE_CHOICE=${RESTART_SERVICE_CHOICE:-Y}
echo ""

case "$RESTART_SERVICE_CHOICE" in
    [yY]|[yY][eE][sS])
        if systemctl list-unit-files | grep -q "$SERVICE_NAME.service"; then
            sudo systemctl restart "$SERVICE_NAME.service"
            echo "🚀 Discord bot service restarted successfully!"
        else
            echo "🚀 Starting bot manually..."
            python3 "$INSTALL_DIR/bot.py" &
        fi
        ;;
    *)
        echo "ℹ️  Service restart skipped."
        ;;
esac

echo ""
echo "✅ Installation & update complete!"
echo "📂 Bot installed to: $INSTALL_DIR/bot.py"
