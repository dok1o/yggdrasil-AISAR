# gui_logic.py  (only the relevant save/restore + connection parts shown)

import os
import socket
from datetime import datetime

from PySide6.QtCore import QSocketNotifier, QTimer, Qt
from PySide6.QtWidgets import QApplication, QLabel, QPushButton

from gui_settings import read_settings_file, write_settings_file
from gui_json_event_handler import EventFactory, EventParser
from gui_theme import apply_theme

from gui_stats import ensure_stats_table
# from gui_torrents_tab import (
    # handle_torrents_job_progress,
    # handle_torrents_job_done
# )


class SpinnerController:
    """Reusable spinner animation controller for QLabel widgets."""
    def __init__(self, label_widget: QLabel, timer: QTimer,
                 prefix: str = "Processing"):
        self.label = label_widget
        self.timer = timer
        self.prefix = prefix
        self.tick = 0
        self.active = False
        self.timer.timeout.connect(self.animate)

    def start(self, prefix: str = None):
        if prefix:
            self.prefix = prefix
        self.tick = 0
        self.active = True
        self.label.show()
        self.timer.start(150)

    def stop(self):
        self.active = False
        self.timer.stop()
        self.label.hide()
        self.tick = 0

    def animate(self):
        if not self.active:
            return
        self.tick += 1
        phase = self.tick % 4
        dots = "." * (phase + 1)
        self.label.setText(f"{self.prefix}{dots}")


class ButtonSpinner:
    """Reusable spinner animation controller for QPushButton widgets."""
    def __init__(self, button: QPushButton, timer: QTimer,
                 active_prefix: str = "Processing", idle_text: str = None):
        self.button = button
        self.timer = timer
        self.active_prefix = active_prefix
        self.idle_text = idle_text or button.text()
        self.tick = 0
        self.active = False
        self.timer.timeout.connect(self.animate)

    def start(self, prefix: str = None):
        if prefix:
            self.active_prefix = prefix
        self.tick = 0
        self.active = True
        self.button.setEnabled(False)
        self.timer.start(150)

    def stop(self):
        self.active = False
        self.timer.stop()
        self.button.setText(self.idle_text)
        self.button.setEnabled(True)
        self.tick = 0

    def animate(self):
        if not self.active:
            return
        self.tick += 1
        phase = self.tick % 4
        dots = "." * (phase + 1)
        self.button.setText(f"{self.active_prefix}{dots}")


# === Connection management ===

