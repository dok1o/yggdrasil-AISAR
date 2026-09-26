defmodule GenS.PFNodesProcessor do
  use GenServer
  import MagnetSorter.Const
  require Logger
  def start_link(o \\ []), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  @batch_interval_ms 100
  @clean_tick 2_000
  @stats_tick 5_000
  @schedule_m %{
    tick: @batch_interval_ms,
    ets_clean: @clean_tick,
    stats: @stats_tick
  }
  @max_msg_len 512
  @ets_tables %{
    fpinged_nodes: %{name: :fpinged_nodes, type: :set}
  }
  for {key, %{name: name}} <- @ets_tables do
    Module.put_attribute(__MODULE__, :"ets_#{key}", name)
  end
  @sets for {_k, v} <- @ets_tables, v.type == :set, do: v.name
  @fping_ttl_ms 30_000
  defstruct pending: [],
            stats: %{
              replies_processed: 0,
              candidates_found: 0,
              legacy_discarded: 0,
              queries_sent: 0,
              pinged: 0
            },
            pf?: false
  def push_queries_stats(qs), do: GenServer.cast(__MODULE__, {:queries_stats, qs})
  def ping_request(ipv4), do: GenServer.cast(__MODULE__, {:ping_request, ipv4})
  @doc "Called from KRPCReplySync when a :pf_bootstrap reply arrives"
  def check_mask(nodes, regime) do
    GenServer.cast(__MODULE__, {:nodes_reply, nodes, regime})
  end
  def process_candidates(candidates, nodes_cnt) do
    GenServer.cast(__MODULE__, {:candidates, candidates, nodes_cnt})
  end
  defp init_await(), do: Process.sleep(sleep_ms())
  defp schedule(msg), do: Process.send_after(self(), msg, Map.fetch!(@schedule_m, msg))
  def init(_opts) do
    TryETS.create_many_named(@sets, :set, :public, true, true)
    pf? = KeyStorageSync.use_pf?()
    st = %__MODULE__{
      pf?: pf?
    }
    {:ok, st, {:continue, :startup}}
  end
  def handle_continue(:startup, %{pf?: pf?} = st) do
    case pf? do
      false ->
        {:noreply, st}
      true ->
        case KeyStorageSync.rt_ready?() do
          false ->
            init_await()
            {:noreply, st, {:continue, :startup}}
          true ->
            Enum.each(Map.keys(@schedule_m), &schedule/1)
            {:noreply, st}
        end
    end
  end
  def handle_cast({:nodes_reply, _nodes, _regime}, %{pf?: false} = st), do: {:noreply, st}
  def handle_cast({:nodes_reply, nodes, regime}, st) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} when len >= @max_msg_len ->
        {:noreply, st}
      {:message_queue_len, _len} ->
        candidates = prepare_candidates(nodes, regime)
        process_candidates(candidates, length(nodes))
        {:noreply, st}
    end
  end
  def handle_cast({:candidates, candidates, nodes_cnt}, st) do
    pinged_cnt = send_count_many_ping_x(candidates)
    maybe_log_legacy_scan(length(candidates), pinged_cnt)
    new_stats = %{
      st.stats
      | replies_processed: st.stats.replies_processed + 1,
        candidates_found: st.stats.candidates_found + length(candidates),
        legacy_discarded: st.stats.legacy_discarded + nodes_cnt,
        pinged: st.stats.pinged + pinged_cnt
    }
    new_pending = candidates ++ st.pending
    new_st = %{st | stats: new_stats, pending: new_pending}
    {:noreply, new_st}
  end
  def handle_cast({:queries_stats, qs}, %{stats: stats} = st) do
    new_stats = %{stats | queries_sent: stats.queries_sent + qs}
    new_st = %{st | stats: new_stats}
    {:noreply, new_st}
  end
  def handle_cast({:ping_request, {a, b, c, d} = ipv4}, st) do
    known_ports = LogManager.scan_ports(ipv4)
    all_ports = Enum.uniq([51413 | known_ports])
    Enum.each(all_ports, fn port ->
      nodev4 = <<a, b, c, d, port::16>>
      Logger.debug(
        "[PF] Pinging #{PrinterSync.peer(nodev4)} of #{length(all_ports)} all IP hits found"
      )
      send_one_ping_x(nodev4)
    end)
    {:noreply, st}
  end
  def handle_info(:tick, %{pending: []} = st), do: no_reply_schedule(st, :tick)
  def handle_info(:tick, %{pending: pend} = st) do
    send_count_many_ping_x(pend)
    new_st = %{st | pending: []}
    no_reply_schedule(new_st, :tick)
  end
  def handle_info(:ets_clean, st) do
    TryETS.clean_expired(@ets_fpinged_nodes)
    no_reply_schedule(st, :ets_clean)
  end
  def handle_info(:stats, st) do
    log_stats(st)
    no_reply_schedule(st, :stats)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp prepare_candidates(nodes, regime) do
    nodes
    |> Enum.filter(fn {rid, _nodev4} -> PFMaskSync.valid_fid?(rid) end)
    |> Enum.map(fn {_rid, nodev4} -> {nodev4, regime} end)
  end
  defp send_count_many_ping_x(candidates) do
    candidates
    |> Enum.map(fn {nodev4, _regime} -> nodev4 end)
    |> Enum.uniq()
    |> Enum.filter(fn nodev4 -> TryETS.cooled_down_ms?(@ets_fpinged_nodes, nodev4) end)
    |> Enum.count(&send_one_ping_x/1)
  end
  defp send_one_ping_x(nodev4) do
    TryETS.set_cooldown_ms(@ets_fpinged_nodes, nodev4, @fping_ttl_ms)
    KRPCOutSync.ping_x(nodev4)
    LogManager.append_line(:pf_out_log, {"ping_x", nodev4})
  end
  defp maybe_log_legacy_scan(cand_cnt, pinged_cnt) do
    if cand_cnt > 0, do: Logger.debug("[PF] Legacy scan: #{cand_cnt} candidates")
    if pinged_cnt > 0, do: Logger.debug("[PF] Legacy scan: #{pinged_cnt} pinged")
  end
  defp log_stats(st) do
    Logger.info(
      "[PF] Node processor: #{st.stats.queries_sent}/#{st.stats.replies_processed} replies, #{st.stats.candidates_found} candidates, #{st.stats.legacy_discarded} no mask match, #{st.stats.pinged} pinged"
    )
  end
end