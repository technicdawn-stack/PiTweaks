#!/usr/bin/env bash
# Description: CoreTrace V1.0 All-in-One Self-Contained Deployment & Management Console
# PERSISTENT: FALSE
# Category: Webpages

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="CoreTrace"
APP_VERSION="V1.0"
SERVICE_NAME="coretrace.service"
DEFAULT_PORT="8087"
DEFAULT_INTERVAL="20"
DEFAULT_HISTORY_HOURS="72"

# Detect real user even if executed via sudo
if [ -n "${SUDO_USER:-}" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$(whoami)"
fi

USER_HOME="$(eval echo ~$CURRENT_USER)"
INSTALL_DIR="$USER_HOME/coretrace"
WEB_DIR="$INSTALL_DIR/web"
PYTHON_APP_PATH="$INSTALL_DIR/coretrace.py"
UNINSTALL_PATH="$INSTALL_DIR/uninstall.sh"
README_PATH="$INSTALL_DIR/README.md"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

PORT="$DEFAULT_PORT"
INTERVAL="$DEFAULT_INTERVAL"
HISTORY_HOURS="$DEFAULT_HISTORY_HOURS"
BIND_ADDRESS="0.0.0.0"

# ------------------------------ Preflight Checks ------------------------------
echo "[*] Checking Python3 and whiptail environment..."
if ! command -v python3 &>/dev/null; then
    echo "[!] python3 could not be found. Installing python3 and whiptail..."
    sudo apt-get update && sudo apt-get install -y python3 whiptail
elif ! command -v whiptail &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y whiptail
fi

[[ "$(uname -s)" == "Linux" ]] || { echo "[!] CoreTrace V1.0 targets Linux environments."; exit 1; }

# ------------------------------ Load Existing Config --------------------------
load_existing_settings() {
    local envfile="$INSTALL_DIR/coretrace.env"
    [[ -f "$envfile" ]] || return 0
    while IFS='=' read -r key value; do
        value="${value\%$'\r'}"
        case "$key" in
            CORETRACE_PORT) [[ "$value" =~ ^[0-9]+$ ]] && PORT="$value" ;;
            CORETRACE_INTERVAL) [[ "$value" =~ ^[0-9]+$ ]] && INTERVAL="$value" ;;
            CORETRACE_HISTORY_HOURS) [[ "$value" =~ ^[0-9]+$ ]] && HISTORY_HOURS="$value" ;;
        esac
    done < "$envfile"
}

load_existing_settings

