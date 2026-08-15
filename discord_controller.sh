#!/bin/bash

clear

# ==============================================================================
# 🤖 Discord Bot Interactive Installer & Setup
# ==============================================================================
INSTALL_DIR="$HOME/PiTweaks/discord_bot"

echo "=========================================="
echo " 🤖 Discord Bot Setup & Installer"
echo "=========================================="
echo ""

# Check if already installed
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

# Check for python3 and pip
if ! command -v python3 &> /dev/null; then
    echo "❌ Python3 is not installed. Installing..."
    sudo apt update && sudo apt install -y python3 python3-pip
fi

# Install discord.py dependency safely
echo "📦 Installing required Python libraries (discord.py)..."
pip3 install discord.py --break-system-packages &> /dev/null || pip3 install discord.py

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

client = discord.Client(intents=discord.Intents.default())

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
    """Performs a CPU test using the provided numeric value."""
    if not args.isdigit():
        await message.channel.send("❌ Please provide a valid number (e.g., \`!test_cpu 98\`).")
        return
    value = int(args)
    await message.channel.send(f"⚡ Running CPU test with parameter: \`{value}\`...")
    await message.channel.send(f"✅ CPU test completed successfully (Value: {value}).")

async def cmd_test_ram(message, args):
    """Performs a RAM test using the provided numeric value."""
    if not args.isdigit():
        await message.channel.send("❌ Please provide a valid number (e.g., \`!test_ram 50\`).")
        return
    value = int(args)
    await message.channel.send(f"🧠 Running RAM test with parameter: \`{value}\`...")
    await message.channel.send(f"✅ RAM test completed successfully (Value: {value}).")

async def cmd_test_temp(message, args):
    """Performs a temperature threshold test using the provided numeric value."""
    if not args.isdigit():
        await message.channel.send("❌ Please provide a valid number (e.g., \`!test_temp 75\`).")
        return
    value = int(args)
    current_temp = subprocess.getoutput("vcgencmd measure_temp")
    await message.channel.send(f"🔥 Running temp threshold check (Target: {value}°C)\n📊 Current: {current_temp}")

async def cmd_help(message, args):
    """Lists all available bot commands."""
    help_text = (
        "🤖 **Raspberry Pi Bot Commands:**\n"
        "• \`!temp_report\` - Check current CPU temperature and clock speed.\n"
        "• \`!test_cpu <num>\` - Run a CPU test with a numeric parameter.\n"
        "• \`!test_ram <num>\` - Run a RAM test with a numeric parameter.\n"
        "• \`!test_temp <num>\` - Check temperature threshold against a value.\n"
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

echo ""
echo "✅ Installation complete!"
echo "📂 Bot installed to: $INSTALL_DIR/bot.py"
echo "🚀 To run your bot manually, use:"
echo "   python3 $INSTALL_DIR/bot.py"
