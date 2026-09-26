# yggdrasil-AISAR

SDP / Yggdrasil bootstrap over Mainline DHT.

## Status: implementation gated — `BLOCKED: SPEC GAP`

The SPEC FREEZE gate (§70) has been evaluated and **refused**. Implementation of the
encoding, prefix and PF binary-protocol layers has correctly not started.

| Document | Purpose |
|---|---|
| [`PROTOCOL_KNOWN_UNKNOWNS.md`](PROTOCOL_KNOWN_UNKNOWNS.md) | §71 living record of every protocol property: `VERIFIED` / `PARTIAL` / `UNKNOWN`, with evidence. |
| [`docs/SPEC_FREEZE.md`](docs/SPEC_FREEZE.md) | §70 gate decision record. Why the gate is shut and what opens it. |
| [`docs/ARCHAEOLOGY.md`](docs/ARCHAEOLOGY.md) | §47/§65 archaeology report. Finding: `b_pf_new/` and all other referenced source material are absent. |

**Summary of the blocker:** the specification designates ~12 binary-format details as
things to be recovered from `b_pf_new/` or a reference implementation, and explicitly
forbids guessing them (§17, §18, §19, §72). `b_pf_new/` does not exist in this repository,
no public reference implementation exists, and no test vectors have been supplied.

See [`docs/SPEC_FREEZE.md` §8](docs/SPEC_FREEZE.md) for the ranked list of ways to unblock.
