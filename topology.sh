#!/bin/bash

# Description: Homelab Topology Visualizer & Management Console
# PERSISTENT: TRUE
# Category: Webpages
# Version: V1.3 (With Cinematic Search & Filter Spotlight)

# Dynamically detect the real user even if run via sudo
if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$(whoami)"
fi

USER_HOME="$(eval echo ~$CURRENT_USER)"
APP_DIR="$USER_HOME/homelab-map"
PYTHON_APP_PATH="$APP_DIR/app.py"
YAML_PATH="$APP_DIR/homelabmap.yaml"
TEMPLATE_DIR="$APP_DIR/templates"
TEMPLATE_PATH="$TEMPLATE_DIR/index.html"
SERVICE_PATH="/etc/systemd/system/homelab-map.service"
PORT=8085

# Automatic Dependency Detection & Installation
echo "[*] Checking Python3 and pip environment..."
if ! command -v python3 &>/dev/null; then
    echo "[!] python3 could not be found. Installing python3..."
    sudo apt-get update && sudo apt-get install -y python3 python3-pip whiptail
elif ! command -v whiptail &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y whiptail
fi

if ! python3 -c "import flask, psutil, yaml" &>/dev/null; then
    echo "[!] Missing required Python modules (Flask, psutil, or pyyaml). Installing dependencies..."
    python3 -m pip install --upgrade pip
    python3 -m pip install flask psutil pyyaml
fi

# Create app directory
mkdir -p "$APP_DIR"
mkdir -p "$TEMPLATE_DIR"

# Check for existing YAML map or create default one
if [ -f "$YAML_PATH" ] && command -v whiptail &>/dev/null; then
    if (whiptail --title "Existing Homelab Map Found" --yesno "An existing homelabmap.yaml was detected. Would you like to keep your previous topology map settings?" 10 60); then
        KEEP_OLD_YAML=true
    fi
fi

if [ "$KEEP_OLD_YAML" != "true" ]; then
    echo "[*] Generating default homelabmap.yaml schema (V1.2 with Exit Nodes)..."
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
          scripts_associated: ["Caddy_Editor.sh", "SSLguide.sh"]
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
          scripts_associated: ["wireguard.sh"]
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
          scripts_associated: ["security_module_upgrade.sh"]
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
          scripts_associated: ["CubeCooler.py", "temp_monitor.sh", "discord_monitor.sh"]
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
fi

# Write Python Flask Application Backend
cat << 'EOF' > "$PYTHON_APP_PATH"
import os
import yaml
import psutil
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
YAML_PATH = os.path.join(BASE_DIR, 'homelabmap.yaml')

def load_homelab_data():
    if not os.path.exists(YAML_PATH):
        return {}
    with open(YAML_PATH, 'r') as f:
        return yaml.safe_load(f)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/topology', methods=['GET'])
def get_topology():
    data = load_homelab_data()
    return jsonify(data)

