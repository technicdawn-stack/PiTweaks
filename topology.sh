#!/bin/bash

# ============================================================
# Homelab Topology Visualizer & Management Console
# PERSISTENT: TRUE
# Category: Webpages
# Version: V1.4
#
# V1.4 Features:
#   - Interactive topology visualization
#   - Cinematic spotlight search
#   - CPU/RAM monitoring
#   - Settings dropdown
#   - Password-protected editor
#   - Add nodes
#   - Delete nodes
#   - Save topology back to YAML
#   - Separate installer prompt for password/settings
#   - Separate installer prompt for topology YAML
#   - Existing YAML preserved unless explicitly replaced
#   - Existing password preserved unless explicitly changed
# ============================================================

set -e

# ------------------------------------------------------------
# Dynamically detect the real user even if run via sudo
# ------------------------------------------------------------

if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$(whoami)"
fi

USER_HOME="$(eval echo ~$CURRENT_USER)"

APP_DIR="$USER_HOME/homelab-map"
PYTHON_APP_PATH="$APP_DIR/app.py"
YAML_PATH="$APP_DIR/homelabmap.yaml"
SETTINGS_PATH="$APP_DIR/settings.env"

TEMPLATE_DIR="$APP_DIR/templates"
TEMPLATE_PATH="$TEMPLATE_DIR/index.html"

SERVICE_PATH="/etc/systemd/system/homelab-map.service"

PORT=8085


# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Homelab Topology Visualizer V1.4"
echo "============================================================"
echo
echo "[*] Running installer as user: $CURRENT_USER"
echo "[*] Application directory: $APP_DIR"
echo


# ------------------------------------------------------------
# Dependency detection
# ------------------------------------------------------------

echo "[*] Checking Python3 and required packages..."

if ! command -v python3 >/dev/null 2>&1; then
    echo "[!] python3 could not be found."
    echo "[*] Installing Python3..."
    
    sudo apt-get update
    sudo apt-get install -y python3 python3-pip python3-venv whiptail
fi

if ! command -v whiptail >/dev/null 2>&1; then
    echo "[*] Installing whiptail..."
    
    sudo apt-get update
    sudo apt-get install -y whiptail
fi


# ------------------------------------------------------------
# Create application directories
# ------------------------------------------------------------

mkdir -p "$APP_DIR"
mkdir -p "$TEMPLATE_DIR"

sudo chown -R "$CURRENT_USER:$CURRENT_USER" "$APP_DIR"


# ------------------------------------------------------------
# Python dependency detection
# ------------------------------------------------------------

echo "[*] Checking Flask / psutil / PyYAML..."

if ! python3 -c "import flask, psutil, yaml" >/dev/null 2>&1; then

    echo "[!] Required Python modules are missing."

    # First try Debian/Ubuntu packages.
    if sudo apt-get install -y python3-flask python3-psutil python3-yaml >/dev/null 2>&1; then
        echo "[+] Python dependencies installed through apt."
    else
        echo "[!] apt packages unavailable. Attempting pip installation..."

        python3 -m pip install --upgrade pip
        python3 -m pip install flask psutil pyyaml
    fi
fi


# ------------------------------------------------------------
# V1.4 - PASSWORD / SETTINGS PROMPT
#
# This is completely separate from the YAML prompt.
# ------------------------------------------------------------

KEEP_OLD_SETTINGS=false

if [ -f "$SETTINGS_PATH" ]; then

    echo "[*] Existing settings/password configuration detected."

    if whiptail \
        --title "V1.4 - Existing Admin Settings Found" \
        --yesno \
        "An existing V1.4 settings file was detected.\n\nWould you like to KEEP your existing admin password and settings?\n\nYES = Keep current password\nNO = Choose a new password" \
        12 70
    then
        KEEP_OLD_SETTINGS=true
    fi
fi


if [ "$KEEP_OLD_SETTINGS" = "true" ]; then

    echo "[+] Keeping existing admin password/settings."