# ------------------------------ Whiptail Menu ---------------------------------
if command -v whiptail &>/dev/null; then
    CHOICE=$(whiptail --title "CoreTrace V1.0 Management Console" --menu "Choose an option:" 15 65 4 \
        "1" "Install or Update CoreTrace" \
        "2" "Configure Settings" \
        "3" "Uninstall CoreTrace" \
        "4" "Exit" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 0
else
    CHOICE="1"
fi

case "$CHOICE" in
    3)
        echo "[*] Uninstalling CoreTrace..."
        sudo systemctl stop "$SERVICE_NAME" || true
        sudo systemctl disable "$SERVICE_NAME" || true
        sudo rm -f "$SERVICE_PATH"
        sudo systemctl daemon-reload
        rm -rf "$INSTALL_DIR"
        echo "[OK] CoreTrace uninstalled successfully."
        exit 0
        ;;
    2)
        PORT=$(whiptail --title "CoreTrace Settings" --inputbox "Enter Web Server Port (1024-65535):" 10 50 "$PORT" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && PORT="$DEFAULT_PORT"
        INTERVAL=$(whiptail --title "CoreTrace Settings" --inputbox "Enter Sampling Interval in Seconds (5-300):" 10 50 "$INTERVAL" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && INTERVAL="$DEFAULT_INTERVAL"
        HISTORY_HOURS=$(whiptail --title "CoreTrace Settings" --inputbox "Enter History Window in Hours (1-72):" 10 50 "$HISTORY_HOURS" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && HISTORY_HOURS="$DEFAULT_HISTORY_HOURS"
        ;;
    4)
        exit 0
        ;;
esac

mkdir -p "$WEB_DIR"

# ------------------------------ Python Backend (coretrace.py) -----------------
cat << 'EOF' > "$PYTHON_APP_PATH"
#!/usr/bin/env python3
from __future__ import annotations
import json
import os
import re
import signal
import threading
import time
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

APP_NAME = "CoreTrace"
APP_VERSION = "V1.0"
ROOT = Path(__file__).resolve().parent
WEB_DIR = ROOT / "web"

def env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        return max(minimum, min(maximum, int(os.environ.get(name, default))))
    except (TypeError, ValueError):
        return default

PORT = env_int("CORETRACE_PORT", 8087, 1024, 65535)
INTERVAL = env_int("CORETRACE_INTERVAL", 20, 5, 300)
HISTORY_HOURS = env_int("CORETRACE_HISTORY_HOURS", 72, 1, 72)
BIND = "0.0.0.0"

HISTORY_SECONDS = HISTORY_HOURS * 3600
MAX_SAMPLES = max(2, int(HISTORY_SECONDS / INTERVAL) + 2)
history = deque(maxlen=MAX_SAMPLES)
history_lock = threading.Lock()
stop_event = threading.Event()
started_at = time.time()
boot_time = None
prev_cpu = None
prev_cores = None
prev_proc_cpu = None
prev_proc_time = None
clk_tck = os.sysconf("SC_CLK_TCK")
page_size = os.sysconf("SC_PAGE_SIZE")

def read_cpu_counters():
    global boot_time
    try:
        with open("/proc/stat", "r", encoding="ascii") as f:
            lines = f.readlines()
        total = None
        cores = {}
        for line in lines:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "cpu":
                values = [int(x) for x in parts[1:]]
                idle = values[3] + (values[4] if len(values) > 4 else 0)
                total = (sum(values), idle)
            elif re.fullmatch(r"cpu\d+", parts[0]):
                values = [int(x) for x in parts[1:]]
                idle = values[3] + (values[4] if len(values) > 4 else 0)
                cores[parts[0]] = (sum(values), idle)
            elif parts[0] == "btime" and len(parts) > 1:
                boot_time = int(parts[1])
        return total, cores
    except (OSError, ValueError, IndexError):
        return None, {}

def cpu_percent(current, previous):
    if current is None or previous is None:
        return None
    total_delta = current[0] - previous[0]
    idle_delta = current[1] - previous[1]
    if total_delta <= 0:
        return None
    return round(max(0.0, min(100.0, 100.0 * (total_delta - idle_delta) / total_delta)), 2)

def read_memory():
    values = {}
    try:
        with open("/proc/meminfo", "r", encoding="ascii") as f:
            for line in f:
                parts = line.replace(":", "").split()
                if len(parts) >= 2:
                    try:
                        values[parts[0]] = int(parts[1]) * 1024
                    except ValueError:
                        continue
    except OSError:
        return {}
    total = values.get("MemTotal")
    available = values.get("MemAvailable", values.get("MemFree", 0))
    if not total or total <= 0:
        return {}
    used = max(0, total - available)
    return {
        "total_bytes": total,
        "used_bytes": used,
        "available_bytes": max(0, available),
        "used_percent": round(100 * used / total, 2),
    }

def read_cpu_temperature():
    candidates = []
    try:
        for item in Path("/sys/class/thermal").glob("thermal_zone*/temp"):
            candidates.append(item)
    except OSError:
        pass
    candidates.append(Path("/sys/class/hwmon/hwmon0/temp1_input"))
    for path in candidates:
        try:
            raw = path.read_text(encoding="ascii").strip()
            value = float(raw)
            if value > 200:
                value /= 1000.0
            if -20.0 <= value <= 150.0:
                return round(value, 1)
        except (OSError, ValueError):
            continue
    return None

def read_storage():
    try:
        stats = os.statvfs("/")
        total = stats.f_blocks * stats.f_frsize
        free = stats.f_bavail * stats.f_frsize
        user_free = max(0, free)
        user_used = max(0, total - user_free)
        return {
            "total_bytes": total,
            "used_bytes": user_used,
            "free_bytes": user_free,
            "used_percent": round(100 * user_used / total, 2) if total else 0,
        }
    except OSError:
        return {}

def read_process_usage():
    try:
        raw = Path("/proc/self/stat").read_text(encoding="ascii")
        tail = raw[raw.rfind(")") + 2:].split()
        cpu_ticks = int(tail[11]) + int(tail[12])
        rss_pages = max(0, int(tail[21]))
        return cpu_ticks, rss_pages * page_size
    except (OSError, ValueError, IndexError):
        return None, None

def mib(value):
    return round(value / (1024 * 1024), 2) if value is not None else None

def make_sample():
    global prev_cpu, prev_cores, prev_proc_cpu, prev_proc_time
    now = time.time()
    current_cpu, current_cores = read_cpu_counters()
    overall = cpu_percent(current_cpu, prev_cpu)
    core_values = {}
    for name in sorted(current_cores, key=lambda x: int(x[3:])):
        core_values[name] = cpu_percent(current_cores[name], (prev_cores or {}).get(name))
    prev_cpu = current_cpu
    prev_cores = current_cores

    proc_ticks, proc_rss = read_process_usage()
    proc_cpu = None
    if proc_ticks is not None and prev_proc_cpu is not None and prev_proc_time is not None:
        elapsed = max(0.001, now - prev_proc_time)
        proc_cpu = round(max(0.0, (proc_ticks - prev_proc_cpu) * 100.0 / clk_tck / elapsed), 2)
    prev_proc_cpu = proc_ticks
    prev_proc_time = now

    return {
        "timestamp": round(now, 3),
        "iso_time": datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="seconds"),
        "cpu_percent": overall,
        "cores": core_values,
        "memory": read_memory(),
        "temperature_c": read_cpu_temperature(),
        "storage": read_storage(),
        "process": {
            "cpu_percent": proc_cpu,
            "rss_bytes": proc_rss,
            "rss_mib": mib(proc_rss),
        },
    }

def sampler():
    next_tick = time.monotonic()
    while not stop_event.is_set():
        sample = make_sample()
        cutoff = time.time() - HISTORY_SECONDS
        with history_lock:
            history.append(sample)
            while history and history[0]["timestamp"] < cutoff:
                history.popleft()
        next_tick += INTERVAL
        stop_event.wait(max(0.1, next_tick - time.monotonic()))

class Handler(BaseHTTPRequestHandler):
    server_version = "CoreTrace/1.0"
    def log_message(self, fmt, *args): return

    def send_bytes(self, body: bytes, content_type: str, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, data, status=200):
        self.send_bytes(json.dumps(data, separators=(",", ":"), allow_nan=False).encode("utf-8"), "application/json; charset=utf-8", status)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/status":
            with history_lock:
                latest = history[-1] if history else None
                count = len(history)
            now = time.time()
            uptime = max(0, int(now - boot_time)) if boot_time else int(now - started_at)
            self.send_json({
                "app": APP_NAME, "version": APP_VERSION, "port": PORT,
                "interval_seconds": INTERVAL, "history_hours": HISTORY_HOURS,
                "sample_count": count, "system_uptime_seconds": uptime,
                "server_uptime_seconds": int(now - started_at), "latest": latest
            })
            return
        if path == "/api/history":
            with history_lock:
                self.send_json({"samples": list(history)})
            return

        files_map = {
            "/": ("index.html", "text/html; charset=utf-8"),
            "/index.html": ("index.html", "text/html; charset=utf-8"),
            "/style.css": ("style.css", "text/css; charset=utf-8"),
            "/app.js": ("app.js", "text/javascript; charset=utf-8"),
        }
        if path not in files_map:
            self.send_bytes(b"Not found\n", "text/plain; charset=utf-8", 404)
            return
        filename, ctype = files_map[path]
        try:
            self.send_bytes((WEB_DIR / filename).read_bytes(), ctype)
        except OSError:
            self.send_bytes(b"Asset missing\n", "text/plain; charset=utf-8", 500)

def main():
    signal.signal(signal.SIGTERM, lambda *_: stop_event.set())
    signal.signal(signal.SIGINT, lambda *_: stop_event.set())
    threading.Thread(target=sampler, daemon=True).start()
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        stop_event.set()
        server.server_close()

if __name__ == "__main__":
    main()
EOF

# ------------------------------ Frontend HTML (web/index.html) ----------------
cat << 'EOF' > "$WEB_DIR/index.html"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>CoreTrace V1.0</title>
  <link rel="stylesheet" href="/style.css">
  <script src="/app.js" defer></script>
</head>
<body>
  <div class="shell">
    <header class="topbar">
      <div class="brand">
        <div class="brand-mark"><span></span><span></span><span></span></div>
        <div><div class="brand-name">CoreTrace</div><div class="brand-sub">TELEMETRY <span>V1.0</span></div></div>
      </div>
      <div class="top-actions">
        <div class="search-wrap">
          <input id="search" type="search" placeholder="Search metrics..." autocomplete="off">
        </div>
        <div class="live-pill"><span class="live-dot"></span><span id="connectionText">CONNECTING</span></div>
      </div>
    </header>
    <div class="layout">
      <aside class="sidebar" id="sidebar">
        <div class="side-heading">NAVIGATION</div>
        <button class="nav-item active" data-target="overview">Overview</button>
        <button class="nav-item" data-target="cpu-card">Processor</button>
        <button class="nav-item" data-target="memory-card">Memory</button>
        <button class="nav-item" data-target="storage-card">Storage</button>
        <button class="nav-item" data-target="temperature-card">Thermals</button>
        <div class="side-divider"></div>
        <div class="side-heading">HISTORY WINDOW</div>
        <div class="range-buttons">
          <button data-range="1">1H</button><button data-range="6">6H</button>
          <button data-range="24">24H</button><button class="selected" data-range="72">3D</button>
        </div>
        <div class="side-foot">
          <div class="tiny-label">COLLECTOR STATUS</div>
          <div class="collector-line"><span class="status-dot"></span><span id="collectorStatus">Starting…</span></div>
          <div class="tiny-label spaced">SAMPLE INTERVAL</div>
          <div class="side-value" id="sampleInterval">—</div>
          <div class="tiny-label spaced">SAMPLES IN RAM</div>
          <div class="side-value" id="sampleCount">—</div>
          <button id="sidebarToggle" class="collapse-button">‹</button>
        </div>
      </aside>
      <main class="main" id="overview">
        <section class="page-heading">
          <div><h1>System Overview</h1><p class="muted">Live health and temporary RAM history.</p></div>
          <div class="updated">LAST SAMPLE <strong id="lastSample">—</strong></div>
        </section>
        <section class="metric-grid">
          <article class="metric-card" id="cpu-card" data-search="cpu processor usage">
            <div class="card-top"><span class="card-label">CPU USAGE</span></div>
            <div class="metric-value"><span id="cpuValue">—</span><small>%</small></div>
            <div class="metric-foot"><span id="cpuMeta">Processor utilisation</span></div>
          </article>
          <article class="metric-card" id="memory-card" data-search="ram memory">
            <div class="card-top"><span class="card-label">MEMORY USAGE</span>
              <div class="inline-toggle"><button class="selected" data-memory-mode="percent">%</button><button data-memory-mode="mib">MiB</button></div>
            </div>
            <div class="metric-value"><span id="memoryValue">—</span><small id="memoryUnit">%</small></div>
            <div class="metric-foot"><span id="memoryMeta">Available-based estimate</span></div>
          </article>
          <article class="metric-card" id="temperature-card" data-search="temp temperature thermal">
            <div class="card-top"><span class="card-label">CPU TEMP</span></div>
            <div class="metric-value"><span id="tempValue">—</span><small>°C</small></div>
            <div class="metric-foot"><span id="tempMeta">Thermal sensor</span></div>
          </article>
          <article class="metric-card" id="storage-card" data-search="storage disk">
            <div class="card-top"><span class="card-label">ROOT STORAGE</span></div>
            <div class="metric-value"><span id="storageValue">—</span><small>%</small></div>
            <div class="metric-foot"><span id="storageMeta">Filesystem usage</span></div>
          </article>
        </section>
        <section class="panel chart-panel">
          <div class="panel-head">
            <div class="panel-title">Processor History</div>
            <div class="segmented"><button class="selected" data-cpu-mode="overall">Overall</button><button data-cpu-mode="cores">Per Core</button></div>
          </div>
          <div class="chart-box"><canvas id="cpuCanvas"></canvas></div>
        </section>
        <section class="panel chart-panel">
          <div class="panel-head"><div class="panel-title">Memory History</div></div>
          <div class="chart-box"><canvas id="memoryCanvas"></canvas></div>
        </section>
        <section class="panel chart-panel">
          <div class="panel-head"><div class="panel-title">Thermal History</div></div>
          <div class="chart-box"><canvas id="tempCanvas"></canvas></div>
        </section>
      </main>
    </div>
  </div>
</body>
</html>
EOF

# ------------------------------ Frontend CSS (web/style.css) ------------------
cat << 'EOF' > "$WEB_DIR/style.css"
:root {
  --bg: #030712; --surface: #0f172a; --border: #1e293b;
  --accent: #38bdf8; --text: #f8fafc; --muted: #94a3b8;
  --success: #22c55e; --warning: #eab308; --danger: #f43f5e;
}
* { box-sizing: border-box; }
body { font-family: system-ui, -apple-system, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 0; }
.shell { display: flex; flex-direction: column; min-height: 100vh; }
.topbar { display: flex; justify-content: space-between; align-items: center; padding: 16px 24px; background: var(--surface); border-bottom: 1px solid var(--border); }
.brand { display: flex; align-items: center; gap: 12px; }
.brand-mark { display: flex; gap: 3px; }
.brand-mark span { width: 4px; height: 16px; background: var(--accent); border-radius: 2px; }
.brand-name { font-weight: 800; font-size: 1.25rem; letter-spacing: -0.025em; }
.brand-sub { font-size: 0.75rem; color: var(--muted); }
.top-actions { display: flex; align-items: center; gap: 16px; }
.search-wrap input { background: var(--bg); border: 1px solid var(--border); color: var(--text); padding: 8px 12px; border-radius: 8px; outline: none; font-size: 0.9rem; width: 200px; }
.live-pill { display: flex; align-items: center; gap: 8px; background: var(--border); padding: 6px 12px; border-radius: 20px; font-size: 0.75rem; font-weight: 600; }
.live-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--success); }
.layout { display: flex; flex: 1; }
.sidebar { width: 260px; background: var(--surface); border-right: 1px solid var(--border); padding: 20px; display: flex; flex-direction: column; gap: 8px; transition: width 0.2s; }
.side-heading { font-size: 0.7rem; color: var(--muted); font-weight: 700; margin-top: 12px; letter-spacing: 0.05em; }
.nav-item { background: transparent; border: none; color: var(--text); padding: 10px 14px; border-radius: 8px; text-align: left; cursor: pointer; font-size: 0.9rem; font-weight: 500; width: 100%; }
.nav-item:hover, .nav-item.active { background: var(--border); color: var(--accent); }
.side-divider { height: 1px; background: var(--border); margin: 12px 0; }
.range-buttons { display: grid; grid-template-columns: repeat(4, 1fr); gap: 4px; }
.range-buttons button { background: var(--bg); border: 1px solid var(--border); color: var(--text); padding: 6px; border-radius: 6px; cursor: pointer; font-size: 0.75rem; }
.range-buttons button.selected { background: var(--accent); color: var(--bg); font-weight: 700; }
.side-foot { margin-top: auto; padding-top: 16px; border-top: 1px solid var(--border); font-size: 0.8rem; }
.tiny-label { font-size: 0.7rem; color: var(--muted); }
.side-value { font-weight: 600; margin-bottom: 8px; }
.collapse-button { background: var(--bg); border: 1px solid var(--border); color: var(--text); padding: 4px 10px; border-radius: 6px; cursor: pointer; width: 100%; margin-top: 8px; }
.main { flex: 1; padding: 30px; overflow-y: auto; display: flex; flex-direction: column; gap: 24px; max-width: 1200px; }
.page-heading { display: flex; justify-content: space-between; align-items: flex-end; }
.page-heading h1 { margin: 0 0 4px 0; font-size: 1.75rem; }
.muted { color: var(--muted); font-size: 0.9rem; margin: 0; }
.updated { font-size: 0.8rem; color: var(--muted); }
.metric-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; }
.metric-card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 20px; }
.card-label { font-size: 0.75rem; color: var(--muted); font-weight: 700; letter-spacing: 0.05em; }
.metric-value { font-size: 2rem; font-weight: 800; margin: 12px 0 8px 0; }
.metric-value small { font-size: 1rem; font-weight: 500; color: var(--muted); margin-left: 4px; }
.metric-foot { font-size: 0.8rem; color: var(--muted); }
.panel { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 24px; }
.panel-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
.panel-title { font-weight: 700; font-size: 1.1rem; }
.chart-box { width: 100%; height: 220px; position: relative; }
canvas { width: 100% !important; height: 100% !important; background: var(--bg); border-radius: 8px; border: 1px solid var(--border); }
.segmented { display: flex; gap: 4px; background: var(--bg); padding: 4px; border-radius: 8px; border: 1px solid var(--border); }
.segmented button { background: transparent; border: none; color: var(--muted); padding: 4px 10px; border-radius: 6px; cursor: pointer; font-size: 0.8rem; font-weight: 600; }
.segmented button.selected { background: var(--surface); color: var(--text); }
.inline-toggle { display: flex; gap: 2px; background: var(--bg); padding: 2px; border-radius: 6px; border: 1px solid var(--border); float: right; }
.inline-toggle button { background: transparent; border: none; color: var(--muted); padding: 2px 6px; border-radius: 4px; cursor: pointer; font-size: 0.7rem; }
.inline-toggle button.selected { background: var(--surface); color: var(--text); font-weight: 700; }
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--success); display: inline-block; margin-right: 6px; }
.collector-line { display: flex; align-items: center; margin-bottom: 8px; font-weight: 650; }
EOF

