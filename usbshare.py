#!/usr/bin/python3
import time
import subprocess
import logging
from watchdog.observers import Observer
from watchdog.events import (
    DirDeletedEvent,
    DirMovedEvent,
    FileDeletedEvent,
    FileModifiedEvent,
    FileMovedEvent,
    FileSystemEventHandler
)

# === Настройки ===
WATCH_PATH = "/mnt/usb_share"
IMAGE_FILE = "/piusb.bin"
TIMEOUT_SEC = 5

# === Логирование ===
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class USBStorageHandler(FileSystemEventHandler):
    def __init__(self):
        self.reset()

    def on_any_event(self, event):
        if not event.is_directory and type(event) in [
            DirDeletedEvent, DirMovedEvent,
            FileDeletedEvent, FileModifiedEvent, FileMovedEvent
        ]:
            self._dirty = True
            self._last_change = time.time()
            logger.info(f"Изменение обнаружено: {event.src_path}")

    @property
    def dirty(self):
        return self._dirty

    @property
    def last_change(self):
        return self._last_change

    def reset(self):
        self._dirty = False
        self._last_change = 0

def run_cmd(cmd):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            logger.warning(f"Ошибка команды: {cmd}\n{result.stderr}")
        else:
            logger.debug(f"Выполнено: {cmd}")
    except Exception as e:
        logger.error(f"Исключение при выполнении '{cmd}': {e}")

def main():
    handler = USBStorageHandler()
    observer = Observer()
    observer.schedule(handler, path=WATCH_PATH, recursive=False)
    observer.start()
    logger.info(f"Наблюдение за {WATCH_PATH} запущено.")

    # === g_multi БЕЗ интернета ===
    CMD_MOUNT = (
        f"modprobe g_multi file={IMAGE_FILE} "
        "luns=1 cdrom=0 stall=0 removable=1 "
        "iSerial=\"DERMA001\" "
        "iManufacturer=\"RaspberryPi\" "
        "iProduct=\"Dermatoscope Storage\""
    )
    CMD_UNMOUNT = "modprobe -r g_multi"

    run_cmd(CMD_UNMOUNT)
    run_cmd(CMD_MOUNT)

    try:
        while True:
            if handler.dirty and (time.time() - handler.last_change) >= TIMEOUT_SEC:
                logger.info("Таймаут превышен. Переподключение USB...")
                run_cmd(CMD_UNMOUNT)
                time.sleep(1)
                run_cmd("sync")
                time.sleep(1)
                run_cmd(CMD_MOUNT)
                handler.reset()
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Получен сигнал завершения.")
    finally:
        observer.stop()
        observer.join()
        run_cmd(CMD_UNMOUNT)
        logger.info("USB Mass Storage отключён.")

if __name__ == "__main__":
    main()
