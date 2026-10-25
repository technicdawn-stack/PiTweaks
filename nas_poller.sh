#!/bin/bash
# Description: PiTweaks NAS Monitor Installer - SNMP, RAM JSON, Dashboard & History V2.0
# PERSISTENT: FALSE
# Category: Scripts
#
# Features:
# - Preserves existing config unless the user chooses reset
# - SNMP collection from Synology NAS
# - RAM-backed JSON feed at /run/nas-stats/nas-status.json
# - HTTP JSON endpoint on port 8088 (compatible with existing URL)
# - Built-in lightweight graph page at /dashboard.html (same origin, no CORS setup)
# - CPU, RAM, temperature, disk, network counters and calculated throughput history
# - Configurable history retention (default 3 days at one-minute collection)
# - Optional one-minute cron collection
# - systemd RuntimeDirectory handles /run directory creation after reboot

set -euo pipefail

# ==============================================================================
# PATH & USER CONFIGURATION
# ==============================================================================

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    CURRENT_USER="$SUDO_USER"
    REAL_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
else
    CURRENT_USER="$(id -un)"
    REAL_HOME="$HOME"
fi

if [[ -z "${REAL_HOME:-}" || ! -d "$REAL_HOME" ]]; then
    echo "ERROR: Could not determine the target user's home directory."
    exit 1
fi

INSTALL_DIR="$REAL_HOME/PiTweaks/nas_monitor"
SCRIPT_PATH="$INSTALL_DIR/nas_poller.py"
SERVER_PATH="$INSTALL_DIR/nas_stats_server.py"
DASHBOARD_PATH="$INSTALL_DIR/dashboard.html"
CONFIG_FILE="$INSTALL_DIR/config.env"
RAM_DIR="/run/nas-stats"
SERVICE_NAME="nas-stats-server"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME.service"
CRON_MARKER="# PiTweaks NAS Monitor"

mkdir -p "$INSTALL_DIR"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$INSTALL_DIR"

# ==============================================================================
# DEPENDENCY CHECK
# ==============================================================================

echo "Checking dependencies..."

if ! command -v whiptail >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y whiptail -qq
fi

if ! command -v snmpget >/dev/null 2>&1; then
    echo "Installing SNMP utilities..."
    sudo apt-get update -qq
    sudo apt-get install -y snmp -qq
fi

if ! command -v python3 >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y python3 -qq
fi

# ==============================================================================
# CONFIGURATION
# ==============================================================================

CONFIG_ACTION="keep"
if [[ -f "$CONFIG_FILE" ]]; then
    if whiptail --backtitle "PiTweaks | NAS Monitor" \
        --title "Existing Configuration Found" \
        --yesno "An existing config.env was found.\n\nYES: Keep current settings and update code.\nNO: Reset and configure settings again." 11 76; then
        CONFIG_ACTION="keep"
    else
        CONFIG_ACTION="reset"
    fi
else
    CONFIG_ACTION="reset"
fi

if [[ "$CONFIG_ACTION" == "reset" ]]; then
    NAS_IP_INPUT="$(whiptail --backtitle "PiTweaks | NAS Monitor" \
        --title "NAS IP Address" \
        --inputbox "Enter your Synology NAS IP address:" 8 65 "192.168.1.50" \
        3>&1 1>&2 2>&3)" || exit 1

    COMMUNITY_INPUT="$(whiptail --backtitle "PiTweaks | NAS Monitor" \
        --title "SNMP Community" \
        --inputbox "Enter the SNMP v2c community name configured on the NAS:" 8 65 "public" \
        3>&1 1>&2 2>&3)" || exit 1

    HISTORY_DAYS_INPUT="$(whiptail --backtitle "PiTweaks | NAS Monitor" \
        --title "History Retention" \
        --inputbox "How many days of history should be kept in RAM? (1-7)" 8 65 "3" \
        3>&1 1>&2 2>&3)" || exit 1

    if ! [[ "$HISTORY_DAYS_INPUT" =~ ^[1-7]$ ]]; then
        whiptail --title "Invalid Retention" --msgbox "History retention must be a whole number from 1 to 7 days. Using 3 days." 8 65
        HISTORY_DAYS_INPUT="3"
    fi

    POLL_INTERVAL_INPUT="$(whiptail --backtitle "PiTweaks | NAS Monitor" \
        --title "Collection Interval" \
        --inputbox "Collection interval in seconds (recommended: 60; minimum: 30)" 8 65 "60" \
        3>&1 1>&2 2>&3)" || exit 1

    if ! [[ "$POLL_INTERVAL_INPUT" =~ ^[0-9]+$ ]] || (( POLL_INTERVAL_INPUT < 30 || POLL_INTERVAL_INPUT > 3600 )); then
        whiptail --title "Invalid Interval" --msgbox "Interval must be 30-3600 seconds. Using 60 seconds." 8 65
        POLL_INTERVAL_INPUT="60"
    fi

    umask 077
    cat > "$CONFIG_FILE" <<EOF
