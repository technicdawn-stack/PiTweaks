#!/bin/bash
# Description: Self-contained deployment engine for Pi-hole Teleporter Backup Manager. V1.3
# PERSISTENT: FALSE
# Category: Backup Managers

# 1. Root Privileges Check
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this installer script with sudo or as root."
  exit 1
fi

# 2. Dependency Audit and Package Fixes
echo "[+] Validating system runtime environments..."
if ! command -v whiptail &> /dev/null || ! command -v python3 &> /dev/null; then
    echo "[+] Updating apt repositories and fetching dependencies..."
    apt-get update -q && apt-get install -y whiptail python3 cron cifs-utils nfs-common
fi

TARGET_BIN="/usr/local/bin/pihole-backup-manager"

# 3. Write Embedded Python Code to Binary Directory
echo "[+] Extracting embedded automation core engine components..."
cat << 'EOF' > "$TARGET_BIN"
#!/usr/bin/env python3
import os
import sys
import json
import glob
import math
import subprocess
from datetime import datetime, timedelta

CONFIG_PATH = "/etc/pihole_backup_manager.conf"

def run_whiptail(args):
    cmd = ["whiptail"] + args
    process = subprocess.run(cmd, stderr=subprocess.PIPE, text=True)
    return process.returncode, process.stderr.strip()

def load_config():
    if not os.path.exists(CONFIG_PATH):
        return None
    try:
        with open(CONFIG_PATH, "r") as f:
            return json.load(f)
    except:
        return None

def save_config(config):
    try:
        with open(CONFIG_PATH, "w") as f:
            json.dump(config, f, indent=4)
        return True
    except Exception as e:
        run_whiptail(["--title", "Error", "--msgbox", f"Failed to save configuration:\n{str(e)}", "10", "60"])
        return False

def check_dependencies():
    missing = []
    for cmd in ["pihole", "whiptail", "cron"]:
        if subprocess.run(["which", cmd], capture_output=True).returncode != 0:
            if cmd == "cron" and subprocess.run(["which", "crontab"], capture_output=True).returncode == 0:
                continue
            missing.append(cmd)
    if missing:
        run_whiptail(["--title", "Missing Dependencies", "--msgbox", 
                      f"Required binaries missing: {', '.join(missing)}\nPlease install Pi-hole before proceeding.", "10", "60"])
        sys.exit(1)

def cron_schedule_worker(config):
    freq = config.get("frequency", "Weekly")
    hour = int(config.get("hour", "02"))
    minute = int(config.get("minute", "00"))
    
    if freq == "Daily":
        cron_time = f"{minute} {hour} * * *"
    elif freq == "Weekly":
        cron_time = f"{minute} {hour} * * 0"
    elif freq == "Monthly":
        cron_time = f"{minute} {hour} 1 * *"
    else:
        cron_time = f"{minute} {hour} * * 0"

    script_path = os.path.abspath(__file__)
    cron_job = f"{cron_time} {sys.executable} {script_path} --run-backup > /dev/null 2>&1"

    try:
        current_crontab = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
        lines = [line for line in current_crontab.splitlines() if "pihole_backup_manager" not in line and line.strip()]
        lines.append(cron_job)
        new_crontab = "\n".join(lines) + "\n"
        subprocess.run(["crontab", "-"], input=new_crontab, text=True, check=True)
        return True
    except Exception as e:
        run_whiptail(["--title", "Cron Error", "--msgbox", f"Failed to update crontab:\n{str(e)}", "10", "60"])
        return False

