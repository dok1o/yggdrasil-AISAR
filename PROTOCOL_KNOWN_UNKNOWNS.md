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

**Critical context (revised 2026-09-26):** the codebase was supplied on `main` and has
been mapped — see `docs/ARCHAEOLOGY.md`. Archaeology resolved **6 of 12** SPEC FREEZE
items from real code. The decisive structural finding:

> `b_pf_new/` is the **legacy** PF scheme. The 80/80 SDP mechanism in the specification
> **has never been implemented** — no `fswarm` string, no cursor, no epoch prefix, no
> painter address, no `yid`. `Sender.paint/0` is a literal `:noop`.

So the remaining `UNKNOWN` rows are **not recoverable by further archaeology**; they are
open design decisions, enumerated with recommendations in
`docs/SPEC_DECISIONS_NEEDED.md`.

Rows marked `VERIFIED (code)` cite file and line in this repository.

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

## 2. Encoding unknowns (§48)

| Property | Status | Value | Evidence |
|---|---|---|---|
| **Bit-reversal semantics** | ✅ **VERIFIED (code)** | **bits reversed within each byte; byte order preserved** | `b_pf_new/pf_mask_sync.ex:11-17,53-58` — `@in_byte_rev` lookup table + `reverse_bits/1` maps it over `bin_to_list` in order. Resolves §18 to its 2nd candidate. 72 bits = 9 whole bytes, applies cleanly. |
| **Checksum algorithm** | ✅ **VERIFIED (code)** | **XOR-fold over fixed-width words, masked to low N bits** | `pf_mask_sync.ex:48-51` — `xor_checksum/1` + `fold/2`. No cryptographic hash is used anywhere in the mask. |
| **Checksum input (pre/post reversal)** | ✅ **VERIFIED (code)** | **post-bit-reversal** | `pf_mask_sync.ex:16-21` — `generate_fid/1` reverses first, then checksums the reversed bits. |
| **Checksum truncation direction** | ✅ **VERIFIED (code)** | **LSB-keeping** (`band(x, (1 <<< bits) - 1)`) | `pf_mask_sync.ex:48` |
| Checksum fold width for an **8-bit** checksum | PARTIAL | legacy uses fold width = checksum width (16/16) | `pf_mask_sync.ex:9,23`. By analogy → 8-bit words. Proposed **D-9**. |
| Affix internal order | UNKNOWN | — | §14 implies checksum last; `PFMaskSync` puts it near the front. Proposed **D-10**. |
| 128-bit address representation | UNKNOWN | — | Depends on **D-1** (uaddr vs yaddr — §13/§14 contradict). |
| IPv4 representation inside 128 bits | UNKNOWN | — | §48. Proposed **D-2** (IPv4-mapped `::ffff:a.b.c.d`). |
| IPv6 representation | UNKNOWN | — | §48. |
| Port byte order | UNKNOWN | — | Repo uses big-endian `<<a,b,c,d,port::16>>` throughout (`udp_shard.ex`, `UnpackSync`) — weak precedent. Proposed **D-3**. |
| Address ∥ port concatenation order | UNKNOWN | — | §13 gives `128 + 16`, does not fix high bits. Proposed **D-3**. |
| 72-bit split order | UNKNOWN | — | §48. Proposed **D-3** (MSB-first). |

### 2.1 New finding — `yaddr` is derivable from `fid`

| Property | Status | Value | Evidence |
|---|---|---|---|
| `yaddr` derivation | ✅ **VERIFIED (code + empirical)** | `yaddr = Ygg.Address.addr_for_key(fid)` | `vendor/ygg_ex/lib/ygg/address.ex`; independently re-derived in Python and matched against `data/ygg/ygg_address.txt` — `3f82…59b4` → `202:3eb:bc02:2e59:6617:5771:1ee0:fa2e` ✅ |

**Consequence:** `yaddr` need not be transported by SDP. This is the main argument for
D-1 = `uaddr`.

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
| Cooldown duration | PARTIAL | legacy precedent **30 000 ms** | `b_pf_new/pf_node_processor.ex:41` `@fping_ttl_ms 30_000`, via `TryETS.set_cooldown_ms/3` + `cooled_down_ms?/2`. Spec value not given. See **D-8**. |
| Cooldown mechanism | ✅ VERIFIED (code) | ETS TTL set on send, checked before re-query, swept by `clean_expired/1` | `ets/try_ets.ex:93-105`, `pf_node_processor.ex:131-141` |
| Scan-cycle definition | UNKNOWN | — | §50. Needed to define "after each scan cycle" (§28). |
| Legacy-node cache representation | UNKNOWN | — | §50. |
| Density calculation | UNKNOWN | — | §26, §50. |
| Initial slowdown formula | UNKNOWN | — | §26, §50. Ratio is stated; the mapping ratio → delay is not. Fixed sleep is explicitly disallowed. |
| Traffic split across paint/scan/last/next cursor | UNKNOWN | — | §25. Total is 16 q/s; distribution "must be verified in code". |
| Candidate-endpoint generation filter | UNKNOWN | — | §2.2 "a simple filter" — unspecified. |

---

