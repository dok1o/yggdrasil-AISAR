# gui_settings.py - setting manager

import json
import os
from pathlib import Path
from PySide6.QtWidgets import QMessageBox

#CONF_FILE = "./magnet_sorter/magnet_sorter_settings.json"

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
CONF_FILE = PROJECT_ROOT / "data" / "settings.json"

def read_settings_file() -> dict:
    try:
        if not os.path.exists(CONF_FILE):
            return {}
        with open(CONF_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def write_settings_file(data: dict) -> None:
    # Shows a GUI warning dialog if write fails (when QApplication exists).
    try:
        os.makedirs(os.path.dirname(CONF_FILE), exist_ok=True)
        with open(CONF_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        try:
            QMessageBox.warning(
                None, "Error", f"Could not save configuration:\n{e}"
            )
        except Exception:
            print(f"[gui_settings] Could not save configuration: {e}")
