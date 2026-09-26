# PROTOCOL_KNOWN_UNKNOWNS.md

**Mandated by §71.** Living document. Every binary-affecting protocol property is tracked
here with an explicit status and the evidence backing it.

**Status legend**

| Status | Meaning |
|---|---|
| `VERIFIED` | Fixed by the authoritative English specification, or by a public standard. Safe to implement. |
| `PARTIAL` | Shape/size known, exact semantics undetermined. **Not** safe to implement. |
| `UNKNOWN` | No evidence. **Must not be guessed** (§72). |

**Evidence rules** (§0): the only admissible evidence is (a) the English specification,
(b) verified reference-implementation behavior, (c) accepted protocol test vectors,
(d) a later approved protocol document. Public standards (BEP5) are admissible where the
spec defers to Mainline DHT.

**Critical context:** per `docs/ARCHAEOLOGY.md`, `b_pf_new/` and all other referenced
source material are **absent from this repository**, and no public reference
implementation exists. Evidence source (b) is therefore currently unavailable, which is
why so many rows below are `UNKNOWN`.

---

## 1. Structural properties — VERIFIED

These are fixed by the specification text itself and do not depend on missing code.

| Property | Status | Value | Evidence |
|---|---|---|---|
| BEP42 required? | VERIFIED | No — not enforced | §2.1, INV-001 |
| Query primitive | VERIFIED | `find_node(identity, target)` | §3, INV-013 |
| Generic SDP payload parts | VERIFIED | `N >= 1` | §4 |
| Max affix payload capacity | VERIFIED | `<= 128 bits` | §4 |
| Generic SDP prefix size | VERIFIED | `>= 32 bits` | §5 |
| Ygg payload parts | VERIFIED | `N = 2` | §13 |
| Painter address hashed? | VERIFIED | No — preserved in plain form | §13, INV-002 |
| Painter address size | VERIFIED | 128-bit addr + 16-bit port = **144 bits** (18 bytes) | §13, INV-003 |
| Address part size | VERIFIED | **72 bits** (144 / 2) | §14, INV-004 |
| Each part bit-reversed? | VERIFIED | Yes (that it happens) | §14, §18, INV-005 |
| Checksum size | VERIFIED | **8 bits** | §14, INV-006 |
| Affix size | VERIFIED | 72 + 8 = **80 bits** | §14, INV-007 |
| Ygg bootstrap prefix size | VERIFIED | **80 bits** | §15, INV-008 |
| `yid` composition | VERIFIED | `prefix \|\| affix` | §16 |
| `yid` size | VERIFIED | 80 + 80 = **160 bits** = **20 bytes** | §16, INV-009 |
| `yid` size matches MLDHT node ID | VERIFIED | 20 bytes — consistent with BEP5 | §16; BEP5 |
| Prefix derivation inputs | VERIFIED | literal string, `N`, `R`, 1-minute epoch | §17 |
| `id_paint` composition | VERIFIED | `prefix \|\| random 80-bit affix` | §20 |
| `id_paint` ≠ `yid` | VERIFIED | `yid` carries payload; `id_paint` is the temporary DHT identity | §20 |
| `id_scan` | VERIFIED | random node ID | §7 |
| Cursor initial value | VERIFIED | `R = 0` | §21, INV-010 |
| Cursor escalation threshold | VERIFIED | **more than 8** yids → escalation begins at **9** | §21, §58, INV-011 |
| Cursor escalation step | VERIFIED | `R = R + 1` | §21 |
| Epoch duration | VERIFIED | **1 minute** | §17, §22 |
| Cursor lifetime | VERIFIED | epoch-local; resets to 0 each new epoch | §22, INV-012 |
| Paint rate, per cursor | VERIFIED | 4 queries / second | §23, §61 |
| Scan rate, per cursor | VERIFIED | 4 queries / second | §23, §61 |
| Fixed-prefix paint rate | VERIFIED | 1 query / second | §27, §61 |
| Fixed-prefix scan rate | VERIFIED | 1 query / second | §27, §61 |
| Total expected traffic | VERIFIED | 16 queries / second | §25 |
| Cursors kept active | VERIFIED | last cursor + next cursor | §25 |
| Painting lags scanning | VERIFIED | Yes — scan establishes cursor before paint | §24 |
| Initial scan slowdown | VERIFIED | proportional to cached-fnode / cached-legacy-node density | §26 |
| `fid` definition | VERIFIED | 32-byte Ygg public key (256 bits) | §11, INV-017 |
| `fid` role | VERIFIED | singular routing identity | §11 |
| Candidate content | VERIFIED | `uaddr + yaddr` | §28 |
| `uaddr` form | VERIFIED | `ipv4:port` or `ipv6:port` (underlay transport) | §29 |
| `yaddr` form | VERIFIED | `ipv6:port` in Yggdrasil range, fixed port | §30 |
| Candidate validation method | VERIFIED | `pingx` → `pong` over PF binary protocol | §31, INV-015 |
| No valid pong ⇒ | VERIFIED | discard candidate | §31 |
| `fid` location | VERIFIED | inside the PF prefix of a valid `pong` | §32, INV-016 |
| SDP alone establishes trust? | VERIFIED | **No** | §32, INV-014 |
| ETS structure shapes | VERIFIED | `{fid}` and `{fid, uaddr}` | §33 |
| yaddr validation rule | VERIFIED | uaddr response ⇒ save `fid` **only if** yaddr also responds | §34, INV-018 |
| Trust distinction | VERIFIED | "reachable by uaddr" ≠ "validated through yaddr" | §35, INV-018 |
| Web-scraped peer priority | VERIFIED | low priority | §36, INV-019 |
| Scan relay vs web peer | VERIFIED | validated scan-discovered relay outranks web-scraped peer | §37, INV-020 |
| Routing priority vs config persistence | VERIFIED | separate concerns; replacement must not delete user config | §37 |
| Scan filter order | VERIFIED | nodes → valid prefix → valid affix → candidate fragments | §8 |
| Reconstruction order | VERIFIED | prefix groups → affix groups → part matching → combinations → checksum → payload | §9 |
| MLDHT bootstrap duration | VERIFIED | ~1–2 minutes, several thousand packets (normal) | §2.2 |

