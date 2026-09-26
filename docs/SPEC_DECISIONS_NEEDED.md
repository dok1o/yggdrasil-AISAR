# Decisions Needed Before Implementation

**Status:** 6 of 12 SPEC FREEZE items resolved by archaeology. **6 remain.**

These are **not** recoverable by further archaeology. The SDP scheme described in the
specification has never been implemented — there is no `fswarm` string, no cursor, no
epoch-rotating prefix and no painter-address encoding anywhere in the repository, and
`Sender.paint/0` is a literal `:noop`. They are open design decisions.

Each entry gives a **repo-grounded recommendation**. Per §72 these are *proposals only* —
nothing below has been implemented. Reply with approvals or corrections and I will freeze
the spec and implement.

Legend — **Interop**: ❗ = wrong choice makes us unable to talk to any conforming node.

---

## D-1 ❗ What does the 144-bit painter address contain?

**The specification contradicts itself.**

- §13 "Painter Address Encoding": `128-bit address + 16-bit port`, *"preserve the address
  in plain form… make full reconstruction possible"*.
- §48 asks for *"IPv4 representation inside 128 bits"* — only meaningful for an **underlay**
  address, since a Yggdrasil address is always IPv6.
- §14 "Address Parts" says each part is a *"72-bit bit-reversed **yaddr** fragment"*.

§14 says `yaddr`; §48 implies `uaddr`. Both cannot hold.

**Evidence that resolves it:** `Ygg.Address.addr_for_key/1` derives `yaddr` from `fid`
deterministically — I verified this reproduces the node's recorded address exactly
(`ARCHAEOLOGY.md` §5.1). So `yaddr` **never needs transporting**; it falls out of `fid`.

Meanwhile `pingx` travels over the **underlay** UDP socket
(`KRPCOutSync.ping_x/1` → `udp_shard`), so a scanner physically cannot contact a candidate
without its `uaddr`.

**Recommendation — painter address = `uaddr`**, giving this coherent chain:

```
paint: encode uaddr (128-bit addr + 16-bit port)
scan:  reconstruct uaddr  →  pingx over uaddr  →  valid binary pong  →  extract fid
       →  yaddr = Ygg.Address.addr_for_key(fid)  →  validate over yaddr  (§34)
       →  candidate = {uaddr, yaddr}  (§28)
```

This satisfies §28, §31, §32 and §34 simultaneously, and explains §48's IPv4 question.
It implies **§14's use of "yaddr" is an error for "uaddr"**.

> **Decide:** painter address = `uaddr` (recommended) / `yaddr` / something else.

---

## D-2 ❗ IPv4 representation inside the 128 bits

Only applies if D-1 = `uaddr`. §29 allows `ipv4:port` or `ipv6:port`.

| Option | Form |
|---|---|
| **A** (recommended) | IPv4-mapped IPv6 — `::ffff:a.b.c.d`, i.e. `<<0::80, 0xFFFF::16, a,b,c,d>>` |
| B | Zero-extend high — `<<0::96, a,b,c,d>>` |
| C | Left-align — `<<a,b,c,d, 0::96>>` |

**A** is the only self-describing option: it is unambiguously distinguishable from a real
IPv6 address, so a decoder can tell v4 from v6 with no side-channel. B and C both collide
with legitimate IPv6 addresses. The repo already works with 6-byte `nodev4`
(`<<a,b,c,d,port::16>>`) but has no 128-bit underlay encoding to copy.

> **Decide:** A (recommended) / B / C.

---

## D-3 ❗ 72-bit split order

`144 = 72 + 72`. Which half is part 0?

**Recommendation:** part 0 = the **most-significant** 72 bits of
`<<addr::128, port::16>>`, part 1 = the least-significant 72. Big-endian throughout,
matching BEP5 compact-node encoding and the repo's `<<a,b,c,d,port::16>>` convention.

> **Decide:** confirm, or specify otherwise.

---

## D-4 ❗ Prefix derivation — the largest remaining gap

§17 gives only a shape:

```
trunc_80bit( hash( "fswarm/v1/bootstrap_prefix/part_N_and_cursor_R" || 1-minute epoch ) )
```

Five sub-decisions, **none** with repo precedent — `PFMaskSync` uses no hash at all, and
the string `fswarm` appears nowhere in the codebase:

| # | Unknown | Note |
|---|---|---|
| D-4a | Hash algorithm | Repo has SHA-1 (DHT IDs) and `:crypto`. §72 forbids defaulting to SHA-256. |
| D-4b | Is the literal a **template** (substitute `N`,`R`) or a **fixed string** with `N`,`R` appended separately? | Reads like a template, but `part_N_and_cursor_R` is also literally valid. |
| D-4c | `N` and `R` serialization | ASCII decimal vs fixed-width binary. |
| D-4d | Epoch representation | `div(unix_seconds, 60)`? width? endianness? ASCII? |
| D-4e | Truncation direction | Leading 80 bits vs trailing 80. |

