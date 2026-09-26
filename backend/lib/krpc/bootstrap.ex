defmodule GenS.RoutingBootstrap do
  use GenServer
  require Logger
  def start_link(o \\ []), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  @compile {:inline, []}
  @tick_ms 75
  @log_tick_ms 1_000
  @schedule_m %{
    tick: @tick_ms,
    log: @log_tick_ms
  }
  @burst_count_s 1_024 * 8
  @burst_count_tick div(@burst_count_s, @tick_ms)
  @node_limit 8
  @cache_path "../data/caches/boot.jsonl"
  defstruct [
    :boot_id,
    tried: 0,
    tick_tried: 0
  ]
  defp schedule(msg), do: Process.send_after(self(), msg, Map.fetch!(@schedule_m, msg))
  def init(_opts) do
    st = %__MODULE__{}
    Enum.each(Map.keys(@schedule_m), &schedule/1)
    {:ok, st}
  end
  def handle_info(:tick, %{tried: count} = st) do
    case KeyStorageSync.rt_ready?() do
      false ->
        new_st = boot_burst(st, count)
        no_reply_schedule(new_st, :tick)
      true ->
        {:noreply, st}
    end
  end
  def handle_info(:log, %{tried: total} = st) do
    case KeyStorageSync.rt_ready?() do
      false ->
        log_stats(total)
        no_reply_schedule(st, :log)
      true ->
        {:noreply, st}
    end
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp boot_burst(st, count) do
    known_random =
      try_select_known(@node_limit)
      |> case do
        [] -> read_cached_nodes(@node_limit)
        nodes -> nodes
      end
    generated = KRPCUtilsSync.generate_candidates_to_ask(@burst_count_tick)
    to_ask =
      (known_random ++ generated)
      |> Enum.uniq()
    GenS.MainlineOutgoing.many_find_node_bs(to_ask)
    new = length(known_random) + @burst_count_tick
    %{st | tried: count + new, tick_tried: new}
  end
  defp try_select_known(count) do
    count
    |> ETSLookup.random_nodes()
    |> Enum.map(fn {_rid, nodev4} -> nodev4 end)
  end
  defp read_cached_nodes(count) do
    case File.exists?(@cache_path) do
      false ->
        []
      true ->
        @cache_path
        |> File.stream!(:line, [])
        |> Stream.map(&decode_cache_line/1)
        |> Stream.filter(&match?({:ok, _nodev4}, &1))
        |> Stream.map(fn {:ok, nodev4} -> nodev4 end)
        |> Stream.uniq()
        |> Enum.take(count)
    end
  rescue
    error ->
      Logger.debug("[DHT] Failed reading bootstrap cache: #{inspect(error)}")
      []
  end
  defp decode_cache_line(line) do
    with {:ok, %{"nodev4" => nodev4_hex}} <- Jason.decode(line),
         {:ok, nodev4} <- Base.decode16(nodev4_hex, case: :mixed),
         true <- byte_size(nodev4) == 6 do
      {:ok, nodev4}
    else
      _malformed -> :error
    end
  end
  defp log_stats(total) do
    Logger.debug("[DHT] Bootstrap: tried #{total} generated IPv4 addresses")
  end
end