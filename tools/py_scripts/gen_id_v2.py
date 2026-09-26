#!/usr/bin/env python3
"""
32-byte ID uniformity checker — 4 scenarios.

Scenario 1: Random 32B
Scenario 2: Stream IPv4:port (filtered) → 32f → 32B
Scenario 3: Ed25519 privkey → Yggdrasil addr (18B) → 32f → 32B
Scenario 4: Real IPv4:port from JSONL → 32f → 32B

32f pipeline:  6B (ip4:port) → 18B (v4-mapped v6:port) → 18B (reversible mix) → 32B (spread+random)
"""

import os
import sys
import json
import struct
import math
import random
from collections import Counter
from pathlib import Path

# ─── Ed25519 (optional) ───────────────────────────────────────────────────────
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False
    print("[WARN] 'cryptography' not installed — Scenario 3 will be skipped.")
    print("       pip install cryptography")

N = 1024          # items per scenario
ID_LEN = 32       # bytes
FIXED_PORT = 6881 # fixed high port for Yggdrasil in scenario 3

# ═══════════════════════════════════════════════════════════════════════════════
#  32f  —  the transformation
# ═══════════════════════════════════════════════════════════════════════════════

# ── Step 1: 6 B → 18 B  (IPv4-mapped IPv6 : port, "4-in-6") ──────────────────

def v4port_to_v6port(ip4: bytes, port: int) -> bytes:
    """4-byte IPv4 + 2-byte port → 18-byte IPv4-mapped-IPv6:port."""
    # ::ffff:a.b.c.d  =  10×00  FF FF  a b c d   (16 B)  +  port (2 B) = 18 B
    return b'\x00' * 10 + b'\xff\xff' + ip4 + struct.pack('!H', port)

def v6port_to_v4port(data: bytes) -> tuple:
    """18 B → (4 B IPv4, port)."""
    return data[12:16], struct.unpack('!H', data[16:18])[0]

# ── Step 2: 18 B → 18 B  (reversible, SIMD-friendly bit mixing) ──────────────
#
# Whitening (breaks structural zeros of v4-mapped v6) + 6-round Feistel on
# (9 B, 9 B).  Round function is byte-parallel (no sequential deps) → SIMD-
# friendly.  Feistel structure guarantees bijectivity.
#
# Forward round:  (L, R) → (R,  L ⊕ F(R, rk))
# Inverse round:  (L, R) → (R ⊕ F(L, rk),  L)

_MIX_PAD = bytes((0xA5 ^ (i * 17)) & 0xFF for i in range(18))
_MIX_ROUNDS = (0x3C, 0xA7, 0x5E, 0xC3, 0x91, 0x4F)

def _F(x: bytes, rk: int) -> bytes:
    """Round function on 9 bytes.  SIMD-friendly (no sequential deps)."""
    n = len(x)  # 9
    # Affine + neighbour XOR — every output byte independent given x
    return bytes(
        (((x[i] * 73 + rk) & 0xFF) ^ x[(i + 3) % n] ^ x[(i + 5) % n])
        for i in range(n)
    )

def mix_144(data: bytes) -> bytes:
    """Reversible 6-round Feistel on 18 bytes, with pre/post whitening."""
    # Pre-whiten (destroys zero-runs in v4-mapped prefix)
    d = bytes(a ^ b for a, b in zip(data, _MIX_PAD))
    L, R = d[:9], d[9:]
    for rk in _MIX_ROUNDS:
        L, R = R, bytes(a ^ b for a, b in zip(L, _F(R, rk)))
    # Post-whiten
    return bytes(a ^ b for a, b in zip(L + R, _MIX_PAD))

def unmix_144(data: bytes) -> bytes:
    """Exact inverse of mix_144."""
    # Undo post-whiten
    d = bytes(a ^ b for a, b in zip(data, _MIX_PAD))
    L, R = d[:9], d[9:]
    for rk in reversed(_MIX_ROUNDS):
        # Inverse Feistel round: (L, R) → (R ⊕ F(L, rk), L)
        L, R = bytes(a ^ b for a, b in zip(R, _F(L, rk))), L
    # Undo pre-whiten
    return bytes(a ^ b for a, b in zip(L + R, _MIX_PAD))

