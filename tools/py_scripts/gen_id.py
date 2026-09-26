# Rewrite uniform vs normal

#!/usr/bin/env python3
"""
1024 x 32B IDs - four generation scenarios and normality comparison

Scenario 1:
    Fully random 32-byte IDs.

Scenario 2:
    Random public IPv4 + DHT port:
        IPv4:port = 4B IPv4 + 2B big-endian port = 6B

    IPv4 is converted to IPv4-mapped IPv6:
        ::ffff:a.b.c.d

    The result is:
        IPv6:port = 16B IPv6 + 2B port = 18B

Scenario 3:
    Random Ed25519 private seeds.
    Public keys are converted into Yggdrasil IPv6 addresses.
    A fixed high port is appended:
        Yggdrasil IPv6 + port = 18B

Scenario 4:
    Real-world DHT nodes read from a JSONL file
    (nodes_20260918.jsonl), one JSON object per line:

        {"node":"212.59.79.166:6881"}

    Each "node" value is an IPv4:port endpoint (bracketed IPv6
    endpoints are also accepted). IPv4 endpoints are converted to
    IPv4-mapped IPv6:port exactly like scenario 2:

        IPv4:port -> IPv6:port = 18B

    Duplicate endpoints are dropped. When the file contains more
    unique endpoints than NUM_IDS, a uniform random sample of
    NUM_IDS endpoints is used. Reserved IPv4 addresses are kept by
    default (real-world data) and only reported; set
    NODES_REQUIRE_PUBLIC = True to filter them like scenario 2.

Scenarios 2, 3, and 4 pass their 18-byte endpoints through 32f():

    18B -> reversible 144-bit mixer
        -> spread over fixed positions in 256 bits
        -> remaining 112 bits filled with random bits
        -> 32B ID

The 144-bit mixer is a reversible 3 x 48-bit generalized Feistel network.
It uses only fixed-width integer arithmetic, additions, XORs, shifts,
rotations, and multiplications. It is not intended to be cryptographic.
"""

import hashlib
import ipaddress
import json
import math
import os
import random
import secrets
import statistics
import struct
from collections import Counter


NUM_IDS = 1024
ID_SIZE = 32
YGGDRASIL_PORT = 51413

# Scenario 4: real-world DHT nodes file, one {"node": "ip:port"} per line.
NODES_FILE = "nodes_20260918.jsonl"

# Scenario 4: when True, reserved/private IPv4 nodes are skipped using the
# same filter as scenario 2. When False (default), every valid endpoint is
# kept as real-world data and the classification is only reported.
NODES_REQUIRE_PUBLIC = False


try:
    from scipy import stats

    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False


# ============================================================================
# General statistics
# ============================================================================

def normal_cdf(z):
    return 0.5 * (1.0 + math.erf(z / math.sqrt(2.0)))


def ks_test_normal(data, mean, stdev):
    """Kolmogorov-Smirnov distance against Normal(mean, stdev)."""
    n = len(data)
    sorted_data = sorted(data)
    d_max = 0.0

    for i, x in enumerate(sorted_data):
        z = (x - mean) / stdev if stdev else 0.0
        cdf = normal_cdf(z)

        ecdf_high = (i + 1) / n
        ecdf_low = i / n

        d_max = max(
            d_max,
            abs(ecdf_high - cdf),
            abs(ecdf_low - cdf),
        )

    critical_05 = 1.36 / math.sqrt(n)
    return d_max, critical_05


def moments(data, mean, stdev):
    n = len(data)

    m3 = sum((x - mean) ** 3 for x in data) / n
    m4 = sum((x - mean) ** 4 for x in data) / n

    skew = m3 / (stdev ** 3) if stdev else 0.0
    kurt_excess = m4 / (stdev ** 4) - 3.0 if stdev else 0.0

    return skew, kurt_excess


def ascii_histogram(data, title, bins=20, width=50):
    lo = min(data)
    hi = max(data)
    span = hi - lo or 1

    counts = [0] * bins

    for x in data:
        index = min(int((x - lo) / span * bins), bins - 1)
        counts[index] += 1

    cmax = max(counts)

    print(f"\n{title}")
    print(f"Range: [{lo:.1f} .. {hi:.1f}]")

    for i, count in enumerate(counts):
        b_lo = lo + span * i / bins
        b_hi = lo + span * (i + 1) / bins
        bar = "█" * int(count / cmax * width)

        print(
            f"{b_lo:7.1f}-{b_hi:7.1f} | "
            f"{bar:<{width}} {count:4d}"
        )


# ============================================================================
# Scenario 2: Elixir-compatible IPv4 and DHT-port generation
# ============================================================================

def rand_octet():
    # Elixir: Enum.random(1..255)
    return secrets.randbelow(255) + 1


def rand_high_port():
    # Elixir: Enum.random(20_000..65_500)
    return 20_000 + secrets.randbelow(65_500 - 20_000 + 1)


def rand_dht_port():
    # Elixir: Enum.random([6881, 51413, rand_high_port()])
    choice = secrets.randbelow(3)

    if choice == 0:
        return 6881
    if choice == 1:
        return 51413

    return rand_high_port()


