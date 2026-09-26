#!/usr/bin/env bash
set -euo pipefail

REGION="europe"
MAX=20

CONF="/etc/yggdrasil/yggdrasil.conf"
WORK=$(mktemp -d)

trap 'rm -rf "$WORK"' EXIT


echo "Fetching peer list..."

curl -fsSL \
"https://api.github.com/repos/yggdrasil-network/public-peers/contents/$REGION" \
-o "$WORK/files.json"


echo "Downloading peer files..."

jq -r '.[].download_url' "$WORK/files.json" |
while read -r url; do
    echo "Downloading $url"
    curl -fsSL "$url"
done > "$WORK/peers.md"


echo "Parsing peers..."

python3 ./parse_ygg_peers.py \
    "$WORK/peers.md" \
    "$MAX" \
    > "$WORK/peers.txt"


echo "Selected peers:"
cat "$WORK/peers.txt"


if [ ! -s "$WORK/peers.txt" ]; then
    echo "No peers found"
    exit 1
fi


echo "Updating Yggdrasil config..."

python3 ./update_ygg_config.py \
    "$CONF" \
    "$WORK/peers.txt"


echo "Restarting Yggdrasil..."

sudo systemctl restart yggdrasil

sleep 5

sudo yggdrasilctl getPeers
