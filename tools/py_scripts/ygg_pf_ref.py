#!/usr/bin/env python3
"""
ygg_pf SDP codec - executable reference implementation.

Purpose: this file is the normative reference for the ygg_pf wire encoding. The Elixir
implementation in backend/lib/ygg_pf/ MUST reproduce the vectors this file emits
(see tools/py_scripts/ygg_pf_vectors.py -> data/ygg_pf_vectors.json).

Every value that the specification left open is marked DECISION-Dn and is defined
here exactly once. See docs/SPEC_DECISIONS_NEEDED.md and docs/PROTOCOL_FROZEN.md.

Layout
    painter address = yaddr = 128-bit Ygg IPv6 || 16-bit port      = 144 bits
    part_i          = 72-bit slice of the painter address           (N = 2)
    rpart_i         = bit_reverse_per_byte(part_i)                  = 72 bits
    affix_i         = rpart_i || xor8(rpart_i)                      = 80 bits
    prefix_i        = trunc80_msb(sha256(label(i, R) || epoch_be64))= 80 bits
    yid_i           = prefix_i || affix_i                           = 160 bits / 20 B
    id_paint_i      = prefix_i || random 80 bits                    = 160 bits / 20 B
"""

import hashlib
import ipaddress
import os
import struct

# --------------------------------------------------------------------------- #
# Frozen protocol constants                                                    #
# --------------------------------------------------------------------------- #

ADDR_BITS = 128
PORT_BITS = 16
PAINTER_BITS = ADDR_BITS + PORT_BITS        # 144   INV-003
N_PARTS = 2                                 #       INV-004
PART_BITS = PAINTER_BITS // N_PARTS         # 72    INV-004
CHECKSUM_BITS = 8                           #       INV-006
AFFIX_BITS = PART_BITS + CHECKSUM_BITS      # 80    INV-007
PREFIX_BITS = 80                            #       INV-008
YID_BITS = PREFIX_BITS + AFFIX_BITS         # 160   INV-009
YID_BYTES = YID_BITS // 8                   # 20    INV-009

PART_BYTES = PART_BITS // 8                 # 9
PREFIX_BYTES = PREFIX_BITS // 8             # 10
AFFIX_BYTES = AFFIX_BITS // 8               # 10

CURSOR_START = 0                            #       INV-010
CURSOR_THRESHOLD = 8                        # escalate when count > 8, i.e. at 9  INV-011
EPOCH_SECONDS = 60                          #       INV-012

# DECISION-D4a  hash algorithm for prefix derivation
HASH = hashlib.sha256

# DECISION-D4b  the specification string is a TEMPLATE; N and R are substituted
PREFIX_LABEL = "fswarm/v1/bootstrap_prefix/part_{n}_and_cursor_{r}"

# DECISION-D5   epoch-independent fixed prefix; no cursor term
FIXED_PREFIX_LABEL = "fswarm/v1/bootstrap_prefix/fixed/part_{n}"

# DECISION-D4c  N and R are rendered as ASCII decimal inside the label
# DECISION-D4d  epoch = floor(unix_seconds / 60), unsigned 64-bit big-endian
# DECISION-D4e  truncation keeps the LEADING (most significant) 80 bits of the digest

# DECISION-D7   fixed Yggdrasil port for yaddr. 0x6666 echoes the PF marker 0x66.
YGG_PF_PORT = 0x6666                        # 26214

YGG_PREFIX_BYTE = 0x02                      # Yggdrasil 200::/7 node address


# --------------------------------------------------------------------------- #
# Bit primitives - copied semantics from b_pf_new/pf_mask_sync.ex              #
# --------------------------------------------------------------------------- #

# DECISION-D-bitrev (VERIFIED from pf_mask_sync.ex:11-17,53-58)
# bits are reversed WITHIN each byte; byte order is preserved.
_REV8 = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))


def bit_reverse_per_byte(data: bytes) -> bytes:
    """Reverse the bit order inside every byte, preserving byte order."""
    return bytes(_REV8[b] for b in data)


