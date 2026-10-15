#!/usr/bin/env bash
# ==============================================================================
# CoreTrace V1.0 All-in-One Self-Contained Deployment & Management Console
# PERSISTENT: FALSE (Metrics history is RAM-only; service/app files on disk)
# Category: System Monitoring
# ==============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="CoreTrace"
APP_VERSION="V1.0"
SERVICE_NAME="coretrace.service"
DEFAULT_PORT="8087"
DEFAULT_INTERVAL="20"
DEFAULT_HISTORY_HOURS="72"

# Dynamically detect real user even if run via sudo
if [ -n "${SUDO_USER:-}" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$(whoami)"
fi

USER_HOME="$(eval echo ~$CURRENT_USER)"
INSTALL_DIR="$USER_HOME/coretrace"
WEB_DIR="$INSTALL_DIR/web"
PYTHON_APP_PATH="$INSTALL_DIR/coretrace.py"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

PORT="$DEFAULT_PORT"
INTERVAL="$DEFAULT_INTERVAL"
HISTORY_HOURS="$DEFAULT_HISTORY_HOURS"
BIND_ADDRESS="127.0.0.1"

# ------------------------------ Dependency Detection --------------------------
echo "[*] Checking Python3 and whiptail environment..."
if ! command -v python3 &>/dev/null; then
    echo "[!] python3 could not be found. Installing python3..."
    sudo apt-get update && sudo apt-get install -y python3 whiptail
elif ! command -v whiptail &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y whiptail
fi

[[ "$(uname -s)" == "Linux" ]] || { echo "[!] CoreTrace targets Linux environments."; exit 1; }

# ------------------------------ Load Existing Config --------------------------
load_existing_settings() {
    local envfile="$INSTALL_DIR/coretrace.env"
    [[ -f "$envfile" ]] || return 0
    while IFS='=' read -r key value; do
        value="${value%$'\r'}"
        case "$key" in
            CORETRACE_PORT) [[ "$value" =~ ^[0-9]+$ ]] && PORT="$value" ;;
            CORETRACE_INTERVAL) [[ "$value" =~ ^[0-9]+$ ]] && INTERVAL="$value" ;;
            CORETRACE_HISTORY_HOURS) [[ "$value" =~ ^[0-9]+$ ]] && HISTORY_HOURS="$value" ;;
        esac
    done < "$envfile"
}

load_existing_settings

# ------------------------------ Whiptail Management Menu ----------------------
if command -v whiptail &>/dev/null; then
    CHOICE=$(whiptail --title "CoreTrace Management Console" --menu "Choose an option:" 15 60 4 \
        "1" "Install or Update CoreTrace" \
        "2" "Configure Settings" \
        "3" "Uninstall CoreTrace" \
        "4" "Exit" 3>&1 1>&2 2>&3)
    EXIT_STATUS=$?
    if [ $EXIT_STATUS -ne 0 ]; then
        exit 0
    fi
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
        PORT=$(whiptail --title "CoreTrace Settings" --inputbox "Enter Web Server Port:" 10 50 "$PORT" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && PORT="$DEFAULT_PORT"
        INTERVAL=$(whiptail --title "CoreTrace Settings" --inputbox "Enter Sampling Interval (seconds):" 10 50 "$INTERVAL" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && INTERVAL="$DEFAULT_INTERVAL"
        HISTORY_HOURS=$(whiptail --title "CoreTrace Settings" --inputbox "Enter History Window (hours):" 10 50 "$HISTORY_HOURS" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && HISTORY_HOURS="$DEFAULT_HISTORY_HOURS"
        ;;
    1|*)
        if [ ! -f "$PYTHON_APP_PATH" ] && command -v whiptail &>/dev/null; then
            if (whiptail --title "CoreTrace Setup" --yesno "Would you like to customize settings before installing?" 10 50); then
                PORT=$(whiptail --title "CoreTrace Setup" --inputbox "Enter Web Server Port:" 10 50 "$PORT" 3>&1 1>&2 2>&3)
                [ $? -ne 0 ] && PORT="$DEFAULT_PORT"
                INTERVAL=$(whiptail --title "CoreTrace Setup" --inputbox "Enter Sampling Interval (seconds):" 10 50 "$INTERVAL" 3>&1 1>&2 2>&3)
                [ $? -ne 0 ] && INTERVAL="$DEFAULT_INTERVAL"
                HISTORY_HOURS=$(whiptail --title "CoreTrace Setup" --inputbox "Enter History Window (hours):" 10 50 "$HISTORY_HOURS" 3>&1 1>&2 2>&3)
                [ $? -ne 0 ] && HISTORY_HOURS="$DEFAULT_HISTORY_HOURS"
            fi
        fi
        ;;
    4)
        exit 0
        ;;
esac

# ------------------------------ Write Application Payload ---------------------
mkdir -p "$WEB_DIR"

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
BIND = "127.0.0.1"

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

def sampler():
    next_tick = time.monotonic()
    while not stop_event.is_set():
        now = time.time()
        global prev_cpu, prev_cores
        current_cpu, current_cores = read_cpu_counters()
        overall = cpu_percent(current_cpu, prev_cpu)
        prev_cpu = current_cpu
        prev_cores = current_cores
        
        sample = {
            "timestamp": round(now, 3),
            "iso_time": datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="seconds"),
            "cpu_percent": overall,
            "memory": read_memory(),
            "temperature_c": read_cpu_temperature(),
            "storage": read_storage()
        }
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

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/status":
            with history_lock:
                latest = history[-1] if history else None
                count = len(history)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"app": APP_NAME, "version": APP_VERSION, "port": PORT, "sample_count": count, "latest": latest}).encode())
            return
        
        files_map = {"/": "index.html", "/index.html": "index.html", "/style.css": "style.css", "/app.js": "app.js"}
        if path in files_map:
            fname = files_map[path]
            ctype = "text/html; charset=utf-8" if fname.endswith(".html") else ("text/css" if fname.endswith(".css") else "application/javascript")
            try:
                self.send_bytes((WEB_DIR / fname).read_bytes(), ctype)
            except OSError:
                self.send_bytes(b"Asset missing", "text/plain", 500)
        else:
            self.send_bytes(b"Not found", "text/plain", 404)

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

