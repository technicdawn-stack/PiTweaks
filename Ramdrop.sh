#!/bin/bash

# Description: RAM Drop v1.0.2 All-in-One Self-Contained Deployment & Management Console
# PERSISTENT: TRUE
# Category: Webpages

APP_DIR="/home/$(whoami)/ram-drop"
PYTHON_APP_PATH="$APP_DIR/app.py"
TEMPLATE_DIR="$APP_DIR/templates"
TEMPLATE_PATH="$TEMPLATE_DIR/index.html"
SERVICE_PATH="/etc/systemd/system/ramdrop.service"
CURRENT_USER=$(whoami)
PORT=8083

mkdir -p "$TEMPLATE_DIR"

# Write the self-contained Flask application and HTML template in a single execution block
cat << 'EOF' > "$PYTHON_APP_PATH"
import os
import time
import random
import string
import psutil
from flask import Flask, render_template, request, jsonify, send_from_directory

app = Flask(__name__)

UPLOAD_FOLDER = '/home/pi/filedrop/uploads'
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
MAX_CONTENT_LENGTH = 100 * 1024 * 1024  # 100MB Max File Limit

file_metadata = {}

def generate_masked_name(original_filename, mode="asterisk"):
    ext = os.path.splitext(original_filename)[1]
    if mode == "random":
        name = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))
    else:
        name = "**********"
    return f"{name}{ext}"

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/stats', methods=['GET'])
def get_stats():
    cpu_usage = psutil.cpu_percent(interval=None)
    ram = psutil.virtual_memory()
    return jsonify({
        'cpu': cpu_usage,
        'ram_percent': ram.percent,
        'ram_used_mb': round(ram.used / (1024 * 1024), 2),
        'ram_total_mb': round(ram.total / (1024 * 1024), 2)
    })

@app.route('/api/files', methods=['GET'])
def list_files():
    current_time = time.time()
    active_files = []
    
    for file_id, meta in list(file_metadata.items()):
        file_path = os.path.join(app.config['UPLOAD_FOLDER'], meta['stored_name'])
        
        if meta['status'] == 'deleted':
            state = 'deleted'
        elif not os.path.exists(file_path):
            state = 'reclaimed'
        elif (meta['timestamp'] + meta['ttl']) < current_time:
            state = 'expired'
        elif (meta['timestamp'] + meta['ttl'] - current_time) < 3600:
            state = 'expiring_soon'
        else:
            state = 'ready'
            
        active_files.append({
            'id': file_id,
            'display_name': meta['display_name'],
            'size': meta['size'],
            'time': time.strftime('%H:%M:%S', time.localtime(meta['timestamp'])),
            'date': time.strftime('%Y-%m-%d', time.localtime(meta['timestamp'])),
            'status': state
        })
        
    return jsonify(active_files)

@app.route('/api/upload', methods=['POST'])
def upload_file():
    if 'file' not in request.files:
        return jsonify({'error': 'No file part'}), 400
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'No selected file'}), 400
        
    mute_name = request.form.get('mute', 'false') == 'true'
    mute_style = request.form.get('mute_style', 'asterisk')
    ttl_hours = int(request.form.get('ttl', 4))
    
    display_name = file.filename
    if mute_name:
        display_name = generate_masked_name(display_name, mute_style)
        
    file_id = ''.join(random.choices(string.ascii_lowercase + string.digits, k=10))
    stored_name = f"{file_id}_{file.filename}"
    file_path = os.path.join(app.config['UPLOAD_FOLDER'], stored_name)
    
    file.save(file_path)
    file_size = os.path.getsize(file_path)
    
    file_metadata[file_id] = {
        'stored_name': stored_name,
        'display_name': display_name,
        'size': f"{round(file_size / 1024, 1)} KB" if file_size < 1024*1024 else f"{round(file_size / (1024*1024), 1)} MB",
        'timestamp': time.time(),
        'ttl': ttl_hours * 3600,
        'status': 'ready'
    }
    
    return jsonify({'success': True, 'id': file_id})

@app.route('/api/download/<file_id>', methods=['GET'])
def download_file(file_id):
    if file_id not in file_metadata:
        return "File not found", 404
    meta = file_metadata[file_id]
    return send_from_directory(app.config['UPLOAD_FOLDER'], meta['stored_name'], as_attachment=True, download_name=meta['display_name'])

