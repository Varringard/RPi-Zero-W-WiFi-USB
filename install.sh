#!/usr/bin/env bash
set -euo pipefail

echo "============================================================="
echo " Настройка Raspberry Pi для дерматоскопа (интерактивная версия)"
echo "============================================================="
echo

# ──────────────────────────────────────────────────────────────
# Вопросы пользователю
# ──────────────────────────────────────────────────────────────

read -p "Обновить систему (apt update + upgrade)? [y/N]: " -n 1 -r UPDATE_SYSTEM
echo
UPDATE_SYSTEM=${UPDATE_SYSTEM:-N}
[[ $UPDATE_SYSTEM =~ ^[Yy]$ ]] && UPDATE_SYSTEM=true || UPDATE_SYSTEM=false

read -p "Сколько ГБ выделить под USB-образ? (рекомендуется 4–32, по умолчанию 8): " -r IMG_SIZE_GB
IMG_SIZE_GB=${IMG_SIZE_GB:-8}
if ! [[ "$IMG_SIZE_GB" =~ ^[0-9]+$ ]] || (( IMG_SIZE_GB < 1 )); then
    echo "Некорректный размер → использую 8 ГБ"
    IMG_SIZE_GB=8
fi

read -p "Название папки для хранения файлов на Raspberry Pi (по умолчанию: derma_share): " -r SMB_DIR_NAME
SMB_DIR_NAME=${SMB_DIR_NAME:-derma_share}
SMB_DIR="/home/pi/$SMB_DIR_NAME"

read -p "Имя сетевой шары (как будет видно в сети, например derma, photos): " -r SHARE_NAME
SHARE_NAME=${SHARE_NAME:-derma}

read -p "Сколько минут между синхронизациями? (1–60, по умолчанию 1): " -r SYNC_MINUTES
SYNC_MINUTES=${SYNC_MINUTES:-1}
if ! [[ "$SYNC_MINUTES" =~ ^[0-9]+$ ]] || (( SYNC_MINUTES < 1 )) || (( SYNC_MINUTES > 60 )); then
    echo "Некорректное значение → использую 1 минуту"
    SYNC_MINUTES=1
fi

read -s -p "Установите пароль для Samba-доступа (пользователь pi): " -r SAMBA_PASSWORD
echo
read -s -p "Повторите пароль: " -r SAMBA_PASSWORD2
echo
if [[ "$SAMBA_PASSWORD" != "$SAMBA_PASSWORD2" ]]; then
    echo "Пароли не совпадают! Завершаем."
    exit 1
fi
if [[ -z "$SAMBA_PASSWORD" ]]; then
    echo "Пароль не может быть пустым!"
    exit 1
fi

echo
echo "Настройки, которые будут применены:"
echo "• Обновление системы:          $( [[ $UPDATE_SYSTEM = true ]] && echo "Да" || echo "Нет" )"
echo "• Размер USB-образа:           ${IMG_SIZE_GB} ГБ"
echo "• Папка на Pi:                 $SMB_DIR"
echo "• Имя шары в сети:             $SHARE_NAME"
echo "• Интервал синхронизации:      каждые $SYNC_MINUTES минут"
echo "• Пароль Samba для pi:         (скрыт)"
echo
read -p "Всё верно? Продолжить? [Y/n]: " -n 1 -r CONFIRM
echo
[[ $CONFIRM =~ ^[Nn]$ ]] && { echo "Отменено."; exit 0; }

# ──────────────────────────────────────────────────────────────
# Основная настройка
# ──────────────────────────────────────────────────────────────

IMG="/home/pi/piusb.bin"
MOUNT_PT="/mnt/usb_tmp"
SYNC_SCRIPT="/home/pi/sync_from_usb.sh"
GADGET_SCRIPT="/home/pi/setup_usb_gadget.sh"

# 1. Обновление системы (если выбрано)
if $UPDATE_SYSTEM; then
    echo "📦 Обновление системы..."
    sudo apt update -qq
    sudo apt upgrade -y
fi

# 2. Установка пакетов
echo "📦 Установка необходимых пакетов..."
sudo apt install -y --no-install-recommends samba rsync dosfstools parted avahi-daemon

# 3. Включение gadget-режима
BOOT_CFG="/boot/firmware/config.txt"
[[ ! -f "$BOOT_CFG" ]] && BOOT_CFG="/boot/config.txt"

grep -q "dtoverlay=dwc2,dr_mode=peripheral" "$BOOT_CFG" || \
    echo "dtoverlay=dwc2,dr_mode=peripheral" | sudo tee -a "$BOOT_CFG" >/dev/null

# 4. Создание/пересоздание образа
if [[ -f "$IMG" ]]; then
    read -p "Образ $IMG уже существует. Пересоздать? [y/N]: " -n 1 -r RECREATE_IMG
    echo
else
    RECREATE_IMG=y
fi

if [[ $RECREATE_IMG =~ ^[Yy]$ ]]; then
    echo "💾 Создаём образ ${IMG_SIZE_GB} ГБ..."
    sudo rm -f "$IMG" 2>/dev/null || true
    sudo truncate -s "${IMG_SIZE_GB}G" "$IMG"
    sudo parted -s "$IMG" mklabel msdos
    sudo parted -s "$IMG" mkpart primary fat32 2048s 100%
    LOOP=$(sudo losetup -f --show -P "$IMG")
    sudo mkfs.vfat -F 32 -n "DERMA" "${LOOP}p1"
    sudo losetup -d "$LOOP"
    sudo chmod 666 "$IMG"
fi

