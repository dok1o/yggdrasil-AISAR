# gui_stats.py — Stats dashboard: hero KPI cards + metric group cards (no scrolling)

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QGridLayout,
    QFrame,
    QLabel,
    QSizePolicy,
)
from gui_theme import apply_theme

METRIC_GROUPS = [
    ("Overview", ["runtime", "utm_rate"]),
    ("Inbound", [
        "recvd", "dropped_packets", "ping"
    ]),
        ("Outbound", [
        "gp_replies", "deferred_get_peers_served"
    ]),
    ("DHT", [
        "dht_blacklist_size", "dht_node_blacklisted", "excluded_node"
    ]),
    ("utm workers", [
        "base_worker", "announce_worker",
    ]),
    ("announce_peer / peers", [
        "announce", "announce_failed", "peer_ext", "peers_tried", "failed_peers_size"
    ]),
    ("utm downloads", [
        "infohash", "utm_downloaded_via_utp", "utm_downloaded_via_tcp"
    ]),
    ("uTP", [
        "utp_attempts", "utp_connected", "utp_data_ok", "utp_resets",
    ]),
    ("PF protocol", [
        "pf_signals", "pf_seek", "pf_file_chunks", "pf_file_ok", "pf_file_fail", "pf_rdv_hit",
        "fnx", "fping", "fnode", "fnode_ack"
    ]),
]

_GRID_COLUMNS = 4

_HERO_KPIS = [
    # (caption, attr/metric key, kind)
    ("Runtime", "runtime", "runtime"),
    ("UTM Rate", "utm_rate", "utm"),
    ("via uTP", "utm_downloaded_via_utp", "via_utp"),
    ("via TCP", "utm_downloaded_via_tcp", "via_tcp"),
]

def _make_hero_card(caption: str, kind: str):
    card = QFrame()
    card.setObjectName("heroCard")
    card.setStyleSheet(apply_theme("hero_card", kind))
    layout = QVBoxLayout(card)
    layout.setContentsMargins(14, 10, 14, 10)
    layout.setSpacing(2)
    cap = QLabel(caption.upper())
    cap.setStyleSheet(apply_theme("hero_cap", kind))
    layout.addWidget(cap)
    value = QLabel("—")
    value.setStyleSheet(apply_theme("hero_value", kind))
    layout.addWidget(value)
    return card, value

def build_stats_tab(gui):
    if not hasattr(gui, 'labels'):
        gui.labels = {}

    gui.stats_tab = QWidget()
    stats_layout = QVBoxLayout(gui.stats_tab)
    stats_layout.setContentsMargins(14, 14, 14, 10)
    stats_layout.setSpacing(12)

    # --- Hero KPI row ---
    hero_row = QHBoxLayout()
    hero_row.setSpacing(12)
    gui._hero_value_labels = {}

    for caption, key, kind in _HERO_KPIS:
        card, value_label = _make_hero_card(caption, kind)
        hero_row.addWidget(card, stretch=1)
        if key == "runtime":
            gui.stats_runtime_label = value_label
        elif key == "utm_rate":
            gui.stats_utm_label = value_label
        else:
            gui._hero_value_labels[key] = value_label

    stats_layout.addLayout(hero_row)

    gui.labels["runtime"] = gui.stats_runtime_label
    gui.labels["utm_rate"] = gui.stats_utm_label

    # --- Metric cards grid ---
    gui.stats_grid_host = QWidget()
    gui.stats_grid = QGridLayout(gui.stats_grid_host)
    gui.stats_grid.setContentsMargins(0, 0, 0, 0)
    gui.stats_grid.setSpacing(12)
    stats_layout.addWidget(gui.stats_grid_host, stretch=1)

    gui._stat_value_labels = {}
    gui._stats_row_for_key = {}
    gui._stats_table_ready = False

    hint = QLabel(
        "Green chips show activity since the last tick. "
        "File → Copy Progress Stats exports a snapshot.",
    )
    hint.setWordWrap(True)
    hint.setStyleSheet(apply_theme("label"))
    stats_layout.addWidget(hint)

    gui.tabs.addTab(gui.stats_tab, "stats")


def _ordered_metric_keys(all_keys):
    seen = set()
    ordered = []
    for _title, keys in METRIC_GROUPS:
        for key in keys:
            if key in all_keys and key not in seen:
                ordered.append(key)
                seen.add(key)
    for key in sorted(all_keys):
        if key not in seen and key not in {"runtime", "utm_rate"}:
            ordered.append(key)
    return ordered


def _make_metric_card(gui, title, keys):
    card = QFrame()
    card.setObjectName("metricCard")
    card.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
    layout = QVBoxLayout(card)
    layout.setContentsMargins(12, 10, 12, 10)
    layout.setSpacing(5)
    
    header = QLabel(title.upper())
    header.setStyleSheet(apply_theme("metric_card"))
    layout.addWidget(header)
    
    for key in keys:
        row = QHBoxLayout()
        row.setSpacing(6)
        name = QLabel(str(key))
        name.setStyleSheet(apply_theme("metric_label"))
        row.addWidget(name, stretch=1)
        
        delta = QLabel("")
        delta.setStyleSheet(apply_theme("metric_delta", positive=False))
        delta.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        row.addWidget(delta)
        
        total = QLabel("0")
        total.setStyleSheet(apply_theme("metric_total", active=False))
        total.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        total.setMinimumWidth(52)
        row.addWidget(total)
        
        layout.addLayout(row)
        gui._stat_value_labels[str(key)] = (total, delta)
        mirror = QLabel("").hide()
        gui.labels[str(key)] = mirror
    layout.addStretch()
    return card

def _clear_grid(gui):
    while gui.stats_grid.count():
        item = gui.stats_grid.takeAt(0)
        widget = item.widget()
        if widget is not None:
            widget.deleteLater()


def ensure_stats_table(gui, diff_metrics):
    """(Re)build the metric card grid when the key set first arrives."""
    if gui._stats_table_ready:
        return

    all_keys = set(diff_metrics.keys())
    _clear_grid(gui)
    gui._stat_value_labels = {}

    cards = []
    placed = set()
    for group_title, group_keys in METRIC_GROUPS:
        if group_title == "Overview":
            continue
        present = [
            k for k in group_keys
            if k in all_keys and k not in {"runtime", "utm_rate"}
        ]
        if not present:
            continue
        cards.append((group_title, present))
        placed.update(present)

    leftovers = [
        k for k in _ordered_metric_keys(all_keys)
        if k not in placed and k not in {"runtime", "utm_rate"}
    ]
    if leftovers:
        cards.append(("Other", leftovers))

    for idx, (title, keys) in enumerate(cards):
        card = _make_metric_card(gui, title, keys)
        row, col = divmod(idx, _GRID_COLUMNS)
        gui.stats_grid.addWidget(card, row, col)

    for col in range(_GRID_COLUMNS):
        gui.stats_grid.setColumnStretch(col, 1)

    gui._stats_table_ready = True