@app.route('/api/delete', methods=['POST'])
def delete_files():
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
    app.run(host='0.0.0.0', port=8080)
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

        .wrapper { width: 100%; max-width: 960px; }
        header { text-align: center; margin-bottom: 30px; }
        h1 {
            font-size: 2.25rem; font-weight: 800; letter-spacing: -0.025em; margin: 0 0 8px 0;
            background: linear-gradient(135deg, #38bdf8 0%, #818cf8 100%);
            -webkit-background-clip: text; -webkit-text-fill-color: transparent;
        }
        p.subtitle { color: var(--text-muted); font-size: 0.95rem; margin: 0; }

        .telemetry-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px; margin-bottom: 24px; }
        .telemetry-card { background-color: var(--surface-color); border: 1px solid var(--surface-border); padding: 16px 20px; border-radius: 12px; }
        .telemetry-label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); margin-bottom: 6px; }
        .telemetry-value { font-size: 1.25rem; font-weight: 700; color: var(--text-main); }

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
        input[type="checkbox"] { width: 18px; height: 18px; accent-color: var(--accent); cursor: pointer; }

        .toolbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
        .btn { background-color: var(--accent); color: #030712; border: none; padding: 10px 18px; border-radius: 8px; font-weight: 600; font-size: 0.9rem; cursor: pointer; transition: background-color 0.2s; }
        .btn:hover { background-color: var(--accent-hover); }
        .btn-danger { background-color: rgba(244, 63, 94, 0.1); color: var(--danger); border: 1px solid rgba(244, 63, 94, 0.2); }
        .btn-danger:hover { background-color: var(--danger); color: white; }

        .table-container { background-color: var(--surface-color); border: 1px solid var(--surface-border); border-radius: 12px; overflow: hidden; }
        table { width: 100%; border-collapse: collapse; text-align: left; font-size: 0.9rem; }
        th, td { padding: 14px 18px; border-bottom: 1px solid var(--surface-border); }
        th { background-color: rgba(15, 23, 42, 0.6); font-weight: 600; color: var(--text-muted); font-size: 0.75rem; text-transform: uppercase; }
        tr:last-child td { border-bottom: none; }
        a.file-link { color: var(--accent); text-decoration: none; font-weight: 500; }
        a.file-link:hover { text-decoration: underline; }

        .status-badge { display: inline-flex; align-items: center; gap: 8px; font-size: 0.85rem; font-weight: 500; }
        .status-dot { width: 10px; height: 10px; border-radius: 50%; position: relative; cursor: pointer; }
        .status-dot[data-tooltip]:hover::after {
            content: attr(data-tooltip); position: absolute; bottom: 18px; left: 50%; transform: translateX(-50%);
            background: #020617; color: #fff; padding: 6px 10px; font-size: 0.75rem; border-radius: 6px;
            white-space: nowrap; border: 1px solid var(--surface-border); z-index: 50; pointer-events: none;
        }
        .dot-ready { background-color: var(--success); }
        .dot-expiring { background-color: var(--amber-pulse); animation: pulse 1.2s infinite ease-in-out; }
        .dot-expired { background-color: var(--warning); }
        .dot-reclaimed { background-color: var(--reclaimed-blue); }
        .dot-deleted { background-color: var(--danger); }

        @keyframes pulse {
            0% { transform: scale(0.95); opacity: 1; }
            70% { transform: scale(1.1); opacity: 0.8; }
            100% { transform: scale(0.95); opacity: 1; }
        }
        .empty-state { text-align: center; padding: 40px; color: var(--text-muted); font-style: italic; }
    </style>
</head>
<body>
    <div class="wrapper">
        <header>
            <h1>RAM DROP</h1>
            <p class="subtitle">Zero-Wear Volatile Local File Transfer Hub</p>
        </header>

        <div class="telemetry-grid">
            <div class="telemetry-card">
                <div class="telemetry-label">CPU Utilization</div>
                <div class="telemetry-value" id="cpu-val">0.0%</div>
            </div>
            <div class="telemetry-card">
                <div class="telemetry-label">RAM Buffer Allocation</div>
                <div class="telemetry-value" id="ram-val">0.0 MB</div>
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
                <input type="checkbox" id="muteToggle">
                <label for="muteToggle" style="cursor: pointer;">Mute Filename (Privacy Shield)</label>
            </div>
            <div class="control-group">
                <label for="ttlSelect">Retention Lifetime:</label>
                <select id="ttlSelect">
                    <option value="1">1 Hour</option>
                    <option value="4" selected>4 Hours</option>
                    <option value="12">12 Hours</option>
                    <option value="24">24 Hours</option>
                </select>
            </div>
        </div>

        <div class="toolbar">
            <div style="font-size: 0.9rem; font-weight: 600; color: var(--text-muted);">Recent Active Cache (Last 24 Hours)</div>
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

    <script>
        let currentCpu = 0, targetCpu = 0;
        let currentRam = 0, targetRam = 0;

        async function fetchStats() {
            try {
                let res = await fetch('/api/stats');
                let data = await res.json();
                targetCpu = data.cpu;
                targetRam = data.ram_used_mb;
            } catch (e) {}
        }
        setInterval(fetchStats, 5000);
        fetchStats();

        function animateStats() {
            currentCpu += (targetCpu - currentCpu) * 0.1;
            currentRam += (targetRam - currentRam) * 0.1;
            document.getElementById('cpu-val').innerText = currentCpu.toFixed(1) + '%';
            document.getElementById('ram-val').innerText = currentRam.toFixed(1) + ' MB';
            requestAnimationFrame(animateStats);
        }
        requestAnimationFrame(animateStats);

        const dropzone = document.getElementById('dropzone');
        const fileInput = document.getElementById('fileInput');
        const progressBar = document.getElementById('progressBar');
        const progressContainer = document.getElementById('progressContainer');

        dropzone.addEventListener('click', () => fileInput.click());
        dropzone.addEventListener('dragover', (e) => { e.preventDefault(); dropzone.classList.add('dragover'); });
        dropzone.addEventListener('dragleave', () => dropzone.classList.remove('dragover'));
        dropzone.addEventListener('drop', (e) => {
            e.preventDefault();
            dropzone.classList.remove('dragover');
            if (e.dataTransfer.files.length) uploadFile(e.dataTransfer.files[0]);
        });
        fileInput.addEventListener('change', () => { if (fileInput.files.length) uploadFile(fileInput.files[0]); });

        function uploadFile(file) {
            let formData = new FormData();
            formData.append('file', file);
            formData.append('mute', document.getElementById('muteToggle').checked);
            formData.append('ttl', document.getElementById('ttlSelect').value);

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
                loadFiles();
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
                        statusTooltip = 'Leaving Soon: Less than 1 hour remaining until automatic purge';
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
        setInterval(loadFiles, 3000);
        loadFiles();

        document.getElementById('selectAll').addEventListener('change', (e) => {
            document.querySelectorAll('.file-checkbox').forEach(cb => cb.checked = e.target.checked);
        });

        document.getElementById('deleteSelected').addEventListener('click', async () => {
            let ids = Array.from(document.querySelectorAll('.file-checkbox:checked')).map(cb => cb.value);
            if (!ids.length) return;
            await fetch('/api/delete', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({ids})
            });
            loadFiles();
        });
    </script>
</body>
</html>
EOF

PI_IP=$(hostname -I | awk '{print $1}')
[ -z "$PI_IP" ] && PI_IP="127.0.0.1"

while true; do
    clear
    echo "=========================================================="
    echo "       RAM DROP v1.0.0 MANAGEMENT CONSOLE                 "
    echo "=========================================================="
    echo " Web Dashboard URL : http://$PI_IP:$PORT"
    echo " App Directory     : $APP_DIR"
    echo "----------------------------------------------------------"
    echo " [1] Start Server (Interactive / Foreground Mode)"
    echo " [2] Enable Always-On (Systemd Service + Background Start)"
    echo " [3] Disable Always-On (Stop & Remove Systemd Service)"
    echo " [4] Uninstall / Purge All Traces & Files"
    echo " [5] Exit Menu"
    echo "=========================================================="
    read -p "Select an option [1-5]: " choice

    case $choice in
        1)
            echo "Starting RAM Drop server on port $PORT. Press Ctrl+C to exit."
            python3 "$PYTHON_APP_PATH"
            ;;
        2)
            if [ "$EUID" -ne 0 ]; then
                echo ""
                echo "[-] Sudo permission required to configure systemd service."
                echo "[!] Please run the script with root privileges or execute:"
                echo "    sudo systemctl daemon-reload"
                read -p "Press Enter to return to menu..."
                continue
            fi
            cat << EOT > "$SERVICE_PATH"
