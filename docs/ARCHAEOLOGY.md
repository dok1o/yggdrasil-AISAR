# Repository Archaeology Report

**Spec sections addressed:** §10, §38, §46, §47, §65
**Date:** 2026-09-26 (revised after `main` supplied the codebase)
**Commit examined:** `origin/main` @ `9935c87`

---

## 0. Verdict

The codebase now exists and has been mapped. Archaeology **succeeded** and resolved a
large share of the protocol unknowns — but with one structural finding that governs
everything else:

> **`b_pf_new/` is the *legacy* PF scheme, not the Yggdrasil SDP scheme.**
> The 80-bit-prefix / 80-bit-affix SDP mechanism in the specification **has never been
> implemented**. There is no `fswarm` string, no cursor, no epoch-rotating prefix, no
> painter-address encoding, and no `yid` anywhere in the repository.
> `Sender.paint/0` is a literal `:noop`.

`README.txt` states the intent directly:

> `pf disabled - old scheme, to be fully retired in favor of Yggdrasil network subnode`

So `ygg_pf/` is a **greenfield subsystem that replaces** `b_pf_new/`, not an adaptation of
it. What `b_pf_new/` provides is *evidenced house conventions* (bit reversal, checksum
folding, PF packet layout, the pingx/pong handshake) which are admissible evidence under
§0 and which resolve six of the twelve SPEC FREEZE items.

---

## 1. Repository shape

```
backend/lib/          Elixir application (15 subsystems, ~11k LOC)
backend/vendor/ygg_ex/  Vendored Yggdrasil implementation in Elixir
gui/                  PySide6 GUI (~2.5k LOC)
web scrape/           Ygg peer scraping: 1 shell + 2 Python scripts
tools/                iex scripts, Python utilities
data/                 Runtime state: settings.json, ygg/, logs/, caches/
```

| Subsystem | Files | LOC |
|---|---|---|
| `backend/lib/a_utm/` | 15 | 2014 |
| `backend/lib/rest/` | 8 | 1659 |
| `backend/lib/krpc/` | 16 | 1562 |
| `backend/lib/conns/` | 5 | 1309 |
| `backend/lib/protocols/` | 4 | 1305 |
| `backend/lib/a_folder/` | 6 | 659 |
| **`backend/lib/b_pf_new/`** | **8** | **559** |
| `backend/lib/static_sync/` | 9 | 497 |
| `backend/lib/ecto/` | 2 | 479 |
| `backend/lib/ets/` | 3 | 387 |

---

## 2. `b_pf_new/` module map (§47)

| Module / file | Purpose | Class | Reusable as-is? | Verdict |
|---|---|---|---|---|
| `pf_mask_sync.ex` · `PFMaskSync` | Legacy node-ID mask: `prefix(8) ∥ checksum(16) ∥ middle(128) ∥ affix(8)` | legacy-specific | ❌ layout differs from spec | **REWRITE** — but **REUSE both primitives** (§2.1) |
| `pf_bootstrap.ex` · `GenS.PFRoutingBootstrap` | Paint/scan scheduler driven by *frequent infohash pairs* | legacy-specific | ❌ wrong driver | **REWRITE** — reuse the GenServer tick pattern |
| `pf_node_processor.ex` · `GenS.PFNodesProcessor` | Filters `nodes` replies by mask, pings candidates, cooldown, stats | new-PF-specific | ⚠️ close | **ADAPT** — highest-value reuse |
| `pf_routing_table.ex` · `GenS.PFRoutingTable` | ETS `fnodes` / `fnodes_rev` / `pf_inbox`, bootstrap-complete gate | new-PF-specific | ⚠️ close | **ADAPT** — shape already matches §33 |
| `pf_out_sync.ex` · `PFOutSync` | Builds/sends 32-byte PF binary packets | protocol-specific | ⚠️ 20B vs 32B id | **ADAPT** (§4.2 conflict) |
| `pf_worker_task.ex` · `PFBinWorkerTask` | PF opcode dispatch table (query + reply opcodes) | protocol-specific | ✅ mostly | **REUSE + EXTEND** |
| `pf_log.ex` · `GenS.PFLog` | Pong logging, beacon log refresh | new-PF-specific | ❌ no failure taxonomy | **ADAPT** for §41–§45 |
| `pf_reply_subtask.ex` · `PFReplySubTask` | Reply sub-handlers — body is `:todo_ets_lookup` atoms | unimplemented scaffold | ❌ | **DO NOT USE** |

### 2.1 The two reusable primitives

Both are *evidenced* answers to spec unknowns, not guesses.

**Bit reversal** (`pf_mask_sync.ex:11-17,53-58`) — resolves §18:

