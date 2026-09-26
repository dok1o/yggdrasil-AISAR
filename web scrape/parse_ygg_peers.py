#!/usr/bin/env python3

import re
import sys
import random


source = sys.argv[1]
limit = int(sys.argv[2])


with open(source, encoding="utf-8") as f:
    text = f.read()


uri_re = re.compile(
    r"(?:tcp|tls|quic|ws|wss|socks|sockstls)://[^\s`<>()\[\]]+"
)


uris = []

for uri in uri_re.findall(text):
    uri = uri.rstrip(".,);:'\"")

    if uri not in uris:
        uris.append(uri)


# Try to group by Yggdrasil IPv6 identity
nodes = {}

for uri in uris:
    pos = text.find(uri)
    section = text[pos:pos + 500]

    addr = re.search(
        r"\b2[0-9a-f]{2}:[0-9a-f:]{10,}\b",
        section,
        re.I
    )

    key = addr.group(0) if addr else uri.split("//", 1)[1]

    nodes.setdefault(key, []).append(uri)


# Randomize so every run doesn't pick the same nodes
unique = list(nodes.values())
random.shuffle(unique)


print(
    f"# URIs found: {len(uris)}",
    file=sys.stderr
)

print(
    f"# Unique nodes: {len(unique)}",
    file=sys.stderr
)


selected = []

for node in unique:
    selected.append(node[0])

    if len(selected) >= limit:
        break


for peer in selected:
    print(peer)
