defmodule GenS.IdStorage do
  use GenServer
  import MagnetSorter.Const
  require Logger
  def start_link(o \\ []), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  @ets_tables %{
    worker_ids: %{name: :ids_prefixes, type: :set},
    secrets: %{name: :prefixes_secrets, type: :set}
  }
  for {key, %{name: name}} <- @ets_tables do
    Module.put_attribute(__MODULE__, :"ets_#{key}", name)
  end
  @rotation_interval 1_000 * 60 * 25
  @schedule_m %{
    rotate: @rotation_interval
  }
  def update_lookup(work_id, ih) do
    GenServer.cast(__MODULE__, {:upd_lookup, work_id, ih})
  end
  defp bits(), do: worker_ids_lookup_bits()
  defp bucket_count(), do: round(:math.pow(2, bits()))
  defp rand_id(), do: :crypto.strong_rand_bytes(20)
  defp schedule(msg), do: Process.send_after(self(), msg, Map.fetch!(@schedule_m, msg))
  def init(_opts) do
    create_tables()
    populate_tables()
    st = %{}
    Enum.each(Map.keys(@schedule_m), &schedule/1)
    {:ok, st}
  end
  defp create_tables() do
    TryETS.create_named(@ets_secrets, :set, :public, true, true)
    TryETS.create_named(@ets_worker_ids, :set, :public, true, :auto)
  end
  defp populate_tables() do
    for i <- 0..(bucket_count() - 1) do
      TryETS.insert(@ets_secrets, {i, rand_id()})
      TryETS.insert(@ets_worker_ids, {i, rand_id()})
    end
  end
  def handle_cast({:upd_lookup, work_id, ih}, st) do
    prefix = WorkerIDSync.prefix_from_binary(ih)
    TryETS.insert(@ets_worker_ids, {prefix, work_id})
    {:noreply, st}
  end
  def handle_info(:rotate, st) do
    for i <- 0..(bucket_count() - 1) do
      TryETS.insert(@ets_secrets, {i, rand_id()})
    end
    no_reply_schedule(st, :rotate)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
end