```elixir
@in_byte_rev Map.new(0..255, fn byte ->
               <<b7::1, b6::1, b5::1, b4::1, b3::1, b2::1, b1::1, b0::1>> = <<byte>>
               {byte, <<b0::1, b1::1, ..., b7::1>> |> :binary.decode_unsigned()}
             end)

defp reverse_bits(binary) do
  binary |> :binary.bin_to_list() |> Enum.map(&Map.get(@in_byte_rev, &1)) |> :binary.list_to_bin()
end
```

→ **bits are reversed *within each byte*; byte order is preserved.** Of the three
candidates §18 lists, this is the second ("reverse bits inside individual bytes"). A
72-bit part is exactly 9 bytes, so the operation applies cleanly.

**Checksum** (`pf_mask_sync.ex:9,48-51`) — resolves §19:

```elixir
@fold_bitsize 16
defp xor_checksum(bits), do: band(fold(bits, 0), (1 <<< @checksum_bits) - 1)
defp fold(<<ch::size(@fold_bitsize), rest::bits>>, acc), do: fold(rest, bxor(acc, ch))
defp fold(<<>>, acc), do: acc
```

→ **XOR-fold over fixed-width words, masked to the low N bits.** No cryptographic hash is
involved anywhere in the mask. Truncation is by **low-bit mask**, i.e. LSB-keeping.

**Checksum input ordering** (`pf_mask_sync.ex:16-21`):

```elixir
def generate_fid(target) do
  reversed = reverse_bits(target)          # reverse FIRST
  {prefix, middle, affix} = extract(reversed)
  checksum = xor_checksum(middle)          # then checksum the reversed bits
  construct(prefix, checksum, middle, affix)
end
```

→ **checksum is computed on POST-bit-reversal data.**

---

## 3. The pingx / pong handshake — fully recovered (§31, §32, §51)

This is the single most valuable archaeology result. The handshake spans four files.

**Step 1 — `pingx` is NOT a binary packet.** It is a bencoded KRPC `ping` carrying a magic
key (`static_sync/wire_sync.ex:144-147`):

```elixir
@pf_magic "f"
@f_syn 0
def ping_x(nid, tid), do: encode_query(@pq, %{@node_id => nid, @pf_magic => @f_syn}, tid)
```

→ wire form: `ping` query with args `{"id": <20B nid>, "f": 0}`.

**Step 2 — responder answers twice** (`krpc/krpc_query_subtask.ex:67-76`):

```elixir
def handle_query({@pq, %{@pf_magic => @f_syn} = _data, tid}, fnodev4, shard_id) do
  PFOutSync.send_pong(fnodev4)                      # binary PF pong
  nid = WorkerIDSync.select_work_id_for_nodev4(fnodev4)
  reply_packet = WireSync.ping_reply(nid, tid)      # ordinary bencoded ping reply
  KRPCUtilsSync.send_packet(shard_id, fnodev4, reply_packet)
end
```

→ A **legacy** node replies with the bencoded ping reply only. A **PF** node *additionally*
emits the binary pong. **The binary pong is the discriminator.** This is exactly the §31
"no valid pong ⇒ discard candidate" rule, already implemented.

**Step 3 — pong packet layout** (`b_pf_new/pf_out_sync.ex`):

```
PF header, 32 bytes:
  [Marker+Ver: 0x66 0x01 | 2B] [TxID: 4B] [Reserved: 4B] [SenderNodeID: 20B] [Opcode: 2B]
```

`send_pong` uses `tx_id = <<0::32>>` (null) and `opcode = 0x4001`.

**Step 4 — inbound parse** (`a_folder/udp_shard.ex:34-37,127-131,214-226`):

```elixir
@pf_marker 0x66;  @pf_ver 0x01;  @pf_header_size 32;  @max_pf_pkt_size 1200

defp work_pf_pkt(<<_marker_and_ver::16, pf_txid::32, _reserved::32,
                   frid::160, opcode::16, msg::binary>>, ipv4, port) do
  Spawn.pf_worker_task(pf_txid, frid, opcode, msg, ipv4, port)
end
```

→ **`frid` sits at bit offset 80, width 160 bits.** Dispatch then reaches
`PFBinWorkerTask.handle_opc(:pong, ...)` → `GenS.PFLog.log_pong/1`.

**Opcodes** (`pf_worker_task.ex`): `ping: 0x0001`, `pong: 0x4001`, `find_fnodes: 0x0002`,
`fnodes: 0x4002`, `error: 0x5001`, `token: 0x5002`, `saddrs: 0x5003`, plugin range
`0x7FFF..0xFFFF`.

---

## 4. Two naming/size conflicts that need a human decision

### 4.1 `fid` means two different things

| Source | Meaning | Size |
|---|---|---|
| `PFMaskSync.generate_fid/1`, `Sender`, `pf_bootstrap.ex` | a **masked Mainline DHT node ID** | **160 bits / 20 B** |
| Specification §11, INV-017 | a **32-byte Ygg public key** | **256 bits / 32 B** |

