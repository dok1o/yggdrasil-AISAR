# gui_client_subwindows.py - dialogue windows
import json
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QVBoxLayout, QHBoxLayout, QFormLayout,
    QSpinBox, QTextEdit, QGroupBox, QPushButton, QComboBox, QLineEdit, QCheckBox, QGridLayout,
    QMessageBox
)
from gui_settings import read_settings_file
#from gui_json_event_handler import EventFactory

class SettingsDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Settings")
        
        # Load settings safely
        try:
            self.original_settings = read_settings_file() or {}
        except Exception as e:
            print(f"⚠️ Failed to load settings file: {e}")
            self.original_settings = {}
            
        self.settings_widgets = {}
        main_layout = QGridLayout(self)
        left_col = QVBoxLayout()
        right_col = QVBoxLayout()

        # Dispatch table: removes if/elif isinstance chain
        _WIDGET_CONFIG = {
            'QCheckBox': {
                'handler': lambda w, v: w.setChecked(bool(v)),
                'signal': 'stateChanged'
            },
            'QSpinBox': {
                'handler': lambda w, v: w.setValue(int(v) if v is not None and str(v).isdigit() else 51413),
                'signal': 'valueChanged'
            },
            # 'QComboBox': {
            #     'handler': lambda w, v: (
            #         w.addItems(["TCP and uTP", "TCP", "uTP"]) if w.count() == 0 else None
            #     ) or w.setCurrentText(str(v).strip() if v else "TCP and uTP"),
            #     'signal': 'currentTextChanged'
            #},
            # todo: min sugar two diff lists for comboboxes, maybe change logic entirely
            'QComboBox': {
                'handler': lambda w, v: (
                    w.addItems([""]) if w.count() == 0 else None
                ) or w.setCurrentText(str(v).strip() if v else ""),
                'signal': 'currentTextChanged'
            },
            'QLineEdit': {
                'handler': lambda w, v: w.setText(str(v).strip() if v else ""),
                'signal': 'textChanged'
            }
        }

        def add_setting(group_box, label_text, widget, config_key, default_value=None, enabled=False):
            form = group_box.layout()
            raw_val = self.original_settings.get(config_key)
            val = raw_val if raw_val is not None else default_value

            # Initialize via dispatch table
            widget_type = type(widget).__name__
            cfg = _WIDGET_CONFIG.get(widget_type)
            if cfg:
                cfg['handler'](widget, val)
                getattr(widget, cfg['signal']).connect(self.on_change)

            form.addRow(label_text, widget)
            self.settings_widgets[config_key] = widget
            widget.setEnabled(enabled)  # Uniformly disables/enables all widgets

        # --- Main Group ---
        main_gb = QGroupBox("Main")
        main_gb.setLayout(QFormLayout())
        add_setting(main_gb, "fdisk Path:", QLineEdit(), "fdisk_path", default_value="", enabled=False)
        
        transport_cb = QComboBox()
        add_setting(main_gb, "Transport:", transport_cb, "transport", default_value="TCP and uTP", enabled=False)
        
        port_spin = QSpinBox()
        port_spin.setRange(0, 65535) # Good practice for spinboxes
        add_setting(main_gb, "Listening Port:", port_spin, "listening_port", default_value=51413, enabled=False)
        
        cb_legacy = QCheckBox()
        add_setting(main_gb, "Legacy Crawl:", cb_legacy, "legacy_crawl", default_value=True, enabled=True)
        left_col.addWidget(main_gb)

        # --- Legacy Group ---
        legacy_gb = QGroupBox("Legacy")
        legacy_gb.setLayout(QFormLayout())
        cb_load_utm = QCheckBox()
        add_setting(legacy_gb, "Load utm as Content:", cb_load_utm, "load_utm_as_content", default_value=False, enabled=False)
        left_col.addWidget(legacy_gb)

        # --- PF Group ---
        pf_gb = QGroupBox("PF")
        pf_gb.setLayout(QFormLayout())
        cb_enable_pf = QCheckBox()
        add_setting(pf_gb, "Enable PF:", cb_enable_pf, "enable_pf", default_value=True, enabled=True)
        
        combo_wot = QComboBox()
        add_setting(pf_gb, "Web-of-Trust Reference Level:", combo_wot, "web_of_trust_level", default_value="1-deep", enabled=False)
        right_col.addWidget(pf_gb)

        # --- Yggdrasil Group ---
        # GUI side only writes settings and emits an event; all scraping and
        # bootstrap logic lives in Elixir (YggPF.WebPeers). Spec section 40.
        ygg_gb = QGroupBox("Yggdrasil")
        ygg_gb.setLayout(QFormLayout())

        cb_enable_ygg = QCheckBox()
        add_setting(ygg_gb, "Enable Yggdrasil:", cb_enable_ygg, "enable_ygg",
                    default_value=True, enabled=True)

        cb_web_scrape = QCheckBox()
        add_setting(ygg_gb, "Web-scrape Peers:", cb_web_scrape, "ygg_web_scrape_peers",
                    default_value=False, enabled=True)

        region_edit = QLineEdit()
        add_setting(ygg_gb, "Scrape Region:", region_edit, "ygg_web_scrape_region",
                    default_value="europe", enabled=True)

        limit_spin = QSpinBox()
        limit_spin.setRange(1, 200)
        add_setting(ygg_gb, "Max Web Peers:", limit_spin, "ygg_web_scrape_limit",
                    default_value=20, enabled=True)

        # "or update" half of spec section 40: refresh now, without waiting for a restart.
        # Web-scraped peers stay low priority (spec section 36) and are outranked by
        # scan-discovered relays (spec section 37) - the backend enforces that ordering.
        self.scrape_now_btn = QPushButton("Scrape Peers Now")
        self.scrape_now_btn.setToolTip(
            "Fetch the Yggdrasil public-peers list now.\n"
            "These peers are low priority and are replaced by\n"
            "validated relays discovered through SDP scanning."
        )
        self.scrape_now_btn.clicked.connect(self._on_scrape_now)
        ygg_gb.layout().addRow("", self.scrape_now_btn)

        right_col.addWidget(ygg_gb)

        # --- Debug Group ---
        debug_gb = QGroupBox("Debug")
        debug_gb.setLayout(QFormLayout())
        cb_hide_debug = QCheckBox()
        add_setting(debug_gb, "Hide Debug:", cb_hide_debug, "hide_debug", default_value=False, enabled=False)
        
        cb_save_utm = QCheckBox()
        add_setting(debug_gb, "Save utm:", cb_save_utm, "save_utm", default_value=False, enabled=False)
        
        cb_save_tjf = QCheckBox()
        add_setting(debug_gb, "Save tjf:", cb_save_tjf, "save_tjf", default_value=True, enabled=False)
        
        cb_jsonl_append = QCheckBox()
        add_setting(debug_gb, "JSONL-append tjf:", cb_jsonl_append, "jsonl_append_tjf", default_value=False, enabled=False)
        right_col.addWidget(debug_gb)

        main_layout.addLayout(left_col, 0, 0)
        main_layout.addLayout(right_col, 0, 1)

        # --- Buttons ---
        self.apply_btn = QPushButton("Apply and Restart")
        self.apply_btn.setEnabled(False)
        cancel_btn = QPushButton("Cancel")
        
        buttons_layout = QHBoxLayout()
        buttons_layout.addWidget(cancel_btn)
        buttons_layout.addWidget(self.apply_btn)
        
        main_layout.addLayout(buttons_layout, 1, 0, 1, 2)
        cancel_btn.clicked.connect(self.reject)
        self.apply_btn.clicked.connect(self.accept)

    def on_change(self):
        """Enable Apply button when any setting changes."""
        self.apply_btn.setEnabled(True)

    def _on_scrape_now(self):
        """
        Ask the backend to refresh web-scraped Yggdrasil peers (spec section 40).

        Deliberately thin: the GUI does no fetching, parsing or config writing.
        It emits one event and lets YggPF.WebPeers do the work, so scraping
        logic stays in Elixir (spec section 39) and out of the GUI (spec section 40).
        """
        from gui_json_event_handler import EventFactory

        region = self.settings_widgets["ygg_web_scrape_region"].text().strip() or "europe"
        limit = self.settings_widgets["ygg_web_scrape_limit"].value()

        window = self.parent()
        sock = getattr(window, "socket", None)
        if sock is None:
            QMessageBox.warning(self, "Not Connected",
                                "No backend connection; cannot request a peer scrape.")
            return

        try:
            evt = EventFactory.gui_ygg_scrape_peers(region, limit).to_json()
            sock.sendall(evt + b"\n")
            self.scrape_now_btn.setText("Scrape requested...")
            self.scrape_now_btn.setEnabled(False)
            QTimer.singleShot(15_000, self._reset_scrape_button)
        except (OSError, ValueError) as e:
            QMessageBox.critical(self, "Scrape Failed", f"Could not request scrape:\n{e}")

    def _reset_scrape_button(self):
        self.scrape_now_btn.setText("Scrape peers now")
        self.scrape_now_btn.setEnabled(True)

    def get_current_settings(self):
        """Return a dict of current UI values mapped to config keys."""
        current = {}
        for key, widget in self.settings_widgets.items():
            if isinstance(widget, QCheckBox):
                current[key] = widget.isChecked()
            elif isinstance(widget, QSpinBox):
                current[key] = widget.value()
            elif isinstance(widget, QComboBox):
                current[key] = widget.currentText()
            elif isinstance(widget, QLineEdit):
                current[key] = widget.text()
        return current


class MagnetInputDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Load Magnets")
        layout = QVBoxLayout(self)

        self.text_edit = QTextEdit()
        self.text_edit.setPlaceholderText("One link per line...")
        layout.addWidget(self.text_edit)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def get_lines(self):
        text = self.text_edit.toPlainText()
        return [line.strip() for line in text.splitlines() if line.strip()]

# class FidLookupDialog(QDialog):
#     """Debug dialog: paste one 40-char hex fid per line."""
#     def __init__(self, parent=None):
#         super().__init__(parent)
#         self.setWindowTitle("Lookup FIDs")
#         layout = QVBoxLayout(self)

#         self.text_edit = QTextEdit()
#         self.text_edit.setPlaceholderText(
#             "Paste one 40-character hex FID per line\n"
#             "(from /fids.log — second column)"
#         )
#         layout.addWidget(self.text_edit)

#         buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
#         buttons.accepted.connect(self.accept)
#         buttons.rejected.connect(self.reject)
#         layout.addWidget(buttons)

#     def get_fids(self):
#         """Return validated 40-char hex strings only."""
#         out = []
#         for raw in self.text_edit.toPlainText().splitlines():
#             line = raw.strip()
#             parts = line.split()
#             candidate = parts[-1] if parts else ""
#             if len(candidate) == 40:
#                 try:
#                     bytes.fromhex(candidate)
#                     out.append(candidate.upper())
#                 except ValueError:
#                     pass
#         return out