NAS_IP="$NAS_IP_INPUT"
SNMP_COMMUNITY="$COMMUNITY_INPUT"
NAS_STATS_OUTPUT="$RAM_DIR/nas-status.json"
HISTORY_DAYS="$HISTORY_DAYS_INPUT"
POLL_INTERVAL="$POLL_INTERVAL_INPUT"
HTTP_PORT="8088"
BACKUP_STATUS_LABEL="Active (Restic)"
DISK_STORAGE_INDEX="auto"
NETWORK_INTERFACE_INDEX="auto"
EOF
    sudo chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
else
    echo "Keeping existing configuration."
fi

# Ensure newer config options exist while preserving existing values.
if ! grep -q '^HISTORY_DAYS=' "$CONFIG_FILE"; then echo 'HISTORY_DAYS="3"' >> "$CONFIG_FILE"; fi
if ! grep -q '^POLL_INTERVAL=' "$CONFIG_FILE"; then echo 'POLL_INTERVAL="60"' >> "$CONFIG_FILE"; fi
if ! grep -q '^HTTP_PORT=' "$CONFIG_FILE"; then echo 'HTTP_PORT="8088"' >> "$CONFIG_FILE"; fi
if ! grep -q '^BACKUP_STATUS_LABEL=' "$CONFIG_FILE"; then echo 'BACKUP_STATUS_LABEL="Active (Restic)"' >> "$CONFIG_FILE"; fi
if ! grep -q '^DISK_STORAGE_INDEX=' "$CONFIG_FILE"; then echo 'DISK_STORAGE_INDEX="auto"' >> "$CONFIG_FILE"; fi
if ! grep -q '^NETWORK_INTERFACE_INDEX=' "$CONFIG_FILE"; then echo 'NETWORK_INTERFACE_INDEX="auto"' >> "$CONFIG_FILE"; fi
sudo chown "$CURRENT_USER:$CURRENT_USER" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# ==============================================================================
# WRITE POLLER
# ==============================================================================

cat > "$SCRIPT_PATH" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import re
import subprocess
import tempfile
from datetime import datetime, timezone

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.env")

