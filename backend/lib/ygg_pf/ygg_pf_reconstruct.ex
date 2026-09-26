defmodule YggPF.Reconstruct do
  @moduledoc """
  Combinatorial payload reconstruction (spec sections 8, 9).

      nodes replies
          -> valid prefix        (which part index does this id belong to?)
          -> valid affix         (checksum)
          -> part matching       (group fragments by part index)
          -> candidate combinations
          -> Ygg-range validation
          -> reconstructed painter address

  Noise resistance comes from three independent filters:

    1. the 80-bit prefix - an unrelated Mainline DHT id matches with probability
       2^-80, so essentially only deliberately painted ids survive;
    2. the 8-bit checksum - rejects 255/256 of corrupted or forged affixes and
       every single-bit mutation;
    3. the Yggdrasil range check - a reconstructed address must begin with 0x02,
       rejecting a further 255/256 of mismatched pairings.

  Filters 2 and 3 are what keep the `N = 2` cross product tractable when an
  attacker floods a prefix region: `k` fragments per part give `k^2` pairs, but
  only about `k^2 / 256` survive the range check and must be probed.
  """

  require Logger
  alias YggPF.{Codec, Const}

  @n_parts Const.n_parts()

  @typedoc "A compact `nodes` entry: the 20-byte id and the 6/18-byte underlay address."
  @type node_entry :: {binary(), binary()}

  @typedoc "uaddr as it appears in a compact entry."
  @type uaddr :: binary()

  @doc """
  Reduce raw `nodes` entries to fragments grouped by part index.

  Returns `%{part_index => [{part, uaddr}]}`. The `uaddr` is carried along because
  it is the address the painting node was reachable at - it arrives for free in the
  same compact entry as the yid and never needs to be encoded in the payload.
  """
  @spec fragments([node_entry()], non_neg_integer(), non_neg_integer()) ::
          %{non_neg_integer() => [{binary(), uaddr()}]}
  def fragments(nodes, cursor, epoch) do
    for {id, uaddr} <- nodes,
        part_index <- 0..(@n_parts - 1),
        Codec.prefix_match?(id, part_index, cursor, epoch),
        {:ok, part} <- [Codec.fragment(id)],
        reduce: %{} do
      acc -> Map.update(acc, part_index, [{part, uaddr}], &[{part, uaddr} | &1])
    end
  end

  @doc """
  Same reduction against the epoch-independent fixed prefix (spec section 27).
  """
  @spec fixed_fragments([node_entry()]) :: %{non_neg_integer() => [{binary(), uaddr()}]}
  def fixed_fragments(nodes) do
    for {id, uaddr} <- nodes,
        part_index <- 0..(@n_parts - 1),
        Codec.fixed_prefix_match?(id, part_index),
        {:ok, part} <- [Codec.fragment(id)],
        reduce: %{} do
      acc -> Map.update(acc, part_index, [{part, uaddr}], &[{part, uaddr} | &1])
    end
  end

  @doc """
  How many yids matched any of our prefixes - the input to cursor escalation
  (spec section 21).
  """
  @spec match_count(%{non_neg_integer() => list()}) :: non_neg_integer()
  def match_count(frags), do: frags |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

  @doc """
  Cross-product the fragments into candidate `{yaddr, uaddrs}` tuples.

  Only combinations that reconstruct into a well-formed Yggdrasil address survive.
  Each distinct yaddr collects the set of uaddrs its fragments arrived from, since
  either fragment's source is a plausible place to reach the node.

  `:max_pairs` bounds the cross product so a flooded region cannot blow up the
  scanner; the excess is dropped and logged (spec section 60, "excessive yids").
  """
  @spec candidates(%{non_neg_integer() => [{binary(), uaddr()}]}, keyword()) ::
          [{Codec.yaddr(), [uaddr()]}]
  def candidates(frags, opts \\ []) do
    max_pairs = Keyword.get(opts, :max_pairs, 4_096)

    a = Map.get(frags, 0, [])
    b = Map.get(frags, 1, [])
    total = length(a) * length(b)

    if total > max_pairs do
      Logger.warning(
        "[YggPF] reconstruction capped: #{total} pairs from #{length(a)}x#{length(b)} " <>
          "fragments exceeds max_pairs=#{max_pairs}; region may be flooded"
      )
    end

    a
    |> pairs(b, max_pairs)
    |> Enum.reduce(%{}, fn {{pa, ua}, {pb, ub}}, acc ->
      case reconstruct_pair(pa, pb) do
        {:ok, yaddr} -> Map.update(acc, yaddr, uniq([ua, ub]), &uniq(&1 ++ [ua, ub]))
        :error -> acc
      end
    end)
    |> Enum.map(fn {yaddr, uaddrs} -> {yaddr, uaddrs} end)
  end

  # Lazily bound the cross product so a flooded region cannot materialise a huge list.
  defp pairs(a, b, max_pairs) do
    a
    |> Stream.flat_map(fn x -> Stream.map(b, fn y -> {x, y} end) end)
    |> Enum.take(max_pairs)
  end

  defp reconstruct_pair(part_a, part_b) do
    with painter when is_binary(painter) <- Codec.join_parts([part_a, part_b]),
         {:ok, {ip, port}} <- Codec.parse_painter_address(painter),
         true <- Codec.ygg_addr?(ip) do
      {:ok, {ip, port}}
    else
      _invalid -> :error
    end
  end

  defp uniq(list), do: list |> Enum.reject(&is_nil/1) |> Enum.uniq()
end