## 5. PF binary protocol (§51) — largely RESOLVED

| Property | Status | Value | Evidence |
|---|---|---|---|
| **`pingx` packet layout** | ✅ **VERIFIED (code)** | **bencoded KRPC `ping` query with magic key** — args `{"id": <20B>, "f": 0}`. *Not* a binary packet. | `static_sync/wire_sync.ex:144-147` (`@pf_magic "f"`, `@f_syn 0`) |
| **`pong` packet layout** | ✅ **VERIFIED (code)** | 32-byte binary header: `[0x66 0x01 \| 2B][TxID 4B][Reserved 4B][SenderNodeID 20B][Opcode 2B][payload]`; `send_pong` uses null TxID + opcode `0x4001` | `b_pf_new/pf_out_sync.ex:7-26` |
| **PF prefix format** | ✅ **VERIFIED (code)** | same 32-byte header; parsed as `<<mv::16, txid::32, reserved::32, frid::160, opcode::16, msg::binary>>` | `a_folder/udp_shard.ex:214-219` |
| **`fid` position within PF prefix** | ⚠️ **CONFLICT** | header carries a **160-bit** `frid` at bit offset 80; spec §11/INV-017 requires a **256-bit** fid | `udp_shard.ex:214-219` vs §11. **Does not fit.** See **D-6**. |
| **Responder behaviour** | ✅ **VERIFIED (code)** | PF node answers a `pingx` **twice**: binary pong *and* ordinary bencoded ping reply. Legacy node answers only the bencoded reply — **the binary pong is the discriminator** (§31). | `krpc/krpc_query_subtask.ex:67-76` |
| **Opcodes** | ✅ **VERIFIED (code)** | `ping 0x0001`, `pong 0x4001`, `find_fnodes 0x0002`, `fnodes 0x4002`, `error 0x5001`, `token 0x5002`, `saddrs 0x5003`; plugins `0x7FFF..0xFFFF` | `b_pf_new/pf_worker_task.ex` |
| **Packet size bounds** | ✅ **VERIFIED (code)** | `>= 32` and `<= 1200` bytes; else dropped | `udp_shard.ex:37-38,127-131` |
| **Malformed-response handling** | ✅ **VERIFIED (code)** | non-matching binary → `work_pf_pkt/3` fallback → `Metrics.increment(:dropped_packets)` | `udp_shard.ex:227-230` |
| PF timeouts | UNKNOWN | — | §51. No PF-level timeout exists; only the ping cooldown (§6). |
| Duplicate-reply handling | UNKNOWN | — | §51. TxID is null in `send_pong`, so replies cannot currently be correlated. |
| Replay behavior / anti-replay | UNKNOWN | — | §51. No nonce or anti-replay in the v1 header. |
| Ygg fixed port for `yaddr` | UNKNOWN | — | §30. **Not in the repo**: `data/ygg/ygg.json` has `"Listen": []`; `ygg_address.txt` records port `0`. See **D-7**. |

---

## 6. ETS unknowns (§52)

| Property | Status | Value | Evidence |
|---|---|---|---|
| Key/value shapes | VERIFIED | `{fid}` and `{fid, uaddr}` | §33 |
| **Existing tables matching §33** | ✅ VERIFIED (code) | `:fnodes` and `:fnodes_rev` (plus `:pf_inbox`) — already the two-structure shape §33 describes | `b_pf_new/pf_routing_table.ex:14-22` |
| **Table creation convention** | ✅ VERIFIED (code) | `TryETS.create_many_named(names, :set, :public, true, true)` — public sets, read+write concurrency | `pf_routing_table.ex:25`, `ets/try_ets.ex:8-24` |
| **Table ownership** | ✅ VERIFIED (code) | created by the owning GenServer in `init/1`; `:public` so any process may write | `pf_routing_table.ex`, `pf_node_processor.ex`, `pf_bootstrap.ex` |
| **Table types** | ✅ VERIFIED (code) | `:set` throughout | as above |
| **Concurrency assumptions** | ✅ VERIFIED (code) | read *and* write concurrency enabled; all access via `TryETS` safe wrappers that swallow `ArgumentError` | `ets/try_ets.ex` |
| **Restart behavior** | ✅ VERIFIED (code) | ETS dies with its owner; `TryETS` degrades to defaults rather than crashing callers | `ets/try_ets.ex:64-74` |
| Table names for `ygg_pf` | UNKNOWN | — | Local naming choice; convention now established. |
| Persistence behavior | UNKNOWN | — | §52. Interacts with §44. `data/caches/boot.jsonl` exists as a prior-run cache precedent. |

> Note: these are **local** design decisions, not wire-format. They do not threaten
> interoperability and can be settled by ordinary design review once an application
> skeleton exists — unlike §2, §3 and §5, which are hard interop blockers.

---

## 7. Web-scrape unknowns (§53)