### 1.1 Failure-logging conditions — VERIFIED

Must remain distinguishable; must not collapse to a generic "bootstrap failed" (§41).

| Condition | Status | Trigger | Evidence |
|---|---|---|---|
| Wall-clock desync | VERIFIED | epoch scheme fails **AND** fallback succeeds | §42 |
| Too few reachable yaddrs | VERIFIED | reachable yaddrs `< 4` (degraded, not total failure) | §43 |
| No new candidates, cache exists | VERIFIED | no new candidates **AND** prior-run fnode cache exists | §44 |
| No candidates, no DHT boot | VERIFIED | `20+ s` elapsed **AND** no candidates **AND** no DHT bootstrap; must not block forever | §45 |

---

## 2. Encoding unknowns (§48) — BLOCKING

| Property | Status | Value | Evidence |
|---|---|---|---|
| 128-bit address representation | UNKNOWN | — | §48. No reference code. |
| IPv4 representation inside 128 bits | UNKNOWN | — | §48. Candidates incl. IPv4-mapped `::ffff:a.b.c.d`, left-pad, right-pad — **not equivalent**. |
| IPv6 representation | UNKNOWN | — | §48. |
| Port byte order | UNKNOWN | — | §48. §72 forbids assuming network byte order. |
| Address ∥ port concatenation order | UNKNOWN | — | §13 gives `128 + 16` but does not fix which occupies the high bits. |
| 72-bit split order | UNKNOWN | — | §48. Which of part A / part B is the high 72 bits is undetermined. |
| Bit-reversal semantics | **PARTIAL** | 72-bit part is reversed; *how* is undetermined | §18 lists 3 non-equivalent candidates: full 72-bit sequence reversal, per-byte bit reversal, byte-order reversal. |
| Checksum algorithm | UNKNOWN | — | §19, §48. §72 explicitly forbids defaulting to SHA-256 etc. |
| Checksum input | UNKNOWN | — | §19. Pre- or post-bit-reversal undetermined. |
| Checksum truncation direction | UNKNOWN | — | §19, §48. MSB vs LSB — §72 forbids assuming. |
| Checksum byte order | UNKNOWN | — | §19. |
| Affix internal order | UNKNOWN | — | §14 gives `72 + 8` but does not fix whether checksum is suffix or prefix within the affix. |

