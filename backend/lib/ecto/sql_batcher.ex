defmodule GenS.SQLiteBatcher do
  use GenServer
  import TimeSync
  require Logger
  alias MagnetSorter.{Repo, Store}
  @compile {:inline, [format_pending_data: 1, finalize_peers: 1]}
  @clock 20_000
  @sql_timeout 30_000
  @chunk_size 4096
  @ets_pending_peers :pending_peers
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def flush_sync do
    GenServer.call(__MODULE__, :flush_sync, 60_000)
  end
  def resync_peer(ih, peer), do: GenServer.cast(__MODULE__, {:resync_peer, ih, peer})
  def delete_peers_tab(), do: Store.delete_all_peers()
  defp schedule_tick(), do: Process.send_after(self(), :tick, @clock)
  def init(_opts) do
    TryETS.create_named(@ets_pending_peers, :set, :public, true, true)
    schedule_tick()
    {:ok, %{}}
  end
  def handle_call(:flush_sync, _from, st) do
    Logger.info("[Ecto] Sync flush requested")
    do_flush()
    {:reply, :ok, st}
  end
  def handle_cast({:resync_peer, ih, peer}, st) do
    case TryETS.lookup(@ets_pending_peers, ih) do
      [{^ih, peers_set}] ->
        TryETS.insert(@ets_pending_peers, {ih, MapSet.put(peers_set, peer)})
      [] ->
        TryETS.insert(@ets_pending_peers, {ih, MapSet.new([peer])})
    end
    {:noreply, st}
  end
  def handle_info(:tick, st) do
    do_flush()
    schedule_tick()
    {:noreply, st}
  end
  defp do_flush() do
    pending = TryETS.tab2list(@ets_pending_peers)
    if pending != [] do
      start_time = mono_ms()
      TryETS.delete_all(@ets_pending_peers)
      rows = format_pending_data(pending)
      rows
      |> Enum.chunk_every(@chunk_size)
      |> Enum.each(fn sub_rows ->
        try do
          Repo.transaction(
            fn ->
              Store.insert_peers_batch(sub_rows)
            end,
            timeout: @sql_timeout
          )
        rescue
          e -> Logger.error("[Ecto] Sub-batch failed: #{inspect(e)}")
        end
      end)
      duration = mono_ms() - start_time
      if MathSync.rolled?(1, 5),
        do: Logger.info("[Ecto] Flushed #{length(rows)} infohashes in #{duration}ms")
    end
  end
  defp format_pending_data(pending_list) do
    Enum.map(pending_list, fn {ih, peers_set} ->
      peers = MapSet.to_list(peers_set)
      {blob, hash, cnt} = finalize_peers(peers)
      {ih, cnt, blob, hash}
    end)
  end
  defp finalize_peers([]), do: {nil, nil, 0}
  defp finalize_peers(peers) do
    blob = :erlang.iolist_to_binary(peers)
    hash = :crypto.hash(:sha, blob)
    {blob, hash, length(peers)}
  end
end