#!/usr/bin/env bash
# Ping a Yggdrasil address through the running magnet_sorter node (it has no TUN, so no OS ping).
# Usage: ygg_ping.sh <ygg-ipv6> [count=10] [--pause]
#   --pause   wait for Enter at the end (for a separate console window)
# Open in a new Windows console:
#   cmd.exe /c start "Ygg ping" wsl.exe -d Ubuntu -- bash -ic "~/ygg_ping.sh <addr> 10 --pause"
set -u
[[ $# -ge 1 ]] || { sed -n 3,7p "$0"; exit 1; }
cd "$(dirname "$0")"
epmd -names 2>/dev/null | grep -q magnet_sorter_ || { echo "magnet_sorter is not running"; exit 1; }
elixir --name "pinger_$$@127.0.0.1" --cookie secret_cookie ygg_ping.exs "$1" "${2:-10}"
rc=$?
[[ "${3:-}" == "--pause" ]] && { echo; read -rp "Press Enter to close..."; }
exit $rc
