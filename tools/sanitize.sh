#!/bin/bash

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$TOOLS_DIR/.." && pwd)"

"$APP_DIR/venv311/bin/python" "$TOOLS_DIR/py_scripts/sanitize.py"
