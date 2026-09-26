defmodule GenS.MainlineOutgoing do
  use GenServer
  import MagnetSorter.Const
  import PFProtocol
  import MathSync
  import TimeSync
  require Logger
  @typedoc "20b SHA-1 base value: remote node_id, infohash, other"
  @type target :: <<_::160>>
  @type rid :: target()
  @typedoc "IPv4 node: 4 bytes for IPv4 address, 2 bytes for port as <<a,b,c,d,port::16>>"
  @type nodev4 :: <<_::48>>
  @ext_ets_nodes :dht_nodes
  @ets_tables %{
    samples_nodes: %{name: :samples_nodes, type: :set}
  }
  for {key, %{name: name}} <- @ets_tables do
    Module.put_attribute(__MODULE__, :"ets_#{key}", name)
  end
  @sets for {_k, v} <- @ets_tables, v.type == :set, do: v.name
  @clock 200
  @clean_tick 2_000
  @stats_tick 10_000
  @samples_asked_ttl_ms 5_000
  @ticks_per_sec div(1_000, @clock)
  @schedule_m %{
    tick: @clock,
    ets_clean: @clean_tick,
    stats: @stats_tick
  }
  @take_count 24
  @max_queue_size 1_024
  @max_pending_fn @max_queue_size
  @max_pending_gpn @max_queue_size
  @gp_net_rate div(get_peers_echo_rate_s(), @ticks_per_sec)
  @si_rate div(base_sample_infohashes_rate_s(), @ticks_per_sec)
  @dht_bytes 20
  @pr_len samples_prefix_length()
  @rem_len @dht_bytes - @pr_len
  @wnd_30s_samples_bootstrap 30
  @wnd30 @wnd_30s_samples_bootstrap
  @random_frc div(@si_rate, 4) * 4
  @salt_frc @si_rate - @random_frc
  defstruct [
    :last_log_at,
    pending_fn: :queue.new(),
    pending_gp_net: :queue.new(),
    pending_gp_samples: :queue.new(),
    get_peers_acc: 0,
    sample_demand: 0,
    stats: %{
      fn_count: 0,
      gp_own_count: 0,
      gp_net_count: 0,
      gp_samp_count: 0,
      si_count: 0
    }
  ]
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def many_find_node_bs(to_query) do
    GenServer.cast(__MODULE__, {:find_node_boot, to_query})
  end
  def find_node(target, ctx), do: GenServer.cast(__MODULE__, {:find_node, target, ctx})
  def get_peers(target, nodev4, ctx) do
    GenServer.cast(__MODULE__, {:get_peers, target, nodev4, ctx})
  end
  def get_peers_n(target), do: GenServer.cast(__MODULE__, {:get_peers_n, target})
  def report_gpq_count(diff), do: GenServer.cast(__MODULE__, {:gpq_count, diff})
  defp init_await(), do: Process.sleep(sleep_ms())
  defp schedule(msg), do: Process.send_after(self(), msg, Map.fetch!(@schedule_m, msg))
  def init(_opts) do
    TryETS.create_many_named(@sets, :set, :public, true, true)
    initial_delay = worker_lifespan_s() * 1_000
    st = %__MODULE__{
      last_log_at: mono_ms() - initial_delay
    }
    {:ok, st, {:continue, :startup_sequence}}
  end
  def handle_continue(:startup_sequence, st) do
    dht_ready? = KeyStorageSync.flags_for_dht_work?() and UDPChk.ready?()
    case dht_ready? do
      false ->
        init_await()
        {:noreply, st, {:continue, :startup_sequence}}
      true ->
        Enum.each(Map.keys(@schedule_m), &schedule/1)
        {:noreply, st}
    end
  end
  def handle_cast({:find_node_boot, to_query}, st) do
    Sender.many_find_node_bs(to_query)
    {:noreply, st}
  end
  def handle_cast({:find_node, target, ctx}, %{pending_fn: fnq} = st) do
    new_queue = put_in_queue({target, ctx}, fnq, :queue.len(fnq), @max_pending_fn)
    {:noreply, %{st | pending_fn: new_queue}}
  end
  def handle_cast({:get_peers, target, nodev4, ctx}, st) do
    KRPCOutSync.get_peers(target, nodev4, ctx)
    {:noreply, st}
  end
  def handle_cast({:get_peers_n, target}, %{pending_gp_net: gpnq} = st) do
    new_queue =
      put_in_queue({target, {:get_peers_asked, target}}, gpnq, :queue.len(gpnq), @max_pending_gpn)
    {:noreply, %{st | pending_gp_net: new_queue}}
  end
  def handle_cast({:gpq_count, count}, st) do
    new_stats = Map.update!(st.stats, :gp_own_count, &(&1 + count))
    {:noreply, %{st | stats: new_stats, get_peers_acc: st.get_peers_acc + count}}
  end
  def handle_info(:tick, st) do
    new_st = do_tick(st)
    no_reply_schedule(new_st, :tick)
  end
  def handle_info(:ets_clean, st) do
    TryETS.clean_expired(@ets_samples_nodes)
    no_reply_schedule(st, :ets_clean)
  end
  def handle_info(:stats, st) do
    new_st = log_stats(st)
    no_reply_schedule(new_st, :stats)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp do_tick(st) do
    {fn_st, fn_sent} = process_fn_queue(st)
    {gpn_st, gpn_sent} = process_gpn_queue(fn_st, @gp_net_rate)
    send_report_samples()
    new_stats = %{
      gpn_st.stats
      | fn_count: gpn_st.stats.fn_count + fn_sent,
        gp_net_count: gpn_st.stats.gp_net_count + gpn_sent,
        si_count: gpn_st.stats.si_count + @si_rate
    }
    %{gpn_st | stats: new_stats, get_peers_acc: 0}
  end
  defp process_fn_queue(%{pending_fn: fnq} = st) do
    {to_send, remaining} = take_from_queue(fnq, @take_count)
    sent = Sender.many_find_node(to_send, :nid)
    {%{st | pending_fn: remaining}, sent}
  end
  defp process_gpn_queue(%{pending_gp_net: gpnq} = st, count) do
    {to_send, remaining} = take_from_queue(gpnq, count)
    sent = Sender.many_get_peers(to_send)
    {%{st | pending_gp_net: remaining}, sent}
  end
  defp put_in_queue(item, q, len, max_size) when len < max_size, do: :queue.in(item, q)
  defp put_in_queue(item, queue, _len, _max_size) do
    {{:value, _item}, old_q} = :queue.out(queue)
    :queue.in(item, old_q)
  end
  defp take_from_queue(q, limit) do
    take_from_queue(q, limit, [])
  end
  defp take_from_queue(q, 0, acc), do: {acc, q}
  defp take_from_queue(q, limit, acc) do
    case :queue.out(q) do
      {{:value, item}, rest} -> take_from_queue(rest, limit - 1, [item | acc])
      {:empty, _item} -> {acc, q}
    end
  end
  defp send_report_samples() do
    mask = generate_salt_mask(@wnd30)
    <<mask_pr::binary-size(@pr_len), _rest1::binary-size(@rem_len)>> = mask
    {close_nodes, far_nodes} = split_nodes(mask_pr)
    sel_close = select_close(close_nodes, mask)
    sel_random = select_random(far_nodes)
    nodes = sel_close ++ sel_random
    asked = Sender.many_samples(nodes)
    set_cooldowns(nodes)
    GenS.SampleCoordinator.samples_info(asked)
  end
  defp split_nodes(mask_pr) do
    @ext_ets_nodes
    |> TryETS.tab2list()
    |> Enum.filter(fn {_rid, nodev4} ->
      TryETS.cooled_down_ms?(@ets_samples_nodes, nodev4)
    end)
    |> Enum.split_with(fn {rid, _nodev4} ->
      binary_part(rid, 0, @pr_len) == mask_pr
    end)
  end
  defp select_close(close_nodes, mask) do
    close_nodes
    |> Enum.take(@salt_frc)
    |> Enum.sort_by(fn {rid, _nodev4} -> MathSync.xor_distance(mask, rid) end)
  end
  defp select_random(far_nodes) do
    far_nodes
    |> Enum.shuffle()
    |> Enum.take(@random_frc)
  end
  defp set_cooldowns(nodes) do
    nodes
    |> Enum.each(fn {_rid, nodev4} ->
      TryETS.set_cooldown_ms(@ets_samples_nodes, nodev4, @samples_asked_ttl_ms)
    end)
  end
  defp log_stats(st) do
    now = mono_ms()
    elapsed_ms = max(1, now - st.last_log_at)
    sec = div(elapsed_ms, 1_000)
    fn_s = safe_rate(st.stats.fn_count, sec, 0)
    gpw_s = safe_rate(st.stats.gp_own_count, sec, 0)
    gpn_s = safe_rate(st.stats.gp_net_count, sec, 0)
    sam_s = safe_rate(st.stats.si_count, sec, 0)
    total = fn_s + gpw_s + gpn_s + sam_s
    unless total == 0 do
      Logger.info(
        "[Mainline DHT] fn: #{fn_s}, gp_workers: #{gpw_s}, gp_network: #{gpn_s}, samples: #{sam_s}, TOTAL: #{total} /s"
      )
    end
    %{
      st
      | last_log_at: now,
        stats: %{fn_count: 0, gp_net_count: 0, gp_own_count: 0, si_count: 0}
    }
  end
end