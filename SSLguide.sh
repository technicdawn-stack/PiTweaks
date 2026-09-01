#!/bin/bash

# Description: Interactive Installer & Systemd Service Setup for SSL Guide Utility
# PERSISTENT: FALSE
# Category: Webpages

INSTALL_DIR="/opt/sslguide"
CONFIG_FILE="$INSTALL_DIR/sslconfig.txt"
SERVICE_NAME="sslguide"
PORT=8084

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo bash sslguide.sh)"
  exit 1
fi

# Check for existing configuration
USE_EXISTING="no"
if [ -f "$CONFIG_FILE" ]; then
  if whiptail --title "Existing Configuration Found" --yesno "An existing sslconfig.txt was found. Would you like to use your existing settings?" 10 60; then
    USE_EXISTING="yes"
  fi
fi

if [ "$USE_EXISTING" = "yes" ]; then
  # Load values from existing config (JSON parsing or sourcing)
  CERT_PATH=$(grep -o '"cert_path": *"[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
  AUTH_ENABLED=$(grep -o '"auth_enabled": *[^,}]*' "$CONFIG_FILE" | awk '{print $2}')
  PASSWORD=$(grep -o '"password": *"[^"]*"' "$CONFIG_FILE" | cut -d'"' -f4)
else
  # Default certificate path
  DEFAULT_CERT="/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"

  # Prompt for Certificate Path using whiptail
  CERT_PATH=$(whiptail --title "SSL Path Configuration" --inputbox "Enter the file path to your root.crt file:" 10 60 "$DEFAULT_CERT" 3>&1 1>&2 2>&3)
  if [ $? -ne 0 ]; then
    echo "Installation cancelled."
    exit 0
  fi

  # Prompt for Password Protection
  if whiptail --title "Authentication" --yesno "Would you like to password-protect access to the SSL guide page?" 10 60; then
    AUTH_ENABLED="true"
    PASSWORD=$(whiptail --title "Set Password" --passwordbox "Enter the password for the web utility:" 10 60 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$PASSWORD" ]; then
      echo "Password cannot be empty. Authentication disabled."
      AUTH_ENABLED="false"
      PASSWORD=""
    fi
  else
    AUTH_ENABLED="false"
    PASSWORD=""
  fi
fi

# Create application directory
mkdir -p "$INSTALL_DIR/templates" "$INSTALL_DIR/static"

# Write out sslconfig.txt
cat << EOF > "$CONFIG_FILE"
{
  "cert_path": "$CERT_PATH",
  "auth_enabled": $AUTH_ENABLED,
  "password": "$PASSWORD"
}
EOF

# Write app.py (Flask Backend)
cat << 'EOF' > "$INSTALL_DIR/app.py"
import os
import json
from flask import Flask, render_template, send_file, request, redirect, url_for, session

app = Flask(__name__)
app.secret_key = os.urandom(24)

CONFIG_PATH = '/opt/sslguide/sslconfig.txt'

def load_config():
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, 'r') as f:
            return json.load(f)
    return {"cert_path": "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt", "auth_enabled": False, "password": ""}

@app.before_request
def require_auth():
    config = load_config()
    if config.get("auth_enabled") and request.endpoint not in ['login', 'static', 'download_cert']:
        if not session.get('authenticated'):
            return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    config = load_config()
    error = None
    if request.method == 'POST':
        if request.form.get('password') == config.get('password'):
            session['authenticated'] = True
            return redirect(url_for('index'))
        error = 'Invalid password.'
    return render_template('login.html', error=error)

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/download')
def download_cert():
    config = load_config()
    cert_path = config.get("cert_path")
    if os.path.exists(cert_path):
        return send_file(cert_path, as_attachment=True, download_name='root.crt')
    return "Certificate file not found on server path.", 404

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8084)
EOF

