#!/usr/bin/env bash
# Description: CoreTrace V1.5 Self-Contained Deployment & Management Console
# PERSISTENT: FALSE
# Category: Webpages

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="CoreTrace"
APP_VERSION="V1.4"
SERVICE_NAME="coretrace.service"
DEFAULT_PORT="8087"
DEFAULT_INTERVAL="20"
DEFAULT_HISTORY_HOURS="72"

if [[ -n "${SUDO_USER:-}" ]]; then
CURRENT_USER="$SUDO_USER"
else
CURRENT_USER="$(id -un)"
fi

if [[ "$CURRENT_USER" == "root" ]]; then
echo "[ERROR] Run this installer as your normal user, not with sudo."
echo "Example: bash install.sh"
exit 1
fi

USER_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" && "$USER_HOME" != "/" && -d "$USER_HOME" ]] || {
echo "[ERROR] Could not determine a safe home directory for $CURRENT_USER."
exit 1
}

INSTALL_DIR="$USER_HOME/coretrace"
WEB_DIR="$INSTALL_DIR/web"
PYTHON_APP_PATH="$INSTALL_DIR/coretrace.py"
UNINSTALL_PATH="$INSTALL_DIR/uninstall.sh"
README_PATH="$INSTALL_DIR/README.md"
ENV_PATH="$INSTALL_DIR/coretrace.env"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

PORT="$DEFAULT_PORT"
INTERVAL="$DEFAULT_INTERVAL"
HISTORY_HOURS="$DEFAULT_HISTORY_HOURS"
BIND_ADDRESS="0.0.0.0"

# ------------------------------ Preflight --------------------------------------
[[ "$(uname -s)" == "Linux" ]] || {
echo "[ERROR] CoreTrace targets Linux."
exit 1
}

if ! command -v python3 >/dev/null 2>&1 || ! command -v whiptail >/dev/null 2>&1; then
echo "[*] Installing required packages (python3 and whiptail)..."
sudo apt-get update
sudo apt-get install -y python3 whiptail
fi

# ------------------------------ Settings ---------------------------------------
load_existing_settings() {
[[ -f "$ENV_PATH" ]] || return 0
local key value
while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
value="${value%$'\r'}"
case "$key" in
CORETRACE_PORT)
[[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1024 && value <= 65535 )) && PORT="$value"
;;
CORETRACE_INTERVAL)
[[ "$value" =~ ^[0-9]+$ ]] && (( value >= 5 && value <= 300 )) && INTERVAL="$value"
;;
CORETRACE_HISTORY_HOURS)
[[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 72 )) && HISTORY_HOURS="$value"
;;
esac
done < "$ENV_PATH"
}

validate_settings() {
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 65535 )) || {
echo "[ERROR] Port must be an integer from 1024 to 65535."; return 1;
}
[[ "$INTERVAL" =~ ^[0-9]+$ ]] && (( INTERVAL >= 5 && INTERVAL <= 300 )) || {
echo "[ERROR] Sampling interval must be an integer from 5 to 300 seconds."; return 1;
}
[[ "$HISTORY_HOURS" =~ ^[0-9]+$ ]] && (( HISTORY_HOURS >= 1 && HISTORY_HOURS <= 72 )) || {
echo "[ERROR] History must be an integer from 1 to 72 hours."; return 1;
}
}

save_settings() {
umask 077
cat > "$ENV_PATH" <<ENV_EOF
CORETRACE_PORT=$PORT
CORETRACE_INTERVAL=$INTERVAL
CORETRACE_HISTORY_HOURS=$HISTORY_HOURS
ENV_EOF
chmod 600 "$ENV_PATH"
}

load_existing_settings

if command -v whiptail >/dev/null 2>&1; then
set +e
CHOICE=$(whiptail --title "CoreTrace $APP_VERSION Management Console" \
--menu "Choose an option:" 16 68 4 \
"1" "Install or update CoreTrace" \
"2" "Configure settings" \
"3" "Uninstall CoreTrace" \
"4" "Exit" 3>&1 1>&2 2>&3)
MENU_STATUS=$?
set -e
(( MENU_STATUS == 0 )) || exit 0
else
CHOICE="1"
fi

case "$CHOICE" in
3)
echo "[*] Uninstalling CoreTrace..."
sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
sudo rm -f "$SERVICE_PATH"
sudo systemctl daemon-reload
if [[ "$INSTALL_DIR" == "$USER_HOME/coretrace" && -d "$INSTALL_DIR" ]]; then
rm -rf -- "$INSTALL_DIR"
fi
echo "[OK] CoreTrace uninstalled."
exit 0
;;
2)
command -v whiptail >/dev/null 2>&1 || {
echo "[ERROR] whiptail is required for the settings menu."; exit 1;
}
while true; do
set +e
PORT_INPUT=$(whiptail --title "CoreTrace $APP_VERSION Settings" \
--inputbox "Web server port (1024-65535):" 10 58 "$PORT" 3>&1 1>&2 2>&3)
rc=$?
set -e
(( rc == 0 )) || { echo "[INFO] Settings cancelled; existing values unchanged."; exit 0; }
set +e
INTERVAL_INPUT=$(whiptail --title "CoreTrace $APP_VERSION Settings" \
--inputbox "Sampling interval in seconds (5-300):" 10 58 "$INTERVAL_INPUT" 3>&1 1>&2 2>&3)
rc=$?
set -e
(( rc == 0 )) || { echo "[INFO] Settings cancelled; existing values unchanged."; exit 0; }
set +e
HISTORY_INPUT=$(whiptail --title "CoreTrace $APP_VERSION Settings" \
--inputbox "History window in hours (1-72):" 10 58 "$HISTORY_HOURS" 3>&1 1>&2 2>&3)
rc=$?
set -e
(( rc == 0 )) || { echo "[INFO] Settings cancelled; existing values unchanged."; exit 0; }

