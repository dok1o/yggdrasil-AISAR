# gui_menu.py
# Menu setup and action handlers for magnet_sorter GUI

from PySide6.QtGui import QAction, QGuiApplication
from PySide6.QtWidgets import (
    QDialog,
    QMessageBox,
    QApplication,
)
from gui_settings import write_settings_file
from gui_json_event_handler import EventFactory
from gui_logic import copy_stats, save_geometry
from gui_client_subwindows import (
    SettingsDialog,
    MagnetInputDialog
    #FidLookupDialog,
)

def init_menu(window):
    menu_bar = window.menu_bar
    
    # --- File ---
    file_menu = menu_bar.addMenu("File")
    act_add_file = QAction("Add File...", window)
    act_add_folder = QAction("Add Folder...", window)
    act_create_mdf = QAction("Create MDF", window)
    act_load_mag = QAction("Load Magnets...", window)
    act_new_tab = QAction("New Tab", window)
    act_close_tab = QAction("Close Tab", window)
    act_exit = QAction("Exit", window)
    
    act_add_file.setEnabled(False)
    act_add_folder.setEnabled(False)
    act_create_mdf.setEnabled(False)
    act_new_tab.setEnabled(False)
    act_close_tab.setEnabled(False)
    
    act_add_file.triggered.connect(lambda: on_placeholder(window, "Add File"))
    act_add_folder.triggered.connect(lambda: on_placeholder(window, "Add Folder"))
    act_create_mdf.triggered.connect(lambda: on_placeholder(window, "Create MDF"))
    act_load_mag.triggered.connect(lambda: on_load_magnets(window))
    act_exit.triggered.connect(window.close)
    
    file_menu.addAction(act_add_file)
    file_menu.addAction(act_add_folder)
    file_menu.addAction(act_create_mdf)
    file_menu.addAction(act_load_mag)
    file_menu.addSeparator()
    file_menu.addAction(act_new_tab)
    file_menu.addAction(act_close_tab)
    file_menu.addAction(act_exit)
    
    # --- Edit ---
    edit_menu = menu_bar.addMenu("Edit")
    act_find = QAction("Find...", window)
    act_settings = QAction("Settings", window)
    act_plugins = QAction("Plugins", window)
    act_review_data = QAction("Review Data", window)
    act_copy_stats = QAction("Copy Stats", window)

    act_find.setEnabled(False)
    act_plugins.setEnabled(False)
    act_review_data.setEnabled(False)

    act_find.triggered.connect(lambda: on_placeholder(window, "Find..."))
    act_settings.triggered.connect(lambda: open_settings(window))
    act_plugins.triggered.connect(lambda: on_placeholder(window, "Plugins"))
    act_review_data.triggered.connect(lambda: on_placeholder(window, "Review Data"))
    act_copy_stats.triggered.connect(lambda: on_copy(window))
    
    edit_menu.addAction(act_find)
    edit_menu.addAction(act_settings)
    edit_menu.addAction(act_plugins)
    edit_menu.addAction(act_review_data)
    edit_menu.addSeparator()
    edit_menu.addAction(act_copy_stats)
    
    # --- View ---
    view_menu = menu_bar.addMenu("View")
    act_sidebar = QAction("Sidebar", window)
    act_theme = QAction("Themes", window)
    act_tab_a = QAction("Tab A", window)
    act_notif = QAction("Notifications", window)

    act_sidebar.setCheckable(True)
    act_sidebar.setChecked(False)
    act_sidebar.setEnabled(False)
    act_theme.setEnabled(False)
    act_tab_a.setEnabled(False)
    act_notif.setEnabled(False)

    act_sidebar.triggered.connect(lambda: on_placeholder(window, "Sidebar"))
    act_theme.triggered.connect(lambda: on_placeholder(window, "Themes"))
    act_tab_a.triggered.connect(lambda: on_placeholder(window, "Tab A"))
    act_notif.triggered.connect(lambda: on_placeholder(window, "Notifications"))
    
    view_menu.addAction(act_sidebar)
    view_menu.addAction(act_theme)
    view_menu.addSeparator()
    view_menu.addAction(act_tab_a)
    view_menu.addSeparator()
    view_menu.addAction(act_notif)
    
    # --- Data (New) ---
    data_menu = menu_bar.addMenu("Data")
    act_profiles = QAction("Profiles", window)
    act_bookmarks = QAction("Bookmarks", window)
    act_history = QAction("History", window)
    act_cache = QAction("Cache", window)

    act_profiles.setEnabled(False)
    act_bookmarks.setEnabled(False)
    act_history.setEnabled(False)
    act_cache.setEnabled(False)

    data_menu.addAction(act_profiles)
    data_menu.addAction(act_bookmarks)
    data_menu.addAction(act_history)
    data_menu.addAction(act_cache)
    
    # --- Help ---
    help_menu = menu_bar.addMenu("Help")
    act_guide = QAction("User Guide", window)
    act_about = QAction("About", window)
    act_guide.setEnabled(False)
    act_about.setEnabled(False)
    act_guide.triggered.connect(lambda: on_placeholder(window, "User Guide"))
    act_about.triggered.connect(lambda: on_placeholder(window, "About"))
    help_menu.addAction(act_guide)
    help_menu.addSeparator()
    help_menu.addAction(act_about)
    
    # --- Debug ---
    debug_menu = menu_bar.addMenu("Debug")
    act_restart = QAction("Restart", window)
    act_restart.triggered.connect(lambda: on_restart(window))
    debug_menu.addAction(act_restart)

def on_placeholder(window, action_name):
    """Placeholder for visually disabled menu items. Prevents silent failures."""
    print(f"[GUI] Placeholder triggered: {action_name} (disabled)")