# class TokenViewerDialog(QDialog):
#     """Displays token/frequency table for a torrent with W/G/B classification."""

#     # ---- dark-mode row tints (muted, low-saturation backgrounds) ----
#     _CLR_BG = {
#         "whitelist": QColor(28, 72, 28),      # muted green
#         "greylist":  QColor(85, 70, 18),       # muted amber
#         "blacklist": QColor(95, 28, 28),       # muted red
#     }
#     # foreground stays light on every tinted row
#     _CLR_FG = {
#         "whitelist": QColor(180, 255, 180),
#         "greylist":  QColor(255, 245, 175),
#         "blacklist": QColor(255, 190, 190),
#     }

#     def __init__(self, gui, infohash, torrent_name, tokens_data, parent=None):
#         super().__init__(parent)
#         self.gui = gui
#         self.infohash = infohash
#         self.selected_token = None

#         short = torrent_name[:80] or infohash[:16]
#         self.setWindowTitle(f"Tokens — {short}")
#         self.setMinimumSize(720, 480)
#         self.resize(720, 520)

#         layout = QVBoxLayout(self)

#         # ---- header (palette-aware) ----
#         hdr = QLabel(
#             f"<b>{torrent_name}</b><br>"
#             f"<small>Infohash: <code>{infohash}</code>  ·  "
#             f"{len(tokens_data)} tokens</small>"
#         )
#         hdr.setWordWrap(True)
#         hdr.setTextInteractionFlags(Qt.TextSelectableByMouse)
#         layout.addWidget(hdr)

#         hint = QLabel(
#             "Double-click a token to search by it.  "
#             "W\u2009=\u2009whitelist  G\u2009=\u2009greylist  B\u2009=\u2009blacklist"
#         )
#         hint.setStyleSheet("color:#aaa; font-size:11px;")
#         layout.addWidget(hint)
        
#         self.btn_greylist_all = QPushButton("Greylist All")
#         self.btn_greylist_all.clicked.connect(self._greylist_all)
#         layout.addWidget(self.btn_greylist_all)

#         # ---- tree ----
#         self.tree = QTreeWidget()
#         self.tree.setHeaderLabels(["Token", "Frequency", "Classification", ""])
#         self.tree.setAlternatingRowColors(True)
#         self.tree.setSortingEnabled(True)
#         self.tree.setRootIsDecorated(False)
#         self.tree.itemDoubleClicked.connect(self._on_double_click)

#         # subtle alternating-row tint that works on a dark base
#         self.tree.setStyleSheet(
#             "QTreeWidget { background: #1e1e1e; alternate-background-color: #262626; }"
#         )

