#!/usr/bin/env bash
set -euo pipefail

# todo: kill tee /tmp/gui.log, how?

# for DEBUG:
# command for iex in second terminal:
# node=$(epmd -names | grep -o 'magnet_sorter_[0-9_]\+'); node="${node}@127.0.0.1"; echo "Connecting to $node"; [ -n "$node" ] && iex --name console@127.0.0.1 --cookie secret_cookie --remsh "$node"

# todo: local port selection logic, currently kills on port

# === Configuration ============================================================
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ELIXIR_PATH="./backend/"
PYTHON_GUI_PATH="./gui/"
VENV_PATH="./"
PORT=4040
LOG_DIR="$SCRIPT_DIR/data/logs"
LOG_FILE="$LOG_DIR/gui.log"

mkdir -p "$LOG_DIR"

# Global Logging
exec > >(tee -a "$LOG_FILE") 2>&1

cleanup() {
  echo "[cleanup] Shutting down backend..."
  if [[ -n "${BACK_PID:-}" ]]; then
    # Try graceful kill first
    kill "$BACK_PID" 2>/dev/null || true
    # Wait up to 2 seconds for it to disappear
    timeout 2 wait "$BACK_PID" 2>/dev/null || kill -9 "$BACK_PID" 2>/dev/null || true
  fi
  
  # Safety: kill any lingering beam processes for this project
  pkill -9 -f "magnet_sorter.*beam.smp" 2>/dev/null || true
  sleep 0.2
}

# Trap for external exits (Ctrl+C)
trap "cleanup; exit" INT TERM EXIT

while true; do
  echo "--- NEW SESSION: $(date) ---"

  # 1. Kill anything on the port
  if command -v lsof >/dev/null 2>&1; then
    PID_ON_PORT=$(lsof -ti tcp:"$PORT" || true)
    if [[ -n "$PID_ON_PORT" ]]; then
        kill -9 "$PID_ON_PORT" 2>/dev/null || true
    fi
  fi

  # 2. Start Elixir backend
  echo "[init] starting Elixir backend..."
  
  cd "$SCRIPT_DIR/$ELIXIR_PATH"
  
  # USE A UNIQUE NODE NAME PER RUN (adds RANDOM to avoid EPMD collisions)
  NODE="magnet_sorter_${$}_${RANDOM}@127.0.0.1"
  
  mix compile --clean --force --no-deps
  
  # Start backend
  elixir --name "$NODE" --cookie secret_cookie -S mix run --no-halt &
  BACK_PID=$!

  cd "$SCRIPT_DIR"
  
  # 3. Start Python GUI
  echo "[init] starting Python GUI..."
  cd "$SCRIPT_DIR/$VENV_PATH"
  source venv311/bin/activate
  
  cd "$SCRIPT_DIR/$PYTHON_GUI_PATH"
  set +e
  python3 -u gui_client.py
  GUI_EXIT_CODE=$?
  set -e

  # 4. Handle Restart/Exit
  if [[ $GUI_EXIT_CODE -eq 5 ]]; then
    echo "[main] Restart signal (5) caught. Cleaning up and looping..."
    cleanup
    continue 
  else
    echo "[main] GUI exited with code $GUI_EXIT_CODE. Exiting script."
    cleanup
    break
  fi
done
