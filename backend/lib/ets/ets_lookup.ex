defmodule ETSLookup do
  import TimeSync
  require Logger
  @ets_nodes :dht_nodes
  @ets_filtered_freq :filtered_freq
  @ets_unv_peers :unv_peers
  @ets_peers :peers
  @ets_peer_info :peer_info
  @ets_peer_source :peer_source
  @ets_launched_ihs :launched_ihs
  @ets_failed_ihs :failed_ihs
  @ets_fresh_ihs :fresh_ihs
  @ets_fetched_ihs :fetched_ihs
  @ets_ih_asked :sample_ih_asked
  @closest_per_ih 3
  @nodes_per_ih @closest_per_ih + 1
  @peer_limit 32
  @ets_ih_frequent :ih_frequent
  @max_ih_frequent 1_024 * 2
  @node_limit 8
  @min_nodes 3
  def closest_nodes(ihv, count \\ @node_limit) do
    case :ets.tab2list(@ets_nodes) do
      nodes when length(nodes) <= @min_nodes ->
        []
      nodes ->
        nodes
        |> Enum.sort_by(fn {rid, _nodev4} -> MathSync.xor_distance(rid, ihv) end)
        |> Enum.take(count)
    end
  end
  @doc "Returns a list of `{ih, freq}` tuples ordered by frequency (descending)."
  def get_frequent_ihs(count \\ @max_ih_frequent) do
    :ets.foldl(fn {ih, freq}, acc -> [{ih, freq} | acc] end, [], @ets_ih_frequent)
    |> Enum.sort_by(fn {_ih, freq} -> freq end, :desc)
    |> Enum.take(count)
  end
  def get_filtered_freq(count \\ @max_ih_frequent) do
    :ets.foldl(fn {ih, freq}, acc -> [{ih, freq} | acc] end, [], @ets_filtered_freq)
    |> Enum.sort_by(fn {_ih, freq} -> freq end, :desc)
    |> Enum.take(count)
  end
  def peers_or_nodes(ih), do: get_peers_or_nodes(ih)
  def peers(ih, limit \\ @peer_limit), do: get_known_peers(ih, limit)
  def peer_info(peer), do: get_peer_info(peer)
  def peer_sources(peer), do: get_peer_sources(peer)
  def unv_peers(ih), do: get_unv_peers(ih)
  def new_infohash?(ih), do: check_ih_tables(ih)
  def fresh_ih?(ih), do: check_fresh_ih(ih)
  def peer_source_count(peer), do: get_peer_source_count(peer)
  def random_nodes(count \\ @node_limit), do: TryETS.random_select(@ets_nodes, count)
  def has_peers?(ih) do
    case TryETS.lookup(@ets_peers, ih) do
      [] -> false
      _entries -> true
    end
  end
  def samples_gp_targets(ih, ih_sources) do
    source_nodes = Map.get(ih_sources, ih, [])
    asked_recently =
      @ets_ih_asked
      |> TryETS.lookup(ih)
      |> Enum.map(fn {^ih, nodev4, _exp} -> nodev4 end)
    final_nodes =
      case length(source_nodes) < @nodes_per_ih do
        true ->
          closest =
            ETSLookup.closest_nodes(ih, @closest_per_ih + length(asked_recently))
            |> Enum.map(fn {_rid, nodev4} -> nodev4 end)
          source_nodes ++ closest
        false ->
          source_nodes
      end
    final_nodes
    |> Enum.uniq()
    |> Enum.reject(&(&1 in asked_recently))
    |> Enum.take(@nodes_per_ih)
  end
  defp check_fresh_ih(ih) do
    case TryETS.lookup(@ets_fresh_ihs, ih) do
      [{^ih, ttl_s}] -> not expired?(ttl_s)
      [] -> false
    end
  end
  defp get_peer_info(peer) do
    case TryETS.lookup(@ets_peer_info, peer) do
      [{^peer, utm, ts}] -> {utm, ts}
      [] -> {0, 0}
    end
  end
  defp get_peers_or_nodes(ih) do
    case get_known_peers(ih, @peer_limit) do
      [] ->
        nodes = ETSLookup.closest_nodes(ih)
        {:nodes, nodes}
      peers ->
        {:values, peers}
    end
  end
  defp get_peer_sources(peer) do
    @ets_peer_source
    |> TryETS.lookup(peer)
    |> Enum.map(fn {^peer, src_nodev4} -> src_nodev4 end)
  end
  defp get_peer_source_count(peer) do
    @ets_peer_source
    |> TryETS.lookup(peer)
    |> length()
  end
  defp get_unv_peers(ih) do
    @ets_unv_peers
    |> CBuffer.lookup_by_key(ih)
    |> Enum.map(fn {_idx, _ih, peer} -> peer end)
    |> Enum.uniq()
  end
  defp get_known_peers(ih, limit) do
    @ets_peers
    |> CBuffer.lookup_by_key(ih)
    |> Enum.map(fn {_idx, _ih, peer} -> peer end)
    |> Enum.uniq()
    |> Enum.take_random(limit)
  end
  defp check_ih_tables(ih) do
    not (TryETS.member?(@ets_launched_ihs, ih) or TryETS.member?(@ets_failed_ihs, ih) or
           TryETS.member?(@ets_fetched_ihs, ih))
  end
end