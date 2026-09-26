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

  @typedoc """
  A recovered payload fragment.

  `uaddr` is the address embedded in the compact entry - where the painted node
  claims to be reachable. `responder` is the DHT node that *sent* us the entry.
  They are usually different nodes, and the difference is what lets the scanner
  tell an echo of its own paint from a genuine third-party sighting.
  """
  @type fragment :: %{part: binary(), uaddr: uaddr(), responder: uaddr() | nil}

  @typedoc "A reconstructed candidate and the provenance of the fragments that built it."
  @type candidate :: %{
          yaddr: Codec.yaddr(),
          uaddrs: [uaddr()],
          responders: [uaddr()]
        }

  @doc """
  Reduce raw `nodes` entries to fragments grouped by part index.

  `responder` is the underlay address of the node that returned these entries. It
  is carried untouched into every fragment and on into the candidate, so callers
  can attribute a finding to its origin. Pass `nil` when the origin is unknown.

  The `uaddr` inside each entry is kept as well: it is the address the painting
  node is reachable at, and it arrives for free in the same compact entry as the
  yid, which is exactly why the payload never needs to encode it (D-1).
  """
  @spec fragments([node_entry()], non_neg_integer(), non_neg_integer(), uaddr() | nil) ::
          %{non_neg_integer() => [fragment()]}
  def fragments(nodes, cursor, epoch, responder \\ nil) do
    for {id, uaddr} <- nodes,
        part_index <- 0..(@n_parts - 1),
        Codec.prefix_match?(id, part_index, cursor, epoch),
        {:ok, part} <- [Codec.fragment(id)],
        reduce: %{} do
      acc -> add(acc, part_index, part, uaddr, responder)
    end
  end

  @doc """
  Same reduction against the epoch-independent fixed prefix (spec section 27).
  """
  @spec fixed_fragments([node_entry()], uaddr() | nil) ::
          %{non_neg_integer() => [fragment()]}
  def fixed_fragments(nodes, responder \\ nil) do
    for {id, uaddr} <- nodes,
        part_index <- 0..(@n_parts - 1),
        Codec.fixed_prefix_match?(id, part_index),
        {:ok, part} <- [Codec.fragment(id)],
        reduce: %{} do
      acc -> add(acc, part_index, part, uaddr, responder)
    end
  end

  defp add(acc, part_index, part, uaddr, responder) do
    frag = %{part: part, uaddr: uaddr, responder: responder}
    Map.update(acc, part_index, [frag], &[frag | &1])
  end

  @doc """
  Merge fragment maps from several replies, so one reconstruction can combine
  fragments that arrived from different responders.
  """
  @spec merge_fragments(%{non_neg_integer() => [fragment()]}, %{
          non_neg_integer() => [fragment()]
        }) :: %{non_neg_integer() => [fragment()]}
  def merge_fragments(a, b), do: Map.merge(a, b, fn _k, x, y -> x ++ y end)

  @doc """
  How many yids matched any of our prefixes - the input to cursor escalation
  (spec section 21).
  """
  @spec match_count(%{non_neg_integer() => list()}) :: non_neg_integer()
  def match_count(frags), do: frags |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

  @doc """
  Cross-product the fragments into candidates.

  Only combinations that reconstruct into a well-formed Yggdrasil address survive.
  Each distinct yaddr collects both the uaddrs its fragments claimed and the
  responders that supplied them, since either fragment's source is a plausible
  place to reach the node and the responders establish provenance.

  `:max_pairs` bounds the cross product so a flooded region cannot blow up the
  scanner; the excess is dropped and logged (spec section 60, "excessive yids").
  """
  @spec candidates(%{non_neg_integer() => [fragment()]}, keyword()) :: [candidate()]
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
    |> Enum.reduce(%{}, fn {fa, fb}, acc ->
      case reconstruct_pair(fa.part, fb.part) do
        {:ok, yaddr} ->
          Map.update(
            acc,
            yaddr,
            %{
              yaddr: yaddr,
              uaddrs: uniq([fa.uaddr, fb.uaddr]),
              responders: uniq([fa.responder, fb.responder])
            },
            fn c ->
              %{
                c
                | uaddrs: uniq(c.uaddrs ++ [fa.uaddr, fb.uaddr]),
                  responders: uniq(c.responders ++ [fa.responder, fb.responder])
              }
            end
          )

        :error ->
          acc
      end
    end)
    |> Map.values()
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
