#!/usr/bin/env bash
set -e

echo "==> Elixir 1.19.5 is required, optionally with mise.run tool. Current Elixir:"
elixir --version
echo ""
echo "==> Python 3.11 is required. Current Python:"
python3 --version

echo "==> Installing Elixir dependencies for Elixir backend..."
cd backend
#mix local.hex --force
#mix local.rebar --force
mix deps.get
mix compile
cd ..

echo "==> Creating Python virtual environment for PySide frontend..."
python3 -m venv venv311

echo "==> Installing Python packages..."
source venv311/bin/activate
#python -m pip install --upgrade pip
pip install -r requirements.txt
deactivate

echo "Installation complete"