PORT="$PORT_INPUT"
INTERVAL="$INTERVAL_INPUT"
HISTORY_HOURS="$HISTORY_INPUT"
if validate_settings; then
break
fi
if ! whiptail --title "Invalid settings" --yesno "One or more values are invalid. Try again?" 9 58; then
exit 1
fi
load_existing_settings
done
;;
1)
;;
4)
exit 0
;;
*)
echo "[ERROR] Unknown menu option."
exit 1
;;
esac

validate_settings
mkdir -p "$WEB_DIR"
save_settings

# ------------------------------ Python backend ---------------------------------
cat > "$PYTHON_APP_PATH" <<'PYTHON_EOF'
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
APP_VERSION = "V1.4"
ROOT = Path(__file__).resolve().parent
WEB_DIR = ROOT / "web"

def env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
        return max(minimum, min(maximum, value))
    except (TypeError, ValueError):
        return default

PORT = env_int("CORETRACE_PORT", 8087, 1024, 65535)
INTERVAL = env_int("CORETRACE_INTERVAL", 20, 5, 300)
HISTORY_HOURS = env_int("CORETRACE_HISTORY_HOURS", 72, 1, 72)
BIND = "0.0.0.0"
HISTORY_SECONDS = HISTORY_HOURS * 3600
MAX_SAMPLES = max(2, int(HISTORY_SECONDS / INTERVAL) + 3)

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
        total = None
        cores = {}
        with open("/proc/stat", "r", encoding="ascii") as stream:
            for line in stream:
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
        with open("/proc/meminfo", "r", encoding="ascii") as stream:
            for line in stream:
                parts = line.replace(":", "").split()
                if len(parts) >= 2:
                    try:
                        values[parts[0]] = int(parts[1]) * 1024
                    except ValueError:
                        pass
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
    candidates = list(Path("/sys/class/thermal").glob("thermal_zone*/temp"))
    candidates.extend(Path("/sys/class/hwmon").glob("hwmon*/temp*_input"))
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
        free = max(0, stats.f_bavail * stats.f_frsize)
        used = max(0, total - free)
        return {
            "total_bytes": total,
            "used_bytes": used,
            "free_bytes": free,
            "used_percent": round(100 * used / total, 2) if total else 0,
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
    for name in sorted(current_cores, key=lambda item: int(item[3:])):
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
    server_version = "CoreTrace/1.4"

    def log_message(self, fmt, *args):
        return

    def send_bytes(self, body: bytes, content_type: str, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_json(self, data, status=200):
        body = json.dumps(data, separators=(",", ":"), allow_nan=False).encode("utf-8")
        self.send_bytes(body, "application/json; charset=utf-8", status)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/status":
            with history_lock:
                latest = history[-1] if history else None
                count = len(history)
                now = time.time()
                uptime = max(0, int(now - boot_time)) if boot_time else int(now - started_at)
                self.send_json({
                    "app": APP_NAME,
                    "version": APP_VERSION,
                    "port": PORT,
                    "interval_seconds": INTERVAL,
                    "history_hours": HISTORY_HOURS,
                    "sample_count": count,
                    "system_uptime_seconds": uptime,
                    "server_uptime_seconds": int(now - started_at),
                    "latest": latest,
                })
            return
        if path == "/api/history":
            with history_lock:
                samples = list(history)
                self.send_json({"samples": samples})
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
        filename, content_type = files_map[path]
        try:
            self.send_bytes((WEB_DIR / filename).read_bytes(), content_type)
        except OSError:
            self.send_bytes(b"Asset missing\n", "text/plain; charset=utf-8", 500)

def main():
    signal.signal(signal.SIGTERM, lambda *_: stop_event.set())
    signal.signal(signal.SIGINT, lambda *_: stop_event.set())
    threading.Thread(target=sampler, daemon=True, name="coretrace-sampler").start()
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        stop_event.set()
        server.server_close()

if __name__ == "__main__":
    main()
PYTHON_EOF
chmod 755 "$PYTHON_APP_PATH"

# ------------------------------ Frontend HTML ----------------------------------
cat > "$WEB_DIR/index.html" <<'HTML_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<title>CoreTrace V1.4</title>
<link rel="stylesheet" href="/style.css?v=1.4">
<script src="/app.js?v=1.4" defer></script>
</head>
<body>
<div class="shell">
<header class="topbar">
<div class="brand">
<div class="brand-mark" aria-hidden="true"><span></span><span></span><span></span></div>
<div><div class="brand-name">CoreTrace</div><div class="brand-sub">TELEMETRY <span>V1.4</span></div></div>
</div>
<div class="top-actions">
<label class="search-wrap"><span class="sr-only">Search metrics</span><input id="search" type="search" placeholder="Search metrics..." autocomplete="off"></label>
<div class="live-pill"><span class="live-dot" id="connectionDot"></span><span id="connectionText">CONNECTING</span></div>
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
<div class="range-buttons" role="group" aria-label="History range">
<button data-range="1">1H</button><button data-range="6">6H</button>
<button data-range="24">24H</button><button class="selected" data-range="72">3D</button>
</div>
<div class="side-foot">
<div class="tiny-label">COLLECTOR STATUS</div>
<div class="collector-line"><span class="status-dot" id="collectorDot"></span><span id="collectorStatus">Starting…</span></div>
<div class="tiny-label spaced">SAMPLE INTERVAL</div><div class="side-value" id="sampleInterval">—</div>
<div class="tiny-label spaced">SAMPLES IN RAM</div><div class="side-value" id="sampleCount">—</div>
<button id="sidebarToggle" class="collapse-button" aria-label="Collapse sidebar" title="Collapse sidebar">‹ Collapse</button>
</div>
</aside>
<main class="main" id="mainContent">
<section class="page-heading" id="overview">
<div><h1>System Overview</h1><p class="muted">Live health and temporary RAM history.</p></div>
<div class="updated">LAST SAMPLE <strong id="lastSample">—</strong></div>
</section>
<section class="metric-grid" aria-label="Current metrics">
<article class="metric-card" id="cpu-card" data-search="cpu processor usage">
<div class="card-top"><span class="card-label">CPU USAGE</span></div>
<div class="metric-value"><span id="cpuValue">—</span><small>%</small></div>
<div class="metric-foot" id="cpuMeta">Processor utilisation</div>
</article>
<article class="metric-card" id="memory-card" data-search="ram memory">
<div class="card-top"><span class="card-label">MEMORY USAGE</span>
<div class="inline-toggle"><button class="selected" data-memory-mode="percent">%</button><button data-memory-mode="mib">MiB</button></div>
</div>
<div class="metric-value"><span id="memoryValue">—</span><small id="memoryUnit">%</small></div>
<div class="metric-foot" id="memoryMeta">Used / total memory</div>
</article>
<article class="metric-card" id="temperature-card" data-search="temp temperature thermal">
<div class="card-top"><span class="card-label">CPU TEMP</span></div>
<div class="metric-value"><span id="tempValue">—</span><small>°C</small></div>
<div class="metric-foot" id="tempMeta">Thermal sensor</div>
</article>
<article class="metric-card" id="storage-card" data-search="storage disk filesystem">
<div class="card-top"><span class="card-label">ROOT STORAGE</span></div>
<div class="metric-value"><span id="storageValue">—</span><small>%</small></div>
<div class="metric-foot" id="storageMeta">Filesystem usage</div>
</article>
</section>
<section class="panel chart-panel" id="cpu-chart-panel">
<div class="panel-head"><div><div class="panel-title">Processor History</div><div class="panel-subtitle">Hover for values · wheel to zoom · drag to pan</div></div>
<div class="segmented"><button class="selected" data-cpu-mode="overall">Overall</button><button data-cpu-mode="cores">Per Core</button></div>
</div>
<div class="chart-box"><canvas id="cpuCanvas" aria-label="CPU history chart"></canvas><div class="chart-tooltip" id="cpuTooltip" hidden></div></div>
<div class="chart-footer"><span id="cpuChartSummary">Waiting for samples…</span><button class="reset-zoom" data-reset-chart="cpuCanvas">Reset zoom</button></div>
</section>
<section class="panel chart-panel" id="memory-chart-panel">
<div class="panel-head"><div><div class="panel-title">Memory History</div><div class="panel-subtitle">Used memory percentage</div></div></div>
<div class="chart-box"><canvas id="memoryCanvas" aria-label="Memory history chart"></canvas><div class="chart-tooltip" id="memoryTooltip" hidden></div></div>
<div class="chart-footer"><span id="memoryChartSummary">Waiting for samples…</span><button class="reset-zoom" data-reset-chart="memoryCanvas">Reset zoom</button></div>
</section>
<section class="panel chart-panel" id="temp-chart-panel">
<div class="panel-head"><div><div class="panel-title">Thermal History</div><div class="panel-subtitle">CPU temperature in °C</div></div></div>
<div class="chart-box"><canvas id="tempCanvas" aria-label="Temperature history chart"></canvas><div class="chart-tooltip" id="tempTooltip" hidden></div></div>
<div class="chart-footer"><span id="tempChartSummary">Waiting for samples…</span><button class="reset-zoom" data-reset-chart="tempCanvas">Reset zoom</button></div>
</section>
<footer class="app-footer"><span>CoreTrace V1.4</span><span>History is held in RAM and resets when the service restarts.</span></footer>
</main>
</div>
</div>
</body>
</html>
HTML_EOF

# ------------------------------ Frontend CSS -----------------------------------
cat > "$WEB_DIR/style.css" <<'CSS_EOF'
:root{--bg:#030712;--surface:#0f172a;--surface2:#111c31;--border:#1e293b;--accent:#38bdf8;--text:#f8fafc;--muted:#94a3b8;--success:#22c55e;--warning:#eab308;--danger:#f43f5e}
*{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:20px}
body{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:var(--bg);color:var(--text);margin:0}
button,input{font:inherit}
button{touch-action:manipulation}
button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.shell{display:flex;flex-direction:column;min-height:100vh}
.topbar{display:flex;justify-content:space-between;align-items:center;gap:20px;padding:16px 24px;background:var(--surface);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:20}
.brand{display:flex;align-items:center;gap:12px;min-width:160px}
.brand-mark{display:flex;gap:3px}.brand-mark span{width:4px;height:16px;background:var(--accent);border-radius:2px}
.brand-name{font-weight:800;font-size:1.25rem;letter-spacing:-.025em}.brand-sub{font-size:.75rem;color:var(--muted)}.brand-sub span{color:var(--accent)}
.top-actions{display:flex;align-items:center;gap:16px}.search-wrap input{background:var(--bg);border:1px solid var(--border);color:var(--text);padding:9px 12px;border-radius:8px;width:min(30vw,260px);min-width:150px}
.live-pill{display:flex;align-items:center;gap:8px;background:var(--border);padding:7px 12px;border-radius:20px;font-size:.75rem;font-weight:700;white-space:nowrap}
.live-dot,.status-dot{width:8px;height:8px;border-radius:50%;background:var(--warning);display:inline-block;flex:none}.live-dot.online,.status-dot.online{background:var(--success)}.live-dot.offline,.status-dot.offline{background:var(--danger)}
.layout{display:flex;flex:1;min-width:0}
.sidebar{width:260px;flex:0 0 260px;background:var(--surface);border-right:1px solid var(--border);padding:20px;display:flex;flex-direction:column;gap:8px;transition:width .2s,flex-basis .2s,padding .2s;position:sticky;top:73px;height:calc(100vh - 73px);overflow-y:auto}
.sidebar.collapsed{width:72px;flex-basis:72px;padding:20px 10px}.sidebar.collapsed .side-heading,.sidebar.collapsed .side-divider,.sidebar.collapsed .side-foot,.sidebar.collapsed .nav-item{font-size:0}.sidebar.collapsed .nav-item{height:42px;padding:8px}.sidebar.collapsed .nav-item::first-letter{font-size:0}.sidebar.collapsed .nav-item{overflow:hidden}.sidebar.collapsed .nav-item:before{font-size:0}.sidebar.collapsed .range-buttons{grid-template-columns:1fr}.sidebar.collapsed .range-buttons button:not(.selected){display:none}.sidebar.collapsed .range-buttons button{font-size:.65rem;padding:5px 0}.sidebar.collapsed .collapse-button{font-size:0}.sidebar.collapsed .collapse-button:after{content:"›";font-size:1rem}
.side-heading{font-size:.7rem;color:var(--muted);font-weight:700;margin-top:12px;letter-spacing:.05em}
.nav-item{background:transparent;border:0;color:var(--text);padding:10px 14px;border-radius:8px;text-align:left;cursor:pointer;font-size:.9rem;font-weight:500;width:100%;white-space:nowrap}
.nav-item:hover,.nav-item.active{background:var(--border);color:var(--accent)}
.side-divider{height:1px;background:var(--border);margin:12px 0}
.range-buttons{display:grid;grid-template-columns:repeat(4,1fr);gap:4px}.range-buttons button{background:var(--bg);border:1px solid var(--border);color:var(--text);padding:7px 3px;border-radius:6px;cursor:pointer;font-size:.75rem}
.range-buttons button.selected{background:var(--accent);color:var(--bg);font-weight:800}
.side-foot{margin-top:auto;padding-top:16px;border-top:1px solid var(--border);font-size:.8rem}.tiny-label{font-size:.7rem;color:var(--muted)}.spaced{margin-top:14px}.side-value{font-weight:650;margin:3px 0 8px}.collector-line{display:flex;align-items:center;gap:7px;margin:6px 0 8px;font-weight:650}
.collapse-button{background:var(--bg);border:1px solid var(--border);color:var(--text);padding:7px 10px;border-radius:6px;cursor:pointer;width:100%;margin-top:8px}
.main{flex:1;min-width:0;padding:30px;overflow:hidden;display:flex;flex-direction:column;gap:24px;max-width:1500px;width:100%;margin:0 auto}
.page-heading{display:flex;justify-content:space-between;align-items:flex-end;gap:18px}.page-heading h1{margin:0 0 4px;font-size:1.75rem}.muted{color:var(--muted);font-size:.9rem;margin:0}.updated{font-size:.75rem;color:var(--muted);text-align:right;white-space:nowrap}.updated strong{display:block;color:var(--text);font-size:.85rem;margin-top:4px}
.metric-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px}.metric-card{min-width:0;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:20px;scroll-margin-top:95px}
.card-top{display:flex;justify-content:space-between;align-items:center;gap:8px}.card-label{font-size:.75rem;color:var(--muted);font-weight:750;letter-spacing:.05em}.metric-value{font-size:clamp(1.6rem,2.4vw,2.2rem);font-weight:800;margin:12px 0 8px;overflow-wrap:anywhere}.metric-value small{font-size:1rem;font-weight:500;color:var(--muted);margin-left:4px}.metric-foot{font-size:.8rem;color:var(--muted);line-height:1.5;min-height:1.2em}
.panel{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:22px;min-width:0}.chart-panel{scroll-margin-top:95px}.panel-head{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:14px}.panel-title{font-weight:750;font-size:1.05rem}.panel-subtitle{font-size:.75rem;color:var(--muted);margin-top:4px}.chart-box{width:100%;height:250px;position:relative;min-width:0}.chart-box canvas{display:block;width:100%;height:100%;background:var(--bg);border-radius:8px;border:1px solid var(--border);cursor:crosshair;touch-action:pan-y}
.segmented{display:flex;gap:4px;background:var(--bg);padding:4px;border-radius:8px;border:1px solid var(--border);flex:none}.segmented button{background:transparent;border:0;color:var(--muted);padding:6px 10px;border-radius:6px;cursor:pointer;font-size:.8rem;font-weight:650}.segmented button.selected{background:var(--surface2);color:var(--text)}
.inline-toggle{display:flex;gap:2px;background:var(--bg);padding:2px;border-radius:6px;border:1px solid var(--border);flex:none}.inline-toggle button{background:transparent;border:0;color:var(--muted);padding:3px 7px;border-radius:4px;cursor:pointer;font-size:.7rem}.inline-toggle button.selected{background:var(--surface2);color:var(--text);font-weight:750}
.chart-tooltip{position:absolute;z-index:5;pointer-events:none;background:#020617;border:1px solid #334155;border-radius:7px;padding:8px 10px;color:var(--text);font-size:.75rem;line-height:1.55;box-shadow:0 8px 24px #0008;white-space:nowrap;max-width:calc(100% - 8px)}
.chart-footer{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-top:10px;font-size:.75rem;color:var(--muted)}.reset-zoom{background:transparent;border:1px solid var(--border);color:var(--muted);border-radius:6px;padding:5px 8px;cursor:pointer}.reset-zoom:hover{color:var(--text);border-color:var(--accent)}
.app-footer{display:flex;justify-content:space-between;gap:12px;color:var(--muted);font-size:.72rem;padding:4px 2px 12px}
[hidden]{display:none!important}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
@media(max-width:1100px){.metric-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.main{padding:22px}.sidebar{width:220px;flex-basis:220px}}
@media(max-width:720px){.topbar{padding:12px 14px;align-items:flex-start;flex-wrap:wrap}.top-actions{width:100%;justify-content:space-between}.search-wrap{flex:1}.search-wrap input{width:100%}.layout{display:block}.sidebar{position:relative;top:auto;height:auto;width:100%;flex-basis:auto;padding:12px;display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px;border-right:0;border-bottom:1px solid var(--border)}.sidebar .side-heading:first-child{grid-column:1/-1}.sidebar .side-heading:nth-of-type(2){grid-column:1/-1}.sidebar .side-divider{display:none}.sidebar .side-foot{grid-column:1/-1;margin-top:4px;display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:5px;border-top:1px solid var(--border)}.sidebar .side-foot .spaced{margin-top:0}.sidebar .collector-line{margin:0}.sidebar .collapse-button{grid-column:1/-1}.sidebar.collapsed{width:100%;height:auto;display:flex;flex-direction:row;flex-wrap:wrap;padding:10px}.sidebar.collapsed .nav-item{font-size:.8rem;height:auto;padding:8px}.sidebar.collapsed .side-heading,.sidebar.collapsed .side-divider{display:none}.sidebar.collapsed .side-foot{display:none}.sidebar.collapsed .range-buttons{display:none}.sidebar.collapsed .collapse-button{font-size:.8rem;width:auto}.sidebar.collapsed .collapse-button:after{content:" Expand"}.main{padding:16px;gap:16px}.page-heading{align-items:flex-start;flex-direction:column}.updated{text-align:left}.metric-grid{gap:10px}.metric-card{padding:14px}.panel{padding:14px}.chart-box{height:220px}.panel-head{align-items:flex-start;flex-wrap:wrap}.app-footer{flex-direction:column}.chart-footer{align-items:flex-start}}
@media(max-width:380px){.metric-grid{grid-template-columns:1fr}.range-buttons{grid-template-columns:repeat(4,1fr)}.metric-value{font-size:1.9rem}}
CSS_EOF

# ------------------------------ Frontend JavaScript ----------------------------
cat > "$WEB_DIR/app.js" <<'JS_EOF'
(() => {
'use strict';

const $ = (selector, root = document) => root.querySelector(selector); const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
const state = {
status: null,
samples: [],
rangeHours: 72,
memoryMode: 'percent',
cpuMode: 'overall',
collapsed: false,
charts: {},
refreshBusy: false,
lastError: null
};

const chartConfigs = {
cpuCanvas: {
tooltip: 'cpuTooltip',
summary: 'cpuChartSummary',
title: 'CPU',
value: sample => sample.cpu_percent,
unit: '%',
min: 0,
max: 100,
color: '#38bdf8'
},
memoryCanvas: {
tooltip: 'memoryTooltip',
summary: 'memoryChartSummary',
title: 'Memory',
value: sample => sample.memory && sample.memory.used_percent,
unit: '%',
min: 0,
max: 100,
color: '#a78bfa'
},
tempCanvas: {
tooltip: 'tempTooltip',
summary: 'tempChartSummary',
title: 'Temperature',
value: sample => sample.temperature_c,
unit: '°C',
min: null,
max: null,
color: '#fb7185'
}
};

function byId(id) { return document.getElementById(id); }
function safeNumber(value, digits = 1) {
return Number.isFinite(Number(value)) ? Number(value).toFixed(digits) : '—';
}
function formatBytesMiB(bytes) {
return Number.isFinite(Number(bytes)) ? (Number(bytes) / 1048576).toLocaleString(undefined, {maximumFractionDigits: 0}) : '—';
}
function formatTime(timestamp) {
if (!Number.isFinite(Number(timestamp))) return '—';
return new Date(Number(timestamp) * 1000).toLocaleString([], {
month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit'
});
}
function setConnection(online, label) {
const text = byId('connectionText');
const dot = byId('connectionDot');
const collector = byId('collectorStatus');
const collectorDot = byId('collectorDot');
if (text) text.textContent = label;
if (dot) dot.className = `live-dot ${online ? 'online' : 'offline'}`;
if (collector) collector.textContent = online ? 'Running' : 'Offline';
if (collectorDot) collectorDot.className = `status-dot ${online ? 'online' : 'offline'}`;
}

async function fetchJSON(url) {
const response = await fetch(url, {cache: 'no-store', headers: {'Accept': 'application/json'}});
if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
return response.json();
}

function updateMetrics() {
const status = state.status;
if (!status) return;
byId('sampleInterval').textContent = `${status.interval_seconds}s`;
byId('sampleCount').textContent = `${status.sample_count} / RAM`;
const latest = status.latest;
if (!latest) return;

byId('cpuValue').textContent = latest.cpu_percent == null ? '—' : safeNumber(latest.cpu_percent, 1);
byId('cpuMeta').textContent = `System-wide utilisation · uptime ${formatDuration(status.system_uptime_seconds)}`;

const memory = latest.memory || {};
if (state.memoryMode === 'percent') {
byId('memoryValue').textContent = memory.used_percent == null ? '—' : safeNumber(memory.used_percent, 1);
byId('memoryUnit').textContent = '%';
byId('memoryMeta').textContent = `${formatBytesMiB(memory.used_bytes)} / ${formatBytesMiB(memory.total_bytes)} MiB used`;
} else {
byId('memoryValue').textContent = formatBytesMiB(memory.used_bytes);
byId('memoryUnit').textContent = 'MiB';
byId('memoryMeta').textContent = `${safeNumber(memory.used_percent, 1)}% used of ${formatBytesMiB(memory.total_bytes)} MiB`;
}

byId('tempValue').textContent = latest.temperature_c == null ? 'N/A' : safeNumber(latest.temperature_c, 1);
byId('tempMeta').textContent = latest.temperature_c == null ? 'Sensor unavailable' : 'Detected thermal sensor';

const storage = latest.storage || {};
byId('storageValue').textContent = storage.used_percent == null ? '—' : safeNumber(storage.used_percent, 1);
byId('storageMeta').textContent = `${formatBytesMiB(storage.used_bytes)} / ${formatBytesMiB(storage.total_bytes)} MiB used`;
byId('lastSample').textContent = formatTime(latest.timestamp);
}

function formatDuration(seconds) {
const value = Math.max(0, Math.floor(Number(seconds) || 0));
const days = Math.floor(value / 86400);
const hours = Math.floor((value % 86400) / 3600);
const minutes = Math.floor((value % 3600) / 60);
if (days) return `${days}d ${hours}h`;
if (hours) return `${hours}h ${minutes}m`;
return `${minutes}m`;
}

function visibleSamples() {
const cutoff = Date.now() / 1000 - state.rangeHours * 3600;
return state.samples.filter(sample => Number(sample.timestamp) >= cutoff);
}

function getChartState(canvasId) {
if (!state.charts[canvasId]) {
state.charts[canvasId] = {zoom: 1, pan: 0, hoverIndex: null, dragging: false, dragX: 0, dragPan: 0, plot: null};
}
return state.charts[canvasId];
}

function getSeries(canvasId, samples) {
if (canvasId === 'cpuCanvas' && state.cpuMode === 'cores') {
const names = new Set();
samples.forEach(sample => Object.keys(sample.cores || {}).forEach(name => names.add(name)));
return Array.from(names).sort((a, b) => Number(a.slice(3)) - Number(b.slice(3))).map((name, index) => ({
name,
color: ['#38bdf8', '#a78bfa', '#34d399', '#fbbf24', '#fb7185', '#22d3ee', '#c084fc', '#bef264'][index % 8],
values: samples.map(sample => sample.cores && sample.cores[name] != null ? Number(sample.cores[name]) : null)
}));
}
const config = chartConfigs[canvasId];
return [{
name: config.title,
color: config.color,
values: samples.map(sample => {
const value = config.value(sample);
return value == null || !Number.isFinite(Number(value)) ? null : Number(value);
})
}];
}

function drawChart(canvasId) {
const canvas = byId(canvasId);
if (!canvas) return;
const box = canvas.parentElement;
const rect = canvas.getBoundingClientRect();
if (!rect.width || !rect.height) return;

const dpr = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
const width = Math.floor(rect.width * dpr);
const height = Math.floor(rect.height * dpr);
if (canvas.width !== width || canvas.height !== height) {
canvas.width = width;
canvas.height = height;
}
const ctx = canvas.getContext('2d');
if (!ctx) return;
ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
const w = rect.width, h = rect.height;
ctx.clearRect(0, 0, w, h);
ctx.fillStyle = '#030712';
ctx.fillRect(0, 0, w, h);

const allSamples = visibleSamples();
const cfg = chartConfigs[canvasId];
const chartState = getChartState(canvasId);
const left = 44, right = 14, top = 16, bottom = 29;
const plot = {x: left, y: top, w: Math.max(1, w - left - right), h: Math.max(1, h - top - bottom)};
chartState.plot = plot;

if (!allSamples.length) {
ctx.fillStyle = '#94a3b8';
ctx.font = '12px system-ui, sans-serif';
ctx.textAlign = 'center';
ctx.fillText('Waiting for samples in this time range…', w / 2, h / 2);
const summary = byId(cfg.summary);
if (summary) summary.textContent = 'No samples in selected window yet.';
const tooltip = byId(cfg.tooltip);
if (tooltip) tooltip.hidden = true;
return;
}

const series = getSeries(canvasId, allSamples);
const total = allSamples.length;
const zoom = Math.max(1, Math.min(20, chartState.zoom));
const windowCount = Math.max(2, Math.ceil(total / zoom));
const maxPan = Math.max(0, total - windowCount);
chartState.pan = Math.max(0, Math.min(maxPan, chartState.pan));
const start = Math.max(0, Math.min(maxPan, maxPan - chartState.pan));
const end = Math.min(total, start + windowCount);
const samples = allSamples.slice(start, end);
const shownSeries = series;

let minVal = cfg.min;
let maxVal = cfg.max;
if (minVal == null || maxVal == null) {
const values = shownSeries.flatMap(s => s.values.slice(start, end)).filter(Number.isFinite);
if (values.length) {
minVal = Math.max(0, Math.floor(Math.min(...values) / 5) * 5 - 5);
maxVal = Math.ceil(Math.max(...values) / 5) * 5 + 5;
if (maxVal <= minVal) maxVal = minVal + 10;
} else { minVal = 0; maxVal = 100; }
}

ctx.font = '10px system-ui, sans-serif';
ctx.textAlign = 'right';
ctx.textBaseline = 'middle';
for (let tick = 0; tick <= 4; tick++) {
const value = minVal + (maxVal - minVal) * tick / 4;
const y = plot.y + plot.h - plot.h * tick / 4;
ctx.strokeStyle = '#1e293b';
ctx.lineWidth = 1;
ctx.beginPath(); ctx.moveTo(plot.x, y); ctx.lineTo(plot.x + plot.w, y); ctx.stroke();
ctx.fillStyle = '#94a3b8';
ctx.fillText(`${Number(value.toFixed(1))}${cfg.unit}`, plot.x - 7, y);
}

const firstTime = samples[0].timestamp;
const lastTime = samples[samples.length - 1].timestamp;
for (let tick = 0; tick <= 4; tick++) {
const x = plot.x + plot.w * tick / 4;
ctx.strokeStyle = '#111c31';
ctx.beginPath(); ctx.moveTo(x, plot.y); ctx.lineTo(x, plot.y + plot.h); ctx.stroke();
const timestamp = firstTime + (lastTime - firstTime) * tick / 4;
ctx.fillStyle = '#94a3b8';
ctx.textAlign = tick === 0 ? 'left' : tick === 4 ? 'right' : 'center';
ctx.textBaseline = 'top';
ctx.fillText(new Date(timestamp * 1000).toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'}), x, plot.y + plot.h + 7);
}

const indexOffset = start;
shownSeries.forEach(s => {
ctx.strokeStyle = s.color;
ctx.lineWidth = 1.8;
ctx.lineJoin = 'round';
ctx.lineCap = 'round';
ctx.beginPath();
let started = false;
s.values.slice(start, end).forEach((raw, i) => {
if (!Number.isFinite(raw)) { started = false; return; }
const x = plot.x + (samples.length <= 1 ? 0 : i / (samples.length - 1) * plot.w);
const y = plot.y + plot.h - ((raw - minVal) / (maxVal - minVal)) * plot.h;
if (!started) { ctx.moveTo(x, y); started = true; } else ctx.lineTo(x, y);
});
ctx.stroke();
});

const hoverIndex = chartState.hoverIndex;
if (hoverIndex != null && hoverIndex >= 0 && hoverIndex < samples.length) {
const x = plot.x + (samples.length <= 1 ? 0 : hoverIndex / (samples.length - 1) * plot.w);
ctx.strokeStyle = '#64748b';
ctx.setLineDash([4, 4]);
ctx.beginPath(); ctx.moveTo(x, plot.y); ctx.lineTo(x, plot.y + plot.h); ctx.stroke();
ctx.setLineDash([]);
shownSeries.forEach(s => {
const value = s.values[start + hoverIndex];
if (!Number.isFinite(value)) return;
const y = plot.y + plot.h - ((value - minVal) / (maxVal - minVal)) * plot.h;
ctx.fillStyle = s.color;
ctx.beginPath(); ctx.arc(x, y, 3.5, 0, Math.PI * 2); ctx.fill();
});
const tooltip = byId(cfg.tooltip);
if (tooltip) {
const sample = samples[hoverIndex];
const lines = shownSeries.map(s => {
const value = s.values[start + hoverIndex];
return Number.isFinite(value) ? `<div><span style="color:${s.color}">●</span> ${escapeHTML(s.name)}: <b>${value.toFixed(1)} ${cfg.unit}</b></div>` : '';
}).filter(Boolean).slice(0, 8).join('');
tooltip.innerHTML = `<div><b>${escapeHTML(formatTime(sample.timestamp))}</b></div>${lines}${shownSeries.length > 8 ? '<div>… more cores</div>' : ''}`;
tooltip.hidden = false;
const tipWidth = tooltip.offsetWidth || 190;
const tipHeight = tooltip.offsetHeight || 70;
let tipX = x + 12;
if (tipX + tipWidth > w - 4) tipX = x - tipWidth - 12;
tooltip.style.left = `${Math.max(4, Math.min(w - tipWidth - 4, tipX))}px`;
tooltip.style.top = `${Math.max(4, Math.min(h - tipHeight - 4, plot.y + 5))}px`;
}
} else {
const tooltip = byId(cfg.tooltip);
if (tooltip) tooltip.hidden = true;
}

const summary = byId(cfg.summary);
if (summary) {
const last = allSamples[allSamples.length - 1];
summary.textContent = `${samples.length} visible samples · ${formatTime(samples[0].timestamp)} – ${formatTime(samples[samples.length - 1].timestamp)}${chartState.zoom > 1 ? ` · ${chartState.zoom.toFixed(1)}× zoom` : ''}`;
}
}

function escapeHTML(value) {
return String(value).replace(/[&<>"']/g, char => ({
'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
})[char]);
}

function redrawCharts() {
Object.keys(chartConfigs).forEach(drawChart);
}

function bindChartInteractions(canvasId) {
const canvas = byId(canvasId);
const chartState = getChartState(canvasId);
if (!canvas) return;
canvas.addEventListener('pointermove', event => {
const rect = canvas.getBoundingClientRect();
const x = event.clientX - rect.left;
if (chartState.dragging) {
const plot = chartState.plot;
if (plot) {
const samples = visibleSamples();
const windowCount = Math.max(2, Math.ceil(samples.length / chartState.zoom));
const step = plot.w / Math.max(1, windowCount);
chartState.pan = chartState.dragPan + (event.clientX - chartState.dragX) / Math.max(1, step);
chartState.pan = Math.max(0, Math.min(Math.max(0, samples.length - windowCount), chartState.pan));
drawChart(canvasId);
}
return;
}
const plot = chartState.plot;
if (!plot || x < plot.x || x > plot.x + plot.w) {
chartState.hoverIndex = null;
drawChart(canvasId);
return;
}
const samples = visibleSamples();
const total = samples.length;
const count = Math.max(2, Math.ceil(total / chartState.zoom));
const maxPan = Math.max(0, total - count);
const start = Math.max(0, Math.min(maxPan, maxPan - chartState.pan));
const end = Math.min(total, start + count);
const shown = end - start;
chartState.hoverIndex = shown ? Math.max(0, Math.min(shown - 1, Math.round((x - plot.x) / plot.w * (shown - 1)))) : null;
drawChart(canvasId);
});
canvas.addEventListener('pointerleave', () => {
if (!chartState.dragging) {
chartState.hoverIndex = null;
drawChart(canvasId);
}
});
canvas.addEventListener('pointerdown', event => {
if (event.button !== 0) return;
chartState.dragging = true;
chartState.dragX = event.clientX;
chartState.dragPan = chartState.pan;
canvas.classList.add('dragging');
try { canvas.setPointerCapture(event.pointerId); } catch (_) {}
});
canvas.addEventListener('pointerup', () => {
chartState.dragging = false;
canvas.classList.remove('dragging');
});
canvas.addEventListener('pointercancel', () => {
chartState.dragging = false;
canvas.classList.remove('dragging');
});
canvas.addEventListener('wheel', event => {
event.preventDefault();
chartState.zoom = Math.max(1, Math.min(20, chartState.zoom * (event.deltaY < 0 ? 1.25 : 0.8)));
chartState.hoverIndex = null;
drawChart(canvasId);
}, {passive: false});
const reset = $(`[data-reset-chart="${canvasId}"]`);
if (reset) reset.addEventListener('click', () => {
chartState.zoom = 1; chartState.pan = 0; chartState.hoverIndex = null;
drawChart(canvasId);
});
}

async function refresh() {
if (state.refreshBusy) return;
state.refreshBusy = true;
try {
const [status, history] = await Promise.all([fetchJSON('/api/status'), fetchJSON('/api/history')]);
state.status = status;
state.samples = Array.isArray(history.samples) ? history.samples : [];
state.lastError = null;
setConnection(true, 'CONNECTED');
updateMetrics();
redrawCharts();
} catch (error) {
state.lastError = error;
setConnection(false, 'DISCONNECTED');
const summaries = ['cpuChartSummary', 'memoryChartSummary', 'tempChartSummary'];
summaries.forEach(id => { if (byId(id)) byId(id).textContent = 'Unable to load telemetry. Check the CoreTrace service.'; });
} finally {
state.refreshBusy = false;
}
}

function bindControls() {
$$('.range-buttons [data-range]').forEach(button => {
button.addEventListener('click', () => {
state.rangeHours = Number(button.dataset.range) || 72;
$$('.range-buttons [data-range]').forEach(item => item.classList.toggle('selected', item === button)); Object.values(state.charts).forEach(chart => { chart.zoom = 1; chart.pan = 0; chart.hoverIndex = null; }); redrawCharts(); }); });  $$
('.inline-toggle [data-memory-mode]').forEach(button => {
button.addEventListener('click', () => {
state.memoryMode = button.dataset.memoryMode;
$$('.inline-toggle [data-memory-mode]').forEach(item => item.classList.toggle('selected', item === button)); updateMetrics(); }); });  $$
('[data-cpu-mode]').forEach(button => {
button.addEventListener('click', () => {
state.cpuMode = button.dataset.cpuMode;
$$('[data-cpu-mode]').forEach(item => item.classList.toggle('selected', item === button)); redrawCharts(); }); });  $$
('.nav-item[data-target]').forEach(button => {
button.addEventListener('click', () => {
const target = byId(button.dataset.target);
if (!target) return;
$$('.nav-item').forEach(item => item.classList.toggle('active', item === button)); target.scrollIntoView({behavior: 'smooth', block: 'start'}); }); });  const search = byId('search'); if (search) search.addEventListener('input', () => { const query = search.value.trim().toLowerCase(); $$
('[data-search]').forEach(element => {
const text = `${element.dataset.search || ''} ${element.textContent || ''}`.toLowerCase();
element.hidden = Boolean(query) && !text.includes(query);
});
if (query) {
const first = $$('[data-search]').find(element => !element.hidden);
if (first) first.scrollIntoView({behavior: 'smooth', block: 'nearest'});
}
});

const sidebarToggle = byId('sidebarToggle');
if (sidebarToggle) sidebarToggle.addEventListener('click', () => {
state.collapsed = !state.collapsed;
byId('sidebar').classList.toggle('collapsed', state.collapsed);
sidebarToggle.textContent = state.collapsed ? '› Expand' : '‹ Collapse';
sidebarToggle.setAttribute('aria-label', state.collapsed ? 'Expand sidebar' : 'Collapse sidebar');
requestAnimationFrame(redrawCharts);
});
}

function init() {
Object.keys(chartConfigs).forEach(bindChartInteractions);
bindControls();
refresh();
window.setInterval(refresh, 5000);
window.addEventListener('resize', () => requestAnimationFrame(redrawCharts));
}

document.addEventListener('DOMContentLoaded', init);
})();
JS_EOF

# ------------------------------ Uninstaller ------------------------------------
cat > "$UNINSTALL_PATH" <<'UNINSTALL_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="coretrace.service"
CURRENT_USER="${SUDO_USER:-$(id -un)}"

if [[ "$CURRENT_USER" == "root" ]]; then
echo "[ERROR] Run the uninstaller as the installation user, not root."
exit 1
fi

USER_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
if [[ -z "$USER_HOME" \vert{}\vert{} "$USER_HOME" == "/" ]]; then
echo "[ERROR] Could not safely determine the user's home directory."
exit 1
fi

INSTALL_DIR="$USER_HOME/coretrace"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

echo
echo "============================================"
echo " CORETRACE V1.4 UNINSTALLER"
echo "============================================"
echo "Installation: $INSTALL_DIR"
echo "Service : $SERVICE_NAME"
echo
read -r -p "Remove CoreTrace and its service? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
echo "[INFO] Uninstallation cancelled."
exit 0
fi

sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
sudo rm -f "$SERVICE_PATH"
sudo systemctl daemon-reload
sudo systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

if [[ -d "$INSTALL_DIR" && "$INSTALL_DIR" == "$USER_HOME/coretrace" ]]; then
rm -rf -- "$INSTALL_DIR"
fi

echo "[OK] CoreTrace V1.4 files and service removed."
echo "[INFO] Unrelated services and network configuration were left untouched."
UNINSTALL_EOF
chmod 755 "$UNINSTALL_PATH"

