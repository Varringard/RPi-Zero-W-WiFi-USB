#!/bin/bash

# Configuration Variables
USB_FILE_SIZE_MB=8192  # 8 ГБ — измените при необходимости
REQUIRED_SPACE_MB=$((USB_FILE_SIZE_MB + 1024))
MOUNT_FOLDER="/mnt/usb_share"

# Known compatible hardware models
COMPATIBLE_MODELS=("Raspberry Pi Zero W Rev 1.1" "Raspberry Pi Zero 2 W Rev 1.0")
HARDWARE_MODEL=$(cat /proc/device-tree/model)

is_model_compatible() {
    for model in "${COMPATIBLE_MODELS[@]}"; do
        if [[ "$model" == "$1" ]]; then
            return 0
        fi
    done
    return 1
}

if is_model_compatible "$HARDWARE_MODEL"; then
    echo "Detected compatible hardware: $HARDWARE_MODEL"
else
    echo "Detected hardware: $HARDWARE_MODEL"
    echo "This model is not officially tested. Continue? (y/n)"
    read -r choice
    [[ ! "$choice" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 1; }
fi

# Install packages
echo "📦 Installing required packages..."
sudo apt update && sudo apt install -y samba winbind python3 python3-watchdog
[[ $? -ne 0 ]] && { echo "Failed to install packages."; exit 1; }

# Determine boot dir
BOOT_DIR="/boot"
[[ -d "/boot/firmware" ]] && BOOT_DIR="/boot/firmware"

# Enable dwc2
grep -q "dtoverlay=dwc2" "$BOOT_DIR/config.txt" || echo "dtoverlay=dwc2" | sudo tee -a "$BOOT_DIR/config.txt" >/dev/null
grep -q "^dwc2$" /etc/modules || echo "dwc2" | sudo tee -a /etc/modules >/dev/null

# Disable Wi-Fi power saving (optional but recommended)
sudo iw wlan0 set power_save off 2>/dev/null || true

# Create USB image if not exists
if [[ ! -f /piusb.bin ]]; then
    echo "💾 Creating $((USB_FILE_SIZE_MB / 1024)) GB USB image..."
    AVAILABLE_MB=$(( $(df --output=avail / | tail -1) / 1024 ))
    if [[ $AVAILABLE_MB -lt $REQUIRED_SPACE_MB ]]; then
        echo "⚠️ Not enough space. Available: ${AVAILABLE_MB} MB, Required: ${REQUIRED_SPACE_MB} MB"
        exit 1
    fi
    sudo dd bs=1M if=/dev/zero of=/piusb.bin count="$USB_FILE_SIZE_MB" status=progress
    sudo mkdosfs /piusb.bin -F 32 -I
fi

# Mount point
sudo mkdir -p "$MOUNT_FOLDER"
sudo chmod 777 "$MOUNT_FOLDER"

# Add to fstab (only if not present)
grep -q "/piusb.bin.*$MOUNT_FOLDER" /etc/fstab || echo "/piusb.bin $MOUNT_FOLDER vfat users,umask=000 0 2" | sudo tee -a /etc/fstab >/dev/null
sudo mount -a

# Configure Samba
cat <<'EOF' | sudo tee -a /etc/samba/smb.conf >/dev/null

[usb]
    browseable = yes
    path = /mnt/usb_share
    guest ok = yes
    read only = no
    create mask = 777
    directory mask = 777
EOF

sudo systemctl restart smbd

# Create watchdog script
cat <<'EOF' | sudo tee /usr/local/share/usbshare.py >/dev/null
#!/usr/bin/python3
import time
import os
import subprocess
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

CMD_UNMOUNT = "modprobe -r g_mass_storage"
CMD_MOUNT   = "modprobe g_mass_storage file=/piusb.bin stall=0 removable=y"
WATCH_PATH  = "/mnt/usb_share"
TIMEOUT     = 5

class Handler(FileSystemEventHandler):
    def __init__(self):
        self.dirty = False
        self.last_event = 0

    def on_any_event(self, event):
        if not event.is_directory:
            self.dirty = True
            self.last_event = time.time()

def run_cmd(cmd):
    subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

event_handler = Handler()
observer = Observer()
observer.schedule(event_handler, path=WATCH_PATH, recursive=False)
observer.start()

# Initial mount
run_cmd(CMD_MOUNT)

try:
    while True:
        if event_handler.dirty and (time.time() - event_handler.last_event) >= TIMEOUT:
            run_cmd(CMD_UNMOUNT)
            time.sleep(1)
            run_cmd("sync")
            time.sleep(1)
            run_cmd(CMD_MOUNT)
            event_handler.dirty = False
        time.sleep(1)
except KeyboardInterrupt:
    observer.stop()
observer.join()
EOF

sudo chmod +x /usr/local/share/usbshare.py

# Create systemd service
cat <<'EOF' | sudo tee /etc/systemd/system/usbshare.service >/dev/null
[Unit]
Description=USB Mass Storage Watchdog
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/share/usbshare.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now usbshare.service

echo
echo "✅ Setup complete!"
echo "• USB Mass Storage: enabled (no Ethernet/RNDIS)"
echo "• Samba share: \\\\$(hostname).local\\usb"
echo "• Image: /piusb.bin (8 GB FAT32)"
echo
echo "🔌 Connect Pi to dermatoscope via RIGHT microUSB port."
echo "💻 Access files from PC via Samba share."
echo
read -p "Reboot now? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo reboot
fi
