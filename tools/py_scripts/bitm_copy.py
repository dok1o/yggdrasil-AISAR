#!/usr/bin/env python3
"""
Go Context Builder v2 - Package-based organization
Groups Go files by package for easier browsing and selection.
"""

import sys
import os
import re
from pathlib import Path
from collections import defaultdict

from PySide6.QtWidgets import (QApplication, QWidget, QVBoxLayout, QHBoxLayout, 
                             QPushButton, QScrollArea, QGridLayout,
                             QListWidget, QLabel, QSplitter,
                             QCheckBox, QStatusBar, QMainWindow, QSizePolicy)
from PySide6.QtCore import Qt, QMimeData, QTimer, Signal
from PySide6.QtGui import QDrag

# =======================
# CONFIGURATION
# =======================

os.environ["QT_LOGGING_RULES"] = "qt.qpa.*=false"

LIB_PATH = "./bitm_internal/"
EXCLUDE_FILE = "go_copy_machine_exclude_v2.txt"

IGNORE_CALLS_TO = {
    "fmt", "log", "errors", "context", "time", "sync", "strings", "strconv",
    "bytes", "io", "os", "path", "filepath", "net", "http", "json", "encoding",
    "reflect", "sort", "math", "regexp", "bufio", "crypto", "hash", "testing",
    "runtime", "unsafe", "syscall", "atomic", "binary", "base64", "hex", "sql",
    "template", "flag", "embed", "slog",
    "fx", "zap", "gorm", "gin", "echo", "chi", "viper", "cobra", "prometheus",
}

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
        background-color: #223344;
        color: #99ccff;
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
# GO PARSING
# =======================

