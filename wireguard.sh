#!/bin/bash

# Description: Dynamic installer and configurer for WireGuard and WireGuard-UI (Bare Metal)
# PERSISTENT: FALSE

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

echo "=========================================="
echo "    Dynamic WireGuard & UI Installer      "
echo "=========================================="
echo ""

# --- 1. Check WireGuard Status ---
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

# --- 2. Check WireGuard-UI Status ---
if systemctl list-units --type=service | grep -q "wireguard-ui" || [ -d "/opt/wireguard-ui" ]; then
  echo "[+] WireGuard-UI is already detected on this system."
  read -p "Do you want to re-install/update WireGuard-UI? (y/n): " REINSTALL_UI
  if [[ "$REINSTALL_UI" =~ ^[Yy]$ ]]; then
    echo "[*] Re-installing WireGuard-UI..."
  else
    echo "[*] Skipping WireGuard-UI installation."
  fi
else
  echo "[-] WireGuard-UI is not detected."
  read -p "Do you want to install WireGuard-UI bare metal and set it to start on boot? (y/n): " INSTALL_UI
  if [[ "$INSTALL_UI" =~ ^[Yy]$ ]]; then
    echo "[*] Creating directory and setting up WireGuard-UI..."
    mkdir -p /opt/wireguard-ui
    cd /opt/wireguard-ui

    # Detect system architecture
    ARCH=$(uname -m)
    echo "[*] Detected architecture: $ARCH"

    echo "[*] Creating systemd service file with persistent keepalive options..."
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

    systemctl daemon-reload
    systemctl enable wireguard-ui.service
    echo "[+] WireGuard-UI service enabled! It will start automatically on boot."
  else
    echo "[*] Skipping WireGuard-UI installation."
  fi
fi

echo ""
echo "=========================================="
echo "          Setup Script Complete           "
echo "=========================================="
