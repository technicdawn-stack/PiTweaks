#!/bin/bash

# Description: RAM Drop v1.4.0 All-in-One Self-Contained Deployment & Management Console
# PERSISTENT: TRUE
# Category: Webpages

# Dynamically detect the real user even if run via sudo
if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$(whoami)"
fi

USER_HOME="$(eval echo ~$CURRENT_USER)"
APP_DIR="$USER_HOME/ram-drop"
PYTHON_APP_PATH="$APP_DIR/app.py"
TEMPLATE_DIR="$APP_DIR/templates"
TEMPLATE_PATH="$TEMPLATE_DIR/index.html"
SERVICE_PATH="/etc/systemd/system/ramdrop.service"
PORT=8083

# Automatic Dependency Detection & Installation
echo "[*] Checking Python3 and pip environment..."
if ! command -v python3 &>/dev/null; then
    echo "[!] python3 could not be found. Installing python3..."
    sudo apt-get update && sudo apt-get install -y python3 python3-pip whiptail
elif ! command -v whiptail &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y whiptail
fi

if ! python3 -c "import flask, psutil" &>/dev/null; then
    echo "[!] Missing required Python modules (Flask or psutil). Installing dependencies..."
    python3 -m pip install --upgrade pip
    python3 -m pip install flask psutil
fi

# Check for existing installation and configuration settings
CONFIG_RAM="1024"
CONFIG_PAGE_PASS=""
CONFIG_SETTINGS_PASS=""
KEEP_OLD_SETTINGS=false

if [ -f "$PYTHON_APP_PATH" ] && command -v whiptail &>/dev/null; then
    if (whiptail --title "Existing Installation Found" --yesno "An existing RAM Drop installation was detected. Would you like to keep your previous settings?" 10 60); then
        EXTRACTED_RAM=$(grep -oP '"max_ram_mb": \K[0-9]+' "$PYTHON_APP_PATH" 2>/dev/null)
        [ -n "$EXTRACTED_RAM" ] && CONFIG_RAM="$EXTRACTED_RAM"
        
        EXTRACTED_PAGE_PASS=$(grep -oP '"page_password": "\K[^"]*' "$PYTHON_APP_PATH" 2>/dev/null)
        [ -n "$EXTRACTED_PAGE_PASS" ] && CONFIG_PAGE_PASS="$EXTRACTED_PAGE_PASS"

        EXTRACTED_SETT_PASS=$(grep -oP '"settings_password": "\K[^"]*' "$PYTHON_APP_PATH" 2>/dev/null)
        [ -n "$EXTRACTED_SETT_PASS" ] && CONFIG_SETTINGS_PASS="$EXTRACTED_SETT_PASS"
        
        KEEP_OLD_SETTINGS=true
    fi
fi

