import sys
import os
import re
import ast
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

os.environ["QT_LOGGING_RULES"] = "qt.qpa.*=false"

LIB_PATH = "./"  # Adjust to your Python project root
EXCLUDE_FILE = "copy_machine_exclude_py.txt"

# Modules to ignore when generating the "imports -> ..." tree output
IGNORE_IMPORTS_FROM = {
    "os", "sys", "re", "ast", "json", "typing", "pathlib", "collections",
    "dataclasses", "functools", "itertools", "datetime", "time", "math",
    "logging", "copy", "enum", "abc", "contextlib", "io", "hashlib",
    "PySide6", "PyQt5", "PyQt6", "Qt", "QtCore", "QtWidgets", "QtGui",
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
# PARSING LOGIC (Python AST-based)
# =======================

class PythonParser:
    @staticmethod
    def parse_file(path: Path, include_private=False):
        """
        Parse a Python file and return structure and LOC.
        Returns: (structure_list, loc)
        """
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            return [], 0
        
        # Calculate LOC (non-empty, non-comment lines)
        lines = text.splitlines()
        loc = sum(1 for l in lines if l.strip() and not l.strip().startswith("#"))
        
        try:
            tree = ast.parse(text, filename=str(path))
        except SyntaxError:
            return [], loc
        
        structure = []
        module_name = path.stem  # Use filename as module name
        
        # Extract module-level info
        module_info = {
            "module": module_name,
            "file_path": str(path),
            "imports": [],
            "classes": [],
            "functions": [],
            "calls": defaultdict(list),
            "docstring": ast.get_docstring(tree) or ""
        }
        
        # Process imports
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    module_info["imports"].append(alias.name)
            elif isinstance(node, ast.ImportFrom):
                if node.module:
                    module_info["imports"].append(node.module)
        
        # Filter imports
        module_info["imports"] = sorted(set(
            imp for imp in module_info["imports"]
            if imp.split(".")[0] not in IGNORE_IMPORTS_FROM
        ))
        
        # Process top-level definitions
        for node in ast.iter_child_nodes(tree):
            if isinstance(node, ast.ClassDef):
                class_info = PythonParser._parse_class(node, include_private)
                module_info["classes"].append(class_info)
            elif isinstance(node, ast.FunctionDef) or isinstance(node, ast.AsyncFunctionDef):
                if include_private or not node.name.startswith("_"):
                    func_info = PythonParser._parse_function(node)
                    module_info["functions"].append(func_info)
        
        structure.append(module_info)
        return structure, loc
    
    @staticmethod
    def _parse_class(node: ast.ClassDef, include_private=False):
        """Parse a class definition."""
        class_info = {
            "name": node.name,
            "bases": [PythonParser._get_name(base) for base in node.bases],
            "methods": [],
            "docstring": ast.get_docstring(node) or ""
        }
        
        for item in node.body:
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                # Skip private methods unless requested
                if not include_private and item.name.startswith("_") and not item.name.startswith("__"):
                    continue
                method_info = PythonParser._parse_function(item, is_method=True)
                class_info["methods"].append(method_info)
        
        return class_info
    
    @staticmethod
    def _parse_function(node, is_method=False):
        """Parse a function/method definition."""
        args = []
        
        # Regular arguments
        for arg in node.args.args:
            arg_str = arg.arg
            if arg.annotation:
                arg_str += f": {PythonParser._get_annotation(arg.annotation)}"
            args.append(arg_str)
        
        # *args
        if node.args.vararg:
            args.append(f"*{node.args.vararg.arg}")
        
        # **kwargs
        if node.args.kwarg:
            args.append(f"**{node.args.kwarg.arg}")
        
        # Return annotation
        return_type = ""
        if node.returns:
            return_type = PythonParser._get_annotation(node.returns)
        
        # Detect calls within function
        calls = []
        for child in ast.walk(node):
            if isinstance(child, ast.Call):
                call_name = PythonParser._get_call_name(child)
                if call_name:
                    calls.append(call_name)
        
        is_async = isinstance(node, ast.AsyncFunctionDef)
        is_private = node.name.startswith("_") and not node.name.startswith("__")
        is_dunder = node.name.startswith("__") and node.name.endswith("__")
        
        return {
            "name": node.name,
            "args": args,
            "arity": len(node.args.args),
            "return_type": return_type,
            "is_async": is_async,
            "is_private": is_private,
            "is_dunder": is_dunder,
            "calls": sorted(set(calls)),
            "docstring": ast.get_docstring(node) or ""
        }
    
    @staticmethod
    def _get_name(node):
        """Get string name from various AST node types."""
        if isinstance(node, ast.Name):
            return node.id
        elif isinstance(node, ast.Attribute):
            return f"{PythonParser._get_name(node.value)}.{node.attr}"
        elif isinstance(node, ast.Subscript):
            return f"{PythonParser._get_name(node.value)}[...]"
        return "?"
    
    @staticmethod
    def _get_annotation(node):
        """Convert annotation AST to string."""
        if isinstance(node, ast.Name):
            return node.id
        elif isinstance(node, ast.Constant):
            return repr(node.value)
        elif isinstance(node, ast.Attribute):
            return f"{PythonParser._get_name(node.value)}.{node.attr}"
        elif isinstance(node, ast.Subscript):
            base = PythonParser._get_annotation(node.value)
            if isinstance(node.slice, ast.Tuple):
                args = ", ".join(PythonParser._get_annotation(e) for e in node.slice.elts)
            else:
                args = PythonParser._get_annotation(node.slice)
            return f"{base}[{args}]"
        elif isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
            # Union type with |
            left = PythonParser._get_annotation(node.left)
            right = PythonParser._get_annotation(node.right)
            return f"{left} | {right}"
        return "..."
    
    @staticmethod
    def _get_call_name(node: ast.Call):
        """Extract the name of a function/method being called."""
        func = node.func
        if isinstance(func, ast.Name):
            return func.id
        elif isinstance(func, ast.Attribute):
            # e.g., obj.method() or Module.func()
            value_name = PythonParser._get_name(func.value)
            if value_name and value_name[0].isupper():
                # Likely a module/class call
                return f"{value_name}.{func.attr}"
            return func.attr
        return None


# =======================
# UI COMPONENTS
# =======================

class ModuleButton(QPushButton):
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
        self.buttons = {}
        self.known_modules_order = []
        self.selected_modules = set()
        
        self.init_ui()
        self.load_exclusions_and_refresh()

    def init_ui(self):
        self.setWindowTitle("Python Context Machine & Tree")
        self.resize(1200, 800)
        self.setGeometry(200, 200, 1200, 800)
        
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        central_widget.setStyleSheet(DARK_STYLE)
        
        main_layout = QVBoxLayout(central_widget)

        # --- Top Controls ---
        controls = QHBoxLayout()
        controls.setSpacing(2)
        controls.setContentsMargins(5, 5, 5, 10)
        
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
        
        widget_container = QWidget()
        sb_layout = QHBoxLayout(widget_container)
        sb_layout.setContentsMargins(10, 0, 10, 0)
        
        self.stats_label = QLabel("Ready")
        self.stats_label.setStyleSheet("font-family: monospace;")
        
        self.chk_comments = QCheckBox("Copy with comments/docstrings")
        self.chk_comments.setChecked(False)
        
        self.chk_private = QCheckBox("Include private (_) in tree")
        self.chk_private.setChecked(False)
        
        sb_layout.addWidget(self.stats_label, 1)
        sb_layout.addWidget(self.chk_private)
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
            
            if name in self.selected_modules:
                self.selected_modules.remove(name)
            
            self.excl_list.addItem(name)
            self.excl_list.sortItems()
            self.refresh_grid_view()

    def remove_exclusion(self, name):
        """Move from Sidebar to Grid."""
        exclusions = self.get_exclusions()
        if name in exclusions:
            exclusions.remove(name)
            self.save_exclusions(exclusions)
            
            items = self.excl_list.findItems(name, Qt.MatchExactly)
            for item in items:
                self.excl_list.takeItem(self.excl_list.row(item))
                
            self.refresh_grid_view()

    def clear_selection(self):
        """Deselects all modules in the grid."""
        for btn in self.buttons.values():
            if btn.isChecked():
                btn.setChecked(False)
        self.selected_modules.clear()

    def refresh_modules(self):
        """Scans filesystem, updates known modules list."""
        lib_dir = Path(LIB_PATH)
        if not lib_dir.exists():
            self.stats_label.setText(f"Error: {LIB_PATH} not found")
            return

        current_scan = {}
        for path in lib_dir.rglob("*.py"):
            # Skip __pycache__ and hidden directories
            if "__pycache__" in str(path) or any(p.startswith('.') for p in path.parts):
                continue
            m_name = path.stem
            current_scan[m_name] = path

        # Remove modules that no longer exist
        self.known_modules_order = [
            (name, path) for name, path in self.known_modules_order 
            if name in current_scan
        ]
        
        existing_names = set(current_scan.keys())
        self.selected_modules = self.selected_modules.intersection(existing_names)

        # Add new modules to the end
        known_names = set(name for name, _ in self.known_modules_order)
        new_names = sorted(list(existing_names - known_names))
        
        for name in new_names:
            self.known_modules_order.append((name, current_scan[name]))

        self.refresh_grid_view()

    def refresh_grid_view(self):
        """Rebuilds the grid buttons based on known_modules and exclusions."""
        for btn in self.buttons.values():
            self.grid.removeWidget(btn)
            btn.deleteLater()
        self.buttons = {}

        exclusions = set(self.get_exclusions())
        
        visible_modules = [
            (name, path) for name, path in self.known_modules_order
            if name not in exclusions
        ]

        COLS = 4
        for i, (m_name, path) in enumerate(visible_modules):
            is_sel = m_name in self.selected_modules
            btn = ModuleButton(m_name, path, is_selected=is_sel)
            
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
        exclusions = set(self.get_exclusions())
        
        total_mods = len(self.known_modules_order)
        active_mods = 0
        
        total_loc = 0
        active_loc = 0

        for name, path in self.known_modules_order:
            try:
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
        
        for name, path in self.known_modules_order:
            if name in self.selected_modules and path not in processed_paths:
                try:
                    text = path.read_text(encoding="utf-8", errors="ignore")
                    if not keep_comments:
                        text = self._strip_comments_and_docstrings(text)
                    
                    final_output.append(f"# {path.name}\n{text}")
                    processed_paths.add(path)
                except Exception as e:
                    print(f"Error reading {path}: {e}")

        QApplication.clipboard().setText("\n\n".join(final_output))
        
        orig = self.btn_copy.text()
        self.btn_copy.setText("Copied!")
        QTimer.singleShot(1500, lambda: self.btn_copy.setText(orig))

    def _strip_comments_and_docstrings(self, text: str) -> str:
        """Remove comments and docstrings from Python code."""
        lines = text.splitlines()
        result = []
        in_docstring = False
        docstring_char = None
        
        for line in lines:
            stripped = line.strip()
            
            # Handle docstrings
            if not in_docstring:
                if stripped.startswith('"""') or stripped.startswith("'''"):
                    docstring_char = stripped[:3]
                    if stripped.count(docstring_char) >= 2 and len(stripped) > 3:
                        # Single-line docstring
                        continue
                    in_docstring = True
                    continue
                elif stripped.startswith('#'):
                    continue
                else:
                    # Remove inline comments (naive - doesn't handle # in strings)
                    if '#' in line and not any(c in line.split('#')[0] for c in ['"', "'"]):
                        line = line.split('#')[0].rstrip()
                    if line.strip():
                        result.append(line)
            else:
                if docstring_char in stripped:
                    in_docstring = False
                continue
        
        return '\n'.join(result)

    def copy_tree(self):
        """Copies tree of ALL non-excluded modules with statistics header."""
        exclusions = set(self.get_exclusions())
        
        all_unique_paths = set(path for _, path in self.known_modules_order)
        total_mods = len(self.known_modules_order)
        total_loc = 0
        
        for path in all_unique_paths:
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                    total_loc += sum(1 for l in f if l.strip() and not l.strip().startswith('#'))
            except: pass

        paths_to_process = sorted(list(all_unique_paths))
        if not paths_to_process:
            return

        include_private = self.chk_private.isChecked()
        
        tree_lines = []
        shown_mods = 0
        shown_loc = 0
        
        for path in paths_to_process:
            try:
                structs, file_loc = PythonParser.parse_file(path, include_private=include_private)
                
                file_contributed = False
                
                for mod in structs:
                    if mod['module'] in exclusions:
                        continue
                        
                    shown_mods += 1
                    file_contributed = True
                    
                    tree_lines.append(f"📦 {mod['module']} ({mod['file_path']})")
                    
                    # Imports
                    if mod['imports']:
                        tree_lines.append(f"   imports: {', '.join(mod['imports'])}")
                    
                    # Module-level functions
                    for fn in mod['functions']:
                        args = ", ".join(fn["args"])
                        prefix = "async def" if fn['is_async'] else "def"
                        ret = f" -> {fn['return_type']}" if fn['return_type'] else ""
                        tree_lines.append(f"   ├── {prefix} {fn['name']}({args}){ret}")
                        
                        if fn['calls']:
                            filtered_calls = [c for c in fn['calls'] if c.split('.')[0] not in IGNORE_IMPORTS_FROM]
                            if filtered_calls:
                                tree_lines.append(f"   │   └── calls → {', '.join(filtered_calls[:10])}")
                    
                    # Classes
                    for cls in mod['classes']:
                        bases = f"({', '.join(cls['bases'])})" if cls['bases'] else ""
                        tree_lines.append(f"   ├── class {cls['name']}{bases}")
                        
                        for method in cls['methods']:
                            args = ", ".join(method["args"])
                            prefix = "async def" if method['is_async'] else "def"
                            ret = f" -> {method['return_type']}" if method['return_type'] else ""
                            priv = "🔒" if method['is_private'] else ""
                            tree_lines.append(f"   │   ├── {prefix} {method['name']}({args}){ret} {priv}")
                    
                    tree_lines.append("")
                
                if file_contributed:
                    shown_loc += file_loc

            except Exception as e:
                print(f"Error parsing {path}: {e}")

        header = f"Python App: total {total_mods} modules / {total_loc} LOC, shown: {shown_mods} modules / {shown_loc} LOC:"
        final_text = header + "\n\n" + "\n".join(tree_lines)
        
        QApplication.clipboard().setText(final_text)
        
        orig = self.btn_copy_tree.text()
        self.btn_copy_tree.setText("Tree Copied!")
        QTimer.singleShot(1500, lambda: self.btn_copy_tree.setText(orig))


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = ContextBuilder()
    window.show()
    sys.exit(app.exec())
