defmodule GenS.InfohashWorkerPool do
  use GenServer
  import MagnetSorter.Const
  import TimeSync
  require Logger
  @max_workers infohash_workers()
  @ets_sorted_unv :sorted_unv
  @ets_sorted_unv_idx :sorted_unv_idx
  @ets_announce_queue :announce_queue
  @ets_announce_idx :announce_idx
  @clock 330
  @reconcile_tick 15_000
  @soft_grace_ms 2_000
  @stats_tick 15_000
  @reboot_ms 30_000
  @spawn_peer_limit 32
  @log_spawn_thr floor(@max_workers * 1.5)
  defstruct [
    :slots_ref,
    crawling?: false,
    workers: %{},
    pending_soft: %{},
    stats: %{
      total_spawned: 0,
      natural_exits: 0,
      soft_terminates: 0,
      hard_terminates: 0
    },
    spawns: 0
  ]
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def reboot_workers(), do: GenServer.call(__MODULE__, :reboot_workers, @reboot_ms)
  def work_available(), do: GenServer.cast(__MODULE__, :work_available)
  def get_stats(), do: GenServer.call(__MODULE__, :get_stats)
  def enable_crawling(), do: GenServer.cast(__MODULE__, :crawl_on)
  defp init_await(), do: Process.sleep(sleep_ms())
  defp schedule(:tick), do: Process.send_after(self(), :tick, @clock)
  defp schedule(:reconcile), do: Process.send_after(self(), :reconcile, @reconcile_tick)
  defp schedule(:stats), do: Process.send_after(self(), :stats, @stats_tick)
  def init(_opts) do
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, 1, @max_workers)
    {:ok, %__MODULE__{slots_ref: ref}, {:continue, :startup}}
  end
  def handle_continue(:startup, st) do
    case KeyStorageSync.ready_for_utm_download?() do
      false ->
        init_await()
        {:noreply, st, {:continue, :startup}}
      true ->
        case KeyStorageSync.do_crawl?() do
          false ->
            {:noreply, st}
          true ->
            new_st = %{st | crawling?: true}
            do_enable_crawl(new_st)
        end
    end
  end
  def handle_call(:get_stats, _from, st) do
    stats =
      Map.merge(st.stats, %{
        active_workers: map_size(st.workers),
        available_slots: :atomics.get(st.slots_ref, 1),
        pending_soft: map_size(st.pending_soft)
      })
    {:reply, stats, st}
  end
  def handle_call(:reboot_workers, _from, st) do
    t0 = mono_ms()
    children = Supervisor.which_children(Spv.InfohashWorkerSup)
    Enum.each(children, fn {_, pid, _, _} ->
      if is_pid(pid), do: send(pid, :soft_terminate)
    end)
    init_await()
    Enum.each(children, fn {id, pid, _, _} ->
      if is_pid(pid) and Process.alive?(pid) do
        Supervisor.terminate_child(Spv.InfohashWorkerSup, id)
      end
    end)
    t1 = mono_ms()
    kill_duration = t1 - t0
    Logger.warning("[IHWP] Reboot: Killed all workers in #{kill_duration}ms")
    {:reply, {:ok, kill_duration}, %{st | spawns: 0}}
  end
  def handle_cast(:work_available, st) do
    {:noreply, try_spawn_one(st)}
  end
  def handle_cast(:crawl_on, %{crawling?: false} = st) do
    new_st = %{st | crawling?: true}
    do_enable_crawl(new_st)
  end
  def handle_cast(:crawl_on, st), do: {:noreply, st}
  def handle_info(:tick, st) do
    now = mono_ms()
    st
    |> send_soft_terminates(now)
    |> enforce_hard_deadlines(now)
    |> no_reply_schedule(:tick)
  end
  def handle_info({:DOWN, ref, :process, _pid, reason}, st) do
    case Map.pop(st.workers, ref) do
      {nil, _} ->
        {:noreply, st}
      {info, remaining_workers} ->
        pending = Map.delete(st.pending_soft, ref)
        new_stats = record_exit(st.stats, info, reason)
        :atomics.add(st.slots_ref, 1, 1)
        new_st = %{st | workers: remaining_workers, pending_soft: pending, stats: new_stats}
        {:noreply, try_spawn_one(new_st)}
    end
  end
  def handle_info(:reconcile, st) do
    slots = available_slots(st)
    st
    |> reconcile_slots()
    |> try_spawn_batch(slots)
    |> no_reply_schedule(:reconcile)
  end
  def handle_info(:stats, st) do
    log_stats(st)
    no_reply_schedule(st, :stats)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp do_enable_crawl(st) do
    schedule(:reconcile)
    schedule(:stats)
    st
    |> try_spawn_batch(available_slots(st))
    |> no_reply_schedule(:tick)
  end
  defp send_soft_terminates(st, now) do
    {to_soft, _ok} =
      Enum.split_with(st.workers, fn {ref, info} ->
        now >= info.soft_deadline and not Map.has_key?(st.pending_soft, ref)
      end)
    new_pending =
      Enum.reduce(to_soft, st.pending_soft, fn {ref, info}, acc ->
        send(info.pid, :soft_terminate)
        Logger.debug(
          "[Worker Pool] Soft terminate sent: #{PrinterSync.short_hex(info.ih)} " <>
            "after #{format_duration(now - info.started_at)}"
        )
        Map.put(acc, ref, now)
      end)
    %{st | pending_soft: new_pending}
  end
  defp enforce_hard_deadlines(st, now) do
    {overdue, _ok} =
      Enum.split_with(st.workers, fn {_ref, info} ->
        now >= info.hard_deadline
      end)
    Enum.each(overdue, fn {ref, info} ->
      Process.demonitor(ref, [:flush])
      lived_ms = now - info.started_at
      expected_ms = worker_lifespan_s() * 1000
      case DynamicSupervisor.terminate_child(Spv.InfohashWorkerSup, info.pid) do
        :ok ->
          Logger.warning(
            "[Worker Pool] HARD TERMINATE: #{PrinterSync.short_hex(info.ih)} | " <>
              "lived: #{format_duration(lived_ms)} | " <>
              "expected: #{format_duration(expected_ms)} | " <>
              "overtime: +#{format_duration(lived_ms - expected_ms)}"
          )
        {:error, :not_found} ->
          :ok
      end
      :atomics.add(st.slots_ref, 1, 1)
    end)
    hard_count = length(overdue)
    new_stats = Map.update!(st.stats, :hard_terminates, &(&1 + hard_count))
    overdue_refs = MapSet.new(overdue, fn {ref, _} -> ref end)
    %{
      st
      | workers: Map.reject(st.workers, fn {ref, _} -> MapSet.member?(overdue_refs, ref) end),
        pending_soft:
          Map.reject(st.pending_soft, fn {ref, _} -> MapSet.member?(overdue_refs, ref) end),
        stats: new_stats
    }
  end
  defp try_spawn_batch(st, 0), do: st
  defp try_spawn_batch(st, count) do
    Enum.reduce(1..count, st, fn _, acc -> try_spawn_one(acc) end)
  end
  defp try_spawn_one(st) do
    case acquire_slot(st.slots_ref) do
      {:error, :no_slots} ->
        st
      :ok ->
        case pull_next_work() do
          nil ->
            release_slot(st.slots_ref)
            st
          {ih, peers, ann_worker?} ->
            spawn_and_track(st, ih, peers, ann_worker?)
        end
    end
  end
  defp spawn_and_track(st, ih, peers, ann_worker?) do
    now = mono_ms()
    lifespan_ms = worker_lifespan_s() * 1_000 + 1_000
    work_id = WorkerIDSync.create_work_id(ih)
    sources = Map.new(peers, &{&1, :values})
    case Spv.InfohashWorkerSup.start_worker({ih, work_id, peers, sources, ann_worker?}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        worker_info = %{
          pid: pid,
          ih: ih,
          started_at: now,
          soft_deadline: now + lifespan_ms,
          hard_deadline: now + lifespan_ms + @soft_grace_ms,
          ann_worker?: ann_worker?
        }
        new_stats = Map.update!(st.stats, :total_spawned, &(&1 + 1))
        %{
          st
          | workers: Map.put(st.workers, ref, worker_info),
            stats: new_stats,
            spawns: st.spawns + 1
        }
      {:error, reason} ->
        Logger.warning("[Worker Pool] Spawn failed: #{inspect(reason)}")
        release_slot(st.slots_ref)
        st
    end
  end
  defp acquire_slot(ref) do
    case :atomics.sub_get(ref, 1, 1) do
      n when n >= 0 ->
        :ok
      _ ->
        :atomics.add(ref, 1, 1)
        {:error, :no_slots}
    end
  end
  defp release_slot(ref), do: :atomics.add(ref, 1, 1)
  defp available_slots(st), do: :atomics.get(st.slots_ref, 1)
  defp reconcile_slots(st) do
    actual_count = map_size(st.workers)
    expected_available = @max_workers - actual_count
    current_available = :atomics.get(st.slots_ref, 1)
    if current_available != expected_available do
      :atomics.put(st.slots_ref, 1, expected_available)
      Logger.warning(
        "[Worker Pool] Slot drift corrected: #{current_available} -> #{expected_available} " <>
          "(#{actual_count} active workers)"
      )
    end
    st
  end
  defp pull_next_work() do
    case pull_announce() do
      nil -> pull_sorted()
      work -> work
    end
  end
  defp pull_announce() do
    now_ts = now()
    case :ets.first(@ets_announce_queue) do
      :"$end_of_table" ->
        nil
      idx ->
        case :ets.take(@ets_announce_queue, idx) do
          [{^idx, ih, peer, ttl}] when ttl >= now_ts ->
            :ets.match_delete(@ets_announce_idx, {ih, idx})
            if ETSLookup.new_infohash?(ih) do
              peers = gather_peers(ih, [peer])
              {ih, peers, true}
            else
              pull_announce()
            end
          _ ->
            pull_announce()
        end
    end
  end
  defp pull_sorted() do
    now_ts = now()
    case :ets.first(@ets_sorted_unv) do
      :"$end_of_table" ->
        nil
      key ->
        case :ets.take(@ets_sorted_unv, key) do
          [{_sort_key, ih, peers, ttl}] when ttl >= now_ts ->
            TryETS.delete(@ets_sorted_unv_idx, ih)
            if ETSLookup.new_infohash?(ih) do
              refreshed = gather_peers(ih, peers)
              {ih, refreshed, false}
            else
              pull_sorted()
            end
          [{_sort_key, ih, _peers, _ttl}] ->
            TryETS.delete(@ets_sorted_unv_idx, ih)
            pull_sorted()
          [] ->
            pull_sorted()
        end
    end
  end
  defp gather_peers(ih, existing) do
    (existing ++ ETSLookup.unv_peers(ih))
    |> Enum.uniq()
    |> GenS.PeerManager.filter_peers()
    |> Enum.take(@spawn_peer_limit)
  end
  defp record_exit(stats, _info, reason) do
    case reason do
      :normal ->
        Map.update!(stats, :natural_exits, &(&1 + 1))
      :shutdown ->
        Map.update!(stats, :soft_terminates, &(&1 + 1))
      {:shutdown, _} ->
        Map.update!(stats, :soft_terminates, &(&1 + 1))
      _other ->
        Map.update!(stats, :natural_exits, &(&1 + 1))
    end
  end
  defp log_stats(st) do
    s = st.stats
    active = map_size(st.workers)
    _slots = :atomics.get(st.slots_ref, 1)
    soft_rate =
      if s.total_spawned > 0,
        do: Float.round(s.soft_terminates / s.total_spawned * 100, 2),
        else: 0.0
    hard_rate =
      if s.total_spawned > 0,
        do: Float.round(s.hard_terminates / s.total_spawned * 100, 2),
        else: 0.0
    Logger.info(
      "[Worker Pool] active: #{active}/#{@max_workers} | " <>
        "spawned: #{s.total_spawned} | " <>
        "exits: ok: #{s.natural_exits}, soft: #{s.soft_terminates} (#{soft_rate}%), " <>
        "hard: #{s.hard_terminates} (#{hard_rate}%)"
    )
    if s.hard_terminates > 0 do
      Logger.warning("[Worker Pool] #{s.hard_terminates} hard terminates indicate stuck workers")
    end
    rate_min = div(st.spawns, div(60_000, @stats_tick))
    if st.spawns > @log_spawn_thr do
      Logger.info(
        "[Worker Pool] infohash worker spawn speed: #{rate_min}/min (max #{@max_workers})"
      )
    end
  end
  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"
end