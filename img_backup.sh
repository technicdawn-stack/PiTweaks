#!/bin/bash
# Description: Modular Pi Imager Utility with Dynamic USB Detection and Network Streaming V1.3
# PERSISTENT: FALSE

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# Step 1: Initial Confirmation TUI
if ! whiptail --title "PiTweaks Cloner" --yesno "Are you sure you want to clone this Raspberry Pi?" 10 60; then
    echo "❌ Backup cancelled."
    exit 0
fi

# Step 2: Choose Destination Type
DEST_TYPE=$(whiptail --title "Select Backup Destination" --menu "Choose where to save the backup image:" 15 60 2 \
    "1" "USB Drive / External SD (Dynamic List)" \
    "2" "Network Stream (PC / Remote Server)" 3>&1 1>&2 2>&3)

[ $? -ne 0 ] && { echo "❌ Cancelled."; exit 0; }

# Determine Root Device Dynamically
ROOT_DEV=$(findmnt / -o source -n | sed 's/[0-9]//g')
[ -z "$ROOT_DEV" ] && ROOT_DEV="/dev/mmcblk0"

# --- OPTION 1: USB / EXTERNAL DRIVE (DYNAMIC) ---
if [ "$DEST_TYPE" = "1" ]; then
    # Scan for available drives (excluding the main boot drive)
    DRIVE_LIST=()
    while read -r name size mountpoint; do
        if [[ "/dev/$name" != "$ROOT_DEV" ]]; then
            DRIVE_LIST+=("/dev/$name" "Size: $size [Mounted: ${mountpoint:-Not Mounted}]")
        fi
    done < <(lsblk -dpn -o NAME,SIZE,MOUNTPOINT | grep -v "loop" | awk '{print $1, $2, $3}')

    if [ ${#DRIVE_LIST[@]} -eq 0 ]; then
        whiptail --title "Error" --msgbox "No external USB drives or SD cards detected!" 10 60
        exit 1
    fi

    SELECTED_DRIVE=$(whiptail --title "Select Target Drive" --menu "Choose destination drive for image:" 15 70 6 \
        "${DRIVE_LIST[@]}" 3>&1 1>&2 2>&3)
    
    [ $? -ne 0 ] && exit 0

    # Auto-mount or locate mount point
    TARGET_DIR=$(lsblk -no MOUNTPOINT "$SELECTED_DRIVE" | head -n 1)
    if [ -z "$TARGET_DIR" ]; then
        TARGET_DIR="/mnt/pi_backup_usb"
        mkdir -p "$TARGET_DIR"
        mount "$SELECTED_DRIVE" "$TARGET_DIR" || {
            whiptail --title "Error" --msgbox "Failed to mount $SELECTED_DRIVE." 10 60
            exit 1
        }
    fi

    BACKUP_FILE="$TARGET_DIR/pi_backup_$(date +%Y%m%d_%H%M%S).img"

    if ! whiptail --title "Final Confirmation" --yesno "Ready to write local image to:\n$BACKUP_FILE\n\nContinue?" 12 60; then
        exit 0
    fi

    echo "🚀 Writing local backup image to external drive..."
    dd if="$ROOT_DEV" bs=4M status=progress of="$BACKUP_FILE"
    sync
    whiptail --title "Success!" --msgbox "Backup completed successfully!\nSaved to: $BACKUP_FILE" 10 60
    exit 0
fi

# --- OPTION 2: NETWORK STREAM ---
NET_MODE=$(whiptail --title "Network Configuration" --menu "Choose how to configure the remote host:" 15 60 2 \
    "1" "Automatic (Use current SSH connection client)" \
    "2" "Manual (Enter IP and username manually)" 3>&1 1>&2 2>&3)

[ $? -ne 0 ] && exit 0

if [ "$NET_MODE" = "1" ]; then
    CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    if [ -z "$CLIENT_IP" ]; then
        whiptail --title "Error" --msgbox "Could not auto-detect SSH client IP. Try Manual mode." 10 60
        exit 1
    fi
    REMOTE_USER=$(whiptail --inputbox "Enter username for remote host ($CLIENT_IP):" 10 60 "$USER" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 0
    REMOTE_HOST="$REMOTE_USER@$CLIENT_IP"
else
    REMOTE_HOST=$(whiptail --inputbox "Enter remote target (e.g., user@192.168.1.50):" 10 60 "user@192.168.1.X" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 0
fi

FILENAME="pi_backup_$(date +%Y%m%d_%H%M%S).img.gz"
REMOTE_PATH="Downloads/$FILENAME"

if ! whiptail --title "Final Confirmation" --yesno "Ready to stream compressed image over network to:\n$REMOTE_HOST:$REMOTE_PATH\n\nContinue?" 14 60; then
    exit 0
fi

echo "🚀 Streaming backup over network to $REMOTE_HOST..."
dd if="$ROOT_DEV" bs=4M status=progress | gzip -c | ssh "$REMOTE_HOST" "cat > ~/$REMOTE_PATH"

whiptail --title "Success!" --msgbox "Network backup stream complete!\nSaved to remote Downloads folder as:\n$FILENAME" 12 60
