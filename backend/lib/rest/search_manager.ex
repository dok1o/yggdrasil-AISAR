defmodule GenS.SearchManager do
  use GenServer
  import MagnetSorter.Const
  import TimeSync
  require Logger
  @typedoc "SHA-1 base type of: infohash, ids, key, file hash, metedata file hash"
  @type ihv :: <<_::160>>
  @type nid :: ihv()
  @type rid :: ihv()
  @type cid :: ihv()
  @type ihw_id :: ihv()
  @type ih :: ihv()
  @typedoc "IPv4 UDP sender address <<a,b,c,d,port::16>>, base type of: uaddr, peer, fnode, faddr, saddr, laddr"
  @type nodev4 :: <<_::48>>
  @type dht_node_entry :: {rid(), nodev4()}
  @type peer_type :: :announce | :pex | :values
  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  @compile {:inline, []}
  @ets_tables %{
    user_ihs: %{name: :user_ihs, type: :set},
    failed_ihs: %{name: :failed_ihs, type: :set},
    launched_ihs: %{name: :launched_ihs, type: :set},
    fresh_ihs: %{name: :fresh_ihs, type: :set},
    utm_cache: %{name: :utm_cache, type: :set}
  }
  for {key, %{name: name}} <- @ets_tables do
    Module.put_attribute(__MODULE__, :"ets_#{key}", name)
  end
  @sets for {_k, v} <- @ets_tables, v.type == :set, do: v.name
  @stats_tick 12_000
  @cleanup_tick 120_000
  @src_stats_tick 60_000
  @failed_ttl_s 600
  @fresh_ih_s 20
  @schedule_m %{
    cleanup: @cleanup_tick,
    sources: @src_stats_tick,
    stats: @stats_tick
  }
  @ext_ets_fetched_ihs :fetched_ihs
  @conn_metrics %{tcp: :utm_downloaded_via_tcp, utp: :utm_downloaded_via_utp}
  defstruct [
    :utm_downloaded,
    :started_at,
    :last_utm_ms,
    :source_stats
  ]
  def user_input(ih), do: GenServer.cast(__MODULE__, {:user_ih, ih})
  def md_fetched({ih, c_type, utm}, peer_type, src_stats) do
    GenServer.cast(__MODULE__, {:md_fetched, {ih, c_type, utm}, peer_type, src_stats})
  end
  def fetch_failed(ih, src_stats),
    do: GenServer.cast(__MODULE__, {:failed, ih, src_stats})
  defp init_await(), do: Process.sleep(sleep_ms())
  defp schedule(msg), do: Process.send_after(self(), msg, Map.fetch!(@schedule_m, msg))
  def init(_opts) do
    TryETS.create_many_named(@sets, :set, :public, true, true)
    st = %__MODULE__{
      utm_downloaded: 0,
      started_at: mono_ms(),
      source_stats: %{announce: {0, 0}, pex: {0, 0}, values: {0, 0}},
      last_utm_ms: mono_ms()
    }
    {:ok, st, {:continue, :startup}}
  end
  def handle_continue(:startup, st) do
    case KeyStorageSync.ready_for_utm_download?() do
      false ->
        init_await()
        {:noreply, st, {:continue, :startup}}
      true ->
        Enum.each(Map.keys(@schedule_m), &schedule/1)
        {:noreply, st}
    end
  end
  def handle_cast({:user_ih, ih}, st) do
    insert_user_ih(ih)
    {:noreply, st}
  end
  def handle_cast(
        {:md_fetched, {ih, c_type, utm}, peer_type, src_stats},
        %{last_utm_ms: last_ms, started_at: start_ms, utm_downloaded: dls} = st
      ) do
    save_tjf? = true
    Spawn.fetch_result_task({ih, utm}, now_ms(), save_tjf?)
    GenS.Metrics.increment(@conn_metrics[c_type])
    TryETS.delete(@ets_launched_ihs, ih)
    TryETS.insert(@ext_ets_fetched_ihs, {ih, MathSync.s_prefix(ih)})
    TryETS.insert(@ets_fresh_ihs, {ih, expires_in(@fresh_ih_s)})
    new_dls = dls + 1
    now_ms = mono_ms()
    if MathSync.rolled?(1, 10) do
      log_fetch_interval(start_ms, last_ms, now_ms, new_dls)
    end
    merged_stats =
      Enum.reduce(src_stats, st.source_stats, fn {src, {s, f}}, acc ->
        Map.update(acc, src, {s, f}, fn {os, of} -> {os + s, of + f} end)
      end)
    new_stats = Map.update(merged_stats, peer_type, {1, 0}, fn {s, f} -> {s + 1, f} end)
    new_st = %{
      st
      | utm_downloaded: new_dls,
        source_stats: new_stats,
        last_utm_ms: now_ms
    }
    {:noreply, new_st}
  end
  def handle_cast({:failed, ih, src_stats}, st) do
    TryETS.delete(@ets_launched_ihs, ih)
    maybe_insert_failed(ih)
    new_stats =
      Enum.reduce(src_stats, st.source_stats, fn {src, {s, f}}, acc ->
        Map.update(acc, src, {s, f}, fn {os, of} -> {os + s, of + f} end)
      end)
    {:noreply, %{st | source_stats: new_stats}}
  end
  def handle_info(:stats, st) do
    log_stats()
    no_reply_schedule(st, :stats)
  end
  def handle_info(:cleanup, st) do
    cleanup_expired()
    no_reply_schedule(st, :cleanup)
  end
  def handle_info(:sources, st) do
    log_sources(st)
    no_reply_schedule(st, :sources)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp insert_user_ih(ih) do
    Logger.info("[SearchManager] User requested magnet #{PrinterSync.short_hex(ih)}")
    TryETS.insert(@ets_user_ihs, {ih})
    peers = ETSLookup.peers(ih)
    spawn_user_worker(ih, peers)
  end
  defp spawn_user_worker(ih, peers) do
    TryETS.insert(@ets_launched_ihs, {ih, self(), now()})
    work_id = WorkerIDSync.create_work_id(ih)
    sources = Map.new(peers, &{&1, :values})
    case Spv.InfohashWorkerSup.start_worker({ih, work_id, peers, sources, _ann_worker? = false}) do
      {:ok, pid} ->
        TryETS.insert(@ets_launched_ihs, {ih, pid, now()})
      {:error, r} ->
        TryETS.delete(@ets_launched_ihs, ih)
        Logger.error("[SearchManager] User worker spawn failed: #{inspect(r)}")
    end
  end
  defp cleanup_expired() do
    now_ts = now()
    :ets.select_delete(@ets_failed_ihs, [{{:"$1", :"$2"}, [{:<, :"$2", now_ts}], [true]}])
    :ets.select_delete(@ets_fresh_ihs, [
      {{:"$1", :"$2"}, [{:<, :"$2", now_ts}], [true]}
    ])
    :ets.select_delete(@ets_launched_ihs, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now_ts - 300}], [true]}
    ])
  end
  defp log_fetch_interval(start, _last, now, count) do
    total_ms = max(1, now - start)
    f_per_min = Float.round(count / total_ms * 60_000, 2)
    Logger.info("[SearchManager] ut_metadata downloads: #{count}, speed: #{f_per_min}/min")
  end
  defp log_stats() do
    Logger.info(
      "[SearchManager] fetched: #{TryETS.size(@ext_ets_fetched_ihs)}, failed: #{TryETS.size(@ets_failed_ihs)}, fresh #{TryETS.size(@ets_fresh_ihs)}"
    )
  end
  defp log_sources(st) do
    lines =
      Enum.map([:announce, :pex, :values], fn src ->
        {s, f} = Map.get(st.source_stats, src, {0, 0})
        total = s + f
        rate = if total > 0, do: Float.round(s / total * 100, 2), else: 0.0
        "#{src}: #{s}/#{total} (#{rate}%)"
      end)
    Logger.info("[SearchManager] Sources: #{Enum.join(lines, ", ")}")
  end
  defp maybe_insert_failed(ih) do
    cond do
      TryETS.member?(@ext_ets_fetched_ihs, ih) -> :noop
      TryETS.member?(@ets_failed_ihs, ih) -> :noop
      true -> TryETS.insert(@ets_failed_ihs, {ih, expires_in(@failed_ttl_s)})
    end
  end
end