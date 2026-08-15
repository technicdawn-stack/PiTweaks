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
    echo "   $INSTALL_DIR"
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

cat << EOF > "$INSTALL_DIR/bot.py"
import discord
import subprocess

intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

YOUR_DISCORD_USER_ID = $USER_ID

@client.event
async def on_ready():
    print(f'Logged in as {client.user.name}')
    try:
        user = await client.fetch_user(YOUR_DISCORD_USER_ID)
        await user.send("🚀 **Raspberry Pi Booted Successfully!**\nSystem control bot is online and ready.")
    except Exception as e:
        print(f"Could not send boot DM: {e}")

async def cmd_reboot(message, args):
    await message.channel.send("🔄 Rebooting Raspberry Pi...")
    subprocess.run(['sudo', 'reboot'])

async def cmd_shutdown(message, args):
    await message.channel.send("🛑 Shutting down Raspberry Pi...")
    subprocess.run(['sudo', 'shutdown', 'now'])

async def cmd_temp_report(message, args):
    await message.channel.send("📊 Generating system report...")
    try:
        result = subprocess.run("bash ~/temp_monitor.sh", shell=True, capture_output=True, text=True, timeout=30)
        output = result.stdout.strip() or result.stderr.strip() or "Report generated with no output."
        if len(output) > 1900:
            output = output[:1900] + "\n[Output truncated...]"
        await message.channel.send(f"\`\`\`text\n{output}\n\`\`\`")
    except Exception as e:
        await message.channel.send(f"❌ Error running command: \`{e}\`")

async def cmd_test_cpu(message, args):
    if not args.isdigit():
        await message.channel.send("❌ Please provide a valid number (e.g., \`!test_cpu 99\`).")
        return
    value = int(args)
    await message.channel.send(f"⚡ Executing CPU test with value {value}...")
    
    try:
        result = subprocess.run(f"bash ~/temp_monitor.sh test_cpu {value}", shell=True, capture_output=True, text=True, timeout=60)
        output = result.stdout.strip() or result.stderr.strip() or "Command executed successfully with no output."
        if len(output) > 1500:
            output = output[:1500] + "\n[Output truncated...]"
        await message.channel.send(f"✅ \`test_cpu {value}\` finished.\n\`\`\`text\n{output}\n\`\`\`")
    except Exception as e:
        await message.channel.send(f"❌ Error executing terminal command: \`{e}\`")

async def cmd_test_ram(message, args):
    if not args.isdigit():
        await message.channel.send("❌ Please provide a valid number (e.g., \`!test_ram 50\`).")
        return
    value = int(args)
    await message.channel.send(f"🧠 Executing RAM test with value {value}...")
    
    try:
        result = subprocess.run(f"bash ~/temp_monitor.sh test_ram {value}", shell=True, capture_output=True, text=True, timeout=60)
        output = result.stdout.strip() or result.stderr.strip() or "Command executed successfully with no output."
        if len(output) > 1500:
            output = output[:1500] + "\n[Output truncated...]"
        await message.channel.send(f"✅ \`test_ram {value}\` finished.\n\`\`\`text\n{output}\n\`\`\`")
    except Exception as e:
        await message.channel.send(f"❌ Error executing terminal command: \`{e}\`")

async def cmd_test_temp(message, args):
    if not args.isdigit():
        await message.channel.send("❌ Please provide a valid number (e.g., \`!test_temp 75\`).")
        return
    value = int(args)
    await message.channel.send(f"🔥 Executing temp test with value {value}...")
    
    try:
        result = subprocess.run(f"bash ~/temp_monitor.sh test_temp {value}", shell=True, capture_output=True, text=True, timeout=60)
        output = result.stdout.strip() or result.stderr.strip() or "Command executed successfully with no output."
        if len(output) > 1500:
            output = output[:1500] + "\n[Output truncated...]"
        await message.channel.send(f"✅ \`test_temp {value}\` finished.\n\`\`\`text\n{output}\n\`\`\`")
    except Exception as e:
        await message.channel.send(f"❌ Error executing terminal command: \`{e}\`")

async def cmd_help(message, args):
    help_text = (
        "🤖 **Raspberry Pi Bot Commands:**\n"
        "• \`!temp_report\` - Run system temperature report.\n"
        "• \`!test_cpu <num>\` - Run CPU test via temp_monitor.sh.\n"
        "• \`!test_ram <num>\` - Run RAM test via temp_monitor.sh.\n"
        "• \`!test_temp <num>\` - Run temperature threshold check.\n"
        "• \`!reboot\` - Safely restart the Raspberry Pi.\n"
        "• \`!shutdown\` - Safely shut down the Raspberry Pi.\n"
        "• \`!help\` - Display this command menu."
    )
    await message.channel.send(help_text)

COMMANDS = {
    "reboot": cmd_reboot,
    "shutdown": cmd_shutdown,
    "temp_report": cmd_temp_report,
    "test_cpu": cmd_test_cpu,
    "test_ram": cmd_test_ram,
    "test_temp": cmd_test_temp,
    "help": cmd_help
}

@client.event
async def on_message(message):
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
                await message.channel.send(f"❌ Error executing command: \`{e}\`")
        else:
            await message.channel.send(f"❌ Unknown command \`!{cmd_name}\`. Type \`!help\` for options.")

client.run('$BOT_TOKEN')
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
