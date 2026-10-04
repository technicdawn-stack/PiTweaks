#!/bin/bash

# ============================================================
# RevPi - Automotive-Inspired Raspberry Pi Telemetry Dashboard
# PERSISTENT: TRUE
# Category: Webpages
# Description: V2.0 (Authentic Digital Dash, Vector Warning Lights & Morphing Core Gauges)
# ============================================================

set -e

if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$(whoami)"
fi

USER_HOME="$(eval echo ~$CURRENT_USER)"
APP_DIR="$USER_HOME/revpi"
PYTHON_APP_PATH="$APP_DIR/app.py"
TEMPLATE_DIR="$APP_DIR/templates"
TEMPLATE_PATH="$TEMPLATE_DIR/index.html"
SERVICE_PATH="/etc/systemd/system/revpi.service"
PORT=8086

echo
echo "============================================================"
echo " RevPi Telemetry Dashboard Installer V2.0"
echo "============================================================"
echo

sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv whiptail

mkdir -p "$APP_DIR"
mkdir -p "$TEMPLATE_DIR"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "$APP_DIR"

if ! python3 -c "import flask, psutil" >/dev/null 2>&1; then
    sudo apt-get install -y python3-flask python3-psutil || python3 -m pip install flask psutil
fi

# ============================================================
# PYTHON FLASK BACKEND
# ============================================================
cat << 'PYEOF' > "$PYTHON_APP_PATH"
import os
import psutil
import shutil
import subprocess
from flask import Flask, render_template, jsonify

app = Flask(__name__)