These are unrelated quantities sharing a name. `ygg_pf` must not inherit the collision.
Recommend the spec's meaning for `fid` and renaming the legacy one (e.g. `mask_id`).

### 4.2 The PF prefix cannot currently carry a 32-byte fid

§32 requires the valid `pong` to carry `fid` **inside the PF prefix**. The implemented PF
prefix carries a **20-byte** `SenderNodeID` at a fixed offset. A 32-byte Ygg public key
does not fit.

Three options, none decidable from code:
1. widen `SenderNodeID` 20 B → 32 B (header becomes 44 B; **breaks the existing PF wire format**);
2. keep the 32-byte header and carry `fid` in the `msg` payload (**contradicts "in the PF prefix"**);
3. bump `@pf_ver` 0x01 → 0x02 and define a v2 header (clean, versioned).

**This is a genuine spec gap requiring a decision.** See `SPEC_DECISIONS_NEEDED.md` D-6.

---

## 5. Reusable infrastructure outside `b_pf_new/`

| Module | Purpose | Class | Verdict |
|---|---|---|---|
| `ets/try_ets.ex` · `TryETS` | Safe ETS wrapper; **`set_cooldown_ms/3`, `cooled_down_ms?/2`, `clean_expired/1`** | generic | **REUSE AS-IS** — cooldown is exactly §23 |
| `ets/ets_lookup.ex` · `ETSLookup` | `closest_nodes/2`, `random_nodes/1`, frequency tables | generic | **REUSE AS-IS** |
| `ets/circular_buffer.ex` | Ring buffer | generic | **REUSE AS-IS** |
| `krpc/sender.ex` · `Sender` | `many_find_node(to_query, :nid \| {:fid, fid})`; **`paint/0` and `scan/0` are `:noop` stubs** | generic | **REUSE + IMPLEMENT the stubs** |
| `krpc/krpc_out_sync.ex` | `find_node/4`, `ping_x/1` | generic | **REUSE AS-IS** |
| `static_sync/wire_sync.ex` | KRPC encode/decode incl. `ping_x/2` | generic | **REUSE AS-IS** |
| `krpc/unpack_sync.ex` | Compact `nodes`/`peers` decoding | generic | **REUSE AS-IS** |
| `krpc/bootstrap.ex`, `routing_table.ex` | Mainline DHT bootstrap (§2.2) | generic | **REUSE AS-IS** |
| `protocols/simple_bencode.ex` | Bencode | generic | **REUSE AS-IS** |
| `a_folder/udp_shard.ex` | UDP sharding + DHT/PF/uTP demux | generic | **ADAPT** only if header version changes |
| `a_folder/settings_manager.ex` | `enable_ygg` / `enable_pf` / `legacy_crawl` flags → `KeyStorageSync` | generic | **ADAPT** — add web-scrape setting |
| `rest/key_storage_sync.ex` | `use_ygg?`, `use_pf?`, `rt_ready?` | generic | **REUSE AS-IS** |

### 5.1 Vendored `ygg_ex` — `fid → yaddr` is solved

`backend/vendor/ygg_ex/lib/ygg/address.ex` ports `yggdrasil-go/src/address/address.go`
exactly: `addr_for_key(<<key::256>>) -> <<addr::128>>`.

**Verified empirically.** I re-implemented the derivation independently in Python and ran
it against the node's own recorded identity in `data/ygg/ygg_address.txt`:

```
key      3f82887fba34d33d1511dc23e0ba25d4e6383dd184a5a4b67d25cc74874759b4
derived  202:3eb:bc02:2e59:6617:5771:1ee0:fa2e
recorded 202:3eb:bc02:2e59:6617:5771:1ee0:fa2e      MATCH ✅
```

**Consequence:** `yaddr` is *derivable from* `fid` and need not be transported
independently. This materially affects what the 144-bit painter address should contain —
see `SPEC_DECISIONS_NEEDED.md` D-1.

`AddressFile` format is `<ipv6> <port> <pubkey-hex>`; the recorded port is `0` because
`data/ygg/ygg.json` has `"Listen": []`. **No fixed Ygg port exists yet** (§30 unresolved).

---

## 6. Web scrape — fully recovered (§38, §53)