def rand_ip():
    return (
        rand_octet(),
        rand_octet(),
        rand_octet(),
        rand_octet(),
    )


def reserved_ipv4_reason(a, b, c, d):
    """
    Direct translation of the Elixir reserved_ipv4_reason/4 function.
    """

    if a == 0:
        return "current_network"

    if a == 10:
        return "private"

    if a == 100 and 64 <= b <= 127:
        return "carrier_grade_nat"

    if a == 127:
        return "loopback"

    if a == 169 and b == 254:
        return "link_local"

    if a == 172 and 16 <= b <= 31:
        return "private"

    if a == 192 and b == 0:
        return "several_purposes_and_test_net_1"

    if a == 192 and b == 31 and c == 196:
        return "as112_project"

    if a == 192 and b == 52 and c == 193:
        return "automatic_multicast_tunneling"

    if a == 192 and b == 88 and c == 99:
        return "six_to_four_relay"

    if a == 192 and b == 168:
        return "private"

    if a == 192 and b == 175 and c == 48:
        return "as112_project"

    if a == 198 and 18 <= b <= 19:
        return "benchmarking"

    if a == 198 and b == 51 and c == 100:
        return "test_net_2"

    if a == 203 and b == 0 and c == 113:
        return "test_net_3"

    if 224 <= a <= 239:
        return "multicast"

    if a >= 240:
        return "reserved"

    return "viable_public"


def valid_public_ip(ip_tuple):
    return reserved_ipv4_reason(*ip_tuple) == "viable_public"


def ipv4_port_to_6_bytes(ip_tuple, port):
    """
    Binary IPv4:port representation:

        4 bytes IPv4
        2 bytes big-endian port
    """
    return bytes(ip_tuple) + struct.pack(">H", port)


def ipv4_port_6_to_ipv6_port_18(endpoint6):
    """
    Convert 6B IPv4:port into 18B IPv6:port.

    The IPv4 address is represented as an IPv4-mapped IPv6 address:

        ::ffff:a.b.c.d
    """

    if len(endpoint6) != 6:
        raise ValueError("expected a 6-byte IPv4:port value")

    ipv4_bytes = endpoint6[:4]
    port_bytes = endpoint6[4:]

    ipv6_mapped = (
        b"\x00" * 10
        + b"\xff\xff"
        + ipv4_bytes
    )

    return ipv6_mapped + port_bytes


def ipv6_port_18_to_ipv4_port_6(endpoint18):
    """
    Reverse ::ffff:a.b.c.d:port back into IPv4:port.
    """

    if len(endpoint18) != 18:
        raise ValueError("expected an 18-byte IPv6:port value")

    expected_prefix = b"\x00" * 10 + b"\xff\xff"

    if endpoint18[:12] != expected_prefix:
        raise ValueError("not an IPv4-mapped IPv6 endpoint")

    return endpoint18[12:16] + endpoint18[16:18]


def endpoint18_to_text(endpoint18):
    address = ipaddress.IPv6Address(endpoint18[:16])
    port = struct.unpack(">H", endpoint18[16:18])[0]

    return f"[{address}]:{port}"


def endpoint6_to_text(endpoint6):
    address = ipaddress.IPv4Address(endpoint6[:4])
    port = struct.unpack(">H", endpoint6[4:6])[0]

    return f"{address}:{port}"


def generate_udp_records(count):
    """
    Generate accepted records:

        (6B IPv4:port, 18B IPv6:port)
    """

    records = []
    attempts = 0

    while len(records) < count:
        attempts += 1

        ip_tuple = rand_ip()
        port = rand_dht_port()

        if not valid_public_ip(ip_tuple):
            continue

        endpoint6 = ipv4_port_to_6_bytes(ip_tuple, port)
        endpoint18 = ipv4_port_6_to_ipv6_port_18(endpoint6)

        records.append((endpoint6, endpoint18))

    return records, attempts


# ============================================================================
# Ed25519 and Yggdrasil address generation
# ============================================================================

# The implementation below derives an Ed25519 public key from a 32-byte
# RFC 8032 private seed without requiring an external package.

ED_MODULUS = 2**255 - 19

ED_D = (
    -121665
    * pow(121666, ED_MODULUS - 2, ED_MODULUS)
    % ED_MODULUS
)

ED_BASE_X = (
    15112221349535400772501151409588531511454012693041857206046113283949847762202
)

ED_BASE_Y = (
    46316835694926478169428394003475163141307993866256225615783033603165251855960
)


def ed_point_add(p1, p2):
    """
    Extended-coordinate Edwards addition for Ed25519.
    """

    x1, y1, z1, t1 = p1
    x2, y2, z2, t2 = p2

    a = (y1 - x1) * (y2 - x2)
    b = (y1 + x1) * (y2 + x2)
    c = 2 * ED_D * t1 * t2
    d = 2 * z1 * z2

    e = b - a
    f = d - c
    g = d + c
    h = b + a

    x3 = e * f
    y3 = g * h
    t3 = e * h
    z3 = f * g

    return (
        x3 % ED_MODULUS,
        y3 % ED_MODULUS,
        z3 % ED_MODULUS,
        t3 % ED_MODULUS,
    )