# ------------------------------ Frontend JS (web/app.js) ----------------------
cat << 'EOF' > "$WEB_DIR/app.js"
document.addEventListener('DOMContentLoaded', () => {
    let memoryMode = 'percent';

    async function fetchStatus() {
        try {
            let res = await fetch('/api/status');
            let data = await res.json();
            document.getElementById('connectionText').innerText = 'CONNECTED';
            document.getElementById('collectorStatus').innerText = 'Running';
            document.getElementById('sampleInterval').innerText = data.interval_seconds + 's';
            document.getElementById('sampleCount').innerText = data.sample_count;
            
            if (data.latest) {
                let l = data.latest;
                document.getElementById('cpuValue').innerText = l.cpu_percent !== null ? l.cpu_percent : '—';
                if (l.memory) {
                    let memVal = memoryMode === 'percent' ? l.memory.used_percent : Math.round(l.memory.used_bytes / (1024*1024));
                    document.getElementById('memoryValue').innerText = memVal;
                    document.getElementById('memoryUnit').innerText = memoryMode === 'percent' ? '%' : 'MiB';
                }
                document.getElementById('tempValue').innerText = l.temperature_c !== null ? l.temperature_c : 'N/A';
                if (l.storage) {
                    document.getElementById('storageValue').innerText = l.storage.used_percent;
                }
                document.getElementById('lastSample').innerText = l.iso_time;
            }
        } catch (e) {
            document.getElementById('connectionText').innerText = 'DISCONNECTED';
            document.getElementById('collectorStatus').innerText = 'Offline';
        }
    }

    // Global Search Filter
    const searchInput = document.getElementById('search');
    if (searchInput) {
        searchInput.addEventListener('input', (e) => {
            const query = e.target.value.toLowerCase();
            document.querySelectorAll('[data-search]').forEach(el => {
                const terms = el.getAttribute('data-search').toLowerCase();
                if (terms.includes(query) || query === '') {
                    el.style.display = '';
                } else {
                    el.style.display = 'none';
                }
            });
        });
    }

    document.querySelectorAll('.inline-toggle button').forEach(btn => {
        btn.addEventListener('click', (e) => {
            document.querySelectorAll('.inline-toggle button').forEach(b => b.classList.remove('selected'));
            e.target.classList.add('selected');
            memoryMode = e.target.getAttribute('data-memory-mode');
            fetchStatus();
        });
    });

    fetchStatus();
    setInterval(fetchStatus, 5000);
});
EOF

# ------------------------------ Uninstaller (uninstall.sh) --------------------
cat << 'EOF' > "$UNINSTALL_PATH"
#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE_NAME="coretrace.service"
if [ -n "${SUDO_USER:-}" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$(whoami)"
fi
USER_HOME="$(eval echo ~$CURRENT_USER)"
INSTALL_DIR="$USER_HOME/coretrace"

echo "[*] Stopping and disabling CoreTrace service..."
sudo systemctl stop "$SERVICE_NAME" || true
sudo systemctl disable "$SERVICE_NAME" || true
sudo rm -f "/etc/systemd/system/$SERVICE_NAME"
sudo systemctl daemon-reload

echo "[*] Removing installation directory at $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
echo "[OK] CoreTrace uninstalled successfully."
EOF
chmod +x "$UNINSTALL_PATH"

# ------------------------------ Documentation (README.md) ---------------------
cat << 'EOF' > "$README_PATH"
# CoreTrace V1.0

Lightweight, professional RAM-only system monitoring dashboard built for Raspberry Pi 3B and Linux environments.

## Quick Start
```bash
bash install.sh