def load_config(path):
    cfg = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                cfg[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return cfg

cfg = load_config(CONFIG_PATH)
NAS_IP = cfg.get("NAS_IP", "192.168.1.50")
COMMUNITY = cfg.get("SNMP_COMMUNITY", "public")
OUTPUT_FILE = cfg.get("NAS_STATS_OUTPUT", "/run/nas-stats/nas-status.json")
HISTORY_DAYS = max(1, min(7, int(cfg.get("HISTORY_DAYS", "3") or 3)))
POLL_INTERVAL = max(30, min(3600, int(cfg.get("POLL_INTERVAL", "60") or 60)))
MAX_HISTORY = max(10, int((HISTORY_DAYS * 86400) / POLL_INTERVAL))
BACKUP_STATUS_LABEL = cfg.get("BACKUP_STATUS_LABEL", "Active (Restic)")
DISK_STORAGE_INDEX = cfg.get("DISK_STORAGE_INDEX", "auto")
NETWORK_INTERFACE_INDEX = cfg.get("NETWORK_INTERFACE_INDEX", "auto")

# Synology enterprise MIB and standard HOST-RESOURCES / IF-MIB OIDs.
OID_UPTIME = "1.3.6.1.2.1.1.3.0"
OID_SYS_TEMP = "1.3.6.1.4.1.6574.1.2.0"
OID_SYS_STATUS = "1.3.6.1.4.1.6574.1.1.0"
OID_CPU = "1.3.6.1.4.1.6574.1.7.1.0"
OID_RAM = "1.3.6.1.4.1.6574.1.7.2.0"
OID_HR_STORAGE_DESCR = "1.3.6.1.2.1.25.2.3.1.3"
OID_HR_STORAGE_UNITS = "1.3.6.1.2.1.25.2.3.1.4"
OID_HR_STORAGE_SIZE = "1.3.6.1.2.1.25.2.3.1.5"
OID_HR_STORAGE_USED = "1.3.6.1.2.1.25.2.3.1.6"
OID_IF_DESCR = "1.3.6.1.2.1.2.2.1.2"
OID_IF_IN_OCTETS = "1.3.6.1.2.1.2.2.1.10"
OID_IF_OUT_OCTETS = "1.3.6.1.2.1.2.2.1.16"
OID_IF_HC_IN_OCTETS = "1.3.6.1.2.1.31.1.1.1.6"
OID_IF_HC_OUT_OCTETS = "1.3.6.1.2.1.31.1.1.1.10"

def snmpget(oid):
    try:
        p = subprocess.run(
            ["snmpget", "-v2c", "-c", COMMUNITY, "-Oqv", "-t", "1", "-r", "1", NAS_IP, oid],
            capture_output=True, text=True, timeout=3, check=False
        )
        if p.returncode != 0:
            return None
        value = p.stdout.strip().strip('"')
        if not value or "No Such" in value or "Timeout" in value:
            return None
        return value
    except (OSError, subprocess.TimeoutExpired):
        return None

def snmpwalk(oid):
    try:
        p = subprocess.run(
            ["snmpwalk", "-v2c", "-c", COMMUNITY, "-On", "-t", "1", "-r", "1", NAS_IP, oid],
            capture_output=True, text=True, timeout=5, check=False
        )
        if p.returncode != 0:
            return []
        rows = []
        for line in p.stdout.splitlines():
            if " = " not in line:
                continue
            name, value = line.split(" = ", 1)
            index_match = re.search(r"\.(\d+)$", name.strip())
            if not index_match:
                continue
            value = re.sub(r"^[A-Z][A-Za-z0-9 ]*:\s*", "", value.strip()).strip('"')
            rows.append((int(index_match.group(1)), value))
        return rows
    except (OSError, subprocess.TimeoutExpired):
        return []

def to_int(value):
    if value is None:
        return None
    match = re.search(r"-?\d+", str(value).replace(",", ""))
    try:
        return int(match.group(0)) if match else None
    except ValueError:
        return None

def get_storage_index():
    if DISK_STORAGE_INDEX.isdigit():
        return int(DISK_STORAGE_INDEX)
    descriptions = snmpwalk(OID_HR_STORAGE_DESCR)
    # Prefer Synology volume paths and mounted filesystem storage entries.
    for idx, descr in descriptions:
        low = descr.lower()
        if "volume" in low and ("volume1" in low or "/volume" in low):
            return idx
    for idx, descr in descriptions:
        low = descr.lower()
        if "ext4" in low or "btrfs" in low or "filesystem" in low:
            return idx
    return descriptions[0][0] if descriptions else None

def get_network_index():
    if NETWORK_INTERFACE_INDEX.isdigit():
        return int(NETWORK_INTERFACE_INDEX)
    interfaces = snmpwalk(OID_IF_DESCR)
    # Prefer a physical ethernet interface over loopback/virtual interfaces.
    preferred = []
    fallback = []
    for idx, descr in interfaces:
        low = descr.lower()
        if any(x in low for x in ("lo", "loopback", "docker", "veth", "br-", "sit")):
            continue
        fallback.append(idx)
        if any(x in low for x in ("eth", "bond", "lan", "en")):
            preferred.append(idx)
    if preferred:
        return preferred[0]
    if fallback:
        return fallback[0]
    return 1

def get_counter(index, hc_oid, regular_oid):
    # Prefer 64-bit counters where supported; fall back to 32-bit counters.
    value = to_int(snmpget(f"{hc_oid}.{index}"))
    if value is None:
        value = to_int(snmpget(f"{regular_oid}.{index}"))
    return value

def uptime_string(raw):
    if raw is None:
        return "N/A"
    # SNMP Timeticks are hundredths of a second.
    ticks = to_int(raw)
    if ticks is None:
        return raw
    seconds = ticks // 100
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, secs = divmod(rem, 60)
    return f"{days}:{hours:02d}:{minutes:02d}:{secs:02d}"

def load_previous():
    try:
        with open(OUTPUT_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}

def collect_stats():
    now = datetime.now().astimezone()
    timestamp = now.isoformat(timespec="seconds")
    current_time = now.strftime("%H:%M:%S")
    previous = load_previous()
    history = previous.get("history", [])
    if not isinstance(history, list):
        history = []

    uptime_raw = snmpget(OID_UPTIME)
    temp = to_int(snmpget(OID_SYS_TEMP))
    sys_status_raw = snmpget(OID_SYS_STATUS)
    cpu = to_int(snmpget(OID_CPU))
    ram = to_int(snmpget(OID_RAM))

    storage_idx = get_storage_index()
    disk_pct = None
    disk_total_bytes = None
    disk_used_bytes = None
    if storage_idx is not None:
        units = to_int(snmpget(f"{OID_HR_STORAGE_UNITS}.{storage_idx}"))
        size_units = to_int(snmpget(f"{OID_HR_STORAGE_SIZE}.{storage_idx}"))
        used_units = to_int(snmpget(f"{OID_HR_STORAGE_USED}.{storage_idx}"))
        if units is not None and size_units is not None and used_units is not None and size_units > 0:
            disk_total_bytes = units * size_units
            disk_used_bytes = units * used_units
            disk_pct = round(100.0 * used_units / size_units, 1)

    if_idx = get_network_index()
    net_in = get_counter(if_idx, OID_IF_HC_IN_OCTETS, OID_IF_IN_OCTETS) if if_idx else None
    net_out = get_counter(if_idx, OID_IF_HC_OUT_OCTETS, OID_IF_OUT_OCTETS) if if_idx else None

    prev = history[-1] if history else {}
    elapsed = None
    try:
        if prev.get("timestamp"):
            old_dt = datetime.fromisoformat(prev["timestamp"])
            elapsed = (now - old_dt).total_seconds()
    except (ValueError, TypeError):
        elapsed = None
    if not elapsed or elapsed <= 0:
        elapsed = float(POLL_INTERVAL)

    old_in = to_int(prev.get("net_in"))
    old_out = to_int(prev.get("net_out"))
    # A counter reset or interface change produces no rate for that sample.
    net_in_rate = max(0, net_in - old_in) / elapsed if net_in is not None and old_in is not None and net_in >= old_in else None
    net_out_rate = max(0, net_out - old_out) / elapsed if net_out is not None and old_out is not None and net_out >= old_out else None

    def sample_num(value):
        return value if value is not None else None

    entry = {
        "time": current_time,
        "timestamp": timestamp,
        "cpu": sample_num(cpu),
        "ram": sample_num(ram),
        "temperature": sample_num(temp),
        "disk": sample_num(disk_pct),
        "net_in": sample_num(net_in),
        "net_out": sample_num(net_out),
        "net_in_bytes_per_sec": round(net_in_rate, 2) if net_in_rate is not None else None,
        "net_out_bytes_per_sec": round(net_out_rate, 2) if net_out_rate is not None else None,
        "network_interface_index": if_idx,
        "disk_storage_index": storage_idx
    }

    history.append(entry)
    history = history[-MAX_HISTORY:]

    if sys_status_raw == "1":
        status = "online"
        alert = "Normal"
    elif sys_status_raw is None:
        status = "unknown"
        alert = "Unable to read Synology system status via SNMP"
    else:
        status = "warning"
        alert = "Check Synology DSM Status"

    data = {
        "status": status,
        "system_alert": alert,
        "last_updated": now.strftime("%Y-%m-%d %H:%M:%S"),
        "timestamp": timestamp,
        "uptime": uptime_string(uptime_raw),
        "temperature": f"{temp}°C" if temp is not None else "N/A",
        "cpu_usage": f"{cpu}%" if cpu is not None else "N/A",
        "ram_usage": f"{ram}%" if ram is not None else "N/A",
        "disk_usage_percent": f"{disk_pct}%" if disk_pct is not None else "N/A",
        "disk_total_bytes": disk_total_bytes,
        "disk_used_bytes": disk_used_bytes,
        "backup_status": BACKUP_STATUS_LABEL,
        "network_interface_index": if_idx,
        "disk_storage_index": storage_idx,
        "poll_interval_seconds": POLL_INTERVAL,
        "history_days": HISTORY_DAYS,
        "history_count": len(history),
        "history_max_samples": MAX_HISTORY,
        "history": history
    }

    out_dir = os.path.dirname(OUTPUT_FILE) or "."
    os.makedirs(out_dir, exist_ok=True)
    # Atomic replacement avoids Dashy reading a half-written JSON file.
    fd, temp_path = tempfile.mkstemp(prefix=".nas-status-", suffix=".json", dir=out_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_path, OUTPUT_FILE)
    finally:
        try:
            if os.path.exists(temp_path):
                os.unlink(temp_path)
        except OSError:
            pass

if __name__ == "__main__":
    collect_stats()
PYEOF

# ==============================================================================
# WRITE HTTP SERVER (SERVES JSON AND GRAPH PAGE ON SAME ORIGIN)
# ==============================================================================

cat > "$SERVER_PATH" <<'PYEOF'
#!/usr/bin/env python3
import os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.env")

def load_config():
    cfg = {}
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return cfg

cfg = load_config()
PORT = int(cfg.get("HTTP_PORT", "8088"))
JSON_PATH = cfg.get("NAS_STATS_OUTPUT", "/run/nas-stats/nas-status.json")

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=BASE_DIR, **kwargs)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/nas-status.json":
            self.serve_json()
        elif path in ("/", "/dashboard.html"):
            self.path = "/dashboard.html"
            super().do_GET()
        elif path == "/health":
            body = b'{"server":"online"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404, "Not found")

    def serve_json(self):
        try:
            with open(JSON_PATH, "rb") as f:
                body = f.read()
        except OSError:
            body = b'{"status":"starting","system_alert":"Waiting for first SNMP poll","history":[]}'
            self.send_response(503)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Avoid routine request logs to reduce disk writes/noise.
        return

ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF

