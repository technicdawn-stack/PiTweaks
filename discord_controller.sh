#!/bin/bash

# Description: Discord bot installer
# PERSISTENT: FALSE
# Category: Discord

# ==============================================================================
# PiTweaks - Discord Bot Installer
# ==============================================================================

set -euo pipefail

# ==============================================================================
# USER / PATH CONFIGURATION
# ==============================================================================

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    CURRENT_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
else
    CURRENT_USER="$(id -un)"
    REAL_HOME="$HOME"
fi

if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
    echo "Error: Could not determine the user's home directory."
    exit 1
fi

INSTALL_DIR="$REAL_HOME/PiTweaks/discord_bot"
CONFIG_FILE="$INSTALL_DIR/config.env"
SERVICE_NAME="pitweaks-discord-bot"
MONITOR_SCRIPT_PATH="$REAL_HOME/temp_monitor.sh"

mkdir -p "$INSTALL_DIR"
chown "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"

# ==============================================================================
# CLI OPTIONS
# ==============================================================================

NON_INTERACTIVE=false
CLI_BOT_TOKEN=""
CLI_USER_ID=""
CLI_LISTEN_CHANNEL=""
CLI_ALERT_CHANNEL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)
            [[ $# -ge 2 ]] || {
                echo "Error: --token requires a value."
                exit 1
            }
            CLI_BOT_TOKEN="$2"
            shift 2
            ;;

        --user-id)
            [[ $# -ge 2 ]] || {
                echo "Error: --user-id requires a value."
                exit 1
            }
            CLI_USER_ID="$2"
            shift 2
            ;;

        --listen-channel)
            [[ $# -ge 2 ]] || {
                echo "Error: --listen-channel requires a value."
                exit 1
            }
            CLI_LISTEN_CHANNEL="$2"
            shift 2
            ;;

        --alert-channel)
            [[ $# -ge 2 ]] || {
                echo "Error: --alert-channel requires a value."
                exit 1
            }
            CLI_ALERT_CHANNEL="$2"
            shift 2
            ;;

        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;

        *)
            echo "Warning: Unknown option ignored: $1"
            shift
            ;;
    esac
done

# ==============================================================================
# HELPERS
# ==============================================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

trim_channel() {
    printf '%s' "$1" |
        sed 's/^[[:space:]]*#//' |
        xargs
}

valid_user_id() {
    [[ "$1" =~ ^[0-9]{5,25}$ ]]
}

valid_channel() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]{1,100}$ ]]
}