def ed_point_double(point):
    """
    Extended-coordinate Edwards doubling for Ed25519.
    """

    x1, y1, z1, _t1 = point

    a = x1 * x1
    b = y1 * y1
    c = 2 * z1 * z1
    d = -a

    e = (x1 + y1) * (x1 + y1) - a - b
    g = d + b
    f = g - c
    h = d - b

    x3 = e * f
    y3 = g * h
    t3 = e * h
    z3 = f * g

    return (
        x3 % ED_MODULUS,
        y3 % ED_MODULUS,
        z3 % ED_MODULUS,
        t3 % ED_MODULUS,
    )


def ed_scalar_multiply(scalar, point):
    identity = (0, 1, 1, 0)
    result = identity
    current = point

    while scalar:
        if scalar & 1:
            result = ed_point_add(result, current)

        current = ed_point_double(current)
        scalar >>= 1

    return result


def ed_encode_point(point):
    x, y, z, _t = point

    z_inverse = pow(z, ED_MODULUS - 2, ED_MODULUS)
    x_affine = x * z_inverse % ED_MODULUS
    y_affine = y * z_inverse % ED_MODULUS

    encoded = y_affine | ((x_affine & 1) << 255)
    return encoded.to_bytes(32, "little")


def ed25519_public_from_seed(seed):
    """
    Derive a raw 32-byte Ed25519 public key from a raw 32-byte private seed.
    """

    if len(seed) != 32:
        raise ValueError("Ed25519 private seed must be 32 bytes")

    digest = bytearray(hashlib.sha512(seed).digest()[:32])

    # RFC 8032 pruning/clamping.
    digest[0] &= 248
    digest[31] &= 63
    digest[31] |= 64

    scalar = int.from_bytes(digest, "little")

    base_point = (
        ED_BASE_X,
        ED_BASE_Y,
        1,
        (ED_BASE_X * ED_BASE_Y) % ED_MODULUS,
    )

    public_point = ed_scalar_multiply(scalar, base_point)
    return ed_encode_point(public_point)


def yggdrasil_address_from_public_key(public_key):
    """
    Current Yggdrasil address derivation:

        SHA-512(raw Ed25519 public key)
        first 128 bits
        force the address into 200::/7 (0200::/7)

    To map strictly into the 200::/7 network, the first 7 bits
    must be exactly 0000 001. In big-endian network byte order:
    - bits 1-7 of byte 0 are set to 0000001
    - bit 8 of the address (LSB of byte 0) is derived from the hash.
    Thus, the first byte of the IP is guaranteed to be 0x02 or 0x03.
    """

    digest = hashlib.sha512(public_key).digest()
    address = bytearray(digest[:16])

    # Enforce 0200::/7 prefix
    address[0] = (address[0] & 0x01) | 0x02

    return bytes(address)


def valid_yggdrasil_address(address):
    """
    Strict validation of Yggdrasil range 200::/7 (or 0200::/7) using standard 
    ipaddress verification.
    """
    if len(address) != 16:
        return False
    try:
        ip = ipaddress.IPv6Address(address)
        return ip in ipaddress.IPv6Network("200::/7")
    except Exception:
        return False


def generate_ygg_records(count):
    """
    Return records:

        (private_seed, public_key, 18B IPv6:port)
    """

    records = []

    for _ in range(count):
        private_seed = secrets.token_bytes(32)
        public_key = ed25519_public_from_seed(private_seed)

        ygg_address = yggdrasil_address_from_public_key(public_key)

        if not valid_yggdrasil_address(ygg_address):
            raise AssertionError("invalid generated Yggdrasil address")

        endpoint18 = (
            ygg_address
            + struct.pack(">H", YGGDRASIL_PORT)
        )

        records.append((private_seed, public_key, endpoint18))

    return records


# ============================================================================
# Scenario 4: real-world DHT nodes from a JSONL file
# ============================================================================

def parse_node_endpoint(text):
    """
    Parse one node endpoint string into (endpoint6, endpoint18).

    Accepted forms:
        "a.b.c.d:port"   -> (6B IPv4:port, 18B IPv4-mapped IPv6:port)
        "[IPv6]:port"    -> (None, 18B IPv6:port)
                            or the 6B form when the address is IPv4-mapped
        "IPv6:port"      -> best effort via the last colon

    Returns None when the text cannot be parsed.
    """

    if not isinstance(text, str):
        return None

    value = text.strip()

    if not value:
        return None

    if value.startswith("["):
        closing = value.find("]")

        if closing < 0:
            return None

        host = value[1:closing].strip()
        remainder = value[closing + 1:]

        if not remainder.startswith(":"):
            return None

        port_text = remainder[1:].strip()
    else:
        host, separator, port_text = value.rpartition(":")
        host = host.strip()
        port_text = port_text.strip()

        if not separator or not host:
            return None

    try:
        port = int(port_text)
    except ValueError:
        return None

    if not 0 <= port <= 65535:
        return None

    port_bytes = struct.pack(">H", port)

    # Plain IPv4.
    try:
        ipv4 = ipaddress.IPv4Address(host)
    except ValueError:
        pass
    else:
        endpoint6 = ipv4.packed + port_bytes
        return endpoint6, ipv4_port_6_to_ipv6_port_18(endpoint6)

    # IPv6 (bracketed or bare).
    try:
        ipv6 = ipaddress.IPv6Address(host)
    except ValueError:
        return None

    # Fold IPv4-mapped IPv6 into the compact 6B form.
    if ipv6.ipv4_mapped is not None:
        endpoint6 = ipv6.ipv4_mapped.packed + port_bytes
        return endpoint6, ipv4_port_6_to_ipv6_port_18(endpoint6)

    return None, ipv6.packed + port_bytes


