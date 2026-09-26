defmodule GenS.PeerManager do
  use GenServer
  import TimeSync
  require Logger
  @compile {:inline, []}
  @typedoc "20b SHA-1 base value: remote node_id, infohash, other"
  @type ihv :: <<_::160>>
  @type ih :: ihv()
  @typedoc "IPv4 node: 4 bytes for IPv4 address, 2 bytes for port as <<a,b,c,d,port::16>>"
  @type nodev4 :: <<_::48>>
  @type peer :: nodev4()
  @ets_peers :peers
  @ets_unv_peers :unv_peers
  @ets_fetched_ihs :fetched_ihs
  @ets_dht_blacklist :dht_blacklist
  @ets_failed_peers :failed_peers
  @ets_peer_source :peer_source
  @ets_peer_info :peer_info
  @ets_watched_peer_type :watched_peer_type
  @cleanup_thr_blacklist 128
  @cleanup_thr_failed 1_024 * 2
  @max_unv_peers 1_024 * 128
  @max_peers 1_024 * 1_024 * 2
  @load_from_db_limit @max_peers
  @clock 10_000
  @cleanup_tick 30_000
  defstruct ver_idx: 0,
            unv_idx: 0,
            peer_info_idx: 0
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def max_unv_peers(), do: @max_unv_peers
  def record_unv_peers(ih, peers, src_nodev4),
    do: GenServer.cast(__MODULE__, {:record_unv, ih, peers, src_nodev4})
  def good_peer(ih, peer, opts \\ %{}),
    do: GenServer.cast(__MODULE__, {:good_peer, ih, peer, opts})
  def failed_peer(peer, reason), do: GenServer.cast(__MODULE__, {:failed_peer, peer, reason})
  def filter_peers(peers), do: Enum.reject(peers, &reject_peer?/1)
  def watch_peer(peer, type), do: maybe_watch_peer(peer, type)
  def take_unv_peers(ih) do
    @ets_unv_peers
    |> CBuffer.take_by_key(ih)
    |> Enum.map(fn {_idx, _ih, peer} -> peer end)
  end
  defp schedule(:cleanup), do: Process.send_after(self(), :cleanup, @cleanup_tick)
  defp schedule(:tick), do: Process.send_after(self(), :tick, @clock)
  def init(_opts) do
    create_cb_tables()
    create_tables()
    st = %__MODULE__{}
    {:ok, st, {:continue, :load_from_db}}
  end
  defp create_cb_tables() do
    circular_buffers = [@ets_unv_peers, @ets_peers]
    TryETS.create_many_named(circular_buffers, :set, :public, true, true)
  end
  defp create_tables() do
    sets = [
      @ets_fetched_ihs,
      @ets_dht_blacklist,
      @ets_failed_peers,
      @ets_peer_info,
      @ets_watched_peer_type
    ]
    bags = [
      @ets_peer_source,
      CBuffer.idx_tab(@ets_peers),
      CBuffer.idx_tab(@ets_unv_peers)
    ]
    TryETS.create_many_named(sets, :set, :public, true, true)
    TryETS.create_many_named(bags, :bag, :public, true, true)
  end
  def handle_continue(:load_from_db, st) do
    new_st = try_load_peers_and_infohashes(st)
    KeyStorageSync.set_peer_mgr_ready()
    schedule(:tick)
    schedule(:cleanup)
    {:noreply, new_st}
  end
  defp try_load_peers_and_infohashes(st) do
    try do
      start_time = mono_ms()
      %{rows: rows} = MagnetSorter.Store.load_peers_and_infohashes(@load_from_db_limit)
      {final_st, peer_counts, ih_count} = loading_logic(st, rows)
      insert_peer_info(peer_counts)
      KeyStorageSync.set_known_ihs(ih_count)
      elapsed = mono_ms() - start_time
      Logger.info(
        "=== [PeerManager] DB loaded in #{elapsed}ms: #{ih_count} infohashes, #{map_size(peer_counts)} peers ==="
      )
      final_st
    rescue
      e ->
        Logger.warning("=== [PeerManager] DB load failed: #{inspect(e)} ===")
        st
    end
  end
  defp loading_logic(st, rows) do
    rows
    |> Stream.map(fn [infohash, blob] -> {infohash, blob} end)
    |> Enum.reduce({st, %{}, 0}, fn {ih, blob}, {acc_st, peer_acc, ih_acc} ->
      TryETS.insert(@ets_fetched_ihs, {ih, MathSync.s_prefix(ih)})
      peers = unpack_peers_blob(blob)
      new_st =
        Enum.reduce(peers, acc_st, fn peer, s ->
          insert_ver_peer(s, ih, peer)
        end)
      new_peer_counts =
        Enum.reduce(peers, peer_acc, fn peer, counts ->
          Map.update(counts, peer, 1, &(&1 + 1))
        end)
      {new_st, new_peer_counts, ih_acc + 1}
    end)
  end
  defp insert_peer_info(peer_counts) do
    peer_info_entries =
      Enum.map(peer_counts, fn {peer, count} ->
        {peer, count, now()}
      end)
    TryETS.insert(@ets_peer_info, peer_info_entries)
  end
  def handle_cast({:record_unv, ih, peers, src_nodev4}, st) do
    case ETSLookup.new_infohash?(ih) do
      false ->
        {:noreply, st}
      true ->
        new_st = process_unv(st, ih, peers, src_nodev4)
        {:noreply, new_st}
    end
  end
  def handle_cast({:good_peer, ih, peer, _opts}, st) do
    process_peer(ih, peer)
    new_st = insert_ver_peer(st, ih, peer)
    {:noreply, new_st}
  end
  def handle_cast({:failed_peer, peer, reason}, st) do
    GenS.ConnectionsOut.record_failure(peer, reason)
    ttl_s = failure_ttl(reason)
    TryETS.insert(@ets_failed_peers, {peer, expires_in(ttl_s)})
    {:noreply, st}
  end
  def handle_info(:tick, st) do
    log_tables()
    no_reply_schedule(st, :tick)
  end
  def handle_info(:cleanup, st) do
    cleanup_sources()
    maybe_expire(@ets_dht_blacklist, @cleanup_thr_blacklist)
    maybe_expire(@ets_failed_peers, @cleanup_thr_failed)
    no_reply_schedule(st, :cleanup)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp process_peer(ih, peer) do
    GenS.ConnectionsOut.trust_peer(peer)
    record_peer_success(peer)
    GenS.SQLiteBatcher.resync_peer(ih, peer)
    TryETS.delete(@ets_failed_peers, peer)
  end
  defp process_unv(st, ih, peers, src_nodev4) do
    GenS.InfohashCollector.resync(ih)
    Enum.reduce(peers, st, fn peer, acc_st ->
      case reject_peer?(peer) do
        true ->
          acc_st
        false ->
          TryETS.insert(@ets_peer_source, {peer, src_nodev4})
          insert_unv_peer(acc_st, ih, peer)
      end
    end)
  end
  defp record_peer_success(peer) do
    now_ts = now()
    case TryETS.lookup(@ets_peer_info, peer) do
      [{^peer, o_utm, _o_ts}] -> TryETS.insert(@ets_peer_info, {peer, o_utm + 1, now_ts})
      [] -> TryETS.insert(@ets_peer_info, {peer, 1, now_ts})
    end
  end
  defp failure_ttl(reason) do
    case reason do
      :crawler -> 300
      :data -> 30
      :firewall -> 15
      :timeout -> 15
    end
  end
  defp insert_unv_peer(%{unv_idx: idx} = st, ih, peer) do
    new_idx = CBuffer.insert(@ets_unv_peers, idx, {ih, peer}, @max_unv_peers)
    %{st | unv_idx: new_idx}
  end
  defp insert_ver_peer(%{ver_idx: idx} = st, ih, peer) do
    new_idx = CBuffer.insert(@ets_peers, idx, {ih, peer}, @max_peers)
    %{st | ver_idx: new_idx}
  end
  defp maybe_expire(table, min_size) do
    if TryETS.size(table) >= min_size do
      TryETS.tab2list(table)
      |> Enum.each(fn {key, ttl} -> if expired?(ttl), do: TryETS.delete(table, key) end)
    end
  end
  defp cleanup_sources() do
    max_size = @max_unv_peers * 2
    size = TryETS.size(@ets_peer_source)
    if size > max_size do
      to_delete = size - @max_unv_peers
      @ets_peer_source
      |> TryETS.tab2list()
      |> Enum.take_random(to_delete)
      |> Enum.each(fn {peer, _src_nodev4} -> TryETS.delete(@ets_peer_source, peer) end)
    end
  end
  defp reject_peer?(peer) do
    active_in_table?(@ets_dht_blacklist, peer) or
      active_in_table?(@ets_failed_peers, peer)
  end
  defp active_in_table?(table, peer) do
    case TryETS.lookup(table, peer) do
      [{^peer, ttl}] -> not expired?(ttl)
      [] -> false
    end
  end
  defp unpack_peers_blob(nil), do: []
  defp unpack_peers_blob(blob) when byte_size(blob) < 6, do: []
  defp unpack_peers_blob(blob), do: for(<<peer::binary-6 <- blob>>, do: peer)
  def maybe_watch_peer(peer, :announce),
    do: TryETS.insert(@ets_watched_peer_type, {peer, :announce})
  def maybe_watch_peer(peer, :pex), do: TryETS.insert(@ets_watched_peer_type, {peer, :pex})
  def maybe_watch_peer(_peer, _type), do: :noop
  defp log_tables() do
    ver = TryETS.size(@ets_peers)
    unv = TryETS.size(@ets_unv_peers)
    info = TryETS.size(@ets_peer_info)
    failed = TryETS.size(@ets_failed_peers)
    Logger.info(
      "[PeerManager] ver_cb: #{ver}, unv_cb: #{unv}, peer_info: #{info}, failed: #{failed}"
    )
  end
end