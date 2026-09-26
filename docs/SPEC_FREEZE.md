# SPEC FREEZE — Gate Decision Record

**Spec sections addressed:** §69, §70, §72
**Date:** 2026-09-26 (revision 2 — after the codebase was supplied on `main`)
**Decision:** ❌ **FREEZE STILL REFUSED** — but 6 of 12 items are now resolved.

---

## 1. Decision

Archaeology against the real codebase resolved **6 of 12** freeze-gate items from
evidence, and exposed **1 conflict**. **5 remain unknown.**

Because all five affect binary compatibility, §70 still applies:

> "If one remains unresolved and affects binary compatibility, the implementer must not invent it."

```
BLOCKED: SPEC GAP  (5 unknown + 1 conflict, down from 12 unknown)
```

**What changed:** the gap is no longer an *archaeology* problem. The SDP scheme described
in the specification **has never been implemented** — there is no `fswarm` string, no
cursor, no epoch-rotating prefix, no painter address and no `yid` anywhere in the
repository, and `Sender.paint/0` is a literal `:noop`. Further code reading cannot
produce the missing values. They are **decisions**, and they need a human.

---

## 2. Gate checklist (§70)

| # | Item | Status | Basis |
|---|---|---|---|
| 1 | address representation | ❌ UNKNOWN | **§13 and §14 contradict** — see D-1 |
| 2 | bit reversal | ✅ **RESOLVED** | `pf_mask_sync.ex:11-17,53-58` — bits reversed **within each byte**, byte order preserved |
| 3 | checksum algorithm | ✅ **RESOLVED** | `pf_mask_sync.ex:48-51` — **XOR-fold** over fixed-width words, LSB mask |
| 4 | checksum input | ✅ **RESOLVED** | `pf_mask_sync.ex:16-21` — **post**-bit-reversal |
| 5 | prefix hash algorithm | ❌ UNKNOWN | no hash exists anywhere in the mask code |
| 6 | N serialization | ❌ UNKNOWN | — |
| 7 | R serialization | ❌ UNKNOWN | — |
| 8 | epoch serialization | ❌ UNKNOWN | — |
| 9 | 80-bit truncation | ❌ UNKNOWN | — |
| 10 | pingx format | ✅ **RESOLVED** | `wire_sync.ex:144-147` — bencoded KRPC `ping` with `"f": 0` |
| 11 | pong format | ✅ **RESOLVED** | `pf_out_sync.ex`, `udp_shard.ex:214-219` — 32-byte header, opcode `0x4001` |
| 12 | fid extraction | ⚠️ **CONFLICT** | header carries **20-byte** `frid`; spec §11 requires **32-byte** fid — see D-6 |

Full evidence: [`../PROTOCOL_KNOWN_UNKNOWNS.md`](../PROTOCOL_KNOWN_UNKNOWNS.md).
Decisions and recommendations: [`SPEC_DECISIONS_NEEDED.md`](SPEC_DECISIONS_NEEDED.md).

---

## 3. Evidence sources (§0)

| Source | Availability | Note |
|---|---|---|
| Explicit human instruction | ⏳ **the remaining path** | 10 decisions await approval. |
| Verified reference implementation behavior | ⚠️ **partially used** | `b_pf_new/` supplied the *legacy* scheme, which yielded items 2, 3, 4, 10, 11. It contains **no SDP scheme** to copy. |
| Accepted protocol test vectors | ❌ unavailable | Would resolve everything. §54 lists exactly which. |
| A later approved protocol document | ❌ unavailable | — |

---

## 4. Residual guess-space

Recomputing §4 of revision 1 with the resolved items removed:

| Degree of freedom | Options | Running |
|---|---|---|
| D-1 painter address = uaddr / yaddr | 2 | 2 |
| D-2 IPv4-in-128 representation | 3 | 6 |
| `addr ∥ port` order | 2 | 12 |
| port byte order | 2 | 24 |
| D-3 72-bit split order | 2 | 48 |
| D-10 affix internal order | 2 | 96 |
| D-4a prefix hash algorithm | 6 | 576 |
| D-4c `N` encoding | 2 | 1 152 |
| D-4c `R` encoding | 2 | 2 304 |
| D-4d epoch encoding / basis | 4 | 9 216 |
| D-4e truncation direction | 2 | **18 432** |