class GoParser:
    """Parser for Go source files."""
    
    PACKAGE_RE = re.compile(r'^\s*package\s+(\w+)')
    IMPORT_SINGLE_RE = re.compile(r'^\s*import\s+"([^"]+)"')
    IMPORT_ALIAS_RE = re.compile(r'^\s*(\w+)?\s*"([^"]+)"')
    TYPE_RE = re.compile(r'^\s*type\s+(\w+)\s+(struct|interface|func|\w+)')
    
    FUNC_SIG_RE = re.compile(
        r'^\s*func\s+'
        r'(?:\(\s*\w+\s+\*?(\w+)\s*\)\s+)?'
        r'(\w+)\s*'
        r'\(([^)]*)\)'
    )
    
    CALL_RE = re.compile(r'\b(\w+)\.(\w+)\s*\(')
    
    @staticmethod
    def get_package_name(path):
        """Quick extraction of just the package name."""
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
            for line in text.splitlines()[:20]:
                if m := GoParser.PACKAGE_RE.match(line.strip()):
                    return m.group(1)
        except:
            pass
        return None
    
    @staticmethod
    def parse_args(arg_str):
        if not arg_str or not arg_str.strip():
            return []
        
        args = []
        current = ''
        depth = 0
        
        for ch in arg_str:
            if ch in '([{':
                depth += 1
                current += ch
            elif ch in ')]}':
                depth -= 1
                current += ch
            elif ch == ',' and depth == 0:
                if current.strip():
                    args.append(current.strip())
                current = ''
            else:
                current += ch
        
        if current.strip():
            args.append(current.strip())
        
        return args
    
    @staticmethod
    def extract_return_type(line):
        match = re.search(r'\)\s*\(?([^{]+?)\)?\s*\{', line)
        if match:
            ret = match.group(1).strip()
            if ret and ret != '{':
                return ret
        return ""
    
    @staticmethod
    def parse_file(path, include_unexported=False):
        """Parse a Go file, return structure dict and LOC count."""
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            return None, 0
        
        lines = text.splitlines()
        loc = sum(1 for l in lines if l.strip() and not l.strip().startswith("//"))
        
        package_name = None
        imports = []
        types = []
        functions = []
        calls = defaultdict(set)
        
        in_import_block = False
        current_func_id = None
        brace_depth = 0
        
        for line in lines:
            stripped = line.strip()
            
            if not stripped or stripped.startswith("//"):
                continue
            
            code_part = stripped.split("//")[0].strip() if "//" in stripped else stripped
            brace_depth += code_part.count('{') - code_part.count('}')
            
            if m := GoParser.PACKAGE_RE.match(code_part):
                package_name = m.group(1)
                continue
            
            if code_part == "import (" or code_part.startswith("import ("):
                in_import_block = True
                continue
            
            if in_import_block:
                if code_part == ")" or code_part.startswith(")"):
                    in_import_block = False
                    continue
                if m := GoParser.IMPORT_ALIAS_RE.match(code_part):
                    alias = m.group(1) or ""
                    imp_path = m.group(2)
                    short_name = imp_path.split("/")[-1]
                    imports.append({
                        "alias": alias,
                        "path": imp_path,
                        "short": alias if alias else short_name
                    })
                continue
            
            if m := GoParser.IMPORT_SINGLE_RE.match(code_part):
                imp_path = m.group(1)
                short_name = imp_path.split("/")[-1]
                imports.append({
                    "alias": "",
                    "path": imp_path,
                    "short": short_name
                })
                continue
            
            if m := GoParser.TYPE_RE.match(code_part):
                type_name = m.group(1)
                type_kind = m.group(2)
                is_exported = type_name[0].isupper()
                
                if is_exported or include_unexported:
                    types.append({
                        "name": type_name,
                        "kind": type_kind,
                        "exported": is_exported
                    })
                continue
            
            if m := GoParser.FUNC_SIG_RE.match(code_part):
                receiver_type = m.group(1)
                func_name = m.group(2)
                args_str = m.group(3)
                
                is_exported = func_name[0].isupper()
                is_method = receiver_type is not None
                
                if is_exported or include_unexported:
                    func_id = f"{func_name}_{len(functions)}"
                    returns = GoParser.extract_return_type(code_part)
                    
                    func_info = {
                        "id": func_id,
                        "name": func_name,
                        "args": GoParser.parse_args(args_str),
                        "returns": returns,
                        "exported": is_exported,
                        "receiver": receiver_type,
                        "type": "method" if is_method else "func"
                    }
                    functions.append(func_info)
                    current_func_id = func_id
                else:
                    current_func_id = f"_unexported_{func_name}"
                continue
            
            if current_func_id and brace_depth > 0:
                for pkg, func_call in GoParser.CALL_RE.findall(code_part):
                    if pkg[0].islower() and pkg not in IGNORE_CALLS_TO:
                        if not current_func_id.startswith("_unexported_"):
                            calls[current_func_id].add(f"{pkg}.{func_call}")
            
            if brace_depth == 0:
                current_func_id = None
        
        return {
            "package": package_name,
            "imports": imports,
            "types": types,
            "functions": functions,
            "calls": {k: sorted(v) for k, v in calls.items()},
        }, loc


# =======================
# PACKAGE DATA STRUCTURE
# =======================

class PackageInfo:
    """Represents a Go package (collection of files with same package declaration in same directory)."""
    
    def __init__(self, pkg_id, directory, package_name):
        self.pkg_id = pkg_id
        self.directory = directory
        self.package_name = package_name
        self.files = []  # List of (relative_path, absolute_path) tuples
        self.total_loc = 0
    
    def add_file(self, rel_path, abs_path, loc):
        self.files.append((rel_path, abs_path))
        self.total_loc += loc
    
    @property
    def display_name(self):
        if self.directory and self.directory != ".":
            return f"{self.directory}"
        return self.package_name
    
    @property
    def file_count(self):
        return len(self.files)


# =======================
# UI COMPONENTS
# =======================

