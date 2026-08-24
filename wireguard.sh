#!/bin/bash

# Description: Dynamic installer and configurer for WireGuard and WireGuard-UI (Bare Metal) V1.0
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

    # Detect system architecture and map to Github release naming
    ARCH=$(uname -m)
    echo "[*] Detected architecture: $ARCH"
    
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
      WG_UI_ARCH="linux-arm64"
    else
      WG_UI_ARCH="linux-arm"
    fi

    echo "[*] Downloading WireGuard-UI binary for $WG_UI_ARCH..."
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

    systemctl daemon-reload
    systemctl enable wireguard-ui.service
    systemctl start wireguard-ui.service
    echo "[+] WireGuard-UI installed, enabled, and started successfully!"
  else
    echo "[*] Skipping WireGuard-UI installation."
  fi
fi

echo ""
echo "=========================================="
echo "          Setup Script Complete           "
echo "=========================================="