mask_token() {
    local token="$1"

    if [[ -z "$token" ]]; then
        printf '%s' "Not Set"
    elif (( ${#token} <= 10 )); then
        printf '%s' "********"
    else
        printf '%s...' "${token:0:6}"
    fi
}

# ==============================================================================
# DEPENDENCIES
# ==============================================================================

echo "Checking dependencies..."

if ! command_exists python3; then
    echo "Installing Python 3..."
    sudo apt-get update -qq
    sudo apt-get install -y python3 python3-pip -qq
fi

if ! command_exists whiptail && [[ "$NON_INTERACTIVE" == false ]]; then
    echo "Installing whiptail..."
    sudo apt-get update -qq
    sudo apt-get install -y whiptail -qq
fi

# ==============================================================================
# PYTHON DISCORD DEPENDENCY
# ==============================================================================

if ! python3 -c "import discord" >/dev/null 2>&1; then
    echo "Installing discord.py..."

    if python3 -m pip install discord.py --break-system-packages >/dev/null 2>&1; then
        :
    elif python3 -m pip install discord.py >/dev/null 2>&1; then
        :
    else
        echo "Error: Could not install discord.py."
        exit 1
    fi
fi

# ==============================================================================
# LOAD EXISTING CONFIGURATION
# ==============================================================================

EXISTING_TOKEN=""
EXISTING_USER_ID=""
EXISTING_LISTEN="general"
EXISTING_ALERT="alert"

if [[ -f "$CONFIG_FILE" ]]; then

    EXISTING_TOKEN=$(
        sed -n 's/^BOT_TOKEN="\([^"]*\)".*/\1/p' "$CONFIG_FILE" |
        head -n1
    )

    EXISTING_USER_ID=$(
        sed -n 's/^USER_ID="\([^"]*\)".*/\1/p' "$CONFIG_FILE" |
        head -n1
    )

    EXISTING_LISTEN=$(
        sed -n 's/^LISTEN_CHANNEL="\([^"]*\)".*/\1/p' "$CONFIG_FILE" |
        head -n1
    )

    EXISTING_ALERT=$(
        sed -n 's/^ALERT_CHANNEL="\([^"]*\)".*/\1/p' "$CONFIG_FILE" |
        head -n1
    )

    [[ -n "$EXISTING_LISTEN" ]] || EXISTING_LISTEN="general"
    [[ -n "$EXISTING_ALERT" ]] || EXISTING_ALERT="alert"
fi

BOT_TOKEN="${CLI_BOT_TOKEN:-$EXISTING_TOKEN}"
USER_ID="${CLI_USER_ID:-$EXISTING_USER_ID}"
LISTEN_CHANNEL="${CLI_LISTEN_CHANNEL:-$EXISTING_LISTEN}"
ALERT_CHANNEL="${CLI_ALERT_CHANNEL:-$EXISTING_ALERT}"

LISTEN_CHANNEL=$(trim_channel "$LISTEN_CHANNEL")
ALERT_CHANNEL=$(trim_channel "$ALERT_CHANNEL")

# ==============================================================================
# INTERACTIVE CONFIGURATION
# ==============================================================================

if [[ "$NON_INTERACTIVE" == false ]]; then

    MENU_ACTIVE=true

    while "$MENU_ACTIVE"; do

        TOKEN_DISPLAY=$(mask_token "$BOT_TOKEN")

        CHOICE=$(
            whiptail \
                --clear \
                --backtitle "PiTweaks  |  Discord Integration" \
                --title "Discord Bot Configuration" \
                --menu \
                "Configure the Discord bot. Select an option:" \
                18 \
                76 \
                7 \
                "USER" \
                "Discord User ID       ${USER_ID:-Not Set}" \
                "TOKEN" \
                "Bot Token             ${TOKEN_DISPLAY}" \
                "LISTEN" \
                "Listen Channel        #${LISTEN_CHANNEL:-Not Set}" \
                "ALERT" \
                "Alert Channel         #${ALERT_CHANNEL:-Not Set}" \
                "SAVE" \
                "Save & Apply Configuration" \
                "EXIT" \
                "Exit Without Saving" \
                3>&1 1>&2 2>&3
        ) || {
            # Esc = return/leave the configuration screen.
            clear
            echo "Configuration cancelled."
            exit 0
        }

        case "$CHOICE" in

            USER)
                while true; do

                    NEW_ID=$(
                        whiptail \
                            --inputbox \
                            "Enter your Discord User ID.

It must be a numeric Discord user ID." \
                            11 \
                            65 \
                            "$USER_ID" \
                            3>&1 1>&2 2>&3
                    ) || break

                    if valid_user_id "$NEW_ID"; then
                        USER_ID="$NEW_ID"
                        break
                    fi

                    whiptail \
                        --title "Invalid User ID" \
                        --msgbox \
                        "The Discord User ID must contain only numbers.

Please check the ID and try again." \
                        9 \
                        60
                done
                ;;

            TOKEN)
                NEW_TOKEN=$(
                    whiptail \
                        --passwordbox \
                        "Enter your Discord Bot Token.

The token will be stored with restricted permissions." \
                        11 \
                        70 \
                        "" \
                        3>&1 1>&2 2>&3
                ) || continue

                if [[ -n "$NEW_TOKEN" ]]; then
                    BOT_TOKEN="$NEW_TOKEN"
                else
                    whiptail \
                        --title "Token Not Changed" \
                        --msgbox \
                        "No token was entered.

The existing token has been kept." \
                        8 \
                        55
                fi
                ;;

            LISTEN)
                while true; do

                    NEW_LISTEN=$(
                        whiptail \
                            --inputbox \
                            "Enter the Discord channel the bot should listen on.

Example:
general

The leading # is optional." \
                            12 \
                            68 \
                            "$LISTEN_CHANNEL" \
                            3>&1 1>&2 2>&3
                    ) || break

                    NEW_LISTEN=$(trim_channel "$NEW_LISTEN")

                    if valid_channel "$NEW_LISTEN"; then
                        LISTEN_CHANNEL="$NEW_LISTEN"
                        break
                    fi

                    whiptail \
                        --title "Invalid Channel" \
                        --msgbox \
                        "Channel names may contain:

• Letters
• Numbers
• Hyphens
• Underscores

