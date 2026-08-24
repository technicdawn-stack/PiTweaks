#!/bin/bash

# Description: Fully automated installer and configurer for WireGuard and WireGuard-UI (Bare Metal) V1.1
# PERSISTENT: FALSE

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

echo "=========================================="
echo "    Full WireGuard & UI Auto-Installer    "
echo "=========================================="
echo ""

# --- 1. Check & Install WireGuard ---
if command -v wg &> /dev/null || [ -d "/etc/wireguard" ]; then
  echo "[+] WireGuard is already detected on this system."
  read -p "Do you want to re-install/re-configure WireGuard? (y/n): " REINSTALL_WG
  if [[ "$REINSTALL_WG" =~ ^[Yy]$ ]]; then
    echo "[*] Installing/Updating WireGuard..."
    apt-get update && apt-get install -y wireguard iptables
  else
    echo "[*] Skipping WireGuard installation."
  fi
else
  echo "[-] WireGuard is not installed."
  read -p "Do you want to install WireGuard now? (y/n): " INSTALL_WG
  if [[ "$INSTALL_WG" =~ ^[Yy]$ ]]; then
    echo "[*] Installing WireGuard..."
    apt-get update && apt-get install -y wireguard iptables
  else
    echo "[*] Skipping WireGuard installation."
  fi
fi

echo ""
echo "------------------------------------------"
echo ""

# --- 2. Check & Full Install WireGuard-UI ---
if systemctl list-units --type=service | grep -q "wireguard-ui" || [ -d "/opt/wireguard-ui" ]; then
  echo "[+] WireGuard-UI is already detected on this system."
  read -p "Do you want to re-install/update WireGuard-UI? (y/n): " REINSTALL_UI
  if [[ "$REINSTALL_UI" =~ ^[Yy]$ ]]; then
    echo "[*] Re-installing WireGuard-UI..."
    systemctl stop wireguard-ui 2>/dev/null
    rm -rf /opt/wireguard-ui/*
  else
    echo "[*] Skipping WireGuard-UI installation."
    exit 0
  fi
else
  echo "[-] WireGuard-UI is not detected."
  read -p "Do you want to fully install WireGuard-UI bare metal and start it on boot? (y/n): " INSTALL_UI
  if [[ ! "$INSTALL_UI" =~ ^[Yy]$ ]]; then
    echo "[*] Skipping WireGuard-UI installation."
    exit 0
  fi
fi

echo "[*] Creating directory and downloading WireGuard-UI..."
mkdir -p /opt/wireguard-ui
cd /opt/wireguard-ui

# Detect system architecture and map to GitHub release naming
ARCH=$(uname -m)
echo "[*] Detected architecture: $ARCH"

if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
  WG_UI_ARCH="linux-arm64"
else
  WG_UI_ARCH="linux-arm"
fi

# Download the binary package
wget -O wireguard-ui.tar.gz "https://github.com/ngoduykhanh/wireguard-ui/releases/download/v0.6.2/wireguard-ui-v0.6.2-${WG_UI_ARCH}.tar.gz"

echo "[*] Extracting files..."
tar -xzvf wireguard-ui.tar.gz
rm wireguard-ui.tar.gz

echo "[*] Creating systemd service file..."
cat << 'EOF' > /etc/systemd/system/wireguard-ui.service
[Unit]
Description=WireGuard-UI Management Dashboard
After=network.target wg-quick@wg0.service

[Service]
Type=simple
WorkingDirectory=/opt/wireguard-ui
ExecStart=/opt/wireguard-ui/wireguard-ui

# Environment configurations:
# WGUI_PERSISTENT_KEEPALIVE: Keeps NAT/firewall mapping alive for mobile devices (set to 15 seconds)
# WGUI_DEFAULT_CLIENT_USE_SERVER_DNS: Forces clients to use your Pi's DNS setup automatically
Environment="WGUI_PERSISTENT_KEEPALIVE=15"
Environment="WGUI_DEFAULT_CLIENT_USE_SERVER_DNS=true"

Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Enabling and starting WireGuard-UI service..."
systemctl daemon-reload
systemctl enable wireguard-ui.service
systemctl restart wireguard-ui.service

echo ""
echo "=========================================="
echo "      Full Installation Complete!         "
echo "=========================================="
echo " WireGuard-UI is now running and enabled."
echo " Access it at: http://<your-pi-ip>:5000"
echo "=========================================="
