defmodule GenS.PFRoutingBootstrap do
  use GenServer
  import MagnetSorter.Const
  require Logger
  @compile {:inline, []}
  @refresh_ms 1_500
  @tick_ms 250
  @max_pairs 512
  @batch_size 8
  @ets_filtered_freq :filtered_freq
  @schedule_m %{
    refresh_ihs: @refresh_ms,
    tick: @tick_ms
  }
  defstruct pairs: [], ptr: 0, queries_sent: 0
  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  defp acc_upd_forumla(acc), do: acc + 2 * 8
  defp init_await(), do: Process.sleep(sleep_ms())
  defp schedule(msg), do: Process.send_after(self(), msg, Map.fetch!(@schedule_m, msg))
  def init(_opts) do
    sets = [
      @ets_filtered_freq
    ]
    TryETS.create_many_named(sets, :set, :public, true, true)
    st = %__MODULE__{}
    {:ok, st, {:continue, :startup}}
  end
  def handle_continue(:startup, st) do
    case KeyStorageSync.use_pf?() do
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
  def handle_info(:tick, %{pairs: pairs} = st) when length(pairs) == 0 do
    no_reply_schedule(st, :tick)
  end
  def handle_info(:tick, %{pairs: pairs, ptr: ptr} = st) do
    {batch, new_ptr} = calc_new_ptr(ptr, pairs)
    process_batch(batch)
    new_st = %{st | ptr: new_ptr}
    no_reply_schedule(new_st, :tick)
  end
  def handle_info(:refresh_ihs, st) do
    new_pairs = build_frequent_pairs()
    schedule(:refresh_ihs)
    {:noreply, %{st | pairs: new_pairs, ptr: 0}}
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp calc_new_ptr(ptr, pairs) do
    len = length(pairs)
    start = min(ptr, len - 1)
    batch = Enum.slice(pairs, start..(start + @batch_size - 1))
    new_ptr = rem(start + @batch_size, len)
    {batch, new_ptr}
  end
  defp build_frequent_pairs() do
    ETSLookup.get_frequent_ihs()
    |> generate_pairs()
    |> uniq_pairs()
    |> cap_and_sort()
  end
  defp generate_pairs(ihs) when length(ihs) >= 2 do
    filtered =
      ihs
      |> Enum.group_by(fn {ih, _freq} -> <<ih::binary-size(4)>> end)
      |> Enum.map(fn {_prefix, candidates} ->
        Enum.max_by(candidates, fn {_ih, freq} -> freq end)
      end)
    refresh_paint_table(filtered)
    for {{ih1, f1}, {ih2, f2}} <- Enum.zip(filtered, tl(filtered)),
        ih1 != ih2,
        do: {f1 * f2, ih1, ih2}
  end
  defp generate_pairs(_last), do: []
  defp uniq_pairs(pairs) do
    Enum.uniq_by(pairs, fn {_fm, ih1, ih2} -> sort_pair(ih1, ih2) end)
  end
  defp cap_and_sort(pairs) do
    pairs =
      case length(pairs) > @max_pairs do
        false ->
          pairs
        true ->
          pairs
          |> Enum.shuffle()
          |> Enum.take(@max_pairs)
      end
    Enum.sort_by(pairs, fn {fm, _ih1, _ih2} -> fm end, :desc)
  end
  defp sort_pair(a, b) do
    case a < b do
      false -> {b, a}
      true -> {a, b}
    end
  end
  defp process_batch(batch) do
    queries_sent =
      Enum.reduce(batch, 0, fn {_score, ih1, ih2}, acc ->
        fid1 = PFMaskSync.generate_fid(ih1)
        fid2 = PFMaskSync.generate_fid(ih2)
        paint(fid1)
        scan(fid2)
        acc_upd_forumla(acc)
      end)
    GenS.PFNodesProcessor.push_queries_stats(queries_sent)
  end
  defp paint(fid), do: Sender.many_find_node([{IdGenSync.rand_id(), :pf_bootstrap}], {:fid, fid})
  defp scan(fid), do: Sender.many_find_node([{fid, :pf_bootstrap}], :nid)
  defp refresh_paint_table(filtered) do
    TryETS.delete_all(@ets_filtered_freq)
    Enum.each(filtered, &TryETS.insert(@ets_filtered_freq, &1))
  end
end