# ==============================================================================
# WRITE SELF-CONTAINED DASHBOARD (NO EXTERNAL JS LIBRARIES)
# ==============================================================================

cat > "$DASHBOARD_PATH" <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NAS Monitor</title>
<style>
:root{color-scheme:dark;--bg:#0b1220;--panel:#111c2e;--line:#24334a;--text:#edf3fc;--muted:#9aabc2;--blue:#4da3ff;--green:#42d392;--yellow:#f5c451;--red:#ff6577}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:1500px;margin:auto;padding:20px}header{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:16px}
h1{font-size:22px;margin:0}h2{font-size:14px;margin:0 0 12px;color:#dce8f8}.sub{color:var(--muted);font-size:12px}
.actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}select,button{background:#17263b;border:1px solid #30435e;color:var(--text);padding:8px 10px;border-radius:8px}
.grid{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));gap:12px}.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px;min-width:0}.metric{grid-column:span 2}.metric .value{font-size:25px;font-weight:700;letter-spacing:-.5px;margin:7px 0 2px;overflow-wrap:anywhere}.label{color:var(--muted);font-size:12px}.status{display:inline-block;border-radius:999px;padding:4px 9px;background:#183d31;color:#8df0c1;font-size:12px}.warn{background:#4b2029;color:#ffb6bf}.chart{grid-column:span 6}.chart canvas{display:block;width:100%;height:220px}.chart-head{display:flex;justify-content:space-between;gap:10px;align-items:center}.chart-head .sub{white-space:nowrap}.wide{grid-column:span 12}.foot{color:var(--muted);font-size:11px;margin-top:14px}
@media(max-width:900px){.metric{grid-column:span 4}.chart{grid-column:span 12}}
@media(max-width:520px){main{padding:12px}.metric{grid-column:span 6}.metric .value{font-size:21px}.chart canvas{height:200px}}
</style>
</head>
<body>
<main>
<header>
  <div><h1>NAS Monitor</h1><div class="sub" id="updated">Waiting for NAS data…</div></div>
  <div class="actions"><label class="sub" for="range">History</label><select id="range"><option value="1">Last hour</option><option value="6">Last 6 hours</option><option value="24" selected>Last 24 hours</option><option value="72">Last 3 days</option></select><button id="refresh">Refresh</button></div>
</header>
<section class="grid">
  <div class="card metric"><div class="label">NAS status</div><div class="value" id="status">—</div><div class="sub" id="alert">—</div></div>
  <div class="card metric"><div class="label">CPU usage</div><div class="value" id="cpu">—</div><div class="sub">Current reading</div></div>
  <div class="card metric"><div class="label">RAM usage</div><div class="value" id="ram">—</div><div class="sub">Current reading</div></div>
  <div class="card metric"><div class="label">Temperature</div><div class="value" id="temp">—</div><div class="sub">System temperature</div></div>
  <div class="card metric"><div class="label">Disk usage</div><div class="value" id="disk">—</div><div class="sub" id="disk-detail">Volume usage</div></div>
  <div class="card metric"><div class="label">Uptime</div><div class="value" id="uptime">—</div><div class="sub">Days:hours:minutes:seconds</div></div>
  <div class="card chart"><div class="chart-head"><h2>CPU usage</h2><span class="sub">Percent</span></div><canvas id="cpuChart"></canvas></div>
  <div class="card chart"><div class="chart-head"><h2>RAM usage</h2><span class="sub">Percent</span></div><canvas id="ramChart"></canvas></div>
  <div class="card chart"><div class="chart-head"><h2>Network throughput</h2><span class="sub">Bytes/sec · incoming and outgoing</span></div><canvas id="netChart"></canvas></div>
  <div class="card chart"><div class="chart-head"><h2>Temperature</h2><span class="sub">°C</span></div><canvas id="tempChart"></canvas></div>
  <div class="card chart"><div class="chart-head"><h2>Disk usage history</h2><span class="sub">Percent</span></div><canvas id="diskChart"></canvas></div>
  <div class="card chart"><div class="chart-head"><h2>Network counters</h2><span class="sub">Cumulative bytes</span></div><canvas id="counterChart"></canvas></div>
  <div class="card wide"><h2>Backup status</h2><div class="value" id="backup">—</div><div class="sub">This is the configured status label, not an independently verified Restic job result.</div></div>
</section>
<div class="foot">Data is polled from the local NAS status JSON. Historical charts use the samples retained by the Pi collector. Network throughput is derived from counter deltas; the first sample after a reset may be unavailable.</div>
</main>
<script>
(function(){
"use strict";
const $=id=>document.getElementById(id);
let lastData=null;
const colors={blue:"#4da3ff",green:"#42d392",yellow:"#f5c451",red:"#ff6577",muted:"#9aabc2",grid:"#26364d"};
function parseTime(s){if(!s)return NaN;let d=new Date(s);return d.getTime();}
function selectedPoints(data){
 const h=Array.isArray(data.history)?data.history:[], hours=Number($("range").value)||24;
 const cutoff=Date.now()-hours*3600000;
 return h.filter(p=>{const t=parseTime(p.timestamp);return !Number.isFinite(t)||t>=cutoff;});
}
function niceBytes(v){if(v===null||v===undefined||!Number.isFinite(Number(v)))return "N/A";v=Number(v);const u=["B/s","KB/s","MB/s","GB/s"];let i=0;while(Math.abs(v)>=1000&&i<u.length-1){v/=1000;i++;}return v.toFixed(i===0?0:2)+" "+u[i];}
function shortBytes(v){if(v===null||v===undefined||!Number.isFinite(Number(v)))return "N/A";v=Number(v);const u=["B","KB","MB","GB","TB"];let i=0;while(Math.abs(v)>=1000&&i<u.length-1){v/=1000;i++;}return v.toFixed(i===0?0:1)+" "+u[i];}
function setText(id,value){$(id).textContent=(value===null||value===undefined||value==="")?"N/A":String(value);}
function drawChart(canvasId,series,opts){
 const canvas=$(canvasId), rect=canvas.getBoundingClientRect(), dpr=window.devicePixelRatio||1;
 const w=Math.max(260,rect.width),h=Math.max(160,rect.height||220);
 canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);
 const ctx=canvas.getContext("2d");ctx.scale(dpr,dpr);ctx.clearRect(0,0,w,h);
 const pad={l:42,r:12,t:14,b:28},pw=w-pad.l-pad.r,ph=h-pad.t-pad.b;
 const all=series.flatMap(s=>s.values.map(p=>p.y).filter(v=>v!==null&&Number.isFinite(Number(v))).map(Number));
 if(!all.length){ctx.fillStyle=colors.muted;ctx.font="12px system-ui";ctx.fillText("Waiting for samples…",pad.l,pad.t+20);return;}
 let min=opts.min!==undefined?opts.min:Math.min(0,...all),max=opts.max!==undefined?opts.max:Math.max(...all);
 if(max<=min)max=min+1;
 const xFor=i=>pad.l+(i/Math.max(1,Math.max(...series.map(s=>s.values.length))-1))*pw;
 const yFor=v=>pad.t+ph-(Number(v)-min)/(max-min)*ph;
 ctx.font="10px system-ui";ctx.lineWidth=1;ctx.strokeStyle=colors.grid;ctx.fillStyle=colors.muted;
 for(let i=0;i<=4;i++){let y=pad.t+ph*i/4;ctx.beginPath();ctx.moveTo(pad.l,y);ctx.lineTo(w-pad.r,y);ctx.stroke();let val=max-(max-min)*i/4;ctx.fillText(opts.formatY?opts.formatY(val):String(Math.round(val*10)/10),2,y+3);}
 const sampleTimes=series[0].values;
 [0,.5,1].forEach(frac=>{let idx=Math.round((sampleTimes.length-1)*frac),p=sampleTimes[idx];if(!p)return;let label=p.timestamp?new Date(p.timestamp).toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"}):p.time||"";ctx.fillText(label,Math.max(pad.l,Math.min(w-pad.r-42,pad.l+pw*frac-18)),h-7);});
 series.forEach(s=>{
   ctx.strokeStyle=s.color;ctx.lineWidth=2;ctx.beginPath();let started=false;
   s.values.forEach((p,i)=>{if(p.y===null||p.y===undefined||!Number.isFinite(Number(p.y))){started=false;return;}let x=xFor(i),y=yFor(p.y);if(!started){ctx.moveTo(x,y);started=true;}else ctx.lineTo(x,y);});ctx.stroke();
 });
 let legendX=pad.l;series.forEach(s=>{ctx.fillStyle=s.color;ctx.fillRect(legendX,pad.t-8,9,3);ctx.fillStyle=colors.muted;ctx.fillText(s.name,legendX+13,pad.t-4);legendX+=ctx.measureText(s.name).width+28;});
 canvas.onmousemove=e=>{
   const r=canvas.getBoundingClientRect(),x=e.clientX-r.left;
   if(x<pad.l||x>w-pad.r){canvas.title="";return;}
   const idx=Math.round((x-pad.l)/pw*Math.max(1,Math.max(...series.map(s=>s.values.length))-1));
   const details=series.map(s=>{const p=s.values[idx];return s.name+": "+(p&&p.y!==null&&p.y!==undefined?(opts.formatTip?opts.formatTip(p.y):p.y):"N/A");});
   const p=sampleTimes[idx];canvas.title=(p?(p.timestamp?new Date(p.timestamp).toLocaleString():p.time||""):"")+ "\n"+details.join("\n");
 };
}
function drawAll(data){
 const points=selectedPoints(data);
 const map=(key)=>points.map(p=>({y:p[key]===undefined?null:p[key],timestamp:p.timestamp,time:p.time}));
 drawChart("cpuChart",[{name:"CPU",color:colors.blue,values:map("cpu")}],{min:0,max:100,formatY:v=>Math.round(v)+"%",formatTip:v=>v+"%"});
 drawChart("ramChart",[{name:"RAM",color:colors.green,values:map("ram")}],{min:0,max:100,formatY:v=>Math.round(v)+"%",formatTip:v=>v+"%"});
 const incoming=points.map(p=>({y:p.net_in_bytes_per_sec,timestamp:p.timestamp,time:p.time}));
 const outgoing=points.map(p=>({y:p.net_out_bytes_per_sec,timestamp:p.timestamp,time:p.time}));
 drawChart("netChart",[{name:"In",color:colors.blue,values:incoming},{name:"Out",color:colors.yellow,values:outgoing}],{min:0,formatY:v=>shortBytes(v),formatTip:v=>niceBytes(v)});
 drawChart("tempChart",[{name:"Temp",color:colors.red,values:map("temperature")}],{min:0,formatY:v=>Math.round(v)+"°",formatTip:v=>v+"°C"});
 drawChart("diskChart",[{name:"Disk",color:colors.yellow,values:map("disk")}],{min:0,max:100,formatY:v=>Math.round(v)+"%",formatTip:v=>v+"%"});
 drawChart("counterChart",[{name:"In",color:colors.blue,values:map("net_in")},{name:"Out",color:colors.green,values:map("net_out")}],{min:0,formatY:v=>shortBytes(v),formatTip:v=>shortBytes(v)});
}
async function refresh(){
 try{
  const response=await fetch("/nas-status.json?ts="+Date.now(),{cache:"no-store"});
  if(!response.ok)throw new Error("HTTP "+response.status);
  const data=await response.json();lastData=data;
  setText("status",data.status);setText("alert",data.system_alert);
  $("status").className="value"+(data.status!=="online"?" warn":"");
  setText("cpu",data.cpu_usage);setText("ram",data.ram_usage);setText("temp",data.temperature);
  setText("disk",data.disk_usage_percent);setText("uptime",data.uptime);setText("backup",data.backup_status);
  if(data.disk_used_bytes!==null&&data.disk_used_bytes!==undefined&&data.disk_total_bytes!==null&&data.disk_total_bytes!==undefined){
    $("disk-detail").textContent=shortBytes(data.disk_used_bytes)+" used / "+shortBytes(data.disk_total_bytes);
  }
  setText("updated","Updated "+(data.last_updated||"unknown")+" · "+(data.history_count||0)+" samples");
  drawAll(data);
 }catch(e){setText("updated","Unable to fetch NAS JSON: "+e.message);}
}
$("refresh").addEventListener("click",refresh);
$("range").addEventListener("change",()=>{if(lastData)drawAll(lastData);});
window.addEventListener("resize",()=>{if(lastData)drawAll(lastData);});
refresh();setInterval(refresh,15000);
})();
</script>
</body>
</html>
HTMLEOF

chmod +x "$SCRIPT_PATH" "$SERVER_PATH"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$SCRIPT_PATH" "$SERVER_PATH" "$DASHBOARD_PATH"

# ==============================================================================
# PREPARE RAM DIRECTORY & SYSTEMD HTTP SERVICE
# ==============================================================================

sudo mkdir -p "$RAM_DIR"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$RAM_DIR"
sudo chmod 755 "$RAM_DIR"

# Poll once before starting the web server; failure is non-fatal, server reports startup.
python3 "$SCRIPT_PATH" || echo "WARNING: Initial SNMP collection failed; scheduled collection can retry."

# Ensure existing cron entry is not duplicated; preserve unrelated entries.
HTTP_PORT="$(sed -n 's/^HTTP_PORT="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CONFIG_FILE" | tail -n1)"
HTTP_PORT="${HTTP_PORT:-8088}"
if ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || (( HTTP_PORT < 1024 || HTTP_PORT > 65535 )); then
    HTTP_PORT="8088"
fi

echo "Configuring HTTP server on port $HTTP_PORT..."

sudo tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=PiTweaks NAS Stats HTTP Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=$CURRENT_USER
Group=$CURRENT_USER
RuntimeDirectory=nas-stats
RuntimeDirectoryMode=0755
Environment=PYTHONUNBUFFERED=1
ExecStartPre=/bin/mkdir -p $RAM_DIR
ExecStart=/usr/bin/python3 $SERVER_PATH
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF

# RuntimeDirectory is owned by service user, so output file remains writable.
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME.service"
sudo systemctl restart "$SERVICE_NAME.service"

# ==============================================================================
# OPTIONAL CRON COLLECTION
# ==============================================================================

POLL_INTERVAL="$(sed -n 's/^POLL_INTERVAL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CONFIG_FILE" | tail -n1)"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || (( POLL_INTERVAL < 30 )); then POLL_INTERVAL=60; fi

if whiptail --backtitle "PiTweaks | NAS Monitor" \
    --title "Automatic Collection" \
    --yesno "Configure automatic NAS polling?\n\nThe current scheduler uses cron. For the default 60-second interval it collects once per minute. The graph page refreshes every 15 seconds, but new history points appear at the collection interval." 12 76; then
    CURRENT_CRON="$(crontab -l 2>/dev/null || true)"
    CLEAN_CRON="$(printf '%s\n' "$CURRENT_CRON" | grep -Fv "$SCRIPT_PATH" | grep -Fv "$CRON_MARKER" || true)"
    if (( POLL_INTERVAL < 60 )); then
        # Cron cannot reliably schedule arbitrary sub-minute intervals.
        whiptail --title "Cron Interval Note" --msgbox "Cron runs at minute granularity. Your configured poll interval is $POLL_INTERVAL seconds, so cron will use once per minute. Set the config interval to 60 seconds or more for matching timestamps." 9 76
    fi
    (printf '%s\n' "$CLEAN_CRON"; echo "$CRON_MARKER"; echo "* * * * * /usr/bin/python3 $SCRIPT_PATH >/dev/null 2>&1") | crontab -
    echo "Cron polling configured (once per minute)."
else
    echo "Automatic cron polling was not changed."
fi

# ==============================================================================
# FINISH
# ==============================================================================

PI_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PI_IP="${PI_IP:-<YOUR_PI_IP>}"

echo
echo "============================================================"
echo " NAS Monitor setup complete"
echo "============================================================"
echo "Script:       $SCRIPT_PATH"
echo "Config:       $CONFIG_FILE"
echo "JSON endpoint: http://$PI_IP:$HTTP_PORT/nas-status.json"
echo "Graph page:    http://$PI_IP:$HTTP_PORT/dashboard.html"
echo "Health check:  http://$PI_IP:$HTTP_PORT/health"
echo "History:       configured for up to ${HISTORY_DAYS:-3} day(s), bounded by RAM"
echo
echo "Dashy iframe widget:"
echo "  - type: iframe"
echo "    options:"
echo "      url: http://$PI_IP:$HTTP_PORT/dashboard.html"
echo "      frameHeight: 900"
echo
echo "Note: SNMP must be enabled on the Synology and the configured community must match."
echo "The Restic label is informational unless your existing script updates it from real backup results."
