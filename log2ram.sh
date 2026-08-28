#!/bin/bash
# Description: Interactive installer for log2ram with whiptail configuration.
# PERSISTENT: TRUE
# Category: Scripts

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

# Check if whiptail is available, install if missing
if ! command -v whiptail &> /dev/null; then
    echo "[+] Installing whiptail for interactive UI..."
    apt-get update && apt-get install -y whiptail
fi

# --- 1. Whiptail Configuration UI ---
SIZE=$(whiptail --inputbox "Enter the RAM size to allocate for logs (e.g., 40M, 100M):" 10 60 "40M" 3>&1 1>&2 2>&3)
exitstatus=$?

if [ $exitstatus != 0 ]; then
    echo "[-] Installation cancelled by user."
    exit 1
fi

# Confirm choices
if !(whiptail --title "Confirm Settings" --yesno "Ready to install log2ram with a size of $SIZE?" 10 60); then
    echo "[-] Installation aborted."
    exit 1
fi

# --- 2. Installation Process ---
echo "[+] Adding azlux repository key and source..."
echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/azlux.list
wget -O /usr/share/keyrings/azlux-archive-keyring.gpg https://azlux.fr/repo.gpg

echo "[+] Updating package list and installing log2ram..."
apt-get update
apt-get install -y log2ram

# --- 3. Apply User Configuration ---
CONFIG_FILE="/etc/log2ram.conf"

if [ -f "$CONFIG_FILE" ]; then
    echo "[+] Applying your custom size ($SIZE) to $CONFIG_FILE..."
    sed -i "s/^SIZE=.*/SIZE=$SIZE/" "$CONFIG_FILE"
else
    echo "[!] Warning: Config file not found at $CONFIG_FILE, skipping custom size injection."
fi

# --- 4. Finalize and Enable Service ---
echo "[+] Enabling and starting log2ram service..."
systemctl enable log2ram
systemctl restart log2ram

whiptail --title "Success!" --msgbox "log2ram has been successfully installed and configured with $SIZE of RAM!\n\nReboot your Pi to fully complete the setup." 10 60
echo "[+] Done! A reboot is recommended."
