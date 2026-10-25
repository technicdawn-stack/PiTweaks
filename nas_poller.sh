#!/bin/bash

# Description: NAS SNMP Poller Installer with Auto-Cron & Config Preservation V1
# PERSISTENT: FALSE
# Category: Monitoring

set -euo pipefail

# ==============================================================================
# PATH CONFIGURATION
# ==============================================================================

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    CURRENT_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
else
    CURRENT_USER="$(id -un)"
    REAL_HOME="$HOME"
fi

INSTALL_DIR="$REAL_HOME/PiTweaks/nas_monitor"
SCRIPT_PATH="$INSTALL_DIR/nas_poller.py"
CONFIG_FILE="$INSTALL_DIR/config.env"
RAM_DIR="/run/nas-stats"

mkdir -p "$INSTALL_DIR"
chown "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"

# ==============================================================================
# DEPENDENCY CHECK & INSTALLATION
# ==============================================================================

echo "Checking system dependencies..."

if ! command -v whiptail >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y whiptail -qq
fi

if ! command -v snmpget >/dev/null 2>&1; then
    echo "Installing snmp utilities..."
    sudo apt-get update -qq
    sudo apt-get install -y snmp -qq
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Installing Python 3..."
    sudo apt-get update -qq
    sudo apt-get install -y python3 -qq
fi

# ==============================================================================
# SETUP RAM DIRECTORY (Zero SD Card Wear)
# ==============================================================================

sudo mkdir -p "$RAM_DIR"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$RAM_DIR"

# ==============================================================================
# CONFIGURATION CHECK & PROMPT
# ==============================================================================

CONFIG_ACTION="keep"

if [[ -f "$CONFIG_FILE" ]]; then
    if whiptail --backtitle "PiTweaks | NAS Monitor" \
               --title "Existing Configuration Found" \
               --yesno "An existing configuration file (config.env) was detected.\n\nDo you want to KEEP your current settings (update code only)?\n\nChoose 'No' to reset and re-configure settings." 10 75; then
        CONFIG_ACTION="keep"
    else
        CONFIG_ACTION="reset"
    fi
else
    CONFIG_ACTION="reset"
fi

if [[ "$CONFIG_ACTION" == "reset" ]]; then
    NAS_IP_INPUT=$(whiptail --backtitle "PiTweaks | NAS Monitor" \
                           --title "NAS IP Address" \
                           --inputbox "Enter your NAS IP address:" 8 60 "192.168.1.155" \
                           3>&1 1>&2 2>&3) || NAS_IP_INPUT="192.168.1.155"

    COMMUNITY_INPUT=$(whiptail --backtitle "PiTweaks | NAS Monitor" \
                              --title "SNMP Community" \
                              --inputbox "Enter your SNMP Community name:" 8 60 "public" \
                              3>&1 1>&2 2>&3) || COMMUNITY_INPUT="public"

    umask 077
    cat > "$CONFIG_FILE" <<EOF
NAS_IP="$NAS_IP_INPUT"
SNMP_COMMUNITY="$COMMUNITY_INPUT"
NAS_STATS_OUTPUT="$RAM_DIR/nas-status.json"
EOF
    chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "Configuration saved to $CONFIG_FILE"
else
    echo "Preserving existing configuration at $CONFIG_FILE"
fi

# ==============================================================================
# WRITE THE POLLER SCRIPT
# ==============================================================================

cat > "$SCRIPT_PATH" <<'PYEOF'
#!/usr/bin/env python3
import os
import json
import subprocess
from datetime import datetime

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.env")

def load_config(path):
    config = {}
    if not os.path.isfile(path):
        return config
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                config[k.strip()] = v.strip().strip('"').strip("'")
    except Exception:
        pass
    return config

cfg = load_config(CONFIG_PATH)

NAS_IP = cfg.get("NAS_IP") or os.getenv("NAS_IP", "192.168.1.155")
SNMP_COMMUNITY = cfg.get("SNMP_COMMUNITY") or os.getenv("SNMP_COMMUNITY", "public")
OUTPUT_FILE = cfg.get("NAS_STATS_OUTPUT") or os.getenv("NAS_STATS_OUTPUT", "/run/nas-stats/nas-status.json")

def run_snmp(oid):
    try:
        result = subprocess.run(
            ["snmpget", "-v2c", "-c", SNMP_COMMUNITY, "-Oqv", NAS_IP, oid],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=3,
            check=False
        )
        return result.stdout.strip()
    except Exception:
        return "N/A"

def collect_stats():
    uptime_raw = run_snmp("1.3.6.1.2.1.1.3.0")
    cpu_raw = run_snmp("1.3.6.1.4.1.2021.11.9.0")

    data = {
        "status": "online",
        "last_updated": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "uptime": uptime_raw.replace("Timeticks: ", ""),
        "cpu_usage": cpu_raw,
        "ram_usage": "Monitored via SNMP",
        "backup_status": "Active (Restic)"
    }

    output_dir = os.path.dirname(OUTPUT_FILE)
    if not os.path.isdir(output_dir):
        os.makedirs(output_dir, exist_ok=True)

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

if __name__ == "__main__":
    collect_stats()
PYEOF

chown "$CURRENT_USER:$CURRENT_USER" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"

# ==============================================================================
# AUTO-SETUP CRON JOB
# ==============================================================================

CRON_JOB="* * * * * /usr/bin/python3 $SCRIPT_PATH >/dev/null 2>&1"

if whiptail --backtitle "PiTweaks | NAS Monitor" \
           --title "Automatic Cron Setup" \
           --yesno "Would you like to automatically configure a 1-minute cron job to run this poller in the background?\n\n(This will keep your Dashy status feed updated continuously without SD card wear)." 11 75; then
    
    # Check if cron job already exists to avoid duplicates
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    if echo "$CURRENT_CRON" | grep -Fq "$SCRIPT_PATH"; then
        echo "Cron job already exists. Skipping duplication."
    else
        (echo "$CURRENT_CRON"; echo "$CRON_JOB") | crontab -
        echo "Cron job added successfully!"
    fi
else
    echo "Skipped automatic cron setup."
fi

echo
echo "NAS Monitor setup complete!"
echo "• Script: $SCRIPT_PATH"
echo "• Config: $CONFIG_FILE"
echo "• Feed:   $RAM_DIR/nas-status.json"