# 5. Скрипт USB gadget (libcomposite)
cat <<'EOF' | sudo tee "$GADGET_SCRIPT" >/dev/null
#!/usr/bin/env bash
set -euo pipefail

modprobe libcomposite || true

GADGET_DIR="/sys/kernel/config/usb_gadget/derma_gadget"
IMG="/home/pi/piusb.bin"

[ -d "$GADGET_DIR" ] && { echo "" > "$GADGET_DIR/UDC" 2>/dev/null; rm -rf "$GADGET_DIR"; }

mkdir -p "$GADGET_DIR"
cd "$GADGET_DIR"

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "0123456789ABCDEF" > strings/0x409/serialnumber
echo "Dermatoscope Pi" > strings/0x409/manufacturer
echo "Derma USB Drive" > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "Mass Storage" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

mkdir -p functions/mass_storage.usb0
echo 0 > functions/mass_storage.usb0/lun.0/cdrom
echo 0 > functions/mass_storage.usb0/lun.0/ro
echo 1 > functions/mass_storage.usb0/lun.0/removable
echo 0 > functions/mass_storage.usb0/lun.0/nofua
echo "$IMG" > functions/mass_storage.usb0/lun.0/file

ln -s functions/mass_storage.usb0 configs/c.1/

UDC=$(ls /sys/class/udc/ | head -n1)
[ -n "$UDC" ] && echo "$UDC" > UDC && echo "Gadget activated" || { echo "UDC not found!"; exit 1; }
EOF

sudo chmod +x "$GADGET_SCRIPT"
sudo chown pi:pi "$GADGET_SCRIPT"

# 6. Systemd-служба USB gadget
cat <<EOF | sudo tee /etc/systemd/system/usb-gadget.service >/dev/null
[Unit]
Description=USB Mass Storage Gadget
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$GADGET_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable usb-gadget.service

# 7. Создание папки шары
sudo mkdir -p "$SMB_DIR"
sudo chown -R pi:pi "$SMB_DIR"
sudo chmod -R 2775 "$SMB_DIR"

# 8. Настройка Samba
cat <<EOF | sudo tee /etc/samba/smb.conf >/dev/null
[global]
   workgroup = WORKGROUP
   server string = Dermatoscope Pi
   security = user
   min protocol = SMB2
   server min protocol = SMB2
   dns proxy = no

[$SHARE_NAME]
   path = $SMB_DIR
   browseable = yes
   writable = yes
   valid users = pi
   read only = no
   create mask = 0664
   directory mask = 0775
   force user = pi
   force group = pi
EOF

# Установка пароля Samba
(echo "$SAMBA_PASSWORD"; echo "$SAMBA_PASSWORD") | sudo smbpasswd -a pi >/dev/null 2>&1
sudo smbpasswd -e pi

sudo systemctl restart smbd nmbd

# 9. Скрипт синхронизации
cat <<EOF | sudo tee "$SYNC_SCRIPT" >/dev/null
#!/usr/bin/env bash
set -euo pipefail

IMG="/home/pi/piusb.bin"
MOUNT_PT="/mnt/usb_tmp"
TARGET="$SMB_DIR"
LOG="/home/pi/sync_usb.log"

sudo mkdir -p "\$MOUNT_PT" "\$TARGET" 2>/dev/null || true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Запуск" >> "\$LOG"

if mountpoint -q "\$MOUNT_PT"; then
    sudo umount "\$MOUNT_PT" 2>>"\$LOG" || true
fi

if sudo mount -o loop,ro,offset=\$((2048*512)) "\$IMG" "\$MOUNT_PT" 2>>"\$LOG"; then
    rsync -av --update --exclude='System Volume Information' --exclude='found.*' \
          "\$MOUNT_PT/" "\$TARGET/" >>"\$LOG" 2>&1
    sync
    sudo umount "\$MOUNT_PT" 2>>"\$LOG" || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK" >> "\$LOG"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Mount failed" >> "\$LOG"
fi

rmdir "\$MOUNT_PT" 2>/dev/null || true
EOF

sudo chmod +x "$SYNC_SCRIPT"
sudo chown pi:pi "$SYNC_SCRIPT"

# 10. Sudo без пароля
echo 'pi ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount' | sudo tee /etc/sudoers.d/99-usb-sync >/dev/null
sudo chmod 0440 /etc/sudoers.d/99-usb-sync

# 11. Cron с выбранным интервалом
CRON_LINE="*/$SYNC_MINUTES * * * * $SYNC_SCRIPT >> /home/pi/cron.log 2>&1"
(crontab -u pi -l 2>/dev/null || true; echo "$CRON_LINE") | crontab -u pi -

# 12. Финальные настройки
sudo iw wlan0 set power_save off 2>/dev/null || true
sudo systemctl enable --now avahi-daemon

echo
echo "============================================================="
echo "               Настройка завершена!"
echo "============================================================="
echo
echo "• USB-образ:           $IMG (${IMG_SIZE_GB} ГБ)"
echo "• Папка хранения:      $SMB_DIR"
echo "• Сетевая шара:        \\\\$(hostname).local\\$SHARE_NAME"
echo "• Доступ:              пользователь pi / пароль, который вы ввели"
echo "• Синхронизация:       каждые $SYNC_MINUTES минут → $SMB_DIR"
echo "• Логи:                /home/pi/sync_usb.log"
echo
echo "После перезагрузки подключите кабель к левому microUSB-порту."
echo

read -n1 -s -r -p "Перезагрузить сейчас? [y/N] " REPLY
echo
[[ $REPLY =~ ^[Yy]$ ]] && sudo reboot
