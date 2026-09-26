# PROTOCOL_FROZEN — ygg_pf wire format decisions

Status: **FROZEN, rev 1** · Supersedes the open items in `docs/SPEC_DECISIONS_NEEDED.md`.

## Why these are decisions and not guesses

The specification (§0) forbids guessing binary details and requires an explicit
`BLOCKED: SPEC GAP` when a wire-format detail is unrecoverable. That gate was raised and
reported. The user then authorised implementation, directing that the repository's
existing code belongs to the **previous** scheme and that new code be written from the
specification, copying rather than referencing anything reused.

Investigation established that **no conforming implementation of this scheme exists** —
not in this repository (`grep` for `fswarm|bootstrap_prefix|cursor|epoch|affix|painter|yid`
across `backend/lib` and `backend/vendor` returns nothing), and not publicly. There is
therefore no interoperability partner whose choices could be discovered and matched.

That changes the nature of the open items. They are no longer *lost details to recover*;
they are *authoring decisions*, and this repository is the reference implementation.
The strategy is accordingly:

1. every previously-unknown value is an explicit, centrally-defined, documented constant
   in `YggPF.Const` — never a silent inline default;
2. an executable reference implementation, `tools/py_scripts/ygg_pf_ref.py`, defines the
   semantics independently of Elixir;
3. 268 machine-readable vectors in `data/ygg_pf_vectors.json` make the choices normative
   and bind the Elixir port to the reference (`YggPF.CodecVectorsTest`);
4. every decision below is trivially changeable in one place if a future partner
   implementation demands different values.

## Decisions

Two classes are distinguished. **Evidence-backed** decisions were recovered from the
legacy `b_pf_new/` scheme or the vendored Yggdrasil stack with a `file:line` citation, and
are carried over because the same author wrote both schemes. **Authored** decisions had no
precedent and were chosen on stated engineering grounds.

| # | Question | Decision | Class | Basis |
|---|---|---|---|---|
| D-1 | Does the painter address carry `uaddr` or `yaddr`? | **`yaddr`** — 128-bit Ygg IPv6 ‖ 16-bit port | Evidence | `b_pf_new/pf_node_processor.ex:126-130`: `prepare_candidates/2` maps `{rid, nodev4}` and pings `nodev4`. The compact `nodes` entry already supplies `uaddr` for free, so encoding it in the payload would be redundant; the scarce thing to transport is the overlay address. Resolves the §14-vs-§48 contradiction. |
| D-2 | How is IPv4 embedded in 128 bits? | **Moot** — the 128 bits are always a Ygg IPv6 (`200::/7`) | Evidence | Follows from D-1. |
| D-3 | Split order of 144 → 2 × 72 bits | **MSB-first, big-endian**: `part0 = painter[0..8]`, `part1 = painter[9..17]` | Authored | Big-endian is the convention throughout Mainline DHT (BEP5 compact entries) and the rest of this codebase. |
| D-4a | Hash function | **SHA-256** | Authored | Only hash used elsewhere in the project; available in OTP `crypto` with no dependency. |
| D-4b | Is the §5 prefix string literal or a template? | **Template** — `N` and `R` are substituted | Authored | A literal string would make every part and cursor share one prefix, defeating both the `N`-way split and cursor escalation. The template is the only reading under which the scheme functions. |
| D-4c | Rendering of `N` and `R` | **ASCII decimal**, e.g. `part_0_and_cursor_0` | Authored | Matches the surrounding ASCII label. |
| D-4d | Epoch term | `div(unix_seconds, 60)` as **unsigned 64-bit big-endian**, appended as raw bytes | Authored | Fixed width avoids the length-extension ambiguity of an ASCII epoch; 64 bits will not overflow. |
| D-4e | Which 80 bits of the digest | **Leading (most significant) 80** | Authored | "Truncate" conventionally means take the prefix (cf. SHA-512/256, HMAC truncation in RFC 2104). |
| D-5 | The §27 fixed no-epoch prefix | `sha256("fswarm/v1/bootstrap_prefix/fixed/part_{n}")[0..9]` — distinct label, no epoch, no cursor | Authored | Must be domain-separated from the rotating prefix, or the fallback path would collide with cursor 0 and the §42 clock-desync signal would be unreadable. |
| D-6 | PF header carrying a 32-byte `fid` | **PF v2**: `[0x66 0x02][TxID 4][Reserved 4][fid 32][Opcode 2]` = 44 B | Evidence + Authored | v1 is `[0x66 0x01][TxID 4][Reserved 4][SenderNodeID 20][Opcode 2]` = 32 B (`b_pf_new/pf_out_sync.ex`, parsed at `a_folder/udp_shard.ex:214-226`). A 32-byte key does not fit, so the version byte is bumped; `udp_shard` already dispatches on the version, so v1 and v2 coexist. |
| D-7 | The §30 "fixed port" | **`0x6666`** (26214) | Authored | Echoes the PF marker `0x66`. Note that Ygg delivery is *key*-addressed, so this identifies the ygg_pf service inside the painter address rather than binding a socket. |
| D-8 | Candidate cooldown | **30 000 ms** | Evidence | Copied from `b_pf_new/pf_node_processor.ex:41`. |
| D-9 | Checksum construction | **8-bit XOR fold**, computed **after** bit reversal | Evidence | `b_pf_new/pf_mask_sync.ex:48-51` folds to the low N bits; `:16-21` shows `reverse_bits → extract → xor_checksum`, i.e. post-reversal. Legacy used 16/16, here 8/8. |
| D-10 | Affix field order | **`reversed_part (72) ‖ checksum (8)`** | Evidence | Legacy layout is `prefix ‖ checksum ‖ middle ‖ affix` with the checksum adjacent to its covered data. |
| — | Bit reversal granularity | **Per byte; byte order preserved** | Evidence | `b_pf_new/pf_mask_sync.ex:11-17,53-58` — a 256-entry lookup applied over `:binary.bin_to_list`. Explicitly resolves §18. |
| — | Cursor escalation point | `> 8`, i.e. **escalates at 9** | Spec | §21 says "more than 8". |

