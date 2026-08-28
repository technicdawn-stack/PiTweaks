#!/bin/bash

# Description: CubeCooler v1.4.1 Management Console with Persistent Service Control
# Author: Raspberry Pi Collaborator

APP_DIR="/home/$(whoami)"
PYTHON_APP_PATH="$APP_DIR/CubeCooler.py"
PORT=8081

# Ensure Python app script exists on disk persistently
create_app() {
    cat << 'EOF' > "$PYTHON_APP_PATH"
import http.servera#!/bin/bash

# Description: CubeCooler v1.4 Management Console with Immediate Background Start & Persistent Cron
# Author: Raspberry Pi Collaborator

APP_DIR="/home/$(whoami)"
PYTHON_APP_PATH="$APP_DIR/CubeCooler.py"
PORT=8081

# Ensure Python app script exists on disk persistently
create_app() {
    cat << 'EOF' > "$PYTHON_APP_PATH"
import http.server
import socketserver
import urllib.parse

PORT = 8081

class CubeCoolerHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        
        parsed_path = urllib.parse.urlparse(self.path)
        query_params = urllib.parse.parse_qs(parsed_path.query)
        
        water_vol = query_params.get("water_vol", [""])[0]
        init_temp = query_params.get("init_temp", [""])[0]
        final_temp = query_params.get("final_temp", [""])[0]
        ice_weight = query_params.get("ice_weight", [""])[0]
        container = query_params.get("container", ["1.15"])[0]
        
        result_msg = ""
        result_color = "#38bdf8"
        
        if any([water_vol, init_temp, final_temp, ice_weight]):
            try:
                eff = float(container)
                fields = {
                    "water_vol": water_vol,
                    "init_temp": init_temp,
                    "final_temp": final_temp,
                    "ice_weight": ice_weight
                }
                
                empty_keys = [k for k, v in fields.items() if not v]
                
                if len(empty_keys) != 1:
                    result_msg = "Error: Please leave exactly ONE field blank to auto-solve it."
                    result_color = "#f43f5e"
                else:
                    empty_key = empty_keys[0]
                    data = {k: float(v) for k, v in fields.items() if v}
                    
                    if empty_key == "final_temp":
                        v = data["water_vol"] * 1000.0
                        ti = data["init_temp"]
                        m_ice = data["ice_weight"]
                        numerator = (v * 4.184 * ti) - (m_ice * 334.0 * eff)
                        denominator = (v * 4.184) + (m_ice * 4.184 * eff)
                        tf = numerator / denominator
                        final_temp = f"{tf:.2f}"
                        result_msg = f"Successfully solved Final Temperature: {final_temp} °C"
                        result_color = "#34d399"
                        
                    elif empty_key == "ice_weight":
                        v = data["water_vol"] * 1000.0
                        ti = data["init_temp"]
                        tf = data["final_temp"]
                        if tf >= ti:
                            result_msg = "Error: Final temp must be lower than initial temp."
                            result_color = "#f43f5e"
                        else:
                            target_drop = ti - tf
                            heat_to_remove = v * 4.184 * target_drop * eff
                            energy_per_g_ice = 334.0 + (4.184 * max(0.0, tf))
                            m_ice = heat_to_remove / energy_per_g_ice
                            ice_weight = f"{m_ice:.2f}"
                            result_msg = f"Successfully solved Ice Weight: {ice_weight} g"
                            result_color = "#34d399"
                            
                    elif empty_key == "water_vol":
                        ti = data["init_temp"]
                        tf = data["final_temp"]
                        m_ice = data["ice_weight"]
                        target_drop = ti - tf
                        energy_gained = m_ice * (334.0 + (4.184 * max(0.0, tf)))
                        water_mass_g = energy_gained / (4.184 * target_drop * eff)
                        v = water_mass_g / 1000.0
                        water_vol = f"{v:.2f}"
                        result_msg = f"Successfully solved Water Volume: {water_vol} L"
                        result_color = "#34d399"
                        
                    elif empty_key == "init_temp":
                        v = data["water_vol"] * 1000.0
                        tf = data["final_temp"]
                        m_ice = data["ice_weight"]
                        energy_gained = m_ice * (334.0 + (4.184 * max(0.0, tf)))
                        heat_needed = energy_gained * eff
                        delta_t = heat_needed / (v * 4.184)
                        ti = tf + delta_t
                        init_temp = f"{ti:.2f}"
                        result_msg = f"Successfully solved Initial Temperature: {init_temp} °C"
                        result_color = "#34d399"
                        
            except Exception as e:
                result_msg = f"Calculation Error: {str(e)}"
                result_color = "#f43f5e"

        html = f"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>CubeCooler v1.4 - Thermal Equilibrium Engine</title>
            <style>
                :root {{
                    --bg-color: #0f172a;
                    --card-bg: #1e293b;
                    --text-color: #f8fafc;
                    --accent-color: #3b82f6;
                    --accent-hover: #2563eb;
                    --border-color: #334155;
                }}
                body {{
                    font-family: system-ui, -apple-system, sans-serif;
                    background-color: var(--bg-color);
                    color: var(--text-color);
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    min-height: 100vh;
                    margin: 0;
                }}
                .container {{
                    background-color: var(--card-bg);
                    padding: 2rem;
                    border-radius: 1rem;
                    box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3);
                    width: 100%;
                    max-width: 450px;
                    border: 1px solid var(--border-color);
                    box-sizing: border-box;
                }}
                h1 {{
                    font-size: 1.5rem;
                    margin-bottom: 1.5rem;
                    text-align: center;
                    color: #38bdf8;
                }}
                .field-group {{
                    margin-bottom: 1rem;
                }}
                label {{
                    display: block;
                    font-size: 0.875rem;
                    margin-bottom: 0.3rem;
                    color: #94a3b8;
                }}
                input, select {{
                    width: 100%;
                    padding: 0.75rem;
                    border-radius: 0.5rem;
                    border: 1px solid var(--border-color);
                    background-color: #0f172a;
                    color: white;
                    font-size: 1rem;
                    box-sizing: border-box;
                }}
                button {{
                    width: 100%;
                    padding: 0.75rem;
                    border: none;
                    border-radius: 0.5rem;
                    background-color: var(--accent-color);
                    color: #ffffff;
                    font-weight: bold;
                    font-size: 1rem;
                    cursor: pointer;
                    transition: background-color 0.2s;
                    margin-top: 1rem;
                }}
                button:hover {{
                    background-color: var(--accent-hover);
                }}
                .result {{
                    margin-top: 1rem;
                    padding: 0.75rem;
                    background-color: #0f172a;
                    border-radius: 0.5rem;
                    text-align: center;
                    font-weight: 500;
                    border: 1px solid var(--border-color);
                    color: {result_color};
                    font-size: 0.9rem;
                }}
                .hint {{
                    text-align: center;
                    font-size: 0.8rem;
                    color: #38bdf8;
                    font-style: italic;
                    margin-bottom: 1.2rem;
                }}
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🧊 CubeCooler v1.4</h1>
                <div class="hint">Leave exactly ONE field blank to auto-solve it.</div>
                
                <form method="GET">
                    <div class="field-group">
                        <label>Water Volume (L)</label>
                        <input type="number" step="any" name="water_vol" value="{water_vol}" placeholder="e.g. 2.0">
                    </div>
                    <div class="field-group">
                        <label>Initial Temp (°C)</label>
                        <input type="number" step="any" name="init_temp" value="{init_temp}" placeholder="e.g. 25.0">
                    </div>
                    <div class="field-group">
                        <label>Final Temp (°C)</label>
                        <input type="number" step="any" name="final_temp" value="{final_temp}" placeholder="e.g. 5.0">
                    </div>
                    <div class="field-group">
                        <label>Ice Weight (g)</label>
                        <input type="number" step="any" name="ice_weight" value="{ice_weight}" placeholder="e.g. 150">
                    </div>
                    <div class="field-group">
                        <label>Container Type</label>
                        <select name="container">
                            <option value="1.15" {'selected' if container == '1.15' else ''}>Thin Plastic (~1.15)</option>
                            <option value="1.05" {'selected' if container == '1.05' else ''}>Standard Metal (~1.05)</option>
                            <option value="1.00" {'selected' if container == '1.00' else ''}>Vacuum Sealed (~1.00)</option>
                        </select>
                    </div>
                    
                    <button type="submit">Calculate Missing Field</button>
                </form>
                
                {f'<div class="result">{result_msg}</div>' if result_msg else ''}
            </div>
        </body>
        </html>
        """
        self.wfile.write(html.encode("utf-8"))

with socketserver.TCPServer(("", PORT), CubeCoolerHandler) as httpd:
    httpd.serve_forever()
EOF
}

create_app

PI_IP=$(hostname -I | awk '{print $1}')
[ -z "$PI_IP" ] && PI_IP="127.0.0.1"

while true; do
    clear
    echo "=================================================="
    echo "           CUBE COOLER v1.4 MANAGEMENT            "
    echo "=================================================="
    echo " Web URL: http://$PI_IP:$PORT"
    echo "--------------------------------------------------"
    echo " [1] Start Server (Interactive / Foreground)"
    echo " [2] Enable Always-On (Cron + Start Immediately)"
    echo " [3] Disable Always-On (Remove Cron Job)"
    echo " [4] Uninstall / Delete All Traces"
    echo " [5] Exit Menu"
    echo "=================================================="
    read -p "Select an option [1-5]: " choice

    case $choice in
        1)
            echo "Starting server on port $PORT. Press Ctrl+C to exit."
            python3 "$PYTHON_APP_PATH"
            ;;
        2)
            # Add to crontab if not already present
            CRON_CMD="@reboot python3 $PYTHON_APP_PATH &"
            (crontab -l 2>/dev/null | grep -v -F "$PYTHON_APP_PATH"; echo "$CRON_CMD") | crontab -
            
            # Start immediately in the background if not already running
            if ! fuser -s ${PORT}/tcp 2>/dev/null; then
                python3 "$PYTHON_APP_PATH" &
                echo "Success: Cron job added AND server started immediately in the background!"
            else
                echo "Success: Cron job added (Server was already running)."
            fi
            read -p "Press Enter to continue..."
            ;;
        3)
            # Remove from crontab
            (crontab -l 2>/dev/null | grep -v -F "$PYTHON_APP_PATH") | crontab -
            echo "Success: Always-on cron job disabled."
            read -p "Press Enter to continue..."
            ;;
        4)
            # Stop any running process on port, remove cron, delete script
            fuser -k ${PORT}/tcp &>/dev/null
            (crontab -l 2>/dev/null | grep -v -F "$PYTHON_APP_PATH") | crontab -
            rm -f "$PYTHON_APP_PATH"
            echo "Success: All traces of CubeCooler v1.4 have been removed."
            exit 0
            ;;
        5)
            echo "Exiting menu."
            exit 0
            ;;
        *)
            echo "Invalid option. Please choose between 1 and 5."
            sleep 2
            ;;
    esac
done
import socketserver
import urllib.parse

PORT = 8081

class CubeCoolerHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        
        parsed_path = urllib.parse.urlparse(self.path)
        query_params = urllib.parse.parse_qs(parsed_path.query)
        
        water_vol = query_params.get("water_vol", [""])[0]
        init_temp = query_params.get("init_temp", [""])[0]
        final_temp = query_params.get("final_temp", [""])[0]
        ice_weight = query_params.get("ice_weight", [""])[0]
        container = query_params.get("container", ["1.15"])[0]
        
        result_msg = ""
        result_color = "#38bdf8"
        
        if any([water_vol, init_temp, final_temp, ice_weight]):
            try:
                eff = float(container)
                fields = {
                    "water_vol": water_vol,
                    "init_temp": init_temp,
                    "final_temp": final_temp,
                    "ice_weight": ice_weight
                }
                
                empty_keys = [k for k, v in fields.items() if not v]
                
                if len(empty_keys) != 1:
                    result_msg = "Error: Please leave exactly ONE field blank to auto-solve it."
                    result_color = "#f43f5e"
                else:
                    empty_key = empty_keys[0]
                    data = {k: float(v) for k, v in fields.items() if v}
                    
                    if empty_key == "final_temp":
                        v = data["water_vol"] * 1000.0
                        ti = data["init_temp"]
                        m_ice = data["ice_weight"]
                        numerator = (v * 4.184 * ti) - (m_ice * 334.0 * eff)
                        denominator = (v * 4.184) + (m_ice * 4.184 * eff)
                        tf = numerator / denominator
                        final_temp = f"{tf:.2f}"
                        result_msg = f"Successfully solved Final Temperature: {final_temp} °C"
                        result_color = "#34d399"
                        
                    elif empty_key == "ice_weight":
                        v = data["water_vol"] * 1000.0
                        ti = data["init_temp"]
                        tf = data["final_temp"]
                        if tf >= ti:
                            result_msg = "Error: Final temp must be lower than initial temp."
                            result_color = "#f43f5e"
                        else:
                            target_drop = ti - tf
                            heat_to_remove = v * 4.184 * target_drop * eff
                            energy_per_g_ice = 334.0 + (4.184 * max(0.0, tf))
                            m_ice = heat_to_remove / energy_per_g_ice
                            ice_weight = f"{m_ice:.2f}"
                            result_msg = f"Successfully solved Ice Weight: {ice_weight} g"
                            result_color = "#34d399"
                            
                    elif empty_key == "water_vol":
                        ti = data["init_temp"]
                        tf = data["final_temp"]
                        m_ice = data["ice_weight"]
                        target_drop = ti - tf
                        energy_gained = m_ice * (334.0 + (4.184 * max(0.0, tf)))
                        water_mass_g = energy_gained / (4.184 * target_drop * eff)
                        v = water_mass_g / 1000.0
                        water_vol = f"{v:.2f}"
                        result_msg = f"Successfully solved Water Volume: {water_vol} L"
                        result_color = "#34d399"
                        
                    elif empty_key == "init_temp":
                        v = data["water_vol"] * 1000.0
                        tf = data["final_temp"]
                        m_ice = data["ice_weight"]
                        energy_gained = m_ice * (334.0 + (4.184 * max(0.0, tf)))
                        heat_needed = energy_gained * eff
                        delta_t = heat_needed / (v * 4.184)
                        ti = tf + delta_t
                        init_temp = f"{ti:.2f}"
                        result_msg = f"Successfully solved Initial Temperature: {init_temp} °C"
                        result_color = "#34d399"
                        
            except Exception as e:
                result_msg = f"Calculation Error: {str(e)}"
                result_color = "#f43f5e"

        html = f"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>CubeCooler v1.4 - Thermal Equilibrium Engine</title>
            <style>
                :root {{
                    --bg-color: #0f172a;
                    --card-bg: #1e293b;
                    --text-color: #f8fafc;
                    --accent-color: #3b82f6;
                    --accent-hover: #2563eb;
                    --border-color: #334155;
                }}
                body {{
                    font-family: system-ui, -apple-system, sans-serif;
                    background-color: var(--bg-color);
                    color: var(--text-color);
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    min-height: 100vh;
                    margin: 0;
                }}
                .container {{
                    background-color: var(--card-bg);
                    padding: 2rem;
                    border-radius: 1rem;
                    box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.3);
                    width: 100%;
                    max-width: 450px;
                    border: 1px solid var(--border-color);
                    box-sizing: border-box;
                }}
                h1 {{
                    font-size: 1.5rem;
                    margin-bottom: 1.5rem;
                    text-align: center;
                    color: #38bdf8;
                }}
                .field-group {{
                    margin-bottom: 1rem;
                }}
                label {{
                    display: block;
                    font-size: 0.875rem;
                    margin-bottom: 0.3rem;
                    color: #94a3b8;
                }}
                input, select {{
                    width: 100%;
                    padding: 0.75rem;
                    border-radius: 0.5rem;
                    border: 1px solid var(--border-color);
                    background-color: #0f172a;
                    color: white;
                    font-size: 1rem;
                    box-sizing: border-box;
                }}
                button {{
                    width: 100%;
                    padding: 0.75rem;
                    border: none;
                    border-radius: 0.5rem;
                    background-color: var(--accent-color);
                    color: #ffffff;
                    font-weight: bold;
                    font-size: 1rem;
                    cursor: pointer;
                    transition: background-color 0.2s;
                    margin-top: 1rem;
                }}
                button:hover {{
                    background-color: var(--accent-hover);
                }}
                .result {{
                    margin-top: 1rem;
                    padding: 0.75rem;
                    background-color: #0f172a;
                    border-radius: 0.5rem;
                    text-align: center;
                    font-weight: 500;
                    border: 1px solid var(--border-color);
                    color: {result_color};
                    font-size: 0.9rem;
                }}
                .hint {{
                    text-align: center;
                    font-size: 0.8rem;
                    color: #38bdf8;
                    font-style: italic;
                    margin-bottom: 1.2rem;
                }}
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🧊 CubeCooler v1.4</h1>
                <div class="hint">Leave exactly ONE field blank to auto-solve it.</div>
                
                <form method="GET">
                    <div class="field-group">
                        <label>Water Volume (L)</label>
                        <input type="number" step="any" name="water_vol" value="{water_vol}" placeholder="e.g. 2.0">
                    </div>
                    <div class="field-group">
                        <label>Initial Temp (°C)</label>
                        <input type="number" step="any" name="init_temp" value="{init_temp}" placeholder="e.g. 25.0">
                    </div>
                    <div class="field-group">
                        <label>Final Temp (°C)</label>
                        <input type="number" step="any" name="final_temp" value="{final_temp}" placeholder="e.g. 5.0">
                    </div>
                    <div class="field-group">
                        <label>Ice Weight (g)</label>
                        <input type="number" step="any" name="ice_weight" value="{ice_weight}" placeholder="e.g. 150">
                    </div>
                    <div class="field-group">
                        <label>Container Type</label>
                        <select name="container">
                            <option value="1.15" {'selected' if container == '1.15' else ''}>Thin Plastic (~1.15)</option>
                            <option value="1.05" {'selected' if container == '1.05' else ''}>Standard Metal (~1.05)</option>
                            <option value="1.00" {'selected' if container == '1.00' else ''}>Vacuum Sealed (~1.00)</option>
                        </select>
                    </div>
                    
                    <button type="submit">Calculate Missing Field</button>
                </form>
                
                {f'<div class="result">{result_msg}</div>' if result_msg else ''}
            </div>
        </body>
        </html>
        """
        self.wfile.write(html.encode("utf-8"))

with socketserver.TCPServer(("", PORT), CubeCoolerHandler) as httpd:
    httpd.serve_forever()
EOF
}