def xor8(data: bytes) -> int:
    """
    8-bit XOR fold. Copied semantics from pf_mask_sync.ex:48-51, with the fold
    width set equal to the checksum width (legacy used 16/16, we use 8/8).
    DECISION-D9.
    """
    acc = 0
    for b in data:
        acc ^= b
    return acc & 0xFF


# --------------------------------------------------------------------------- #
# Painter address (yaddr)                                                      #
# --------------------------------------------------------------------------- #

def painter_address(yaddr_ip: str, port: int = YGG_PF_PORT) -> bytes:
    """
    Build the 144-bit painter address: 128-bit Ygg IPv6 || 16-bit port, big-endian.
    The address is preserved verbatim - never hashed (INV-002).
    """
    packed = ipaddress.IPv6Address(yaddr_ip).packed
    if len(packed) != 16:
        raise ValueError("yaddr must be IPv6")
    if not 0 <= port <= 0xFFFF:
        raise ValueError("port out of range")
    return packed + struct.pack(">H", port)          # 18 bytes = 144 bits


def parse_painter_address(raw: bytes) -> tuple[str, int]:
    if len(raw) != PAINTER_BITS // 8:
        raise ValueError("painter address must be 18 bytes")
    ip = ipaddress.IPv6Address(raw[:16]).compressed
    (port,) = struct.unpack(">H", raw[16:])
    return ip, port


def is_ygg_addr(yaddr_ip: str) -> bool:
    """Yggdrasil node addresses live in 200::/7 and start with prefix byte 0x02."""
    return ipaddress.IPv6Address(yaddr_ip).packed[0] == YGG_PREFIX_BYTE


# --------------------------------------------------------------------------- #
# Split / join  (DECISION-D3: MSB-first, big-endian)                           #
# --------------------------------------------------------------------------- #

def split_parts(painter: bytes) -> list[bytes]:
    """144 bits -> [part0 (high 72 bits), part1 (low 72 bits)], 9 bytes each."""
    if len(painter) != PAINTER_BITS // 8:
        raise ValueError("painter address must be 18 bytes")
    return [painter[:PART_BYTES], painter[PART_BYTES:]]


def join_parts(parts: list[bytes]) -> bytes:
    """Inverse of split_parts. join(split(a)) == a  (spec section 56)."""
    if len(parts) != N_PARTS or any(len(p) != PART_BYTES for p in parts):
        raise ValueError(f"expected {N_PARTS} parts of {PART_BYTES} bytes")
    return b"".join(parts)


# --------------------------------------------------------------------------- #
# Affix  (DECISION-D10: rpart then checksum)                                   #
# --------------------------------------------------------------------------- #

def build_affix(part: bytes) -> bytes:
    """
    part (9 B) -> bit-reverse -> append 8-bit XOR fold of the REVERSED bytes.
    Checksum input is post-bit-reversal, copying generate_fid/1 ordering.
    """
    if len(part) != PART_BYTES:
        raise ValueError("part must be 9 bytes")
    rpart = bit_reverse_per_byte(part)
    return rpart + bytes([xor8(rpart)])              # 10 bytes = 80 bits


def parse_affix(affix: bytes) -> bytes | None:
    """Validate the checksum and undo the bit reversal. None if the checksum fails."""
    if len(affix) != AFFIX_BYTES:
        return None
    rpart, cks = affix[:PART_BYTES], affix[PART_BYTES]
    if xor8(rpart) != cks:
        return None
    return bit_reverse_per_byte(rpart)               # involution -> original part


# --------------------------------------------------------------------------- #
# Prefix derivation                                                            #
# --------------------------------------------------------------------------- #

def current_epoch(now_seconds: float | int) -> int:
    """1-minute epoch number (DECISION-D4d)."""
    return int(now_seconds) // EPOCH_SECONDS


def derive_prefix(part_index: int, cursor: int, epoch: int) -> bytes:
    """
    trunc80_msb( sha256( label || epoch_be64 ) )

    label = "fswarm/v1/bootstrap_prefix/part_{N}_and_cursor_{R}" as UTF-8,
    N and R rendered as ASCII decimal (D4b, D4c).
    epoch is unsigned 64-bit big-endian (D4d), appended as raw bytes.
    The leading 10 bytes of the digest are kept (D4e).
    """
    label = PREFIX_LABEL.format(n=part_index, r=cursor).encode("utf-8")
    digest = HASH(label + struct.pack(">Q", epoch)).digest()
    return digest[:PREFIX_BYTES]