Please try again." \
                        11 \
                        60
                done
                ;;

            ALERT)
                while true; do

                    NEW_ALERT=$(
                        whiptail \
                            --inputbox \
                            "Enter the Discord channel used for alerts.

Example:
alert

The leading # is optional." \
                            12 \
                            68 \
                            "$ALERT_CHANNEL" \
                            3>&1 1>&2 2>&3
                    ) || break

                    NEW_ALERT=$(trim_channel "$NEW_ALERT")

                    if valid_channel "$NEW_ALERT"; then
                        ALERT_CHANNEL="$NEW_ALERT"
                        break
                    fi

                    whiptail \
                        --title "Invalid Channel" \
                        --msgbox \
                        "Channel names may contain:

• Letters
• Numbers
• Hyphens
• Underscores

Please try again." \
                        11 \
                        60
                done
                ;;

            SAVE)
                if [[ -z "$BOT_TOKEN" ]]; then
                    whiptail \
                        --title "Configuration Incomplete" \
                        --msgbox \
                        "A Discord Bot Token is required before the bot can start." \
                        8 \
                        60
                    continue
                fi

                if ! valid_user_id "$USER_ID"; then
                    whiptail \
                        --title "Configuration Incomplete" \
                        --msgbox \
                        "A valid numeric Discord User ID is required." \
                        8 \
                        60
                    continue
                fi

                if ! valid_channel "$LISTEN_CHANNEL"; then
                    whiptail \
                        --title "Configuration Incomplete" \
                        --msgbox \
                        "The listen channel name is invalid." \
                        8 \
                        60
                    continue
                fi

                if ! valid_channel "$ALERT_CHANNEL"; then
                    whiptail \
                        --title "Configuration Incomplete" \
                        --msgbox \
                        "The alert channel name is invalid." \
                        8 \
                        60
                    continue
                fi

                MENU_ACTIVE=false
                ;;

            EXIT)
                clear
                echo "Configuration cancelled."
                exit 0
                ;;

        esac
    done
fi

# ==============================================================================
# FINAL VALIDATION
# ==============================================================================

LISTEN_CHANNEL=$(trim_channel "$LISTEN_CHANNEL")
ALERT_CHANNEL=$(trim_channel "$ALERT_CHANNEL")

if [[ -z "$BOT_TOKEN" ]]; then
    echo "Error: Discord Bot Token is not configured."
    exit 1
fi

if ! valid_user_id "$USER_ID"; then
    echo "Error: Invalid Discord User ID."
    exit 1
fi

if ! valid_channel "$LISTEN_CHANNEL"; then
    echo "Error: Invalid listen channel."
    exit 1
fi

if ! valid_channel "$ALERT_CHANNEL"; then
    echo "Error: Invalid alert channel."
    exit 1
fi

# ==============================================================================
# WRITE CONFIGURATION
# ==============================================================================

umask 077

cat > "$CONFIG_FILE" <<EOF
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
LISTEN_CHANNEL="$LISTEN_CHANNEL"
ALERT_CHANNEL="$ALERT_CHANNEL"
MONITOR_SCRIPT="$MONITOR_SCRIPT_PATH"
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# ==============================================================================
# WRITE BOT
# ==============================================================================

cat > "$INSTALL_DIR/bot.py" <<'PYEOF'
import os
import sys
import discord
import subprocess
import datetime
import shlex


# ==============================================================================
# CONFIGURATION
# ==============================================================================

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.env")


def load_config(path):
    config = {}

    if not os.path.isfile(path):
        return config

    try:
        with open(path, "r", encoding="utf-8") as config_file:
            for raw_line in config_file:
                line = raw_line.strip()

                if not line or line.startswith("#") or "=" not in line:
                    continue

                key, value = line.split("=", 1)

                key = key.strip()
                value = value.strip()

                if (
                    len(value) >= 2
                    and value[0] == '"'
                    and value[-1] == '"'
                ):
                    value = value[1:-1]

                config[key] = value

    except OSError as exc:
        print(f"Could not read configuration: {exc}")
        sys.exit(1)

    return config


config = load_config(CONFIG_PATH)

BOT_TOKEN = config.get("BOT_TOKEN", "").strip()
USER_ID_STR = config.get("USER_ID", "").strip()
LISTEN_CHANNEL = (
    config.get("LISTEN_CHANNEL", "general")
    .strip()
    .lstrip("#")
    .lower()
)
ALERT_CHANNEL = (
    config.get("ALERT_CHANNEL", "alert")
    .strip()
    .lstrip("#")
    .lower()
)
MONITOR_SCRIPT = os.path.expanduser(
    config.get("MONITOR_SCRIPT", "~/temp_monitor.sh")
)