| Property | Status | Value | Evidence |
|---|---|---|---|
| Source URL list | ✅ VERIFIED (code) | `https://api.github.com/repos/yggdrasil-network/public-peers/contents/$REGION`, `REGION=europe`, then each `.download_url` | `web scrape/ygg_peers_fetch.sh:4,17-29` |
| Source format | ✅ VERIFIED (code) | GitHub contents JSON → Markdown peer files, concatenated | `ygg_peers_fetch.sh:24-29` |
| Parsing rules | ✅ VERIFIED (code) | regex `(?:tcp\|tls\|quic\|ws\|wss\|socks\|sockstls)://[^\s\`<>()\[\]]+`, then `rstrip(".,);:'\"")` | `parse_ygg_peers.py:17-24` |
| Filter rules | ✅ VERIFIED (code) | group by Ygg IPv6 identity found within 500 chars after the URI (`\b2[0-9a-f]{2}:[0-9a-f:]{10,}\b`, case-insens.), else by host; one URI per node; cap `MAX=20` | `parse_ygg_peers.py:31-70`, `ygg_peers_fetch.sh:5` |
| Deduplication | ✅ VERIFIED (code) | order-preserving `if uri not in uris`, then per-identity grouping | `parse_ygg_peers.py:26-44` |
| Selection order | ✅ VERIFIED (code) | `random.shuffle` of node groups — deliberately varies per run | `parse_ygg_peers.py:47-48` |
| Output format | ✅ VERIFIED (code) | one peer URI per line on stdout; counts to stderr | `parse_ygg_peers.py:50-74` |
| Config integration | ✅ VERIFIED (code) | regex-replace `Peers\s*:\s*\[[^\]]*\]` in `/etc/yggdrasil/yggdrasil.conf`, then `systemctl restart yggdrasil` | `update_ygg_config.py:27-41`, `ygg_peers_fetch.sh:52-60` |
| Failure handling | ✅ VERIFIED (code) | `set -euo pipefail`; `exit 1` if no peers; `SystemExit("Peers block not found")` | scripts |
| Refresh / update frequency | UNKNOWN | manual invocation only — no cron/timer in repo | §38 |
| Peer-manager integration for `ygg_pf` | UNKNOWN | — | The scripts target the **system** daemon; the embedded node reads `data/ygg/ygg.json` (`PeerListFile`, `PublicPeers{Enabled,Count,CacheFile,CacheTTLHours}`). §37 forbids deleting user config. |
| Required pipeline stages | VERIFIED | fetch → parse → validate → deduplicate → classify source → store/expose | §39 |
| Implementation language | VERIFIED | Elixir; no permanent Python shell-out | §39 |
| GUI separation | VERIFIED | PySide GUI logic separate from Elixir scraping/bootstrap logic | §40 |

---

## 8. SPEC FREEZE gate (§70)

§70 lists 12 items that "must no longer be unknown" before implementation begins.

| # | Freeze-gate item | Status | Source |
|---|---|---|---|
| 1 | address representation | ❌ UNKNOWN | D-1/D-2 — §13 vs §14 contradict |
| 2 | bit reversal | ✅ **RESOLVED** | `pf_mask_sync.ex` — per-byte, order preserved |
| 3 | checksum algorithm | ✅ **RESOLVED** | `pf_mask_sync.ex` — XOR-fold, LSB mask |
| 4 | checksum input | ✅ **RESOLVED** | `pf_mask_sync.ex` — post-reversal |
| 5 | prefix hash algorithm | ❌ UNKNOWN | D-4 — no precedent in repo |
| 6 | N serialization | ❌ UNKNOWN | D-4 |
| 7 | R serialization | ❌ UNKNOWN | D-4 |
| 8 | epoch serialization | ❌ UNKNOWN | D-4 |
| 9 | 80-bit truncation | ❌ UNKNOWN | D-4 |
| 10 | pingx format | ✅ **RESOLVED** | `wire_sync.ex` — bencoded ping + `"f":0` |
| 11 | pong format | ✅ **RESOLVED** | `pf_out_sync.ex` / `udp_shard.ex` — 32-byte header, opcode `0x4001` |
| 12 | fid extraction | ⚠️ **CONFLICT** | D-6 — header has 20-byte frid, spec needs 32-byte fid |

**6 / 12 resolved, 1 conflict, 5 unknown. SPEC FREEZE STILL FAILS.**

Per §70: *"If one remains unresolved and affects binary compatibility, the implementer must
not invent it."*

```
BLOCKED: SPEC GAP  (5 unknown + 1 conflict, down from 12 unknown)
```

---

## 9. How to unblock

Archaeology is **exhausted** — the SDP scheme was never written, so no amount of further
code reading will produce items 1 and 5–9. What remains are decisions, not discoveries.

See **`docs/SPEC_DECISIONS_NEEDED.md`** for all ten, each with a repo-grounded
recommendation. Of those:

- **D-1, D-2, D-3, D-6, D-9, D-10** have defensible recommendations that can be approved
  as-is.
- **D-4 (prefix derivation) and D-5 (fixed prefix) have no evidentiary basis whatsoever.**
  These are the true blockers.

The cheapest complete unblock remains **protocol test vectors** (§0 admits these as
authoritative, and §54 already enumerates exactly which are needed). A handful of concrete
`(address, port, epoch, N, R) → yid` tuples would pin D-1 through D-5 and D-9/D-10
simultaneously, by search against known-good outputs.
