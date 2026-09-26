defmodule EphemeralDHTSync do
  import Bitwise
  @moduledoc """
  XOR-distance optimized structure for per-infohash DHT walks.
  Binary trie where each level represents a bit of XOR distance.
  Nodes closer to target cluster near the root.
  """
  @compile {:inline, []}
  @type t :: %__MODULE__{}
  @high_bit 0x8000000000000000000000000000000000000000
  defstruct target: nil,
            target_int: 0,
            size: 0,
            max_size: 0,
            node_map: %{}
  @spec new(<<_::160>>, pos_integer()) :: t()
  def new(<<target_int::160>> = target, max_size) do
    %__MODULE__{
      target: target,
      target_int: target_int,
      max_size: max_size
    }
  end
  @doc "Insert node, deduped, evicts furthest when at capacity"
  @spec insert(t(), <<_::160>>, <<_::48>>) :: t()
  def insert(%__MODULE__{node_map: nmap} = dht, rid, nodev4) do
    case Map.has_key?(nmap, rid) do
      true -> dht
      false -> do_insert(dht, rid, nodev4)
    end
  end
  @doc "Get k closest unqueried nodes as [{rid, nodev4}]"
  @spec closest_unqueried(t(), pos_integer()) :: [{<<_::160>>, <<_::48>>}]
  def closest_unqueried(%__MODULE__{node_map: nmap}, k) do
    nmap
    |> Enum.filter(fn {_rid, {_dist, _nv4, queried}} -> not queried end)
    |> Enum.sort_by(fn {_rid, {dist, _nv4, _q}} -> dist end)
    |> Enum.take(k)
    |> Enum.map(fn {rid, {_dist, nv4, _q}} -> {rid, nv4} end)
  end
  @doc "Get k closest nodes as [{dist, rid, nodev4}]"
  @spec closest(t(), pos_integer()) :: [{non_neg_integer(), <<_::160>>, <<_::48>>}]
  def closest(%__MODULE__{node_map: nmap}, k) do
    nmap
    |> Enum.sort_by(fn {_rid, {dist, _nv4, _q}} -> dist end)
    |> Enum.take(k)
    |> Enum.map(fn {rid, {dist, nv4, _q}} -> {dist, rid, nv4} end)
  end
  @doc "Mark node as queried"
  @spec mark_queried(t(), <<_::160>>) :: t()
  def mark_queried(%__MODULE__{node_map: nmap} = dht, rid) do
    case Map.get(nmap, rid) do
      nil -> dht
      {dist, nv4, _old} -> %{dht | node_map: Map.put(nmap, rid, {dist, nv4, true})}
    end
  end
  @doc "Any unqueried nodes remaining?"
  @spec has_unqueried?(t()) :: boolean()
  def has_unqueried?(%__MODULE__{node_map: nmap}),
    do: Enum.any?(nmap, fn {_rid, {_d, _nv4, q}} -> not q end)
  @doc "Convergence quality stats for logging"
  @spec convergence_stats(t()) :: map()
  def convergence_stats(%__MODULE__{node_map: nmap} = dht) do
    queried_nodes = Enum.filter(nmap, fn {_rid, {_d, _nv4, q}} -> q end)
    case queried_nodes do
      [] ->
        %{quality: :no_queries, min_bits: 160, bits_gained: 0}
      nodes ->
        distances = nodes |> Enum.map(fn {_rid, {d, _nv4, _q}} -> d end) |> Enum.sort()
        min_d = hd(distances)
        max_d = List.last(distances)
        min_bits = distance_to_bits(min_d)
        initial_bits = distance_to_bits(initial_best_distance(dht))
        %{
          quality: classify_quality(min_bits, length(nodes)),
          min_bits: min_bits,
          bits_gained: initial_bits - min_bits,
          spread: spread_ratio(min_d, max_d),
          nodes_queried: length(nodes)
        }
    end
  end
  defp do_insert(%__MODULE__{target_int: ti} = dht, rid, nodev4) do
    <<rid_int::160>> = rid
    distance = bxor(rid_int, ti)
    maybe_insert_with_eviction(dht, rid, nodev4, distance)
  end
  defp maybe_insert_with_eviction(
         %{size: sz, max_size: max} = dht,
         rid,
         nodev4,
         distance
       )
       when sz < max do
    new_map = Map.put(dht.node_map, rid, {distance, nodev4, false})
    %{dht | node_map: new_map, size: sz + 1}
  end
  defp maybe_insert_with_eviction(%{node_map: n_map} = dht, rid, nodev4, init_dist) do
    {furthest_rid, {furthest_dist, _nodev4, _q}} =
      Enum.max_by(n_map, fn {_rid, {dist, _nodev4, _q}} -> dist end)
    case init_dist < furthest_dist do
      true -> dht |> remove(furthest_rid) |> insert(rid, nodev4)
      false -> dht
    end
  end
  defp remove(%{node_map: nmap, size: sz} = dht, rid),
    do: %{dht | node_map: Map.delete(nmap, rid), size: sz - 1}
  defp distance_to_bits(0), do: 0
  defp distance_to_bits(d), do: 160 - leading_zeros(d)
  def leading_zeros(0), do: 160
  def leading_zeros(n), do: do_leading_zeros(n, 0)
  defp do_leading_zeros(n, count) when n >= @high_bit, do: count
  defp do_leading_zeros(n, count), do: do_leading_zeros(bsl(n, 1), count + 1)
  defp classify_quality(min_bits, _count) when min_bits < 40, do: :excellent
  defp classify_quality(min_bits, _count) when min_bits < 80, do: :good
  defp classify_quality(min_bits, count) when min_bits < 120 and count > 50, do: :converged
  defp classify_quality(_min_bits, count) when count < 20, do: :incomplete
  defp classify_quality(_min_bits, _count), do: :sparse
  defp spread_ratio(min, _max) when min <= 0, do: :infinity
  defp spread_ratio(min, max), do: Float.round(max / min, 1)
  defp initial_best_distance(%{node_map: nmap}) do
    case Enum.min_by(nmap, fn {_rid, {d, _nv4, _q}} -> d end, fn -> nil end) do
      nil -> 0
      {_rid, {d, _nv4, _q}} -> d
    end
  end
end