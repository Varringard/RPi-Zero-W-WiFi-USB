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
TIMEOUT_SEC = 5  # секунд ожидания после изменения

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
            logger.warning(f"Команда завершилась с ошибкой: {cmd}\n{result.stderr}")
        else:
            logger.debug(f"Выполнено: {cmd}")
    except Exception as e:
        logger.error(f"Ошибка при выполнении '{cmd}': {e}")

def main():
    handler = USBStorageHandler()
    observer = Observer()
    observer.schedule(handler, path=WATCH_PATH, recursive=False)
    observer.start()
    logger.info(f"Наблюдение за {WATCH_PATH} запущено.")

    # Изначально подключаем USB Mass Storage
    run_cmd(f"modprobe g_mass_storage file={IMAGE_FILE} stall=0 removable=y")

    try:
        while True:
            if handler.dirty and (time.time() - handler.last_change) >= TIMEOUT_SEC:
                logger.info("Таймаут превышен. Переподключение USB...")
                run_cmd("modprobe -r g_mass_storage")
                time.sleep(1)
                run_cmd("sync")
                time.sleep(1)
                run_cmd(f"modprobe g_mass_storage file={IMAGE_FILE} stall=0 removable=y")
                handler.reset()
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Получен сигнал завершения.")
    finally:
        observer.stop()
        observer.join()
        run_cmd("modprobe -r g_mass_storage")
        logger.info("USB Mass Storage отключён. Выход.")

if __name__ == "__main__":
    main()