class PackageButton(QPushButton):
    """Button representing a Go package."""
    exclude_requested = Signal(str)

    def __init__(self, pkg_info: PackageInfo, is_selected=False):
        display_text = f"{pkg_info.display_name}\n{pkg_info.file_count} files · {pkg_info.total_loc} LOC"
        super().__init__(display_text)
        
        self.pkg_info = pkg_info
        self.pkg_id = pkg_info.pkg_id
        self.setCheckable(True)
        self.setChecked(is_selected)
        self.setMinimumHeight(65)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setCursor(Qt.OpenHandCursor)
        
        files_list = ', '.join(Path(f[0]).name for f in pkg_info.files)
        self.setToolTip(f"Package: {pkg_info.package_name}\nDir: {pkg_info.directory}\nFiles: {files_list}")
        self.update_style()
        self.toggled.connect(self.update_style)

    def update_style(self):
        base = "text-align: left; padding: 10px; border-radius: 6px;"
        if self.isChecked():
            self.setStyleSheet(f"""
                background-color: #2980b9; 
                color: white; 
                font-weight: bold; 
                border: 2px solid #3498db;
                {base}
            """)
        else:
            self.setStyleSheet(f"""
                background-color: #3c3f41; 
                color: #bbbbbb; 
                border: 1px solid #555555;
                {base}
            """)

    def mouseMoveEvent(self, e):
        if e.buttons() == Qt.LeftButton:
            drag = QDrag(self)
            mime = QMimeData()
            mime.setText(self.pkg_id)
            drag.setMimeData(mime)
            drag.exec_(Qt.MoveAction)

    def mouseDoubleClickEvent(self, e):
        if e.button() == Qt.LeftButton:
            self.exclude_requested.emit(self.pkg_id)


class ExclusionList(QListWidget):
    """Sidebar list for excluded packages."""
    
    def __init__(self, parent_window):
        super().__init__()
        self.parent_window = parent_window
        self.setAcceptDrops(True)
        self.setToolTip("Drag packages here to exclude.\nDouble-click to restore.")
        self.itemDoubleClicked.connect(self.remove_exclusion)

    def dragEnterEvent(self, event):
        if event.mimeData().hasText():
            event.accept()
        else:
            event.ignore()

    def dragMoveEvent(self, event):
        event.accept()

    def dropEvent(self, event):
        pkg_id = event.mimeData().text()
        self.parent_window.add_exclusion(pkg_id)
        event.accept()

    def remove_exclusion(self, item):
        self.parent_window.remove_exclusion(item.text())