# ── Step 3: 18 B → 32 B  (spread + random fill) ──────────────────────────────
# 18 mixed bytes placed at fixed positions; 14 remaining bytes filled with
# cryptographic random.  Reversal: extract the 18 positions → unmix → v4port.

SPREAD_POS = [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 1, 3]
FILL_POS   = [5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31]
assert sorted(SPREAD_POS + FILL_POS) == list(range(32))
assert len(SPREAD_POS) == 18 and len(FILL_POS) == 14

def spread(mixed18: bytes) -> bytes:
    out = bytearray(32)
    for i, p in enumerate(SPREAD_POS):
        out[p] = mixed18[i]
    rand = os.urandom(len(FILL_POS))
    for j, p in enumerate(FILL_POS):
        out[p] = rand[j]
    return bytes(out)

def extract(id32: bytes) -> bytes:
    return bytes(id32[p] for p in SPREAD_POS)

# ── Full 32f and its inverse ──────────────────────────────────────────────────

def f32(raw6: bytes) -> bytes:
    """6 B (IPv4:port) → 32 B ID."""
    ip4  = raw6[:4]
    port = struct.unpack('!H', raw6[4:6])[0]
    v6p  = v4port_to_v6port(ip4, port)   # 18 B
    mix  = mix_144(v6p)                  # 18 B
    return spread(mix)                   # 32 B

def f32_inv(id32: bytes) -> bytes:
    """32 B ID → 6 B (IPv4:port)."""
    mix  = extract(id32)                 # 18 B
    v6p  = unmix_144(mix)                # 18 B
    ip4, port = v6port_to_v4port(v6p)    # 4 B + 2 B
    return ip4 + struct.pack('!H', port)

def f32_from_18b(data18: bytes) -> bytes:
    """Apply 32f mix+spread to an arbitrary 18-byte input (scenarios 3/4)."""
    return spread(mix_144(data18))

def f32_from_18b_inv(id32: bytes) -> bytes:
    """Inverse of f32_from_18b: 32 B → 18 B."""
    return unmix_144(extract(id32))

# ═══════════════════════════════════════════════════════════════════════════════
#  Reserved-IPv4 filter  (ported from the Elixir code)
# ═══════════════════════════════════════════════════════════════════════════════

def is_viable_public_ip(a, b, c, d) -> bool:
    if a == 0:       return False
    if a == 10:      return False
    if a == 100 and 64 <= b <= 127: return False
    if a == 127:     return False
    if a == 169 and b == 254: return False
    if a == 172 and 16 <= b <= 31: return False
    if a == 192 and b == 0:  return False
    if a == 192 and b == 31 and c == 196: return False
    if a == 192 and b == 52 and c == 193: return False
    if a == 192 and b == 88 and c == 99: return False
    if a == 192 and b == 168: return False
    if a == 192 and b == 175 and c == 48: return False
    if a == 198 and 18 <= b <= 19: return False
    if a == 198 and b == 51 and c == 100: return False
    if a == 203 and b == 0 and c == 113: return False
    if 224 <= a <= 239: return False
    if a >= 240:        return False
    return True

def rand_octet():
    return random.randint(1, 255)

def rand_high_port():
    return random.randint(20_000, 65_500)

def rand_dht_port():
    return random.choice([6881, 51413, rand_high_port()])

def gen_valid_v4port() -> bytes:
    """Stream-generate until we get a viable public IPv4:port (6 B)."""
    while True:
        a, b, c, d = rand_octet(), rand_octet(), rand_octet(), rand_octet()
        if is_viable_public_ip(a, b, c, d):
            port = rand_dht_port()
            return bytes([a, b, c, d]) + struct.pack('!H', port)

# ═══════════════════════════════════════════════════════════════════════════════
#  Uniformity metrics
# ═══════════════════════════════════════════════════════════════════════════════

def chi2_byte(counts: Counter, n: int) -> float:
    """Chi-squared statistic for one byte position (expected n/256 per value)."""
    expected = n / 256
    return sum((counts[v] - expected) ** 2 / expected for v in range(256))