if [ "$KEEP_OLD_SETTINGS" != "true" ] && command -v whiptail &>/dev/null; then
    CONFIG_RAM=$(whiptail --title "RAM Drop Initial Setup" --inputbox "Enter Max RAM Limit (MB):" 10 50 "1024" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && CONFIG_RAM="1024"

    CONFIG_PAGE_PASS=$(whiptail --title "RAM Drop Initial Setup" --passwordbox "Enter Main Page / Upload Password (leave blank for none):" 10 50 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && CONFIG_PAGE_PASS=""

    CONFIG_SETTINGS_PASS=$(whiptail --title "RAM Drop Initial Setup" --passwordbox "Enter Settings Tab Password (leave blank for none):" 10 50 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && CONFIG_SETTINGS_PASS=""
fi

mkdir -p "$TEMPLATE_DIR"

cat << EOF > "$PYTHON_APP_PATH"
import os
import time
import random
import string
import psutil
from flask import Flask, render_template, request, jsonify, send_from_directory, session, redirect, url_for

app = Flask(__name__)
app.secret_key = ''.join(random.choices(string.ascii_letters + string.digits, k=32))

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
UPLOAD_FOLDER = os.path.join(BASE_DIR, 'uploads')
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
app.config['MAX_CONTENT_LENGTH'] = 100 * 1024 * 1024

file_metadata = {}
LOG_RETENTION_HOURS = 24

app_settings = {
    "max_ram_mb": $CONFIG_RAM,
    "page_password": "$CONFIG_PAGE_PASS",
    "settings_password": "$CONFIG_SETTINGS_PASS",
    "blur_filename": False,
    "blur_extension": False,
    "mute_style": "asterisk"
}

def generate_masked_name(original_filename, mode="asterisk", blur_ext=False):
    root, ext = os.path.splitext(original_filename)
    if mode == "random":
        name = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))
    else:
        name = "**********"
    
    if blur_ext:
        ext = ".***"
    return f"{name}{ext}"

def get_current_app_ram_usage():
    total_bytes = 0
    for meta in file_metadata.values():
        if meta.get('status') in ['ready', 'expiring_soon']:
            file_path = os.path.join(app.config['UPLOAD_FOLDER'], meta['stored_name'])
            if os.path.exists(file_path):
                total_bytes += os.path.getsize(file_path)
    return total_bytes / (1024 * 1024)

@app.route('/login', methods=['GET', 'POST'])
def login():
    if not app_settings["page_password"]:
        return redirect(url_for('index'))
    if request.method == 'POST':
        if request.form.get('password') == app_settings["page_password"]:
            session['page_authenticated'] = True
            return redirect(url_for('index'))
        return render_template('login.html', error="Incorrect network password", title="RAM Drop - Network Login")
    return render_template('login.html', error=None, title="RAM Drop - Network Login")

@app.route('/settings-login', methods=['GET', 'POST'])
def settings_login():
    if not app_settings["settings_password"]:
        return redirect(url_for('index'))
    if request.method == 'POST':
        if request.form.get('password') == app_settings["settings_password"]:
            session['settings_authenticated'] = True
            return jsonify({'success': True})
        return jsonify({'success': False, 'error': 'Incorrect password'}), 401
    return render_template('login.html', error=None, title="RAM Drop - Settings Login")

@app.route('/api/verify-settings-auth', methods=['GET'])
def verify_settings_auth():
    if not app_settings["settings_password"] or session.get('settings_authenticated'):
        return jsonify({'authenticated': True})
    return jsonify({'authenticated': False})

@app.route('/')
def index():
    if app_settings["page_password"] and not session.get('page_authenticated'):
        return redirect(url_for('login'))
    return render_template('index.html')

@app.route('/api/settings', methods=['GET', 'POST'])
def handle_settings():
    global app_settings
    if request.method == 'POST':
        if app_settings["settings_password"] and not session.get('settings_authenticated'):
            return jsonify({'success': False, 'error': 'Unauthorized'}), 401
            
        data = request.json
        if 'max_ram_mb' in data:
            app_settings['max_ram_mb'] = int(data['max_ram_mb'])
        if 'page_password' in data:
            app_settings['page_password'] = data['page_password']
        if 'settings_password' in data:
            app_settings['settings_password'] = data['settings_password']
        if 'blur_filename' in data:
            app_settings['blur_filename'] = bool(data['blur_filename'])
        if 'blur_extension' in data:
            app_settings['blur_extension'] = bool(data['blur_extension'])
        if 'mute_style' in data:
            app_settings['mute_style'] = data['mute_style']
        return jsonify({'success': True, 'settings': app_settings})
        
    safe_settings = app_settings.copy()
    return jsonify(safe_settings)

@app.route('/api/stats', methods=['GET'])
def get_stats():
    if app_settings["page_password"] and not session.get('page_authenticated'):
        return jsonify({'error': 'Unauthorized'}), 401
    cpu_usage = psutil.cpu_percent(interval=None)
    ram = psutil.virtual_memory()
    app_ram_mb = get_current_app_ram_usage()
    return jsonify({
        'cpu': cpu_usage,
        'ram_percent': ram.percent,
        'ram_used_mb': round(ram.used / (1024 * 1024), 2),
        'ram_total_mb': round(ram.total / (1024 * 1024), 2),
        'app_ram_mb': round(app_ram_mb, 2),
        'max_ram_limit': app_settings['max_ram_mb']
    })

@app.route('/api/files', methods=['GET'])
def list_files():
    if app_settings["page_password"] and not session.get('page_authenticated'):
        return jsonify({'error': 'Unauthorized'}), 401
        
    current_time = time.time()
    active_files = []
    cutoff_time = current_time - (LOG_RETENTION_HOURS * 3600)
    
    for file_id, meta in list(file_metadata.items()):
        if meta['timestamp'] < cutoff_time:
            del file_metadata[file_id]
            continue

        file_path = os.path.join(app.config['UPLOAD_FOLDER'], meta['stored_name'])
        time_elapsed = current_time - meta['timestamp']
        time_remaining = meta['ttl'] - time_elapsed
        
        if meta.get('status') == 'deleted':
            state = 'deleted'
        elif not os.path.exists(file_path):
            state = 'reclaimed'
        elif time_remaining <= 0:
            state = 'expired'
        elif time_remaining < 3600:
            state = 'expiring_soon'
        else:
            state = 'ready'
            
        active_files.append({
            'id': file_id,
            'display_name': meta['display_name'],
            'size': meta['size'],
            'size_bytes': meta.get('size_bytes', 0),
            'timestamp': meta['timestamp'],
            'time': time.strftime('%H:%M:%S', time.localtime(meta['timestamp'])),
            'date': time.strftime('%Y-%m-%d', time.localtime(meta['timestamp'])),
            'status': state,
            'remaining_seconds': max(0, int(time_remaining)) if state == 'expiring_soon' else 0
        })
    
    active_files.sort(key=lambda x: x['timestamp'], reverse=True)
    return jsonify(active_files)

@app.route('/api/check-capacity', methods=['POST'])
def check_capacity():
    if app_settings["page_password"] and not session.get('page_authenticated'):
        return jsonify({'error': 'Unauthorized'}), 401
        
    data = request.json
    incoming_size = data.get('size_bytes', 0)
    current_usage = get_current_app_ram_usage() * 1024 * 1024
    max_limit = app_settings['max_ram_mb'] * 1024 * 1024
    
    if current_usage + incoming_size <= max_limit:
        return jsonify({'needs_deletion': False})
        
    # Determine files to delete oldest first
    active = [(fid, m) for fid, m in file_metadata.items() if m.get('status') in ['ready', 'expiring_soon']]
    active.sort(key=lambda x: x[1]['timestamp']) # oldest first
    
    freed = 0
    files_to_delete = []
    target_needed = (current_usage + incoming_size) - max_limit
    
    for fid, m in active:
        fpath = os.path.join(app.config['UPLOAD_FOLDER'], m['stored_name'])
        if os.path.exists(fpath):
            fsize = os.path.getsize(fpath)
            files_to_delete.append({'id': fid, 'name': m['display_name']})
            freed += fsize
            if current_usage - freed + incoming_size <= max_limit:
                break
                
    return jsonify({
        'needs_deletion': True,
        'files_to_delete': files_to_delete
    })

@app.route('/api/upload', methods=['POST'])
def upload_file():
    if app_settings["page_password"] and not session.get('page_authenticated'):
        return jsonify({'error': 'Unauthorized'}), 401
        
    if 'file' not in request.files:
        return jsonify({'error': 'No file part'}), 400
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'No selected file'}), 400
        
    ttl_hours = int(request.form.get('ttl', 4))
    force_cleanup = request.form.get('force_cleanup', 'false') == 'true'
    
    file_path_temp = os.path.join(app.config['UPLOAD_FOLDER'], f"temp_{file.filename}")
    file.save(file_path_temp)
    file_size = os.path.getsize(file_path_temp)
    os.remove(file_path_temp)
    
    current_usage = get_current_app_ram_usage() * 1024 * 1024
    max_limit = app_settings['max_ram_mb'] * 1024 * 1024
    
    if current_usage + file_size > max_limit and not force_cleanup:
        return jsonify({'error': 'Capacity exceeded', 'requires_confirmation': True}), 400
        
    if force_cleanup:
        active = [(fid, m) for fid, m in file_metadata.items() if m.get('status') in ['ready', 'expiring_soon']]
        active.sort(key=lambda x: x[1]['timestamp'])
        freed = 0
        for fid, m in active:
            fpath = os.path.join(app.config['UPLOAD_FOLDER'], m['stored_name'])
            if os.path.exists(fpath):
                fsize = os.path.getsize(fpath)
                os.remove(fpath)
                m['status'] = 'deleted'
                freed += fsize
                if current_usage - freed + file_size <= max_limit:
                    break

    display_name = file.filename
    if app_settings['blur_filename']:
        display_name = generate_masked_name(display_name, app_settings['mute_style'], app_settings['blur_extension'])
        
    file_id = ''.join(random.choices(string.ascii_lowercase + string.digits, k=10))
    stored_name = f"{file_id}_{file.filename}"
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], stored_name)
    
    file.stream.seek(0)
    file.save(file_path)
    
    file_metadata[file_id] = {
        'stored_name': stored_name,
        'display_name': display_name,
        'size': f"{round(file_size / 1024, 1)} KB" if file_size < 1024*1024 else f"{round(file_size / (1024*1024), 1)} MB",
        'size_bytes': file_size,
        'timestamp': time.time(),
        'ttl': ttl_hours * 3600,
        'status': 'ready'
    }
    
    return jsonify({'success': True, 'id': file_id})