if not BOT_TOKEN:
    print("Error: BOT_TOKEN is missing.")
    sys.exit(1)


if not USER_ID_STR.isdigit():
    print("Error: USER_ID is invalid.")
    sys.exit(1)


USER_ID = int(USER_ID_STR)


# ==============================================================================
# SECURITY / EXECUTION HELPERS
# ==============================================================================

def run_monitor_command(*args, timeout=30):
    """
    Execute the configured monitor script without invoking a shell.
    """

    script_path = os.path.abspath(os.path.expanduser(MONITOR_SCRIPT))

    if not os.path.isfile(script_path):
        raise FileNotFoundError(
            f"Monitor script not found: {script_path}"
        )

    if not os.access(script_path, os.X_OK):
        raise PermissionError(
            f"Monitor script is not executable: {script_path}"
        )

    command = [script_path, *args]

    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def truncate_output(output, limit=1900):
    output = output.strip()

    if len(output) <= limit:
        return output

    return output[:limit - 30] + "\n[Output truncated...]"


# ==============================================================================
# DISCORD CLIENT
# ==============================================================================

intents = discord.Intents.default()
intents.message_content = True

client = discord.Client(intents=intents)


# ==============================================================================
# EVENTS
# ==============================================================================

@client.event
async def on_ready():
    print(f"Logged in as {client.user}")

    try:
        user = await client.fetch_user(USER_ID)

        await user.send(
            "Raspberry Pi Online!\n"
            f"• Listen Channel: `{LISTEN_CHANNEL}`\n"
            f"• Alert Channel: `{ALERT_CHANNEL}`"
        )

    except Exception as exc:
        print(f"Could not send boot DM: {exc}")


# ==============================================================================
# COMMANDS
# ==============================================================================

async def cmd_reboot(message, args):
    await message.channel.send(
        "Rebooting Raspberry Pi..."
    )

    subprocess.run(
        ["sudo", "reboot"],
        check=False
    )


async def cmd_shutdown(message, args):
    await message.channel.send(
        "Shutting down Raspberry Pi..."
    )

    subprocess.run(
        ["sudo", "shutdown", "now"],
        check=False
    )


async def cmd_ping(message, args):
    latency = round(client.latency * 1000)

    await message.channel.send(
        f"Pong! Latency: `{latency}ms`"
    )