else

    echo "[*] Creating/changing admin password..."

    ADMIN_PASS=""

    if command -v whiptail >/dev/null 2>&1; then

        ADMIN_PASS=$(whiptail \
            --passwordbox \
            "Enter the admin password used to unlock the online topology editor.\n\nThis password is NOT requested when simply viewing the page." \
            12 70 \
            3>&1 1>&2 2>&3) || true

    else

        read -r -s -p "Enter admin password: " ADMIN_PASS
        echo

    fi

    if [ -z "$ADMIN_PASS" ]; then
        echo "[!] No password entered."
        echo "[*] Using fallback password: homelab123"
        ADMIN_PASS="homelab123"
    fi

    # Escape characters that could break the environment file.
    ESCAPED_PASS=$(printf '%s' "$ADMIN_PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')

    cat > "$SETTINGS_PATH" <<EOF
HOMELAB_ADMIN_PASS="$ESCAPED_PASS"
EOF

    chmod 600 "$SETTINGS_PATH"

    echo "[+] Admin password saved securely."
fi


# ------------------------------------------------------------
# Make sure settings exist
# ------------------------------------------------------------

if [ ! -f "$SETTINGS_PATH" ]; then

    echo 'HOMELAB_ADMIN_PASS="homelab123"' > "$SETTINGS_PATH"

    chmod 600 "$SETTINGS_PATH"

fi


# ------------------------------------------------------------
# V1.4 - TOPOLOGY YAML PROMPT
#
# This happens AFTER the password/settings prompt.
# They are intentionally independent.
# ------------------------------------------------------------

KEEP_OLD_YAML=false

if [ -f "$YAML_PATH" ]; then

    echo "[*] Existing homelabmap.yaml detected."

    if whiptail \
        --title "V1.4 - Existing Homelab Topology Found" \
        --yesno \
        "An existing homelabmap.yaml was detected.\n\nWould you like to KEEP your existing topology, services and layers?\n\nYES = Keep existing topology\nNO = Replace it with the V1.4 default topology" \
        12 70
    then
        KEEP_OLD_YAML=true
    fi
fi


# ------------------------------------------------------------
# Create default YAML only if user did not keep existing one
# ------------------------------------------------------------

if [ "$KEEP_OLD_YAML" != "true" ]; then

    echo "[*] Generating default V1.4 homelabmap.yaml..."

    cat << 'EOF' > "$YAML_PATH"
homelab_environment:
  system_info:
    hardware: "Raspberry Pi 3B"
    os: "Raspberry Pi OS"
    primary_dashboard: "Dashy"

  layers:

    - name: "Exit & WAN Layer"
      description: "External gateways, internet connections, and public routing"
      services:

        - id: internet
          name: "Internet / WAN"
          type: "External Gateway"
          ports: []
          config_path: "ISP Modem / Router"
          connects_to: [caddy, wireguard]
          scripts_associated: []
          status: "Connected"
          uptime: "21 days"
          traffic_out: "45.2 GB"
          traffic_in: "128.5 GB"

    - name: "Edge & Access Layer"
      description: "External entry points, reverse proxy, and remote tunnels"
      services:

        - id: caddy
          name: "Caddy"
          type: "Reverse Proxy / Web Server"
          ports: [80, 443]
          config_path: "/etc/caddy/Caddyfile"
          connects_to: [dashy, pihole]
          scripts_associated:
            - "Caddy_Editor.sh"
            - "SSLguide.sh"
          status: "Running"
          uptime: "14 days, 3 hours"
          traffic_out: "23.4 MB"
          traffic_in: "3.1 MB"

        - id: wireguard
          name: "WireGuard"
          type: "VPN Tunnel"
          ports: [51820]
          config_path: "/etc/wireguard/"
          connects_to: [pihole]
          scripts_associated:
            - "wireguard.sh"
          status: "Running"
          uptime: "21 days, 12 hours"
          traffic_out: "45.1 MB"
          traffic_in: "88.6 MB"

        - id: duckdns
          name: "DuckDNS"
          type: "Dynamic DNS"
          ports: []
          config_path: "~/duckdns/"
          connects_to: [internet]
          scripts_associated: []
          status: "Running"
          uptime: "21 days, 12 hours"
          traffic_out: "120 KB"
          traffic_in: "45 KB"

    - name: "Core Services Layer"
      description: "DNS resolution, ad-blocking, and file sharing"
      services:

        - id: pihole
          name: "Pi-hole"
          type: "DNS Sinkhole & Ad Blocker"
          ports: [53, 80]
          config_path: "/etc/pihole/"
          connects_to: [unbound]
          scripts_associated: []
          status: "Running"
          uptime: "14 days, 3 hours"
          traffic_out: "1.2 GB"
          traffic_in: "450 MB"

        - id: unbound
          name: "Unbound"
          type: "Recursive DNS Resolver"
          ports: [5335]
          config_path: "/etc/unbound/unbound.conf.d/"
          connects_to: [internet]
          scripts_associated: []
          status: "Running"
          uptime: "14 days, 3 hours"
          traffic_out: "890 MB"
          traffic_in: "310 MB"

        - id: samba
          name: "Samba"
          type: "File System Management / Sharing"
          ports: [445, 139]
          config_path: "/etc/samba/smb.conf"
          connects_to: []
          scripts_associated: []
          status: "Running"
          uptime: "5 days, 8 hours"
          traffic_out: "3.4 GB"
          traffic_in: "1.8 GB"

    - name: "Security & Monitoring Layer"
      description: "Intrusion detection, alerting, and hardware monitoring"
      services:

        - id: crowdsec
          name: "CrowdSec"
          type: "Security Engine & IDS"
          ports: []
          config_path: "/etc/crowdsec/"
          connects_to: [caddy]
          scripts_associated:
            - "security_module_upgrade.sh"
          status: "Running"
          uptime: "14 days, 3 hours"
          traffic_out: "500 KB"
          traffic_in: "2.1 MB"

        - id: monitoring
          name: "Hardware & Discord Monitors"
          type: "Custom Alerting & Cooling"
          ports: []
          config_path: "~/"
          connects_to: []
          scripts_associated:
            - "CubeCooler.py"
            - "temp_monitor.sh"
            - "discord_monitor.sh"
          status: "Running"
          uptime: "14 days, 3 hours"
          traffic_out: "1.5 MB"
          traffic_in: "100 KB"

    - name: "Presentation & Automation Layer"
      description: "Dashboards, custom shortcuts, and utility toolsets"
      services:

        - id: dashy
          name: "Dashy"
          type: "Centralized Web Dashboard"
          ports: [4000]
          config_path: "~/dashy/"
          connects_to: [pihole, samba]
          scripts_associated: []
          status: "Running"
          uptime: "14 days, 3 hours"
          traffic_out: "15.2 MB"
          traffic_in: "2.8 MB"
EOF

else

    echo "[+] Existing topology preserved."

fi


# ------------------------------------------------------------
# Ensure ownership
# ------------------------------------------------------------

sudo chown "$CURRENT_USER:$CURRENT_USER" "$YAML_PATH"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$SETTINGS_PATH"

chmod 600 "$SETTINGS_PATH"


# ============================================================
# PYTHON FLASK BACKEND
# ============================================================

echo "[*] Writing V1.4 Flask backend..."

cat << 'PYEOF' > "$PYTHON_APP_PATH"

import os
import tempfile

import yaml
import psutil

from flask import Flask, render_template, jsonify, request


app = Flask(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

YAML_PATH = os.path.join(
    BASE_DIR,
    "homelabmap.yaml"
)

SETTINGS_PATH = os.path.join(
    BASE_DIR,
    "settings.env"
)


# ------------------------------------------------------------
# Password handling
# ------------------------------------------------------------

def get_admin_password():

    if not os.path.exists(SETTINGS_PATH):
        return os.environ.get(
            "HOMELAB_ADMIN_PASS",
            "homelab123"
        )

    try:

        with open(
            SETTINGS_PATH,
            "r",
            encoding="utf-8"
        ) as f:

            for line in f:

                line = line.strip()

                if line.startswith(
                    "HOMELAB_ADMIN_PASS="
                ):

                    value = line.split(
                        "=",
                        1
                    )[1].strip()

                    if (
                        len(value) >= 2
                        and value[0] == '"'
                        and value[-1] == '"'
                    ):
                        value = value[1:-1]

                    elif (
                        len(value) >= 2
                        and value[0] == "'"
                        and value[-1] == "'"
                    ):
                        value = value[1:-1]

                    return value

    except Exception:
        pass

    return os.environ.get(
        "HOMELAB_ADMIN_PASS",
        "homelab123"
    )


# ------------------------------------------------------------
# YAML loading
# ------------------------------------------------------------

def load_homelab_data():

    if not os.path.exists(YAML_PATH):
        return {}

    try:

        with open(
            YAML_PATH,
            "r",
            encoding="utf-8"
        ) as f:

            data = yaml.safe_load(f)

            if data is None:
                return {}

            return data

    except Exception as exc:

        print(
            f"Failed to load YAML: {exc}"
        )

        return {}


# ------------------------------------------------------------
# Safe YAML saving
#
# Write to a temporary file first, then replace the original.
# This helps reduce the chance of corrupting the map if the
# Pi loses power during a write.
# ------------------------------------------------------------

def save_homelab_data(data):

    directory = os.path.dirname(YAML_PATH)

    fd, temp_path = tempfile.mkstemp(
        prefix=".homelabmap.",
        suffix=".yaml",
        dir=directory
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8"
        ) as f:

            yaml.safe_dump(
                data,
                f,
                sort_keys=False,
                default_flow_style=False,
                allow_unicode=True
            )

            f.flush()
            os.fsync(f.fileno())

        os.replace(
            temp_path,
            YAML_PATH
        )

    except Exception:

        try:
            os.unlink(temp_path)
        except OSError:
            pass

        raise


# ------------------------------------------------------------
# Basic topology validation
# ------------------------------------------------------------

def validate_topology(data):

    if not isinstance(data, dict):
        return False

    environment = data.get(
        "homelab_environment"
    )

    if not isinstance(environment, dict):
        return False

    layers = environment.get(
        "layers"
    )

    if not isinstance(layers, list):
        return False

    for layer in layers:

        if not isinstance(layer, dict):
            return False

        if "name" not in layer:
            return False

        services = layer.get(
            "services",
            []
        )

        if not isinstance(services, list):
            return False

        for service in services:

            if not isinstance(service, dict):
                return False

            if "id" not in service:
                return False

            if "name" not in service:
                return False

    return True


# ------------------------------------------------------------
# Frontend
# ------------------------------------------------------------

@app.route("/")
def index():

    return render_template(
        "index.html"
    )


# ------------------------------------------------------------
# Public topology endpoint
#
# Reading the map does NOT require a password.
# ------------------------------------------------------------

@app.route(
    "/api/topology",
    methods=["GET"]
)
def get_topology():

    data = load_homelab_data()

    return jsonify(data)


# ------------------------------------------------------------
# Authentication endpoint
#
# The password is only sent when the user clicks
# "Unlock Editor".
# ------------------------------------------------------------

@app.route(
    "/api/auth",
    methods=["POST"]
)
def authenticate():

    payload = request.get_json(
        silent=True
    ) or {}

    supplied_password = payload.get(
        "password",
        ""
    )

    if supplied_password != get_admin_password():

        return jsonify({
            "authenticated": False,
            "error": "Invalid admin password"
        }), 401

    return jsonify({
        "authenticated": True
    })


# ------------------------------------------------------------
# Save topology
#
# Password is checked here again so the save endpoint cannot
# simply be called without authentication.
# ------------------------------------------------------------

@app.route(
    "/api/topology",
    methods=["POST"]
)
def update_topology():

    supplied_password = request.headers.get(
        "X-Admin-Password",
        ""
    )

    if supplied_password != get_admin_password():

        return jsonify({
            "error": "Unauthorized: Invalid password"
        }), 401

    new_data = request.get_json(
        silent=True
    )

    if not validate_topology(
        new_data
    ):

        return jsonify({
            "error": "Invalid topology data format"
        }), 400

    try:

        save_homelab_data(
            new_data
        )

        return jsonify({
            "status": "success",
            "message": "Topology saved successfully to YAML."
        })

    except Exception as exc:

        return jsonify({
            "error": str(exc)
        }), 500


# ------------------------------------------------------------
# System statistics
# ------------------------------------------------------------

@app.route(
    "/api/stats",
    methods=["GET"]
)
def get_stats():

    cpu = psutil.cpu_percent(
        interval=None
    )

    ram = psutil.virtual_memory()

    return jsonify({

        "cpu": cpu,

        "ram_percent": ram.percent,

        "ram_used_mb": round(
            ram.used / (1024 * 1024),
            1
        ),

        "ram_total_mb": round(
            ram.total / (1024 * 1024),
            1
        )

    })


# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

if __name__ == "__main__":

    app.run(
        host="0.0.0.0",
        port=8085
    )

PYEOF


# ============================================================
# FRONTEND
# ============================================================

echo "[*] Writing V1.4 frontend..."

cat << 'HTMLEOF' > "$TEMPLATE_PATH"

<!DOCTYPE html>

<html lang="en">

<head>

    <meta charset="UTF-8">

    <meta
        name="viewport"
        content="width=device-width, initial-scale=1.0"
    >

    <title>
        Homelab Interactive Topology Map V1.4
    </title>

    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>

    <script
        type="text/javascript"
        src="https://unpkg.com/vis-network/standalone/umd/vis-network.min.js"
    ></script>

    <style>

        :root {
            --bg-color: #030712;
            --surface-color: #0f172a;
            --surface-border: #1e293b;
        }

        body {
            background-color: var(--bg-color);
            color: #f8fafc;
            font-family:
                system-ui,
                -apple-system,
                sans-serif;
        }

        #network-container {
            width: 100vw;
            height: calc(100vh - 70px);
            background: #030712;
        }

        .modal-input {
            width: 100%;
            background: #020617;
            border: 1px solid #334155;
            padding: 8px;
            border-radius: 6px;
            color: #e2e8f0;
            outline: none;
        }

        .modal-input:focus {
            border-color: #38bdf8;
        }

    </style>

</head>


<body class="flex flex-col h-screen overflow-hidden">


<!-- =========================================================
     TOP NAVIGATION
========================================================= -->

<header
    class="bg-slate-900 border-b border-slate-800 px-6 py-3 flex justify-between items-center z-20"
>

    <div class="flex items-center gap-4">

        <!-- SETTINGS -->

        <div class="relative">

            <button
                id="settingsBtn"
                class="bg-slate-800 hover:bg-slate-700 text-sky-400 px-3 py-2 rounded-lg border border-slate-700 flex items-center gap-2 text-xs font-semibold cursor-pointer transition-colors shadow-lg"
            >
                ⚙️ Settings & Editor
            </button>


            <!-- SETTINGS DROPDOWN -->

            <div
                id="settingsDropdown"
                class="absolute left-0 mt-2 w-72 bg-slate-900 border border-slate-800 rounded-xl shadow-2xl p-4 hidden flex-col gap-3 z-50"
            >

                <h3
                    class="font-bold text-sm text-sky-400 border-b border-slate-800 pb-2"
                >
                    Map Preferences
                </h3>


                <label
                    class="flex items-center gap-2 cursor-pointer select-none text-xs text-slate-300"
                >

                    <input
                        type="checkbox"
                        id="physicsToggle"
                        checked
                        class="accent-sky-500"
                    >

                    Physics Jiggle

                </label>


                <label
                    class="flex items-center gap-2 cursor-pointer select-none text-xs text-slate-300"
                >

                    <input
                        type="checkbox"
                        id="importanceToggle"
                        class="accent-sky-500"
                    >

                    Size by Importance

                </label>


                <!-- EDITOR -->

                <div
                    class="border-t border-slate-800 pt-3 flex flex-col gap-2"
                >

                    <span
                        class="text-xs font-bold text-emerald-400"
                    >
                        Admin Editor Mode
                    </span>


                    <!-- LOCKED -->

                    <div
                        id="authContainer"
                        class="flex flex-col gap-2"
                    >

                        <p
                            class="text-[11px] text-slate-400"
                        >
                            The password is only requested when you choose to edit.
                        </p>

                        <input
                            type="password"
                            id="adminPasswordInput"
                            placeholder="Enter Admin Password"
                            class="bg-slate-950 border border-slate-700 px-2.5 py-1.5 rounded text-xs text-slate-200 outline-none focus:border-emerald-400"
                        >

                        <button
                            id="unlockEditorBtn"
                            class="bg-emerald-600 hover:bg-emerald-500 text-white py-1.5 rounded text-xs font-semibold cursor-pointer transition-colors"
                        >
                            🔓 Unlock Editor
                        </button>

                    </div>


                    <!-- UNLOCKED -->

                    <div
                        id="editorControls"
                        class="hidden flex-col gap-2"
                    >

                        <p
                            class="text-xs text-emerald-400 font-medium"
                        >
                            ✓ Editor Unlocked
                        </p>


                        <button
                            id="openAddNodeModal"
                            class="bg-sky-600 hover:bg-sky-500 text-white py-1.5 rounded text-xs font-semibold cursor-pointer"
                        >
                            + Add New Node
                        </button>


                        <button
                            id="saveYamlBtn"
                            class="bg-amber-600 hover:bg-amber-500 text-white py-1.5 rounded text-xs font-semibold cursor-pointer"
                        >
                            💾 Save All to YAML
                        </button>


                        <button
                            id="lockEditorBtn"
                            class="bg-slate-700 hover:bg-slate-600 text-white py-1.5 rounded text-xs font-semibold cursor-pointer"
                        >
                            🔒 Lock Editor
                        </button>

                    </div>

                </div>

            </div>

        </div>


        <!-- TITLE -->

        <div class="flex items-center gap-3">

            <span class="text-xl">
                🗺️
            </span>

            <div>

                <h1
                    class="font-bold text-lg text-sky-400"
                >
                    Homelab Topology V1.4
                </h1>

                <p
                    class="text-xs text-slate-400"
                >
                    Raspberry Pi 3B Service Mesh & Dependencies
                </p>

            </div>

        </div>

    </div>


    <!-- RIGHT SIDE -->

    <div
        class="flex items-center gap-4 text-sm flex-wrap"
    >

        <div
            class="bg-slate-800 px-3 py-1.5 rounded-lg border border-slate-700 flex gap-4 text-xs"
        >

            <span>
                CPU:
                <strong
                    id="cpu-stat"
                    class="text-sky-400"
                >
                    0.0%
                </strong>
            </span>

            <span>
                RAM:
                <strong
                    id="ram-stat"
                    class="text-emerald-400"
                >
                    0.0%
                </strong>
            </span>

        </div>


        <input
            type="text"
            id="searchInput"
            placeholder="Search service (spotlight)..."
            class="bg-slate-950 border border-slate-700 px-3 py-2 rounded-lg text-xs outline-none focus:border-sky-400 text-slate-200 w-64 transition-all"
        >

    </div>

</header>


<!-- =========================================================
     MAIN
========================================================= -->

<div
    class="flex flex-1 relative overflow-hidden"
>


    <!-- NETWORK -->

    <div
        id="network-container"
    ></div>


    <!-- INSPECTOR -->

    <div
        id="inspectorPanel"
        class="absolute right-0 top-0 h-full w-96 bg-slate-900 border-l border-slate-800 p-6 flex flex-col gap-5 transform translate-x-full transition-transform duration-300 z-30 shadow-2xl overflow-y-auto"
    >

        <div
            class="flex justify-between items-center border-b border-slate-800 pb-3"
        >

            <h2
                id="panelTitle"
                class="font-bold text-lg text-sky-400"
            >
                Service Details
            </h2>

            <button
                id="closePanel"
                class="text-slate-400 hover:text-white text-lg"
            >
                ✕
            </button>

        </div>


        <div
            class="flex flex-col gap-4 text-sm"
        >

            <div>
                <span class="text-xs text-slate-400 uppercase tracking-wider">
                    Service ID
                </span>

                <p
                    id="panelId"
                    class="font-mono text-slate-300"
                >
                    -
                </p>
            </div>


            <div>
                <span class="text-xs text-slate-400 uppercase tracking-wider">
                    Layer
                </span>

                <p
                    id="panelLayer"
                    class="font-medium text-slate-200"
                >
                    -
                </p>
            </div>


            <div>
                <span class="text-xs text-slate-400 uppercase tracking-wider">
                    Service Type
                </span>

                <p
                    id="panelType"
                    class="font-medium text-slate-200"
                >
                    -
                </p>
            </div>


            <div>
                <span class="text-xs text-slate-400 uppercase tracking-wider">
                    Current Status
                </span>

                <p
                    id="panelStatus"
                    class="font-semibold text-emerald-400"
                >
                    -
                </p>
            </div>


            <div>
                <span class="text-xs text-slate-400 uppercase tracking-wider">
                    Runtime Uptime
                </span>

                <p
                    id="panelUptime"
                    class="text-slate-200"
                >
                    -
                </p>
            </div>


            <div>
                <span class="text-xs text-slate-400 uppercase tracking-wider">
                    Data Transfer
                </span>

                <p
                    id="panelTraffic"
                    class="text-slate-200"
                >
                    -
                </p>
            </div>


            <div>
                <span class="text-xs text-slate-400 uppercase tracking-wider">
                    Ports
                </span>

                <p
                    id="panelPorts"
                    class="text-slate-200 font-mono"
                >
                    -
                </p>
            </div>


            <div>

                <span class="text-xs text-slate-400 uppercase tracking-wider">
                    Configuration Path
                </span>

                <p
                    id="panelConfig"
                    class="text-sky-300 font-mono text-xs bg-slate-950 p-2 rounded border border-slate-800 break-all"
                >
                    -
                </p>

            </div>


            <div>

                <span class="text-xs text-slate-400 uppercase tracking-wider">
                    Associated Scripts
                </span>

                <ul
                    id="panelScripts"
                    class="list-disc list-inside text-xs text-slate-300 font-mono mt-1"
                ></ul>

            </div>


            <!-- EDIT ACTIONS -->

            <div
                id="editNodeActions"
                class="hidden border-t border-slate-800 pt-4 flex gap-2"
            >

                <button
                    id="deleteNodeBtn"
                    class="flex-1 bg-rose-600 hover:bg-rose-500 text-white py-2 rounded text-xs font-semibold cursor-pointer"
                >
                    Delete Node
                </button>

            </div>

        </div>

    </div>

</div>


<!-- =========================================================
     ADD NODE MODAL
========================================================= -->

<div
    id="addNodeModal"
    class="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center hidden z-50"
>

    <div
        class="bg-slate-900 border border-slate-800 rounded-2xl w-full max-w-md p-6 flex flex-col gap-4 shadow-2xl"
    >

        <h3
            class="font-bold text-lg text-sky-400"
        >
            Add New Homelab Node
        </h3>


        <div
            class="flex flex-col gap-3 text-xs"
        >

            <div>

                <label class="text-slate-400">
                    Service ID:
                </label>

                <input
                    type="text"
                    id="newNodeId"
                    placeholder="plex"
                    class="modal-input mt-1"
                >

            </div>


            <div>

                <label class="text-slate-400">
                    Display Name:
                </label>

                <input
                    type="text"
                    id="newNodeName"
                    placeholder="Plex Media Server"
                    class="modal-input mt-1"
                >

            </div>


            <div>

                <label class="text-slate-400">
                    Service Type:
                </label>

                <input
                    type="text"
                    id="newNodeType"
                    placeholder="Media Streaming"
                    class="modal-input mt-1"
                >

            </div>


            <div>

                <label class="text-slate-400">
                    Target Layer:
                </label>

                <select
                    id="newNodeLayer"
                    class="modal-input mt-1"
                ></select>

            </div>

        </div>


        <div
            class="flex justify-end gap-2 mt-2"
        >

            <button
                id="cancelAddNode"
                class="bg-slate-800 hover:bg-slate-700 text-slate-300 px-4 py-2 rounded text-xs font-semibold cursor-pointer"
            >
                Cancel
            </button>

            <button
                id="confirmAddNode"
                class="bg-sky-600 hover:bg-sky-500 text-white px-4 py-2 rounded text-xs font-semibold cursor-pointer"
            >
                Add Node
            </button>

        </div>

    </div>

</div>


<!-- =========================================================
     JAVASCRIPT
========================================================= -->

<script>

let network = null;

let allNodesData = {};

let rawTopologyData = null;

let nodesDataSet = null;

let edgesDataSet = null;

let originalNodeStyles = {};

let isEditorUnlocked = false;

let currentAdminPassword = "";

let selectedNodeIdForInspector = null;


/* =========================================================
   ELEMENTS
========================================================= */

const settingsBtn =
    document.getElementById("settingsBtn");

const settingsDropdown =
    document.getElementById("settingsDropdown");

const physicsToggle =
    document.getElementById("physicsToggle");

const importanceToggle =
    document.getElementById("importanceToggle");

const searchInput =
    document.getElementById("searchInput");

const inspectorPanel =
    document.getElementById("inspectorPanel");

const closePanel =
    document.getElementById("closePanel");

const adminPasswordInput =
    document.getElementById("adminPasswordInput");

const unlockEditorBtn =
    document.getElementById("unlockEditorBtn");

const authContainer =
    document.getElementById("authContainer");

const editorControls =
    document.getElementById("editorControls");

const lockEditorBtn =
    document.getElementById("lockEditorBtn");

const openAddNodeModal =
    document.getElementById("openAddNodeModal");

const addNodeModal =
    document.getElementById("addNodeModal");

const cancelAddNode =
    document.getElementById("cancelAddNode");

const confirmAddNode =
    document.getElementById("confirmAddNode");

const saveYamlBtn =
    document.getElementById("saveYamlBtn");

const deleteNodeBtn =
    document.getElementById("deleteNodeBtn");

const newNodeId =
    document.getElementById("newNodeId");

const newNodeName =
    document.getElementById("newNodeName");

const newNodeType =
    document.getElementById("newNodeType");

const newNodeLayer =
    document.getElementById("newNodeLayer");


/* =========================================================
   SETTINGS DROPDOWN
========================================================= */

settingsBtn.addEventListener(
    "click",
    function(event) {

        event.stopPropagation();

        settingsDropdown.classList.toggle(
            "hidden"
        );

    }
);


settingsDropdown.addEventListener(
    "click",
    function(event) {

        event.stopPropagation();

    }
);


document.addEventListener(
    "click",
    function() {

        settingsDropdown.classList.add(
            "hidden"
        );

    }
);


/* =========================================================
   TOPOLOGY FETCH
========================================================= */

async function fetchTopology() {

    try {

        const response =
            await fetch(
                "/api/topology",
                {
                    cache: "no-store"
                }
            );

        if (!response.ok) {

            throw new Error(
                "Topology request failed"
            );

        }

        const data =
            await response.json();

        if (
            data &&
            data.homelab_environment &&
            Array.isArray(
                data.homelab_environment.layers
            )
        ) {

            rawTopologyData =
                data;

            populateLayerSelector(
                data.homelab_environment.layers
            );

            buildGraph(
                data.homelab_environment.layers
            );

        }

    } catch (error) {

        console.error(
            "Failed to fetch topology:",
            error
        );

    }

}


/* =========================================================
   STATS
========================================================= */

async function fetchStats() {

    try {

        const response =
            await fetch("/api/stats");

        const data =
            await response.json();

        document.getElementById(
            "cpu-stat"
        ).innerText =
            Number(data.cpu).toFixed(1) + "%";

        document.getElementById(
            "ram-stat"
        ).innerText =
            Number(data.ram_percent).toFixed(1)
            + "% ("
            + data.ram_used_mb
            + "MB)";

    } catch (error) {

        console.error(
            "Failed to fetch system stats:",
            error
        );

    }

}


/* =========================================================
   BUILD GRAPH
========================================================= */

function buildGraph(layers) {

    const nodes = [];

    const edges = [];

    allNodesData = {};

    originalNodeStyles = {};


    /* -----------------------------------------------------
       Calculate node connection importance
    ----------------------------------------------------- */

    const degreeMap = {};


    layers.forEach(
        function(layer) {

            if (!Array.isArray(layer.services)) {
                return;
            }

            layer.services.forEach(
                function(service) {

                    if (!degreeMap[service.id]) {
                        degreeMap[service.id] = 0;
                    }

                    if (
                        Array.isArray(
                            service.connects_to
                        )
                    ) {

                        service.connects_to.forEach(
                            function(target) {

                                degreeMap[
                                    service.id
                                ] =
                                    (
                                        degreeMap[
                                            service.id
                                        ] || 0
                                    ) + 1;

                                degreeMap[
                                    target
                                ] =
                                    (
                                        degreeMap[
                                            target
                                        ] || 0
                                    ) + 1;

                            }
                        );

                    }

                }
            );

        }
    );


    /* -----------------------------------------------------
       Layer colours
    ----------------------------------------------------- */

    const layerColors = [

        {
            background: "#1c1917",
            border: "#f43f5e",
            text: "#fb7185"
        },

        {
            background: "#0f172a",
            border: "#0284c7",
            text: "#38bdf8"
        },

        {
            background: "#0f172a",
            border: "#16a34a",
            text: "#4ade80"
        },

        {
            background: "#0f172a",
            border: "#d97706",
            text: "#fbbf24"
        },

        {
            background: "#0f172a",
            border: "#7c3aed",
            text: "#a78bfa"
        }

    ];


    const useImportance =
        importanceToggle.checked;


    /* -----------------------------------------------------
       Create nodes
    ----------------------------------------------------- */

    layers.forEach(
        function(layer, layerIndex) {

            const colorTheme =
                layerColors[
                    layerIndex %
                    layerColors.length
                ];


            if (!Array.isArray(layer.services)) {
                return;
            }


            layer.services.forEach(
                function(service) {

                    allNodesData[
                        service.id
                    ] = {
                        ...service,
                        layerName: layer.name
                    };


                    let marginVal = 12;

                    let fontSize = 13;


                    if (useImportance) {

                        const degree =
                            degreeMap[
                                service.id
                            ] || 1;

                        marginVal =
                            12 +
                            (degree * 3);

                        fontSize =
                            13 +
                            Math.min(
                                degree * 2,
                                6
                            );

                    }


                    originalNodeStyles[
                        service.id
                    ] = {

                        background:
                            colorTheme.background,

                        border:
                            colorTheme.border,

                        textColor:
                            colorTheme.text,

                        fontSize:
                            fontSize

                    };


                    nodes.push({

                        id: service.id,

                        label:
                            `  ${service.name}  \n` +
                            `  [ ${service.type} ]  `,

                        shape: "box",

                        margin: marginVal,

                        borderRadius: 8,

                        title:
                            `${service.name}\n` +
                            `Type: ${service.type}\n` +
                            `Status: ${service.status || "Unknown"}`,

                        color: {

                            background:
                                colorTheme.background,

                            border:
                                colorTheme.border,

                            highlight: {

                                background:
                                    "#1e293b",

                                border:
                                    "#38bdf8"

                            }

                        },

                        font: {

                            color:
                                colorTheme.text,

                            size:
                                fontSize,

                            face:
                                "system-ui",

                            multi:
                                true,

                            align:
                                "center"

                        },

                        shadow: {

                            enabled:
                                true,

                            color:
                                "rgba(0,0,0,0.6)",

                            size:
                                8,

                            x:
                                2,

                            y:
                                2

                        }

                    });


                    /* -------------------------------------------------
                       Edges
                    ------------------------------------------------- */

                    if (
                        Array.isArray(
                            service.connects_to
                        )
                    ) {

                        service.connects_to.forEach(
                            function(target) {

                                /*
                                 * Only create an edge if the target
                                 * actually exists.
                                 */
                                if (
                                    allNodesData[target]
                                ) {

                                    edges.push({

                                        from:
                                            service.id,

                                        to:
                                            target,

                                        arrows:
                                            "to",

                                        color: {

                                            color:
                                                "#475569",

                                            highlight:
                                                "#38bdf8"

                                        },

                                        width:
                                            2

                                    });

                                }

                            }
                        );

                    }

                }
            );

        }
    );


    /* -----------------------------------------------------
       Rebuild DataSets
    ----------------------------------------------------- */

    const container =
        document.getElementById(
            "network-container"
        );


    nodesDataSet =
        new vis.DataSet(nodes);

    edgesDataSet =
        new vis.DataSet(edges);


    const graphData = {

        nodes:
            nodesDataSet,

        edges:
            edgesDataSet

    };


    const physicsEnabled =
        physicsToggle.checked;


    const options = {

        autoResize: true,

        physics: {

            enabled:
                physicsEnabled,

            barnesHut: {

                gravitationalConstant:
                    -5000,

                centralGravity:
                    0.3,

                springLength:
                    180,

                nodeDistance:
                    140,

                avoidOverlap:
                    1.0

            }

        },

        interaction: {

            hover:
                true,

            navigationButtons:
                false,

            keyboard:
                true

        },

        edges: {

            smooth: {

                enabled:
                    true,

                type:
                    "dynamic"

            }

        }

    };


    /*
     * Destroy old network before replacing it.
     * This prevents multiple vis-network instances
     * from accumulating after importance changes.
     */

    if (network) {

        network.destroy();

        network = null;

    }


    network =
        new vis.Network(
            container,
            graphData,
            options
        );


    /* -----------------------------------------------------
       Click handler
    ----------------------------------------------------- */

    network.on(
        "click",
        function(params) {

            if (
                params.nodes &&
                params.nodes.length > 0
            ) {

                const nodeId =
                    params.nodes[0];

                selectedNodeIdForInspector =
                    nodeId;

                showInspector(
                    allNodesData[nodeId]
                );

            } else {

                hideInspector();

            }

        }
    );

}


/* =========================================================
   LAYER SELECTOR
========================================================= */

function populateLayerSelector(layers) {

    newNodeLayer.innerHTML = "";


    if (!Array.isArray(layers)) {
        return;
    }


    layers.forEach(
        function(layer, index) {

            const option =
                document.createElement(
                    "option"
                );

            option.value =
                String(index);

            option.textContent =
                layer.name;

            newNodeLayer.appendChild(
                option
            );

        }
    );

}


/* =========================================================
   PHYSICS
========================================================= */

physicsToggle.addEventListener(
    "change",
    function(event) {

        if (network) {

            network.setOptions({

                physics: {

                    enabled:
                        event.target.checked

                }

            });

        }

    }
);


/* =========================================================
   IMPORTANCE
========================================================= */

importanceToggle.addEventListener(
    "change",
    function() {

        if (
            rawTopologyData &&
            rawTopologyData.homelab_environment &&
            rawTopologyData.homelab_environment.layers
        ) {

            buildGraph(
                rawTopologyData
                    .homelab_environment
                    .layers
            );

            applySearchFilter();

        }

    }
);


/* =========================================================
   INSPECTOR
========================================================= */

function showInspector(service) {

    if (!service) {
        return;
    }


    document.getElementById(
        "panelTitle"
    ).innerText =
        service.name || service.id;


    document.getElementById(
        "panelId"
    ).innerText =
        service.id || "-";


    document.getElementById(
        "panelLayer"
    ).innerText =
        service.layerName || "-";


    document.getElementById(
        "panelType"
    ).innerText =
        service.type || "-";


    document.getElementById(
        "panelStatus"
    ).innerText =
        service.status || "Running";


    document.getElementById(
        "panelUptime"
    ).innerText =
        service.uptime || "N/A";


    document.getElementById(
        "panelTraffic"
    ).innerText =
        `Out: ${
            service.traffic_out || "0 MB"
        } / In: ${
            service.traffic_in || "0 MB"
        }`;


    document.getElementById(
        "panelPorts"
    ).innerText =
        Array.isArray(service.ports) &&
        service.ports.length > 0
            ? service.ports.join(", ")
            : "None / Internal";


    document.getElementById(
        "panelConfig"
    ).innerText =
        service.config_path || "N/A";


    const scriptList =
        document.getElementById(
            "panelScripts"
        );

    scriptList.innerHTML = "";


    if (
        Array.isArray(
            service.scripts_associated
        ) &&
        service.scripts_associated.length > 0
    ) {

        service.scripts_associated.forEach(
            function(script) {

                const li =
                    document.createElement(
                        "li"
                    );

                li.innerText =
                    script;

                scriptList.appendChild(
                    li
                );

            }
        );

    } else {

        const li =
            document.createElement(
                "li"
            );

        li.innerText =
            "No associated scripts";

        scriptList.appendChild(
            li
        );

    }


    /* -----------------------------------------------------
       Delete button only exists while editor is unlocked.
    ----------------------------------------------------- */

    const editActions =
        document.getElementById(
            "editNodeActions"
        );


    if (
        isEditorUnlocked
    ) {

        editActions.classList.remove(
            "hidden"
        );

        editActions.classList.add(
            "flex"
        );

    } else {

        editActions.classList.add(
            "hidden"
        );

        editActions.classList.remove(
            "flex"
        );

    }


    inspectorPanel.classList.remove(
        "translate-x-full"
    );

}


function hideInspector() {

    inspectorPanel.classList.add(
        "translate-x-full"
    );

    selectedNodeIdForInspector =
        null;

}


/* =========================================================
   CLOSE INSPECTOR
========================================================= */

closePanel.addEventListener(
    "click",
    hideInspector
);


/* =========================================================
   SEARCH
========================================================= */

searchInput.addEventListener(
    "input",
    function() {

        applySearchFilter();

    }
);


function applySearchFilter() {

    if (!nodesDataSet) {
        return;
    }


    const query =
        searchInput.value
            .toLowerCase()
            .trim();


    const nodeIds =
        nodesDataSet.getIds();


    if (!query) {

        const updates =
            nodeIds.map(
                function(id) {

                    const original =
                        originalNodeStyles[id];

                    if (!original) {
                        return { id: id };
                    }

                    return {

                        id: id,

                        color: {

                            background:
                                original.background,

                            border:
                                original.border

                        },

                        font: {

                            color:
                                original.textColor,

                            size:
                                original.fontSize

                        }

                    };

                }
            );


        nodesDataSet.update(
            updates
        );

        return;

    }


    const matchedIds =
        nodeIds.filter(
            function(id) {

                const service =
                    allNodesData[id];

                if (!service) {
                    return false;
                }

                const name =
                    String(
                        service.name || ""
                    ).toLowerCase();

                const type =
                    String(
                        service.type || ""
                    ).toLowerCase();

                const serviceId =
                    String(
                        service.id || ""
                    ).toLowerCase();

                return (
                    name.includes(query) ||
                    type.includes(query) ||
                    serviceId.includes(query)
                );

            }
        );


    const matchedSet =
        new Set(matchedIds);


    const updates =
        nodeIds.map(
            function(id) {

                const original =
                    originalNodeStyles[id];

                if (!original) {
                    return { id: id };
                }


                if (
                    matchedSet.has(id)
                ) {

                    return {

                        id: id,

                        color: {

                            background:
                                "#0284c7",

                            border:
                                "#38bdf8"

                        },

                        font: {

                            color:
                                "#ffffff",

                            size:
                                original.fontSize + 2

                        }

                    };

                }


                return {

                    id: id,

                    color: {

                        background:
                            "#030712",

                        border:
                            "#1e293b"

                    },

                    font: {

                        color:
                            "#334155",

                        size:
                            original.fontSize

                    }

                };

            }
        );


    nodesDataSet.update(
        updates
    );


    /* -----------------------------------------------------
       Exactly one result = cinematic spotlight
    ----------------------------------------------------- */

    if (
        matchedIds.length === 1 &&
        network
    ) {

        const singleMatchId =
            matchedIds[0];


        network.selectNodes(
            [singleMatchId]
        );


        showInspector(
            allNodesData[
                singleMatchId
            ]
        );


        network.focus(
            singleMatchId,
            {

                scale:
                    1.4,

                animation: {

                    duration:
                        800,

                    easingFunction:
                        "easeInOutQuad"

                }

            }
        );

    }

}


/* =========================================================
   UNLOCK EDITOR
========================================================= */

unlockEditorBtn.addEventListener(
    "click",
    async function() {

        const password =
            adminPasswordInput.value;


        if (!password) {

            alert(
                "Please enter the admin password."
            );

            return;

        }


        unlockEditorBtn.disabled =
            true;


        unlockEditorBtn.innerText =
            "Checking...";


        try {

            const response =
                await fetch(
                    "/api/auth",
                    {

                        method:
                            "POST",

                        headers: {

                            "Content-Type":
                                "application/json"

                        },

                        body:
                            JSON.stringify({
                                password:
                                    password
                            })

                    }
                );


            const data =
                await response.json();


            if (
                response.ok &&
                data.authenticated
            ) {

                isEditorUnlocked =
                    true;

                currentAdminPassword =
                    password;


                authContainer.classList.add(
                    "hidden"
                );


                editorControls.classList.remove(
                    "hidden"
                );


                editorControls.classList.add(
                    "flex"
                );


                adminPasswordInput.value =
                    "";


                if (
                    selectedNodeIdForInspector &&
                    allNodesData[
                        selectedNodeIdForInspector
                    ]
                ) {

                    showInspector(
                        allNodesData[
                            selectedNodeIdForInspector
                        ]
                    );

                }


                alert(
                    "Editor unlocked."
                );

            } else {

                alert(
                    data.error ||
                    "Invalid admin password."
                );

                adminPasswordInput.select();

            }

        } catch (error) {

            console.error(error);

            alert(
                "Unable to contact the authentication service."
            );

        } finally {

            unlockEditorBtn.disabled =
                false;

            unlockEditorBtn.innerText =
                "🔓 Unlock Editor";

        }

    }
);


/* =========================================================
   ENTER KEY FOR PASSWORD
========================================================= */

adminPasswordInput.addEventListener(
    "keydown",
    function(event) {

        if (
            event.key === "Enter"
        ) {

            unlockEditorBtn.click();

        }

    }
);


/* =========================================================
   LOCK EDITOR
========================================================= */

lockEditorBtn.addEventListener(
    "click",
    function() {

        isEditorUnlocked =
            false;

        currentAdminPassword =
            "";

        authContainer.classList.remove(
            "hidden"
        );

        editorControls.classList.add(
            "hidden"
        );

        editorControls.classList.remove(
            "flex"
        );


        document
            .getElementById(
                "editNodeActions"
            )
            .classList.add(
                "hidden"
            );

        document
            .getElementById(
                "editNodeActions"
            )
            .classList.remove(
                "flex"
            );

    }
);


/* =========================================================
   OPEN ADD NODE MODAL
========================================================= */

openAddNodeModal.addEventListener(
    "click",
    function() {

        if (!isEditorUnlocked) {

            alert(
                "Please unlock the editor first."
            );

            return;

        }


        newNodeId.value =
            "";

        newNodeName.value =
            "";

        newNodeType.value =
            "";


        addNodeModal.classList.remove(
            "hidden"
        );

    }
);


/* =========================================================
   CLOSE ADD NODE MODAL
========================================================= */

cancelAddNode.addEventListener(
    "click",
    function() {

        addNodeModal.classList.add(
            "hidden"
        );

    }
);


addNodeModal.addEventListener(
    "click",
    function(event) {

        if (
            event.target ===
            addNodeModal
        ) {

            addNodeModal.classList.add(
                "hidden"
            );

        }

    }
);


/* =========================================================
   ADD NODE
========================================================= */

confirmAddNode.addEventListener(
    "click",
    function() {

        if (!isEditorUnlocked) {

            alert(
                "Editor is locked."
            );

            return;

        }


        const id =
            newNodeId.value
                .trim()
                .toLowerCase()
                .replace(
                    /[^a-z0-9_-]/g,
                    ""
                );


        const name =
            newNodeName.value.trim();


        const type =
            newNodeType.value.trim();


        const layerIndex =
            parseInt(
                newNodeLayer.value,
                10
            );


        if (!id) {

            alert(
                "Please enter a valid service ID."
            );

            return;

        }


        if (!name) {

            alert(
                "Please enter a display name."
            );

            return;

        }


        if (!type) {

            alert(
                "Please enter a service type."
            );

            return;

        }


        if (
            !rawTopologyData ||
            !rawTopologyData.homelab_environment ||
            !Array.isArray(
                rawTopologyData
                    .homelab_environment
                    .layers
            )
        ) {

            alert(
                "Topology data is not available."
            );

            return;

        }


        /* Prevent duplicate IDs */

        if (
            allNodesData[id]
        ) {

            alert(
                "A node with that ID already exists."
            );

            return;

        }


        const layers =
            rawTopologyData
                .homelab_environment
                .layers;


        const layer =
            layers[layerIndex];


        if (!layer) {

            alert(
                "Invalid target layer."
            );

            return;

        }


        if (
            !Array.isArray(
                layer.services
            )
        ) {

            layer.services = [];

        }


        const newService = {

            id:
                id,

            name:
                name,

            type:
                type,

            ports:
                [],

            config_path:
                "",

            connects_to:
                [],

            scripts_associated:
                [],

            status:
                "Running",

            uptime:
                "New",

            traffic_out:
                "0 MB",

            traffic_in:
                "0 MB"

        };


        layer.services.push(
            newService
        );


        addNodeModal.classList.add(
            "hidden"
        );


        populateLayerSelector(
            layers
        );


        buildGraph(
            layers
        );


        /* Automatically select the new node */

        if (
            network &&
            allNodesData[id]
        ) {

            network.selectNodes(
                [id]
            );

            showInspector(
                allNodesData[id]
            );

            network.focus(
                id,
                {

                    scale:
                        1.3,

                    animation: {

                        duration:
                            600,

                        easingFunction:
                            "easeInOutQuad"

                    }

                }
            );

        }


        alert(
            "Node added.\n\nRemember to click 'Save All to YAML' to permanently save it."
        );

    }
);


/* =========================================================
   DELETE NODE
========================================================= */

deleteNodeBtn.addEventListener(
    "click",
    function() {

        if (!isEditorUnlocked) {

            alert(
                "Editor is locked."
            );

            return;

        }


        const nodeId =
            selectedNodeIdForInspector;


        if (!nodeId) {

            alert(
                "No node selected."
            );

            return;

        }


        const service =
            allNodesData[nodeId];


        if (!service) {

            return;

        }


        const confirmed =
            confirm(
                `Delete "${service.name}" (${nodeId})?\n\nThis will remove the node from the current editor state. Click "Save All to YAML" afterward to permanently save the deletion.`
            );


        if (!confirmed) {
            return;
        }


        const layers =
            rawTopologyData
                .homelab_environment
                .layers;


        layers.forEach(
            function(layer) {

                if (
                    Array.isArray(
                        layer.services
                    )
                ) {

                    layer.services =
                        layer.services.filter(
                            function(item) {

                                return (
                                    item.id !==
                                    nodeId
                                );

                            }
                        );

                }

            }
        );


        /*
         * Remove references to deleted node
         * from connects_to arrays.
         */

        layers.forEach(
            function(layer) {

                if (
                    !Array.isArray(
                        layer.services
                    )
                ) {
                    return;
                }


                layer.services.forEach(
                    function(item) {

                        if (
                            Array.isArray(
                                item.connects_to
                            )
                        ) {

                            item.connects_to =
                                item.connects_to.filter(
                                    function(target) {

                                        return (
                                            target !==
                                            nodeId
                                        );

                                    }
                                );

                        }

                    }
                );

            }
        );


        selectedNodeIdForInspector =
            null;


        hideInspector();


        buildGraph(
            layers
        );


        alert(
            "Node deleted from the current editor state.\n\nClick 'Save All to YAML' to permanently save the deletion."
        );

    }
);


/* =========================================================
   SAVE TO YAML
========================================================= */

saveYamlBtn.addEventListener(
    "click",
    async function() {

        if (!isEditorUnlocked) {

            alert(
                "Editor is locked."
            );

            return;

        }


        if (!rawTopologyData) {

            alert(
                "No topology data available."
            );

            return;

        }


        const confirmed =
            confirm(
                "Save all current topology changes to homelabmap.yaml?"
            );


        if (!confirmed) {
            return;
        }


        saveYamlBtn.disabled =
            true;

        saveYamlBtn.innerText =
            "Saving...";


        try {

            const response =
                await fetch(
                    "/api/topology",
                    {

                        method:
                            "POST",

                        headers: {

                            "Content-Type":
                                "application/json",

                            "X-Admin-Password":
                                currentAdminPassword

                        },

                        body:
                            JSON.stringify(
                                rawTopologyData
                            )

                    }
                );


            const data =
                await response.json();


            if (
                response.ok &&
                data.status === "success"
            ) {

                alert(
                    "✓ Topology saved successfully to homelabmap.yaml."
                );

            } else {

                alert(
                    data.error ||
                    "Failed to save topology."
                );

            }

        } catch (error) {

            console.error(error);

            alert(
                "Unable to save topology."
            );

        } finally {

            saveYamlBtn.disabled =
                false;

            saveYamlBtn.innerText =
                "💾 Save All to YAML";

        }

    }
);


/* =========================================================
   INITIAL STARTUP
========================================================= */

fetchTopology();

fetchStats();

setInterval(
    fetchStats,
    5000
);

</script>


</body>

</html>

HTMLEOF


# ============================================================
# OWNERSHIP
# ============================================================

sudo chown "$CURRENT_USER:$CURRENT_USER" "$PYTHON_APP_PATH"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$TEMPLATE_PATH"


# ============================================================
# SYSTEMD SERVICE
# ============================================================

echo "[*] Configuring systemd service for Homelab Topology V1.4..."

sudo tee "$SERVICE_PATH" > /dev/null << EOF
[Unit]
Description=Homelab Topology Visualizer & Management Console V1.4
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $PYTHON_APP_PATH
Restart=always
RestartSec=3

# Basic hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF


# ============================================================
# SYSTEMD START
# ============================================================

sudo systemctl daemon-reload

sudo systemctl enable homelab-map.service

sudo systemctl restart homelab-map.service


# ============================================================
# VERIFY SERVICE
# ============================================================

sleep 2

if sudo systemctl is-active --quiet homelab-map.service; then

    echo
    echo "============================================================"
    echo " V1.4 INSTALLATION COMPLETE"
    echo "============================================================"
    echo
    echo "[+] Homelab Topology V1.4 is running."
    echo
    echo "    Port: $PORT"
    echo "    User: $CURRENT_USER"
    echo "    App:  $APP_DIR"
    echo
    echo "    Open:"
    echo "    http://$(hostname -I | awk '{print $1}'):$PORT"
    echo
    echo "------------------------------------------------------------"
    echo " Editor behavior:"
    echo "   • Viewing the page requires NO password."
    echo "   • Click Settings & Editor to access editor controls."
    echo "   • Enter the admin password only when unlocking editor."
    echo "   • Add/Delete changes remain in memory until saved."
    echo "   • Save All to YAML writes changes to homelabmap.yaml."
    echo "------------------------------------------------------------"
    echo

else

    echo
    echo "[!] WARNING: homelab-map.service did not start correctly."
    echo
    echo "[*] Check the service with:"
    echo
    echo "    sudo systemctl status homelab-map.service"
    echo
    echo "    sudo journalctl -u homelab-map.service -n 100 --no-pager"
    echo

    exit 1

fi
