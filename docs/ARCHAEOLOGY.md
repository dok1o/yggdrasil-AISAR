# Repository Archaeology Report

**Spec sections addressed:** §10 (Implementation Location), §38 (Existing Web-Scrape Implementation), §47 (Repository Archaeology Task), §65 (Repository Archaeology Agent)

**Date:** 2026-09-26
**Repository:** `dok1o/yggdrasil-AISAR`
**Branch:** `arena/01a0dd9a-yggdrasil-aisar` (from `main` @ `6bc4de5`)

---

## 0. Verdict

> **The repository is empty. None of the artifacts the specification instructs me to inspect exist.**

The specification's archaeology tasks (§10, §38, §47, §65) and — critically — its evidence
requirements for every binary wire-format detail (§17, §18, §19, §27, §30, §48–§53, §70)
all depend on source material that is **not present in this repository and not present
anywhere reachable**.

Per §72 (Anti-Hallucination Rule) and §66 (Elixir Implementer), this is reported as a
spec gap rather than filled in with plausible defaults.

---

## 1. Evidence

### 1.1 Complete repository contents

```
$ git ls-tree -r HEAD --name-only
README.md
```

```
$ cat README.md
# yggdrasil-AISAR
```

That is the entire tracked content: **one file, 18 bytes, one line**.

### 1.2 Repository history

```
$ git log --oneline
6bc4de5 Initial commit

$ git rev-list --all --count
1
```

A single commit. There is no prior history to recover code from.

### 1.3 All refs contain the same single file

```
$ for b in refs/heads/arena/..., refs/heads/main, refs/remotes/origin/HEAD, refs/remotes/origin/main
README.md
```

No branch, remote or otherwise, contains additional material.

### 1.4 No unreachable / dangling objects

```
$ git fsck --lost-found
(no output)

$ git stash list
(no output)
```

Nothing was committed and orphaned; nothing is stashed. There is no deleted code to resurrect.

### 1.5 No working-tree material

```
$ find . -path ./.git -prune -o -type d -print
.
```

No subdirectories at all — tracked or untracked.

---

## 2. Required-artifact checklist

Each row is an artifact the specification explicitly directs the implementer to inspect.

| # | Spec § | Artifact to inspect | Present? | Consequence |
|---|---|---|---|---|
| 1 | §10, §46, §47 | `b_pf_new/` | **ABSENT** | No modules to reuse/adapt/copy. Reuse-vs-rewrite analysis is vacuous. |
| 2 | §10 | `ygg_pf/` (target subsystem) | **ABSENT** | Would be greenfield, not an adaptation. |
| 3 | §38 | Ygg peer-scraping **shell scripts** | **ABSENT** | Source URLs, parsing, filtering, dedup, output format all unrecoverable. |
| 4 | §38 | Ygg peer-scraping **Python scripts** | **ABSENT** | Same as above. |
| 5 | §40 | **PySide GUI** | **ABSENT** | No Settings surface exists to add a "Web-scrape peers" control to. |
| 6 | §33, §52 | Existing **ETS** code / conventions | **ABSENT** | "Follow existing repository conventions" — there are none. |
| 7 | §31, §51 | **PF binary protocol** (`pingx`/`pong`) implementation | **ABSENT** | Packet layouts, PF prefix format, fid position unrecoverable. |
| 8 | §17, §49 | Prefix-derivation reference code | **ABSENT** | Hash algorithm, literal bytes, N/R/epoch encoding, truncation unrecoverable. |
| 9 | §18 | Bit-reversal reference code | **ABSENT** | Cannot distinguish the three candidate semantics. |
| 10 | §19, §48 | Checksum reference code | **ABSENT** | Algorithm, input, truncation, byte order unrecoverable. |
| 11 | §27, §49 | Fixed-prefix derivation | **ABSENT** | Unrecoverable. |
| 12 | §30 | Ygg fixed-port config | **ABSENT** | Unrecoverable. |
| 13 | — | Elixir app (`mix.exs`, `lib/`, `config/`) | **ABSENT** | No application structure to integrate with (§66). |

**Score: 0 of 13 required artifacts present.**

---

## 3. REUSE / ADAPT / REWRITE / DO NOT USE classification

§65 requires this classification for relevant components. It is reproduced here for
completeness, but every cell resolves identically because the input set is empty.

| Component | Purpose | Generic / specific | Classification |
|---|---|---|---|
| *(none found)* | — | — | **N/A — NOTHING EXISTS TO CLASSIFY** |

The `module/file · purpose · generic-or-protocol-specific · reusable-as-is? · adapt-required?
· copy-required? · shared-dependency?` map mandated by §47 **cannot be produced**. Its input,
`b_pf_new/`, does not exist.

