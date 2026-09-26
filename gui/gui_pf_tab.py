import re
import datetime
import subprocess
from pathlib import Path
from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
    QLabel, QPushButton, QLineEdit, QListWidget,
    QGroupBox, QSpinBox, QCheckBox, QMessageBox, QApplication
)
from gui_json_event_handler import EventFactory

# ──────────────────────────────────────────────────────────────
# Paths & Constants
# ──────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
LOGS_DIR = PROJECT_ROOT / "data" / "logs"

PF_OUT_LOG     = LOGS_DIR / "pf_out.log"
BEACONS_LOG    = LOGS_DIR / "beacons.log"
OWN_UADDR_LOG  = LOGS_DIR / "own_uaddr.log"
PF_REPLIES_LOG = LOGS_DIR / "pf_reply.log"

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────
def _safe_read_lines(path):
    """Reads log file robustly, strips whitespace, and filters empty lines."""
    if not path.exists():
        return []
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            return [line.strip() for line in f if line.strip()]
    except Exception:
        return []

def _move_to_trash(path):
    """Move file to system trash using 'gio trash', with safe fallbacks."""
    if not isinstance(path, Path):
        path = Path(path)
    path = path.resolve()
    if not path.exists():
        return

    # 1. Try gio trash (GNOME/Linux standard)
    try:
        result = subprocess.run(
            ["gio", "trash", str(path)],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return
    except FileNotFoundError:
        pass

    # 2. Fallback: Move to a local .trash directory in the same folder
    project_trash = path.parent / "trashed_logs"
    project_trash.mkdir(exist_ok=True)
    dest = project_trash / path.name
    counter = 1
    while dest.exists():
        dest = project_trash / f"{path.stem}_{counter}{path.suffix}"
        counter += 1
    try:
        path.rename(dest)
    except Exception:
        pass

def _extract_and_fill_ip(gui, text):
    """Regex scans text for IPv4:port and pastes result into pf_ip_input."""
    match = re.search(r'\b\d{1,3}(\.\d{1,3}){3}:\d+\b', text)
    if match:
        gui.pf_ip_input.setText(match.group())
    else:
        gui.pf_ip_input.setText("")  # fallback to empty string

# ──────────────────────────────────────────────────────────────
# Log Scanners (attached to gui)
# ──────────────────────────────────────────────────────────────
def _scan_pf_out(gui):
    lines = _safe_read_lines(PF_OUT_LOG)
    gui.pf_matched_list.clear()
    recent = lines[-1024:] if len(lines) > 1024 else lines
    if not recent:
        return

    filter_watched = getattr(gui, 'pf_filter_watched_cb', None) and gui.pf_filter_watched_cb.isChecked()
    watched_ips = set(gui.pf_watch_ips)

    if filter_watched and watched_ips:
        filtered_lines = [line for line in recent if any(ip in line for ip in watched_ips)]
    else:
        filtered_lines = recent

    if filtered_lines:
        #gui.pf_matched_list.addItems(filtered_lines)
        gui.pf_matched_list.addItems(filtered_lines[::-1])

def _scan_beacons(gui):
    lines = _safe_read_lines(BEACONS_LOG)
    gui.pf_beacon_list.clear()
    top_lines = lines[:64] if len(lines) > 64 else lines
    
    if top_lines:
        gui.pf_beacon_list.addItems(top_lines)

def _scan_replies(gui):
    lines = _safe_read_lines(PF_REPLIES_LOG)
    gui.pf_replies_list.clear()
    recent = lines[-1024:] if len(lines) > 1024 else lines
    if recent:
        #gui.pf_replies_list.addItems(recent)
        gui.pf_replies_list.addItems(recent[::-1])

def _scan_own_uaddr(gui):
    lines = _safe_read_lines(OWN_UADDR_LOG)
    if lines:
        gui.pf_own_uaddr_label.setText(lines[-1].strip())
    else:
        gui.pf_own_uaddr_label.setText("...")

# ──────────────────────────────────────────────────────────────
# UI Builders
# ──────────────────────────────────────────────────────────────
def build_pf_tab(gui):
    if not hasattr(gui, 'labels'):
        gui.labels = {}

    gui.pf_tab = QWidget()
    root_layout = QVBoxLayout(gui.pf_tab)
    root_layout.setContentsMargins(2, 2, 2, 2)
    root_layout.setSpacing(4)

    # ── 1. TOP TOOLBAR (Reordered per request) ──
    toolbar = QHBoxLayout()
    toolbar.setSpacing(6)

    # Start/Stop Toggle
    gui.pf_toggle_btn = QPushButton("Start")
    gui.pf_toggle_btn.setFixedWidth(95)
    gui.pf_toggle_btn.setFont(QFont("Consolas", 10, QFont.Bold))
    gui.pf_toggle_btn.clicked.connect(lambda: _toggle_tracking(gui))
    toolbar.addWidget(gui.pf_toggle_btn)

    # Clear Button
    btn_clear = QPushButton("Clear")
    btn_clear.clicked.connect(lambda: _clear_all(gui))
    toolbar.addWidget(btn_clear)

    # IP Input Field
    gui.pf_ip_input = QLineEdit()
    gui.pf_ip_input.setPlaceholderText("IPv4...")
    gui.pf_ip_input.setMinimumWidth(180)
    toolbar.addWidget(gui.pf_ip_input)

    # Track IP Button
    btn_track_ip = QPushButton("watch")
    btn_track_ip.clicked.connect(lambda: _add_watched_ip(gui))
    toolbar.addWidget(btn_track_ip)

    # ping_x (kept adjacent to tracking controls)
    btn_ping_x = QPushButton("ping_x")
    btn_ping_x.setFixedWidth(70)
    btn_ping_x.clicked.connect(lambda: _ping_x(gui))
    toolbar.addWidget(btn_ping_x)

    # Filter Label + Checkbox
    toolbar.addWidget(QLabel("Filter:"))
    gui.pf_filter_watched_cb = QCheckBox("Watched-only")
    gui.pf_filter_watched_cb.setStyleSheet("font-size: 9px;")
    toolbar.addWidget(gui.pf_filter_watched_cb)

    # Own IPv4 Group (Static + Dynamic with thin border)
    own_ip_layout = QHBoxLayout()
    own_ip_layout.setContentsMargins(0, 0, 0, 0)
    own_ip_layout.setSpacing(2)
    lbl_own_ip_static = QLabel("Own IPv4:")
    lbl_own_ip_static.setStyleSheet("font-size: 10px; color: #aaa;")
    gui.pf_own_uaddr_label = QLabel("...")
    gui.pf_own_uaddr_label.setFixedWidth(400)
    gui.pf_own_uaddr_label.setFont(QFont("Consolas", 12))
    gui.pf_own_uaddr_label.setAlignment(Qt.AlignCenter)
    gui.pf_own_uaddr_label.setStyleSheet("border: 1px solid #555; padding: 2px; background: #1e1e1e; color: #dcdcdc; font-size: 13px;")
    own_ip_layout.addWidget(lbl_own_ip_static)
    own_ip_layout.addWidget(gui.pf_own_uaddr_label)
    toolbar.addLayout(own_ip_layout)

    toolbar.addStretch()
    root_layout.addLayout(toolbar)

    # ── 2. PF PARAMS ROW ──
    params_layout = QHBoxLayout()
    params_layout.setContentsMargins(0, 0, 0, 0)
    params_layout.setSpacing(4)
    gui._pf_spinboxes = {}
    spin_defs = ["freq_wnd", "freq_cnt", "infreq_buf", "mask_b", "xor_thr_b", "nodes_asked", "t_asked_wnd"]
    for name in spin_defs:
        lbl = QLabel(f"{name}:")
        lbl.setStyleSheet("font-size: 9px; color: #aaa;")
        sb = QSpinBox()
        sb.setMinimum(0)
        sb.setValue(0)
        sb.setFixedWidth(50)
        sb.setStyleSheet("font-size: 9px;")
        params_layout.addWidget(lbl)
        params_layout.addWidget(sb)
        gui._pf_spinboxes[name] = sb

    gui.pf_use_id_cb = QCheckBox("use_nids")
    gui.pf_use_id_cb.setChecked(False)
    gui.pf_use_id_cb.setStyleSheet("font-size: 9px;")
    params_layout.addWidget(gui.pf_use_id_cb)
    params_layout.addStretch()
    root_layout.addLayout(params_layout)

    # ── 3. MAIN CONTENT (2 COLUMNS) ──
    main_widget = QWidget()
    content_layout = QHBoxLayout(main_widget)
    content_layout.setContentsMargins(0, 4, 0, 0)
    content_layout.setSpacing(8)

    # Left Column: Watch (1/3) + pf_out (2/3)
    left_col = QWidget()
    left_layout = QVBoxLayout(left_col)
    left_layout.setContentsMargins(0, 0, 0, 0)
    left_layout.setSpacing(6)

    grp_watch = QGroupBox("watch")
    layout_watch = QVBoxLayout(grp_watch)
    gui.pf_added_ips_list = QListWidget()
    gui.pf_added_ips_list.itemDoubleClicked.connect(lambda item: _remove_watched_ip(gui, item))
    layout_watch.addWidget(gui.pf_added_ips_list)
    left_layout.addWidget(grp_watch, 1)

    grp_pf_out = QGroupBox("pf_out")
    layout_pf_out = QVBoxLayout(grp_pf_out)
    gui.pf_matched_list = QListWidget()
    gui.pf_matched_list.setWordWrap(True)
    # ✅ CHANGED: Double-click now extracts IPv4:port instead of copying full string
    gui.pf_matched_list.itemDoubleClicked.connect(lambda item: _extract_and_fill_ip(gui, item.text()))
    layout_pf_out.addWidget(gui.pf_matched_list)
    left_layout.addWidget(grp_pf_out, 2)

    # Right Column: Replies (1/3) + Beacons (2/3)
    right_col = QWidget()
    right_layout = QVBoxLayout(right_col)
    right_layout.setContentsMargins(0, 0, 0, 0)
    right_layout.setSpacing(6)

    grp_replies = QGroupBox("pf_replies")
    layout_replies = QVBoxLayout(grp_replies)
    gui.pf_replies_list = QListWidget()
    gui.pf_replies_list.setWordWrap(True)
    # ✅ CHANGED: Double-click now extracts IPv4:port instead of copying full string
    gui.pf_replies_list.itemDoubleClicked.connect(lambda item: _extract_and_fill_ip(gui, item.text()))
    layout_replies.addWidget(gui.pf_replies_list)
    right_layout.addWidget(grp_replies, 1)

    grp_beacons = QGroupBox("beacons")
    layout_beacons = QVBoxLayout(grp_beacons)
    gui.pf_beacon_list = QListWidget()
    gui.pf_beacon_list.setWordWrap(True)
    gui.pf_beacon_list.itemDoubleClicked.connect(_copy_item_to_clipboard) # Beacons unchanged as requested
    layout_beacons.addWidget(gui.pf_beacon_list)
    right_layout.addWidget(grp_beacons, 2)

    content_layout.addWidget(left_col, 1)
    content_layout.addWidget(right_col, 1)
    root_layout.addWidget(main_widget)

    # ── STYLING (1px borders, reduced padding, small labels) ──
    gui.pf_tab.setStyleSheet("""
        QWidget { padding: 2px; margin: 0px; }
        QGroupBox {
            border: 1px solid #555;
            margin-top: 4px;
            padding-top: 4px;
            font-size: 9px;
            color: #ccc;
        }
        QGroupBox::title { subcontrol-origin: margin; left: 6px; top: -2px; }
        QListWidget { font-size: 13px; background: #1e1e1e; color: #dcdcdc; border: 1px solid #444; font-family: monospace; }
        QPushButton { min-width: 70px; padding: 4px; border: 1px solid #555; border-radius: 3px; }
        QLineEdit { min-width: 180px; padding: 3px; border: 1px solid #555; }
    """)

    # ── TIMERS & STATE ──
    gui.pf_watch_ips = []
    gui._pf_tracking_active = False
    gui._pf_start_time = None
    # Log refresh timers
    gui.pf_log_timer = QTimer(); gui.pf_log_timer.setInterval(300); gui.pf_log_timer.timeout.connect(lambda: _scan_pf_out(gui))
    gui.pf_beacon_timer = QTimer(); gui.pf_beacon_timer.setInterval(5100); gui.pf_beacon_timer.timeout.connect(lambda: _scan_beacons(gui))
    gui.pf_replies_timer = QTimer(); gui.pf_replies_timer.setInterval(1000); gui.pf_replies_timer.timeout.connect(lambda: _scan_replies(gui))
    gui.pf_uaddr_timer = QTimer(); gui.pf_uaddr_timer.setInterval(200); gui.pf_uaddr_timer.timeout.connect(lambda: _scan_own_uaddr(gui))
    # Counter timer
    gui.pf_counter_timer = QTimer()
    gui.pf_counter_timer.setInterval(100)
    gui.pf_counter_timer.timeout.connect(lambda: _update_tracking_counter(gui))
    gui._pf_timers = [gui.pf_log_timer, gui.pf_beacon_timer, gui.pf_replies_timer, gui.pf_uaddr_timer, gui.pf_counter_timer]

    if hasattr(gui, 'tabs'):
        gui.tabs.addTab(gui.pf_tab, "pf_protocol")

# ──────────────────────────────────────────────────────────────
# Event Handlers
# ──────────────────────────────────────────────────────────────
def _add_watched_ip(gui):
    raw_input = gui.pf_ip_input.text().strip()
    # ✅ CHANGED: Strip port if present (e.g., 192.168.1.1:8080 -> 192.168.1.1)
    ip_only = re.sub(r':\d+$', '', raw_input)

    # ✅ FIXED: Proper IPv4 regex (original had invalid ** syntax)
    if re.match(r'^(\d{1,3}\.){3}\d{1,3}$', ip_only):
        if ip_only not in gui.pf_watch_ips:
            gui.pf_watch_ips.append(ip_only)
            gui.pf_added_ips_list.addItem(ip_only)
            gui.pf_ip_input.clear()
            gui.pf_ip_input.setFocus()
        else:
            QMessageBox.warning(gui.pf_tab, f"{ip_only} already added")
    else:
        QMessageBox.warning(gui.pf_tab, "Enter a valid IPv4 address (e.g., 192.168.1.1)")

def _remove_watched_ip(gui, item):
    row = gui.pf_added_ips_list.row(item)
    removed_ip = gui.pf_watch_ips.pop(row)
    gui.pf_added_ips_list.takeItem(row)
    to_remove = []
    for i in range(gui.pf_matched_list.count()):
        if removed_ip in gui.pf_matched_list.item(i).text():
            to_remove.append(i)
    for idx in reversed(to_remove):
        gui.pf_matched_list.takeItem(idx)

def _toggle_tracking(gui):
    if not gui._pf_tracking_active:
        # Start tracking
        gui._pf_tracking_active = True
        gui._pf_start_time = datetime.datetime.now().timestamp()
        gui.pf_toggle_btn.setText("Stop")
        gui.pf_counter_timer.start()
        for timer in gui._pf_timers:
            if timer != gui.pf_counter_timer:
                timer.start()
    else:
        # Stop tracking
        gui._pf_tracking_active = False
        gui.pf_toggle_btn.setText("Start Scan")
        gui.pf_counter_timer.stop()
        for timer in gui._pf_timers:
            if timer != gui.pf_counter_timer:
                timer.stop()

def _update_tracking_counter(gui):
    if gui._pf_tracking_active and hasattr(gui, '_pf_start_time') and gui._pf_start_time is not None:
        elapsed = int(datetime.datetime.now().timestamp() - gui._pf_start_time)
        gui.pf_toggle_btn.setText(f"{elapsed}s")

def _clear_all(gui):
    # Move logs to trash instead of truncating
    _move_to_trash(PF_OUT_LOG)
    _move_to_trash(BEACONS_LOG)
    _move_to_trash(PF_REPLIES_LOG)
    _move_to_trash(OWN_UADDR_LOG)
    # Clear UI lists & state
    gui.pf_watch_ips.clear()
    gui.pf_added_ips_list.clear()
    gui.pf_matched_list.clear()
    gui.pf_beacon_list.clear()
    gui.pf_replies_list.clear()
    gui.pf_own_uaddr_label.setText("...")

def _ping_x(gui):
    raw_text = gui.pf_ip_input.text().strip()
    if not raw_text:
        QMessageBox.warning(gui.pf_tab, "Enter an IPv4 address first.")
        return
    
    ip_str = re.sub(r':\d+$', '', raw_text)

    try:
        evt = EventFactory.gui_input_ping_x(ip_str).to_json()
        gui.socket.sendall(evt + b"\n")
        # Create the event using the new factory method
        #event = EventFactory.gui_input_ping_x(ip_str)
        
        # TODO: Replace this print with your actual event dispatch mechanism
        # Examples:
        # gui.event_queue.put(event.to_json())
        # gui.backend_socket.send(event.to_json())
        # gui.event_bus.emit(event)
        # print(f"[PING_X] Created: {event.event} | Payload (base64): {event.metadata['payload']}")
        
    except ValueError as e:
        QMessageBox.warning(gui.pf_tab, str(e))

def _copy_item_to_clipboard(item):
    QApplication.clipboard().setText(item.text())
