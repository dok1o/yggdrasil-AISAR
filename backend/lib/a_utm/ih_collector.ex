defmodule GenS.InfohashCollector do
  use GenServer
  import MagnetSorter.Const
  import TimeSync
  require Logger
  @clock 330
  @ets_prepared_unv :prepared_to_fetch
  @ets_prepared_idx :prepared_idx
  @ets_sorted_unv :sorted_unv
  @ets_sorted_unv_idx :sorted_unv_idx
  @ets_announce_queue :announce_queue
  @ets_announce_idx :announce_idx
  @announce_ttl_s 30
  @ih_fresh_ttl_s 120
  @max_prepared 1_024 * 64
  @max_announces 1_024 * 32
  @max_peers_per_ih 256
  @log_interval 40
  @batch_sort infohash_workers() * 4
  defstruct announce_idx: 0,
            prepared_idx: 0,
            pending_unv: MapSet.new(),
            tick_count: 0,
            last_drain_ms: 0,
            last_drain_count: 0
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def resync(ih), do: GenServer.cast(__MODULE__, {:resync_ih, ih})
  def announce(ih, peer), do: GenServer.cast(__MODULE__, {:announce, ih, peer})
  defp init_await(), do: Process.sleep(sleep_ms())
  defp schedule(:tick), do: Process.send_after(self(), :tick, @clock)
  def init(_opts) do
    sets = [@ets_prepared_unv, @ets_announce_queue, @ets_sorted_unv_idx, @ets_prepared_idx]
    TryETS.create_many_named(sets, :set, :public, true, true)
    TryETS.create_named(@ets_sorted_unv, :ordered_set, :public, true, true)
    TryETS.create_named(@ets_announce_idx, :bag, :public, true, true)
    st = %__MODULE__{}
    {:ok, st, {:continue, :startup}}
  end
  def handle_continue(:startup, st) do
    case KeyStorageSync.ready_for_preparing_utm_candidates?() do
      false ->
        init_await()
        {:noreply, st, {:continue, :startup}}
      true ->
        KeyStorageSync.set_utm_candidates_prepared()
        schedule(:tick)
        {:noreply, st}
    end
  end
  def handle_cast({:resync_ih, ih}, %{pending_unv: p_unv} = st) do
    {:noreply, %{st | pending_unv: MapSet.put(p_unv, ih)}}
  end
  def handle_cast({:announce, ih, peer}, %{announce_idx: idx} = st) do
    GenS.IHWorkerRouter.find(ih, [peer], peer, :announce)
    case TryETS.lookup(@ets_announce_queue, idx) do
      [{^idx, old_ih, _peer, _ttl}] -> :ets.match_delete(@ets_announce_idx, {old_ih, idx})
      [] -> :noop
    end
    TryETS.insert(@ets_announce_queue, {idx, ih, peer, now() + @announce_ttl_s})
    TryETS.insert(@ets_announce_idx, {ih, idx})
    {:noreply, %{st | announce_idx: rem(idx + 1, @max_announces)}}
  end
  def handle_info(:tick, %{pending_unv: pending, tick_count: tc} = st) do
    start = mono_ms()
    st1 = prepare_pending(st, pending)
    promote_to_sorted(@batch_sort)
    clean_expired_announces()
    clean_expired_sorted()
    _elapsed = mono_ms() - start
    new_tc = tc + 1
    if rem(new_tc, @log_interval) == 0, do: log_stats()
    new_st = %{st1 | pending_unv: MapSet.new(), tick_count: new_tc}
    no_reply_schedule(new_st, :tick)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp prepare_pending(st, pending) do
    Enum.reduce(pending, st, fn ih, acc_st ->
      case ETSLookup.new_infohash?(ih) do
        false -> acc_st
        true -> prepare_one(acc_st, ih)
      end
    end)
  end
  defp prepare_one(st, ih) do
    peers = GenS.PeerManager.take_unv_peers(ih)
    filtered = GenS.PeerManager.filter_peers(peers)
    case filtered do
      [] ->
        remove_from_prepared(ih)
        st
      peers ->
        capped = Enum.take(peers, @max_peers_per_ih)
        insert_prepared(st, ih, capped)
    end
  end
  defp insert_prepared(%{prepared_idx: idx} = st, ih, peers) do
    case TryETS.lookup(@ets_prepared_idx, ih) do
      [{^ih, existing_idx}] ->
        case TryETS.lookup(@ets_prepared_unv, existing_idx) do
          [{^existing_idx, ^ih, _old_cnt, old_peers}] ->
            merged = Enum.uniq(old_peers ++ peers) |> Enum.take(@max_peers_per_ih)
            TryETS.insert(@ets_prepared_unv, {existing_idx, ih, length(merged), merged})
          [{^existing_idx, _other_ih, _old_cnt, _old_peers}] ->
            TryETS.delete(@ets_prepared_idx, ih)
            TryETS.delete(@ets_prepared_unv, existing_idx)
            :noop
          [] ->
            :noop
        end
        st
      [] ->
        case TryETS.lookup(@ets_prepared_unv, idx) do
          [{_idx, old_ih, _cnt, _peers}] ->
            TryETS.delete(@ets_prepared_idx, old_ih)
          [] ->
            :noop
        end
        if !TryETS.member?(@ets_prepared_idx, ih) do
          GenS.Metrics.increment(:infohash)
        end
        TryETS.insert(@ets_prepared_unv, {idx, ih, length(peers), peers})
        TryETS.insert(@ets_prepared_idx, {ih, idx})
        %{st | prepared_idx: rem(idx + 1, @max_prepared)}
    end
  end
  defp remove_from_prepared(ih) do
    case TryETS.lookup(@ets_prepared_idx, ih) do
      [{^ih, idx}] ->
        TryETS.delete(@ets_prepared_unv, idx)
        TryETS.delete(@ets_prepared_idx, ih)
      [] ->
        :noop
    end
  end
  defp promote_to_sorted(batch_size) do
    own_ip = KeyStorageSync.own_ip()
    candidates = take_from_prepared_for_sorting(batch_size)
    Enum.each(candidates, fn {ih, peers} ->
      score_and_insert_sorted(ih, peers, own_ip)
    end)
  end
  defp take_from_prepared_for_sorting(count) do
    @ets_prepared_unv
    |> TryETS.tab2list()
    |> Enum.filter(fn {_idx, ih, _cnt, _peers} ->
      ETSLookup.new_infohash?(ih)
    end)
    |> Enum.take(count)
    |> Enum.map(fn {idx, ih, _cnt, peers} ->
      TryETS.delete(@ets_prepared_unv, idx)
      TryETS.delete(@ets_prepared_idx, ih)
      {ih, peers}
    end)
  end
  defp score_and_insert_sorted(ih, peers, own_ip) do
    case ETSLookup.new_infohash?(ih) do
      false ->
        :noop
      true ->
        {sorted_peers, total_utms, peer_count} = score_and_sort_peers(peers, own_ip)
        delete_from_sorted(ih)
        sort_key = {-total_utms, -peer_count, ih}
        TryETS.insert(@ets_sorted_unv, {sort_key, ih, sorted_peers, expires_in(@ih_fresh_ttl_s)})
        TryETS.insert(@ets_sorted_unv_idx, {ih, sort_key})
    end
  end
  defp score_and_sort_peers(peers, own_ip) do
    scored =
      Enum.map(peers, fn peer ->
        {utm, ts} = ETSLookup.peer_info(peer)
        source_count = ETSLookup.peer_source_count(peer)
        proximity = subnet_score(peer, own_ip)
        {peer, utm, ts, source_count, proximity}
      end)
    {known, unknown} = Enum.split_with(scored, fn {_p, utm, _ts, _cnt, _prox} -> utm > 0 end)
    sorted_known = Enum.sort_by(known, fn {_p, utm, ts, _cnt, _prox} -> {-utm, -ts} end)
    sorted_unknown = Enum.sort_by(unknown, fn {_p, _utm, _ts, cnt, prox} -> {-prox, -cnt} end)
    sorted_all = sorted_known ++ sorted_unknown
    sorted_peers = Enum.map(sorted_all, fn {peer, _utm, _ts, _cnt, _prox} -> peer end)
    total_utms = Enum.sum(for {_p, utm, _ts, _cnt, _prox} <- scored, do: utm)
    {sorted_peers, total_utms, length(peers)}
  end
  defp subnet_score(<<p1, p2, p3, _p4, _port::16>>, <<o1, o2, o3, _o4>>) do
    slash24? = p3 == o3
    slash16? = p2 == o2
    slash8? = p1 == o1
    cond do
      slash24? and slash16? and slash8? -> 3
      slash16? and slash8? -> 3
      slash8? -> 2
      true -> 1
    end
  end
  defp delete_from_sorted(ih) do
    case TryETS.lookup(@ets_sorted_unv_idx, ih) do
      [{^ih, old_key}] ->
        TryETS.delete(@ets_sorted_unv, old_key)
        TryETS.delete(@ets_sorted_unv_idx, ih)
      [] ->
        :ok
    end
  end
  defp clean_expired_sorted() do
    sorted_size = TryETS.size(@ets_sorted_unv)
    if sorted_size > @batch_sort do
      now_ts = now()
      @ets_sorted_unv
      |> TryETS.tab2list()
      |> Enum.filter(fn {_sort_key, _ih, _peers, expires_at} -> expires_at < now_ts end)
      |> Enum.each(fn {sort_key, ih, _peers, _expires_at} ->
        TryETS.delete(@ets_sorted_unv, sort_key)
        TryETS.delete(@ets_sorted_unv_idx, ih)
      end)
    end
  end
  defp clean_expired_announces() do
    now_ts = now()
    @ets_announce_queue
    |> TryETS.tab2list()
    |> Enum.filter(fn {_idx, _ih, _peer, ttl} -> ttl < now_ts end)
    |> Enum.each(fn {idx, ih, peer, _ttl} ->
      TryETS.delete(@ets_announce_queue, idx)
      :ets.match_delete(@ets_announce_idx, {ih, idx})
      GenS.PeerManager.record_unv_peers(ih, [peer], peer)
    end)
  end
  defp log_stats() do
    prep_unv = TryETS.size(@ets_prepared_unv)
    sorted = TryETS.size(@ets_sorted_unv)
    announces = TryETS.size(@ets_announce_queue)
    Logger.info("[IH Collector] prep: #{prep_unv}, sorted: #{sorted}, ann: #{announces}")
  end
end