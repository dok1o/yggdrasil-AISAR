# SPEC FREEZE — Gate Decision Record

**Spec sections addressed:** §69 (Recommended Agent Pipeline), §70 (SPEC FREEZE), §72 (Anti-Hallucination Rule)

**Date:** 2026-09-26
**Decision:** ❌ **FREEZE REFUSED**

---

## 1. Decision

The orchestrator gate defined in §70 **cannot be passed**. Implementation of the encoding
layer, the prefix layer and the PF binary protocol **must not begin**.

```
BLOCKED: SPEC GAP
```

§70 states the gate condition plainly:

> "If one remains unresolved and affects binary compatibility, the implementer must not invent it."

**0 of 12** freeze-gate items are resolved. **12 of 12** affect binary compatibility.

---

## 2. Gate checklist (§70, verbatim item list)

| # | Item | Required status | Actual | Interop-critical? |
|---|---|---|---|---|
| 1 | address representation | resolved | ❌ UNKNOWN | Yes |
| 2 | bit reversal | resolved | ❌ PARTIAL | Yes |
| 3 | checksum algorithm | resolved | ❌ UNKNOWN | Yes |
| 4 | checksum input | resolved | ❌ UNKNOWN | Yes |
| 5 | prefix hash algorithm | resolved | ❌ UNKNOWN | Yes |
| 6 | N serialization | resolved | ❌ UNKNOWN | Yes |
| 7 | R serialization | resolved | ❌ UNKNOWN | Yes |
| 8 | epoch serialization | resolved | ❌ UNKNOWN | Yes |
| 9 | 80-bit truncation | resolved | ❌ UNKNOWN | Yes |
| 10 | pingx format | resolved | ❌ UNKNOWN | Yes |
| 11 | pong format | resolved | ❌ UNKNOWN | Yes |
| 12 | fid extraction | resolved | ❌ UNKNOWN | Yes |

Detail and evidence for every row: [`../PROTOCOL_KNOWN_UNKNOWNS.md`](../PROTOCOL_KNOWN_UNKNOWNS.md).

---

## 3. Why the gate cannot be passed by research

§0 admits exactly four evidence sources. All four are currently unavailable:

| Evidence source (§0) | Availability | Note |
|---|---|---|
| Explicit human instruction | ⏳ **available on request** | The user can supply the missing values directly. |
| Verified reference implementation behavior | ❌ unavailable | `b_pf_new/` absent; no public implementation exists. See `ARCHAEOLOGY.md` §4. |
| Accepted protocol test vectors | ❌ unavailable | None provided. §54 specifies which are needed. |
| A later approved protocol document | ❌ unavailable | None provided. |

The English specification itself is authoritative but **deliberately silent** on these
twelve items — it does not merely omit them, it explicitly designates them as things to be
recovered elsewhere and explicitly forbids guessing:

- §17: *"Do not guess any of these."*
- §18: *"Only the behavior evidenced by existing/reference implementation should be used."*
- §19: *"Until resolved, these are protocol unknowns."*
- §72: *"Binary protocol implementation must never rely on 'reasonable defaults'."*

---

## 4. Why guessing is not a viable shortcut

§72 forbids defaulting, and the combinatorics show why the prohibition is not merely
stylistic. Counting only the *plausible* choices for each unresolved encoding degree of
freedom:

| Degree of freedom | Plausible options | Running product |
|---|---|---|
| IPv4-in-128 representation | 3 | 3 |
| `addr ∥ port` order | 2 | 6 |
| port byte order | 2 | 12 |
| 72-bit split order | 2 | 24 |
| bit-reversal semantics (§18 lists 3) | 3 | 72 |
| checksum algorithm | 8 | 576 |
| checksum input pre-/post-reversal | 2 | 1 152 |
| checksum truncation direction | 2 | 2 304 |
| affix internal order | 2 | 4 608 |
| prefix hash algorithm | 6 | 27 648 |
| `N` encoding | 2 | 55 296 |
| `R` encoding | 2 | 110 592 |
| epoch encoding / time basis | 4 | 442 368 |
| prefix 80-bit truncation direction | 2 | **884 736** |

**≈ 8.85 × 10⁵ mutually incompatible wire formats** — a conservative lower bound, before
`pingx`/`pong` layout (§51), the fixed-prefix derivation (§27) and the Ygg fixed port
(§30) are even considered.

