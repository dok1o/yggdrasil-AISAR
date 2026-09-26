#!/usr/bin/env python3

import sys
import re


conf = sys.argv[1]
peerfile = sys.argv[2]


with open(conf, encoding="utf-8") as f:
    cfg = f.read()


with open(peerfile, encoding="utf-8") as f:
    peers = [
        x.strip()
        for x in f
        if x.strip() and not x.startswith("#")
    ]


block = "Peers: [\n"

for peer in peers:
    block += f"    {peer}\n"

block += "]"


cfg, count = re.subn(
    r"Peers\s*:\s*\[[^\]]*\]",
    block,
    cfg,
    flags=re.S
)


if count == 0:
    raise SystemExit("Peers block not found")


with open(conf, "w", encoding="utf-8") as f:
    f.write(cfg)


print(f"Updated {len(peers)} peers")

