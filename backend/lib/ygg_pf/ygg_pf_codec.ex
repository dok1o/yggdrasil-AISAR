defmodule YggPF.Codec do
  @moduledoc """
  SDP encoding for the Yggdrasil bootstrap: painter address <-> `yid`.

  Pure and side-effect free. Every function here is covered by
  `data/ygg_pf_vectors.json`, generated from the reference implementation at
  `tools/py_scripts/ygg_pf_ref.py`.

      yaddr ──split──> 2 x 72-bit parts ──bitrev──> ──xor8──> 2 x 80-bit affixes
                                                                    │
                            80-bit epoch prefix ────────────────────┤
                                                                    ▼
                                                       2 x 20-byte yids

  The painter address is preserved verbatim and is never hashed (INV-002).

  Bit reversal and the XOR-fold checksum are *copied* from
  `b_pf_new/pf_mask_sync.ex` rather than called, so retiring the legacy PF scheme
  cannot break this module. See `YggPF.Const` for provenance of every value.
  """

  import Bitwise
  alias YggPF.Const

  @part_bytes Const.part_bytes()
  @affix_bytes Const.affix_bytes()
  @prefix_bytes Const.prefix_bytes()
  @painter_bytes Const.painter_bytes()
  @yid_bytes Const.yid_bytes()
  @n_parts Const.n_parts()
  @ygg_prefix_byte Const.ygg_prefix_byte()

  @type part :: <<_::72>>
  @type affix :: <<_::80>>
  @type prefix :: <<_::80>>
  @type yid :: <<_::160>>
  @type painter :: <<_::144>>
  @type yaddr :: {:inet.ip6_address(), :inet.port_number()}

  # ------------------------------------------------------------------ #
  # Bit primitives (copied from b_pf_new/pf_mask_sync.ex)               #
  # ------------------------------------------------------------------ #

  # Bits are reversed WITHIN each byte; byte order is preserved.
  @in_byte_rev Map.new(0..255, fn byte ->
                 <<b7::1, b6::1, b5::1, b4::1, b3::1, b2::1, b1::1, b0::1>> = <<byte>>

                 {byte,
                  <<b0::1, b1::1, b2::1, b3::1, b4::1, b5::1, b6::1, b7::1>>
                  |> :binary.decode_unsigned()}
               end)

  @doc """
  Reverse the bit order inside every byte, preserving byte order.

  This is an involution: `reverse_bits(reverse_bits(x)) == x`.
  """
  @spec reverse_bits(binary()) :: binary()
  def reverse_bits(bin) when is_binary(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.map(&Map.fetch!(@in_byte_rev, &1))
    |> :binary.list_to_bin()
  end

  @doc """
  8-bit XOR fold (D-9). Fold width equals checksum width, as in the legacy scheme.
  """
  @spec xor8(binary()) :: 0..255
  def xor8(bin) when is_binary(bin), do: fold(bin, 0)

  defp fold(<<ch::8, rest::binary>>, acc), do: fold(rest, bxor(acc, ch))
  defp fold(<<>>, acc), do: band(acc, 0xFF)

  # ------------------------------------------------------------------ #
  # Painter address                                                     #
  # ------------------------------------------------------------------ #

  @doc """
  Build the 144-bit painter address from a yaddr: 128-bit IPv6 then 16-bit port,
  big-endian (D-1, D-3).
  """
  @spec painter_address(:inet.ip6_address() | binary(), :inet.port_number()) :: painter()
  def painter_address(ip, port \\ Const.ygg_pf_port())

  def painter_address({a, b, c, d, e, f, g, h}, port) when port in 0..0xFFFF do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, port::16>>
  end

  def painter_address(<<ip::binary-16>>, port) when port in 0..0xFFFF,
    do: <<ip::binary-16, port::16>>

  @doc "Inverse of `painter_address/2`."
  @spec parse_painter_address(painter()) :: {:ok, yaddr()} | :error
  def parse_painter_address(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, port::16>>),
    do: {:ok, {{a, b, c, d, e, f, g, h}, port}}

  def parse_painter_address(_other), do: :error

  @doc "True for addresses inside the Yggdrasil node range 200::/7 (prefix byte 0x02)."
  @spec ygg_addr?(:inet.ip6_address() | binary()) :: boolean()
  def ygg_addr?({a, _, _, _, _, _, _, _}), do: bsr(a, 8) == @ygg_prefix_byte
  def ygg_addr?(<<@ygg_prefix_byte, _::binary-15>>), do: true
  def ygg_addr?(_other), do: false

  # ------------------------------------------------------------------ #
  # Split / join (D-3)                                                  #
  # ------------------------------------------------------------------ #

  @doc """
  Split the 144-bit painter address into `N = 2` parts of 72 bits, MSB-first.

  Property: `join_parts(split_parts(a)) == a` (spec section 56).
  """
  @spec split_parts(painter()) :: [part()]
  def split_parts(<<a::binary-size(@part_bytes), b::binary-size(@part_bytes)>>), do: [a, b]

  @doc "Inverse of `split_parts/1`."
  @spec join_parts([part()]) :: painter() | :error
  def join_parts([<<a::binary-size(@part_bytes)>>, <<b::binary-size(@part_bytes)>>]),
    do: <<a::binary, b::binary>>

  def join_parts(_other), do: :error

  # ------------------------------------------------------------------ #
  # Affix (D-9, D-10)                                                   #
  # ------------------------------------------------------------------ #

  @doc """
  Build an 80-bit affix from a 72-bit part: bit-reverse, then append the 8-bit XOR
  fold **of the reversed bytes** (checksum input is post-reversal).
  """
  @spec build_affix(part()) :: affix()
  def build_affix(<<part::binary-size(@part_bytes)>>) do
    rpart = reverse_bits(part)
    <<rpart::binary, xor8(rpart)::8>>
  end

  @doc """
  Validate an affix checksum and undo the bit reversal.

  Returns `{:ok, part}` or `:error` when the checksum does not match.
  """
  @spec parse_affix(affix()) :: {:ok, part()} | :error
  def parse_affix(<<rpart::binary-size(@part_bytes), cks::8>>) do
    case xor8(rpart) do
      ^cks -> {:ok, reverse_bits(rpart)}
      _mismatch -> :error
    end
  end

  def parse_affix(_other), do: :error

  # ------------------------------------------------------------------ #
  # Prefix derivation (D-4, D-5)                                        #
  # ------------------------------------------------------------------ #

  @doc """
  The 1-minute epoch number for a unix timestamp in seconds (D-4d, INV-012).
  """
  @spec epoch(integer()) :: non_neg_integer()
  def epoch(unix_seconds) when is_integer(unix_seconds),
    do: div(unix_seconds, Const.epoch_seconds())

  @doc "The epoch number for now."
  @spec current_epoch() :: non_neg_integer()
  def current_epoch, do: epoch(System.os_time(:second))

  @doc """
  Derive the 80-bit epoch-dependent prefix.

      trunc80_msb( sha256( label(N, R) || epoch_be64 ) )
  """
  @spec derive_prefix(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: prefix()
  def derive_prefix(part_index, cursor, epoch)
      when is_integer(part_index) and is_integer(cursor) and is_integer(epoch) and epoch >= 0 do
    input = <<Const.prefix_label(part_index, cursor)::binary, epoch::unsigned-big-64>>
    trunc80(:crypto.hash(Const.hash_algo(), input))
  end

  @doc """
  Derive the 80-bit epoch-independent prefix used by the fixed low-rate discovery
  path (spec section 27, D-5).
  """
  @spec derive_fixed_prefix(non_neg_integer()) :: prefix()
  def derive_fixed_prefix(part_index) when is_integer(part_index) do
    trunc80(:crypto.hash(Const.hash_algo(), Const.fixed_prefix_label(part_index)))
  end

  # Keep the LEADING (most significant) 80 bits of the digest (D-4e).
  defp trunc80(<<head::binary-size(@prefix_bytes), _rest::binary>>), do: head

  # ------------------------------------------------------------------ #
  # yid / id_paint                                                      #
  # ------------------------------------------------------------------ #

  @doc "`yid = prefix || affix`, 20 bytes (INV-009)."
  @spec build_yid(prefix(), affix()) :: yid()
  def build_yid(<<prefix::binary-size(@prefix_bytes)>>, <<affix::binary-size(@affix_bytes)>>),
    do: <<prefix::binary, affix::binary>>

  @doc "Split a 20-byte node id into `{prefix, affix}`."
  @spec split_yid(yid()) :: {prefix(), affix()} | :error
  def split_yid(<<prefix::binary-size(@prefix_bytes), affix::binary-size(@affix_bytes)>>),
    do: {prefix, affix}

  def split_yid(_other), do: :error

  @doc """
  The temporary active DHT identity used while painting (spec section 20).

  `id_paint = prefix || random 80 bits`. Not a `yid`: it carries no payload.
  """
  @spec id_paint(prefix()) :: yid()
  def id_paint(<<prefix::binary-size(@prefix_bytes)>>),
    do: <<prefix::binary, :crypto.strong_rand_bytes(@affix_bytes)::binary>>

  # ------------------------------------------------------------------ #
  # Full encode / decode                                                #
  # ------------------------------------------------------------------ #

  @doc """
  Encode a yaddr into the `N = 2` yids that paint it.

      iex> [a, b] = YggPF.Codec.encode({{0x202, 0x3eb, 0xbc02, 0x2e59, 0x6617, 0x5771, 0x1ee0, 0xfa2e}, 26214}, 0, 0)
      iex> {byte_size(a), byte_size(b)}
      {20, 20}
  """
  @spec encode(yaddr(), non_neg_integer(), non_neg_integer()) :: [yid()]
  def encode({ip, port}, cursor, epoch) do
    ip
    |> painter_address(port)
    |> split_parts()
    |> Enum.with_index()
    |> Enum.map(fn {part, i} ->
      build_yid(derive_prefix(i, cursor, epoch), build_affix(part))
    end)
  end

  @doc """
  Decode an ordered list of `N = 2` yids back into a yaddr.

  Every prefix must match the expected `(part_index, cursor, epoch)` and every affix
  checksum must validate, otherwise `:error`.
  """
  @spec decode([yid()], non_neg_integer(), non_neg_integer()) :: {:ok, yaddr()} | :error
  def decode(yids, cursor, epoch) when length(yids) == @n_parts do
    yids
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {yid, i}, acc ->
      with {prefix, affix} <- split_yid(yid),
           true <- prefix == derive_prefix(i, cursor, epoch),
           {:ok, part} <- parse_affix(affix) do
        {:cont, [part | acc]}
      else
        _invalid -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      parts -> parts |> Enum.reverse() |> join_parts() |> parse_painter_address()
    end
  end

  def decode(_yids, _cursor, _epoch), do: :error

  # ------------------------------------------------------------------ #
  # Scan-side filtering (spec section 8)                                #
  # ------------------------------------------------------------------ #

  @doc "Does this node id sit under the prefix for `(part_index, cursor, epoch)`?"
  @spec prefix_match?(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  def prefix_match?(<<prefix::binary-size(@prefix_bytes), _::binary-size(@affix_bytes)>>,
        part_index, cursor, epoch),
      do: prefix == derive_prefix(part_index, cursor, epoch)

  def prefix_match?(_id, _part_index, _cursor, _epoch), do: false

  @doc "Does this node id sit under the fixed prefix for `part_index`?"
  @spec fixed_prefix_match?(binary(), non_neg_integer()) :: boolean()
  def fixed_prefix_match?(<<prefix::binary-size(@prefix_bytes), _::binary-size(@affix_bytes)>>,
        part_index),
      do: prefix == derive_fixed_prefix(part_index)

  def fixed_prefix_match?(_id, _part_index), do: false

  @doc """
  Extract a candidate payload fragment from a node id whose prefix already matched.

  Returns `{:ok, part}` when the affix checksum validates.
  """
  @spec fragment(binary()) :: {:ok, part()} | :error
  def fragment(<<_prefix::binary-size(@prefix_bytes), affix::binary-size(@affix_bytes)>>),
    do: parse_affix(affix)

  def fragment(_id), do: :error

  @doc """
  Number of leading bits two binaries share.

  Used purely for diagnostics: it answers "is the DHT even routing us into the
  right neighbourhood?" without needing an exact prefix match.
  """
  @spec common_prefix_bits(binary(), binary()) :: non_neg_integer()
  def common_prefix_bits(a, b) when is_binary(a) and is_binary(b) do
    count_common(a, b, 0)
  end

  defp count_common(<<x, ra::binary>>, <<y, rb::binary>>, acc) when x == y,
    do: count_common(ra, rb, acc + 8)

  defp count_common(<<x, _::binary>>, <<y, _::binary>>, acc),
    do: acc + leading_zeros(Bitwise.bxor(x, y))

  defp count_common(_a, _b, acc), do: acc

  defp leading_zeros(0), do: 8
  defp leading_zeros(byte) when byte < 2, do: 7
  defp leading_zeros(byte) when byte < 4, do: 6
  defp leading_zeros(byte) when byte < 8, do: 5
  defp leading_zeros(byte) when byte < 16, do: 4
  defp leading_zeros(byte) when byte < 32, do: 3
  defp leading_zeros(byte) when byte < 64, do: 2
  defp leading_zeros(byte) when byte < 128, do: 1
  defp leading_zeros(_byte), do: 0

  @doc "Byte size of a well-formed yid, for guards and tests."
  def yid_bytes, do: @yid_bytes
  def painter_bytes, do: @painter_bytes
end