def browse_directories(start_dir="/mnt"):
    current_dir = os.path.abspath(start_dir)
    if not os.path.isdir(current_dir):
        current_dir = "/"

    while True:
        try:
            items = sorted(os.listdir(current_dir))
        except Exception as e:
            run_whiptail(["--title", "Access Error", "--msgbox", f"Cannot access directory:\n{str(e)}", "10", "60"])
            current_dir = "/"
            items = sorted(os.listdir(current_dir))

        menu_items = []
        if current_dir != "/":
            menu_items.extend(["..", "[ Parent Directory ]"])
        
        # Option to create a new folder directly inside the current view
        menu_items.extend(["[CREATE_NEW_DIR] 📁", "[ Create New Folder Here ]"])
        menu_items.extend(["[SELECT_THIS_DIR] 🎯", f">> Use Current Directory ({current_dir}) <<"])

        for item in items:
            full_path = os.path.join(current_dir, item)
            if os.path.isdir(full_path):
                menu_items.extend([full_path, f"[DIR]  {item}"])

        code, choice = run_whiptail([
            "--title", "Interactive Directory Browser",
            "--cancel-button", "Cancel",
            "--menu", f"Current Path: {current_dir}\nNavigate into your NAS or select 'Use Current Directory':",
            "20", "75", "10"
        ] + menu_items)

        if code != 0:
            return None

        if choice == "[SELECT_THIS_DIR] 🎯":
            return current_dir
        elif choice == "[CREATE_NEW_DIR] 📁":
            code_in, new_name = run_whiptail(["--title", "Create Folder", "--inputbox", "Enter the name for the new backup folder:", "10", "50", "pihole_backups"])
            if code_in == 0 and new_name.strip():
                new_folder_path = os.path.join(current_dir, new_name.strip())
                try:
                    os.makedirs(new_folder_path, exist_ok=True)
                    current_dir = new_folder_path
                except Exception as e:
                    run_whiptail(["--title", "Error", "--msgbox", f"Could not create directory:\n{str(e)}", "10", "60"])
            continue
        elif choice == "..":
            current_dir = os.path.dirname(current_dir)
        else:
            current_dir = choice

def detect_active_mounts():
    mounts = []
    search_bases = ["/mnt", "/media"]
    for base in search_bases:
        if os.path.isdir(base):
            for entry in os.listdir(base):
                full_path = os.path.join(base, entry)
                if os.path.ismount(full_path):
                    mounts.append(full_path)
    return mounts

def interactive_setup():
    config = load_config() or {}
    
    # 1. Detect existing mounts / NAS
    active_mounts = detect_active_mounts()
    starting_browse_dir = "/mnt"

    if active_mounts:
        mount_menu = []
        for m in active_mounts:
            mount_menu.extend([m, "Detected Storage Mount"])
        mount_menu.extend(["BROWSE_CUSTOM", "Browse manually from root root/mnt"])
        
        code, choice = run_whiptail([
            "--title", "Storage / NAS Detection",
            "--menu", "Storage mount detected! Select it to browse inside, or choose custom browse:",
            "14", "70", "4"
        ] + mount_menu)

        if code == 0 and choice != "BROWSE_CUSTOM":
            starting_browse_dir = choice

    # Launch file browser so the user can choose the exact sub-folder on the NAS (or create one)
    target_dir = browse_directories(starting_browse_dir)
    if not target_dir:
        return

    config["backup_dir"] = target_dir

    # 2. Schedule Frequency
    code, freq = run_whiptail(["--title", "Backup Schedule Frequency", "--menu", "How often should a Teleporter backup occur?", "12", "60", "3",
                               "Daily", "Execute backup every day",
                               "Weekly", "Execute backup every Sunday",
                               "Monthly", "Execute backup on the 1st of every month"])
    if code != 0: return
    config["frequency"] = freq

    # 3. Execution Time
    code, target_time = run_whiptail(["--title", "Backup Execution Time", "--inputbox", 
                                      "At what time should the backup fire off?\nFormat: HH:MM (24-hour style)", "12", "60", 
                                      f"{config.get('hour','02')}:{config.get('minute','00')}"])
    if code != 0: return
    try:
        h, m = target_time.split(":")
        config["hour"] = f"{int(h):02d}"
        config["minute"] = f"{int(m):02d}"
    except:
        config["hour"] = "02"
        config["minute"] = "00"

    # 4. Storage Retention
    code, _ = run_whiptail(["--title", "Storage Purge Feature", "--yesno", "Do you want to autoremove old backups to save disk space?", "9", "55"])
    if code == 0:
        config["purge_enabled"] = True
        # Prompt for retention count
        code_count, count = run_whiptail(["--title", "Retention Pool Size", "--inputbox", "How many total historical backups do you want to keep stored?", "9", "55", str(config.get("retention_count", 10))])
        if code_count == 0 and count.strip():
            try: 
                config["retention_count"] = max(1, int(count.strip()))
            except: 
                config["retention_count"] = 10
        else:
            config["retention_count"] = 10
    else:
        config["purge_enabled"] = False