def load_nodes_records(path, count):
    """
    Read real-world node endpoints from a JSONL file.

    Every non-empty line is expected to be a JSON object such as:

        {"node": "212.59.79.166:6881"}

    Returns (records, stats). Each record is:

        (node_text, endpoint6_or_None, endpoint18)

    Behavior:
        - invalid lines are counted and skipped
        - duplicate endpoints (by 18B form) are counted and dropped
        - when NODES_REQUIRE_PUBLIC is True, reserved IPv4 endpoints
          are skipped using the same filter as scenario 2
        - when more unique endpoints than `count` exist, a uniform
          random sample of `count` records is returned
        - when fewer exist, all of them are returned
    """

    if not os.path.isfile(path):
        raise FileNotFoundError(f"nodes file not found: {path}")

    records = []
    seen = set()

    line_count = 0
    invalid_count = 0
    duplicate_count = 0
    skipped_reserved = 0
    reserved_counts = Counter()
    port_counts = Counter()

    with open(path, "r", encoding="utf-8-sig") as handle:
        for line in handle:
            stripped = line.strip()

            if not stripped:
                continue

            line_count += 1

            try:
                entry = json.loads(stripped)
                node_text = entry["node"]
            except (ValueError, KeyError, TypeError):
                invalid_count += 1
                continue

            parsed = parse_node_endpoint(node_text)

            if parsed is None:
                invalid_count += 1
                continue

            endpoint6, endpoint18 = parsed

            if NODES_REQUIRE_PUBLIC and endpoint6 is not None:
                if not valid_public_ip(tuple(endpoint6[:4])):
                    skipped_reserved += 1
                    continue

            if endpoint18 in seen:
                duplicate_count += 1
                continue

            seen.add(endpoint18)

            if endpoint6 is not None:
                reserved_counts[
                    reserved_ipv4_reason(*endpoint6[:4])
                ] += 1
                port = struct.unpack(">H", endpoint6[4:6])[0]
            else:
                port = struct.unpack(">H", endpoint18[16:18])[0]

            port_counts[port] += 1

            records.append((node_text, endpoint6, endpoint18))

    unique_count = len(records)

    if unique_count > count:
        records = random.SystemRandom().sample(records, count)
    elif unique_count < count:
        print(
            f"WARNING: only {unique_count} unique nodes in {path}, "
            f"expected {count}; analyzing all of them"
        )

    stats = {
        "path": path,
        "lines": line_count,
        "invalid": invalid_count,
        "duplicates": duplicate_count,
        "skipped_reserved": skipped_reserved,
        "unique": unique_count,
        "used": len(records),
        "reserved_counts": reserved_counts,
        "port_counts": port_counts,
    }

    return records, stats


# ============================================================================
# 144-bit reversible mixer
# ============================================================================

"""
The mixer works as three 48-bit lanes.

Each round is:

    (a, b, c) -> (b, c, a XOR F(b XOR ROTL(c)))

This is a generalized Feistel step. F itself does not need to be
invertible because the whole round is invertible:

    new_a = old_b
    new_b = old_c
    new_c = old_a XOR F(old_b, old_c)

The inverse therefore uses the same F function in reverse round order.
"""

LANE_BITS = 48
LANE_MASK = (1 << LANE_BITS) - 1
MIX_ROUNDS = 12

LANE_MUL_1 = 0xD6E8FEB86659
LANE_MUL_2 = 0xA5A3564E27F1

ROUND_BASE = 0x9E3779B97F4A
ROUND_STEP = 0xBB67AE8584C9


def rotl48(value, amount):
    amount %= LANE_BITS

    if amount == 0:
        return value & LANE_MASK

    return (
        (value << amount)
        | (value >> (LANE_BITS - amount))
    ) & LANE_MASK


def lane_mix(value, key):
    value = (value + key) & LANE_MASK

    value ^= value >> 17

    value = (value * LANE_MUL_1) & LANE_MASK

    value ^= (value << 11) & LANE_MASK

    value = (
        value
        + (key ^ 0x243F6A8885A3)
    ) & LANE_MASK

    value = (value * LANE_MUL_2) & LANE_MASK

    value ^= value >> 23

    return value & LANE_MASK


