import sys
import os
import re
from pathlib import Path
from collections import defaultdict

from PySide6.QtWidgets import (QApplication, QWidget, QVBoxLayout, QHBoxLayout, 
                             QPushButton, QScrollArea, QGridLayout,
                             QListWidget, QListWidgetItem, QLabel, QSplitter,
                             QCheckBox, QStatusBar, QMainWindow, QSizePolicy)
from PySide6.QtCore import Qt, QMimeData, QTimer, Signal
from PySide6.QtGui import QDrag

# =======================
# CONFIGURATION
# =======================

# Don't log: qt.qpa.theme.gnome: dbus reply error
os.environ["QT_LOGGING_RULES"] = "qt.qpa.*=false"

LIB_PATH = "./backend/lib/"
EXCLUDE_FILE = "copy_machine_exclude.txt"

# Modules to ignore when generating the "calls -> ..." tree output
IGNORE_CALLS_TO = {
    "IdGen", "TryETS", "Printer", "Timeout", "Bootstrap", "LogEvery", "TTL", 
    "Logger", "Enum", "Map", "Process", "Task", "IO", 
    "System", "MapSet", "Keyword", "Integer", "String", "File", "Base"
    "GenS.Metrics"
}

# Dark Theme Stylesheet
DARK_STYLE = """
    QWidget {
        background-color: #2b2b2b;
        color: #efefef;
        font-family: 'Segoe UI', sans-serif;
        font-size: 13px;
    }
    QScrollArea {
        border: none;
        background-color: #2b2b2b;
    }
    QListWidget {
        background-color: #1e1e1e;
        border: 1px solid #3f3f4f;
        border-radius: 4px;
        outline: none;
    }
    QListWidget::item {
        padding: 8px;
        border-bottom: 1px solid #333;
    }
    QListWidget::item:hover {
        background-color: #442222;
        color: #ff9999;
    }
    QPushButton {
        background-color: #3c3f41;
        border: 1px solid #555;
        border-radius: 4px;
        padding: 6px;
        color: #eee;
    }
    QPushButton:hover {
        background-color: #4c5052;
    }
    QStatusBar {
        background-color: #222;
        border-top: 1px solid #444;
        color: #aaa;
    }
    QCheckBox {
        spacing: 5px;
        color: #ccc;
    }
    QCheckBox::indicator {
        width: 16px;
        height: 16px;
    }
"""

# =======================
# PARSING LOGIC (From ms_tree)
# =======================

MODULE_RE = re.compile(r"^\s*defmodule\s+([\w\.]+)")
FUNC_RE   = re.compile(r"^\s*defp?\s+(\w+)\s*\(([^)]*)\)")
CALL_RE   = re.compile(r"([A-Z]\w*(?:\.[A-Z]\w+)*\.\w+)\s*\(")