[Unit]
Description=RAM Drop Volatile File Sharing Web Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/usr/bin/python3 $PYTHON_APP_PATH
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOT
            systemctl daemon-reload
            systemctl enable ramdrop.service
            systemctl restart ramdrop.service
            echo "Success: Systemd service enabled and started successfully!"
            read -p "Press Enter to continue..."
            ;;
        3)
            if [ "$EUID" -ne 0 ]; then
                echo "[-] Sudo required to remove systemd service."
                read -p "Press Enter to continue..."
                continue
            fi
            systemctl stop ramdrop.service &>/dev/null
            systemctl disable ramdrop.service &>/dev/null
            rm -f "$SERVICE_PATH"
            systemctl daemon-reload
            echo "Success: Systemd service disabled and removed."
            read -p "Press Enter to continue..."
            ;;
        4)
            if [ "$EUID" -eq 0 ]; then
                systemctl stop ramdrop.service &>/dev/null
                systemctl disable ramdrop.service &>/dev/null
                rm -f "$SERVICE_PATH"
                systemctl daemon-reload
            fi
            fuser -k ${PORT}/tcp &>/dev/null
            rm -rf "$APP_DIR"
            echo "Success: All traces of RAM Drop v1.0.0 have been completely purged."
            exit 0
            ;;
        5)
            echo "Exiting menu."
            exit 0
            ;;
        *)
            echo "Invalid option. Please choose a number between 1 and 5."
            sleep 2
            ;;
    esac
done
