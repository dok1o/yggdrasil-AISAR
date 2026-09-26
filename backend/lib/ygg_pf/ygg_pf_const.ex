defmodule YggPF.Const do
  @moduledoc """
  Frozen protocol constants for the Yggdrasil SDP bootstrap (`ygg_pf`).

  This module is the single source of truth for every value the specification left
  open. Nothing below is duplicated elsewhere in `ygg_pf/` - if a number needs to
  change, it changes here.

  The reference implementation is `tools/py_scripts/ygg_pf_ref.py` and the binding
  vectors are `data/ygg_pf_vectors.json`. Any change here must be mirrored there and
  the vectors regenerated, or `YggPF.CodecVectorsTest` will fail.

  ## Layout

      painter address = yaddr = 128-bit Ygg IPv6 || 16-bit port      = 144 bits
      part_i          = 72-bit slice of the painter address            (N = 2)
      rpart_i         = bit_reverse_per_byte(part_i)                 =  72 bits
      affix_i         = rpart_i || xor8(rpart_i)                     =  80 bits
      prefix_i        = trunc80_msb(sha256(label(i, R) || epoch_be64)) = 80 bits
      yid_i           = prefix_i || affix_i                          = 160 bits / 20 B
      id_paint_i      = prefix_i || random 80 bits                   = 160 bits / 20 B

  ## Where the values come from

  Carried over from the legacy scheme in `b_pf_new/` (copied, not referenced - the
  legacy modules stay untouched and will be retired):

    * bit reversal - `pf_mask_sync.ex:11-17,53-58`: bits are reversed *within each
      byte* and byte order is preserved.
    * checksum - `pf_mask_sync.ex:48-51`: XOR fold over fixed-width words, masked to
      the low N bits. Fold width equals checksum width (legacy 16/16, here 8/8).
    * checksum input - `pf_mask_sync.ex:16-21`: computed *after* bit reversal.
    * cooldown - `pf_node_processor.ex:41`: 30 s, via `TryETS.set_cooldown_ms/3`.

  Decisions taken here because no prior art existed anywhere in the repository (the
  SDP scheme had never been implemented). Each is recorded in
  `docs/PROTOCOL_FROZEN.md` with its rationale:

    * `D-1` painter address carries **yaddr**, not uaddr. `uaddr` arrives for free in
      the same compact `nodes` entry as the `yid`, so it does not need transporting.
    * `D-3` split order is MSB-first, big-endian.
    * `D-4a` hash is SHA-256.
    * `D-4b` the spec string is a *template*; `N` and `R` are substituted.
    * `D-4c` `N` and `R` render as ASCII decimal inside the label.
    * `D-4d` epoch = `div(unix_seconds, 60)`, unsigned 64-bit big-endian.
    * `D-4e` truncation keeps the leading (most significant) 80 bits.
    * `D-5` the fixed prefix uses a distinct label and omits epoch and cursor.
    * `D-6` PF v2 header carries a 32-byte `fid` (v1 carried a 20-byte `frid`).
    * `D-7` the fixed Yggdrasil port is `0x6666`.
    * `D-9` checksum fold width is 8 bits.
    * `D-10` affix is `reversed_part || checksum`.
  """

  # --- payload geometry ---------------------------------------------------- #

  @addr_bits 128
  @port_bits 16
  @painter_bits @addr_bits + @port_bits
  @n_parts 2
  @part_bits div(@painter_bits, @n_parts)
  @checksum_bits 8
  @affix_bits @part_bits + @checksum_bits
  @prefix_bits 80
  @yid_bits @prefix_bits + @affix_bits

  def addr_bits, do: @addr_bits
  def port_bits, do: @port_bits
  def painter_bits, do: @painter_bits
  def painter_bytes, do: div(@painter_bits, 8)
  def n_parts, do: @n_parts
  def part_bits, do: @part_bits
  def part_bytes, do: div(@part_bits, 8)
  def checksum_bits, do: @checksum_bits
  def affix_bits, do: @affix_bits
  def affix_bytes, do: div(@affix_bits, 8)
  def prefix_bits, do: @prefix_bits
  def prefix_bytes, do: div(@prefix_bits, 8)
  def yid_bits, do: @yid_bits
  def yid_bytes, do: div(@yid_bits, 8)

  # --- prefix derivation (D-4) --------------------------------------------- #

  @hash :sha256

  def hash_algo, do: @hash

  @doc """
  Epoch-dependent prefix label (D-4b, D-4c).

      iex> YggPF.Const.prefix_label(0, 0)
      "fswarm/v1/bootstrap_prefix/part_0_and_cursor_0"
  """
  def prefix_label(part_index, cursor)
      when is_integer(part_index) and part_index >= 0 and is_integer(cursor) and cursor >= 0,
      do: "fswarm/v1/bootstrap_prefix/part_#{part_index}_and_cursor_#{cursor}"

  @doc """
  Epoch-independent prefix label (D-5). No epoch term, no cursor term.

      iex> YggPF.Const.fixed_prefix_label(1)
      "fswarm/v1/bootstrap_prefix/fixed/part_1"
  """
  def fixed_prefix_label(part_index) when is_integer(part_index) and part_index >= 0,
    do: "fswarm/v1/bootstrap_prefix/fixed/part_#{part_index}"

  # --- epoch and cursor ----------------------------------------------------- #

  @epoch_seconds 60
  @cursor_start 0
  @cursor_threshold 8

  @doc "Epoch length in seconds (INV-012)."
  def epoch_seconds, do: @epoch_seconds
  @doc "Initial cursor value (INV-010)."
  def cursor_start, do: @cursor_start
  @doc "Escalate when matching yids are strictly greater than this, i.e. at 9 (INV-011)."
  def cursor_threshold, do: @cursor_threshold

  # --- Yggdrasil ------------------------------------------------------------ #

  @ygg_prefix_byte 0x02
  @ygg_pf_port 0x6666

  @doc "Yggdrasil node addresses live in 200::/7 and begin with this byte."
  def ygg_prefix_byte, do: @ygg_prefix_byte
  @doc "Fixed port for yaddr (D-7)."
  def ygg_pf_port, do: @ygg_pf_port

  # --- PF binary protocol (D-6) --------------------------------------------- #

  @pf_marker 0x66
  @pf_ver 0x02
  @pf_v1_ver 0x01
  @fid_bytes 32
  @pf_header_bytes 44
  @opcode_ping 0x0001
  @opcode_pong 0x4001

  def pf_marker, do: @pf_marker
  @doc "ygg_pf speaks PF v2. v1 (`b_pf_new`) remains readable for migration."
  def pf_ver, do: @pf_ver
  def pf_v1_ver, do: @pf_v1_ver
  @doc "fid is a 32-byte Ygg public key (INV-017)."
  def fid_bytes, do: @fid_bytes
  def pf_header_bytes, do: @pf_header_bytes
  def opcode_ping, do: @opcode_ping
  def opcode_pong, do: @opcode_pong

  # --- scheduling (spec sections 23, 25, 27) -------------------------------- #

  @paint_per_second 4
  @scan_per_second 4
  @fixed_paint_per_second 1
  @fixed_scan_per_second 1
  @active_cursors 2
  @cooldown_ms 30_000
  @min_reachable_yaddrs 4
  @no_boot_deadline_ms 20_000

  @doc "Paint queries per second, per cursor."
  def paint_per_second, do: @paint_per_second
  @doc "Scan queries per second, per cursor."
  def scan_per_second, do: @scan_per_second
  def fixed_paint_per_second, do: @fixed_paint_per_second
  def fixed_scan_per_second, do: @fixed_scan_per_second
  @doc "Cursors kept active concurrently: last and next (spec section 25)."
  def active_cursors, do: @active_cursors

  @doc """
  Epoch-driven traffic budget: 16 q/s (spec section 25).

      (4 paint + 4 scan) * 2 cursors = 16
  """
  def epoch_queries_per_second,
    do: (@paint_per_second + @scan_per_second) * @active_cursors

  @doc "Fixed-prefix traffic budget: 2 q/s, on top of the epoch budget (spec section 27)."
  def fixed_queries_per_second,
    do: @fixed_paint_per_second + @fixed_scan_per_second

  @doc "Per-fnode cooldown after a query. Copied from `pf_node_processor.ex:41` (D-8)."
  def cooldown_ms, do: @cooldown_ms

  @ask_cooldown_ms 5_000

  @doc """
  Short cooldown applied to any DHT node we ask, paint or scan.

  Deliberately much smaller than `cooldown_ms/0`: that one governs how often we
  re-probe a *candidate fnode*, whereas this one only spreads our own outbound
  find_node traffic across the nodes nearest the region prefix, so a small stable
  set is not hammered every 250 ms tick.
  """
  def ask_cooldown_ms, do: @ask_cooldown_ms

  @doc "Below this many reachable yaddrs, discovery is degraded (spec section 43)."
  def min_reachable_yaddrs, do: @min_reachable_yaddrs

  @doc "Deadline after which no candidates *and* no DHT boot is a failure (spec section 45)."
  def no_boot_deadline_ms, do: @no_boot_deadline_ms

  # --- web scrape (spec sections 36-39) ------------------------------------ #

  @web_cache_ttl_ms 2 * 60 * 60 * 1000
  @web_bootstrap_peers 16

  @doc """
  How long a scrape of the public-peers repository stays usable: 2 hours.

  Long enough that restarts do not hammer the GitHub API (unauthenticated
  api.github.com allows 60 requests/hour and a full recursive walk costs one
  request per directory), short enough that dead peers age out.
  """
  def web_cache_ttl_ms, do: @web_cache_ttl_ms

  @doc """
  How many web-scraped peers the node connects to at startup.

  Drawn at random from the whole cached population, not the first N, so repeated
  starts spread load across the public peer set instead of converging on the same
  few hosts.
  """
  def web_bootstrap_peers, do: @web_bootstrap_peers
end
