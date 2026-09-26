# gui_client.py
# magnet_sorter: GUI client for Elixir backend

import os
os.environ["QT_LOGGING_RULES"] = "qt.qpa.*=false"

import sys
from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (
    QApplication,
    QLabel,
    QWidget,
    QVBoxLayout,
    QMenuBar,
    QTabWidget,
)
from gui_theme import set_app_theme, apply_theme
from gui_json_event_handler import EventFactory
from gui_menu import init_menu
from gui_logic import attempt_connection, save_geometry, restore_geometry

from gui_stats import build_stats_tab
from gui_pf_tab import build_pf_tab
#from gui_torrents_tab import build_torrent_tab
#from gui_pf_monitor import build_pf_tab
#from gui_search_tab import build_search_tab
#from gui_sort_tab import build_sort_tab

#from gui_torrent_view import save_column_widths, restore_column_widths

class GUIMagnetSorter(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("magnet_sorter")
        self.setGeometry(100, 100, 1280, 760)

        self.backend = ('localhost', 4040)
        self.socket = None
        self.notifier = None
        self.buffer = ""

        self.labels = {}
        self.totals = {}

        # Track maximized state for column-width profiles
        self._was_maximized = False

        # === Main Layout + Menu ===
        self.layout = QVBoxLayout(self)
        # Parent the menu bar to the window: on macOS a parentless QMenuBar
        # becomes the global native menu bar at construction time and gets
        # lost for a plain QWidget window.
        self.menu_bar = QMenuBar(self)
        self.menu_bar.setNativeMenuBar(False)
        self.layout.setMenuBar(self.menu_bar)
        init_menu(self)

        # Header
        self.header = QLabel("Init...")
        self.header.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.header.setMinimumHeight(36)
        self.header.setStyleSheet(apply_theme("summary", kind="default"))

        self.layout.addWidget(self.header)

        # === Tab Widget ===
        self.tabs = QTabWidget()
        self.layout.addWidget(self.tabs)

        build_stats_tab(self)
        #build_torrent_tab(self)
        build_pf_tab(self)
        #build_search_tab(self)
        #build_sort_tab(self)

        # Initialize abs placeholders
        self.init_abs_placeholders()

        # Reconnect timer
        self.reconnect_timer = QTimer(self)
        self.reconnect_timer.timeout.connect(lambda: attempt_connection(self))
        self.reconnect_timer.start(500)

        restore_geometry(self)

        # Restore column widths after geometry is set
        #QTimer.singleShot(50, self._restore_all_column_widths)

    def init_abs_placeholders(self):
        """Placeholders will be populated on first backend message."""

    def _is_maximized(self) -> bool:
        return bool(self.windowState() & Qt.WindowMaximized)

    # def _save_all_column_widths(self):
    #     """Save column widths for every tree that has a _view_id."""
    #     maximized = self._is_maximized()
    #     for tree in self._all_view_trees():
    #         view_id = tree.property("_view_id")
    #         if view_id:
    #             save_column_widths(tree, view_id, maximized)

    # def _restore_all_column_widths(self):
    #     """Restore column widths for every tree that has a _view_id."""
    #     maximized = self._is_maximized()
    #     self._was_maximized = maximized
    #     for tree in self._all_view_trees():
    #         view_id = tree.property("_view_id")
    #         if view_id:
    #             restore_column_widths(tree, view_id, maximized)

    # def _all_view_trees(self):
    #     """Yield all torrent-view trees we manage."""
    #     trees = []
    #     if hasattr(self, 'torrent_tree') and self.torrent_tree:
    #         trees.append(self.torrent_tree)
    #     if hasattr(self, 'search_tree') and self.search_tree:
    #         trees.append(self.search_tree)
    #     return trees

    # ---- window state change: maximized ↔ normal ----
    # def changeEvent(self, event):
    #     super().changeEvent(event)
    #     if event.type() == event.Type.WindowStateChange:
    #         now_maximized = self._is_maximized()
    #         if now_maximized != self._was_maximized:
    #             # Save widths under the OLD profile before switching
    #             for tree in self._all_view_trees():
    #                 view_id = tree.property("_view_id")
    #                 # if view_id:
    #                 #     save_column_widths(tree, view_id, self._was_maximized)
    #             self._was_maximized = now_maximized
    #             # Restore widths for the NEW profile
    #             for tree in self._all_view_trees():
    #                 view_id = tree.property("_view_id")
    #                 # if view_id:
    #                 #     restore_column_widths(tree, view_id, now_maximized)

    def closeEvent(self, event):
        try:
            #self._save_all_column_widths()
            save_geometry(self)
            if self.socket:
                start_event = EventFactory.gui_exit().to_json()
                self.socket.sendall(start_event + b"\n")
        except Exception:
            pass
        finally:
            if self.notifier:
                self.notifier.setEnabled(False)
                self.notifier.deleteLater()
                self.notifier = None
            if self.socket:
                self.socket.close()
                self.socket = None
        event.accept()


if __name__ == "__main__":
    # Render menus inside the window on macOS, like on Windows/Linux.
    QApplication.setAttribute(Qt.AA_DontUseNativeMenuBar, True)
    app = QApplication(sys.argv)
    set_app_theme(app)
    window = GUIMagnetSorter()
    window.show()
    sys.exit(app.exec())