# Write templates/index.html (Modern Wizard UI)
cat << 'EOF' > "$INSTALL_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SSL Setup Guide</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body>
    <div class="container">
        <header>
            <h1>SSL Setup Guide</h1>
            <p class="subtitle">Secure your local network connection with trust.</p>
        </header>

        <main id="wizard-card" class="card">
            <!-- Intro Screen -->
            <div id="step-intro" class="wizard-step active">
                <h2>Do you need help installing the SSL certificate?</h2>
                <p>This interactive wizard will walk you through downloading and trusting the local root certificate on your iOS device for seamless access to your local services.</p>
                <div class="button-group">
                    <button class="btn primary" onclick="nextStep(1)">Start Guide</button>
                    <a href="/download" class="btn secondary">Download Certificate Only</a>
                </div>
            </div>

            <!-- Step 1 -->
            <div id="step-1" class="wizard-step">
                <span class="step-badge">Step 1 of 8</span>
                <h2>Download the Profile</h2>
                <p>Tap the button below to download the root certificate directly to your device.</p>
                <a href="/download" class="btn primary download-btn">Download root.crt</a>
                <div class="nav-buttons">
                    <button class="btn outline" onclick="prevStep(0)">Back</button>
                    <button class="btn primary" onclick="nextStep(2)">Next</button>
                </div>
            </div>

            <!-- Step 2 -->
            <div id="step-2" class="wizard-step">
                <span class="step-badge">Step 2 of 8</span>
                <h2>Install Profile Location</h2>
                <p>Click on the downloaded file. When prompted, select your target device (e.g., your iPhone or iPad name) to initiate installation.</p>
                <div class="nav-buttons">
                    <button class="btn outline" onclick="prevStep(1)">Back</button>
                    <button class="btn primary" onclick="nextStep(3)">Next</button>
                </div>
            </div>

            <!-- Step 3 -->
            <div id="step-3" class="wizard-step">
                <span class="step-badge">Step 3 of 8</span>
                <h2>Open Device Management</h2>
                <p>Open your device <strong>Settings</strong>. If visible, tap <strong>Profile Downloaded</strong>. Otherwise, navigate to <strong>General</strong> &rarr; <strong>VPN & Device Management</strong>.</p>
                <div class="nav-buttons">
                    <button class="btn outline" onclick="prevStep(2)">Back</button>
                    <button class="btn primary" onclick="nextStep(4)">Next</button>
                </div>
            </div>

            <!-- Step 4 -->
            <div id="step-4" class="wizard-step">
                <span class="step-badge">Step 4 of 8</span>
                <h2>Confirm Installation</h2>
                <p>Select the <strong>Caddy Local Authority ECC Root</strong> profile, then tap <strong>Install</strong> in the top-right corner.</p>
                <div class="nav-buttons">
                    <button class="btn outline" onclick="prevStep(3)">Back</button>
                    <button class="btn primary" onclick="nextStep(5)">Next</button>
                </div>
            </div>

            <!-- Step 5 -->
            <div id="step-5" class="wizard-step">
                <span class="step-badge">Step 5 of 8</span>
                <h2>Bypass Warning Prompt</h2>
                <p>Enter your device passcode. When warned that the certificate cannot be verified, do not panic—tap <strong>Install</strong> again.</p>
                <div class="callout warning">
                    <p>The warning simply indicates a custom local CA rather than a global provider. It is completely secure for home network usage.</p>
                </div>
                <div class="nav-buttons">
                    <button class="btn outline" onclick="prevStep(4)">Back</button>
                    <button class="btn primary" onclick="nextStep(6)">Next</button>
                </div>
            </div>

            <!-- Step 6 -->
            <div id="step-6" class="wizard-step">
                <span class="step-badge">Step 6 of 8</span>
                <h2>Pre-Trust Sanity Check</h2>
                <p>Before tapping the final confirmation tick, review the profile to ensure there is no red warning text or errors.</p>
                <div class="callout tip">
                    <p>If you see red error text, remove the profile and restart this guide. If clean, tap <strong>Done</strong>.</p>
                </div>
                <div class="nav-buttons">
                    <button class="btn outline" onclick="prevStep(5)">Back</button>
                    <button class="btn primary" onclick="nextStep(7)">Next</button>
                </div>
            </div>

            <!-- Step 7 -->
            <div id="step-7" class="wizard-step">
                <span class="step-badge">Step 7 of 8</span>
                <h2>Enable Full Trust</h2>
                <p>Navigate to <strong>Settings</strong> &rarr; <strong>General</strong> &rarr; <strong>About</strong>, scroll to the bottom, and tap <strong>Certificate Trust Settings</strong>.</p>
                <div class="nav-buttons">
                    <button class="btn outline" onclick="prevStep(6)">Back</button>
                    <button class="btn primary" onclick="nextStep(8)">Next</button>
                </div>
            </div>

            <!-- Step 8 -->
            <div id="step-8" class="wizard-step">
                <span class="step-badge">Step 8 of 8</span>
                <h2>Activate Root Trust</h2>
                <p>Under <em>Enable Full Trust for Root Certificates</em>, find the <strong>Caddy Local Authority - ECC Root</strong> entry and toggle the switch on. Accept any warning prompts.</p>
                <div class="success-box">
                    <p><strong>You're all set!</strong> You can now browse your local network securely without security warnings.</p>
                </div>
                <div class="button-group">
                    <a href="https://dash.home" class="btn primary">Visit Dashboard</a>
                    <button class="btn outline" onclick="prevStep(0)">Restart Guide</button>
                </div>
            </div>
        </main>
    </div>

    <script>
        let currentStep = 0;
        const totalSteps = 8;

        function showStep(stepIndex) {
            document.querySelectorAll('.wizard-step').forEach(el => el.classList.remove('active'));
            document.getElementById(`step-${stepIndex === 0 ? 'intro' : stepIndex}`).classList.add('active');
            currentStep = stepIndex;
        }

        function nextStep(step) { showStep(step); }
        function prevStep(step) { showStep(step); }
    </script>
</body>
</html>
EOF