def chi2_critical(df=255, alpha=0.01):
    """Approximate chi2 critical value (df=255, α=0.01) ≈ 341.1."""
    return 341.1

def byte_entropy(counts: Counter, n: int) -> float:
    """Shannon entropy of a single byte position (max = 8.0 bits)."""
    h = 0.0
    for v in range(256):
        if counts[v]:
            p = counts[v] / n
            h -= p * math.log2(p)
    return h

def bit_frequency(ids: list) -> list:
    """Fraction of 1-bits per bit position (256 positions)."""
    total_ones = [0] * 256
    for idb in ids:
        for i in range(256):
            total_ones[i] += (idb[i >> 3] >> (7 - (i & 7))) & 1
    n = len(ids)
    return [total_ones[i] / n for i in range(256)]

def summarize(name: str, ids: list):
    """Print uniformity report for a list of 32-byte IDs."""
    n = len(ids)
    print(f"\n{'═'*72}")
    print(f"  {name}  ({n} items × {ID_LEN} B = {n*ID_LEN} B)")
    print(f"{'═'*72}")

    chi2_vals = []
    ent_vals  = []
    for pos in range(ID_LEN):
        counts = Counter(idb[pos] for idb in ids)
        chi2_vals.append(chi2_byte(counts, n))
        ent_vals.append(byte_entropy(counts, n))

    avg_chi2 = sum(chi2_vals) / ID_LEN
    max_chi2 = max(chi2_vals)
    min_chi2 = min(chi2_vals)
    avg_ent  = sum(ent_vals) / ID_LEN
    max_ent  = max(ent_vals)
    min_ent  = min(ent_vals)

    crit = chi2_critical()
    n_fail = sum(1 for c in chi2_vals if c > crit)

    print(f"  Chi²  (df=255, crit α=0.01 ≈ {crit:.1f}):")
    print(f"    mean = {avg_chi2:8.2f}   min = {min_chi2:8.2f}   max = {max_chi2:8.2f}")
    print(f"    positions exceeding critical: {n_fail}/{ID_LEN}")

    print(f"  Per-byte entropy (max 8.00 bits):")
    print(f"    mean = {avg_ent:.4f}   min = {min_ent:.4f}   max = {max_ent:.4f}")

    bf = bit_frequency(ids)
    bf_mean = sum(bf) / 256
    bf_std  = (sum((x - bf_mean)**2 for x in bf) / 256) ** 0.5
    print(f"  Bit frequency: mean = {bf_mean:.6f}   std = {bf_std:.6f}   (ideal 0.500000)")

    all_bytes = [idb[pos] for idb in ids for pos in range(ID_LEN)]
    all_counts = Counter(all_bytes)
    total_ent = 0.0
    for v in range(256):
        if all_counts[v]:
            p = all_counts[v] / len(all_bytes)
            total_ent -= p * math.log2(p)
    print(f"  Pooled byte entropy: {total_ent:.4f} / 8.00 bits")

    print(f"\n  Byte-position histogram (count per value, 16 of 32 shown):")
    print(f"  {'pos':>4} {'min':>5} {'max':>5} {'mean':>7} {'chi²':>8} {'H':>7}")
    for pos in range(0, ID_LEN, 2):
        counts = Counter(idb[pos] for idb in ids)
        mn = min(counts.values()) if counts else 0
        mx = max(counts.values()) if counts else 0
        print(f"  {pos:>4} {mn:>5} {mx:>5} {n/256:>7.1f} {chi2_vals[pos]:>8.2f} {ent_vals[pos]:>7.4f}")

    return avg_chi2, avg_ent, n_fail

# ═══════════════════════════════════════════════════════════════════════════════
#  Scenario generators
# ═══════════════════════════════════════════════════════════════════════════════

def scenario_1() -> list:
    """1024 random 32-byte IDs."""
    return [os.urandom(ID_LEN) for _ in range(N)]

def scenario_2() -> list:
    """Stream-generate valid IPv4:port → 32f → 32 B."""
    ids = []
    for _ in range(N):
        raw6 = gen_valid_v4port()
        ids.append(f32(raw6))
    return ids