---

## 4. External-evidence search

Because in-repo evidence is absent, I checked whether the unknowns could be resolved from a
public reference implementation — which §0 permits ("verified reference implementation
behavior").

| Search | Result |
|---|---|
| `"fswarm" bootstrap_prefix SDP self-describing payload mainline DHT node id` | No match. No project named `fswarm` implementing SDP was found. |
| `"b_pf_new" OR "ygg_pf" Yggdrasil Elixir mainline DHT paint scan prefix affix` | No match. Results were unrelated (Yggdrasil core docs, Path of Exile affixes). |
| `dok1o` repository listing (12 public repos) | None related: `Clipping-APP`, `Path2Uni`, `FocusStudy`, `ee-tracker-kz`, `auto-adder`, `Review-Booster`, `EasyRAM`, `TRIZ-VIP`, `INFproject`, `Whatsapp-ai-bot`, `DataUni-KZ`. |

**No public reference implementation of this protocol exists.** The literal string
`"fswarm/v1/bootstrap_prefix/part_N_and_cursor_R"` (§17) returns nothing, which strongly
indicates this is a private/unpublished protocol.

Generic Mainline DHT / KRPC / BEP5 facts *are* publicly documented and usable as evidence
(20-byte node IDs, XOR distance, `find_node` semantics, network byte order for the
compact `nodes` encoding). These corroborate the spec's structural claims (§16: 160-bit
node ID) but say nothing about SDP-specific encoding.

---

## 5. Toolchain state

| Tool | Status |
|---|---|
| `python3` | present (`/usr/bin/python3`) |
| `elixir` | **absent** |
| `mix` | **absent** |
| `erl` / OTP | **absent** |
| `apt-get install elixir` | fails — package not in index |
| `sudo` | unavailable (non-root, no passwordless sudo) |

Consequence: even the parts of §66 that are *not* blocked on protocol unknowns cannot
currently be compiled or tested in this environment. An Elixir/OTP toolchain would need to
be provisioned (e.g. a precompiled OTP + Elixir tarball unpacked into `$HOME`) before any
Elixir code could be verified rather than merely written.

---

## 6. What this means for the pipeline (§69)

```
                    ┌─ Mainline DHT / SDP Research ....... partially possible (public BEP5 only)
                    │
                    ├─ Ygg Encoding Research ............. BLOCKED (no evidence source)
Task → Orchestrator ┤
                    ├─ b_pf_new Archaeology .............. COMPLETE — target does not exist
                    │
                    └─ Web/PySide Archaeology ............ COMPLETE — target does not exist
                              │
                              ▼
                         SPEC FREEZE ....................... CANNOT FREEZE (see SPEC_FREEZE.md)
                              │
                              ▼
                    Elixir Implementer .................... MUST NOT START on encoding (§66, §70, §72)
```

Three of the four research stages have terminated. Two terminated with the finding that
their subject matter is absent; one (Ygg Encoding) terminated blocked. The SPEC FREEZE
gate therefore **fails**, and §70 is explicit about the consequence:

> "If one remains unresolved and affects binary compatibility, the implementer must not invent it."

12 of the 12 freeze-gate items are unresolved. See `../PROTOCOL_KNOWN_UNKNOWNS.md` and
`SPEC_FREEZE.md`.

---

## 7. Formal block

```
BLOCKED: SPEC GAP
```

**Exact unknowns** (§66 requires identifying them precisely) — enumerated in
`../PROTOCOL_KNOWN_UNKNOWNS.md`. Summary of the blocking set:

1. Prefix hash algorithm (§17, §49)
2. Exact literal prefix-string bytes and how `N`/`R` interpolate into it (§17, §49)
3. `N` serialization (§49)
4. `R` serialization (§49)
5. Epoch serialization and time basis (§49)
6. 80-bit truncation direction (§17, §49)
7. Bit-reversal semantics — 3 mutually incompatible candidates (§18)
8. Checksum algorithm (§19, §48)
9. Checksum input, pre- or post-bit-reversal (§19, §48)
10. Checksum truncation direction and byte order (§19, §48)
11. 128-bit address representation, incl. IPv4-in-128 and port byte order (§48)
12. 72-bit split order (§48)
13. `pingx` / `pong` packet layout, PF prefix format, fid position (§51)
14. Fixed-prefix derivation (§27, §49)
15. Ygg fixed port (§30)
16. Web-scrape source list (§38, §53)

Each of items 1–14 **affects binary compatibility** and therefore falls squarely under the
§72 prohibition. Guessing any one of them would produce a node that paints `yid`s no
conforming peer can decode — the exact failure mode §73 warns about:

> "The goal is protocol compatibility, not merely approximate functional similarity."