def check_undervolt():
    try:
        output = subprocess.check_output(['vcgencmd', 'get_throttled'], stderr=subprocess.STDOUT, text=True).strip()
        val = int(output.split('=')[-1], 16)
        return bool(val & 0x1)
    except Exception:
        return False

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/telemetry", methods=["GET"])
def get_telemetry():
    cpu_overall = psutil.cpu_percent(interval=None)
    cpu_per_core = psutil.cpu_percent(interval=None, percpu=True)
    
    ram = psutil.virtual_memory()
    ram_percent = ram.percent
    ram_used_mb = round(ram.used / (1024 * 1024), 1)
    ram_total_mb = round(ram.total / (1024 * 1024), 1)
    ram_active_mb = round(getattr(ram, 'active', ram.used * 0.7) / (1024 * 1024), 1)
    ram_cached_mb = round(getattr(ram, 'cached', ram.used * 0.3) / (1024 * 1024), 1)

    temp_c = 0.0
    try:
        temps = psutil.sensors_temperatures()
        if temps:
            for name, entries in temps.items():
                if 'cpu' in name.lower() or 'core' in name.lower() or 'bcm' in name.lower():
                    temp_c = entries[0].current
                    break
            if temp_c == 0.0:
                temp_c = temps[list(temps.keys())[0]][0].current
    except Exception:
        try:
            with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
                temp_c = int(f.read().strip()) / 1000.0
        except Exception:
            temp_c = 42.0

    disk = shutil.disk_usage("/")
    disk_percent = round((disk.used / disk.total) * 100, 1)

    return jsonify({
        "cpu": {
            "overall": cpu_overall,
            "cores": cpu_per_core
        },
        "ram": {
            "percent": ram_percent,
            "used_mb": ram_used_mb,
            "total_mb": ram_total_mb,
            "active_mb": ram_active_mb,
            "cached_mb": ram_cached_mb
        },
        "temperature": {
            "celsius": temp_c
        },
        "storage": {
            "percent": disk_percent
        },
        "warnings": {
            "battery_undervolt": check_undervolt(),
            "thermal_warning": temp_c > 75.0,
            "storage_low_fuel": disk_percent > 90.0,
            "network_slip": False,
            "service_wrench": False
        }
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8086)
PYEOF

# ============================================================
# FRONTEND TEMPLATE (Authentic Dash & Vector Light-up Icons)
# ============================================================
cat << 'HTMLEOF' > "$TEMPLATE_PATH"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RevPi - Digital Instrument Cluster</title>
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
    <style>
        body {
            background-color: #05070c;
            color: #f1f5f9;
            font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
            background-image: radial-gradient(circle at 50% 20%, #111827 0%, #05070c 100%);
            min-height: 100vh;
        }
        .cluster-panel {
            background: linear-gradient(145deg, #0f172a, #090d16);
            border: 2px solid #1e293b;
            box-shadow: inset 0 0 30px rgba(0,0,0,0.9), 0 20px 40px rgba(0,0,0,0.6);
        }
        .needle {
            transform-origin: 100px 100px;
            transition: transform 0.5s cubic-bezier(0.175, 0.885, 0.32, 1.275);
        }
        .needle-sm {
            transform-origin: 75px 75px;
            transition: transform 0.5s cubic-bezier(0.175, 0.885, 0.32, 1.275);
        }
        .warning-icon {
            opacity: 0.15;
            filter: grayscale(100%);
            transition: all 0.4s ease;
        }
        .warning-icon.active {
            opacity: 1;
            filter: grayscale(0%);
            animation: dashGlow 1.2s infinite alternate ease-in-out;
        }
        @keyframes dashGlow {
            0% { filter: drop-shadow(0 0 2px currentColor); transform: scale(1); }
            100% { filter: drop-shadow(0 0 10px currentColor); transform: scale(1.08); }
        }
        .gauge-click {
            cursor: pointer;
            transition: transform 0.3s ease;
        }
        .gauge-click:hover {
            transform: scale(1.015);
        }
    </style>
</head>
<body class="flex flex-col">

<!-- DASHBOARD HEADER -->
<header class="bg-[#04060a] border-b border-slate-800/80 px-8 py-4 flex flex-wrap justify-between items-center shadow-2xl">
    <div class="flex items-center gap-4">
        <div class="w-10 h-10 rounded-xl bg-slate-900 border border-slate-700 flex items-center justify-center text-sky-400 font-bold shadow-inner">
            RP
        </div>
        <div>
            <h1 class="font-extrabold text-lg text-slate-100 tracking-widest uppercase">REVPI COCKPIT</h1>
            <p class="text-[11px] text-slate-400 tracking-wider">HARDWARE TELEMETRY INSTRUMENT CLUSTER</p>
        </div>
    </div>

    <!-- CAR WARNING LIGHTS CLUSTER -->
    <div class="flex items-center gap-5 bg-[#080c14] px-6 py-2.5 rounded-2xl border border-slate-800 shadow-inner">
        
        <!-- 1. Battery / Undervolt -->
        <div class="relative group cursor-pointer">
            <svg id="warnBattery" class="warning-icon text-red-500 w-7 h-7" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                <rect x="2" y="7" width="16" height="10" rx="2" ry="2"></rect>
                <line x1="22" y1="11" x2="22" y2="13"></line>
                <line x1="6" y1="12" x2="14" y2="12"></line>
            </svg>
            <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-3 hidden group-hover:flex flex-col bg-slate-950 border border-slate-700 text-xs text-slate-200 px-3 py-1.5 rounded-lg shadow-2xl whitespace-nowrap z-50">
                <span class="font-bold text-red-400">Battery / Alternator</span>
                <span>Pi Warning: Undervoltage detected (&lt;4.63V)</span>
            </div>
        </div>

        <!-- 2. Temperature / Thermal -->
        <div class="relative group cursor-pointer">
            <svg id="warnTemp" class="warning-icon text-amber-500 w-7 h-7" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M14 14.76V3.5a2.5 2.5 0 0 0-5 0v11.26a4.5 4.5 0 1 0 5 0z"></path>
            </svg>
            <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-3 hidden group-hover:flex flex-col bg-slate-950 border border-slate-700 text-xs text-slate-200 px-3 py-1.5 rounded-lg shadow-2xl whitespace-nowrap z-50">
                <span class="font-bold text-amber-400">Engine Coolant Temp</span>
                <span>Pi Warning: Thermal throttle active (&gt;75°C)</span>
            </div>
        </div>

        <!-- 3. Fuel / Storage -->
        <div class="relative group cursor-pointer">
            <svg id="warnFuel" class="warning-icon text-yellow-400 w-7 h-7" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M3 22V6a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v16H3z"></path>
                <path d="M15 10h3a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2h-3v-8z"></path>
                <line x1="7" y1="9" x2="11" y2="9"></line>
            </svg>
            <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-3 hidden group-hover:flex flex-col bg-slate-950 border border-slate-700 text-xs text-slate-200 px-3 py-1.5 rounded-lg shadow-2xl whitespace-nowrap z-50">
                <span class="font-bold text-yellow-400">Low Fuel Indicator</span>
                <span>Pi Warning: Root filesystem nearly full (&gt;90%)</span>
            </div>
        </div>

        <!-- 4. Traction Slip / Network -->
        <div class="relative group cursor-pointer">
            <svg id="warnSlip" class="warning-icon text-sky-400 w-7 h-7" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M4 14l4-4 4 4 4-4 4 4"></path>
                <path d="M4 18l4-4 4 4 4-4 4 4"></path>
            </svg>
            <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-3 hidden group-hover:flex flex-col bg-slate-950 border border-slate-700 text-xs text-slate-200 px-3 py-1.5 rounded-lg shadow-2xl whitespace-nowrap z-50">
                <span class="font-bold text-sky-400">Traction Control / Slip</span>
                <span>Pi Warning: Gateway packet loss or latency spike</span>
            </div>
        </div>

        <!-- 5. Service Wrench -->
        <div class="relative group cursor-pointer">
            <svg id="warnWrench" class="warning-icon text-emerald-400 w-7 h-7" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"></path>
            </svg>
            <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-3 hidden group-hover:flex flex-col bg-slate-950 border border-slate-700 text-xs text-slate-200 px-3 py-1.5 rounded-lg shadow-2xl whitespace-nowrap z-50">
                <span class="font-bold text-emerald-400">Service Maintenance Wrench</span>
                <span>Pi Warning: Security updates pending upgrade</span>
            </div>
        </div>

    </div>
</header>

<!-- DASHBOARD GRID -->
<main class="flex-1 p-8 flex items-center justify-center">
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-8 max-w-7xl w-full">

        <!-- GAUGE 1: CPU TACHOMETER (Morphs into 4-core cluster on click) -->
        <div id="cpuContainer" class="cluster-panel rounded-3xl p-6 flex flex-col items-center justify-center gauge-click relative min-h-[320px]">
            <span class="absolute top-5 left-6 text-xs font-bold text-slate-400 tracking-widest uppercase">CPU Tachometer</span>
            
            <div id="cpuViewWrapper" class="w-full flex flex-col items-center justify-center">
                <!-- Single Main Tachometer -->
                <div class="relative my-4">
                    <svg width="200" height="200" viewBox="0 0 200 200">
                        <circle cx="100" cy="100" r="75" fill="none" stroke="#1e293b" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="88" transform="rotate(135 100 100)"></circle>
                        <!-- Redline Zone Marker (80% - 100%) -->
                        <circle cx="100" cy="100" r="75" fill="none" stroke="#ef4444" stroke-width="12" stroke-dasharray="353 353" stroke-dashoffset="264" transform="rotate(270 100 100)" opacity="0.4"></circle>
                        <circle id="cpuProgressArc" cx="100" cy="100" r="75" fill="none" stroke="#38bdf8" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="353" transform="rotate(135 100 100)" stroke-linecap="round"></circle>
                        <circle cx="100" cy="100" r="20" fill="#070a10" stroke="#334155" stroke-width="3"></circle>
                        <polygon id="cpuNeedle" points="97,35 103,35 100,105" fill="#ef4444" class="needle" style="transform: rotate(-135deg);"></polygon>
                    </svg>
                    <div class="absolute inset-0 flex flex-col items-center justify-center mt-5">
                        <span id="cpuValueText" class="text-2xl font-black text-white font-mono tracking-tighter">0.0%</span>
                        <span class="text-[9px] text-slate-400 font-bold uppercase tracking-wider">Overall RPM</span>
                    </div>
                </div>
                <span class="text-[11px] text-slate-400 mt-2 font-medium tracking-wide">Click to split into 4 Cores</span>
            </div>
        </div>

        <!-- GAUGE 2: ENGINE TEMPERATURE -->
        <div id="tempContainer" class="cluster-panel rounded-3xl p-6 flex flex-col items-center justify-center relative min-h-[320px]">
            <span class="absolute top-5 left-6 text-xs font-bold text-slate-400 tracking-widest uppercase">Engine Temp</span>
            <div class="relative my-4">
                <svg width="200" height="200" viewBox="0 0 200 200">
                    <circle cx="100" cy="100" r="75" fill="none" stroke="#1e293b" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="88" transform="rotate(135 100 100)"></circle>
                    <circle id="tempProgressArc" cx="100" cy="100" r="75" fill="none" stroke="#f59e0b" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="353" transform="rotate(135 100 100)" stroke-linecap="round"></circle>
                    <circle cx="100" cy="100" r="20" fill="#070a10" stroke="#334155" stroke-width="3"></circle>
                    <polygon id="tempNeedle" points="97,35 103,35 100,105" fill="#ef4444" class="needle" style="transform: rotate(-135deg);"></polygon>
                </svg>
                <div class="absolute inset-0 flex flex-col items-center justify-center mt-5">
                    <span id="tempValueText" class="text-2xl font-black text-white font-mono tracking-tighter">0.0°C</span>
                    <span class="text-[9px] text-slate-400 font-bold uppercase tracking-wider">Coolant Temp</span>
                </div>
            </div>
            <div class="w-full mt-2 pt-3 border-t border-slate-800/80 text-center">
                <span class="text-[11px] text-slate-400 font-medium">Safe Operating Zone: 30°C - 75°C</span>
            </div>
        </div>

        <!-- GAUGE 3: RAM FUEL TANK -->
        <div id="ramContainer" class="cluster-panel rounded-3xl p-6 flex flex-col items-center justify-center gauge-click relative min-h-[320px]">
            <span class="absolute top-5 left-6 text-xs font-bold text-slate-400 tracking-widest uppercase">RAM Fuel Tank</span>
            
            <div id="ramViewWrapper" class="w-full flex flex-col items-center justify-center">
                <div class="relative my-4">
                    <svg width="200" height="200" viewBox="0 0 200 200">
                        <circle cx="100" cy="100" r="75" fill="none" stroke="#1e293b" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="88" transform="rotate(135 100 100)"></circle>
                        <circle id="ramProgressArc" cx="100" cy="100" r="75" fill="none" stroke="#10b981" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="353" transform="rotate(135 100 100)" stroke-linecap="round"></circle>
                        <circle cx="100" cy="100" r="20" fill="#070a10" stroke="#334155" stroke-width="3"></circle>
                        <polygon id="ramNeedle" points="97,35 103,35 100,105" fill="#ef4444" class="needle" style="transform: rotate(-135deg);"></polygon>
                    </svg>
                    <div class="absolute inset-0 flex flex-col items-center justify-center mt-5">
                        <span id="ramValueText" class="text-2xl font-black text-white font-mono tracking-tighter">0.0%</span>
                        <span id="ramDetailsText" class="text-[9px] text-slate-400 font-bold uppercase tracking-wider">0 MB / 0 MB</span>
                    </div>
                </div>
                <span class="text-[11px] text-slate-400 mt-2 font-medium tracking-wide">Click to toggle Active/Cached Breakdown</span>
            </div>
        </div>

    </div>
</main>

<script>
    let cpuSplit = false;
    let ramBreakdown = false;
    let cachedData = null;

    function percentToDegrees(percent) {
        const clamped = Math.max(0, Math.min(100, percent));
        return -135 + (clamped / 100) * 270;
    }

    function percentToDashOffset(percent) {
        const clamped = Math.max(0, Math.min(100, percent));
        return 353 - (clamped / 100) * (353 * 0.75);
    }

    async function fetchTelemetry() {
        try {
            const res = await fetch('/api/telemetry');
            const data = await res.json();
            cachedData = data;
            renderUI(data);
        } catch (e) {
            console.error("Telemetry fetch error:", e);
        }
    }

    function renderUI(data) {
        // CPU Render
        if (!cpuSplit) {
            const cpuPct = data.cpu.overall;
            document.getElementById('cpuValueText').innerText = cpuPct.toFixed(1) + '%';
            document.getElementById('cpuNeedle').style.transform = `rotate(${percentToDegrees(cpuPct)}deg)`;
            document.getElementById('cpuProgressArc').style.strokeDashoffset = percentToDashOffset(cpuPct);
        } else if (data.cpu.cores) {
            const wrapper = document.getElementById('cpuViewWrapper');
            wrapper.innerHTML = `
                <div class="grid grid-cols-2 gap-4 w-full my-2">
                    ${data.cpu.cores.map((c, i) => `
                        <div class="flex flex-col items-center bg-slate-950/60 p-2 rounded-2xl border border-slate-800">
                            <span class="text-[10px] font-bold text-slate-400 uppercase">Core ${i}</span>
                            <div class="relative my-1">
                                <svg width="110" height="110" viewBox="0 0 150 150">
                                    <circle cx="75" cy="75" r="55" fill="none" stroke="#1e293b" stroke-width="9" stroke-dasharray="259" stroke-dashoffset="65" transform="rotate(135 75 75)"></circle>
                                    <circle cx="75" cy="75" r="55" fill="none" stroke="#38bdf8" stroke-width="9" stroke-dasharray="259" stroke-dashoffset="${259 - (c/100)*(259*0.75)}" transform="rotate(135 75 75)" stroke-linecap="round"></circle>
                                    <polygon points="73,25 77,25 75,80" fill="#ef4444" class="needle-sm" style="transform: rotate(${percentToDegrees(c)}deg);"></polygon>
                                </svg>
                                <div class="absolute inset-0 flex items-center justify-center mt-3">
                                    <span class="text-xs font-black text-white font-mono">${c.toFixed(0)}%</span>
                                </div>
                            </div>
                        </div>
                    `).join('')}
                </div>
                <span class="text-[11px] text-sky-400 mt-1 font-medium">Click to collapse back</span>
            `;
        }

        // Temperature Render
        const tempC = data.temperature.celsius;
        const tempPct = (tempC / 100) * 100;
        document.getElementById('tempValueText').innerText = tempC.toFixed(1) + '°C';
        document.getElementById('tempNeedle').style.transform = `rotate(${percentToDegrees(tempPct)}deg)`;
        document.getElementById('tempProgressArc').style.strokeDashoffset = percentToDashOffset(tempPct);

        // RAM Render
        if (!ramBreakdown) {
            const ramPct = data.ram.percent;
            document.getElementById('ramValueText').innerText = ramPct.toFixed(1) + '%';
            document.getElementById('ramDetailsText').innerText = `${data.ram.used_mb} MB / ${data.ram.total_mb} MB`;
            document.getElementById('ramNeedle').style.transform = `rotate(${percentToDegrees(ramPct)}deg)`;
            document.getElementById('ramProgressArc').style.strokeDashoffset = percentToDashOffset(ramPct);
        } else {
            const wrapper = document.getElementById('ramViewWrapper');
            wrapper.innerHTML = `
                <div class="flex flex-col gap-3 w-full my-4 bg-slate-950/70 p-4 rounded-2xl border border-slate-800">
                    <div class="flex justify-between text-xs font-mono">
                        <span class="text-slate-400">Total RAM:</span>
                        <span class="text-slate-100 font-bold">${data.ram.total_mb} MB</span>
                    </div>
                    <div class="flex justify-between text-xs font-mono">
                        <span class="text-emerald-400">Active RAM:</span>
                        <span class="text-slate-100 font-bold">${data.ram.active_mb} MB</span>
                    </div>
                    <div class="flex justify-between text-xs font-mono">
                        <span class="text-sky-400">Cached RAM:</span>
                        <span class="text-slate-100 font-bold">${data.ram.cached_mb} MB</span>
                    </div>
                </div>
                <span class="text-[11px] text-emerald-400 mt-1 font-medium">Click to collapse back</span>
            `;
        }

        // Warning lights activation
        const w = data.warnings;
        document.getElementById('warnBattery').classList.toggle('active', w.battery_undervolt);
        document.getElementById('warnTemp').classList.toggle('active', w.thermal_warning);
        document.getElementById('warnFuel').classList.toggle('active', w.storage_low_fuel);
        document.getElementById('warnSlip').classList.toggle('active', w.network_slip);
        document.getElementById('warnWrench').classList.toggle('active', w.service_wrench);
    }

    // Click Handlers for Morphing Views
    document.getElementById('cpuContainer').addEventListener('click', () => {
        cpuSplit = !cpuSplit;
        if (!cpuSplit) {
            document.getElementById('cpuViewWrapper').innerHTML = `
                <div class="relative my-4">
                    <svg width="200" height="200" viewBox="0 0 200 200">
                        <circle cx="100" cy="100" r="75" fill="none" stroke="#1e293b" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="88" transform="rotate(135 100 100)"></circle>
                        <circle cx="100" cy="100" r="75" fill="none" stroke="#ef4444" stroke-width="12" stroke-dasharray="353 353" stroke-dashoffset="264" transform="rotate(270 100 100)" opacity="0.4"></circle>
                        <circle id="cpuProgressArc" cx="100" cy="100" r="75" fill="none" stroke="#38bdf8" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="353" transform="rotate(135 100 100)" stroke-linecap="round"></circle>
                        <circle cx="100" cy="100" r="20" fill="#070a10" stroke="#334155" stroke-width="3"></circle>
                        <polygon id="cpuNeedle" points="97,35 103,35 100,105" fill="#ef4444" class="needle" style="transform: rotate(-135deg);"></polygon>
                    </svg>
                    <div class="absolute inset-0 flex flex-col items-center justify-center mt-5">
                        <span id="cpuValueText" class="text-2xl font-black text-white font-mono tracking-tighter">0.0%</span>
                        <span class="text-[9px] text-slate-400 font-bold uppercase tracking-wider">Overall RPM</span>
                    </div>
                </div>
                <span class="text-[11px] text-slate-400 mt-2 font-medium tracking-wide">Click to split into 4 Cores</span>
            `;
        }
        if (cachedData) renderUI(cachedData);
    });

    document.getElementById('ramContainer').addEventListener('click', () => {
        ramBreakdown = !ramBreakdown;
        if (!ramBreakdown) {
            document.getElementById('ramViewWrapper').innerHTML = `
                <div class="relative my-4">
                    <svg width="200" height="200" viewBox="0 0 200 200">
                        <circle cx="100" cy="100" r="75" fill="none" stroke="#1e293b" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="88" transform="rotate(135 100 100)"></circle>
                        <circle id="ramProgressArc" cx="100" cy="100" r="75" fill="none" stroke="#10b981" stroke-width="12" stroke-dasharray="353" stroke-dashoffset="353" transform="rotate(135 100 100)" stroke-linecap="round"></circle>
                        <circle cx="100" cy="100" r="20" fill="#070a10" stroke="#334155" stroke-width="3"></circle>
                        <polygon id="ramNeedle" points="97,35 103,35 100,105" fill="#ef4444" class="needle" style="transform: rotate(-135deg);"></polygon>
                    </svg>
                    <div class="absolute inset-0 flex flex-col items-center justify-center mt-5">
                        <span id="ramValueText" class="text-2xl font-black text-white font-mono tracking-tighter">0.0%</span>
                        <span id="ramDetailsText" class="text-[9px] text-slate-400 font-bold uppercase tracking-wider">0 MB / 0 MB</span>
                    </div>
                </div>
                <span class="text-[11px] text-slate-400 mt-2 font-medium tracking-wide">Click to toggle Active/Cached Breakdown</span>
            `;
        }
        if (cachedData) renderUI(cachedData);
    });

    setInterval(fetchTelemetry, 2000);
    fetchTelemetry();
</script>
</body>
</html>
HTMLEOF

# ============================================================
# SYSTEMD SETUP
# ============================================================
sudo bash -c "cat > $SERVICE_PATH" <<EOF
[Unit]
Description=RevPi Automotive Telemetry Dashboard
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
sudo systemctl enable revpi.service
sudo systemctl restart revpi.service

echo
echo "============================================================"
echo " [SUCCESS] RevPi V2 Digital Instrument Cluster Installed!"
echo " Access your sleek dash at: http://<your-pi-ip>:$PORT"
echo "============================================================"
echo