# --- Action handlers ---

def on_load_magnets(window):
    dialog = MagnetInputDialog(window)
    if dialog.exec() == QDialog.Accepted:
        magnets = dialog.get_lines()
        events = EventFactory.gui_input_loadmagnets(magnets)
        try:
            for evt in events:
                window.socket.sendall(evt.to_json() + b"\n")
            window.header.setText(f"Sent {len(events)} magnets")
        except Exception as e:
            QMessageBox.warning(
                window, "Error", f"Failed to send magnets:\n{e}",
            )

def open_settings(window):
    dialog = SettingsDialog(window)
    
    # Show dialog and wait for user interaction
    if dialog.exec() == QDialog.Accepted:
        current_settings = dialog.get_current_settings()
        original_settings = dialog.original_settings
        
        # Compare current vs original
        has_changes = False
        for key in set(current_settings.keys()) | set(original_settings.keys()):
            if current_settings.get(key) != original_settings.get(key):
                has_changes = True
                break
                
        if has_changes:
            try:
                write_settings_file(current_settings)
                window.header.setText("Settings applied. Restarting...")
                on_restart(window)
            except Exception as e:
                QMessageBox.critical(window, "Config Error", f"Failed to save settings:\n{e}")
        else:
            window.header.setText("No changes detected.")


def on_copy(window):
    lines = [label.text() for label in window.labels.values()]
    text = "\n".join(lines)
    clipboard = QGuiApplication.clipboard()
    clipboard.setText(text)
    window.header.setText("Progress stats copied to clipboard.")

def on_restart(window):
    try:
        if window.socket:
            evt = EventFactory.gui_exit().to_json()
            window.socket.sendall(evt + b"\n")
    except Exception:
        pass

    print("[GUI] Triggering Full Restart...")
    copy_stats(window)
    save_geometry(window)

    QApplication.exit(5)

# def on_start(window):
#     data = read_settings_file()
#     data["crawling_status_flag"] = 1
#     write_settings_file(data)
#     try:
#         if window.socket:
#             evt = EventFactory.gui_settings_change().to_json()
#             window.socket.sendall(evt + b"\n")
#             window.header.setText("Crawling started")
#     except Exception as e:
#         print(f"Start error: {e}")


# def on_stop(window):
#     data = read_settings_file()
#     data["crawling_status_flag"] = 0
#     write_settings_file(data)
#     try:
#         if window.socket:
#             evt = EventFactory.gui_settings_change().to_json()
#             window.socket.sendall(evt + b"\n")
#             window.header.setText("Crawling stopped")
#     except Exception as e:
#         print(f"Stop error: {e}")


# def on_crawl_restart(window):
#     try:
#         if window.socket:
#             evt = EventFactory.gui_restart_crawl().to_json()
#             window.socket.sendall(evt + b"\n")
#             window.header.setText("Restarting crawling")
#     except Exception as e:
#         print(f"Restart crawl error: {e}")

# def on_lookup_fid(window):
#     dialog = FidLookupDialog(window)
#     if dialog.exec() == QDialog.Accepted:
#         fids = dialog.get_fids()
#         if not fids:
#             QMessageBox.warning(
#                 window, "Invalid", "No valid 40-char hex FIDs found.",
#             )
#             return
#         try:
#             if window.socket:
#                 evt = EventFactory.gui_debug_lookup_fid(fids)
#                 window.socket.sendall(evt.to_json() + b"\n")
#                 window.header.setText(f"Looking up {len(fids)} FID(s)…")
#         except Exception as e:
#             QMessageBox.warning(
#                 window, "Error", f"Failed to send lookup:\n{e}",
#             )


# def on_enable_pf(window):
#     data = read_settings_file()
#     data["use_pf_flag"] = 1
#     write_settings_file(data)
#     try:
#         if window.socket:
#             evt = EventFactory.gui_pf_enable().to_json()
#             window.socket.sendall(evt + b"\n")
#             evt2 = EventFactory.gui_settings_change().to_json()
#             window.socket.sendall(evt2 + b"\n")
#             window.header.setText("ProtocolF mode enabled")
#     except Exception as e:
#         print(f"Enable PF error: {e}")


# def on_publish_fid(window):
#     try:
#         if window.socket:
#             evt = EventFactory.gui_pf_rendezvous_publish().to_json()
#             window.socket.sendall(evt + b"\n")
#             window.header.setText("Publishing local FID…")
#     except Exception as e:
#         QMessageBox.warning(window, "Error", f"Failed to publish FID:\n{e}")


# def on_seek_fid(window):
#     dialog = FidLookupDialog(window)
#     if dialog.exec() == QDialog.Accepted:
#         fids = dialog.get_fids()
#         if not fids:
#             QMessageBox.warning(
#                 window, "Invalid", "No valid 40-char hex FIDs found.",
#             )
#             return
#         try:
#             if window.socket:
#                 evt = EventFactory.gui_pf_rendezvous_seek(fids[0]).to_json()
#                 window.socket.sendall(evt + b"\n")
#                 window.header.setText(f"Seeking FID {fids[0][:8]}…")
#         except Exception as e:
#             QMessageBox.warning(window, "Error", f"Failed to seek FID:\n{e}")


# def on_pf_selftest(window):
#     try:
#         if window.socket:
#             evt = EventFactory.gui_pf_file_selftest().to_json()
#             window.socket.sendall(evt + b"\n")
#             window.header.setText("PF transfer self-test started…")
#     except Exception as e:
#         QMessageBox.warning(window, "Error", f"Failed to start self-test:\n{e}")