---

## 3. Prefix unknowns (§49) — BLOCKING

| Property | Status | Value | Evidence |
|---|---|---|---|
| Prefix hash algorithm | UNKNOWN | — | §17, §49. |
| Exact literal prefix bytes | UNKNOWN | — | §17, §49. Whether `"fswarm/v1/bootstrap_prefix/part_N_and_cursor_R"` is a literal template or has `N`/`R` substituted in is undetermined. |
| `N` encoding | UNKNOWN | — | §49. ASCII vs binary integer — §72 forbids assuming. |
| `R` encoding | UNKNOWN | — | §49. |
| Epoch representation | UNKNOWN | — | §49. |
| Epoch time basis | UNKNOWN | — | §49. Unix-epoch minutes vs other origin. |
| Concatenation operator `\|\|` semantics | UNKNOWN | — | §17. Raw byte concat vs delimited. |
| 80-bit truncation direction | UNKNOWN | — | §17, §49. Leading vs trailing 80 bits. |
| Fixed-prefix derivation | UNKNOWN | — | §27, §49. Must be recovered from reference code. |

---

## 4. Mainline DHT / SDP unknowns (§50)

| Property | Status | Value | Evidence |
|---|---|---|---|
| `find_node` wire semantics | VERIFIED | BEP5: `{"id": <20B>, "target": <20B>}` → `nodes` as 26-byte compact entries | BEP5 (public standard; §3 defers to MLDHT) |
| Node ID size / distance metric | VERIFIED | 160-bit IDs, XOR distance | BEP5 |
| Paint identity/target construction | UNKNOWN | — | §50. Which of `id_paint` / `yid` occupies `id` vs `target` is undetermined. |
| Scan identity/target construction | UNKNOWN | — | §50. §7 says identity is random; the target derivation is not fixed. |
| Prefix matching rule | UNKNOWN | — | §50. Exact-match vs "closest prefix" tolerance (§6, §7 both say "same / closest"). |
| Affix matching rule | UNKNOWN | — | §50. |
| Distance calculations | UNKNOWN | — | §50. Whether prefix/affix distance is plain XOR over the whole ID or segmented. |
| Cooldown duration | UNKNOWN | — | §23, §50. "small cooldown" — value not given. |
| Scan-cycle definition | UNKNOWN | — | §50. Needed to define "after each scan cycle" (§28). |
| Legacy-node cache representation | UNKNOWN | — | §50. |
| Density calculation | UNKNOWN | — | §26, §50. |
| Initial slowdown formula | UNKNOWN | — | §26, §50. Ratio is stated; the mapping ratio → delay is not. Fixed sleep is explicitly disallowed. |
| Traffic split across paint/scan/last/next cursor | UNKNOWN | — | §25. Total is 16 q/s; distribution "must be verified in code". |
| Candidate-endpoint generation filter | UNKNOWN | — | §2.2 "a simple filter" — unspecified. |

---

## 5. PF binary protocol unknowns (§51) — BLOCKING

| Property | Status | Value | Evidence |
|---|---|---|---|
| `pingx` packet layout | UNKNOWN | — | §51. |
| `pong` packet layout | UNKNOWN | — | §51. |
| PF prefix format | UNKNOWN | — | §51. |
| `fid` position within PF prefix | UNKNOWN | — | §51. Only "inside the PF prefix" (§32) is known. |
| PF timeouts | UNKNOWN | — | §51. |
| Malformed-response handling | UNKNOWN | — | §51. |
| Duplicate-reply handling | UNKNOWN | — | §51. |
| Replay behavior / anti-replay | UNKNOWN | — | §51. |
| Ygg fixed port for `yaddr` | UNKNOWN | — | §30. "recovered from existing code/configuration". |

---

## 6. ETS unknowns (§52)

