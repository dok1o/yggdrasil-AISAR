defmodule Ygg.Bloom do
  @moduledoc """
  Ironwood multicast bloom filters: the filter itself (`bits-and-blooms/bloom/v3` v3.7.1 +
  `bitset` v1.24.4 as configured by ironwood `network/bloomfilter.go:13-31`), the wire format
  (`bloomfilter.go:54-116`) and the per-peer bookkeeping of `blooms` (`bloomfilter.go:122-332`)
  as pure functions the router calls.
  Filter: M = 8192 bits (128 uint64 words), K = 8. `add/2` hashes the raw bytes with
  `Ygg.Murmur3.sum256/1` (`bloom.go:111-117`), location `i` is
  `h[i%2] + i*h[2 + ((i + i%2) % 4) / 2]` mod 2^64, then mod M (`bloom.go:120-128`); bit
  `idx` is bit `idx &&& 63` (LSB-first) of word `idx >>> 6` (`bitset.Set`). A filter is a
  non-negative integer `< 2^8192` with `<<f::unsigned-big-8192>>` = the 128 words big-endian,
  so bit `b` of word `w` is integer bit `(127 - w) * 64 + b`; union is `bor`, equality is `==`.
  Wire (`encode`/`decode`, `bloomfilter.go:54-116`): `flags0` (16 bytes, word == 0),
  `flags1` (16 bytes, word == 2^64-1), one flag per word MSB-first, then every other word as a
  big-endian uint64. Decoding is strict like Go: both flags set, missing words, trailing bytes
  or fewer than 32 flag bytes are `{:error, :decode}`.
  Keys are inserted transformed: `x_key/1` = Yggdrasil `SubnetForKey(key).GetKey()`
  (`core.go:101`, `WithBloomTransform`), i.e. `add_key/2`, `member_key?/2`.
  Bookkeeping (`t:peers/0` = `%{peer_key => %Ygg.Bloom.Info{}}`, keyed by the peer's raw
  public key; one entry per peer node, not per link):
    * `add_peer/2` (`router.go:116-143`, `_addInfo`, `_sendBloom`): returns the filter to
      send on the new link — the last one sent to that node (empty for a new node).
    * `remove_peer/2` (`_removeInfo`): call when the last link to the node is gone. When
      other links remain, Go resends `sent/2` on each of them (`router.go:164-170`).
    * `recv/3` (`_handleBloom`): store a received filter; ignored for unknown peers.
    * `fix_on_tree/2` (`_fixOnTree`, :154-183): `on_tree_keys` = peers that are our parent or
      whose parent is us. A peer that drops off the tree gets (and stores as `send`) an empty
      filter so it does not keep false positives when it returns.
    * `send_all/2` (`_getBloomFor` + `_sendAllBlooms`, :231-303): for every on-tree peer `k`
      the filter is `x_key(own) ∪ recv(j)` over on-tree `j != k`; sent when it differs from
      the last one sent, or when `seq` reaches 3600 maintenance ticks (then `seq = 0`).
    * `maintenance/3` = `fix_on_tree` then `send_all` (`_doMaintenance`, :226-229).
    * `multicast_targets/3` (`_sendMulticast`, :315-332): on-tree peers other than the sender
      whose `recv` filter matches the already transformed destination key.
    * `on_tree?/2` (`_isOnTree`): lookups from off-tree peers are ignored (`pathfinder.go:46`).
  Emitted sends are `{:send, peer_key, filter}` (to every link of that node), sorted by key.
  Simplification allowed by PLAN_STAGE2 §4: the `keepOnes`/`zDirty` heuristic of
  `_getBloomFor` is omitted, the filter sent is always the exact union (not visible on the
  wire beyond fewer stale 1 bits; the hourly resend is kept).
  """
  import Bitwise
  alias Ygg.{Address, Murmur3}
  @compile {:inline, [bit: 1, location: 2, mask: 1]}
  @m 8192
  @k 8
  @words 128
  @ones 0xFFFF_FFFF_FFFF_FFFF
  @resend_ticks 3600
  @type t :: non_neg_integer()
  @type key :: <<_::256>>
  @type send :: {:send, key(), t()}
  defmodule Info do
    @moduledoc "Per-peer bloom state (`bloomInfo`, `bloomfilter.go:128-134`, without `zDirty`)."
    defstruct send: 0, recv: 0, seq: 0, on_tree: false
    @type t :: %__MODULE__{
            send: Ygg.Bloom.t(),
            recv: Ygg.Bloom.t(),
            seq: non_neg_integer(),
            on_tree: boolean()
          }
  end
  @type peers :: %{key() => Info.t()}
  def m, do: @m
  def k, do: @k
  def resend_ticks, do: @resend_ticks
  @spec new() :: t()
  def new, do: 0
  @spec x_key(key()) :: key()
  def x_key(<<_::binary-size(32)>> = key), do: Address.subnet_get_key(Address.subnet_for_key(key))
  @doc "The 8 bit positions of `data` (`bloom.go:120-128`), in hash order."
  @spec locations(binary()) :: [non_neg_integer()]
  def locations(data) do
    h = Murmur3.sum256(data)
    for i <- 0..(@k - 1), do: location(h, i)
  end
  @spec add(t(), binary()) :: t()
  def add(f, data), do: f ||| mask(data)
  @spec add_key(t(), key()) :: t()
  def add_key(f, key), do: add(f, x_key(key))
  @spec member?(t(), binary()) :: boolean()
  def member?(f, data) do
    m = mask(data)
    (f &&& m) == m
  end
  @spec member_key?(t(), key()) :: boolean()
  def member_key?(f, key), do: member?(f, x_key(key))
  @spec union(t(), t()) :: t()
  def union(a, b), do: a ||| b
  @spec empty?(t()) :: boolean()
  def empty?(f), do: f == 0
  @doc "The 128 backing words (bitset order)."
  @spec to_words(t()) :: [non_neg_integer()]
  def to_words(f), do: for(<<w::64 <- encode_words(f)>>, do: w)
  defp encode_words(f), do: <<f::unsigned-big-size(@m)>>
  @spec from_words([non_neg_integer()]) :: t()
  def from_words(ws) when length(ws) == @words do
    <<f::unsigned-big-size(@m)>> = for w <- ws, into: <<>>, do: <<w::64>>
    f
  end
  @spec encode(t()) :: binary()
  def encode(f) do
    bin = encode_words(f)
    f0 = for <<w::64 <- bin>>, into: <<>>, do: <<if(w == 0, do: 1, else: 0)::1>>
    f1 = for <<w::64 <- bin>>, into: <<>>, do: <<if(w == @ones, do: 1, else: 0)::1>>
    keep = for <<w::64 <- bin>>, w != 0 and w != @ones, into: <<>>, do: <<w::64>>
    <<f0::bitstring, f1::bitstring, keep::binary>>
  end
  @spec decode(binary()) :: {:ok, t()} | {:error, :decode}
  def decode(<<f0::bitstring-size(@words), f1::bitstring-size(@words), rest::binary>>),
    do: words(f0, f1, rest, [])
  def decode(_bin), do: {:error, :decode}
  defp words(<<1::1, _::bitstring>>, <<1::1, _::bitstring>>, _data, _acc), do: {:error, :decode}
  defp words(<<1::1, f0::bitstring>>, <<0::1, f1::bitstring>>, d, acc),
    do: words(f0, f1, d, [<<0::64>> | acc])
  defp words(<<0::1, f0::bitstring>>, <<1::1, f1::bitstring>>, d, acc),
    do: words(f0, f1, d, [<<@ones::64>> | acc])
  defp words(
         <<0::1, f0::bitstring>>,
         <<0::1, f1::bitstring>>,
         <<w::binary-size(8), d::binary>>,
         acc
       ),
       do: words(f0, f1, d, [w | acc])
  defp words(<<>>, <<>>, <<>>, acc) do
    <<f::unsigned-big-size(@m)>> = IO.iodata_to_binary(Enum.reverse(acc))
    {:ok, f}
  end
  defp words(_f0, _f1, _data, _acc), do: {:error, :decode}
  defp mask(data), do: data |> locations() |> Enum.reduce(0, &(&2 ||| bit(&1)))
  defp bit(idx), do: 1 <<< ((@words - 1 - (idx >>> 6)) * 64 + (idx &&& 63))
  defp location({h0, h1, h2, h3}, i) do
    a = if rem(i, 2) == 0, do: h0, else: h1
    b = if div(rem(i + rem(i, 2), 4), 2) == 0, do: h2, else: h3
    rem(a + i * b &&& @ones, @m)
  end
  @spec add_peer(peers(), key()) :: {peers(), t()}
  def add_peer(peers, key) do
    peers = Map.put_new(peers, key, %Info{})
    {peers, peers[key].send}
  end
  @spec remove_peer(peers(), key()) :: peers()
  def remove_peer(peers, key), do: Map.delete(peers, key)
  @doc "The filter last sent to `key` (empty when unknown)."
  @spec sent(peers(), key()) :: t()
  def sent(peers, key) do
    case peers do
      %{^key => i} -> i.send
      _ -> 0
    end
  end
  @spec recv(peers(), key(), t()) :: peers()
  def recv(peers, key, f) do
    case peers do
      %{^key => i} -> %{peers | key => %{i | recv: f}}
      _ -> peers
    end
  end
  @spec on_tree?(peers(), key()) :: boolean()
  def on_tree?(peers, key), do: match?(%{^key => %Info{on_tree: true}}, peers)
  @spec fix_on_tree(peers(), Enumerable.t()) :: {peers(), [send()]}
  def fix_on_tree(peers, on_tree_keys) do
    on = MapSet.new(on_tree_keys)
    Enum.reduce(Enum.sort(peers), {peers, []}, fn {k, i}, {acc, out} ->
      now = MapSet.member?(on, k)
      if i.on_tree and not now,
        do: {%{acc | k => %{i | on_tree: false, send: 0}}, [{:send, k, 0} | out]},
        else: {%{acc | k => %{i | on_tree: now}}, out}
    end)
    |> then(fn {acc, out} -> {acc, Enum.reverse(out)} end)
  end
  @spec send_all(peers(), key()) :: {peers(), [send()]}
  def send_all(peers, own_key) do
    own = add_key(0, own_key)
    tree = for {k, %Info{on_tree: true} = i} <- Enum.sort(peers), do: {k, i}
    Enum.reduce(tree, {peers, []}, fn {k, i}, {acc, out} ->
      f = Enum.reduce(tree, own, fn {j, ij}, f -> if j == k, do: f, else: f ||| ij.recv end)
      seq = i.seq + 1
      if f != i.send or seq >= @resend_ticks,
        do: {%{acc | k => %{i | send: f, seq: 0}}, [{:send, k, f} | out]},
        else: {%{acc | k => %{i | seq: seq}}, out}
    end)
    |> then(fn {acc, out} -> {acc, Enum.reverse(out)} end)
  end
  @spec maintenance(peers(), key(), Enumerable.t()) :: {peers(), [send()]}
  def maintenance(peers, own_key, on_tree_keys) do
    {peers, s1} = fix_on_tree(peers, on_tree_keys)
    {peers, s2} = send_all(peers, own_key)
    {peers, s1 ++ s2}
  end
  @doc "On-tree peers except `from_key` whose received filter matches `x_dest` (already `x_key`ed)."
  @spec multicast_targets(peers(), key(), key() | nil) :: [key()]
  def multicast_targets(peers, x_dest, from_key) do
    m = mask(x_dest)
    for {k, %Info{on_tree: true, recv: r}} <- Enum.sort(peers),
        k != from_key,
        (r &&& m) == m,
        do: k
  end
end