def mix144(value):
    """
    Reversible 144-bit permutation.
    """

    if not 0 <= value < (1 << 144):
        raise ValueError("value must fit in 144 bits")

    a = (value >> 96) & LANE_MASK
    b = (value >> 48) & LANE_MASK
    c = value & LANE_MASK

    for round_index in range(MIX_ROUNDS):
        key = (
            ROUND_BASE
            + round_index * ROUND_STEP
        ) & LANE_MASK

        rotation = (5 + 7 * round_index) % LANE_BITS

        mixed = lane_mix(
            b ^ rotl48(c, rotation),
            key,
        )

        a, b, c = (
            b,
            c,
            (a ^ mixed) & LANE_MASK,
        )

    return (
        (a << 96)
        | (b << 48)
        | c
    )


def unmix144(value):
    """
    Exact inverse of mix144().
    """

    if not 0 <= value < (1 << 144):
        raise ValueError("value must fit in 144 bits")

    a = (value >> 96) & LANE_MASK
    b = (value >> 48) & LANE_MASK
    c = value & LANE_MASK

    for round_index in reversed(range(MIX_ROUNDS)):
        key = (
            ROUND_BASE
            + round_index * ROUND_STEP
        ) & LANE_MASK

        rotation = (5 + 7 * round_index) % LANE_BITS

        old_b = a
        old_c = b

        mixed = lane_mix(
            old_b ^ rotl48(old_c, rotation),
            key,
        )

        old_a = (c ^ mixed) & LANE_MASK

        a, b, c = old_a, old_b, old_c

    return (
        (a << 96)
        | (b << 48)
        | c
    )


# ============================================================================
# 32f: spread 144 bits into 256 bits and add random filler
# ============================================================================

FULL_256_MASK = (1 << 256) - 1

"""
Payload bit i is stored at this fixed output bit position.

Because 167 is coprime to 256, the first 144 generated positions are
all unique.
"""

PAYLOAD_POSITIONS = tuple(
    (167 * i + 29) & 0xFF
    for i in range(144)
)

if len(set(PAYLOAD_POSITIONS)) != 144:
    raise AssertionError("payload positions are not unique")


PAYLOAD_MASK = sum(
    1 << position
    for position in PAYLOAD_POSITIONS
)


def encode_32f(payload18):
    """
    Encode exactly 18 bytes into a 32-byte ID.

    The 18 bytes are mixed deterministically.
    The mixed 144 bits are scattered over fixed positions.
    The remaining 112 bits are random.
    """

    if len(payload18) != 18:
        raise ValueError("32f input must be exactly 18 bytes")

    input_value = int.from_bytes(payload18, "big")
    mixed_value = mix144(input_value)

    # Generate random filler, then clear all payload positions.
    output_value = (
        secrets.randbits(256)
        & (FULL_256_MASK ^ PAYLOAD_MASK)
    )

    for payload_bit, output_bit in enumerate(PAYLOAD_POSITIONS):
        bit = (mixed_value >> payload_bit) & 1
        output_value |= bit << output_bit

    return output_value.to_bytes(32, "big")


def decode_32f(identifier32):
    """
    Extract the 144-bit payload and reverse the mixer.

    The 112 random filler bits are ignored.
    """

    if len(identifier32) != 32:
        raise ValueError("32f input must be exactly 32 bytes")

    input_value = int.from_bytes(identifier32, "big")
    mixed_value = 0

    for payload_bit, output_bit in enumerate(PAYLOAD_POSITIONS):
        bit = (input_value >> output_bit) & 1
        mixed_value |= bit << payload_bit

    original_value = unmix144(mixed_value)
    return original_value.to_bytes(18, "big")


def test_32f():
    test_values = [
        bytes(18),
        bytes(range(18)),
        secrets.token_bytes(18),
    ]

    for payload in test_values:
        encoded = encode_32f(payload)
        decoded = decode_32f(encoded)

        if decoded != payload:
            raise AssertionError("32f round-trip failed")


# ============================================================================
# Scenario analysis
# ============================================================================

THEORY_SUM_MEAN = ID_SIZE * 127.5
THEORY_SUM_STDEV = math.sqrt(
    ID_SIZE * ((256 ** 2 - 1) / 12)
)

THEORY_BITCOUNT_MEAN = ID_SIZE * 8 / 2
THEORY_BITCOUNT_STDEV = math.sqrt(
    ID_SIZE * 8 * 0.25
)