# Write templates/login.html
cat << 'EOF' > "$INSTALL_DIR/templates/login.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SSL Guide - Login</title>
    <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body>
    <div class="container">
        <div class="card login-card">
            <h2>Restricted Access</h2>
            <p>Enter the password to access the SSL guide.</p>
            {% if error %}
            <p class="error-msg">{{ error }}</p>
            {% endif %}
            <form method="POST">
                <input type="password" name="password" placeholder="Password" required autofocus>
                <button type="submit" class="btn primary">Login</button>
            </form>
        </div>
    </div>
</body>
</html>
EOF

# Write static/style.css (Slick, Modern Theme)
cat << 'EOF' > "$INSTALL_DIR/static/style.css"
:root {
    --bg-color: #0f172a;
    --card-bg: #1e293b;
    --text-color: #f8fafc;
    --text-muted: #94a3b8;
    --accent: #38bdf8;
    --accent-hover: #0ea5e9;
    --border: #334155;
    --warning-bg: rgba(234, 179, 8, 0.1);
    --warning-border: #eab308;
    --success-bg: rgba(34, 197, 94, 0.1);
    --success-border: #22c55e;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background-color: var(--bg-color);
    color: var(--text-color);
    margin: 0;
    padding: 0;
    display: flex;
    justify-content: center;
    align-items: center;
    min-height: 100vh;
}

.container {
    width: 100%;
    max-width: 550px;
    padding: 20px;
    box-sizing: border-box;
}

header {
    text-align: center;
    margin-bottom: 24px;
}

header h1 {
    font-size: 1.75rem;
    margin: 0 0 8px 0;
}

.subtitle {
    color: var(--text-muted);
    font-size: 0.95rem;
    margin: 0;
}

.card {
    background-color: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 32px;
    box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3);
}

.wizard-step {
    display: none;
}

.wizard-step.active {
    display: block;
    animation: fadeIn 0.3s ease-in-out;
}

@keyframes fadeIn {
    from { opacity: 0; transform: translateY(6px); }
    to { opacity: 1; transform: translateY(0); }
}

.step-badge {
    display: inline-block;
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--accent);
    background: rgba(56, 189, 248, 0.1);
    padding: 4px 10px;
    border-radius: 20px;
    margin-bottom: 16px;
}

h2 {
    font-size: 1.25rem;
    margin-top: 0;
    margin-bottom: 12px;
}

p {
    color: var(--text-muted);
    font-size: 0.95rem;
    line-height: 1.5;
    margin-bottom: 20px;
}

strong {
    color: var(--text-color);
}

.callout {
    padding: 12px 16px;
    border-radius: 8px;
    font-size: 0.9rem;
    margin-bottom: 20px;
}

.callout.warning {
    background-color: var(--warning-bg);
    border-left: 4px solid var(--warning-border);
}

.callout.tip {
    background-color: rgba(56, 189, 248, 0.1);
    border-left: 4px solid var(--accent);
}

.success-box {
    background-color: var(--success-bg);
    border: 1px solid var(--success-border);
    border-radius: 8px;
    padding: 14px;
    margin-bottom: 20px;
    text-align: center;
}

.button-group, .nav-buttons {
    display: flex;
    gap: 12px;
    margin-top: 24px;
}

.nav-buttons {
    justify-content: space-between;
}

.btn {
    display: inline-block;
    text-align: center;
    padding: 10px 20px;
    border-radius: 8px;
    font-size: 0.95rem;
    font-weight: 500;
    text-decoration: none;
    cursor: pointer;
    border: none;
    transition: background 0.2s, transform 0.1s;
}

.btn.primary {
    background-color: var(--accent);
    color: #0f172a;
    flex: 1;
}

.btn.primary:hover {
    background-color: var(--accent-hover);
}

.btn.outline {
    background-color: transparent;
    border: 1px solid var(--border);
    color: var(--text-color);
}

.btn.outline:hover {
    background-color: rgba(255, 255, 255, 0.05);
}

.btn.secondary {
    background-color: var(--border);
    color: var(--text-color);
    flex: 1;
}

.download-btn {
    display: block;
    text-align: center;
    margin-bottom: 10px;
}

input[type="password"] {
    width: 100%;
    padding: 12px;
    background-color: var(--bg-color);
    border: 1px solid var(--border);
    border-radius: 8px;
    color: var(--text-color);
    font-size: 1rem;
    margin-bottom: 16px;
    box-sizing: border-box;
}

.error-msg {
    color: #ef4444;
    font-size: 0.85rem;
    margin-bottom: 12px;
}
EOF

# Set up Python virtual environment and dependencies
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet flask

# Create Systemd Service
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat << EOF > "$SERVICE_FILE"
[Unit]
Description=SSL Guide Local Web Utility
After=network.target

[Service]
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Reload and start service
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo "===================================================="
echo "SSL Guide successfully installed and running!"
echo "Access it on your local network at: http://<pi-ip>:$PORT"
echo "Config stored cleanly at: $CONFIG_FILE"
echo "===================================================="