**≈ 1.8 × 10⁴ incompatible wire formats**, down from ≈ 8.85 × 10⁵ — a **48× reduction**.

Real progress, but still ~18 000 ways to be silently wrong. The failure mode is unchanged
and remains the reason not to guess: the node would bootstrap into Mainline DHT fine
(§2.2 — generic and already working), paint well-formed 20-byte IDs, scan, and match
nothing. Every §42–§45 failure condition would fire while the actual defect is, say, an
epoch encoded as ASCII rather than binary.

> §72: "A plausible implementation is not equivalent to an interoperable implementation."

If the recommendations in D-1/2/3/6/9/10 are approved, the residual space collapses to
**D-4 alone: 6 × 2 × 2 × 4 × 2 = 384**. Still too many to guess, but it shows how narrow
the true blocker is.

---

## 5. Pipeline state (§69)

```
                    ┌─ Mainline DHT / SDP Research ....... DONE — BEP5 + repo KRPC layer mapped
                    │
                    ├─ Ygg Encoding Research ............. PARTIAL — primitives recovered,
Task → Orchestrator ┤                                       SDP scheme does not exist
                    ├─ b_pf_new Archaeology .............. DONE — legacy scheme, fully mapped
                    │
                    └─ Web/PySide Archaeology ............ DONE — fully recovered
                              │
                              ▼
                       ██ SPEC FREEZE ██ ................. ❌ REFUSED (6/12)  ◄── we are here
                              │
                              ▼
                    Elixir Implementer .................... NOT STARTED (correctly gated)
```

---

## 6. What is frozen and ready to build

Substantially more than in revision 1:

**Now evidence-backed and safe to implement:**
- Bit reversal (per-byte), XOR-fold checksum, post-reversal ordering.
- `pingx` = bencoded `ping` + `"f": 0`; `pong` = 32-byte PF binary header, opcode `0x4001`;
  the binary pong as the PF-vs-legacy discriminator (§31).
- `yaddr = Ygg.Address.addr_for_key(fid)` — **empirically verified** against
  `data/ygg/ygg_address.txt`.
- ETS conventions: public `:set` tables via `TryETS.create_many_named/5`; cooldown via
  `set_cooldown_ms/3` + `cooled_down_ms?/2` + `clean_expired/1` (§23's mechanism, already built).
- The complete web-scrape pipeline (§38, §53) — sources, regexes, dedup, limits, output.
- The GUI settings channel (`data/settings.json` ↔ `settings_manager.ex`) for §40.

**Fixed by spec text alone** (unchanged from revision 1): all structural sizes and
INV-001…INV-020, cursor logic (§21/§22/§58), scheduler rates (§23/§25/§27), the
uaddr-vs-yaddr trust state machine (§31–§35), the §42–§45 failure taxonomy, and peer
priority (§36/§37).

**Still blocked:** the SDP encoder itself — painter address representation (D-1/D-2/D-3),
prefix derivation (D-4), fixed prefix (D-5).

---

## 7. Secondary blocker: toolchain

Unchanged — see [`TOOLCHAIN.md`](TOOLCHAIN.md). No Elixir/OTP in this environment and all
BEAM distribution channels are outside the sandbox egress allowlist.
`README.txt` pins the project to **Elixir 1.19.5 / Python 3.11**.

Note this is now a *hard* blocker for verification: the repo ships a real `mix` project
with dependencies, so implementation work could not be compiled or tested here even once
the protocol gate opens. `repo.hex.pm` is blocked too, so `mix deps.get` would also fail.

---

## 8. Recommended unblock

1. **Answer D-4** (prefix hash algorithm, literal bytes, `N`/`R`/epoch serialization,
   truncation direction) and **D-5** (fixed prefix). These are the true blockers.
2. **Approve or correct** the recommendations for D-1, D-2, D-3, D-6, D-9, D-10.
3. **Or supply test vectors** — §54's list, populated. This subsumes 1 and 2 entirely and
   is the most reliable route to actual interoperability.
4. **Allowlist `builds.hex.pm` + `repo.hex.pm`** so the implementation can be compiled and
   tested rather than written blind.