| Property | Status | Value | Evidence |
|---|---|---|---|
| Key/value shapes | VERIFIED | `{fid}` and `{fid, uaddr}` | §33 |
| Table names | UNKNOWN | — | §33, §52. "follow existing repository conventions" — none exist. |
| Table ownership | UNKNOWN | — | §52. |
| Table lifetime | UNKNOWN | — | §52. |
| Table types (`set`/`bag`/`ordered_set`) | UNKNOWN | — | §52. |
| Concurrency assumptions | UNKNOWN | — | §52. |
| Restart behavior | UNKNOWN | — | §52. |
| Persistence behavior | UNKNOWN | — | §52. Interacts with §44 ("fnode cache from prior run"). |

> Note: these are **local** design decisions, not wire-format. They do not threaten
> interoperability and can be settled by ordinary design review once an application
> skeleton exists — unlike §2, §3 and §5, which are hard interop blockers.

---

## 7. Web-scrape unknowns (§53)

| Property | Status | Value | Evidence |
|---|---|---|---|
| Source URL list | UNKNOWN | — | §38, §53. Scripts absent. |
| Source format | UNKNOWN | — | §53. |
| Parsing rules | UNKNOWN | — | §38. |
| Filter rules | UNKNOWN | — | §53. |
| Validation | UNKNOWN | — | §53. |
| Deduplication | UNKNOWN | — | §53. |
| Refresh / update frequency | UNKNOWN | — | §38, §53. |
| Failure handling | UNKNOWN | — | §53. |
| Output format | UNKNOWN | — | §38. |
| Peer-manager integration | UNKNOWN | — | §53. |
| Required pipeline stages | VERIFIED | fetch → parse → validate → deduplicate → classify source → store/expose | §39 |
| Implementation language | VERIFIED | Elixir; no permanent Python shell-out | §39 |
| GUI separation | VERIFIED | PySide GUI logic separate from Elixir scraping/bootstrap logic | §40 |

---

## 8. SPEC FREEZE gate (§70)

§70 lists 12 items that "must no longer be unknown" before implementation begins.

| # | Freeze-gate item | Status |
|---|---|---|
| 1 | address representation | ❌ UNKNOWN |
| 2 | bit reversal | ❌ PARTIAL |
| 3 | checksum algorithm | ❌ UNKNOWN |
| 4 | checksum input | ❌ UNKNOWN |
| 5 | prefix hash algorithm | ❌ UNKNOWN |
| 6 | N serialization | ❌ UNKNOWN |
| 7 | R serialization | ❌ UNKNOWN |
| 8 | epoch serialization | ❌ UNKNOWN |
| 9 | 80-bit truncation | ❌ UNKNOWN |
| 10 | pingx format | ❌ UNKNOWN |
| 11 | pong format | ❌ UNKNOWN |
| 12 | fid extraction | ❌ UNKNOWN |

**0 / 12 resolved. SPEC FREEZE FAILS.**

Per §70: *"If one remains unresolved and affects binary compatibility, the implementer must
not invent it."* All twelve remain unresolved and all twelve affect binary compatibility.

```
BLOCKED: SPEC GAP
```

---

## 9. How to unblock

Any one of the following would resolve most or all of §2, §3 and §5:

1. **Provide `b_pf_new/`** — the specification assumes it is in-tree (§10). This is the
   primary intended evidence source and would likely close the majority of rows.
2. **Provide the reference implementation** in any language (§0 admits "verified
   reference implementation behavior").
3. **Provide protocol test vectors** (§0 admits "accepted protocol test vectors"). §54
   already enumerates exactly the vectors needed; a populated set of them would let the
   encoder be derived and validated without seeing the reference source at all.
4. **Provide a later approved protocol document** (§0) pinning the §48/§49/§51 details.
5. **Packet capture** of a conforming node painting/scanning, plus the painter address it
   was encoding — sufficient to reverse the encoding empirically.

Option 3 is the cheapest high-value unblock: a handful of concrete
`(address, port, epoch, N, R) → yid` tuples uniquely determines split order, bit-reversal
semantics, checksum, prefix hash and truncation direction in combination.