def scenario_3() -> list:
    """Ed25519 privkey → Yggdrasil-like addr (16 B pubkey prefix + port) → 32f."""
    if not HAS_CRYPTO:
        print("  [SKIP] cryptography library not available.")
        return []
    ids = []
    for _ in range(N):
        priv = Ed25519PrivateKey.generate()
        pub  = priv.public_key().public_bytes_raw()  # 32 B
        # 18 B: first 16 B of pubkey (as "address") + fixed port
        data18 = pub[:16] + struct.pack('!H', FIXED_PORT)
        ids.append(f32_from_18b(data18))
    return ids

def scenario_4(jsonl_path: str) -> list:
    """Read real IPv4:port from JSONL → 32f → 32 B."""
    ids = []
    path = Path(jsonl_path)
    if not path.exists():
        print(f"  [WARN] {jsonl_path} not found — generating sample data.")
        sample = [
            "212.59.79.166:6881", "60.188.86.59:9700", "82.26.195.52:23003",
            "185.220.101.34:6881", "193.148.122.89:51413", "77.247.181.200:6881",
            "109.70.100.55:6881", "141.98.10.66:6881", "217.12.204.17:6881",
            "91.219.236.130:6881", "195.201.150.42:6881", "80.94.12.187:6881",
        ]
        lines = [json.dumps({"node": s}) for s in sample]
    else:
        lines = path.read_text().strip().splitlines()

    for line in lines[:N]:
        obj = json.loads(line)
        node = obj["node"]
        ip_str, port_str = node.rsplit(':', 1)
        ip4 = socket_inet_aton(ip_str)
        port = int(port_str)
        raw6 = ip4 + struct.pack('!H', port)
        ids.append(f32(raw6))

    # If fewer than N, top up with random valid IPs
    while len(ids) < N:
        raw6 = gen_valid_v4port()
        ids.append(f32(raw6))
    return ids[:N]

def socket_inet_aton(ip: str) -> bytes:
    """Minimal IPv4 → 4 bytes (avoids importing socket just for this)."""
    parts = ip.split('.')
    return bytes(int(p) for p in parts)

# ═══════════════════════════════════════════════════════════════════════════════
#  Reversibility check
# ═══════════════════════════════════════════════════════════════════════════════

def check_reversibility(raw6: bytes) -> bool:
    id32 = f32(raw6)
    back = f32_inv(id32)
    return raw6 == back

def check_reversibility_18(data18: bytes) -> bool:
    id32 = f32_from_18b(data18)
    back = f32_from_18b_inv(id32)
    return data18 == back

