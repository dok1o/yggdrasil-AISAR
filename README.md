# yggdrasil-AISAR

SDP / Yggdrasil bootstrap over Mainline DHT.

## Status: implementation gated — `BLOCKED: SPEC GAP` (6 of 12 resolved)

Archaeology against the codebase resolved **6 of 12** SPEC FREEZE items (§70) from real
evidence. **5 remain unknown and 1 is a conflict**, so the gate stays shut and the SDP
encoder has correctly not been implemented.

**Key finding:** `b_pf_new/` is the **legacy** PF scheme. The 80-bit-prefix / 80-bit-affix
SDP mechanism in the specification **has never been implemented** — no `fswarm` string, no
cursor, no epoch-rotating prefix, no painter address, no `yid`, and `Sender.paint/0` is a
literal `:noop`. The remaining gaps are therefore *decisions*, not discoveries.

| Document | Purpose |
|---|---|
| [`docs/SPEC_DECISIONS_NEEDED.md`](docs/SPEC_DECISIONS_NEEDED.md) | **Start here.** The 10 open decisions, each with a repo-grounded recommendation. |
| [`PROTOCOL_KNOWN_UNKNOWNS.md`](PROTOCOL_KNOWN_UNKNOWNS.md) | §71 register: every property as `VERIFIED` / `PARTIAL` / `UNKNOWN`, with file:line evidence. |
| [`docs/SPEC_FREEZE.md`](docs/SPEC_FREEZE.md) | §70 gate decision record. |
| [`docs/ARCHAEOLOGY.md`](docs/ARCHAEOLOGY.md) | §47/§65 module map and REUSE/ADAPT/REWRITE/DO-NOT-USE classification. |
| [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md) | Why Elixir/OTP cannot be installed in this sandbox. |

### Resolved by archaeology

- **Bit reversal** — bits reversed *within each byte*, byte order preserved (`pf_mask_sync.ex`).
- **Checksum** — XOR-fold over fixed-width words, LSB mask, computed *post*-reversal.
- **`pingx`** — a bencoded KRPC `ping` carrying `"f": 0`, not a binary packet (`wire_sync.ex`).
- **`pong`** — 32-byte PF binary header, opcode `0x4001`; its presence is the PF-vs-legacy
  discriminator (`pf_out_sync.ex`, `udp_shard.ex`).
- **`yaddr = Ygg.Address.addr_for_key(fid)`** — verified empirically against
  `data/ygg/ygg_address.txt`.
- **Web scrape** — sources, regexes, dedup, limits and output fully recovered.

### Still blocked

- **D-4** prefix derivation: hash algorithm, literal bytes, `N`/`R`/epoch serialization,
  80-bit truncation direction.
- **D-5** fixed-prefix derivation (§27).
- **D-1** painter address contents — §13 and §14 contradict (`uaddr` vs `yaddr`).
- **D-6** `fid` in the PF prefix — header carries a 20-byte `frid`, spec requires 32 bytes.

## Toolchain

No Elixir/OTP in this environment and it cannot be installed — all BEAM distribution
channels are outside the sandbox egress allowlist. See [`docs/TOOLCHAIN.md`](docs/TOOLCHAIN.md).
`scripts/install-toolchain.sh` provisions a pinned, user-space OTP + Elixir once
`builds.hex.pm` is reachable.