def derive_fixed_prefix(part_index: int) -> bytes:
    """Epoch-independent discovery prefix (DECISION-D5). No epoch, no cursor."""
    label = FIXED_PREFIX_LABEL.format(n=part_index).encode("utf-8")
    return HASH(label).digest()[:PREFIX_BYTES]


# --------------------------------------------------------------------------- #
# yid / id_paint                                                               #
# --------------------------------------------------------------------------- #

def build_yid(prefix: bytes, affix: bytes) -> bytes:
    if len(prefix) != PREFIX_BYTES or len(affix) != AFFIX_BYTES:
        raise ValueError("bad prefix/affix size")
    return prefix + affix                            # 20 bytes  INV-009


def split_yid(yid: bytes) -> tuple[bytes, bytes]:
    if len(yid) != YID_BYTES:
        raise ValueError("yid must be 20 bytes")
    return yid[:PREFIX_BYTES], yid[PREFIX_BYTES:]


def encode_yaddr(yaddr_ip: str, cursor: int, epoch: int,
                 port: int = YGG_PF_PORT) -> list[bytes]:
    """Full paint encode: yaddr -> [yid_0, yid_1]."""
    painter = painter_address(yaddr_ip, port)
    out = []
    for i, part in enumerate(split_parts(painter)):
        out.append(build_yid(derive_prefix(i, cursor, epoch), build_affix(part)))
    return out


def decode_yids(yids: list[bytes], cursor: int, epoch: int) -> tuple[str, int] | None:
    """
    Full scan decode: [yid_0, yid_1] -> (yaddr_ip, port), or None if any
    prefix/checksum/ordering check fails.
    """
    if len(yids) != N_PARTS:
        return None
    parts = []
    for i, yid in enumerate(yids):
        if len(yid) != YID_BYTES:
            return None
        prefix, affix = split_yid(yid)
        if prefix != derive_prefix(i, cursor, epoch):
            return None
        part = parse_affix(affix)
        if part is None:
            return None
        parts.append(part)
    return parse_painter_address(join_parts(parts))


def id_paint(prefix: bytes, rand: bytes | None = None) -> bytes:
    """Temporary active DHT identity while painting: prefix || random affix."""
    return prefix + (rand if rand is not None else os.urandom(AFFIX_BYTES))


# --------------------------------------------------------------------------- #
# Scan-side filtering (spec section 8)                                         #
# --------------------------------------------------------------------------- #

def matches_prefix(yid: bytes, part_index: int, cursor: int, epoch: int) -> bool:
    return len(yid) == YID_BYTES and yid[:PREFIX_BYTES] == derive_prefix(
        part_index, cursor, epoch)


def candidate_fragment(yid: bytes) -> bytes | None:
    """nodes reply -> valid affix -> candidate payload fragment. None if invalid."""
    if len(yid) != YID_BYTES:
        return None
    return parse_affix(yid[PREFIX_BYTES:])


# --------------------------------------------------------------------------- #
# Combinatorial reconstruction (spec section 9)                                #
# --------------------------------------------------------------------------- #

def reconstruct(fragments_by_part: dict[int, list[bytes]]) -> list[tuple[str, int]]:
    """
    fragments_by_part: {part_index: [9-byte part, ...]} already prefix- and
    checksum-filtered. Returns every distinct painter address that the cross
    product yields, restricted to well-formed Yggdrasil addresses.

    The Ygg-range check is what makes N=2 tractable: a random pairing of noise
    fragments almost never produces a 0x02-prefixed address.
    """
    out, seen = [], set()
    for a in fragments_by_part.get(0, []):
        for b in fragments_by_part.get(1, []):
            try:
                ip, port = parse_painter_address(join_parts([a, b]))
            except ValueError:
                continue
            if not is_ygg_addr(ip) or (ip, port) in seen:
                continue
            seen.add((ip, port))
            out.append((ip, port))
    return out