`PFMaskSync` truncates its checksum by **low-bit mask** (`band(..., (1 <<< bits) - 1)`),
which is weak evidence for LSB-keeping — but that is a *fold*, not a *hash truncation*,
so I will not generalise it.

**No recommendation offered.** This needs your values. If you have them written down
anywhere, that single paragraph unblocks the whole encoder.

---

## D-5 ❗ Fixed-prefix derivation (§27)

§27 requires 1 paint/s + 1 scan/s on an **epoch-independent** fixed prefix, *"recovered
from existing/reference code"*. It is not in the repo.

Presumably the same construction as D-4 with the epoch term omitted — but whether the
literal string also changes (e.g. `.../fixed`) is undetermined.

> **Decide:** give the fixed prefix, or the rule that derives it.

---

## D-6 ❗ How does `fid` fit in the PF prefix?

§32 requires a valid `pong` to carry `fid` **inside the PF prefix**. The implemented PF
header carries a **20-byte** `SenderNodeID` at bit offset 80
(`udp_shard.ex:214-219`). A 32-byte Ygg public key does not fit.

| Option | Consequence |
|---|---|
| A | Widen `SenderNodeID` 20 B → 32 B; header 32 B → 44 B. **Breaks existing PF wire format.** |
| B | Keep 32-byte header, carry `fid` in `msg` payload. **Contradicts "in the PF prefix".** |
| **C** (recommended) | Bump `@pf_ver` `0x01` → `0x02` and define a v2 header with a 32-byte `fid`. Clean, versioned, and `udp_shard` already matches on `<<@pf_marker, @pf_ver, …>>` so v1 and v2 can coexist during migration. |

Since `b_pf_new` is being retired anyway (`README.txt`), C costs little.

> **Decide:** A / B / C (recommended).

---

## D-7 Fixed Yggdrasil port for `yaddr` (§30)

§30 says the `yaddr` port is fixed and should be *"recovered from existing
code/configuration"*. It is not there: `data/ygg/ygg.json` has `"Listen": []`, and
`data/ygg/ygg_address.txt` records port `0`.

> **Decide:** pick the port `ygg_pf` will listen on over Yggdrasil. Not interop-critical
> between *our* nodes only if both sides read it from config — but §30 says fixed, so it
> must be a constant every implementation agrees on.

---

## D-8 Cooldown duration (§23)

§23: *"Queried fnodes are placed on a small cooldown"* — value unspecified.

**Precedent:** `pf_node_processor.ex:41` — `@fping_ttl_ms 30_000`, applied via
`TryETS.set_cooldown_ms/3` + `cooled_down_ms?/2`. Those helpers are directly reusable.

**Recommendation:** reuse **30 000 ms**. Purely local; no interop impact.

> **Decide:** confirm 30 s, or give a value.

---

## D-9 Checksum fold width for the 8-bit checksum

`PFMaskSync` folds in **16-bit** words for its **16-bit** checksum — fold width equals
checksum width. The Ygg affix checksum is **8 bits**.

**Recommendation:** fold in **8-bit** words, `band(..., 0xFF)`, over the **post-bit-reversal**
72-bit part (matching `generate_fid/1`'s ordering). 72 bits = 9 whole bytes, so the fold
divides evenly with no padding question.

> **Decide:** confirm, or specify a different fold width / input.

---

## D-10 Affix internal order

§14 writes the affix as `72-bit fragment + 8-bit checksum`, implying checksum **last**.
But `PFMaskSync` puts its checksum **near the front** (`prefix ∥ checksum ∥ middle ∥ affix`),
so house style does not settle it.

**Recommendation:** follow §14's written order — `<<part::72, checksum::8>>`.

> **Decide:** confirm.

---

## Summary

| ID | Decision | Interop | Recommendation |
|---|---|---|---|
| D-1 | Painter address = uaddr or yaddr | ❗ | **uaddr** |
| D-2 | IPv4 inside 128 bits | ❗ | **IPv4-mapped `::ffff:a.b.c.d`** |
| D-3 | 72-bit split order | ❗ | **MSB-first, big-endian** |
| D-4 | Prefix hash / literal / N / R / epoch / truncation | ❗ | **none — needs your values** |
| D-5 | Fixed-prefix derivation | ❗ | **none — needs your values** |
| D-6 | fid in PF prefix | ❗ | **C: PF v2 header, 32-byte fid** |
| D-7 | Fixed Ygg port | ⚠️ | **none — pick one** |
| D-8 | Cooldown duration | — | **30 000 ms** (existing precedent) |
| D-9 | Checksum fold width | ❗ | **8-bit words, post-reversal** |
| D-10 | Affix internal order | ❗ | **`<<part::72, checksum::8>>`** |

**D-4 and D-5 are the true blockers.** D-1/2/3/6/9/10 have defensible recommendations I can
proceed on if you approve them. D-4 and D-5 have no evidentiary basis whatsoever, and
inventing them would produce a node that paints IDs no conforming peer can find —
precisely the failure §72 and §73 rule out.

**If you have the intended prefix construction written down, that one answer plus
approval of the recommendations above opens the gate completely.**
