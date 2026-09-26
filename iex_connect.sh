#!/usr/bin/env bash
node=$(epmd -names | grep -o 'magnet_sorter_[0-9_]\+'); node="${node}@127.0.0.1"; echo "Connecting to $node"; [ -n "$node" ] && iex --name console@127.0.0.1 --cookie secret_cookie --remsh "$node"