#         h = self.tree.header()
#         h.setStretchLastSection(False)
#         h.setSectionResizeMode(0, QHeaderView.Stretch)
#         h.setSectionResizeMode(1, QHeaderView.ResizeToContents)
#         h.setSectionResizeMode(2, QHeaderView.ResizeToContents)
#         h.setSectionResizeMode(3, QHeaderView.Fixed)
#         h.resizeSection(3, 112)

#         layout.addWidget(self.tree)

#         # ---- populate ----
#         self._fill(tokens_data)

#         # ---- status ----
#         self.status = QLabel(f"{len(tokens_data)} tokens loaded")
#         self.status.setStyleSheet("color:#aaa; font-size:11px;")
#         layout.addWidget(self.status)

#     def _greylist_all(self):
#         count = 0
#         self.tree.setUpdatesEnabled(False) # Performance optimization for large lists
        
#         for i in range(self.tree.topLevelItemCount()):
#             item = self.tree.topLevelItem(i)
#             # Column 2 is "Classification"
#             current_status = item.text(2)
            
#             # REQUIREMENT: Only apply to "unsorted"
#             if current_status == "unsorted":
#                 tok = item.data(0, Qt.UserRole)
#                 self._classify(tok, "greylist")
#                 count += 1
                
#         self.tree.setUpdatesEnabled(True)
#         self.status.setText(f"Greylisted {count} unsorted tokens")

#     def _fill(self, tokens_data):
#         self.tree.setUpdatesEnabled(False)
#         for td in tokens_data:
#             tok  = td.get("token", "")
#             freq = td.get("frequency", 0)
            
#             # --- CACHE LOGIC HERE ---
#             # Check if we have a locally cached classification from this session
#             # Otherwise, use the one provided by the backend
#             backend_cls = td.get("classification", "unsorted")
#             cls = self.gui.token_cache.get(tok, backend_cls)

#             item = QTreeWidgetItem()
#             item.setText(0, tok)
#             item.setData(1, Qt.DisplayRole, freq)
#             item.setText(2, cls)
#             item.setData(0, Qt.UserRole, tok)

#             self._paint(item, cls)
#             self.tree.addTopLevelItem(item)

#             # --- buttons ---
#             box = QWidget()
#             box.setStyleSheet("background: transparent;")
#             bl = QHBoxLayout(box)
#             bl.setContentsMargins(2, 1, 2, 1)
#             bl.setSpacing(2)
#             for label, cname, bg in (
#                 ("W", "whitelist",  "#27ae60"),
#                 ("G", "greylist",   "#d4a017"),
#                 ("B", "blacklist",  "#c0392b"),
#             ):
#                 b = QPushButton(label)
#                 b.setFixedSize(28, 22)
#                 # ... (keep existing button styling) ...
                
#                 # Connect to the local _classify method
#                 b.clicked.connect(
#                     lambda _checked, t=tok, c=cname: self._classify(t, c)
#                 )
#                 bl.addWidget(b)
#             self.tree.setItemWidget(item, 3, box)

#         self.tree.setUpdatesEnabled(True)

#     def _classify(self, token, classification):
#         # 1. Update the local memory cache immediately
#         self.gui.token_cache[token] = classification

#         # 2. Inform the backend
#         if self.gui.socket:
#             try:
#                 evt = EventFactory.gui_search_classify_token(token, classification)
#                 self.gui.socket.sendall(evt.to_json() + b"\n")
#             except Exception:
#                 pass

#         # 3. Update the UI in the current dialog
#         for i in range(self.tree.topLevelItemCount()):
#             item = self.tree.topLevelItem(i)
#             if item.data(0, Qt.UserRole) == token:
#                 item.setText(2, classification)
#                 self._paint(item, classification)
#                 # Note: We don't break here just in case the same token 
#                 # appears twice (though unlikely in this view)
        
#         self.status.setText(f"'{token}' → {classification} (cached)")

#     # ---------------------------------------------------------- row colour
#     def _paint(self, item, classification):
#         bg = self._CLR_BG.get(classification)
#         fg = self._CLR_FG.get(classification)
#         if bg and fg:
#             bg_brush = QBrush(bg)
#             fg_brush = QBrush(fg)
#             for c in range(3):
#                 item.setBackground(c, bg_brush)
#                 item.setForeground(c, fg_brush)
#         else:
#             # unsorted → clear back to palette defaults
#             for c in range(3):
#                 item.setData(c, Qt.BackgroundRole, None)
#                 item.setData(c, Qt.ForegroundRole, None)

#     # --------------------------------------------------------- double-click
#     def _on_double_click(self, item, _col):
#         tok = item.data(0, Qt.UserRole)
#         if tok:
#             self.selected_token = tok
#             self.accept()
