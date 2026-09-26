defmodule GenS.KRPCPayloadFactory do
  use GenServer
  import MagnetSorter.Const
  import PFProtocol
  require Logger
  @typedoc "20b SHA-1 base value: remote node_id, infohash, other"
  @type ihv :: <<_::160>>
  @type nid :: ihv()
  @type rid :: ihv()
  @type ih :: ihv()
  @type tid :: <<_::16>>
  @type nodev4 :: <<_::48>>
  @salt_closest_count 4
  @max_samples 20
  @ext_ets_fetched_ihs :fetched_ihs
  @wnd_30s_samples_bootstrap 30
  @wnd30 @wnd_30s_samples_bootstrap
  @dht_bytes 20
  @pr_len samples_prefix_length()
  @rem_len @dht_bytes - @pr_len
  def start_link(o \\ []), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def find_node(ihv, nodev4, nid, tid, shard_id) do
    GenServer.cast(__MODULE__, {:find_node, ihv, nodev4, nid, tid, shard_id})
  end
  def get_peers(ih, nodev4, token, nid, tid, shard_id) do
    GenServer.cast(__MODULE__, {:get_peers, ih, nodev4, token, nid, tid, shard_id})
  end
  def sample_infohashes(ihv, nodev4, nid, tid, shard_id) do
    GenServer.cast(__MODULE__, {:sample_infohashes, ihv, nodev4, nid, tid, shard_id})
  end
  def init(_opts) do
    st = %{}
    {:ok, st}
  end
  def handle_cast({:find_node, ihv, nodev4, nid, tid, shard_id}, st) do
    case ETSLookup.closest_nodes(ihv) do
      [] ->
        :noop
      nodes ->
        packed = KRPCUtilsSync.pack_nodes(nodes)
        reply_packet = WireSync.find_node_reply(nid, packed, tid)
        KRPCUtilsSync.send_packet(shard_id, nodev4, reply_packet)
    end
    {:noreply, st}
  end
  def handle_cast({:get_peers, ih, nodev4, token, nid, tid, shard_id}, st) do
    case ETSLookup.peers_or_nodes(ih) do
      {:nodes, nodes} ->
        packed = KRPCUtilsSync.pack_nodes(nodes)
        reply_packet = WireSync.get_peers_reply_nodes(nid, token, packed, tid)
        KRPCUtilsSync.send_packet(shard_id, nodev4, reply_packet)
        GenS.MainlineOutgoing.get_peers_n(ih)
      {:values, peers} ->
        reply_packet = WireSync.get_peers_reply_values(nid, token, peers, ih, tid)
        KRPCUtilsSync.send_packet(shard_id, nodev4, reply_packet)
        GenS.Metrics.increment(:gp_replies)
    end
    {:noreply, st}
  end
  def handle_cast({:sample_infohashes, ihv, nodev4, nid, tid, shard_id}, st) do
    prepare_send_samples(ihv, nodev4, nid, tid, shard_id)
    {:noreply, st}
  end
  defp prepare_send_samples(ihv, nodev4, nid, tid, shard_id) do
    <<ihv_prefix::binary-size(@pr_len), _rest1::binary-size(@rem_len)>> = ihv
    mask = generate_salt_mask(@wnd30)
    selected_ihs =
      @ext_ets_fetched_ihs
      |> :ets.match_object({:_, ihv_prefix})
      |> Enum.map(fn {ih, _ih_prefix} -> ih end)
    cnt = length(selected_ihs)
    cond do
      cnt < @max_samples ->
        send_samples_reply(selected_ihs, nid, tid, cnt, nodev4, shard_id)
      true ->
        samples = select_samples(selected_ihs, ihv, mask)
        send_samples_reply(samples, nid, tid, cnt, nodev4, shard_id)
    end
  end
  defp select_samples(selected_ihs, ihv, mask) do
    closest =
      selected_ihs
      |> Enum.sort_by(&MathSync.xor_distance(mask, &1))
      |> Enum.take(@salt_closest_count)
    remaining =
      selected_ihs
      |> Enum.reject(fn ih -> ih in closest end)
      |> Enum.shuffle()
      |> Enum.take(@max_samples - @salt_closest_count)
    (closest ++ remaining)
    |> Enum.sort_by(&MathSync.xor_distance(ihv, &1))
  end
  defp send_samples_reply(samples, nid, tid, cnt, nodev4, shard_id) do
    packed = Enum.join(samples)
    reply = WireSync.sample_infohashes_reply(nid, tid, cnt, packed, nil)
    KRPCUtilsSync.send_packet(shard_id, nodev4, reply)
  end
end