defmodule GenS.RoutingTable do
  use GenServer
  require Logger
  import MagnetSorter.Const
  import TimeSync
  def start_link(o \\ []), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  @compile {:inline, []}
  @typedoc "20b SHA-1 base value: remote node_id, infohash, other"
  @type target :: <<_::160>>
  @type rid :: target()
  @typedoc "IPv4 node: 4 bytes for IPv4 address, 2 bytes for port as <<a,b,c,d,port::16>>"
  @type nodev4 :: <<_::48>>
  @type node_entry :: {rid(), nodev4()}
  @ets_tables %{
    nodes: %{name: :dht_nodes, type: :set},
    node_rev: %{name: :node_reverse, type: :set},
    inbox: %{name: :dht_inbox, type: :set}
  }
  @boot_cache_dir "../data/caches"
  @cache_path "../data/caches/boot.jsonl"
  @cache_nodes 256
  for {key, %{name: name}} <- @ets_tables do
    Module.put_attribute(__MODULE__, :"ets_#{key}", name)
  end
  @sets for {_k, v} <- @ets_tables, v.type == :set, do: v.name
  @refill_tick 600
  @discard_tick 3_000
  @cache_tick 10_000
  @schedule_m %{
    refill_tick: @refill_tick,
    discard_tick: @discard_tick,
    cache_tick_once: @cache_tick
  }
  @random_refill_frc 16
  @discard_num div(dht_size(), 32)
  def full?(), do: TryETS.size(@ets_nodes) >= dht_size()
  defp analyze_nat() do
    GenS.NATChk.start_analysis()
    init_await()
  end
  defp init_await(), do: Process.sleep(sleep_ms())
  defp schedule(msg), do: Process.send_after(self(), msg, Map.fetch!(@schedule_m, msg))
  def init(_opts) do
    File.mkdir_p!(@boot_cache_dir)
    TryETS.create_many_named(@sets, :set, :public, true, true)
    st = %{start_ms: mono_ms()}
    {:ok, st, {:continue, :startup_sequence}}
  end
  def handle_continue(:startup_sequence, st) do
    dht_ready? = KeyStorageSync.flags_for_dht_work?() and UDPChk.ready?()
    case dht_ready? do
      false ->
        init_await()
        {:noreply, st, {:continue, :startup_sequence}}
      true ->
        analyze_nat()
        {:noreply, st, {:continue, :booting}}
    end
  end
  def handle_continue(:booting, %{start_ms: start_ms} = st) do
    case full?() do
      false ->
        {:noreply, st, {:continue, :booting}}
      true ->
        KeyStorageSync.set_rt_filled()
        Enum.each(Map.keys(@schedule_m), &schedule/1)
        log_bootstrap(start_ms)
        {:noreply, st}
    end
  end
  def handle_info(:cache_tick_once, st) do
    refresh_bootstrap_cache()
    {:noreply, st}
  end
  def handle_info(:discard_tick, st) do
    do_discard()
    no_reply_schedule(st, :discard_tick)
  end
  def handle_info(:refill_tick, st) do
    refill_count = dht_size() - TryETS.size(@ets_nodes)
    maybe_refill(refill_count)
    no_reply_schedule(st, :refill_tick)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp do_discard() do
    size = TryETS.size(@ets_nodes)
    if size >= dht_size() do
      @ets_nodes
      |> TryETS.random_select(@discard_num)
      |> Enum.each(fn {rid, nodev4} ->
        sync_del(rid, nodev4)
        GenS.Metrics.increment(:excluded_node)
      end)
    end
  end
  defp maybe_refill(count) when count <= 0, do: :noop
  defp maybe_refill(count) do
    random_refill = div(count, @random_refill_frc)
    maybe_generate_send(random_refill)
    within_table_refill = count - random_refill
    Enum.each(1..within_table_refill, fn _i ->
      GenS.MainlineOutgoing.find_node(IdGenSync.rand_id(), :hash_table_rotation)
    end)
  end
  defp maybe_generate_send(0), do: :noop
  defp maybe_generate_send(count) do
    generated = KRPCUtilsSync.generate_candidates_to_ask(count)
    GenS.MainlineOutgoing.many_find_node_bs(generated)
  end
  defp sync_del(rid, n4) do
    TryETS.take(@ets_node_rev, n4)
    case TryETS.take(@ets_nodes, rid) do
      [{^rid, some_n4}] when some_n4 != n4 -> TryETS.delete(@ets_node_rev, some_n4)
      _ -> :noop
    end
  end
  defp log_bootstrap(start_ms) do
    nodes = TryETS.tab2list(@ets_node_rev)
    {ip_cnt, subnet_cnt} = count_addrs(nodes)
    elapsed_s = div(mono_ms() - start_ms, 1_000)
    Logger.info(
      "[DHT] Routing Table populated in #{elapsed_s} seconds with #{ip_cnt} IPs of #{subnet_cnt} /16 subnets"
    )
  end
  defp count_addrs(nodes) do
    addrs =
      nodes
      |> Enum.map(fn {_rid, nodev4} -> nodev4 end)
      |> Enum.uniq()
    subnets =
      addrs
      |> Enum.map(fn <<subnet_pr::binary-2, _rest::binary>> -> subnet_pr end)
      |> Enum.uniq()
    {length(addrs), length(subnets)}
  end
  defp refresh_bootstrap_cache() do
    nodes =
      @ets_nodes
      |> TryETS.random_select(@cache_nodes)
    if nodes != [] do
      write_bootstrap_cache(nodes)
    end
  rescue
    error ->
      Logger.warning("[DHT] Bootstrap cache refresh failed: #{inspect(error)}")
  end
  defp write_bootstrap_cache(nodes) do
    path = Path.expand(@cache_path)
    path
    |> Path.dirname()
    |> File.mkdir_p!()
    tmp_path = path <> ".tmp"
    {:ok, io} = File.open(tmp_path, [:write, :binary])
    try do
      Enum.each(nodes, fn {rid, nodev4} ->
        line =
          Jason.encode!(%{
            "rid" => Base.encode16(rid, case: :lower),
            "nodev4" => Base.encode16(nodev4, case: :lower)
          })
        IO.write(io, line)
        IO.write(io, "\n")
      end)
    after
      File.close(io)
    end
    File.rename!(tmp_path, path)
  end
end