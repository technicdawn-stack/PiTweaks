#!/bin/bash

# Description: Interactive Caddyfile Configuration Manager & Syntax Validator V1.4
# PERSISTENT: FALSE
# Category: Administration

CADDYFILE_PATH="/etc/caddy/Caddyfile"
BACKUP_DIR="/etc/caddy/backups"
GLOBAL_COMMAND_PATH="/usr/local/bin/caddy-edit"

# Ensure backup directory exists (using sudo if not root)
if [ "$EUID" -ne 0 ]; then
    sudo mkdir -p "$BACKUP_DIR"
else
    mkdir -p "$BACKUP_DIR"
fi

# Install global shortcut command to /usr/local/bin using sudo if needed
install_global_command() {
    local script_path
    script_path="$(realpath "$0")"
    
    if [ "$EUID" -ne 0 ]; then
        sudo cp "$script_path" "$GLOBAL_COMMAND_PATH"
        sudo chmod +x "$GLOBAL_COMMAND_PATH"
    else
        cp "$script_path" "$GLOBAL_COMMAND_PATH"
        chmod +x "$GLOBAL_COMMAND_PATH"
    fi
    
    echo "--------------------------------------------------"
    echo "SUCCESS: Global command installed!"
    echo "Command Name: caddy-edit"
    echo "Location:     $GLOBAL_COMMAND_PATH"
    echo "You can now run 'sudo caddy-edit' from anywhere."
    echo "--------------------------------------------------"
}

install_global_command

# Function to validate Caddyfile syntax
validate_caddyfile() {
    local test_file="$1"
    if command -v caddy &>/dev/null; then
        if sudo caddy validate --config "$test_file" &>/dev/null; then
            return 0
        else
            return 1
        fi
    else
        local open_braces=$(grep -o "{" "$test_file" | wc -l)
        local close_braces=$(grep -o "}" "$test_file" | wc -l)
        if [ "$open_braces" -eq "$close_braces" ]; then
            return 0
        else
            return 1
        fi
    fi
}

# Function to add a new site block with modifiers
add_site_block() {
    clear
    echo "=================================================="
    echo "          ADD NEW CADDY SITE CONFIGURATION        "
    echo "=================================================="
    read -p "Enter domain or address (e.g., mysite.local or 192.168.1.50:80): " site_domain
    [ -z "$site_domain" ] && { echo "Domain cannot be empty."; sleep 2; return; }

    read -p "Enter backend destination (e.g., localhost:8081): " backend_dest
    [ -z "$backend_dest" ] && { echo "Backend destination cannot be empty."; sleep 2; return; }

    echo "Select security / TLS modifier:"
    echo " [1] Standard / Auto-TLS (Default)"
    echo " [2] Internal TLS (tls internal - great for local home labs)"
    echo " [3] None / Plain HTTP"
    read -p "Select option [1-3]: " tls_choice

    local tls_modifier=""
    case $tls_choice in
        2) tls_modifier="    tls internal" ;;
        3) tls_modifier="" ;;
        *) tls_modifier="" ;;
    esac

    read -p "Enable reverse proxy buffering or custom headers? (y/N): " extra_mod
    local extra_config=""
    if [[ "$extra_mod" =~ ^[Yy]$ ]]; then
        echo " [1] Add header X-Forwarded-Proto"
        echo " [2] Skip log access for this site"
        read -p "Select modifier: " mod_sub
        if [ "$mod_sub" = "1" ]; then
            extra_config="    header_up X-Forwarded-Proto {scheme}"
        elif [ "$mod_sub" = "2" ]; then
            extra_config="    log { output discard }"
        fi
    fi

    local temp_block="\n$site_domain {\n    reverse_proxy $backend_dest\n"
    [ -n "$tls_modifier" ] && temp_block+="$tls_modifier\n"
    [ -n "$extra_config" ] && temp_block+="$extra_config\n"
    temp_block+="}\n"

    local tmp_test="/tmp/Caddyfile.test"
    sudo cp "$CADDYFILE_PATH" "$tmp_test"
    echo -e "$temp_block" | sudo tee -a "$tmp_test" > /dev/null

    if validate_caddyfile "$tmp_test"; then
        sudo cp "$tmp_test" "$CADDYFILE_PATH"
        rm -f "$tmp_test"
        echo "Success: Site block added and validated successfully!"
        prompt_restart_caddy
    else
        rm -f "$tmp_test"
        echo "Error: Configuration validation failed! Block was not added."
        sleep 3
    fi
}