class ElixirParser:
    @staticmethod
    def split_args(arg_str: str):
        args, current, depth, in_string, quote_char = [], '', 0, False, ''
        for ch in arg_str:
            if ch in ('"', "'"):
                if in_string and ch == quote_char:
                    in_string = False
                elif not in_string:
                    in_string, quote_char = True, ch
                current += ch
                continue
            if in_string:
                current += ch
                continue
            if ch in "({[": depth += 1
            elif ch in ")}]": depth = max(0, depth - 1)
            elif ch == "," and depth == 0:
                args.append(current.strip())
                current = ''
                continue
            current += ch
        if current.strip():
            args.append(current.strip())
        return [a for a in args if a]

    @staticmethod
    def extract_children(content: str):
        lines = content.splitlines()
        block = ""
        collecting = False
        depth = 0
        
        for raw in lines:
            line = re.sub(r"#.*", "", raw.strip())
            if not line: continue
            
            if not collecting:
                if re.match(r"^children\s*=", line):
                    collecting = True
                    if "[" in line:
                        depth = 1
                        block += line.split("[", 1)[1] + " "
                    continue
            else:
                depth += line.count("[")
                depth -= line.count("]")
                block += line + " "
                if depth <= 0: break
                
        mods = re.findall(r"\b([A-Z]\w*(?:\.[A-Z]\w+)*)\b", block)
        return sorted(set(m for m in mods if m not in {"Supervisor", "Application", "Task"}))

    @staticmethod
    def parse_file(path, include_defp=False):
        """Returns stats and structure."""
        text = path.read_text(encoding="utf-8", errors="ignore")
        lines = text.splitlines()
        
        loc = 0
        for l in lines:
            if l.strip() and not l.strip().startswith("#"):
                loc += 1

        structure = []
        current_module = None
        current_funcs = []
        current_aliases = [] # <--- NEW: Store aliases
        calls = defaultdict(list)
        lines_accum = []

        for line in lines:
            clean_line = line.strip()
            
            # 1. Module Detection
            if mmod := MODULE_RE.match(line):
                # Save previous module if exists
                if current_module:
                    structure.append({
                        "module": current_module,
                        "aliases": current_aliases, # <--- NEW
                        "functions": current_funcs,
                        "calls": calls,
                        "supervised": ElixirParser.extract_children("\n".join(lines_accum))
                    })
                    # Reset
                    current_funcs, calls, lines_accum, current_aliases = [], defaultdict(list), [], []
                
                current_module = mmod.group(1)
                continue

            if not current_module: continue
            lines_accum.append(line)

            # 2. Alias Detection (NEW)
            if clean_line.startswith("alias "):
                # Remove comments and "alias " prefix
                content = clean_line.split("#")[0].strip()[6:] 
                current_aliases.append(content)
                continue

            # 3. Function Detection
            is_def = clean_line.startswith("def ")
            is_defp = clean_line.startswith("defp ")
            
            if (is_def or (include_defp and is_defp)) and (mf := FUNC_RE.match(line)):
                name = mf.group(1)
                args = ElixirParser.split_args(mf.group(2))
                func_id = f"{name}_{len(current_funcs)}"
                current_funcs.append({
                    "id": func_id,
                    "name": name,
                    "args": args,
                    "arity": len(args),
                    "type": "defp" if is_defp else "def"
                })
                continue
            
            # 4. Call Detection
            if current_funcs:
                curr_id = current_funcs[-1]["id"]
                for call in CALL_RE.findall(line):
                    root_mod = call.split(".", 1)[0]
                    if root_mod not in IGNORE_CALLS_TO and not call.startswith(current_module):
                        calls[curr_id].append(call)

        # Flush last module
        if current_module:
            structure.append({
                "module": current_module,
                "aliases": current_aliases, # <--- NEW
                "functions": current_funcs,
                "calls": calls,
                "supervised": ElixirParser.extract_children("\n".join(lines_accum))
            })
            
        return structure, loc

# =======================
# UI COMPONENTS
# =======================

class ModuleButton(QPushButton):
    # Custom signal: module_name
    exclude_requested = Signal(str) 

    def __init__(self, module_name, file_path, is_selected=False):
        super().__init__(module_name)
        self.file_path = file_path
        self.module_name = module_name
        self.setCheckable(True)
        self.setChecked(is_selected)
        self.setMinimumHeight(40)
        self.setCursor(Qt.OpenHandCursor)
        self.update_style()
        self.toggled.connect(self.update_style)

    def update_style(self):
        if self.isChecked():
            self.setStyleSheet("""
                background-color: #2980b9; 
                color: white; 
                font-weight: bold; 
                border: 1px solid #3498db;
            """)
        else:
            self.setStyleSheet("""
                background-color: #3c3f41; 
                color: #bbbbbb; 
                border: 1px solid #555555;
            """)

    def mouseMoveEvent(self, e):
        if e.buttons() == Qt.LeftButton:
            drag = QDrag(self)
            mime = QMimeData()
            mime.setText(self.module_name)
            drag.setMimeData(mime)
            drag.exec_(Qt.MoveAction)
            
    def mouseDoubleClickEvent(self, e):
        # Req 4: Double click to exclude
        if e.button() == Qt.LeftButton:
            self.exclude_requested.emit(self.module_name)

class ExclusionList(QListWidget):
    def __init__(self, parent_window):
        super().__init__()
        self.parent_window = parent_window
        self.setAcceptDrops(True)
        self.setToolTip("Drag modules here or double-click grid items to exclude.")
        self.itemDoubleClicked.connect(self.remove_exclusion)

    def dragEnterEvent(self, event):
        if event.mimeData().hasText():
            event.accept()
        else:
            event.ignore()

    def dragMoveEvent(self, event):
        event.accept()

    def dropEvent(self, event):
        module_name = event.mimeData().text()
        self.parent_window.add_exclusion(module_name)
        event.accept()

    def remove_exclusion(self, item):
        self.parent_window.remove_exclusion(item.text())