@app.route('/api/stats', methods=['GET'])
def get_stats():
    cpu = psutil.cpu_percent(interval=None)
    ram = psutil.virtual_memory()
    return jsonify({
        'cpu': cpu,
        'ram_percent': ram.percent,
        'ram_used_mb': round(ram.used / (1024 * 1024), 1),
        'ram_total_mb': round(ram.total / (1024 * 1024), 1)
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8085)
EOF

# Write Frontend HTML with Cinematic Spotlight Search Animation
cat << 'EOF' > "$TEMPLATE_PATH"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Homelab Interactive Topology Map V1.2</title>
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
    <script type="text/javascript" src="https://unpkg.com/vis-network/standalone/umd/vis-network.min.js"></script>
    <style>
        :root {
            --bg-color: #030712;
            --surface-color: #0f172a;
            --surface-border: #1e293b;
        }
        body { background-color: var(--bg-color); color: #f8fafc; font-family: system-ui, -apple-system, sans-serif; }
        #network-container { width: 100vw; height: calc(100vh - 70px); background: #030712; }
    </style>
</head>
<body class="flex flex-col h-screen overflow-hidden">
    <!-- Top Navigation Bar -->
    <header class="bg-slate-900 border-b border-slate-800 px-6 py-3 flex justify-between items-center z-20">
        <div class="flex items-center gap-3">
            <span class="text-xl">🗺️</span>
            <div>
                <h1 class="font-bold text-lg text-sky-400">Homelab Topology V1.2</h1>
                <p class="text-xs text-slate-400">Raspberry Pi 3B Service Mesh & Dependencies</p>
            </div>
        </div>
        <div class="flex items-center gap-4 text-sm flex-wrap">
            <div class="bg-slate-800 px-3 py-1.5 rounded-lg border border-slate-700 flex gap-4 text-xs">
                <span>CPU: <strong id="cpu-stat" class="text-sky-400">0.0%</strong></span>
                <span>RAM: <strong id="ram-stat" class="text-emerald-400">0.0%</strong></span>
            </div>
            
            <!-- V1.2 Controls -->
            <div class="flex items-center gap-2 bg-slate-950 px-3 py-1.5 rounded-lg border border-slate-800 text-xs">
                <label class="flex items-center gap-1.5 cursor-pointer select-none">
                    <input type="checkbox" id="physicsToggle" checked class="accent-sky-500"> Physics Jiggle
                </label>
                <span class="text-slate-700">|</span>
                <label class="flex items-center gap-1.5 cursor-pointer select-none">
                    <input type="checkbox" id="importanceToggle" class="accent-sky-500"> Size by Importance
                </label>
            </div>

            <input type="text" id="searchInput" placeholder="Search service (lights out animation)..." class="bg-slate-950 border border-slate-700 px-3 py-2 rounded-lg text-xs outline-none focus:border-sky-400 text-slate-200 w-64 transition-all">
        </div>
    </header>

    <div class="flex flex-1 relative overflow-hidden">
        <!-- Main Interactive Graph Canvas -->
        <div id="network-container"></div>

        <!-- Service Inspector Side Panel -->
        <div id="inspectorPanel" class="absolute right-0 top-0 h-full w-96 bg-slate-900 border-l border-slate-800 p-6 flex flex-col gap-5 transform translate-x-full transition-transform duration-300 z-30 shadow-2xl overflow-y-auto">
            <div class="flex justify-between items-center border-b border-slate-800 pb-3">
                <h2 id="panelTitle" class="font-bold text-lg text-sky-400">Service Details</h2>
                <button id="closePanel" class="text-slate-400 hover:text-white text-lg">✕</button>
            </div>
            <div class="flex flex-col gap-4 text-sm">
                <div>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Service Type</span>
                    <p id="panelType" class="font-medium text-slate-200">-</p>
                </div>
                <div>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Current Status</span>
                    <p id="panelStatus" class="font-semibold text-emerald-400">-</p>
                </div>
                <div>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Runtime Uptime</span>
                    <p id="panelUptime" class="text-slate-200">-</p>
                </div>
                <div>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Data Transfer (Out / In)</span>
                    <p id="panelTraffic" class="text-slate-200">-</p>
                </div>
                <div>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Ports</span>
                    <p id="panelPorts" class="text-slate-200 font-mono">-</p>
                </div>
                <div>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Configuration Path</span>
                    <p id="panelConfig" class="text-sky-300 font-mono text-xs bg-slate-950 p-2 rounded border border-slate-800 break-all">-</p>
                </div>
                <div>
                    <span class="text-xs text-slate-400 uppercase tracking-wider">Associated Scripts</span>
                    <ul id="panelScripts" class="list-disc list-inside text-xs text-slate-300 font-mono mt-1"></ul>
                </div>
            </div>
        </div>
    </div>

    <script>
        let network = null;
        let allNodesData = {};
        let rawLayersData = null;
        let nodesDataSet = null;
        let edgesDataSet = null;
        let originalNodeStyles = {};

        async function fetchTopology() {
            try {
                const res = await fetch('/api/topology');
                const data = await res.json();
                if (data && data.homelab_environment && data.homelab_environment.layers) {
                    rawLayersData = data.homelab_environment.layers;
                    buildGraph(rawLayersData);
                }
            } catch (err) {
                console.error("Failed to fetch topology:", err);
            }
        }

        async function fetchStats() {
            try {
                const res = await fetch('/api/stats');
                const data = await res.json();
                document.getElementById('cpu-stat').innerText = data.cpu + '%';
                document.getElementById('ram-stat').innerText = data.ram_percent + '% (' + data.ram_used_mb + 'MB)';
            } catch (e) {}
        }

        function buildGraph(layers) {
            const nodes = [];
            const edges = [];
            allNodesData = {};
            originalNodeStyles = {};

            const degreeMap = {};
            layers.forEach(layer => {
                if (layer.services) {
                    layer.services.forEach(svc => {
                        if (!degreeMap[svc.id]) degreeMap[svc.id] = 0;
                        if (svc.connects_to) {
                            svc.connects_to.forEach(target => {
                                degreeMap[svc.id] = (degreeMap[svc.id] || 0) + 1;
                                degreeMap[target] = (degreeMap[target] || 0) + 1;
                            });
                        }
                    });
                }
            });

            const layerColors = [
                { background: '#1c1917', border: '#f43f5e', text: '#fb7185' }, 
                { background: '#0f172a', border: '#0284c7', text: '#38bdf8' }, 
                { background: '#0f172a', border: '#16a34a', text: '#4ade80' }, 
                { background: '#0f172a', border: '#d97706', text: '#fbbf24' }, 
                { background: '#0f172a', border: '#7c3aed', text: '#a78bfa' }  
            ];

            const useImportance = document.getElementById('importanceToggle').checked;

            layers.forEach((layer, layerIdx) => {
                const colorTheme = layerColors[layerIdx % layerColors.length];
                if (layer.services) {
                    layer.services.forEach(svc => {
                        allNodesData[svc.id] = { ...svc, layerName: layer.name };
                        
                        let marginVal = 12;
                        let fontSize = 13;
                        if (useImportance) {
                            const deg = degreeMap[svc.id] || 1;
                            marginVal = 12 + (deg * 3);
                            fontSize = 13 + Math.min(deg * 2, 6);
                        }

                        originalNodeStyles[svc.id] = {
                            background: colorTheme.background,
                            border: colorTheme.border,
                            textColor: colorTheme.text,
                            fontSize: fontSize
                        };

                        nodes.push({
                            id: svc.id,
                            label: `  ${svc.name}  \n  [ ${svc.type} ]  `,
                            shape: 'box',
                            margin: marginVal,
                            borderRadius: 8,
                            title: `${svc.name}\nType: ${svc.type}`,
                            color: {
                                background: colorTheme.background,
                                border: colorTheme.border,
                                highlight: { background: '#1e293b', border: '#38bdf8' }
                            },
                            font: { color: colorTheme.text, size: fontSize, face: 'system-ui', multi: true, align: 'center' },
                            shadow: { enabled: true, color: 'rgba(0,0,0,0.6)', size: 8, x: 2, y: 2 }
                        });

                        if (svc.connects_to) {
                            svc.connects_to.forEach(target => {
                                edges.push({ from: svc.id, to: target, arrows: 'to', color: { color: '#475569', highlight: '#38bdf8' }, width: 2 });
                            });
                        }
                    });
                }
            });

            const container = document.getElementById('network-container');
            nodesDataSet = new vis.DataSet(nodes);
            edgesDataSet = new vis.DataSet(edges);
            const data = { nodes: nodesDataSet, edges: edgesDataSet };
            
            const physicsEnabled = document.getElementById('physicsToggle').checked;
            
            const options = {
                physics: {
                    enabled: physicsEnabled,
                    barnesHut: { 
                        gravitationalConstant: -5000, 
                        centralGravity: 0.3, 
                        springLength: 180,
                        nodeDistance: 140,
                        avoidOverlap: 1.0 
                    }
                },
                interaction: { hover: true }
            };

            network = new vis.Network(container, data, options);

            network.on("click", function (params) {
                if (params.nodes.length > 0) {
                    const nodeId = params.nodes[0];
                    showInspector(allNodesData[nodeId]);
                } else {
                    hideInspector();
                }
            });
        }

        document.getElementById('physicsToggle').addEventListener('change', function(e) {
            if (network) {
                network.setOptions({ physics: { enabled: e.target.checked } });
            }
        });

        document.getElementById('importanceToggle').addEventListener('change', function() {
            if (rawLayersData) {
                buildGraph(rawLayersData);
            }
        });

        function showInspector(svc) {
            if (!svc) return;
            document.getElementById('panelTitle').innerText = svc.name;
            document.getElementById('panelType').innerText = svc.type;
            document.getElementById('panelStatus').innerText = svc.status || 'Running';
            document.getElementById('panelUptime').innerText = svc.uptime || 'N/A';
            document.getElementById('panelTraffic').innerText = `Out: ${svc.traffic_out || '0 MB'} / In: ${svc.traffic_in || '0 MB'}`;
            document.getElementById('panelPorts').innerText = svc.ports && svc.ports.length > 0 ? svc.ports.join(', ') : 'None / Internal';
            document.getElementById('panelConfig').innerText = svc.config_path || 'N/A';
            
            const scriptList = document.getElementById('panelScripts');
            scriptList.innerHTML = '';
            if (svc.scripts_associated && svc.scripts_associated.length > 0) {
                svc.scripts_associated.forEach(script => {
                    const li = document.createElement('li');
                    li.innerText = script;
                    scriptList.appendChild(li);
                });
            } else {
                const li = document.createElement('li');
                li.innerText = 'No associated scripts';
                scriptList.appendChild(li);
            }

            document.getElementById('inspectorPanel').classList.remove('translate-x-full');
        }

        function hideInspector() {
            document.getElementById('inspectorPanel').classList.add('translate-x-full');
        }

        document.getElementById('closePanel').addEventListener('click', hideInspector);

        // Cinematic Search & Filter "Lights Out" Animation Handler
        document.getElementById('searchInput').addEventListener('input', function(e) {
            const query = e.target.value.toLowerCase().trim();
            const nodeIds = nodesDataSet.getIds();

            if (!query) {
                // Restore all node lighting/styles when query is empty
                const updates = nodeIds.map(id => {
                    const orig = originalNodeStyles[id];
                    return {
                        id: id,
                        color: { background: orig.background, border: orig.border },
                        font: { color: orig.textColor, size: orig.fontSize }
                    };
                });
                nodesDataSet.update(updates);
                return;
            }

            // Find matching nodes based on name or type
            const matchedIds = nodeIds.filter(id => {
                const svc = allNodesData[id];
                return svc.name.toLowerCase().includes(query) || svc.type.toLowerCase().includes(query);
            });

            // Lights out effect on non-matching nodes, highlight matching ones
            const updates = nodeIds.map(id => {
                const isMatch = matchedIds.includes(id);
                const orig = originalNodeStyles[id];
                if (isMatch) {
                    return {
                        id: id,
                        color: { background: '#0284c7', border: '#38bdf8' },
                        font: { color: '#ffffff', size: orig.fontSize + 2 }
                    };
                } else {
                    // Dim/fade unmatching nodes ("lights out")
                    return {
                        id: id,
                        color: { background: '#030712', border: '#1e293b' },
                        font: { color: '#334155', size: orig.fontSize }
                    };
                }
            });
            nodesDataSet.update(updates);

            // If exactly ONE match remains: spotlight it, select it, open inspector, and smoothly zoom in!
            if (matchedIds.length === 1) {
                const singleMatchId = matchedIds[0];
                network.selectNodes([singleMatchId]);
                showInspector(allNodesData[singleMatchId]);
                
                network.focus(singleMatchId, {
                    scale: 1.4,
                    animation: {
                        duration: 800,
                        easingFunction: 'easeInOutQuad'
                    }
                });
            }
        });

        fetchTopology();
        fetchStats();
        setInterval(fetchStats, 5000);
    </script>
</body>
</html>
EOF

# Create Systemd Service File for Permanent Operation
echo "[*] Configuring systemd service for Homelab Topology V1.2..."
sudo bash -c "cat << 'EOF' > $SERVICE_PATH
[Unit]
Description=Homelab Topology Visualizer & Management Console V1.2
After=network.target

[Service]
User=$CURRENT_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $PYTHON_APP_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable homelab-map.service
sudo systemctl restart homelab-map.service

echo "[+] Installation complete! Homelab Topology V1.2 running with Cinematic Search & Spotlight."