create_app

PI_IP=$(hostname -I | awk '{print $1}')
[ -z "$PI_IP" ] && PI_IP="127.0.0.1"

while true; do
    clear
    echo "=================================================="
    echo "           CUBE COOLER v1.4 MANAGEMENT            "
    echo "=================================================="
    echo " Web URL: http://$PI_IP:$PORT"
    echo "--------------------------------------------------"
    echo " [1] Start Server (Interactive / Foreground)"
    echo " [2] Enable Always-On (Add @reboot Cron Job)"
    echo " [3] Disable Always-On (Remove Cron Job)"
    echo " [4] Uninstall / Delete All Traces"
    echo " [5] Exit Menu"
    echo "=================================================="
    read -p "Select an option [1-5]: " choice

    case $choice in
        1)
            echo "Starting server on port $PORT. Press Ctrl+C to exit."
            python3 "$PYTHON_APP_PATH"
            ;;
        2)
            # Add to crontab if not already present
            CRON_CMD="@reboot python3 $PYTHON_APP_PATH &"
            (crontab -l 2>/dev/null | grep -v -F "$PYTHON_APP_PATH"; echo "$CRON_CMD") | crontab -
            echo "Success: Always-on cron job enabled! It will start automatically on reboot."
            read -p "Press Enter to continue..."
            ;;
        3)
            # Remove from crontab
            (crontab -l 2>/dev/null | grep -v -F "$PYTHON_APP_PATH") | crontab -
            echo "Success: Always-on cron job disabled."
            read -p "Press Enter to continue..."
            ;;
        4)
            # Stop any running process on port, remove cron, delete script
            fuser -k ${PORT}/tcp &>/dev/null
            (crontab -l 2>/dev/null | grep -v -F "$PYTHON_APP_PATH") | crontab -
            rm -f "$PYTHON_APP_PATH"
            echo "Success: All traces of CubeCooler v1.4 have been removed."
            exit 0
            ;;
        5)
            echo "Exiting menu."
            exit 0
            ;;
        *)
            echo "Invalid option. Please choose between 1 and 5."
            sleep 2
            ;;
    esac
done