class ContextBuilder(QMainWindow):
    def __init__(self):
        super().__init__()
        self.buttons = {} # Map module_name -> ModuleButton
        
        # State
        self.known_modules_order = [] # List of tuples (name, path) to maintain order
        self.selected_modules = set() # Set of names currently selected
        
        self.init_ui()
        self.load_exclusions_and_refresh()

    def init_ui(self):
        self.setWindowTitle("Elixir Context Machine & Tree")
        self.resize(100, 1000)
        self.setGeometry(200, 200, 100, 800)
        
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        central_widget.setStyleSheet(DARK_STYLE)
        
        main_layout = QVBoxLayout(central_widget)

        # --- Top Controls ---
        controls = QHBoxLayout()
        controls.setSpacing(2)      # Gap between buttons
        controls.setContentsMargins(5, 5, 5, 10) # Margins: Left, Top, Right, Bottom
        
        size_policy = QSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
         
        self.btn_refresh = QPushButton("Refresh Data")
        self.btn_refresh.clicked.connect(self.refresh_modules)
        self.btn_refresh.setMinimumHeight(36)
        self.btn_refresh.setSizePolicy(size_policy)
        
        self.btn_copy_tree = QPushButton("Copy Program Tree")
        self.btn_copy_tree.clicked.connect(self.copy_tree)
        self.btn_copy_tree.setMinimumHeight(36)
        self.btn_copy_tree.setSizePolicy(size_policy)
        
        self.btn_copy = QPushButton("Copy Selected Modules")
        self.btn_copy.clicked.connect(self.copy_content)
        self.btn_copy.setMinimumHeight(36)
        self.btn_copy.setSizePolicy(size_policy)

        self.btn_copy.setStyleSheet("""
            QPushButton {
                background-color: #27ae60; 
                color: white; 
                font-weight: bold;
                border: 1px solid #219150;
                border-radius: 4px;
            }
            QPushButton:hover { background-color: #2ecc71; }
            QPushButton:pressed { background-color: #219150; }
        """)
        
        self.btn_clear = QPushButton("Clear Selection")
        self.btn_clear.clicked.connect(self.clear_selection)
        self.btn_clear.setMinimumHeight(36)
        self.btn_clear.setSizePolicy(size_policy)
        
        controls.addWidget(self.btn_refresh, 1)
        controls.addWidget(self.btn_copy_tree, 1)
        controls.addWidget(self.btn_copy, 1)
        controls.addWidget(self.btn_clear, 1)
        main_layout.addLayout(controls)

        # --- Middle Splitter ---
        self.splitter = QSplitter(Qt.Horizontal)

        # Sidebar (Exclusions)
        excl_container = QWidget()
        excl_layout = QVBoxLayout(excl_container)
        excl_layout.setContentsMargins(0, 0, 5, 0)
        
        lbl = QLabel("EXCLUSIONS")
        lbl.setStyleSheet("font-weight: bold; color: #7f8c8d; margin-bottom: 5px;")
        excl_layout.addWidget(lbl)
        
        self.excl_list = ExclusionList(self)
        excl_layout.addWidget(self.excl_list)
        
        # Grid area
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll_content = QWidget()
        self.grid = QGridLayout(self.scroll_content)
        self.grid.setAlignment(Qt.AlignTop | Qt.AlignLeft)
        self.grid.setSpacing(8)
        self.scroll.setWidget(self.scroll_content)

        self.splitter.addWidget(excl_container)
        self.splitter.addWidget(self.scroll)
        self.splitter.setStretchFactor(1, 4)
        
        main_layout.addWidget(self.splitter)
        
        # --- Status Bar ---
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        
        # Status Bar Controls
        widget_container = QWidget()
        sb_layout = QHBoxLayout(widget_container)
        sb_layout.setContentsMargins(10, 0, 10, 0)
        
        self.stats_label = QLabel("Ready")
        self.stats_label.setStyleSheet("font-family: monospace;")
        
        self.chk_comments = QCheckBox("Copy selected with comments")
        self.chk_comments.setChecked(False) # Default OFF
        
        self.chk_defps = QCheckBox("Copy tree with defps")
        self.chk_defps.setChecked(False) # Default OFF
        
        sb_layout.addWidget(self.stats_label, 1)
        sb_layout.addWidget(self.chk_defps)
        sb_layout.addWidget(self.chk_comments)
        
        self.status_bar.addWidget(widget_container, 1)

    # =======================
    # LOGIC
    # =======================

    def get_exclusions(self):
        if os.path.exists(EXCLUDE_FILE):
            with open(EXCLUDE_FILE, 'r') as f:
                return [line.strip().replace('"', '') for line in f.readlines() if line.strip()]
        return []

    def save_exclusions(self, exclusions):
        with open(EXCLUDE_FILE, 'w') as f:
            for item in sorted(exclusions):
                f.write(f'"{item}"\n')

    def load_exclusions_and_refresh(self):
        # Initial load
        self.excl_list.clear()
        for item in sorted(self.get_exclusions()):
            self.excl_list.addItem(item)
        self.refresh_modules()

    def add_exclusion(self, name):
        """Move from Grid to Sidebar."""
        exclusions = self.get_exclusions()
        if name not in exclusions:
            exclusions.append(name)
            self.save_exclusions(exclusions)
            
            # Req 5: If selected moved to excluded, deselect it
            if name in self.selected_modules:
                self.selected_modules.remove(name)
            
            self.excl_list.addItem(name)
            self.excl_list.sortItems()
            self.refresh_grid_view() # Don't re-scan FS, just redraw

    def remove_exclusion(self, name):
        """Move from Sidebar to Grid."""
        exclusions = self.get_exclusions()
        if name in exclusions:
            exclusions.remove(name)
            self.save_exclusions(exclusions)
            
            # Find list item and remove
            items = self.excl_list.findItems(name, Qt.MatchExactly)
            for item in items:
                self.excl_list.takeItem(self.excl_list.row(item))
                
            self.refresh_grid_view()
            
    def clear_selection(self):
        """Deselects all modules in the grid."""
        # Unchecking the buttons will automatically trigger handle_selection 
        # via the toggled signal, which updates the self.selected_modules set.
        for btn in self.buttons.values():
            if btn.isChecked():
                btn.setChecked(False)
        
        # Explicit safety clear
        self.selected_modules.clear()

    def refresh_modules(self):
        """Scans filesystem, updates known modules list (append new), maintains selection."""
        lib_dir = Path(LIB_PATH)
        if not lib_dir.exists():
            self.stats_label.setText(f"Error: {LIB_PATH} not found")
            return

        # 1. Scan current modules
        current_scan = {}
        for path in lib_dir.rglob("*.ex"):
            try:
                content = path.read_text(encoding="utf-8", errors="ignore")
                matches = re.findall(r"defmodule\s+([\w\.]+)", content)
                for m_name in matches:
                    current_scan[m_name] = path
            except: pass

        # 2. Update Order Strategy
        # Remove modules that no longer exist from known list
        # Remove deleted modules from selection
        self.known_modules_order = [
            (name, path) for name, path in self.known_modules_order 
            if name in current_scan
        ]
        
        # Clean selection set
        existing_names = set(current_scan.keys())
        self.selected_modules = self.selected_modules.intersection(existing_names)

        # 3. Add new modules to the end
        known_names = set(name for name, _ in self.known_modules_order)
        new_names = sorted(list(existing_names - known_names))
        
        for name in new_names:
            self.known_modules_order.append((name, current_scan[name]))

        self.refresh_grid_view()

    def refresh_grid_view(self):
        """Rebuilds the grid buttons based on known_modules and exclusions."""
        # Clear existing buttons
        for btn in self.buttons.values():
            self.grid.removeWidget(btn)
            btn.deleteLater()
        self.buttons = {}

        exclusions = set(self.get_exclusions())
        
        # Filter visible modules
        visible_modules = [
            (name, path) for name, path in self.known_modules_order
            if name not in exclusions
        ]

        COLS = 4
        for i, (m_name, path) in enumerate(visible_modules):
            # Create button
            is_sel = m_name in self.selected_modules
            btn = ModuleButton(m_name, path, is_selected=is_sel)
            
            # Connect signals
            btn.toggled.connect(lambda c, n=m_name: self.handle_selection(n, c))
            btn.exclude_requested.connect(self.add_exclusion)
            
            self.grid.addWidget(btn, i // COLS, i % COLS)
            self.buttons[m_name] = btn

        self.update_stats()

    def handle_selection(self, name, checked):
        if checked:
            self.selected_modules.add(name)
        else:
            self.selected_modules.discard(name)

    def update_stats(self):
        """Calculates LOC and counts."""
        # This can be slightly expensive so we could cache it, but for <1000 files it's fine
        exclusions = set(self.get_exclusions())
        
        total_mods = len(self.known_modules_order)
        active_mods = 0
        
        total_loc = 0
        active_loc = 0

        for name, path in self.known_modules_order:
            # Quick LOC count
            try:
                # Basic line count not starting with #
                with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = [1 for l in f if l.strip() and not l.strip().startswith('#')]
                    loc = sum(lines)
            except: 
                loc = 0
                
            total_loc += loc
            if name not in exclusions:
                active_mods += 1
                active_loc += loc
        
        excl_mods = total_mods - active_mods
        excl_loc = total_loc - active_loc
        
        txt = (f"Total: {total_mods} mods ({total_loc} LOC) | "
               f"Active: {active_mods} ({active_loc} LOC) | "
               f"Excluded: {excl_mods} ({excl_loc} LOC)")
        self.stats_label.setText(txt)

    # =======================
    # ACTIONS
    # =======================

    def copy_content(self):
        """Copies content of SELECTED modules."""
        if not self.selected_modules:
            self.btn_copy.setText("Nothing selected")
            QTimer.singleShot(1500, lambda: self.btn_copy.setText("Copy Selected Modules"))
            return

        keep_comments = self.chk_comments.isChecked()
        final_output = []
        processed_paths = set() 
        
        # We iterate known_modules to maintain order
        for name, path in self.known_modules_order:
            if name in self.selected_modules and path not in processed_paths:
                try:
                    text = path.read_text(encoding="utf-8", errors="ignore")
                    if not keep_comments:
                        # Strip lines starting with #
                        lines = text.splitlines()
                        text = "\n".join([l for l in lines if not l.strip().startswith("#")])
                    
                    final_output.append(text)
                    processed_paths.add(path)
                except Exception as e:
                    print(f"Error reading {path}: {e}")

        QApplication.clipboard().setText("\n\n".join(final_output))
        
        orig = self.btn_copy.text()
        self.btn_copy.setText("Copied")
        QTimer.singleShot(1500, lambda: self.btn_copy.setText(orig))

    def copy_tree(self):
        """Copies tree of ALL non-excluded modules with statistics header."""
        exclusions = set(self.get_exclusions())
        
        # 1. Calculate Totals (X modules / Z1 LOC)
        all_unique_paths = set(path for _, path in self.known_modules_order)
        total_mods = len(self.known_modules_order)
        total_loc = 0
        
        # Pre-calculate Total LOC (count non-empty/non-comment lines)
        for path in all_unique_paths:
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                    total_loc += sum(1 for l in f if l.strip() and not l.strip().startswith('#'))
            except: pass

        # 2. Generate Tree & Calculate Shown Stats (Y modules / Z LOC)
        paths_to_process = sorted(list(all_unique_paths))
        if not paths_to_process:
            return

        include_defp = self.chk_defps.isChecked()
        
        tree_lines = []
        shown_mods = 0
        shown_loc = 0
        
        for path in paths_to_process:
            try:
                structs, file_loc = ElixirParser.parse_file(path, include_defp=include_defp)
                
                # Track if this file contributed any modules to add its LOC to stats
                file_contributed = False
                
                for mod in structs:
                    # Check exclusion
                    if mod['module'] in exclusions:
                        continue
                        
                    shown_mods += 1
                    file_contributed = True
                    
                    tree_lines.append(f"📦 {mod['module']}")
                    
                    # Aliases
                    for alias_str in mod.get("aliases", []):
                        tree_lines.append(f"alias {alias_str}")
                    
                    # Functions
                    for fn in mod["functions"]:
                        args = ", ".join(fn["args"])
                        prefix = "defp" if fn.get("type") == "defp" else "def"
                        tree_lines.append(f"   ├── {prefix} {fn['name']}({args})/{fn['arity']}")
                        
                        # Calls
                        calls = sorted(set(mod["calls"].get(fn["id"], [])))
                        if calls:
                            joined = ", ".join(calls)
                            tree_lines.append(f"   │   ├── calls → {joined}")
                    
                    if mod["supervised"]:
                        tree_lines.append(f"   │   ├── spv tree → {', '.join(mod['supervised'])}")
                    
                    tree_lines.append("") # Spacer
                
                if file_contributed:
                    shown_loc += file_loc

            except Exception as e:
                print(f"Error parsing {path}: {e}")

        # 3. Construct Final Output with Header
        header = f"MagnetSorter App: total {total_mods} modules / {total_loc} LOC, shown: {shown_mods} modules / {shown_loc} LOC:"
        final_text = header + "\n\n" + "\n".join(tree_lines)
        
        QApplication.clipboard().setText(final_text)

if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = ContextBuilder()
    window.show()
    sys.exit(app.exec())