# ═══════════════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    random.seed(42)  # reproducibility for scenario 2 stream

    print("╔══════════════════════════════════════════════════════════════════════╗")
    print("║   32-byte ID Uniformity Checker — 4 Scenarios × 1024 items         ║")
    print("╚══════════════════════════════════════════════════════════════════════╝")

    # ── Reversibility self-test ────────────────────────────────────────────────
    print("\n── Reversibility self-test (32f round-trip) ──")
    test_cases = [
        bytes([1, 2, 3, 4, 0x1A, 0xE1]),          # 1.2.3.4:6881
        bytes([255, 255, 255, 255, 0xFF, 0xFF]),  # 255.255.255.255:65535
        bytes([93, 184, 216, 34, 0xC8, 0x95]),    # 93.184.216.34:51349
        bytes([8, 8, 8, 8, 0x00, 0x35]),          # 8.8.8.8:53
        bytes([1, 1, 1, 1, 0xC8, 0x43]),          # 1.1.1.1:51267
    ]
    all_ok = True
    for tc in test_cases:
        ok = check_reversibility(tc)
        all_ok &= ok
        ip = '.'.join(str(b) for b in tc[:4])
        port = struct.unpack('!H', tc[4:6])[0]
        print(f"  {ip}:{port:<5} → 32f → inv → {'✓' if ok else '✗ FAIL'}")

    # Also test pure 18 B path (scenario 3 style)
    d18_ok = True
    for _ in range(16):
        d18 = os.urandom(18)
        if not check_reversibility_18(d18):
            d18_ok = False
            break
    print(f"  18 B path (16 random): {'✓' if d18_ok else '✗ FAIL'}")
    all_ok &= d18_ok
    print(f"  All reversible: {'YES' if all_ok else 'NO'}")

    if not all_ok:
        print("\n[FATAL] Reversibility broken — aborting.")
        sys.exit(1)

    # ── Run scenarios ──────────────────────────────────────────────────────────
    results = {}

    print("\n\n── Generating Scenario 1: Random 32 B ──")
    ids1 = scenario_1()
    results['S1'] = summarize("SCENARIO 1 — Random 32 B", ids1)

    print("\n\n── Generating Scenario 2: Stream IPv4:port → 32f ──")
    ids2 = scenario_2()
    results['S2'] = summarize("SCENARIO 2 — Stream IPv4:port (filtered) → 32f", ids2)

    print("\n\n── Generating Scenario 3: Ed25519 → Yggdrasil → 32f ──")
    ids3 = scenario_3()
    if ids3:
        results['S3'] = summarize("SCENARIO 3 — Ed25519 → Yggdrasil 18 B → 32f", ids3)

    print("\n\n── Generating Scenario 4: Real nodes JSONL → 32f ──")
    jsonl = "nodes_20260918.jsonl"
    ids4 = scenario_4(jsonl)
    results['S4'] = summarize("SCENARIO 4 — Real IPv4:port (JSONL) → 32f", ids4)

    # ── Examples ───────────────────────────────────────────────────────────────
    print(f"\n\n{'═'*72}")
    print(f"  EXAMPLES")
    print(f"{'═'*72}")

    for label, ids in [("S1 (random)", ids1), ("S2 (stream)", ids2),
                       ("S3 (ed25519)", ids3), ("S4 (real)", ids4)]:
        if not ids:
            continue
        print(f"\n  {label}:")
        for i in range(3):
            print(f"    [{i}] {ids[i].hex()}")

    # Show a full 32f trace
    print(f"\n  ── 32f pipeline trace (example: 93.184.216.34:6881) ──")
    raw6 = bytes([93, 184, 216, 34]) + struct.pack('!H', 6881)
    ip4, port = raw6[:4], struct.unpack('!H', raw6[4:6])[0]
    v6p  = v4port_to_v6port(ip4, port)
    mix  = mix_144(v6p)
    id32 = spread(mix)
    back = f32_inv(id32)
    print(f"    6 B  input : {raw6.hex()}  ({'.'.join(map(str, raw6[:4]))}:{port})")
    print(f"    18 B v6:p  : {v6p.hex()}")
    print(f"    18 B mixed : {mix.hex()}")
    print(f"    32 B output: {id32.hex()}")
    print(f"    inv → 6 B  : {back.hex()}  "
          f"({'.'.join(map(str, back[:4]))}:{struct.unpack('!H', back[4:6])[0]})")
    print(f"    match      : {raw6 == back}")

    # ── Summary table ──────────────────────────────────────────────────────────
    print(f"\n\n{'═'*72}")
    print(f"  SUMMARY")
    print(f"{'═'*72}")
    print(f"  {'Scenario':<44} {'mean χ²':>9} {'mean H':>8} {'fails':>6}")
    print(f"  {'─'*44} {'─'*9} {'─'*8} {'─'*6}")
    for key, label in [('S1', 'S1: Random 32B'),
                       ('S2', 'S2: Stream IPv4:port→32f'),
                       ('S3', 'S3: Ed25519→Yggdrasil→32f'),
                       ('S4', 'S4: Real JSONL→32f')]:
        if key in results:
            c, h, f = results[key]
            print(f"  {label:<44} {c:>9.2f} {h:>8.4f} {f:>6}")
        else:
            print(f"  {label:<44} {'—':>9} {'—':>8} {'—':>6}")

    print(f"\n  χ² critical (df=255, α=0.01) ≈ 341.1")
    print(f"  Ideal mean χ² ≈ 255.0, ideal entropy = 8.0000 bits")
    print(f"  0 fails across all positions = strong evidence of uniformity.")
    print()

if __name__ == '__main__':
    main()
