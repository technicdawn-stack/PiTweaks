#!/bin/bash

# Description: HomeLab Subnet & IP Calculator Management Console with Systemd Service Control
# PERSISTENT: FALSE
# Category: Webpages

APP_DIR="/home/$(whoami)"
PYTHON_APP_PATH="$APP_DIR/SubnetCalc.py"
SERVICE_PATH="/etc/systemd/system/subnetcalc.service"
CURRENT_USER=$(whoami)
PORT=8082

# Ensure Python app script exists on disk persistently with IP calculations and conflict checking
create_app() {
    cat << 'EOF' > "$PYTHON_APP_PATH"
import http.server
import socketserver
import urllib.parse
import ipaddress

PORT = 8082

class SubnetCalculatorHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        
        parsed_path = urllib.parse.urlparse(self.path)
        query_params = urllib.parse.parse_qs(parsed_path.query)
        
        cidr_input = query_params.get("cidr", [""])[0].strip()
        check_ip = query_params.get("check_ip", [""])[0].strip()
        
        result_html = ""
        
        if cidr_input:
            try:
                network = ipaddress.ip_network(cidr_input, strict=False)
                netmask = network.netmask
                broadcast = network.broadcast_address
                total_hosts = network.num_addresses
                hosts = list(network.hosts())
                
                if hosts:
                    first_host = hosts[0]
                    last_host = hosts[-1]
                    usable_count = len(hosts)
                else:
                    first_host = "N/A (Host-only or Broadcast)"
                    last_host = "N/A"
                    usable_count = 0
                
                conflict_msg = ""
                conflict_color = "#34d399"
                if check_ip:
                    try:
                        target = ipaddress.ip_address(check_ip)
                        if target in network:
                            conflict_msg = f"Target IP {check_ip} is INSIDE this subnet range."
                            conflict_color = "#f43f5e"
                        else:
                            conflict_msg = f"Target IP {check_ip} is OUTSIDE this subnet range (No conflict)."
                    except ValueError:
                        conflict_msg = "Invalid IP address provided for conflict check."
                        conflict_color = "#f43f5e"

                result_html = f"""
                <div class="result-box">
                    <h3>Subnet Details for {network}</h3>
                    <p><strong>Netmask:</strong> {netmask}</p>
                    <p><strong>Broadcast Address:</strong> {broadcast}</p>
                    <p><strong>Total Addresses:</strong> {total_hosts}</p>
                    <p><strong>Usable Host Range:</strong> {first_host} - {last_host} ({usable_count} usable)</p>
                    {f'<div class="conflict" style="color: {conflict_color};">{conflict_msg}</div>' if check_ip else ''}
                </div>
                """
            except Exception as e:
                result_html = f'<div class="result-box error">Error parsing CIDR: {str(e)}</div>'

        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>HomeLab CIDR & Subnet Calculator</title>
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
            max-width: 480px;
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
        input {{
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
        .result-box {{
            margin-top: 1.5rem;
            padding: 1rem;
            background-color: #0f172a;
            border-radius: 0.5rem;
            border: 1px solid var(--border-color);
            font-size: 0.9rem;
        }}
        .result-box h3 {{
            margin-top: 0;
            color: #38bdf8;
            font-size: 1rem;
        }}
        .conflict {{
            margin-top: 0.75rem;
            font-weight: bold;
        }}
        .error {{
            color: #f43f5e;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>🌐 Subnet & IP Calculator</h1>
        <form method="GET">
            <div class="field-group">
                <label>CIDR Network (e.g. 192.168.1.0/24)</label>
                <input type="text" name="cidr" value="{cidr_input}" placeholder="192.168.1.0/24">
            </div>
            <div class="field-group">
                <label>Check IP Conflict / Membership (Optional)</label>
                <input type="text" name="check_ip" value="{check_ip}" placeholder="192.168.1.50">
            </div>
            <button type="submit">Calculate & Verify</button>
        </form>
        {result_html}
    </div>
</body>
</html>"""
        self.wfile.write(html.encode("utf-8"))

with socketserver.TCPServer(("", PORT), SubnetCalculatorHandler) as httpd:
    httpd.allow_reuse_address = True
    httpd.serve_forever()
EOF
}

create_app

PI_IP=$(hostname -I | awk '{print $1}')
[ -z "$PI_IP" ] && PI_IP="127.0.0.1"

while true; do
    clear
    echo "=================================================="
    echo "       SUBNET CALCULATOR v1.0 MANAGEMENT        "
    echo "=================================================="
    echo " Web URL: http://$PI_IP:$PORT"
    echo "--------------------------------------------------"
    echo " [1] Start Server (Interactive / Foreground)"
    echo " [2] Enable Always-On (Systemd Service + Start)"
    echo " [3] Disable Always-On (Stop & Remove Service)"
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
            sudo bash -c "cat << 'EOT' > $SERVICE_PATH
[Unit]
Description=Subnet Calculator Web Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/usr/bin/python3 $PYTHON_APP_PATH
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOT"
            sudo systemctl daemon-reload
            sudo systemctl enable subnetcalc.service
            sudo systemctl restart subnetcalc.service
            echo "Success: Systemd service enabled and started!"
            read -p "Press Enter to continue..."
            ;;
        3)
            sudo systemctl stop subnetcalc.service &>/dev/null
            sudo systemctl disable subnetcalc.service &>/dev/null
            sudo rm -f "$SERVICE_PATH"
            sudo systemctl daemon-reload
            echo "Success: Always-on systemd service disabled and removed."
            read -p "Press Enter to continue..."
            ;;
        4)
            sudo systemctl stop subnetcalc.service &>/dev/null
            sudo systemctl disable subnetcalc.service &>/dev/null
            sudo rm -f "$SERVICE_PATH"
            sudo systemctl daemon-reload
            fuser -k ${PORT}/tcp &>/dev/null
            rm -f "$PYTHON_APP_PATH"
            echo "Success: All traces of Subnet Calculator have been removed."
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