def get_backups_list(directory, sort_newest_first=True):
    pattern = os.path.join(directory, "pi-hole-teleporter_*.tar.gz")
    files = glob.glob(pattern)
    file_data = []
    for f in files:
        stat = os.stat(f)
        file_data.append({
            "path": f,
            "name": os.path.basename(f),
            "mtime": stat.st_mtime,
            "size": f"{stat.st_size / (1024*1024):.2f} MB"
        })
    file_data.sort(key=lambda x: x["mtime"], reverse=sort_newest_first)
    return file_data

def run_backup_engine():
    config = load_config()
    if not config:
        sys.exit("Configuration missing.")
    
    backup_dir = config.get("backup_dir")
    if not os.path.isdir(backup_dir):
        sys.exit(f"Directory {backup_dir} unavailable.")
        
    os.chdir(backup_dir)
    subprocess.run(["pihole", "-a", "-t"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    if config.get("purge_enabled", False):
        retention_max = int(config.get("retention_count", 10))
        backups = get_backups_list(backup_dir, sort_newest_first=True)
        if len(backups) > retention_max:
            excess_files = backups[retention_max:]
            for f in excess_files:
                try: os.remove(f["path"])
                except: pass

def check_backup_timing():
    config = load_config()
    if not config:
        run_whiptail(["--title", "Error", "--msgbox", "No active profile found. Please run the setup wizard first.", "10", "60"])
        return

    freq = config.get("frequency", "Weekly")
    hour = int(config.get("hour", 2))
    minute = int(config.get("minute", 0))

    now = datetime.now()
    target_time = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

    if freq == "Daily":
        if now >= target_time:
            target_time += timedelta(days=1)
    elif freq == "Weekly":
        days_ahead = (6 - now.weekday()) % 7
        if days_ahead == 0 and now >= target_time:
            days_ahead = 7
        target_time += timedelta(days=days_ahead)
    elif freq == "Monthly":
        if target_time.day != 1:
            try: target_time = target_time.replace(day=1)
            except: pass
        if now >= target_time:
            if target_time.month == 12:
                target_time = target_time.replace(year=target_time.year + 1, month=1)
            else:
                target_time = target_time.replace(month=target_time.month + 1)

    delta = target_time - now
    days = delta.days
    hours = math.floor(delta.seconds / 3600)
    minutes = math.floor((delta.seconds % 3600) / 60)
    seconds = delta.seconds % 60

    if days > 0: countdown = f"[In {days} day{'s' if days > 1 else ''}]"
    elif hours > 0: countdown = f"[In {hours} hour{'s' if hours > 1 else ''}]"
    elif minutes > 0: countdown = f"[In {minutes} minute{'s' if minutes > 1 else ''}]"
    else: countdown = f"[In {seconds} second{'s' if seconds > 1 else ''}]"

    formatted_time = target_time.strftime("%H:%M:%S %d-%m-%Y")
    info_msg = (f"Active Schedule Profile: {freq}\n"
                f"Configured Run Window:  {hour:02d}:{minute:02d}:00\n\n"
                f"Next Planned Automated Execution:\n"
                f"-> {formatted_time} {countdown}")

    run_whiptail(["--title", "Backup Timing Information", "--msgbox", info_msg, "12", "70"])

def manage_backups_interface():
    config = load_config()
    if not config or not os.path.isdir(config.get("backup_dir", "")):
        run_whiptail(["--title", "Directory Missing", "--msgbox", "Backup destination mount path is invalid or unconfigured.", "10", "60"])
        return

    backup_dir = config["backup_dir"]
    sort_newest = True

    while True:
        backups = get_backups_list(backup_dir, sort_newest_first=sort_newest)
        menu_items = []
        
        toggle_label = "Switch Order: [Oldest -> Newest]" if sort_newest else "Switch Order: [Newest -> Oldest]"
        menu_items.extend(["TOGGLE_SORT", toggle_label])
        
        for index, b in enumerate(backups):
            menu_items.extend([str(index), f"[{b['size']}] {b['name']}"])
            
        msg_header = f"Storage Directory: {backup_dir}\nSelect an entry to view/delete it from storage:"
        code, choice = run_whiptail(["--title", "Saved Teleporter Backups", "--cancel-button", "Back", "--menu", msg_header, "20", "80", "10"] + menu_items)
        
        if code != 0:
            break
            
        if choice == "TOGGLE_SORT":
            sort_newest = not sort_newest
            continue
            
        selected_backup = backups[int(choice)]
        confirm_code = run_whiptail(["--title", "Confirm Deletion", "--yesno", f"Are you sure you want to permanently delete:\n{selected_backup['name']}?", "10", "60"])
        if confirm_code == 0:
            try:
                os.remove(selected_backup["path"])
                run_whiptail(["--title", "Success", "--msgbox", "File purged successfully.", "8", "50"])
            except Exception as e:
                run_whiptail(["--title", "Error", "--msgbox", f"Failed to delete file:\n{str(e)}", "10", "60"])

def trigger_manual_backup():
    config = load_config()
    if not config:
        run_whiptail(["--title", "Error", "--msgbox", "Please configure the application before executing a backup.", "10", "60"])
        return
    msg_proc = subprocess.Popen(["whiptail", "--title", "Backup In Progress", "--infobox", "\nProcessing Pi-hole Teleporter dump...\nPlease wait...", "10", "60"])
    run_backup_engine()
    msg_proc.terminate()
    run_whiptail(["--title", "Success", "--msgbox", "Teleporter backup and file retention clean up complete.", "10", "60"])

def main_menu():
    if len(sys.argv) > 1 and sys.argv[1] == "--run-backup":
        run_backup_engine()
        sys.exit(0)

    if os.getuid() != 0:
        print("[-] This interface requires root system permissions. Please run with sudo.")
        sys.exit(1)

    check_dependencies()
    while True:
        code, choice = run_whiptail([
            "--title", "Pi-hole Teleporter Backup Manager",
            "--cancel-button", "Exit",
            "--menu", "Main Interface Management Panel Options:", "16", "65", "5",
            "1", "Run Immediate Teleporter Backup Now",
            "2", "View / Delete Existing Backups",
            "3", "Check Next Scheduled Backup Timing Countdown",
            "4", "Run System Configuration / Installer Wizard",
            "5", "Remove Auto-Backup Cron Scheduling"
        ])
        if code != 0:
            sys.exit(0)
        if choice == "1":
            trigger_manual_backup()
        elif choice == "2":
            manage_backups_interface()
        elif choice == "3":
            check_backup_timing()
        elif choice == "4":
            interactive_setup()
        elif choice == "5":
            try:
                current_crontab = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
                lines = [line for line in current_crontab.splitlines() if "pihole_backup_manager" not in line and line.strip()]
                new_crontab = "\n".join(lines) + "\n" if lines else ""
                subprocess.run(["crontab", "-"], input=new_crontab, text=True, check=True)
                run_whiptail(["--title", "Cron Removed", "--msgbox", "Automated cron scheduling jobs have been cleared cleanly.", "10", "60"])
            except Exception as e:
                run_whiptail(["--title", "Failure", "--msgbox", f"Error updating cron tasks:\n{str(e)}", "10", "60"])

if __name__ == "__main__":
    main_menu()
EOF

# 4. Make Binary Executable and Launch Interactive Welcome Dashboard
chmod +x "$TARGET_BIN"
if [ -f "$TARGET_BIN" ]; then
    whiptail --title "Deployer Success" --msgbox "Components successfully installed to:\n$TARGET_BIN\n\nPress OK to drop into the setup wizard dashboard panel." 11 65
    sudo pihole-backup-manager
else
    echo "[-] System compilation exception: Could not install binary to disk."
    exit 1
fi
