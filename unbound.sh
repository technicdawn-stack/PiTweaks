#!/bin/bash

# ==============================================================================
# # Description: Automated installer and configurer for Unbound (Recursive DNS)
# # PERSISTENT: TRUE
# ==============================================================================
set -eo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with sudo or as root."
  exit 1
fi

echo "[+] Updating package lists and installing Unbound..."
apt-get update -qq
apt-get install -y unbound dns-root-data -qq

# Create the optimized Pi-hole configuration file for Unbound
CONFIG_FILE="/etc/unbound/unbound.conf.d/pi-hole.conf"
echo "[+] Writing custom configuration to $CONFIG_FILE..."

cat << 'EOF' > "$CONFIG_FILE"
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
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

echo "[+] Success! Unbound is now running locally on port 5335."
echo "[*] Next step: Go to your Pi-hole web interface -> Settings -> DNS, uncheck public upstreams, and set Custom 1 (IPv4) to: 127.0.0.1#5335"