def analyze_ids(name, ids_bytes, show_histogram=True):
    print(f"\n{'=' * 78}")
    print(f"{name}")
    print(f"{'=' * 78}")

    # Scenarios 1-3 always provide exactly NUM_IDS IDs; scenario 4 may
    # provide fewer when the nodes file contains fewer unique endpoints.
    if len(ids_bytes) < 2:
        raise AssertionError("not enough IDs to analyze")

    if any(len(item) != ID_SIZE for item in ids_bytes):
        raise AssertionError("unexpected ID size")

    print(f"IDs analyzed: {len(ids_bytes)}")

    all_bytes = [
        byte
        for identifier in ids_bytes
        for byte in identifier
    ]

    total_bytes = len(all_bytes)
    total_bits = total_bytes * 8

    # ------------------------------------------------------------------
    # Bit-level balance
    # ------------------------------------------------------------------

    ones = sum(
        byte.bit_count()
        for byte in all_bytes
    )
    zeros = total_bits - ones

    expected_ones = total_bits / 2
    bit_stdev = math.sqrt(total_bits * 0.25)
    z_bits = (ones - expected_ones) / bit_stdev

    ones_ratio = ones / total_bits * 100.0

    print("\n--- 1. BIT LEVEL UNIFORMITY ---")
    print(f"Total bits: {total_bits}")
    print(f"Ones: {ones}, zeros: {zeros}")
    print(f"Ones ratio: {ones_ratio:.4f}%")
    print(
        f"Z-score: {z_bits:+.3f} "
        f"(|z| < 1.96 = PASS 95%) -> "
        f"{'PASS' if abs(z_bits) < 1.96 else 'FAIL'}"
    )

    # ------------------------------------------------------------------
    # Byte-level uniformity
    # ------------------------------------------------------------------

    print("\n--- 2. BYTE LEVEL UNIFORMITY ---")

    frequencies = Counter(all_bytes)
    expected_frequency = total_bytes / 256

    chi2 = sum(
        (
            frequencies.get(value, 0)
            - expected_frequency
        ) ** 2 / expected_frequency
        for value in range(256)
    )

    print(f"Expected count per byte value: {expected_frequency:.1f}")
    print(f"Chi-square: {chi2:.2f}")
    print("Reference: df=255, expected chi-square approximately 255")

    chi2_pass = 175 < chi2 < 335
    print(
        f"-> {'PASS-ish' if chi2_pass else 'SUSPICIOUS'} "
        f"using the original heuristic range"
    )

    if HAS_SCIPY:
        chi2_p = stats.chi2.sf(chi2, 255)
        print(f"Scipy chi-square p-value: {chi2_p:.4f}")
    else:
        chi2_p = None

    # ------------------------------------------------------------------
    # Per-ID normality
    # ------------------------------------------------------------------

    sums = [
        sum(identifier)
        for identifier in ids_bytes
    ]

    bitcounts = [
        sum(byte.bit_count() for byte in identifier)
        for identifier in ids_bytes
    ]

    print("\n--- 3. PER-ID NORMALITY ---")
    print(
        "Ideal random-32B reference: "
        f"sum mean={THEORY_SUM_MEAN:.2f}, "
        f"sum stdev={THEORY_SUM_STDEV:.2f}, "
        f"bit-count mean={THEORY_BITCOUNT_MEAN:.2f}, "
        f"bit-count stdev={THEORY_BITCOUNT_STDEV:.2f}"
    )

    metric_results = {}

    for label, data, theory_mean, theory_stdev in [
        (
            "Sum of 32 bytes per ID",
            sums,
            THEORY_SUM_MEAN,
            THEORY_SUM_STDEV,
        ),
        (
            "Bit-count per ID",
            bitcounts,
            THEORY_BITCOUNT_MEAN,
            THEORY_BITCOUNT_STDEV,
        ),
    ]:
        sample_mean = statistics.mean(data)
        sample_stdev = statistics.stdev(data)
        median = statistics.median(data)

        skew, kurtosis = moments(
            data,
            sample_mean,
            sample_stdev,
        )

        sample_count = len(data)
        jarque_bera = sample_count / 6.0 * (
            skew ** 2 + kurtosis ** 2 / 4.0
        )

        if HAS_SCIPY:
            jb_p_value = float(
                stats.jarque_bera(data).pvalue
            )
        else:
            # Asymptotic chi-square survival function for df=2.
            jb_p_value = math.exp(-jarque_bera / 2.0)

        ks_d, ks_critical = ks_test_normal(
            data,
            theory_mean,
            theory_stdev,
        )

        normality_degree = (1.0 - ks_d) * 100.0

        print(f"\n{label}:")
        print(
            f"  sample mean={sample_mean:.2f}, "
            f"ideal mean={theory_mean:.2f}"
        )
        print(
            f"  sample stdev={sample_stdev:.2f}, "
            f"ideal stdev={theory_stdev:.2f}"
        )
        print(f"  median={median:.2f}")
        print(f"  min={min(data)}, max={max(data)}")
        print(
            f"  skew={skew:+.4f}, "
            f"excess kurtosis={kurtosis:+.4f}"
        )
        print(
            f"  Jarque-Bera={jarque_bera:.3f}, "
            f"p-value={jb_p_value:.4f} -> "
            f"{'NORMAL-ish' if jb_p_value > 0.05 else 'NOT NORMAL'}"
        )
        print(
            f"  KS D={ks_d:.4f}, "
            f"critical 5%={ks_critical:.4f} -> "
            f"{'PASS' if ks_d < ks_critical else 'FAIL'}"
        )
        print(
            f"  Degree of normal distribution: "
            f"{normality_degree:.2f}%"
        )

        if HAS_SCIPY:
            scipy_normaltest_p = float(
                stats.normaltest(data).pvalue
            )
            print(
                f"  Scipy D'Agostino normality p-value: "
                f"{scipy_normaltest_p:.4f}"
            )

        metric_key = (
            "sum"
            if label.startswith("Sum")
            else "bitcount"
        )

        metric_results[f"{metric_key}_ks"] = ks_d
        metric_results[f"{metric_key}_degree"] = normality_degree

        if label.startswith("Sum") and show_histogram:
            ascii_histogram(
                data,
                f"{name} - per-ID byte-sum histogram",
            )

    return {
        "ones_ratio": ones_ratio,
        "chi2": chi2,
        "sum_mean": statistics.mean(sums),
        "sum_stdev": statistics.stdev(sums),
        "sum_ks": metric_results["sum_ks"],
        "sum_degree": metric_results["sum_degree"],
        "bitcount_ks": metric_results["bitcount_ks"],
        "bitcount_degree": metric_results["bitcount_degree"],
    }