# Function to remove an existing site block
remove_site_block() {
    if [ ! -f "$CADDYFILE_PATH" ]; then
        echo "Caddyfile not found at $CADDYFILE_PATH"
        sleep 2
        return
    fi

    clear
    echo "=================================================="
    echo "         REMOVE EXISTING CADDY SITE BLOCK         "
    echo "=================================================="
    echo "Current Caddyfile contents preview:"
    echo "--------------------------------------------------"
    sudo cat "$CADDYFILE_PATH"
    echo "--------------------------------------------------"
    read -p "Enter the exact domain line to remove (e.g., mysite.local): " target_domain

    if [ -z "$target_domain" ]; then
        return
    fi

    sudo cp "$CADDYFILE_PATH" "$BACKUP_DIR/Caddyfile.bak.$(date +%s)"

    sudo awk -v target="$target_domain" '
        $1 == target { skipping=1; next }
        skipping && /^}/ { skipping=0; next }
        !skipping { print }
    ' "$CADDYFILE_PATH" | sudo tee /tmp/Caddyfile.new > /dev/null

    if validate_caddyfile "/tmp/Caddyfile.new"; then
        sudo mv /tmp/Caddyfile.new "$CADDYFILE_PATH"
        echo "Success: Site block removed and configuration verified!"
        prompt_restart_caddy
    else
        rm -f /tmp/Caddyfile.new
        echo "Error: Resulting configuration failed syntax validation. Reverting."
        sleep 3
    fi
}

# Prompt to restart Caddy service
prompt_restart_caddy() {
    read -p "Would you like to restart Caddy now to apply changes? (y/N): " restart_choice
    if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
        if sudo systemctl restart caddy; then
            echo "Caddy service restarted successfully."
        else
            echo "Error: Failed to restart Caddy service. Check journalctl -u caddy."
        fi
    fi
    read -p "Press Enter to continue..."
}

# Main interactive loop
while true; do
    clear
    echo "=================================================="
    echo "        CADDY CONFIGURATION MANAGER (caddy-edit)   "
    echo "=================================================="
    echo " Active Config: $CADDYFILE_PATH"
    echo "--------------------------------------------------"
    echo " [1] View Current Caddyfile"
    echo " [2] Add New Site Block (with Modifiers & Validation)"
    echo " [3] Remove Existing Site Block"
    echo " [4] Validate Current Caddyfile Syntax"
    echo " [5] Restart Caddy Service"
    echo " [6] Exit"
    echo "=================================================="
    read -p "Select an option [1-6]: " main_choice

    case $main_choice in
        1)
            clear
            echo "--- Caddyfile Contents ---"
            sudo cat "$CADDYFILE_PATH"
            echo "--------------------------"
            read -p "Press Enter to continue..."
            ;;
        2)
            add_site_block
            ;;
        3)
            remove_site_block
            ;;
        4)
            if validate_caddyfile "$CADDYFILE_PATH"; then
                echo "Success: Caddyfile syntax is valid!"
            else
                echo "Error: Syntax error detected in Caddyfile."
            fi
            read -p "Press Enter to continue..."
            ;;
        5)
            sudo systemctl restart caddy && echo "Caddy restarted." || echo "Restart failed."
            read -p "Press Enter to continue..."
            ;;
        6)
            echo "Exiting caddy-edit."
            exit 0
            ;;
        *)
            echo "Invalid option. Please choose between 1 and 6."
            sleep 2
            ;;
    esac
done