async def cmd_sysinfo(message, args):
    status_msg = await message.channel.send(
        "Gathering system information..."
    )

    try:
        result = subprocess.run(
            ["bash", "-c", "uname -a && uptime"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

        output = (
            result.stdout.strip()
            or result.stderr.strip()
            or "No system information was returned."
        )

        output = truncate_output(output)

        await status_msg.edit(
            content=f"```text\n{output}\n```"
        )

    except Exception as exc:
        await status_msg.edit(
            content=f"Error getting system info: `{exc}`"
        )


async def cmd_temp_report(message, args):
    status_msg = await message.channel.send(
        "Generating temperature report..."
    )

    try:
        result = run_monitor_command(
            "temp_report",
            timeout=30
        )

        output = (
            result.stdout.strip()
            or result.stderr.strip()
            or "Report generated with no output."
        )

        output = truncate_output(output)

        await status_msg.edit(
            content=f"```text\n{output}\n```"
        )

    except Exception as exc:
        await status_msg.edit(
            content=f"Error running temperature report: `{exc}`"
        )


async def cmd_test(message, args):
    try:
        parts = shlex.split(args)
    except ValueError:
        await message.channel.send(
            "Invalid command arguments."
        )
        return

    if len(parts) != 2:
        await message.channel.send(
            "Usage: `!test <cpu|ram|temp> <num>`"
        )
        return

    test_type = parts[0].lower()
    value_str = parts[1]

    if test_type not in {"cpu", "ram", "temp"}:
        await message.channel.send(
            "Test type must be `cpu`, `ram`, or `temp`."
        )
        return

    if not value_str.isdigit():
        await message.channel.send(
            "Please provide a valid numeric value."
        )
        return

    value = int(value_str)

    if value < 0 or value > 100:
        await message.channel.send(
            "Test value must be between `0` and `100`."
        )
        return

    initial_text = (
        f"Executing {test_type} test with value {value}..."
    )

    status_msg = await message.channel.send(
        initial_text
    )

    try:
        result = run_monitor_command(
            f"test_{test_type}",
            str(value),
            timeout=60
        )

        output = (
            result.stdout.strip()
            or result.stderr.strip()
            or "Command executed successfully with no output."
        )

        clean_lines = [
            line
            for line in output.splitlines()
            if not line.startswith("Running Real")
        ]

        output = "\n".join(clean_lines).strip()

        output = truncate_output(output)

        final_content = (
            f"{initial_text}\n\n"
            f"{output}"
        )

        await status_msg.edit(
            content=final_content
        )

    except Exception as exc:
        await status_msg.edit(
            content=f"Error executing test: `{exc}`"
        )


async def cmd_test_cpu(message, args):
    await cmd_test(message, f"cpu {args}")


async def cmd_test_ram(message, args):
    await cmd_test(message, f"ram {args}")


async def cmd_test_temp(message, args):
    await cmd_test(message, f"temp {args}")


async def cmd_alert(message, args):
    try:
        parts = shlex.split(args)
    except ValueError:
        parts = args.split()

    if not parts:
        await message.channel.send(
            "Usage examples:\n"
            "`!alert reboot 5`\n"
            "`!alert 5 15 \"Custom maintenance notice\"`"
        )
        return

    target_channel = None

    if message.guild:
        for channel in message.guild.text_channels:
            if channel.name.lower() == ALERT_CHANNEL:
                target_channel = channel
                break

    if target_channel is None:
        target_channel = message.channel

    now = datetime.datetime.now()

    # --------------------------------------------------------------------------
    # PRESET ALERT
    # --------------------------------------------------------------------------

    if parts[0].lower() in {
        "reboot",
        "shutdown",
        "update",
        "interrupt",
    }:

        action = parts[0].lower()

        delay_mins = 5

        if len(parts) > 1:
            if parts[1].isdigit():
                delay_mins = int(parts[1])

        if delay_mins < 0 or delay_mins > 10080:
            await message.channel.send(
                "Delay must be between 0 and 10080 minutes."
            )
            return

        start_time = (
            now +
            datetime.timedelta(minutes=delay_mins)
        )

        if action in {"reboot", "shutdown"}:
            title = (
                f"PLANNED NETWORK DOWNTIME: "
                f"{action.upper()}"
            )
            classification = (
                "Necessary Downtime (Guaranteed Event)"
            )
            emoji = "🚨"
            advice = (
                "Please save your work accordingly!"
            )
        else:
            title = (
                f"POTENTIAL SERVICE INTERRUPTION: "
                f"{action.upper()}"
            )
            classification = (
                "Soft Event (Downtime Not Guaranteed)"
            )
            emoji = "⚠️"
            advice = (
                "Services may experience a brief blip."
            )

        output_msg = (
            f"{emoji} **{title}** {emoji}\n"
            f"• **Action Type:** {action.capitalize()}\n"
            f"• **Notice Given At:** "
            f"{now.strftime('%H:%M')}\n"
            f"• **Execution Time:** "
            f"~{start_time.strftime('%H:%M')} "
            f"(In {delay_mins} mins)\n"
            f"• **Event Classification:** "
            f"{classification}\n\n"
            f"*{advice}*"
        )

        await target_channel.send(output_msg)

    # --------------------------------------------------------------------------
    # CUSTOM TIMED ALERT
    # --------------------------------------------------------------------------

    elif parts[0].isdigit():

        delay_mins = int(parts[0])

        duration_mins = 5

        if len(parts) > 1 and parts[1].isdigit():
            duration_mins = int(parts[1])

        if delay_mins < 0 or delay_mins > 10080:
            await message.channel.send(
                "Delay must be between 0 and 10080 minutes."
            )
            return

        if duration_mins < 0 or duration_mins > 10080:
            await message.channel.send(
                "Duration must be between 0 and 10080 minutes."
            )
            return

        if len(parts) > 2:
            custom_text_parts = parts[2:]
        elif len(parts) > 1 and not parts[1].isdigit():
            custom_text_parts = parts[1:]
        else:
            custom_text_parts = []

        custom_text = " ".join(custom_text_parts).strip()

        if not custom_text:
            custom_text = (
                "Scheduled maintenance notification."
            )

        # Prevent accidentally creating an enormous Discord message.
        custom_text = custom_text[:1500]

        start_time = (
            now +
            datetime.timedelta(minutes=delay_mins)
        )

        end_time = (
            start_time +
            datetime.timedelta(minutes=duration_mins)
        )

        output_msg = (
            "🚨 **PLANNED NETWORK NOTICE: CUSTOM EVENT** 🚨\n"
            f"• **Custom Message:** {custom_text}\n"
            f"• **Notice Given At:** "
            f"{now.strftime('%H:%M')}\n"
            f"• **Execution Time:** "
            f"~{start_time.strftime('%H:%M')} "
            f"(In {delay_mins} mins)\n"
            f"• **Expected Length:** "
            f"{duration_mins} minute(s) "
            f"(Expected back ~{end_time.strftime('%H:%M')})\n\n"
            "*Please save your work and log off if necessary.*"
        )

        await target_channel.send(output_msg)

    else:
        await message.channel.send(
            "Unknown alert format.\n\n"
            "Presets:\n"
            "`!alert reboot 5`\n"
            "`!alert shutdown 5`\n\n"
            "Custom:\n"
            "`!alert 5 15 \"Maintenance notice\"`"
        )


async def cmd_help(message, args):
    help_text = (
        "🤖 **Raspberry Pi Bot Commands:**\n\n"
        "• `!temp_report` — Temperature report\n"
        "• `!test <cpu|ram|temp> <num>` — Diagnostic test\n"
        "• `!test_cpu <num>` — CPU test\n"
        "• `!test_ram <num>` — RAM test\n"
        "• `!test_temp <num>` — Temperature test\n"
        "• `!ping` — Bot latency\n"
        "• `!sysinfo` — System information\n"
        "• `!alert reboot <mins>` — Reboot notice\n"
        "• `!alert shutdown <mins>` — Shutdown notice\n"
        "• `!alert update <mins>` — Update notice\n"
        "• `!alert interrupt <mins>` — Interruption notice\n"
        "• `!alert <delay> <dur> \"text\"` — Custom alert\n"
        "• `!reboot` — Restart Raspberry Pi\n"
        "• `!shutdown` — Shut down Raspberry Pi\n"
        "• `!help` — Display this menu"
    )

    await message.channel.send(help_text)


# ==============================================================================
# COMMAND REGISTRY
# ==============================================================================

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
    "help": cmd_help,
}


# ==============================================================================
# MESSAGE HANDLER
# ==============================================================================

@client.event
async def on_message(message):

    # Ignore ourselves.
    if message.author == client.user:
        return

    # Only the configured Discord user can operate the bot.
    if message.author.id != USER_ID:
        return

    # Ignore unrelated guild channels.
    if isinstance(message.channel, discord.TextChannel):
        if message.channel.name.lower() != LISTEN_CHANNEL:
            return

    if not message.content.startswith("!"):
        return

    parts = message.content[1:].split(None, 1)

    if not parts:
        return

    command_name = parts[0].lower()
    args = parts[1].strip() if len(parts) > 1 else ""

    command = COMMANDS.get(command_name)

    if command is None:
        await message.channel.send(
            f"Unknown command `!{command_name}`. "
            "Type `!help` for available commands."
        )
        return

    try:
        await command(message, args)

    except Exception as exc:
        print(
            f"Command error "
            f"({command_name}): {exc}"
        )

        await message.channel.send(
            f"Error executing command: `{exc}`"
        )


# ==============================================================================
# START
# ==============================================================================

client.run(BOT_TOKEN)
PYEOF

chown "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR/bot.py"
chmod 750 "$INSTALL_DIR/bot.py"

# ==============================================================================
# SYSTEMD SERVICE
# ==============================================================================

sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=PiTweaks Discord Bot Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/bot.py

Restart=on-failure
RestartSec=10

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF

# ==============================================================================
# ENABLE / RESTART
# ==============================================================================

echo "Applying systemd configuration..."

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME.service" >/dev/null
sudo systemctl restart "$SERVICE_NAME.service"

sleep 2

if sudo systemctl is-active --quiet "$SERVICE_NAME.service"; then
    echo
    echo "Discord Bot configured successfully."
    echo "Service: $SERVICE_NAME"
    echo "Listen:  #$LISTEN_CHANNEL"
    echo "Alerts:  #$ALERT_CHANNEL"
    echo
    echo "Bot service is running."
else
    echo
    echo "Warning: Discord Bot service did not remain running."
    echo
    echo "Check its status with:"
    echo "  sudo systemctl status $SERVICE_NAME"
    echo
    echo "View recent logs with:"
    echo "  sudo journalctl -u $SERVICE_NAME -n 50 --no-pager"
    exit 1
fi