@app.route('/api/download/<file_id>', methods=['GET'])
def download_file(file_id):
    if app_settings["page_password"] and not session.get('page_authenticated'):
        return redirect(url_for('login'))
    if file_id not in file_metadata:
        return "File not found", 404
    meta = file_metadata[file_id]
    return send_from_directory(app.config['UPLOAD_FOLDER'], meta['stored_name'], as_attachment=True, download_name=meta['display_name'])

@app.route('/api/delete', methods=['POST'])
def delete_files():
    if app_settings["page_password"] and not session.get('page_authenticated'):
        return jsonify({'error': 'Unauthorized'}), 401
        
    data = request.json
    file_ids = data.get('ids', [])
    for file_id in file_ids:
        if file_id in file_metadata:
            meta = file_metadata[file_id]
            file_path = os.path.join(app.config['UPLOAD_FOLDER'], meta['stored_name'])
            if os.path.exists(file_path):
                os.remove(file_path)
            meta['status'] = 'deleted'
    return jsonify({'success': True})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8083)
EOF

cat << 'EOF' > "$TEMPLATE_PATH"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RAM DROP — Secure Local Volatile File Drop</title>
    <style>
        :root {
            --bg-color: #030712;
            --surface-color: #0f172a;
            --surface-border: #1e293b;
            --accent: #38bdf8;
            --accent-hover: #0ea5e9;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --danger: #f43f5e;
            --success: #22c55e;
            --warning: #eab308;
            --amber-pulse: #f97316;
            --reclaimed-blue: #64748b;
        }

        body {
            font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-main);
            margin: 0;
            padding: 40px 20px;
            display: flex;
            justify-content: center;
        }

        .wrapper { width: 100%; max-width: 960px; position: relative; }
        header { text-align: center; margin-bottom: 30px; position: relative; }
        
        .top-left-controls { position: absolute; top: 0; left: 0; display: flex; gap: 8px; z-index: 10; }
        .top-right-controls { position: absolute; top: 0; right: 0; display: flex; gap: 8px; z-index: 10; }

        .icon-btn {
            background-color: var(--surface-color); border: 1px solid var(--surface-border);
            color: var(--text-main); padding: 8px 12px; border-radius: 8px; cursor: pointer;
            font-size: 0.9rem; display: flex; align-items: center; gap: 6px; transition: background 0.2s;
        }
        .icon-btn:hover { background-color: var(--surface-border); }

        .dropdown-menu {
            display: none; position: absolute; top: 42px; left: 0; background-color: var(--surface-color);
            border: 1px solid var(--surface-border); border-radius: 8px; padding: 12px; width: 200px;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.5); z-index: 100; font-size: 0.85rem;
        }
        .dropdown-menu.show { display: block; }
        .dropdown-item { margin-bottom: 8px; display: flex; flex-direction: column; gap: 4px; }

        h1 {
            font-size: 2.25rem; font-weight: 800; letter-spacing: -0.025em; margin: 0 0 8px 0;
            background: linear-gradient(135deg, #38bdf8 0%, #818cf8 100%);
            -webkit-background-clip: text; -webkit-text-fill-color: transparent;
        }
        p.subtitle { color: var(--text-muted); font-size: 0.95rem; margin: 0; }

        .telemetry-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px; margin-bottom: 16px; }
        .telemetry-card { background-color: var(--surface-color); border: 1px solid var(--surface-border); padding: 16px 20px; border-radius: 12px; }
        .telemetry-label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); margin-bottom: 6px; }
        .telemetry-value { font-size: 1.25rem; font-weight: 700; color: var(--text-main); }

        /* App RAM Capacity Progress Bar Card */
        .capacity-card { background-color: var(--surface-color); border: 1px solid var(--surface-border); padding: 16px 20px; border-radius: 12px; margin-bottom: 24px; }
        .capacity-header { display: flex; justify-content: space-between; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); margin-bottom: 8px; }
        .capacity-bar-track { width: 100%; background: var(--surface-border); border-radius: 6px; height: 10px; overflow: hidden; position: relative; cursor: pointer; }
        .capacity-bar-fill { height: 100%; width: 0%; transition: width 0.3s ease, background-color 0.3s ease; }
        .capacity-bar-track[data-tooltip]:hover::after {
            content: attr(data-tooltip); position: absolute; bottom: 16px; left: 50%; transform: translateX(-50%);
            background: #020617; color: #fff; padding: 4px 8px; font-size: 0.75rem; border-radius: 6px;
            white-space: nowrap; border: 1px solid var(--surface-border); z-index: 50; pointer-events: none;
        }

        .dropzone {
            background-color: var(--surface-color); border: 2px dashed var(--surface-border);
            border-radius: 16px; padding: 48px 24px; text-align: center; cursor: pointer;
            transition: all 0.25s ease; position: relative; margin-bottom: 24px;
        }
        .dropzone:hover, .dropzone.dragover { border-color: var(--accent); background-color: rgba(56, 189, 248, 0.03); transform: translateY(-2px); }
        .dropzone-icon { font-size: 3rem; margin-bottom: 12px; }
        .dropzone-text { font-size: 1.1rem; font-weight: 600; margin-bottom: 6px; }
        .dropzone-sub { font-size: 0.85rem; color: var(--text-muted); }

        .progress-container { width: 100%; background: var(--surface-border); border-radius: 8px; height: 6px; margin-top: 20px; overflow: hidden; display: none; }
        .progress-bar { width: 0%; height: 100%; background: var(--accent); transition: width 0.1s linear; }

        .controls-panel {
            background-color: var(--surface-color); border: 1px solid var(--surface-border);
            border-radius: 12px; padding: 20px; display: flex; flex-wrap: wrap; gap: 20px; align-items: center; justify-content: space-between; margin-bottom: 24px;
        }
        .control-group { display: flex; align-items: center; gap: 10px; font-size: 0.9rem; }
        select { background-color: var(--bg-color); border: 1px solid var(--surface-border); color: var(--text-main); padding: 8px 12px; border-radius: 8px; font-size: 0.9rem; outline: none; cursor: pointer; }
        input[type="checkbox"], input[type="radio"] { accent-color: var(--accent); cursor: pointer; }

        .toolbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
        .btn { background-color: var(--accent); color: #030712; border: none; padding: 10px 18px; border-radius: 8px; font-weight: 600; font-size: 0.9rem; cursor: pointer; transition: background-color 0.2s; }
        .btn:hover { background-color: var(--accent-hover); }
        .btn-danger { background-color: rgba(244, 63, 94, 0.1); color: var(--danger); border: 1px solid rgba(244, 63, 94, 0.2); }
        .btn-danger:hover { background-color: var(--danger); color: white; }
        .btn-clear { background: transparent; color: var(--text-muted); border: 1px solid var(--surface-border); }
        .btn-clear:hover { color: var(--text-main); background: var(--surface-border); }

        .table-container { background-color: var(--surface-color); border: 1px solid var(--surface-border); border-radius: 12px; overflow: hidden; }
        table { width: 100%; border-collapse: collapse; text-align: left; font-size: 0.9rem; }
        th, td { padding: 14px 18px; border-bottom: 1px solid var(--surface-border); }
        th { background-color: rgba(15, 23, 42, 0.6); font-weight: 600; color: var(--text-muted); font-size: 0.75rem; text-transform: uppercase; }
        tr:last-child td { border-bottom: none; }
        a.file-link { color: var(--accent); text-decoration: none; font-weight: 500; }
        a.file-link:hover { text-decoration: underline; }

        /* Highlight Row Animation */
        tr.highlight-target {
            animation: highlightPulse 2s ease-in-out infinite;
        }
        @keyframes highlightPulse {
            0% { background-color: rgba(56, 189, 248, 0.2); }
            50% { background-color: rgba(56, 189, 248, 0.05); }
            100% { background-color: rgba(56, 189, 248, 0.2); }
        }

        .status-badge { display: inline-flex; align-items: center; gap: 8px; font-size: 0.85rem; font-weight: 500; }
        .status-dot { width: 10px; height: 10px; border-radius: 50%; position: relative; cursor: pointer; }
        .status-dot[data-tooltip]:hover::after {
            content: attr(data-tooltip); position: absolute; bottom: 18px; left: 50%; transform: translateX(-50%);
            background: #020617; color: #fff; padding: 6px 10px; font-size: 0.75rem; border-radius: 6px;
            white-space: nowrap; border: 1px solid var(--surface-border); z-index: 50; pointer-events: none;
        }
        .dot-ready { background-color: var(--success); }
        .dot-expiring { background-color: var(--amber-pulse); }
        .dot-expired { background-color: var(--warning); }
        .dot-reclaimed { background-color: var(--reclaimed-blue); }
        .dot-deleted { background-color: var(--danger); }

        .empty-state { text-align: center; padding: 40px; color: var(--text-muted); font-style: italic; }

        /* General Modal Overlay */
        .modal-overlay {
            display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%;
            background: rgba(3, 7, 18, 0.8); z-index: 1000; justify-content: center; align-items: center;
        }
        .modal-content {
            background-color: var(--surface-color); border: 1px solid var(--surface-border);
            padding: 30px; border-radius: 16px; width: 100%; max-width: 450px; display: flex; flex-direction: column; gap: 16px;
        }
        .modal-header { font-size: 1.25rem; font-weight: 700; margin-bottom: 4px; }
        .modal-input { background: var(--bg-color); border: 1px solid var(--surface-border); color: var(--text-main); padding: 10px 14px; border-radius: 8px; font-size: 0.95rem; width: 100%; box-sizing: border-box; }

        /* Custom Warning Alert Modal */
        .alert-modal-box {
            background-color: var(--surface-color); border: 1px solid var(--surface-border);
            padding: 24px; border-radius: 16px; width: 100%; max-width: 400px; text-align: center;
            display: flex; flex-direction: column; align-items: center; gap: 16px; box-shadow: 0 20px 25px -5px rgba(0,0,0,0.5);
        }
        .warning-icon-svg { width: 48px; height: 48px; stroke: var(--warning); fill: none; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
        .alert-text { font-size: 0.95rem; color: var(--text-main); line-height: 1.4; margin: 0; }
        .alert-actions { display: flex; justify-content: space-between; width: 100%; margin-top: 8px; align-items: center; }
    </style>
</head>
<body>
    <div class="wrapper">
        <header>
            <div class="top-left-controls">
                <div style="position: relative;">
                    <button class="icon-btn" id="refreshDropdownBtn" title="Refresh Controls">
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.65-5.65"/></svg>
                        <span style="font-size: 0.75rem;">▼</span>
                    </button>
                    <div class="dropdown-menu" id="refreshDropdown">
                        <div class="dropdown-item">
                            <label><input type="checkbox" id="autoRefreshToggle"> Auto-Refresh</label>
                        </div>
                        <div class="dropdown-item">
                            <label style="color: var(--text-muted); font-size: 0.75rem;">Interval (seconds):</label>
                            <select id="refreshInterval" style="width: 100%;">
                                <option value="2">2s</option>
                                <option value="5" selected>5s</option>
                                <option value="10">10s</option>
                                <option value="30">30s</option>
                            </select>
                        </div>
                        <div style="margin-top: 4px;">
                            <button class="btn" style="width: 100%; padding: 6px; font-size: 0.8rem;" id="manualRefreshBtn">Refresh Now</button>
                        </div>
                    </div>
                </div>
            </div>

            <div class="top-right-controls">
                <button class="icon-btn" id="settingsBtn" title="Settings">⚙️ Settings</button>
            </div>

            <h1 id="scrambleTitle">RAM DROP</h1>
            <p class="subtitle">Zero-Wear Volatile Local File Transfer Hub</p>
        </header>

        <div class="telemetry-grid">
            <div class="telemetry-card">
                <div class="telemetry-label">CPU Utilization</div>
                <div class="telemetry-value" id="cpu-val">0.0%</div>
            </div>
            <div class="telemetry-card">
                <div class="telemetry-label">System RAM Total</div>
                <div class="telemetry-value" id="ram-val">0.0 MB</div>
            </div>
        </div>

        <!-- App Capacity Progress Bar Card -->
        <div class="capacity-card">
            <div class="capacity-header">
                <span>App RAM Usage Allocation</span>
                <span id="capacity-text">0.0 / 0.0 MB</span>
            </div>
            <div class="capacity-bar-track" id="capacityTrack" data-tooltip="0.0 MB / 0.0 MB (0.0%)">
                <div class="capacity-bar-fill" id="capacityFill"></div>
            </div>
        </div>

        <div class="dropzone" id="dropzone">
            <div class="dropzone-icon">📥</div>
            <div class="dropzone-text">Drag & Drop files here, or click to browse</div>
            <div class="dropzone-sub">Files are handled entirely in volatile system RAM</div>
            <input type="file" id="fileInput" style="display: none;">
            <div class="progress-container" id="progressContainer">
                <div class="progress-bar" id="progressBar"></div>
            </div>
        </div>

        <div class="controls-panel">
            <div class="control-group">
                <label for="ttlSelect">Retention Lifetime:</label>
                <select id="ttlSelect">
                    <option value="1">1 Hour</option>
                    <option value="4" selected>4 Hours</option>
                    <option value="12">12 Hours</option>
                    <option value="24">24 Hours</option>
                </select>
            </div>
            <div class="control-group" style="color: var(--text-muted); font-size: 0.85rem;">
                Privacy blur & settings configured via ⚙️ menu.
            </div>
        </div>

        <div class="toolbar">
            <div style="font-size: 0.9rem; font-weight: 600; color: var(--text-muted);">Recent Active Cache (Newest First)</div>
            <button class="btn btn-danger" id="deleteSelected">Delete Selected Files</button>
        </div>

        <div class="table-container">
            <table>
                <thead>
                    <tr>
                        <th style="width: 40px;"><input type="checkbox" id="selectAll"></th>
                        <th>Name</th>
                        <th>Size</th>
                        <th>Time</th>
                        <th>Date</th>
                        <th>Status</th>
                    </tr>
                </thead>
                <tbody id="fileTableBody">
                    <tr><td colspan="6" class="empty-state">No active files cached in memory.</td></tr>
                </tbody>
            </table>
        </div>
    </div>

    <!-- Capacity Warning Alert Modal -->
    <div class="modal-overlay" id="capacityAlertModal">
        <div class="alert-modal-box">
            <svg class="warning-icon-svg" viewBox="0 0 24 24"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"></path><line x1="12" y1="9" x2="12" y2="13"></line><line x1="12" y1="17" x2="12.01" y2="17"></line></svg>
            <p class="alert-text" id="alertModalText">A file will be deleted to make space.</p>
            <div class="alert-actions">
                <button class="btn btn-clear" id="alertCancelBtn">Cancel</button>
                <button class="btn" id="alertTakeMeThereBtn" style="background-color: var(--accent);">Take me there</button>
            </div>
        </div>
    </div>

    <!-- Settings Modal -->
    <div class="modal-overlay" id="settingsModal">
        <div class="modal-content">
            <div class="modal-header">Console Settings</div>
            <div style="display: flex; flex-direction: column; gap: 12px; font-size: 0.9rem;">
                <div>
                    <label style="color: var(--text-muted); display: block; margin-bottom: 4px;">Max RAM Limit (MB)</label>
                    <input type="number" id="settingMaxRam" class="modal-input" value="1024">
                </div>
                <div>
                    <label style="color: var(--text-muted); display: block; margin-bottom: 4px;">Main Page Password (Leave blank for none)</label>
                    <input type="password" id="settingPagePass" class="modal-input" placeholder="Network password">
                </div>
                <div>
                    <label style="color: var(--text-muted); display: block; margin-bottom: 4px;">Settings Password (Leave blank for none)</label>
                    <input type="password" id="settingSettingsPass" class="modal-input" placeholder="Settings password">
                </div>
                <div style="display: flex; align-items: center; gap: 8px;">
                    <input type="checkbox" id="settingBlurFilename">
                    <label for="settingBlurFilename">Blur / Mask Filename</label>
                </div>
                <div style="display: flex; align-items: center; gap: 8px;">
                    <input type="checkbox" id="settingBlurExtension">
                    <label for="settingBlurExtension">Blur File Extension Too</label>
                </div>
                <div>
                    <label style="color: var(--text-muted); display: block; margin-bottom: 4px;">Mask Style</label>
                    <select id="settingMuteStyle" style="width: 100%;">
                        <option value="asterisk">Asterisks (**********)</option>
                        <option value="random">Random Alphanumeric</option>
                    </select>
                </div>
            </div>
            <div style="display: flex; justify-content: flex-end; gap: 10px; margin-top: 10px;">
                <button class="icon-btn" id="closeSettingsBtn">Cancel</button>
                <button class="btn" id="saveSettingsBtn">Save Changes</button>
            </div>
        </div>
    </div>

    <script>
        function runScrambleAnimation() {
            const el = document.getElementById('scrambleTitle');
            const targetText = "RAM DROP";
            const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$%#@*&!f57";
            let iteration = 0;
            
            const interval = setInterval(() => {
                el.innerText = targetText.split("").map((letter, index) => {
                    if (index < iteration) return targetText[index];
                    return chars[Math.floor(Math.random() * chars.length)];
                }).join("");
                
                if (iteration >= targetText.length) {
                    clearInterval(interval);
                    el.innerText = targetText;
                }
                iteration += 1 / 3;
            }, 40);
        }
        runScrambleAnimation();

        const refreshBtn = document.getElementById('refreshDropdownBtn');
        const refreshMenu = document.getElementById('refreshDropdown');
        refreshBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            refreshMenu.classList.toggle('show');
        });
        window.addEventListener('click', () => refreshMenu.classList.remove('show'));
        refreshMenu.addEventListener('click', (e) => e.stopPropagation());

        const settingsModal = document.getElementById('settingsModal');
        async function openSettings() {
            let authRes = await fetch('/api/verify-settings-auth');
            let authData = await authRes.json();
            
            if (!authData.authenticated) {
                let password = prompt("Enter Settings Tab Password:");
                if (!password) return;
                
                let loginRes = await fetch('/settings-login', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                    body: 'password=' + encodeURIComponent(password)
                });
                
                if (!loginRes.ok) {
                    alert("Incorrect settings password.");
                    return;
                }
            }

            let res = await fetch('/api/settings');
            let data = await res.json();
            document.getElementById('settingMaxRam').value = data.max_ram_mb;
            document.getElementById('settingPagePass').value = data.page_password || '';
            document.getElementById('settingSettingsPass').value = data.settings_password || '';
            document.getElementById('settingBlurFilename').checked = data.blur_filename;
            document.getElementById('settingBlurExtension').checked = data.blur_extension;
            document.getElementById('settingMuteStyle').value = data.mute_style;
            settingsModal.style.display = 'flex';
        }

        document.getElementById('settingsBtn').addEventListener('click', openSettings);
        document.getElementById('closeSettingsBtn').addEventListener('click', () => settingsModal.style.display = 'none');

        document.getElementById('saveSettingsBtn').addEventListener('click', async () => {
            let payload = {
                max_ram_mb: document.getElementById('settingMaxRam').value,
                page_password: document.getElementById('settingPagePass').value,
                settings_password: document.getElementById('settingSettingsPass').value,
                blur_filename: document.getElementById('settingBlurFilename'].checked,
                blur_extension: document.getElementById('settingBlurExtension').checked,
                mute_style: document.getElementById('settingMuteStyle').value
            };
            await fetch('/api/settings', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify(payload)
            });
            settingsModal.style.display = 'none';
            fetchStats();
        });

        let currentCpu = 0, targetCpu = 0;
        let currentRamTotal = 0, targetRamTotal = 0;
        let currentAppRam = 0, targetAppRam = 0;
        let maxRamLimit = 1024;

        async function fetchStats() {
            try {
                let res = await fetch('/api/stats');
                let data = await res.json();
                targetCpu = data.cpu;
                targetRamTotal = data.ram_used_mb;
                targetAppRam = data.app_ram_mb;
                maxRamLimit = data.max_ram_limit;

                updateCapacityBar();
            } catch (e) {}
        }
        setInterval(fetchStats, 5000);
        fetchStats();

        function updateCapacityBar() {
            let percent = Math.min(100, (currentAppRam / maxRamLimit) * 100);
            const fill = document.getElementById('capacityFill');
            fill.style.width = percent + '%';

            // Color shift from green/blue to red
            if (percent < 60) {
                fill.style.backgroundColor = 'var(--success)';
            } else if (percent < 85) {
                fill.style.backgroundColor = 'var(--warning)';
            } else {
                fill.style.backgroundColor = 'var(--danger)';
            }

            document.getElementById('capacity-text').innerText = `${currentAppRam.toFixed(1)} / ${maxRamLimit} MB`;
            document.getElementById('capacityTrack').setAttribute('data-tooltip', `${currentAppRam.toFixed(1)} MB / ${maxRamLimit} MB (${percent.toFixed(1)}%)`);
        }

        function animateStats() {
            currentCpu += (targetCpu - currentCpu) * 0.1;
            currentRamTotal += (targetRamTotal - currentRamTotal) * 0.1;
            currentAppRam += (targetAppRam - currentAppRam) * 0.1;

            document.getElementById('cpu-val').innerText = currentCpu.toFixed(1) + '%';
            document.getElementById('ram-val').innerText = currentRamTotal.toFixed(1) + ' MB';
            updateCapacityBar();

            requestAnimationFrame(animateStats);
        }
        requestAnimationFrame(animateStats);

        const dropzone = document.getElementById('dropzone');
        const fileInput = document.getElementById('fileInput');
        const progressBar = document.getElementById('progressBar');
        const progressContainer = document.getElementById('progressContainer');
        const capacityAlertModal = document.getElementById('capacityAlertModal');
        
        let pendingFile = null;
        let pendingTtl = 4;
        let targetFileIdsToHighlight = [];

        dropzone.addEventListener('click', () => fileInput.click());
        dropzone.addEventListener('dragover', (e) => { e.preventDefault(); dropzone.classList.add('dragover'); });
        dropzone.addEventListener('dragleave', () => dropzone.classList.remove('dragover'));
        dropzone.addEventListener('drop', (e) => {
            e.preventDefault();
            dropzone.classList.remove('dragover');
            if (e.dataTransfer.files.length) handleFileUploadPrecheck(e.dataTransfer.files[0]);
        });
        fileInput.addEventListener('change', () => { if (fileInput.files.length) handleFileUploadPrecheck(fileInput.files[0]); });

        async function handleFileUploadPrecheck(file) {
            pendingFile = file;
            pendingTtl = document.getElementById('ttlSelect').value;

            // Check capacity first
            let checkRes = await fetch('/api/check-capacity', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({size_bytes: file.size})
            });
            let checkData = await checkRes.json();

            if (checkData.needs_deletion) {
                targetFileIdsToHighlight = checkData.files_to_delete.map(f => f.id);
                let names = checkData.files_to_delete.map(f => f.name).join(', ');
                document.getElementById('alertModalText').innerHTML = `Uploading this file exceeds max RAM capacity.<br><br>The oldest file(s) (<strong>${names}</strong>) will be deleted to make space.<br><br>Press 'I understand, continue' to proceed.`;
                document.getElementById('alertTakeMeThereBtn').innerText = "I understand, continue";
                capacityAlertModal.style.display = 'flex';
            } else {
                executeUpload(false);
            }
        }

        document.getElementById('alertCancelBtn').addEventListener('click', () => {
            capacityAlertModal.style.display = 'none';
            pendingFile = null;
        });

        document.getElementById('alertTakeMeThereBtn').addEventListener('click', () => {
            capacityAlertModal.style.display = 'none';
            
            // Scroll to table and highlight target files
            const tableContainer = document.querySelector('.table-container');
            tableContainer.scrollIntoView({ behavior: 'smooth' });

            targetFileIdsToHighlight.forEach(id => {
                const row = document.querySelector(`tr[data-file-id="${id}"]`);
                if (row) {
                    row.classList.add('highlight-target');
                    setTimeout(() => row.classList.remove('highlight-target'), 6000);
                }
            });

            // Execute upload with force cleanup
            setTimeout(() => {
                executeUpload(true);
            }, 1000);
        });

        function executeUpload(forceCleanup) {
            if (!pendingFile) return;

            let formData = new FormData();
            formData.append('file', pendingFile);
            formData.append('ttl', pendingTtl);
            if (forceCleanup) {
                formData.append('force_cleanup', 'true');
            }

            let xhr = new XMLHttpRequest();
            xhr.open('POST', '/api/upload', true);
            progressContainer.style.display = 'block';

            xhr.upload.onprogress = (e) => {
                if (e.lengthComputable) {
                    let percent = (e.loaded / e.total) * 100;
                    progressBar.style.width = percent + '%';
                }
            };

            xhr.onload = () => {
                progressContainer.style.display = 'none';
                progressBar.style.width = '0%';
                pendingFile = null;
                loadFiles();
                fetchStats();
            };
            xhr.send(formData);
        }

        async function loadFiles() {
            try {
                let res = await fetch('/api/files');
                let files = await res.json();
                let tbody = document.getElementById('fileTableBody');
                
                if (!files.length) {
                    tbody.innerHTML = '<tr><td colspan="6" class="empty-state">No active files cached in memory.</td></tr>';
                    return;
                }

                tbody.innerHTML = '';
                files.forEach(f => {
                    let statusClass = 'dot-ready';
                    let statusTooltip = 'Ready: Safely cached in RAM and fully accessible';
                    
                    if (f.status === 'expiring_soon') {
                        statusClass = 'dot-expiring';
                        let mins = Math.floor(f.remaining_seconds / 60);
                        let secs = f.remaining_seconds % 60;
                        statusTooltip = `Expiring Soon: ${mins}m ${secs}s remaining until automatic purge`;
                    } else if (f.status === 'expired') {
                        statusClass = 'dot-expired';
                        statusTooltip = 'Discarded: Exceeded assigned retention window, pending cleanup';
                    } else if (f.status === 'reclaimed') {
                        statusClass = 'dot-reclaimed';
                        statusTooltip = 'System Reclaimed: Linux kernel automatically cleared buffer space for system stability';
                    } else if (f.status === 'deleted') {
                        statusClass = 'dot-deleted';
                        statusTooltip = 'Manually Deleted: Explicitly purged from memory by user action';
                    }

                    let tr = document.createElement('tr');
                    tr.setAttribute('data-file-id', f.id);
                    tr.innerHTML = `
                        <td><input type="checkbox" class="file-checkbox" value="${f.id}"></td>
                        <td><a href="/api/download/${f.id}" class="file-link">${f.display_name}</a></td>
                        <td>${f.size}</td>
                        <td>${f.time}</td>
                        <td>${f.date}</td>
                        <td>
                            <div class="status-badge">
                                <span class="status-dot ${statusClass}" data-tooltip="${statusTooltip}"></span>
                                <span style="font-size: 0.8rem; color: var(--text-muted); text-transform: capitalize;">${f.status.replace('_', ' ')}</span>
                            </div>
                        </td>
                    `;
                    tbody.appendChild(tr);
                });
            } catch (e) {}
        }

        let refreshTimer = null;
        const autoRefreshToggle = document.getElementById('autoRefreshToggle');
        const refreshIntervalSelect = document.getElementById('refreshInterval');
        const manualRefreshBtn = document.getElementById('manualRefreshBtn');

        function updateRefreshInterval() {
            if (refreshTimer) clearInterval(refreshTimer);
            if (autoRefreshToggle.checked) {
                let intervalSecs = parseInt(refreshIntervalSelect.value) || 5;
                refreshTimer = setInterval(loadFiles, intervalSecs * 1000);
            }
        }

        autoRefreshToggle.addEventListener('change', updateRefreshInterval);
        refreshIntervalSelect.addEventListener('change', updateRefreshInterval);
        manualRefreshBtn.addEventListener('click', () => {
            loadFiles();
            refreshMenu.classList.remove('show');
        });

        const selectAllCheckbox = document.getElementById('selectAll');
        selectAllCheckbox.addEventListener('change', () => {
            document.querySelectorAll('.file-checkbox').forEach(cb => cb.checked = selectAllCheckbox.checked);
        });

        document.getElementById('deleteSelected').addEventListener('click', async () => {
            let selectedIds = [];
            document.querySelectorAll('.file-checkbox:checked').forEach(cb => selectedIds.push(cb.value));
            if (!selectedIds.length) return;

            await fetch('/api/delete', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({ids: selectedIds})
            });
            loadFiles();
            fetchStats();
        });

        loadFiles();
    </script>
