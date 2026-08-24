#!/bin/bash

# ==============================================================================
# # Description: Automated installer and configurer for Unbound (Recursive DNS) with Port Conflict Check
# # PERSISTENT: TRUE
# ==============================================================================
set -eo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo or as root."
  exit 1
fi

# --- 1. Port Conflict Check ---
TARGET_PORT="5335"
echo "[+] Checking if port $TARGET_PORT is already in use..."

if command -v ss &>/dev/null; then
    PORT_CHECK=$(ss -tuln | grep ":$TARGET_PORT " || true)
else
    PORT_CHECK=$(netstat -tuln | grep ":$TARGET_PORT " || true)
fi

if [ -n "$PORT_CHECK" ]; then
    echo "⚠️ WARNING: Port $TARGET_PORT is already in use on this system!"
    echo "$PORT_CHECK"
    read -p "Do you want to continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "[-] Installation aborted by user due to port conflict."
        exit 1
    fi
else
    echo "[✓] Port $TARGET_PORT is free."
fi

# --- 2. Installation ---
echo "[+] Updating package lists and installing Unbound..."
apt-get update -qq
apt-get install -y unbound dns-root-data -qq

# --- 3. Configuration ---
CONFIG_FILE="/etc/unbound/unbound.conf.d/pi-hole.conf"
echo "[+] Writing explicit configuration (127.0.0.1:$TARGET_PORT) to $CONFIG_FILE..."

cat << EOF > "$CONFIG_FILE"
server:
    verbosity: 1
    interface: 127.0.0.1
    port: $TARGET_PORT
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    so-rcvbuf: 1m
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
EOF

# Disable conflicting service if present on Debian/Raspberry Pi OS
if systemctl list-unit-files | grep -q unbound-resolvconf.service; then
    echo "[+] Disabling conflicting unbound-resolvconf service..."
    systemctl disable --now unbound-resolvconf.service || true
fi

echo "[+] Enabling and restarting Unbound service..."
systemctl enable unbound
systemctl restart unbound

echo "[+] Success! Unbound is now running locally at 127.0.0.1:$TARGET_PORT."
echo "[*] Next step: Go to your Pi-hole web interface -> Settings -> DNS, uncheck public upstreams, and set Custom 1 (IPv4) to: 127.0.0.1#$TARGET_PORT"