| Property | Recovered value | Evidence |
|---|---|---|
| Source | `https://api.github.com/repos/yggdrasil-network/public-peers/contents/$REGION` | `ygg_peers_fetch.sh:17-19` |
| Region | `europe` (hardcoded) | `ygg_peers_fetch.sh:4` |
| Limit | `MAX=20` | `ygg_peers_fetch.sh:5` |
| Fetch | `jq -r '.[].download_url'` then `curl` each, concatenated to one `.md` | `ygg_peers_fetch.sh:24-29` |
| URI parse | `(?:tcp\|tls\|quic\|ws\|wss\|socks\|sockstls)://[^\s\`<>()\[\]]+` | `parse_ygg_peers.py:17-19` |
| Cleanup | `rstrip(".,);:'\"")` | `parse_ygg_peers.py:24` |
| Dedup | order-preserving `if uri not in uris` | `parse_ygg_peers.py:26-27` |
| Identity grouping | within 500 chars after the URI, match `\b2[0-9a-f]{2}:[0-9a-f:]{10,}\b` (case-insens.); fall back to host | `parse_ygg_peers.py:31-44` |
| Selection | `random.shuffle` node groups, take first URI of each, cap at limit | `parse_ygg_peers.py:47-70` |
| Output | one URI per line on stdout | `parse_ygg_peers.py:73-74` |
| Config write | regex-replace `Peers\s*:\s*\[[^\]]*\]` in `/etc/yggdrasil/yggdrasil.conf` | `update_ygg_config.py:27-37` |
| Refresh | manual only — no timer | absence of cron/timer |
| Error handling | `set -euo pipefail`; exit 1 on empty; `SystemExit` if Peers block absent | scripts |

**Note on the config target:** the scripts rewrite the *system* Yggdrasil config at
`/etc/yggdrasil/yggdrasil.conf` and `sudo systemctl restart yggdrasil`. The application's
own embedded node reads `data/ygg/ygg.json` (`"PeerListFile": "peer_list_09_22_europe.txt"`,
plus a `PublicPeers` block with `Enabled/Count/CacheFile/CacheTTLHours`). The Elixir port
(§39) should target the **embedded** node's config, not the system daemon — and §37's
"do not delete user configuration" applies.

**Classification: REWRITE in Elixir.** Semantics fully recovered; no reason to shell out.

---

## 7. GUI (§40)

| File | Role |
|---|---|
| `gui/gui_settings.py` | Reads/writes `data/settings.json`; that file *is* the GUI↔Elixir channel |
| `gui/gui_menu.py` | Edit/Settings menu — current checkboxes live here |
| `backend/lib/a_folder/settings_manager.ex` | Parses the same JSON, normalises, pushes into `KeyStorageSync` |

Current keys: `legacy_crawl`, `enable_pf`, `enable_ygg`, `hide_debug`,
`jsonl_append_tjf`, `window_geometry`, `window_maximized`.

Adding a **Web-scrape peers** control is therefore a small, well-bounded change:
a checkbox in `gui_menu.py` → new key in `settings.json` → a `ygg_flag`-style normaliser
in `settings_manager.ex`. The existing `enable_ygg` path is the template to copy, and it
already satisfies §40's "keep GUI logic separate from Elixir logic".

**Classification: ADAPT.**

---

## 8. Summary — §65 classification

| Component | Verdict |
|---|---|
| `TryETS`, `ETSLookup`, `CircularBuffer` | **REUSE** |
| `WireSync.ping_x`, `KRPCOutSync`, `UnpackSync`, `SimpleBencode` | **REUSE** |
| Mainline DHT bootstrap / routing table | **REUSE** |
| `Ygg.Address` + vendored `ygg_ex` | **REUSE** (verified) |
| `PFMaskSync` bit-reversal + XOR-fold primitives | **REUSE** (as evidence + code) |
| `PFBinWorkerTask` opcode table | **REUSE + EXTEND** |
| `GenS.PFNodesProcessor` | **ADAPT** |
| `GenS.PFRoutingTable` | **ADAPT** |
| `PFOutSync` | **ADAPT** (header conflict, §4.2) |
| `GenS.PFLog` | **ADAPT** (§41–§45 taxonomy) |
| `settings_manager.ex` + `gui_settings.py`/`gui_menu.py` | **ADAPT** |
| `web scrape/*` | **REWRITE in Elixir** |
| `PFMaskSync` 8/16/128/8 layout | **REWRITE** (spec is 80/80) |
| `GenS.PFRoutingBootstrap` | **REWRITE** (infohash-pair driver → epoch/cursor driver) |
| `PFReplySubTask` | **DO NOT USE** (`:todo_` scaffold) |
| SDP encoder, prefix derivation, cursor, painter address | **NEW — nothing exists** |

---

## 9. Residual block

Archaeology resolved 6 of 12 SPEC FREEZE items. The remainder are **not recoverable by
further archaeology** — the SDP scheme has simply never been written. They are design
decisions, enumerated with repo-grounded recommendations in
[`SPEC_DECISIONS_NEEDED.md`](SPEC_DECISIONS_NEEDED.md).

```
BLOCKED: SPEC GAP  (6 remaining, down from 12)
```
