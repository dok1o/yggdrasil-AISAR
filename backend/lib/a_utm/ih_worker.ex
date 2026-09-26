defmodule GenS.InfohashWorker do
  use GenServer, restart: :temporary
  require Logger
  import TimeSync
  import MagnetSorter.Const
  @compile {:inline, [process?: 2]}
  @type peer_type :: :announce | :pex | :values
  @clock 330
  @requeue_tick 200
  @last_retry_wait 1_500
  @task_timeout_ms 10_000
  @dht_fn_await 200
  @exhaustion_wait 500
  @node_limit 8
  @max_requeues 4
  @max_ephemeral_nodes 128
  @peer_queue_limit 16
  @stats_freq 96
  @exploration_odds 5
  @timeouts_thr_num 6
  @timeouts_thr_den 7
  @min_timeouts_thr 16
  @requeue_errors [
    :transport_conn_limit,
    :global_conn_limit,
    :ip_cooldown,
    :peer_busy_by_other_worker
  ]
  @drop_errors [
    :rejected_blocked_ip,
    :rejected_blocked_subnet,
    :subnet_limit,
    :ip_limit
  ]
  @firewall_errors @requeue_errors ++ @drop_errors
  defstruct [
    :ih,
    :ih_int,
    :ihw_id,
    :own_ip,
    :deadline,
    :pending_exhaustion,
    :ephemeral_dht,
    ann_w?: false,
    max_slots: ih_worker_concurrent_downloads(),
    failed_peer_source_map: %{},
    peer_sources: %{},
    peers_queue: [],
    peers_tried: MapSet.new(),
    cycle: 0,
    dht_walked: false,
    stats: %{
      get_peers_sent: 0,
      last_reported_gp: 0,
      peers_found: 0,
      gp_replies_recvd: 0
    },
    active_dl: %{},
    failure_reasons: %{},
    peer_attempts: %{},
    source_stats: %{announce: {0, 0}, pex: {0, 0}, values: {0, 0}}
  ]
  def start_link({ih, ihw_id, peers, sources_map, ann_worker?}),
    do: GenServer.start_link(__MODULE__, {ih, ihw_id, peers, sources_map, ann_worker?})
  defp process?(slots, peers_queue), do: not (slots <= 0 or peers_queue == [])
  defp schedule(:peer_requeued), do: Process.send_after(self(), :peer_requeued, @requeue_tick)
  defp schedule(:tick), do: Process.send_after(self(), :tick, @clock)
  def init({<<ih_int::unsigned-big-160>> = ih, ihw_id, peers, sources_map, ann_worker?}) do
    st = %__MODULE__{
      ih: ih,
      ih_int: ih_int,
      ihw_id: ihw_id,
      ann_w?: ann_worker?,
      peers_queue: peers,
      peer_sources: sources_map,
      own_ip: KeyStorageSync.own_ip(),
      deadline: now_ms() + worker_lifespan_s() * 1_000,
      ephemeral_dht: EphemeralDHTSync.new(ih, @max_ephemeral_nodes)
    }
    {:ok, st, {:continue, :instance_bootstrap}}
  end
  def handle_continue(:instance_bootstrap, %{ih: ih, ann_w?: ann_worker?} = st) do
    incr_ih_metrics(ann_worker?)
    nodes = ETSLookup.closest_nodes(ih, @node_limit)
    new_st =
      st
      |> process_downloads()
      |> add_nodes_to_dht(nodes)
      |> query_recursive()
    tick_and_check(new_st)
  end
  def handle_info(:soft_terminate, st), do: shutdown_stop(st)
  def handle_info(:tick, %{deadline: deadline, stats: stats} = st) do
    maybe_report_gp_sent(stats.get_peers_sent, stats.last_reported_gp)
    st = put_in(st.stats.last_reported_gp, stats.get_peers_sent)
    case deadline?(deadline) do
      true -> finish(st, :worker_timeout)
      false -> tick_and_check(st)
    end
  end
  def handle_info(:peer_requeued, st) do
    st
    |> process_downloads()
    |> check_termination()
  end
  def handle_info({:nodes, nodes}, st) do
    if now_ms() > st.deadline do
      finish(st, :worker_timeout)
    else
      st
      |> add_nodes_to_dht(nodes)
      |> maybe_query_recursive()
      |> check_termination()
    end
  end
  def handle_info({:new_peers, peers, type}, st) do
    if now_ms() > st.deadline do
      finish(st, :worker_timeout)
    else
      case type == :values do
        false ->
          process_peers(st, peers, type)
        true ->
          new_st = update_in(st.stats.gp_replies_recvd, &(&1 + 1))
          process_peers(new_st, peers, :values)
      end
    end
  end
  def handle_info(
        :check_exhaustion,
        %{ih: ih, cycle: cycle, dht_walked: walked?, ephemeral_dht: dht} = st
      ) do
    st = %{st | pending_exhaustion: nil}
    conv = EphemeralDHTSync.convergence_stats(dht)
    dht_useless? = conv[:nodes_queried] > 32 and st.stats.peers_found == 0
    cond do
      EphemeralDHTSync.has_unqueried?(dht) ->
        {:noreply, query_recursive(st)}
      dht_useless? and st.peers_queue == [] ->
        finish(st, :dht_exhausted_no_peers)
      cycle < 4 ->
        new_cycle = cycle + 1
        send_find_node(ih)
        Process.send_after(self(), :reload_and_query, @dht_fn_await)
        {:noreply, %{st | cycle: new_cycle}}
      not walked? ->
        st = last_retry(st)
        Process.send_after(self(), :last_retry_done, @last_retry_wait)
        {:noreply, st}
      true ->
        check_termination(st)
    end
  end
  def handle_info(:reload_and_query, st) do
    reload_count = @node_limit * (1 + st.cycle)
    nodes = ETSLookup.closest_nodes(st.ih, reload_count)
    st = add_nodes_to_dht(st, nodes)
    {:noreply, query_recursive(st)}
  end
  def handle_info(:last_retry_done, st) do
    check_termination(%{st | dht_walked: true})
  end
  def handle_info({ref, result}, st) do
    Process.demonitor(ref, [:flush])
    handle_completion(st, ref, result)
  end
  def handle_info({:DOWN, ref, :process, _pid, reason}, st) do
    handle_completion(st, ref, {:error, reason})
  end
  def handle_info(msg, st) do
    Logger.debug("[IHW] Unhandled msg: #{inspect(msg)}")
    {:noreply, st}
  end
  defp tick_and_check(st) do
    schedule(:tick)
    check_termination(st)
  end
  defp handle_completion(%{active_dl: adl} = st, ref, result) do
    case Map.pop(adl, ref) do
      {nil, _active} ->
        {:noreply, st}
      {{peer, _pid, _ttl}, new_adl} ->
        source_type = Map.get(st.peer_sources, peer, :values)
        new_st = update_attempts(st, new_adl, peer)
        case result do
          {:ok, {conn_type, utm}} ->
            finish_ok(new_st, {conn_type, utm}, peer, source_type)
          {:error, r} when r in @firewall_errors ->
            case Map.get(new_st.peer_attempts, peer, 0) < @max_requeues do
              false ->
                process_peer_failure(new_st, r)
              true ->
                schedule(:peer_requeued)
                new_st
                |> update_requeue(peer)
                |> process_peer_failure(r)
            end
          {:error, reason} ->
            report_failure(peer, reason)
            new_st
            |> record_source_failure(source_type)
            |> process_peer_failure(reason)
        end
    end
  end
  defp update_attempts(%{peer_attempts: pa} = st, new_adl, peer) do
    %{st | active_dl: new_adl, peer_attempts: Map.update(pa, peer, 1, &(&1 + 1))}
  end
  defp update_requeue(%{peers_tried: pt, peers_queue: pq} = st, peer) do
    %{st | peers_tried: MapSet.delete(pt, peer), peers_queue: pq ++ [peer]}
  end
  defp process_peer_failure(st, reason) do
    st
    |> record_failure(reason)
    |> process_downloads()
    |> check_termination()
  end
  defp record_failure(st, reason) do
    %{st | failure_reasons: Map.update(st.failure_reasons, reason, 1, &(&1 + 1))}
  end
  defp record_source_failure(st, src) do
    %{st | source_stats: Map.update(st.source_stats, src, {0, 1}, fn {s, f} -> {s, f + 1} end)}
  end
  defp maybe_query_recursive(%{dht_walked: false} = st), do: query_recursive(st)
  defp maybe_query_recursive(st), do: st
  defp query_recursive(%{ephemeral_dht: dht, deadline: dl} = st) do
    if now_ms() > dl do
      st
    else
      case EphemeralDHTSync.closest_unqueried(dht, @node_limit) do
        [] ->
          case st.pending_exhaustion do
            nil ->
              ref = Process.send_after(self(), :check_exhaustion, @exhaustion_wait)
              %{st | pending_exhaustion: ref}
            _ref ->
              st
          end
        to_query ->
          cancel_pending_exhaustion(st.pending_exhaustion)
          Enum.reduce(to_query, %{st | pending_exhaustion: nil}, fn {rid, nodev4}, acc ->
            send_get_peers(acc, rid, nodev4)
          end)
      end
    end
  end
  defp cancel_pending_exhaustion(nil), do: :ok
  defp cancel_pending_exhaustion(ref), do: Process.cancel_timer(ref)
  defp last_retry(%{ih: ih, ephemeral_dht: dht} = st) do
    to_query = EphemeralDHTSync.closest(dht, @node_limit)
    Enum.reduce(to_query, st, fn {_dist, _rid, nodev4}, acc ->
      new_stats = send_and_record_get_peers(ih, nodev4, acc.stats)
      %{acc | stats: new_stats}
    end)
  end
  defp add_nodes_to_dht(%{ephemeral_dht: dht} = st, nodes) do
    new_dht =
      Enum.reduce(nodes, dht, fn {rid, nodev4}, acc ->
        EphemeralDHTSync.insert(acc, rid, nodev4)
      end)
    %{st | ephemeral_dht: new_dht}
  end
  defp send_find_node(ih), do: GenS.MainlineOutgoing.find_node(ih, {:ihw, self()})
  defp send_get_peers(%{ih: ih, ephemeral_dht: dht, stats: stats} = st, rid, nodev4) do
    new_stats = send_and_record_get_peers(ih, nodev4, stats)
    new_dht = EphemeralDHTSync.mark_queried(dht, rid)
    %{st | ephemeral_dht: new_dht, stats: new_stats}
  end
  defp send_and_record_get_peers(ih, nodev4, stats) do
    GenS.MainlineOutgoing.get_peers(ih, nodev4, {:ihw, self()})
    Map.update!(stats, :get_peers_sent, &(&1 + 1))
  end
  defp process_downloads(
         %{
           ih: ih,
           own_ip: own_ip,
           ihw_id: ihw_id,
           peers_queue: pq,
           active_dl: adl,
           peers_tried: pt,
           max_slots: max
         } = st
       ) do
    slots = max - map_size(adl)
    case process?(slots, pq) do
      false ->
        st
      true ->
        {to_try, remaining} = Enum.split(pq, slots)
        new_active =
          Enum.reduce(to_try, adl, fn peer, acc ->
            case spawn_download(ih, peer, own_ip, ihw_id) do
              {:error, :spawn_failed_internal} -> acc
              {ref, {peer, pid, expires_at}} -> Map.put(acc, ref, {peer, pid, expires_at})
            end
          end)
        %{
          st
          | peers_queue: remaining,
            active_dl: new_active,
            peers_tried: MapSet.union(pt, MapSet.new(to_try))
        }
    end
  end
  defp spawn_download(ih, peer, own_ip, ihw_id) do
    GenS.Metrics.increment(:peers_tried)
    task =
      Task.Supervisor.async(Spv.FetchTask, fn ->
        GetTorrent.download(ih, peer, own_ip, ihw_id)
      end)
    {task.ref, {peer, task.pid, expires_in(@task_timeout_ms)}}
  rescue
    e in [ErlangError] ->
      case e.original do
        err when err in [:emfile, :enfile] ->
          GenS.ResourceLimiter.fd_exhausted()
          {:error, :spawn_failed_internal}
        _other_err ->
          {:error, :spawn_failed_internal}
      end
  end
  defp process_peers(st, peers, type) do
    peers
    |> Enum.reject(&MapSet.member?(st.peers_tried, &1))
    |> Enum.reduce(st, fn peer, acc_st ->
      update_peer_state(acc_st, peer, type)
    end)
    |> process_downloads()
    |> check_termination()
  end
  defp update_peer_state(%{peers_queue: pq, peer_sources: ps, stats: stats} = st, peer, src_type) do
    new_ps = Map.put(ps, peer, src_type)
    pq_without_current = Enum.reject(pq, &(&1 == peer))
    cond do
      length(pq_without_current) < @peer_queue_limit ->
        new_q = [peer | pq_without_current]
        %{
          st
          | peers_queue: sort_queue(new_q),
            peer_sources: new_ps,
            stats: Map.update!(stats, :peers_found, &(&1 + 1))
        }
      true ->
        worst_peer = List.last(pq_without_current)
        if should_replace?(worst_peer, peer) do
          new_q = [peer | List.delete(pq_without_current, worst_peer)]
          %{
            st
            | peers_queue: sort_queue(new_q),
              peer_sources: Map.delete(new_ps, worst_peer),
              stats: Map.update!(stats, :peers_found, &(&1 + 1))
          }
        else
          %{st | peer_sources: new_ps}
        end
    end
  end
  defp should_replace?(worst, candidate) do
    {w_utm, _ts} = ETSLookup.peer_info(worst)
    {c_utm, _ts} = ETSLookup.peer_info(candidate)
    cond do
      c_utm > w_utm ->
        true
      true ->
        :rand.uniform(100) <= div(100, @exploration_odds)
    end
  end
  defp sort_queue(pq) do
    Enum.sort_by(pq, fn peer ->
      {utm, ts} = ETSLookup.peer_info(peer)
      score = utm + ts / 1_000_000
      -score
    end)
  end
  defp report_failure(peer, reason) do
    case Conn.Error.get_error_type(reason) do
      :crawler_errors ->
        GenS.PeerManager.failed_peer(peer, :crawler)
      type when type in [:connect_errors, :timeout_errors, :data_errors] ->
        GenS.PeerManager.failed_peer(peer, :timeout)
      :firewall_errors ->
        GenS.PeerManager.failed_peer(peer, :firewall)
      :common_errors ->
        :noop
    end
  end
  defp log_shutdown(%{ephemeral_dht: dht} = st, reason) do
    conv = EphemeralDHTSync.convergence_stats(dht)
    nodes_queried = conv[:nodes_queried] || 0
    peer_yield =
      if st.stats.get_peers_sent > 0,
        do: Float.round(st.stats.gp_replies_recvd / st.stats.get_peers_sent * 100, 1),
        else: 0.0
    failures =
      st.failure_reasons
      |> Enum.map(fn {r, count} -> "#{inspect(r)}: #{count}" end)
      |> Enum.join(", ")
    if MathSync.rolled?(1, @stats_freq) do
      Logger.debug("""
      [IHW] [#{PrinterSync.short_hex(st.ih)}], REASON: #{reason}
              -- DHT XOR: quality: #{conv.quality}, d: #{conv.min_bits}b, gained bits: #{conv.bits_gained}b, spread: #{conv.spread}x
              -- KRPC: get_peers: #{st.stats.get_peers_sent}, nodes asked: #{nodes_queried} -> yield: #{peer_yield}%, peers found: #{st.stats.peers_found},
              -- Conns: peers: #{MapSet.size(st.peers_tried)} / queued #{length(st.peers_queue)}, failures [#{failures}]
      """)
    end
  end
  defp maybe_report_gp_sent(gp_sent, last_reported) do
    diff = gp_sent - last_reported
    GenS.MainlineOutgoing.report_gpq_count(diff)
  end
  defp check_termination(
         %{
           failure_reasons: fr,
           peers_queue: pq,
           peers_tried: pt,
           active_dl: adl,
           deadline: dl,
           dht_walked: walked?
         } = st
       ) do
    now = now_ms()
    close_deadline? = now + 500 > dl
    cond do
      early_abandon?(pq, pt, fr) -> finish(st, :too_many_timeouts)
      now > dl -> finish(st, :worker_timeout)
      close_deadline? and any_hanged?(adl, now) -> finish(st, :some_downloads_hanged)
      walked? and pq == [] and map_size(adl) == 0 -> finish(st, :work_done_no_result)
      true -> {:noreply, st}
    end
  end
  defp early_abandon?(pq, pt, fr) do
    timeouts_count = Map.get(fr, :timeout, 0)
    total_peers_count = length(pq) + MapSet.size(pt)
    total_peers_count >= @min_timeouts_thr and
      timeouts_count * @timeouts_thr_den >= total_peers_count * @timeouts_thr_num
  end
  defp any_hanged?(adl, _now) when map_size(adl) == 0, do: false
  defp any_hanged?(adl, now) do
    Enum.any?(adl, fn {_ref, {_peer, _pid, ttl}} -> now > ttl end)
  end
  defp incr_ih_metrics(false), do: GenS.Metrics.increment(:base_worker)
  defp incr_ih_metrics(true), do: GenS.Metrics.increment(:announce_worker)
  defp finish(%{ih: ih, source_stats: src_stats} = st, reason) do
    GenS.SearchManager.fetch_failed(ih, src_stats)
    report_and_stop(st, reason)
  end
  defp finish_ok(%{ih: ih, source_stats: src_stats} = st, {c_type, utm}, peer, type) do
    GenS.SearchManager.md_fetched({ih, c_type, utm}, type, src_stats)
    GenS.PeerManager.good_peer(ih, peer)
    report_and_stop(st, :success)
  end
  defp report_and_stop(st, reason) do
    maybe_report_gp_sent(st.stats.get_peers_sent, st.stats.last_reported_gp)
    log_shutdown(st, reason)
    {:stop, :normal, st}
  end
  defp shutdown_stop(%{ih: _ih, active_dl: _adl} = st), do: {:stop, :shutdown, st}
  def terminate(_reason, _st) do
    GenS.ResourceLimiter.release()
  catch
    _kind, _reason -> :ok
  end
end