def copy_stats(window):
    lines = [f"=== STATS SNAPSHOT: {datetime.now().isoformat()} ==="]
    for label in window.labels.values():
        if label is None:
            continue
        try:
            # 2. Safely access Qt widget methods (handles deleted widgets gracefully)
            text = label.text().strip()
            if text:
                lines.append(text)
            lines.append("=" * 50)
        except RuntimeError:
            # PySide6 raises RuntimeError when accessing a destroyed C++ object
            continue
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        log_dir = os.path.join(script_dir, "logs")
        os.makedirs(log_dir, exist_ok=True)
        log_path = os.path.join(log_dir, "gui.log")
        with open(log_path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n\n")
    except Exception as e:
        print(f"[GUI] Failed to write stats: {e}")


def save_geometry(gui):
    settings = read_settings_file()
    geo = gui.geometry()
    settings["window_geometry"] = {
        "x": geo.x(), "y": geo.y(),
        "width": geo.width(), "height": geo.height(),
    }
    settings["window_maximized"] = bool(gui.windowState() & Qt.WindowMaximized)
    write_settings_file(settings)


def restore_geometry(gui):
    settings = read_settings_file()
    geo = settings.get("window_geometry")
    if geo:
        gui.setGeometry(geo["x"], geo["y"], geo["width"], geo["height"])
    if settings.get("window_maximized", False):
        gui.setWindowState(gui.windowState() | Qt.WindowMaximized)


def attempt_connection(gui):
    if gui.socket:
        return
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setblocking(False)
        sock.settimeout(0.5)
        sock.connect(gui.backend)
        sock.setblocking(False)
        gui.socket = sock
        gui.header.setText("Connected")
        gui.header.setStyleSheet(apply_theme("summary", kind="connected"))
        gui.notifier = QSocketNotifier(
            sock.fileno(), QSocketNotifier.Read, gui
        )
        gui.notifier.activated.connect(lambda: on_socket_read(gui))
        sock.sendall(EventFactory.gui_start().to_json() + b"\n")
        gui.reconnect_timer.stop()

        # Ensure labels dict exists to prevent NoneType errors
        # if not hasattr(gui, 'labels'):
        #     gui.labels = {}

        gui._totals = {}
        gui._stats_table_ready = False
    except (socket.error, socket.timeout, ConnectionRefusedError):
        gui.header.setText("Connecting...")
        gui.header.setStyleSheet(apply_theme("summary", kind="disconnected"))


def on_socket_read(gui):
    if not gui.socket:
        return
    try:
        data = gui.socket.recv(8192)
        if not data:
            handle_disconnect(gui)
            return
        gui.buffer += data.decode("utf-8", errors="replace")
        while "\n" in gui.buffer:
            line, gui.buffer = gui.buffer.split("\n", 1)
            line = line.strip()
            if line:
                process_backend_message(gui, line)
    except BlockingIOError:
        pass
    except (socket.error, OSError):
        handle_disconnect(gui)


def handle_disconnect(gui):
    if gui.notifier:
        gui.notifier.setEnabled(False)
        gui.notifier.deleteLater()
        gui.notifier = None
    if gui.socket:
        try:
            gui.socket.close()
        except OSError:
            pass
        gui.socket = None
    gui.header.setText("Disconnected")
    gui.header.setStyleSheet(apply_theme("summary", kind="disconnected"))
    gui.reconnect_timer.start(2000)


def process_backend_message(gui, line: str):
    if line.startswith("EVENT_ACK:") or line.startswith("Open the gates!"):
        return
    event = EventParser.parse_line(line)
    if event is None:
        return

    event_name, metadata = event.event, event.metadata

    # if event_name == "backend.torrents.job_progress":
        # handle_torrents_job_progress(gui, metadata)
    # elif event_name == "backend.torrents.job_done":
        # handle_torrents_job_done(gui, metadata)
    if event_name in ["backend.stats", "backend.status.update"]:
        handle_stats_update(gui, metadata)
    elif event_name == "backend.request_restart":
        copy_stats(gui)
        save_geometry(gui)
        # Save column widths before restart
        if hasattr(gui, '_save_all_column_widths'):
            gui._save_all_column_widths()
        QApplication.exit(5)
    # elif "backend.pf" in event_name:
        # import gui_pf_monitor
        # if event_name == "backend.pf.fids_list":
            # gui_pf_monitor.handle_pf_fids_response(gui, metadata)
        # elif event_name == "backend.pf.uaddrs_list":
            # gui_pf_monitor.handle_pf_uaddrs_response(gui, metadata)
        # elif event_name == "backend.pf.lists_update":
            # gui_pf_monitor.handle_pf_lists_update(gui, metadata)
        # elif event_name == "backend.pf.signals_update":
            # gui_pf_monitor.handle_pf_signals_update(gui, metadata)
        # elif event_name == "backend.pf.rendezvous_published":
            # gui_pf_monitor.handle_pf_rendezvous_published(gui, metadata)
        # elif event_name == "backend.pf.transfer_result":
            # gui_pf_monitor.handle_pf_transfer_result(gui, metadata)
    # elif event_name == "backend.search.done":
    #     from gui_search_tab import handle_search_done
    #     handle_search_done(gui, metadata)
    # elif event_name == "backend.search.all_tokens_done":
    #     from gui_torrent_view import _open_token_dialog
    #     tokens = metadata.get("tokens", [])
    #     job_id = metadata.get("job_id", "aggregate")
    #     _open_token_dialog(gui, f"batch_{job_id}", "Aggregate View", tokens)
    #     gui.search_status_label.setText(
    #         f"Aggregated {len(tokens)} unique tokens"
    #     )
    # elif event_name == "backend.search.tokenize_done":
    #     from gui_torrent_view import _open_token_dialog
    #     status = metadata.get("status")
    #     ih = metadata.get("infohash")
    #     name = metadata.get("torrent_name", ih)
    #     tokens = metadata.get("tokens", [])

    #     if status == "ok":
    #         # Cache the result so we don't fetch again
    #         gui.token_cache[ih] = tokens
    #         _open_token_dialog(gui, ih, name, tokens)
    #     else:
    #         # Show error in the relevant status label
    #         err = metadata.get("error", "Unknown error")
    #         if hasattr(gui, 'search_status_label'):
    #             gui.search_status_label.setText(f"Tokenize Error: {err}")


def handle_stats_update(gui, metadata):
    abs_metrics = metadata.get("abs", {})
    diff_metrics = metadata.get("diffs", {})
    backend_totals = metadata.get("totals", {})

    # if not hasattr(gui, '_totals'):
    #     gui._totals = {}

    table_keys = set(diff_metrics.keys()) | set(backend_totals.keys())
    for snap_key in ("dht_blacklist_size", "failed_peers_size"):
        if snap_key in abs_metrics:
            table_keys.add(snap_key)

    ensure_stats_table(gui, {k: 0 for k in table_keys})

    for key, value in backend_totals.items():
        gui._totals[str(key)] = value

    for snap_key in ("dht_blacklist_size", "failed_peers_size"):
        if snap_key in abs_metrics:
            gui._totals[snap_key] = abs_metrics[snap_key]

    for key, value in abs_metrics.items():
        if key == "runtime":
            seconds = value // 1000 if value > 1000 else value
            gui.stats_runtime_label.setText(format_runtime(seconds))
        elif key == "utm_rate":
            gui.stats_utm_label.setText(f"{value:,.0f}/h")

    hero_labels = getattr(gui, "_hero_value_labels", {})

    for key in table_keys:
        k_str = str(key)
        labels = gui._stat_value_labels.get(k_str)
        if labels is None:
            continue
        total_label, delta_label = labels

        diff_val = diff_metrics.get(key, diff_metrics.get(k_str, 0))
        total = gui._totals.get(k_str, 0)

        total_label.setText(_format_number(total))
        delta_label.setText(_format_delta(diff_val))

        # Restyle only on state change to keep updates cheap.
        delta_state = diff_val > 0
        if delta_label.property("_active") != delta_state:
            delta_label.setProperty("_active", delta_state)
            delta_label.setStyleSheet(apply_theme("metric_delta", positive=delta_state))

        total_state = total > 0
        if total_label.property("_active") != total_state:
            total_label.setProperty("_active", total_state)
            total_label.setStyleSheet(apply_theme("metric_total", active=total_state))

        if k_str in hero_labels:
            hero_labels[k_str].setText(_format_number(total))

        # Check if label exists and is not None before setting text
        if k_str in gui.labels and gui.labels[k_str] is not None:
            suffix = f" (+{diff_val})" if diff_val > 0 else ""
            gui.labels[k_str].setText(f"{k_str}: {total}{suffix}")

        # if k_str in gui.labels:
            # suffix = f" (+{diff_val})" if diff_val > 0 else ""
            # gui.labels[k_str].setText(f"{k_str}: {total}{suffix}")


def _format_number(value):
    if isinstance(value, float):
        return f"{value:,.2f}"
    return f"{int(value):,}"


def _format_delta(value):
    if value > 0:
        return f"+{_format_number(value)}"
    return "—"


def format_runtime(seconds):
    h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
    return f"{h:02d}:{m:02d}:{s:02d}"
