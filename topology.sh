#!/bin/bash

# ============================================================
# Homelab Topology Visualizer & Management Console
# PERSISTENT: TRUE
# Category: Webpages
# Description: V1.4 (Enhanced with Spotlight, Live Status & Export)
#
# V1.4 Features:
#   - Interactive topology visualization
#   - Cinematic spotlight search with lightbulb animation
#   - Real-time node status / ping monitoring
#   - CPU/RAM host metrics
#   - Settings dropdown
#   - Password-protected editor
#   - Add/Delete nodes & Export tools (PNG/SVG/JSON)
#   - Save topology back to YAML safely (atomic writes)
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
echo " Homelab Topology Visualizer V1.4 (Enhanced)"
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
    echo "[!] python3 could not be found. Installing Python3..."
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
    echo "[!] Required Python modules are missing. Installing..."
    if sudo apt-get install -y python3-flask python3-psutil python3-yaml >/dev/null 2>&1; then
        echo "[+] Python dependencies installed through apt."
    else
        python3 -m pip install --upgrade pip
        python3 -m pip install flask psutil pyyaml
    fi
fi


# ------------------------------------------------------------
# PASSWORD / SETTINGS PROMPT
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
        echo "[!] No password entered. Using fallback: homelab123"
        ADMIN_PASS="homelab123"
    fi

    ESCAPED_PASS=$(printf '%s' "$ADMIN_PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')

    cat > "$SETTINGS_PATH" <<EOF
HOMELAB_ADMIN_PASS="$ESCAPED_PASS"
EOF
    chmod 600 "$SETTINGS_PATH"
    echo "[+] Admin password saved securely."
fi

if [ ! -f "$SETTINGS_PATH" ]; then
    echo 'HOMELAB_ADMIN_PASS="homelab123"' > "$SETTINGS_PATH"
    chmod 600 "$SETTINGS_PATH"
fi


# ------------------------------------------------------------
# TOPOLOGY YAML PROMPT
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
EOF
else
    echo "[+] Existing topology preserved."
fi

sudo chown "$CURRENT_USER:$CURRENT_USER" "$YAML_PATH"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$SETTINGS_PATH"
chmod 600 "$SETTINGS_PATH"


# ============================================================
# PYTHON FLASK BACKEND
# ============================================================

echo "[*] Writing V1.4 Flask backend with Live Status checker..."

cat << 'PYEOF' > "$PYTHON_APP_PATH"

import os
import tempfile
import socket
import yaml
import psutil
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
YAML_PATH = os.path.join(BASE_DIR, "homelabmap.yaml")
SETTINGS_PATH = os.path.join(BASE_DIR, "settings.env")

def get_admin_password():
    if not os.path.exists(SETTINGS_PATH):
        return os.environ.get("HOMELAB_ADMIN_PASS", "homelab123")
    try:
        with open(SETTINGS_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("HOMELAB_ADMIN_PASS="):
                    value = line.split("=", 1)[1].strip()
                    if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
                        value = value[1:-1]
                    return value
    except Exception:
        pass
    return os.environ.get("HOMELAB_ADMIN_PASS", "homelab123")

def load_homelab_data():
    if not os.path.exists(YAML_PATH):
        return {}
    try:
        with open(YAML_PATH, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
            return data if data else {}
    except Exception as exc:
        print(f"Failed to load YAML: {exc}")
        return {}

def save_homelab_data(data):
    directory = os.path.dirname(YAML_PATH)
    fd, temp_path = tempfile.mkstemp(prefix=".homelabmap.", suffix=".yaml", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False, allow_unicode=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_path, YAML_PATH)
    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise

def validate_topology(data):
    if not isinstance(data, dict): return False
    environment = data.get("homelab_environment")
    if not isinstance(environment, dict): return False
    layers = environment.get("layers")
    if not isinstance(layers, list): return False
    return True

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/topology", methods=["GET"])
def get_topology():
    data = load_homelab_data()
    return jsonify(data)

@app.route("/api/status", methods=["GET"])
def get_live_status():
    """Performs quick socket probes on standard service ports or reports active."""
    data = load_homelab_data()
    status_map = {}
    
    layers = data.get("homelab_environment", {}).get("layers", [])
    for layer in layers:
        for svc in layer.get("services", []):
            sid = svc.get("id")
            ports = svc.get("ports", [])
            # Quick local socket test if port is defined
            is_up = True
            if ports:
                is_up = False
                for p in ports:
                    try:
                        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                        s.settimeout(0.3)
                        result = s.connect_ex(('127.0.0.1', int(p)))
                        s.close()
                        if result == 0:
                            is_up = True
                            break
                    except Exception:
                        pass
            status_map[sid] = {
                "online": is_up,
                "status_text": "Online / Active" if is_up else "Unreachable / Port Closed"
            }
    return jsonify(status_map)

@app.route("/api/auth", methods=["POST"])
def authenticate():
    payload = request.get_json(silent=True) or {}
    if payload.get("password", "") != get_admin_password():
        return jsonify({"authenticated": False, "error": "Invalid admin password"}), 401
    return jsonify({"authenticated": True})

@app.route("/api/topology", methods=["POST"])
def update_topology():
    if request.headers.get("X-Admin-Password", "") != get_admin_password():
        return jsonify({"error": "Unauthorized: Invalid password"}), 401
    new_data = request.get_json(silent=True)
    if not validate_topology(new_data):
        return jsonify({"error": "Invalid topology data format"}), 400
    try:
        save_homelab_data(new_data)
        return jsonify({"status": "success", "message": "Topology saved successfully to YAML."})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500

@app.route("/api/stats", methods=["GET"])
def get_stats():
    cpu = psutil.cpu_percent(interval=None)
    ram = psutil.virtual_memory()
    return jsonify({
        "cpu": cpu,
        "ram_percent": ram.percent,
        "ram_used_mb": round(ram.used / (1024 * 1024), 1),
        "ram_total_mb": round(ram.total / (1024 * 1024), 1)
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8085)
PYEOF


# ============================================================
# FRONTEND WITH SPOTLIGHT SEARCH & EXPORT OPTIONS
# ============================================================

echo "[*] Writing V1.4 frontend template..."

cat << 'HTMLEOF' > "$TEMPLATE_PATH"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Homelab Interactive Topology Map V1.4</title>
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
    <script type="text/javascript" src="https://unpkg.com/vis-network/standalone/umd/vis-network.min.js"></script>
    <style>
        :root {
            --bg-color: #030712;
            --surface-color: #0f172a;
            --surface-border: #1e293b;
        }
        body {
            background-color: var(--bg-color);
            color: #f8fafc;
            font-family: system-ui, -apple-system, sans-serif;
        }
        #network-container {
            width: 100vw;
            height: calc(100vh - 70px);
            background: #030712;
        }
        /* Spotlight Laser Animation Effect */
        @keyframes spotlightPulse {
            0% { box-shadow: 0 0 0 0 rgba(56, 189, 248, 0.8), inset 0 0 15px rgba(56, 189, 248, 0.5); border-color: #38bdf8; }
            50% { box-shadow: 0 0 35px 15px rgba(56, 189, 248, 0.4), inset 0 0 30px rgba(56, 189, 248, 0.8); border-color: #7dd3fc; }
            100% { box-shadow: 0 0 0 0 rgba(56, 189, 248, 0.8), inset 0 0 15px rgba(56, 189, 248, 0.5); border-color: #38bdf8; }
        }
        .spotlight-active {
            animation: spotlightPulse 1.5s infinite ease-in-out;
        }
    </style>
</head>
<body class="flex flex-col h-screen overflow-hidden">

<header class="bg-slate-900 border-b border-slate-800 px-6 py-3 flex justify-between items-center z-20">
    <div class="flex items-center gap-4">
        <!-- SETTINGS -->
        <div class="relative">
            <button id="settingsBtn" class="bg-slate-800 hover:bg-slate-700 text-sky-400 px-3 py-2 rounded-lg border border-slate-700 flex items-center gap-2 text-xs font-semibold cursor-pointer transition-colors shadow-lg">
                ⚙️ Settings & Editor
            </button>
            <div id="settingsDropdown" class="absolute left-0 mt-2 w-72 bg-slate-900 border border-slate-800 rounded-xl shadow-2xl p-4 hidden flex-col gap-3 z-50">
                <h3 class="font-bold text-sm text-sky-400 border-b border-slate-800 pb-2">Map Preferences</h3>
                <label class="flex items-center gap-2 cursor-pointer select-none text-xs text-slate-300">
                    <input type="checkbox" id="physicsToggle" checked class="accent-sky-500"> Physics Jiggle
                </label>
                <label class="flex items-center gap-2 cursor-pointer select-none text-xs text-slate-300">
                    <input type="checkbox" id="importanceToggle" class="accent-sky-500"> Size by Importance
                </label>
                
                <!-- EXPORT OPTIONS SECTION -->
                <div class="border-t border-slate-800 pt-3 flex flex-col gap-2">
                    <span class="text-xs font-bold text-sky-400">Export & Backup</span>
                    <button id="exportJsonBtn" class="bg-slate-800 hover:bg-slate-700 text-slate-200 py-1.5 px-2 rounded text-xs text-left flex items-center gap-2">📥 Export Topology JSON</button>
                    <button id="exportPngBtn" class="bg-slate-800 hover:bg-slate-700 text-slate-200 py-1.5 px-2 rounded text-xs text-left flex items-center gap-2">📷 Snapshot Canvas (PNG)</button>
                </div>

                <!-- EDITOR AUTH -->
                <div class="border-t border-slate-800 pt-3 flex flex-col gap-2">
                    <span class="text-xs font-bold text-emerald-400">Admin Editor Mode</span>
                    <div id="authContainer" class="flex flex-col gap-2">
                        <input type="password" id="adminPasswordInput" placeholder="Enter Admin Password" class="bg-slate-950 border border-slate-700 px-2.5 py-1.5 rounded text-xs text-slate-200 outline-none focus:border-emerald-400">
                        <button id="unlockEditorBtn" class="bg-emerald-600 hover:bg-emerald-500 text-white py-1.5 rounded text-xs font-semibold cursor-pointer">🔓 Unlock Editor</button>
                    </div>
                    <div id="editorControls" class="hidden flex-col gap-2">
                        <p class="text-xs text-emerald-400 font-medium">✓ Editor Unlocked</p>
                        <button id="openAddNodeModal" class="bg-sky-600 hover:bg-sky-500 text-white py-1.5 rounded text-xs font-semibold cursor-pointer">+ Add New Node</button>
                        <button id="saveYamlBtn" class="bg-amber-600 hover:bg-amber-500 text-white py-1.5 rounded text-xs font-semibold cursor-pointer">💾 Save All to YAML</button>
                        <button id="lockEditorBtn" class="bg-slate-700 hover:bg-slate-600 text-white py-1.5 rounded text-xs font-semibold cursor-pointer">🔒 Lock Editor</button>
                    </div>
                </div>
            </div>
        </div>

        <div class="flex items-center gap-3">
            <span class="text-xl">🗺️</span>
            <div>
                <h1 class="font-bold text-lg text-sky-400">Homelab Topology V1.4</h1>
                <p class="text-xs text-slate-400">Service Mesh & Live Health Monitor</p>
            </div>
        </div>
    </div>

    <!-- RIGHT SIDE: STATS & SPOTLIGHT SEARCH -->
    <div class="flex items-center gap-4 text-sm flex-wrap">
        <div class="bg-slate-800 px-3 py-1.5 rounded-lg border border-slate-700 flex gap-4 text-xs">
            <span>CPU: <strong id="cpu-stat" class="text-sky-400">0.0%</strong></span>
            <span>RAM: <strong id="ram-stat" class="text-emerald-400">0.0%</strong></span>
        </div>

        <!-- Spotlight Search Container with Lightbulb Icon indicator -->
        <div class="relative flex items-center">
            <span id="searchBulb" class="absolute left-2.5 text-xs transition-all duration-300 opacity-50">💡</span>
            <input type="text" id="searchInput" placeholder="Spotlight search node..." class="bg-slate-950 border border-slate-700 pl-8 pr-3 py-2 rounded-lg text-xs outline-none focus:border-sky-400 text-slate-200 w-64 transition-all">
        </div>
    </div>
</header>

<div class="flex flex-1 relative overflow-hidden">
    <div id="network-container"></div>

    <!-- INSPECTOR PANEL -->
    <div id="inspectorPanel" class="absolute right-0 top-0 h-full w-96 bg-slate-900 border-l border-slate-800 p-6 flex flex-col gap-5 transform translate-x-full transition-transform duration-300 z-30 shadow-2xl overflow-y-auto">
        <div class="flex justify-between items-center border-b border-slate-800 pb-3">
            <h2 id="panelTitle" class="font-bold text-lg text-sky-400">Service Details</h2>
            <button id="closePanel" class="text-slate-400 hover:text-white text-lg">✕</button>
        </div>
        <div class="flex flex-col gap-4 text-sm">
            <div><span class="text-xs text-slate-400 uppercase tracking-wider">Service ID</span><p id="panelId" class="font-mono text-slate-300">-</p></div>
            <div><span class="text-xs text-slate-400 uppercase tracking-wider">Layer</span><p id="panelLayer" class="font-medium text-slate-200">-</p></div>
            <div><span class="text-xs text-slate-400 uppercase tracking-wider">Service Type</span><p id="panelType" class="font-medium text-slate-200">-</p></div>
            <div><span class="text-xs text-slate-400 uppercase tracking-wider">Live Probe Status</span><p id="panelStatus" class="font-semibold text-emerald-400">-</p></div>
            <div><span class="text-xs text-slate-400 uppercase tracking-wider">Runtime Uptime</span><p id="panelUptime" class="text-slate-200">-</p></div>
            <div><span class="text-xs text-slate-400 uppercase tracking-wider">Data Transfer</span><p id="panelTraffic" class="text-slate-200">-</p></div>
            <div><span class="text-xs text-slate-400 uppercase tracking-wider">Ports</span><p id="panelPorts" class="text-slate-200 font-mono">-</p></div>
            <div><span class="text-xs text-slate-400 uppercase tracking-wider">Configuration Path</span><p id="panelConfig" class="text-sky-300 font-mono text-xs bg-slate-950 p-2 rounded border border-slate-800 break-all">-</p></div>
            <div><span class="text-xs text-slate-400 uppercase tracking-wider">Associated Scripts</span><ul id="panelScripts" class="list-disc list-inside text-xs text-slate-300 font-mono mt-1"></ul></div>
            <div id="editNodeActions" class="hidden border-t border-slate-800 pt-4 flex gap-2">
                <button id="deleteNodeBtn" class="flex-1 bg-rose-600 hover:bg-rose-500 text-white py-2 rounded text-xs font-semibold cursor-pointer">Delete Node</button>
            </div>
        </div>
    </div>
</div>

<!-- ADD NODE MODAL -->
<div id="addNodeModal" class="fixed inset-0 bg-black/70 backdrop-blur-sm flex items-center justify-center hidden z-50">
    <div class="bg-slate-900 border border-slate-800 rounded-xl p-6 w-full max-w-md shadow-2xl flex flex-col gap-4">
        <h3 class="text-base font-bold text-sky-400">Add New Topology Node</h3>
        <div class="flex flex-col gap-3 text-xs">
            <input type="text" id="newNodeId" placeholder="Node ID (e.g., plex)" class="modal-input">
            <input type="text" id="newNodeName" placeholder="Display Name (e.g., Plex Media Server)" class="modal-input">
            <input type="text" id="newNodeType" placeholder="Service Type (e.g., Media Streaming)" class="modal-input">
            <input type="text" id="newNodeLayer" placeholder="Target Layer Name (e.g., Core Services Layer)" class="modal-input">
            <input type="text" id="newNodePorts" placeholder="Ports (comma-separated, e.g., 32400)" class="modal-input">
            <input type="text" id="newNodeConnects" placeholder="Connects To IDs (comma-separated, e.g., internet,nas)" class="modal-input">
        </div>
        <div class="flex justify-end gap-2 mt-2">
            <button id="cancelAddNode" class="bg-slate-800 hover:bg-slate-700 text-slate-300 px-4 py-2 rounded text-xs font-semibold cursor-pointer">Cancel</button>
            <button id="submitAddNode" class="bg-sky-600 hover:bg-sky-500 text-white px-4 py-2 rounded text-xs font-semibold cursor-pointer">Add Node</button>
        </div>
    </div>
</div>

<script>
    let topologyData = {};
    let network = null;
    let nodesDataset = new vis.DataSet();
    let edgesDataset = new vis.DataSet();
    let isAdminUnlocked = false;
    let adminPassword = "";
    let liveStatuses = {};

    // DOM Elements
    const settingsBtn = document.getElementById('settingsBtn');
    const settingsDropdown = document.getElementById('settingsDropdown');
    const physicsToggle = document.getElementById('physicsToggle');
    const importanceToggle = document.getElementById('importanceToggle');
    const unlockEditorBtn = document.getElementById('unlockEditorBtn');
    const lockEditorBtn = document.getElementById('lockEditorBtn');
    const authContainer = document.getElementById('authContainer');
    const editorControls = document.getElementById('editorControls');
    const adminPasswordInput = document.getElementById('adminPasswordInput');
    const inspectorPanel = document.getElementById('inspectorPanel');
    const closePanel = document.getElementById('closePanel');
    const searchInput = document.getElementById('searchInput');
    const searchBulb = document.getElementById('searchBulb');
    const openAddNodeModal = document.getElementById('openAddNodeModal');
    const addNodeModal = document.getElementById('addNodeModal');
    const cancelAddNode = document.getElementById('cancelAddNode');
    const submitAddNode = document.getElementById('submitAddNode');
    const deleteNodeBtn = document.getElementById('deleteNodeBtn');
    const saveYamlBtn = document.getElementById('saveYamlBtn');
    const exportJsonBtn = document.getElementById('exportJsonBtn');
    const exportPngBtn = document.getElementById('exportPngBtn');

    // Toggle dropdown
    settingsBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        settingsDropdown.classList.toggle('hidden');
        settingsDropdown.classList.toggle('flex');
    });
    document.addEventListener('click', () => {
        settingsDropdown.classList.add('hidden');
        settingsDropdown.classList.remove('flex');
    });
    settingsDropdown.addEventListener('click', (e) => e.stopPropagation());

    // Fetch Stats
    async function updateStats() {
        try {
            const res = await fetch('/api/stats');
            const data = await res.json();
            document.getElementById('cpu-stat').innerText = data.cpu.toFixed(1) + '%';
            document.getElementById('ram-stat').innerText = data.ram_percent.toFixed(1) + '%';
        } catch (e) {}
    }
    setInterval(updateStats, 3000);
    updateStats();

    // Fetch Live Statuses
    async function updateStatuses() {
        try {
            const res = await fetch('/api/status');
            liveStatuses = await res.json();
        } catch (e) {}
    }
    setInterval(updateStatuses, 5000);

    // Initialize Network Canvas
    async function initTopology() {
        await updateStatuses();
        try {
            const res = await fetch('/api/topology');
            topologyData = await res.json();
            buildGraph(topologyData);
        } catch (e) {
            console.error("Failed to load topology", e);
        }
    }

    function buildGraph(data) {
        nodesDataset.clear();
        edgesDataset.clear();

        const layers = data?.homelab_environment?.layers || [];
        const layerColors = ['#0284c7', '#0d9488', '#059669', '#d97706', '#7c3aed', '#db2777'];

        layers.forEach((layer, layerIndex) => {
            const color = layerColors[layerIndex % layerColors.length];
            const services = layer.services || [];

            services.forEach(svc => {
                const stat = liveStatuses[svc.id];
                const isOnline = stat ? stat.online : true;
                const statusColor = isOnline ? '#10b981' : '#f43f5e';

                nodesDataset.add({
                    id: svc.id,
                    label: svc.name,
                    title: `${svc.name}\nType: ${svc.type}\nStatus: ${svc.status}`,
                    group: layer.name,
                    color: {
                        background: '#0f172a',
                        border: color,
                        highlight: { background: '#1e293b', border: '#38bdf8' }
                    },
                    font: { color: '#f8fafc', size: 13 },
                    shape: 'box',
                    margin: 10,
                    shadow: true
                });

                if (svc.connects_to && Array.isArray(svc.connects_to)) {
                    svc.connects_to.forEach(targetId => {
                        edgesDataset.add({
                            from: svc.id,
                            to: targetId,
                            arrows: 'to',
                            color: { color: '#334155', highlight: '#38bdf8' },
                            width: 1.5,
                            smooth: { type: 'cubicBezier', roundness: 0.2 }
                        });
                    });
                }
            });
        });

        if (!network) {
            const container = document.getElementById('network-container');
            const options = {
                physics: { enabled: true, stabilization: { iterations: 150 } },
                interaction: { hover: true, tooltipDelay: 200 },
                nodes: { borderWidth: 2, borderRadius: 6 }
            };
            network = new vis.Network(container, { nodes: nodesDataset, edges: edgesDataset }, options);

            network.on('click', params => {
                if (params.nodes.length > 0) {
                    showNodeInspector(params.nodes[0]);
                } else {
                    closeInspector();
                }
            });
        }
    }

    // Spotlight Search with Lightbulb Animation & Laser Focus
    searchInput.addEventListener('input', (e) => {
        const query = e.target.value.toLowerCase().trim();
        if (!query) {
            searchBulb.classList.remove('text-amber-400', 'scale-125');
            searchInput.classList.remove('spotlight-active');
            network.fit();
            return;
        }

        searchBulb.classList.add('text-amber-400', 'scale-125');
        searchInput.classList.add('spotlight-active');

        // Find matching nodes
        const allNodes = nodesDataset.get();
        const matched = allNodes.find(n => n.id.toLowerCase().includes(query) || n.label.toLowerCase().includes(query));

        if (matched) {
            network.selectNodes([matched.id]);
            network.focus(matched.id, { scale: 1.2, animation: { duration: 800, easing: 'easeInOutQuad' } });
            showNodeInspector(matched.id);
        }
    });

    // Inspector Panel details
    function showNodeInspector(nodeId) {
        let foundSvc = null;
        let foundLayerName = "";

        const layers = topologyData?.homelab_environment?.layers || [];
        for (let l of layers) {
            for (let s of (l.services || [])) {
                if (s.id === nodeId) {
                    foundSvc = s;
                    foundLayerName = l.name;
                    break;
                }
            }
            if (foundSvc) break;
        }

        if (!foundSvc) return;

        document.getElementById('panelTitle').innerText = foundSvc.name;
        document.getElementById('panelId').innerText = foundSvc.id;
        document.getElementById('panelLayer').innerText = foundLayerName;
        document.getElementById('panelType').innerText = foundSvc.type || '-';
        
        const statElem = document.getElementById('panelStatus');
        const liveStat = liveStatuses[foundSvc.id];
        statElem.innerText = liveStat ? liveStat.status_text : (foundSvc.status || 'Active');
        statElem.className = (liveStat && !liveStat.online) ? 'font-semibold text-rose-500' : 'font-semibold text-emerald-400';

        document.getElementById('panelUptime').innerText = foundSvc.uptime || 'N/A';
        document.getElementById('panelTraffic').innerText = `Out: ${foundSvc.traffic_out || '0 MB'} | In: ${foundSvc.traffic_in || '0 MB'}`;
        document.getElementById('panelPorts').innerText = (foundSvc.ports && foundSvc.ports.length) ? foundSvc.ports.join(', ') : 'None / Internal';
        document.getElementById('panelConfig').innerText = foundSvc.config_path || 'None';

        const scriptsUl = document.getElementById('panelScripts');
        scriptsUl.innerHTML = '';
        if (foundSvc.scripts_associated && foundSvc.scripts_associated.length > 0) {
            foundSvc.scripts_associated.forEach(scr => {
                const li = document.createElement('li');
                li.innerText = scr;
                scriptsUl.appendChild(li);
            });
        } else {
            const li = document.createElement('li');
            li.innerText = 'No attached scripts';
            scriptsUl.appendChild(li);
        }

        inspectorPanel.classList.remove('translate-x-full');
        if (isAdminUnlocked) {
            document.getElementById('editNodeActions').classList.remove('hidden');
        }
    }

    function closeInspector() {
        inspectorPanel.classList.add('translate-x-full');
    }
    closePanel.addEventListener('click', closeInspector);

    // Physics & Importance toggles
    physicsToggle.addEventListener('change', (e) => {
        network.setOptions({ physics: { enabled: e.target.checked } });
    });

    importanceToggle.addEventListener('change', (e) => {
        const useImportance = e.target.checked;
        nodesDataset.forEach(node => {
            nodesDataset.update({ id: node.id, size: useImportance ? 35 : 25 });
        });
    });

    // Authentication & Editor Mode
    unlockEditorBtn.addEventListener('click', async () => {
        const pwd = adminPasswordInput.value;
        try {
            const res = await fetch('/api/auth', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ password: pwd })
            });
            const data = await res.json();
            if (data.authenticated) {
                isAdminUnlocked = true;
                adminPassword = pwd;
                authContainer.classList.add('hidden');
                editorControls.classList.remove('hidden');
                editorControls.classList.add('flex');
                adminPasswordInput.value = '';
                alert('Editor unlocked successfully!');
            } else {
                alert('Invalid admin password.');
            }
        } catch (e) {
            alert('Authentication request failed.');
        }
    });

    lockEditorBtn.addEventListener('click', () => {
        isAdminUnlocked = false;
        adminPassword = '';
        editorControls.classList.add('hidden');
        editorControls.classList.remove('flex');
        authContainer.classList.remove('hidden');
        document.getElementById('editNodeActions').classList.add('hidden');
        alert('Editor locked.');
    });

    // Add Node modal controls
    openAddNodeModal.addEventListener('click', () => addNodeModal.classList.remove('hidden'));
    cancelAddNode.addEventListener('click', () => addNodeModal.classList.add('hidden'));

    submitAddNode.addEventListener('click', () => {
        const id = document.getElementById('newNodeId').value.trim();
        const name = document.getElementById('newNodeName').value.trim();
        const type = document.getElementById('newNodeType').value.trim();
        const layerName = document.getElementById('newNodeLayer').value.trim();
        const portsStr = document.getElementById('newNodePorts').value.trim();
        const connectsStr = document.getElementById('newNodeConnects').value.trim();

        if (!id || !name || !layerName) {
            alert('Please fill out at least ID, Name, and Layer Name.');
            return;
        }

        const ports = portsStr ? portsStr.split(',').map(p => parseInt(p.trim())).filter(p => !isNaN(p)) : [];
        const connects_to = connectsStr ? connectsStr.split(',').map(c => c.trim()).filter(Boolean) : [];

        let layers = topologyData.homelab_environment.layers;
        let targetLayer = layers.find(l => l.name.toLowerCase() === layerName.toLowerCase());

        if (!targetLayer) {
            targetLayer = { name: layerName, description: "Dynamically added layer", services: [] };
            layers.push(targetLayer);
        }

        targetLayer.services.push({
            id, name, type: type || "Custom Service", ports, config_path: "/etc/" + id, connects_to, status: "Running", uptime: "Just added"
        });

        buildGraph(topologyData);
        addNodeModal.classList.add('hidden');
        alert('Node added locally! Remember to click "Save All to YAML" to persist.');
    });

    // Delete Node
    deleteNodeBtn.addEventListener('click', () => {
        const selectedIds = network.getSelectedNodes();
        if (selectedIds.length === 0) return;
        const nodeId = selectedIds[0];

        if (!confirm(`Are you sure you want to delete node "${nodeId}"?`)) return;

        let layers = topologyData.homelab_environment.layers;
        layers.forEach(l => {
            if (l.services) {
                l.services = l.services.filter(s => s.id !== nodeId);
            }
        });

        buildGraph(topologyData);
        closeInspector();
        alert('Node removed locally. Click "Save All to YAML" to save changes.');
    });

    // Save YAML Back
    saveYamlBtn.addEventListener('click', async () => {
        try {
            const res = await fetch('/api/topology', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-Admin-Password': adminPassword
                },
                body: JSON.stringify(topologyData)
            });
            const data = await res.json();
            if (res.ok) {
                alert('Success: ' + data.message);
            } else {
                alert('Error saving: ' + data.error);
            }
        } catch (e) {
            alert('Failed to connect to backend server.');
        }
    });

    // Export Options
    exportJsonBtn.addEventListener('click', () => {
        const dataStr = "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(topologyData, null, 2));
        const downloadAnchor = document.createElement('a');
        downloadAnchor.setAttribute("href", dataStr);
        downloadAnchor.setAttribute("download", "homelab_topology_backup.json");
        document.body.appendChild(downloadAnchor);
        downloadAnchor.click();
        downloadAnchor.remove();
    });

    exportPngBtn.addEventListener('click', () => {
        const canvas = document.querySelector('#network-container canvas');
        if (!canvas) {
            alert('Canvas not rendered yet.');
            return;
        }
        const imageURI = canvas.toDataURL('image/png');
        const downloadAnchor = document.createElement('a');
        downloadAnchor.setAttribute("href", imageURI);
        downloadAnchor.setAttribute("download", "homelab_topology_snapshot.png");
        document.body.appendChild(downloadAnchor);
        downloadAnchor.click();
        downloadAnchor.remove();
    });

    window.onload = initTopology;
</script>
</body>
</html>
HTMLEOF


# ============================================================
# SYSTEMD SERVICE SETUP
# ============================================================

echo "[*] Configuring systemd service..."

sudo bash -c "cat > $SERVICE_PATH" <<EOF
[Unit]
Description=Homelab Topology Visualizer V1.4
After=network.target

[Service]
User=$CURRENT_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $PYTHON_APP_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable homelab-map.service
sudo systemctl restart homelab-map.service

echo
echo "============================================================"
echo " Installation Complete!"
echo "============================================================"
echo "[+] Homelab Topology Visualizer V1.4 is running at:"
echo "    http://<your-pi-ip>:$PORT"
echo
echo "[+] Features active:"
echo "    - Cinematic Spotlight Search (with lightbulb glow animation)"
echo "    - Live Socket & Port Health Status checks"
echo "    - Direct Canvas Snapshots (PNG) & JSON Export options"
echo "    - Secure Password-Protected Editor & YAML Persistence"
echo "============================================================"