# ============================================================================
# Main
# ============================================================================

def main():
    print(
        f"Generating {NUM_IDS} IDs per scenario "
        f"({ID_SIZE} bytes / {ID_SIZE * 8} bits each)..."
    )
    print(f"Scenario 4 reads real-world nodes from: {NODES_FILE}")

    print("Testing reversible 32f transform...")
    test_32f()
    print("32f round-trip: PASS")

    # ------------------------------------------------------------------
    # Scenario 1: completely random IDs
    # ------------------------------------------------------------------

    scenario1_ids = [
        secrets.token_bytes(ID_SIZE)
        for _ in range(NUM_IDS)
    ]

    # ------------------------------------------------------------------
    # Scenario 2: filtered public IPv4 + DHT port
    # ------------------------------------------------------------------

    udp_records, udp_attempts = generate_udp_records(NUM_IDS)

    scenario2_ids = [
        encode_32f(endpoint18)
        for _endpoint6, endpoint18 in udp_records
    ]

    for endpoint6, endpoint18 in udp_records:
        encoded = encode_32f(endpoint18)
        decoded18 = decode_32f(encoded)
        decoded6 = ipv6_port_18_to_ipv4_port_6(decoded18)

        if decoded18 != endpoint18:
            raise AssertionError("scenario 2 18B reverse failed")

        if decoded6 != endpoint6:
            raise AssertionError("scenario 2 6B reverse failed")

    # ------------------------------------------------------------------
    # Scenario 3: Ed25519 -> Yggdrasil IPv6 + fixed high port
    # ------------------------------------------------------------------

    ygg_records = generate_ygg_records(NUM_IDS)

    scenario3_ids = [
        encode_32f(endpoint18)
        for _private_seed, _public_key, endpoint18 in ygg_records
    ]

    for _private_seed, _public_key, endpoint18 in ygg_records:
        encoded = encode_32f(endpoint18)
        decoded18 = decode_32f(encoded)

        if decoded18 != endpoint18:
            raise AssertionError("scenario 3 18B reverse failed")

    # ------------------------------------------------------------------
    # Scenario 4: real-world DHT nodes from a JSONL file
    # ------------------------------------------------------------------

    scenario4_records = None
    nodes_stats = None
    scenario4_ids = None

    if os.path.isfile(NODES_FILE):
        scenario4_records, nodes_stats = load_nodes_records(
            NODES_FILE,
            NUM_IDS,
        )

        if not scenario4_records:
            raise RuntimeError(
                f"no valid node endpoints in {NODES_FILE} "
                f"(lines={nodes_stats['lines']}, "
                f"invalid={nodes_stats['invalid']})"
            )

        scenario4_ids = [
            encode_32f(endpoint18)
            for _node_text, _endpoint6, endpoint18 in scenario4_records
        ]

        for _node_text, endpoint6, endpoint18 in scenario4_records:
            encoded = encode_32f(endpoint18)
            decoded18 = decode_32f(encoded)

            if decoded18 != endpoint18:
                raise AssertionError("scenario 4 18B reverse failed")

            if endpoint6 is not None:
                decoded6 = ipv6_port_18_to_ipv4_port_6(decoded18)

                if decoded6 != endpoint6:
                    raise AssertionError("scenario 4 6B reverse failed")
    else:
        print(
            f"\nWARNING: {NODES_FILE} not found, "
            f"scenario 4 skipped"
        )

    # ------------------------------------------------------------------
    # Examples
    # ------------------------------------------------------------------

    print("\nScenario 1 examples:")
    for identifier in scenario1_ids[:5]:
        print(" ", identifier.hex())

    print("\nScenario 2 examples:")
    for endpoint6, endpoint18 in udp_records[:5]:
        identifier = encode_32f(endpoint18)
        recovered18 = decode_32f(identifier)
        recovered6 = ipv6_port_18_to_ipv4_port_6(recovered18)

        print(f"  IPv4:port : {endpoint6_to_text(endpoint6)}")
        print(f"  6B source : {endpoint6.hex()}")
        print(f"  IPv6:port : {endpoint18_to_text(endpoint18)}")
        print(f"  18B data  : {endpoint18.hex()}")
        print(f"  32B ID    : {identifier.hex()}")
        print(f"  reverse 6B: {recovered6.hex()}")
        print()

    print("\nScenario 3 examples:")
    for private_seed, public_key, endpoint18 in ygg_records[:5]:
        identifier = encode_32f(endpoint18)

        ygg_address = ipaddress.IPv6Address(endpoint18[:16])

        print(f"  public key : {public_key.hex()}")
        print(f"  Ygg address: [{ygg_address}]:{YGGDRASIL_PORT}")
        print(f"  18B data   : {endpoint18.hex()}")
        print(f"  32B ID     : {identifier.hex()}")
        print()

    if scenario4_records is not None:
        print(f"\nScenario 4 source: {nodes_stats['path']}")
        print(
            f"  node lines={nodes_stats['lines']}, "
            f"invalid={nodes_stats['invalid']}, "
            f"duplicates={nodes_stats['duplicates']}, "
            f"skipped_reserved={nodes_stats['skipped_reserved']}, "
            f"unique={nodes_stats['unique']}, "
            f"used={nodes_stats['used']}"
        )

        reserved_summary = ", ".join(
            f"{reason}={number}"
            for reason, number in nodes_stats["reserved_counts"].most_common()
        )

        if reserved_summary:
            print(f"  IPv4 classification: {reserved_summary}")

        top_ports = nodes_stats["port_counts"].most_common(20)

        if top_ports:
            print(
                "  most common ports: "
                + ", ".join(
                    f"{port} x{number}"
                    for port, number in top_ports
                )
            )

        print("\nScenario 4 examples:")
        for node_text, endpoint6, endpoint18 in scenario4_records[:5]:
            identifier = encode_32f(endpoint18)
            recovered18 = decode_32f(identifier)

            print(f"  node      : {node_text}")

            if endpoint6 is not None:
                print(f"  IPv4:port : {endpoint6_to_text(endpoint6)}")

            print(f"  IPv6:port : {endpoint18_to_text(endpoint18)}")
            print(f"  18B data  : {endpoint18.hex()}")
            print(f"  32B ID    : {identifier.hex()}")

            if endpoint6 is not None:
                recovered6 = ipv6_port_18_to_ipv4_port_6(recovered18)
                print(f"  reverse 6B: {recovered6.hex()}")

            print()

    print(f"Scenario 2 accepted {NUM_IDS} addresses")
    print(f"Scenario 2 generation attempts: {udp_attempts}")

    # ------------------------------------------------------------------
    # Statistical analysis
    # ------------------------------------------------------------------

    results = {}

    results["1 random"] = analyze_ids(
        "SCENARIO 1 - fully random 32B IDs",
        scenario1_ids,
    )

    results["2 UDP"] = analyze_ids(
        "SCENARIO 2 - IPv4:port -> IPv4-mapped IPv6:port -> 32f",
        scenario2_ids,
    )

    results["3 Yggdrasil"] = analyze_ids(
        "SCENARIO 3 - Ed25519 -> Yggdrasil IPv6:port -> 32f",
        scenario3_ids,
    )

    if scenario4_ids is not None:
        results["4 real nodes"] = analyze_ids(
            "SCENARIO 4 - real-world DHT nodes (JSONL) -> IPv6:port -> 32f",
            scenario4_ids,
        )

    # ------------------------------------------------------------------
    # Compact comparison table
    # ------------------------------------------------------------------

    print(f"\n{'=' * 78}")
    print("COMPARISON AGAINST IDEAL RANDOM 32-BYTE IDS")
    print(f"{'=' * 78}")

    print(
        f"{'Scenario':<18}"
        f"{'ones %':>10}"
        f"{'byte chi2':>12}"
        f"{'sum mean':>12}"
        f"{'sum stdev':>12}"
        f"{'sum KS D':>12}"
        f"{'sum degree':>13}"
    )

    print(
        f"{'ideal reference':<18}"
        f"{50.0:>10.3f}"
        f"{255.0:>12.2f}"
        f"{THEORY_SUM_MEAN:>12.2f}"
        f"{THEORY_SUM_STDEV:>12.2f}"
        f"{0.0:>12.4f}"
        f"{100.0:>12.2f}%"
    )

    for scenario_name, result in results.items():
        print(
            f"{scenario_name:<18}"
            f"{result['ones_ratio']:>10.3f}"
            f"{result['chi2']:>12.2f}"
            f"{result['sum_mean']:>12.2f}"
            f"{result['sum_stdev']:>12.2f}"
            f"{result['sum_ks']:>12.4f}"
            f"{result['sum_degree']:>12.2f}%"
        )

    print("\nInterpretation:")
    print("  - Ideal byte chi-square is approximately 255 for df=255.")
    print("  - Ideal per-ID byte sums have mean 4080 and stdev about 418.")
    print("  - Ideal per-ID bit counts have mean 128 and stdev 8.")
    print("  - A lower KS D and higher degree indicate a closer match.")
    print("  - The 32f reversible mixer diffuses structure but cannot create")
    print("    entropy. The 112 random filler bits provide additional entropy.")
    print("  - The unkeyed mixer is obfuscating and statistically diffusive,")
    print("    but should not be treated as a cryptographic permutation.")
    print("  - Scenario 4 analyzes real-world endpoints; address and port")
    print("    distributions (including any reserved-range nodes and the")
    print("    crawl's port biases) come from the file and are reported.")

    print("\nDone.")


if __name__ == "__main__":
    main()