class ContextBuilder(QMainWindow):
    """Main window for Go package browsing and context building."""
    
    COLS = 3
    
    def __init__(self):
        super().__init__()
        self.buttons = {}
        self.packages = {}
        self.packages_order = []
        self.selected_packages = set()
        
        self.init_ui()
        self.load_exclusions_and_refresh()

    def init_ui(self):
        self.setWindowTitle("Go Context Builder v2 - Package View")
        self.resize(1100, 900)
        
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        central_widget.setStyleSheet(DARK_STYLE)
        
        main_layout = QVBoxLayout(central_widget)
        main_layout.setSpacing(8)
        main_layout.setContentsMargins(8, 8, 8, 0)

        # --- Top Controls ---
        controls = QHBoxLayout()
        controls.setSpacing(6)
        
        btn_style = "min-height: 38px; font-size: 13px;"
        
        self.btn_refresh = QPushButton("🔄 Refresh")
        self.btn_refresh.clicked.connect(self.refresh_packages)
        self.btn_refresh.setStyleSheet(btn_style)
        
        self.btn_copy_tree = QPushButton("🌳 Copy Tree")
        self.btn_copy_tree.clicked.connect(self.copy_tree)
        self.btn_copy_tree.setStyleSheet(btn_style)
        
        self.btn_copy = QPushButton("📄 Copy Selected Code")
        self.btn_copy.clicked.connect(self.copy_content)
        self.btn_copy.setStyleSheet(f"""
            {btn_style}
            background-color: #27ae60; 
            color: white; 
            font-weight: bold;
            border: 1px solid #219150;
        """)

        self.btn_select_none = QPushButton("✕ Clear")
        self.btn_select_none.clicked.connect(self.clear_selection)
        self.btn_select_none.setStyleSheet(btn_style)

        controls.addWidget(self.btn_refresh, 1)
        controls.addWidget(self.btn_copy_tree, 1)
        controls.addWidget(self.btn_copy, 2)
        controls.addWidget(self.btn_select_none, 1)
        main_layout.addLayout(controls)

        # --- Main Splitter ---
        self.splitter = QSplitter(Qt.Horizontal)

        # Sidebar (Exclusions)
        excl_container = QWidget()
        excl_container.setMaximumWidth(250)
        excl_layout = QVBoxLayout(excl_container)
        excl_layout.setContentsMargins(0, 0, 8, 0)
        
        lbl = QLabel("EXCLUDED PACKAGES")
        lbl.setStyleSheet("font-weight: bold; color: #7f8c8d; padding: 4px;")
        excl_layout.addWidget(lbl)
        
        self.excl_list = ExclusionList(self)
        excl_layout.addWidget(self.excl_list)
        
        # Grid area - vertical scroll only
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.scroll.setVerticalScrollBarPolicy(Qt.ScrollBarAsNeeded)
        
        self.scroll_content = QWidget()
        self.grid = QGridLayout(self.scroll_content)
        self.grid.setAlignment(Qt.AlignTop)
        self.grid.setSpacing(10)
        self.grid.setContentsMargins(5, 5, 5, 5)
        self.scroll.setWidget(self.scroll_content)

        self.splitter.addWidget(excl_container)
        self.splitter.addWidget(self.scroll)
        self.splitter.setStretchFactor(0, 0)
        self.splitter.setStretchFactor(1, 1)
        self.splitter.setSizes([200, 900])
        
        main_layout.addWidget(self.splitter)
        
        # --- Status Bar ---
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        
        widget_container = QWidget()
        sb_layout = QHBoxLayout(widget_container)
        sb_layout.setContentsMargins(10, 2, 10, 2)
        sb_layout.setSpacing(15)
        
        self.stats_label = QLabel("Ready")
        self.stats_label.setStyleSheet("font-family: monospace; font-size: 12px;")
        
        self.chk_calls = QCheckBox("Tree: show calls/imports")
        self.chk_calls.setChecked(False)
        
        self.chk_unexported = QCheckBox("Tree: include unexported")
        self.chk_unexported.setChecked(False)
        
        self.chk_comments = QCheckBox("Copy: keep comments")
        self.chk_comments.setChecked(False)
        
        sb_layout.addWidget(self.stats_label, 1)
        sb_layout.addWidget(self.chk_calls)
        sb_layout.addWidget(self.chk_unexported)
        sb_layout.addWidget(self.chk_comments)
        
        self.status_bar.addWidget(widget_container, 1)

    # =======================
    # EXCLUSION LOGIC
    # =======================

    def get_exclusions(self):
        if os.path.exists(EXCLUDE_FILE):
            with open(EXCLUDE_FILE, 'r') as f:
                return [line.strip().replace('"', '') for line in f if line.strip()]
        return []

    def save_exclusions(self, exclusions):
        with open(EXCLUDE_FILE, 'w') as f:
            for item in sorted(exclusions):
                f.write(f'"{item}"\n')

    def load_exclusions_and_refresh(self):
        self.excl_list.clear()
        for item in sorted(self.get_exclusions()):
            self.excl_list.addItem(item)
        self.refresh_packages()

    def add_exclusion(self, pkg_id):
        exclusions = self.get_exclusions()
        if pkg_id not in exclusions:
            exclusions.append(pkg_id)
            self.save_exclusions(exclusions)
            self.selected_packages.discard(pkg_id)
            self.excl_list.addItem(pkg_id)
            self.excl_list.sortItems()
            self.refresh_grid_view()

    def remove_exclusion(self, pkg_id):
        exclusions = self.get_exclusions()
        if pkg_id in exclusions:
            exclusions.remove(pkg_id)
            self.save_exclusions(exclusions)
            items = self.excl_list.findItems(pkg_id, Qt.MatchExactly)
            for item in items:
                self.excl_list.takeItem(self.excl_list.row(item))
            self.refresh_grid_view()

    # =======================
    # PACKAGE SCANNING
    # =======================

    def refresh_packages(self):
        """Scan filesystem and group files by package."""
        lib_dir = Path(LIB_PATH)
        if not lib_dir.exists():
            self.stats_label.setText(f"Error: {LIB_PATH} not found")
            return

        file_packages = defaultdict(list)
        
        for path in lib_dir.rglob("*.go"):
            if path.name.endswith("_test.go"):
                continue
            
            pkg_name = GoParser.get_package_name(path)
            if not pkg_name:
                continue
            
            rel_path = str(path.relative_to(lib_dir))
            directory = str(Path(rel_path).parent)
            
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
                loc = sum(1 for l in text.splitlines() if l.strip() and not l.strip().startswith("//"))
            except:
                loc = 0
            
            file_packages[(directory, pkg_name)].append((rel_path, path, loc))
        
        self.packages = {}
        self.packages_order = []
        
        for (directory, pkg_name), files in sorted(file_packages.items()):
            pkg_id = f"{directory}:{pkg_name}"
            pkg_info = PackageInfo(pkg_id, directory, pkg_name)
            
            for rel_path, abs_path, loc in sorted(files):
                pkg_info.add_file(rel_path, abs_path, loc)
            
            self.packages[pkg_id] = pkg_info
            self.packages_order.append(pkg_id)
        
        existing_ids = set(self.packages.keys())
        self.selected_packages = self.selected_packages.intersection(existing_ids)
        
        self.refresh_grid_view()

    def refresh_grid_view(self):
        """Rebuild grid buttons."""
        for btn in self.buttons.values():
            self.grid.removeWidget(btn)
            btn.deleteLater()
        self.buttons = {}

        exclusions = set(self.get_exclusions())
        visible = [pid for pid in self.packages_order if pid not in exclusions]

        for i, pkg_id in enumerate(visible):
            pkg_info = self.packages[pkg_id]
            is_sel = pkg_id in self.selected_packages
            btn = PackageButton(pkg_info, is_selected=is_sel)
            
            btn.toggled.connect(lambda c, pid=pkg_id: self.handle_selection(pid, c))
            btn.exclude_requested.connect(self.add_exclusion)
            
            row, col = divmod(i, self.COLS)
            self.grid.addWidget(btn, row, col)
            self.buttons[pkg_id] = btn

        self.update_stats()

    def handle_selection(self, pkg_id, checked):
        if checked:
            self.selected_packages.add(pkg_id)
        else:
            self.selected_packages.discard(pkg_id)
        self.update_stats()

    def clear_selection(self):
        self.selected_packages.clear()
        for btn in self.buttons.values():
            btn.setChecked(False)
        self.update_stats()

    def update_stats(self):
        exclusions = set(self.get_exclusions())
        
        total_pkgs = len(self.packages)
        total_files = sum(p.file_count for p in self.packages.values())
        total_loc = sum(p.total_loc for p in self.packages.values())
        
        active_pkgs = sum(1 for pid in self.packages if pid not in exclusions)
        active_files = sum(p.file_count for pid, p in self.packages.items() if pid not in exclusions)
        active_loc = sum(p.total_loc for pid, p in self.packages.items() if pid not in exclusions)
        
        selected = len(self.selected_packages)
        selected_files = sum(self.packages[pid].file_count for pid in self.selected_packages if pid in self.packages)
        selected_loc = sum(self.packages[pid].total_loc for pid in self.selected_packages if pid in self.packages)
        
        txt = (f"Pkgs: {active_pkgs}/{total_pkgs} │ "
               f"Files: {active_files}/{total_files} │ "
               f"LOC: {active_loc:,}/{total_loc:,} │ "
               f"Selected: {selected} ({selected_files} files, {selected_loc:,} LOC)")
        self.stats_label.setText(txt)

    # =======================
    # COPY ACTIONS
    # =======================

    def copy_content(self):
        """Copy content of selected packages."""
        if not self.selected_packages:
            self.btn_copy.setText("Nothing selected!")
            QTimer.singleShot(1500, lambda: self.btn_copy.setText("📄 Copy Selected Code"))
            return

        keep_comments = self.chk_comments.isChecked()
        final_output = []
        
        for pkg_id in sorted(self.selected_packages):
            pkg_info = self.packages.get(pkg_id)
            if not pkg_info:
                continue
            
            for rel_path, abs_path in pkg_info.files:
                try:
                    text = abs_path.read_text(encoding="utf-8", errors="ignore")
                    if not keep_comments:
                        lines = text.splitlines()
                        text = "\n".join([l for l in lines if not l.strip().startswith("//")])
                    
                    final_output.append(f"// ===== FILE: {rel_path} =====\n{text}")
                except Exception as e:
                    print(f"Error reading {abs_path}: {e}")

        QApplication.clipboard().setText("\n\n".join(final_output))
        
        self.btn_copy.setText("✓ Copied!")
        QTimer.singleShot(1500, lambda: self.btn_copy.setText("📄 Copy Selected Code"))

    def copy_tree(self):
        """Copy tree of all non-excluded packages."""
        exclusions = set(self.get_exclusions())
        include_unexported = self.chk_unexported.isChecked()
        show_calls = self.chk_calls.isChecked()
        
        total_pkgs = len(self.packages)
        total_files = sum(p.file_count for p in self.packages.values())
        total_loc = sum(p.total_loc for p in self.packages.values())
        
        tree_lines = []
        shown_pkgs = 0
        shown_files = 0
        shown_loc = 0
        
        for pkg_id in self.packages_order:
            if pkg_id in exclusions:
                continue
            
            pkg_info = self.packages[pkg_id]
            shown_pkgs += 1
            shown_files += pkg_info.file_count
            shown_loc += pkg_info.total_loc
            
            # Collect all parsed data from files
            all_imports = set()
            all_types = []
            all_functions = []
            all_calls = {}
            
            file_names = []
            for rel_path, abs_path in pkg_info.files:
                file_names.append(Path(rel_path).name)
                
                parsed, _ = GoParser.parse_file(abs_path, include_unexported=include_unexported)
                if not parsed:
                    continue
                
                for imp in parsed['imports']:
                    all_imports.add(imp['short'])
                
                all_types.extend(parsed['types'])
                all_functions.extend(parsed['functions'])
                all_calls.update(parsed['calls'])
            
            # Package header with files list
            files_str = ", ".join(sorted(file_names))
            tree_lines.append(f"\n📁 package {pkg_info.package_name} ({files_str}) [{pkg_info.total_loc} LOC]")
            tree_lines.append("-" * 70)
            
            # Imports (optional)
            if show_calls and all_imports:
                imports_list = sorted(all_imports)[:15]
                more = f" +{len(all_imports)-15}" if len(all_imports) > 15 else ""
                tree_lines.append(f"   imports: {', '.join(imports_list)}{more}")
            
            # Types
            for t in all_types:
                exp_marker = "⬜" if t['exported'] else "🔒"
                tree_lines.append(f"   {exp_marker} type {t['name']} {t['kind']}")
            
            # Functions grouped by receiver
            methods_by_receiver = defaultdict(list)
            standalone = []
            
            for fn in all_functions:
                if fn['receiver']:
                    methods_by_receiver[fn['receiver']].append(fn)
                else:
                    standalone.append(fn)
            
            # Standalone functions
            for fn in standalone:
                exp_marker = "⬜" if fn['exported'] else "🔒"
                args = ", ".join(fn['args']) if fn['args'] else ""
                ret = f" → {fn['returns']}" if fn['returns'] else ""
                tree_lines.append(f"   {exp_marker} func {fn['name']}({args}){ret}")
                
                if show_calls and fn['id'] in all_calls:
                    calls = all_calls[fn['id']][:5]
                    more = f" +{len(all_calls[fn['id']])-5}" if len(all_calls[fn['id']]) > 5 else ""
                    tree_lines.append(f"      └─ calls: {', '.join(calls)}{more}")
            
            # Methods by receiver
            for receiver, methods in sorted(methods_by_receiver.items()):
                tree_lines.append(f"   ── methods on {receiver}:")
                for fn in methods:
                    exp_marker = "⬜" if fn['exported'] else "🔒"
                    args = ", ".join(fn['args']) if fn['args'] else ""
                    ret = f" → {fn['returns']}" if fn['returns'] else ""
                    tree_lines.append(f"      {exp_marker} {fn['name']}({args}){ret}")
                    
                    if show_calls and fn['id'] in all_calls:
                        calls = all_calls[fn['id']][:5]
                        more = f" +{len(all_calls[fn['id']])-5}" if len(all_calls[fn['id']]) > 5 else ""
                        tree_lines.append(f"         └─ calls: {', '.join(calls)}{more}")

        # Header
        header = (f"Project: {total_pkgs} packages ({total_files} files, {total_loc:,} LOC) total\n"
                  f"Showing: {shown_pkgs} packages ({shown_files} files, {shown_loc:,} LOC)")
        
        final_text = header + "\n" + "\n".join(tree_lines)
        QApplication.clipboard().setText(final_text)
        
        self.btn_copy_tree.setText("✓ Copied!")
        QTimer.singleShot(1500, lambda: self.btn_copy_tree.setText("🌳 Copy Tree"))


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = ContextBuilder()
    window.show()
    sys.exit(app.exec())