</body>
</html>
EOF

cat << 'EOF' > "$TEMPLATE_DIR/login.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{ title }}</title>
    <style>
        :root {
            --bg-color: #030712;
            --surface-color: #0f172a;
            --surface-border: #1e293b;
            --accent: #38bdf8;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --danger: #f43f5e;
        }
        body {
            font-family: system-ui, -apple-system, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-main);
            height: 100vh;
            margin: 0;
            display: flex;
            justify-content: center;
            align-items: center;
        }
        .login-box {
            background-color: var(--surface-color);
            border: 1px solid var(--surface-border);
            padding: 30px;
            border-radius: 16px;
            width: 100%;
            max-width: 350px;
            display: flex;
            flex-direction: column;
            gap: 16px;
            box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.5);
        }
        h2 { margin: 0 0 4px 0; font-size: 1.5rem; text-align: center; }
        .input-field {
            background: var(--bg-color); border: 1px solid var(--surface-border);
            color: var(--text-main); padding: 10px 14px; border-radius: 8px; font-size: 0.95rem; width: 100%; box-sizing: border-box;
        }
        .btn {
            background-color: var(--accent); color: #030712; border: none; padding: 10px;
            border-radius: 8px; font-weight: 600; cursor: pointer; width: 100%;
        }
        .error { color: var(--danger); font-size: 0.85rem; text-align: center; margin: 0; }
    </style>
</head>
<body>
    <form class="login-box" method="POST">
        <h2>RAM DROP</h2>
        <p style="color: var(--text-muted); font-size: 0.85rem; text-align: center; margin: 0;">Authentication Required</p>
        {% if error %}
        <p class="error">{{ error }}</p>
        {% endif %}
        <input type="password" name="password" class="input-field" placeholder="Password" required autofocus>
        <button type="submit" class="btn">Authenticate</button>
    </form>
</body>
</html>
EOF

echo "[*] Configuring systemd service..."
sudo bash -c "cat > $SERVICE_PATH" << EOL
[Unit]
Description=RAM Drop Secure Volatile File Drop Service
After=network.target

[Service]
User=$CURRENT_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $PYTHON_APP_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable ramdrop.service
sudo systemctl restart ramdrop.service

echo "[+] RAM Drop v1.4.0 successfully deployed!"
echo "[+] Access your console at: http://<server-ip>:$PORT"