# ------------------------------ Write Web Assets ------------------------------
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
      <div class="brand-name">CoreTrace V1.0</div>
      <div class="live-pill"><span class="live-dot"></span><span id="connectionText">CONNECTING</span></div>
    </header>
    <div class="layout" style="padding: 24px;">
      <div class="metric-grid" style="display:grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; width: 100%;">
        <div style="background:#0f172a; border:1px solid #1e293b; padding:20px; border-radius:12px;">
          <div style="color:#94a3b8; font-size:0.75rem; font-weight:700;">CPU USAGE</div>
          <div style="font-size:2rem; font-weight:800; margin-top:10px;"><span id="cpuValue">—</span>%</div>
        </div>
        <div style="background:#0f172a; border:1px solid #1e293b; padding:20px; border-radius:12px;">
          <div style="color:#94a3b8; font-size:0.75rem; font-weight:700;">MEMORY USAGE</div>
          <div style="font-size:2rem; font-weight:800; margin-top:10px;"><span id="memoryValue">—</span>%</div>
        </div>
        <div style="background:#0f172a; border:1px solid #1e293b; padding:20px; border-radius:12px;">
          <div style="color:#94a3b8; font-size:0.75rem; font-weight:700;">CPU TEMP</div>
          <div style="font-size:2rem; font-weight:800; margin-top:10px;"><span id="tempValue">—</span>°C</div>
        </div>
      </div>
    </div>
  </div>
</body>
</html>
EOF

cat << 'EOF' > "$WEB_DIR/style.css"
body { background: #030712; color: #f8fafc; font-family: system-ui, sans-serif; margin: 0; }
.topbar { display: flex; justify-content: space-between; align-items: center; padding: 16px 24px; background: #0f172a; border-bottom: 1px solid #1e293b; }
.brand-name { font-weight: 800; font-size: 1.25rem; }
.live-pill { display: flex; align-items: center; gap: 8px; background: #1e293b; padding: 6px 12px; border-radius: 20px; font-size: 0.75rem; }
.live-dot { width: 8px; height: 8px; border-radius: 50%; background: #22c55e; }
EOF

cat << 'EOF' > "$WEB_DIR/app.js"
async function fetchStatus() {
    try {
        let res = await fetch('/api/status');
        let data = await res.json();
        document.getElementById('connectionText').innerText = 'CONNECTED';
        if (data.latest) {
            document.getElementById('cpuValue').innerText = data.latest.cpu_percent ?? '—';
            document.getElementById('memoryValue').innerText = data.latest.memory?.used_percent ?? '—';
            document.getElementById('tempValue').innerText = data.latest.temperature_c ?? 'N/A';
        }
    } catch(e) {
        document.getElementById('connectionText').innerText = 'DISCONNECTED';
    }
}
setInterval(fetchStatus, 5000);
fetchStatus();
EOF

# ------------------------------ Systemd Service Setup -------------------------
cat <<EOF | sudo tee "$SERVICE_PATH" > /dev/null
[Unit]
Description=CoreTrace V1.0 System Monitor
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$INSTALL_DIR
Environment=CORETRACE_PORT=$PORT
Environment=CORETRACE_INTERVAL=$INTERVAL
Environment=CORETRACE_HISTORY_HOURS=$HISTORY_HOURS
ExecStart=/usr/bin/python3 $PYTHON_APP_PATH
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo ""
echo "=============================================================================="
echo " CoreTrace V1.0 deployment complete!"
echo " Web UI  : http://127.0.0.1:$PORT"
echo " Service : sudo systemctl status $SERVICE_NAME"
echo "=============================================================================="