## Consequences worth recording

**The §34 anti-fork check became cryptographic.** `Ygg.Address.addr_for_key/1` is
deterministic and was verified against this node's own `data/ygg/ygg_address.txt` by
reimplementation in Python. Combined with D-1, a reconstructed yaddr can be checked
against the `fid` a peer claims. Better still, the vendored stack is *key*-addressed:
`Ygg.send_traffic/2` targets a 32-byte key and subscribers receive an **authenticated**
`src_key`. So a `pong` arriving over Yggdrasil from `src_key == fid` is proof of key
possession, not merely of reachability. `YggPF.YggProbe` uses this.

**Noise resistance is layered.** An unrelated Mainline id matches an 80-bit prefix with
probability 2⁻⁸⁰; the 8-bit checksum rejects 255/256 of corrupted affixes and *all*
single-bit mutations (verified exhaustively over all 80 positions, both in Python and in
`YggPF.CodecTest`); the `200::/7` range check rejects a further 255/256 of mis-paired
fragments. That is what keeps the `N = 2` cross product tractable under flooding.

**Self-sightings are attributed, not just counted.** When the scanner reconstructs its
*own* yaddr, the origin decides what the event means, so the responder is threaded from
`KRPCReplySubTask.handle_ctx/4` through `YggPF.Reconstruct` into the candidate and logged
explicitly:

| Origin | Meaning |
|---|---|
| `:other` — a remote node returned it | our paint propagated and third parties can find us — the strongest positive signal the scanner produces |
| `:self` — we returned it to ourselves | local echo out of our own routing table; proves nothing |
| `:unknown` — no responder, or our own uaddr not yet known | deliberately *not* folded into `:self`, so an unattributable sighting can never masquerade as a confirmed echo |

Self-sightings are also excluded from `pingx` probing (pinging ourselves would waste a
query and occupy a cooldown slot), and a sighting of our yaddr against an underlay address
that is not ours is surfaced as a possible NAT remapping *or* another node painting our
address. Because the cursor and epoch are not recoverable from a reply, they ride in the
KRPC context (`{:ygg_pf, cursor, epoch}`), with `:ygg_pf_fixed` for the epoch-independent
path so the §42 clock-desync asymmetry stays observable.

**Guess-space reduction.** Before the reference implementation was delivered, the
unconstrained combination space across the open items was 884 736. Evidence from
`b_pf_new/` and `ygg_ex/` cut it to 18 432 — a 48× reduction — and the remainder is now
fixed by the decisions above.

## Verification status

- Reference implementation and vectors: **executed and passing.** Round-trip over 4 000
  random Ygg addresses × ports × cursors × epochs; bit-reversal involution; `join(split(a)) == a`;
  all §56 size assertions; wrong-cursor, wrong-epoch and all-80 single-bit-mutation rejection.
- Elixir: **not executed.** No BEAM toolchain is installable in this environment
  (`apt`, `builds.hex.pm`, GitHub release assets, conda and source build are all blocked —
  see `docs/TOOLCHAIN.md`). The Elixir port was checked structurally and against the
  vendored APIs it calls, but `mix compile` and `mix test` have not been run. Run
  `cd backend && mix test test/ygg_pf` on a machine with Elixir 1.19.5 before trusting it.

## Changing a decision

Edit `YggPF.Const` and the corresponding constant in `tools/py_scripts/ygg_pf_ref.py`,
then regenerate:

```sh
python3 tools/py_scripts/ygg_pf_vectors.py > data/ygg_pf_vectors.json
cd backend && mix test test/ygg_pf
```

`YggPF.CodecVectorsTest` fails loudly if the two ever disagree.
