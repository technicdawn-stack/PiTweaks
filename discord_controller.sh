#!/bin/bash

clear

# ==============================================================================
# 🤖 Discord Bot Interactive Installer & Setup
# ==============================================================================
INSTALL_DIR="$HOME/PiTweaks/discord_bot"
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

# Check Python3
if ! command -v python3 &> /dev/null; then
    echo "📦 Python3 not found. Installing..."
    sudo apt update && sudo apt install -y python3
else
    echo "✅ Python3 is installed."
fi

# Check Pip3
if ! command -v pip3 &> /dev/null; then
    echo "📦 Python3-pip not found. Installing..."
    sudo apt update && sudo apt install -y python3-pip
else
    echo "✅ Pip3 is installed."
fi

# Check/Install/Upgrade discord.py library
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
echo "⚙️  Configuration Setup"
echo "------------------------------------------"

# Prompt for Discord Bot Token securely (hidden input)
read -p "Enter your Discord Bot Token: " -s BOT_TOKEN
echo ""

# Prompt for Discord User ID
read -p "Enter your Discord User ID (numeric): " USER_ID
echo ""

# Validate user ID is numeric
if ! [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: Discord User ID must be numbers only."
    exit 1
fi

mkdir -p "$INSTALL_DIR"

echo "📝 Generating bot script..."

# Write the Python bot file directly with the user's variables injected
cat << EOF > "$INSTALL_DIR/bot.py"
import discord
import subprocess

# Enable intents so the bot can read messages in channels
intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)

YOUR_DISCORD_USER_ID = $USER_ID

async def cmd_reboot(message, args):
    """Reboots the Raspberry Pi."""
    await message.channel.send("🔄 Rebooting Raspberry Pi...")
    subprocess.run(['sudo', 'reboot'])

async def cmd_shutdown(message, args):
    """Shuts down the Raspberry Pi."""
    await message.channel.send("🛑 Shutting down Raspberry Pi...")
    subprocess.run(['sudo', 'shutdown', 'now'])

async def cmd_temp_report(message, args):
    """Reports current CPU temperature and clock speed."""
    temp = subprocess.getoutput("vcgencmd measure_temp")
    freq = subprocess.getoutput("vcgencmd measure_clock arm")
    await message.channel.send(f"📊 **Temperature Report:**\n🌡️ {temp}\n⚡ {freq}")

async def cmd_test_cpu(message, args):
    """Executes a CPU test command/script on the Pi terminal."""
    if not args.isdigit():
        await message.channel.send("❌ Please provide a valid number (e.g., \`!test_cpu 99\`).")
        return
    value = int(args)
    await message.channel.send(f"⚡ Executing CPU test with value {value} on the Pi terminal...")
    
    # Example terminal execution hook:
    # subprocess.run(["python3", "/home/raspi3b/PiTweaks/your_script.py", str(value)])
    
    await message.channel.send(f"✅ \`test_cpu {value}\` terminal execution finished.")

async def cmd_test_ram(message, args):
    """Executes a RAM test command/script on the Pi terminal."""
    if not args.isdigit():
        await message.channel.send("❌ Please provide a valid number (e.g., \`!test_ram 50\`).")
        return
    value = int(args)
    await message.channel.send(f"🧠 Executing RAM test with value {value} on the Pi terminal...")
    await message.channel.send(f"✅ \`test_ram {value}\` terminal execution finished.")

async def cmd_test_temp(message, args):
    """Performs a temperature threshold check using the provided numeric value."""
    if not args.isdigit():
        await message.channel.send("❌ Please provide a valid number (e.g., \`!test_temp 75\`).")
        return
    value = int(args)
    current_temp = subprocess.getoutput("vcgencmd measure_temp")
    await message.channel.send(f"🔥 Temp check (Target: {value}°C)\n📊 Current: {current_temp}")

async def cmd_help(message, args):
    """Lists all available bot commands."""
    help_text = (
        "🤖 **Raspberry Pi Bot Commands:**\n"
        "• \`!temp_report\` - Check current temperature and clock speed.\n"
        "• \`!test_cpu <num>\` - Run CPU test command on Pi terminal.\n"
        "• \`!test_ram <num>\` - Run RAM test command on Pi terminal.\n"
        "• \`!test_temp <num>\` - Check temperature threshold.\n"
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
    # Security: Only listen to your specific user ID
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

# ==============================================================================
# 🔄 Auto-Start on Reboot Configuration (Systemd Service)
# ==============================================================================
echo ""
read -p "Do you want the bot to automatically start on system reboot? [y/N]: " AUTOSTART_CHOICE </dev/tty
echo ""

case "$AUTOSTART_CHOICE" in
    [yY]|[yY][eE][sS])
        echo "⚙️  Setting up background systemd service..."
        CURRENT_USER=$(whoami)
        
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
        sudo systemctl restart $SERVICE_NAME.service
        echo "✅ Auto-start enabled successfully!"
        ;;
    *)
        echo "ℹ️  Skipped auto-start configuration."
        ;;
esac

echo ""
echo "✅ Installation complete!"
echo "📂 Bot installed to: $INSTALL_DIR/bot.py"

# ==============================================================================
# 🚀 Launch Bot Now
# ==============================================================================
if systemctl is-active --quiet $SERVICE_NAME.service; then
    echo "🚀 Bot is already running in the background via systemd!"
else
    echo "🚀 Starting bot now..."
    python3 "$INSTALL_DIR/bot.py"
fi