A guessed implementation therefore has an expected interoperability probability on the
order of **1 in 900 000**. Worse, it would fail *silently and asymmetrically*: the node
would bootstrap into Mainline DHT successfully (§2.2 — that part is generic and works),
paint well-formed 20-byte IDs, scan, and find nothing but noise. Every failure mode in
§42–§45 would fire while the actual defect is a wrong truncation direction. This is
precisely the outcome §73 rules out:

> "The goal is protocol compatibility, not merely approximate functional similarity."

and §72:

> "A plausible implementation is not equivalent to an interoperable implementation."

---

## 5. Pipeline state (§69)

```
                    ┌─ Mainline DHT / SDP Research ....... PARTIAL — public BEP5 facts only;
                    │                                      SDP-specific semantics blocked
                    ├─ Ygg Encoding Research ............. BLOCKED — no admissible evidence source
Task → Orchestrator ┤
                    ├─ b_pf_new Archaeology .............. DONE — subject matter does not exist
                    │
                    └─ Web/PySide Archaeology ............ DONE — subject matter does not exist
                              │
                              ▼
                       ██ SPEC FREEZE ██ ................. ❌ REFUSED  ◄── we are here
                              │
                              ▼
                    Elixir Implementer .................... NOT STARTED (correctly gated)
                              │
                              ▼
                      PF Verifier ......................... not reached
                              │
                              ▼
                    Adversarial Reviewer .................. not reached
```

Two of the four research stages completed with a null finding; one is blocked; one is
partial. The gate correctly refuses.

---

## 6. What *is* frozen

Not everything is blocked. The following are fixed by the specification alone and are safe
to build against once the gate opens — or to build now in the non-interop layers:

- **All structural sizes and invariants** — INV-001 … INV-020, and §56's property set
  (`bit_size(prefix) == 80`, `bit_size(address_part) == 72`, `bit_size(checksum) == 8`,
  `bit_size(affix) == 80`, `byte_size(yid) == 20`).
- **Cursor logic** — `R = 0` initial, escalate when matching yids `> 8` (i.e. at 9),
  reset each 1-minute epoch (§21, §22, §58).
- **Scheduler rates** — 4 paint/s + 4 scan/s per cursor, 1 + 1 on the fixed prefix,
  16 q/s total, paint lags scan (§23, §24, §25, §27).
- **Trust state machine** — SDP candidate → `pingx` → valid `pong` → extract `fid` →
  validated fnode; uaddr-only never reaches full trust without yaddr validation
  (§31, §32, §34, §35).
- **Failure-log taxonomy** — the four distinguishable conditions of §42–§45.
- **Peer priority ordering** — validated scan-discovered relay > web-scraped peer;
  routing priority is separate from config persistence (§36, §37).

These are *logic*, not *wire format*. They can be specified, tested and reviewed without
resolving a single binary unknown — a candidate scope if partial progress is wanted while
the gate stays shut.

**However**, note the dependency: this logic layer cannot be *executed end-to-end* or
validated against a real network without the encoder. It is buildable as a tested pure
core, not as a working bootstrap.

---

## 7. Secondary blocker: toolchain

Independent of the protocol gap, this environment has **no Elixir/OTP toolchain**
(`elixir`, `mix`, `erl` all absent; no distro package; no root). Any Elixir written here
today could not be compiled or tested — it would be unverified code, which sits poorly
beside a specification this insistent on evidence. Provisioning a precompiled OTP +
Elixir into `$HOME` is the prerequisite for §66 work of any kind.

---

## 8. Recommended unblock

Ranked by cost-to-value. Any single one of 1–3 opens most of the gate.

1. **Supply `b_pf_new/`** (§10 assumes it is in-tree). Primary intended evidence source;
   likely closes §48, §49, §51 together.
2. **Supply protocol test vectors** — cheapest high-value option. §54 already enumerates
   exactly the seven vector families needed. A handful of concrete
   `(address, port, epoch, N, R) → yid` tuples collapses the 8.85 × 10⁵ space to 1:
   split order, bit-reversal semantics, checksum, prefix hash and both truncation
   directions are all jointly recoverable by search against known-good outputs.
3. **Supply the reference implementation** in any language.
4. **Supply a packet capture** of a conforming node painting, plus the address it encoded.
5. **Explicitly authorise** a non-interoperable v0 — permitted only by §0's "explicit human
   instruction" clause. This would mean accepting that the result will not talk to any
   existing fnode, and pinning our chosen values as the new normative reference.

Until one of these lands, the correct action is to hold the gate shut.
