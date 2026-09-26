defmodule GenS.SampleCoordinator do
  use GenServer
  import MagnetSorter.Const
  import PFProtocol
  import TimeSync
  require Logger
  @compile {:inline, []}
  @typedoc "20b SHA-1 base value"
  @type ih :: <<_::160>>
  @type nodev4 :: <<_::48>>
  @ets_tables %{
    sample_inbox: %{name: :sample_inbox, type: :set},
    peers_smp_inbox: %{name: :peers_smp_inbox, type: :set},
    yield_nodes: %{name: :yield_nodes, type: :set},
    ih_recent: %{name: :ih_recent_ring, type: :set},
    ih_recent_idx: %{name: :ih_recent_idx, type: :set},
    ih_frequent: %{name: :ih_frequent, type: :set},
    tid_asked: %{name: :ets_tid_asked, type: :set},
    rid_asked: %{name: :ets_rid_asked, type: :set},
    ih_asked: %{name: :sample_ih_asked, type: :bag}
  }
  for {key, %{name: name}} <- @ets_tables do
    Module.put_attribute(__MODULE__, :"ets_#{key}", name)
  end
  @sets for {_k, v} <- @ets_tables, v.type == :set, do: v.name
  @bags for {_k, v} <- @ets_tables, v.type == :bag, do: v.name
  @send_tick 200
  @drain_offset 50
  @drain_tick @send_tick + @drain_offset
  @log_tick 15_000
  @discard_tick 1_500
  @max_inbox_size 512
  @max_ih_recent 1_024 * 16
  @max_ih_frequent 1_024 * 2
  @asked_ttl_s 20
  @max_yield_nodes 128
  @discard_num_ihs div(@max_ih_frequent, 64)
  @discard_num_nodes div(@max_yield_nodes, 64)
  @jsonl_batch_thr 256
  @max_asked_size 1_024 * 8
  @datetime Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M")
  @samples_dir "../data/logs/samples"
  @smp_log "../data/logs/samples/samples_#{@datetime}.jsonl"
  @wnd_30s_samples_bootstrap 30
  @wnd30 @wnd_30s_samples_bootstrap
  @schedule_m %{
    send: @send_tick,
    drain: @drain_tick,
    stats: @log_tick,
    discard_tick: @discard_tick
  }
  defstruct [
    :ih_next_idx,
    :tick_count,
    :total_samples_sent,
    :total_ihs_received,
    :total_gp_sent,
    :total_batched_to_pm,
    :last_log_ms,
    :sample_write_batch,
    :write_tick,
    :write_log?
  ]
  defp init_await(), do: Process.sleep(sleep_ms())
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def samples_info(asked) do
    GenServer.cast(__MODULE__, {:samples_info, asked})
  end
  @doc "Called from KRPCReply when sample_infohashes response arrives"
  def sample_response(ihs, {rid, nodev4}, tid) do
    case insert?(@ets_sample_inbox) do
      false -> :noop
      true -> GenServer.cast(__MODULE__, {:sample_response, ihs, {rid, nodev4}, tid})
    end
  end
  @doc "Called from KRPCReply when get_peers values response arrives for a sample"
  def sample_peers(ih, peers, source) do
    case insert?(@ets_peers_smp_inbox) do
      false -> :noop
      true -> GenServer.cast(__MODULE__, {:sample_peers, ih, peers, source})
    end
  end
  defp schedule(msg), do: Process.send_after(self(), msg, Map.fetch!(@schedule_m, msg))
  defp insert?(table), do: TryETS.size(table) < @max_inbox_size
  def init(_opts) do
    File.mkdir_p!(@samples_dir)
    TryETS.create_many_named(@sets, :set, :public, true, true)
    TryETS.create_many_named(@bags, :bag, :public, true, true)
    st = %__MODULE__{
      ih_next_idx: 0,
      tick_count: 0,
      total_samples_sent: 0,
      total_ihs_received: 0,
      total_gp_sent: 0,
      total_batched_to_pm: 0,
      last_log_ms: mono_ms(),
      sample_write_batch: [],
      write_tick: 0,
      write_log?: KeyStorageSync.write_samples_log?()
    }
    Enum.each(Map.keys(@schedule_m), &schedule/1)
    {:ok, st, {:continue, :startup_sequence}}
  end
  def handle_continue(:startup_sequence, st) do
    init_await()
    {:noreply, st}
  end
  def handle_cast({:samples_info, asked}, st) do
    asked
    |> Enum.each(fn {{rid, nodev4}, tid} ->
      insert_asked_idx(@ets_tid_asked, nodev4, tid)
      insert_asked_idx(@ets_rid_asked, nodev4, rid)
    end)
    {:noreply, st}
  end
  def handle_cast({:sample_response, ihs, {_rid, nodev4}, _tid}, %{write_log?: false} = st) do
    TryETS.insert(@ets_sample_inbox, {{nodev4, ihs}})
    {:noreply, st}
  end
  def handle_cast({:sample_response, ihs, {rid, nodev4}, tid}, st) do
    TryETS.insert(@ets_sample_inbox, {{nodev4, ihs}})
    new_st = match_and_queue_jsonl(st, ihs, {rid, nodev4}, tid)
    {:noreply, new_st}
  end
  def handle_cast({:sample_peers, ih, peers, source}, st) do
    TryETS.insert(@ets_peers_smp_inbox, {{ih, peers, source}})
    {:noreply, st}
  end
  def handle_info(:send, st) do
    no_reply_schedule(st, :send)
  end
  def handle_info(:drain, st) do
    new_st = do_drain_and_process(st)
    no_reply_schedule(new_st, :drain)
  end
  def handle_info(:stats, st) do
    log_stats(st)
    reset_st = reset_stats(st)
    no_reply_schedule(reset_st, :stats)
  end
  def handle_info(:discard_tick, st) do
    do_discard()
    no_reply_schedule(st, :discard_tick)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
  defp match_and_queue_jsonl(st, ihs, {rid, nodev4}, tid) do
    matched? =
      case key_nodev4_match?(@ets_tid_asked, tid, nodev4) do
        true -> true
        false -> key_nodev4_match?(@ets_rid_asked, rid, nodev4)
      end
    case matched? do
      false ->
        st
      true ->
        batch_entry = build_jsonl_entry(nodev4, ihs, rid)
        new_batch = st.sample_write_batch ++ [batch_entry]
        new_st = %{st | sample_write_batch: new_batch}
        maybe_flush_batch(new_st)
    end
  end
  defp key_nodev4_match?(table, key1, nodev4) do
    case TryETS.lookup(table, key1) do
      [{^key1, ^nodev4, _ttl}] -> true
      [_any] -> false
      [] -> false
    end
  end
  defp maybe_flush_batch(st) do
    case length(st.sample_write_batch) >= @jsonl_batch_thr or st.write_tick >= 100 do
      false ->
        %{st | write_tick: st.write_tick + 1}
      true ->
        Enum.each(st.sample_write_batch, &JsonHelper.append_l(@smp_log, &1))
        %{st | sample_write_batch: [], write_tick: 0}
    end
  end
  defp build_jsonl_entry(nodev4, ihs, rid) do
    short_uuid =
      :crypto.strong_rand_bytes(8)
      |> Base.encode16(case: :lower)
    timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.to_iso8601()
    hex_ihs =
      Enum.sort(Enum.uniq(ihs))
      |> Enum.map(&PrinterSync.full_hex/1)
    mask = generate_salt_mask(@wnd30)
    %{
      uuid: short_uuid,
      ts: timestamp,
      rid: PrinterSync.full_hex(rid),
      mask: PrinterSync.full_hex(mask),
      nodev: PrinterSync.peer(nodev4),
      ih_list: hex_ihs
    }
  end
  defp insert_asked_idx(table, nodev4, key) do
    ttl = now() + @asked_ttl_s
    if TryETS.size(table) >= @max_asked_size do
      cleanup_expired_table(table)
      if TryETS.size(table) >= @max_asked_size do
        case :ets.first(table) do
          :"$end_of_table" -> :ok
          first_key -> TryETS.delete(table, first_key)
        end
      end
    end
    :ets.insert(table, {key, nodev4, ttl})
  end
  defp cleanup_expired_table(table) do
    now_s = now()
    :ets.select_delete(table, [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", now_s}], [true]}
    ])
  end
  defp do_drain_and_process(st) do
    cleanup_expired_table(@ets_ih_asked)
    s_items = TryETS.tab2list(@ets_sample_inbox)
    p_items = TryETS.tab2list(@ets_peers_smp_inbox)
    TryETS.delete_all(@ets_peers_smp_inbox)
    TryETS.delete_all(@ets_sample_inbox)
    case s_items == [] do
      true ->
        st
      false ->
        {ihs_count, gp_count, new_idx} = process_samples(s_items, st.ih_next_idx)
        batched_count = process_peers(p_items)
        %{
          st
          | ih_next_idx: new_idx,
            total_ihs_received: st.total_ihs_received + ihs_count,
            total_gp_sent: st.total_gp_sent + gp_count,
            total_batched_to_pm: st.total_batched_to_pm + batched_count
        }
    end
  end
  defp process_samples(sample_items, ih_idx) do
    now_s = now()
    ih_sources =
      Enum.reduce(sample_items, %{}, fn {{nodev4, ihs}}, acc ->
        fresh_count = Enum.count(ihs, &ETSLookup.fresh_ih?/1)
        update_yielding_table(nodev4, fresh_count, now_s)
        Enum.reduce(ihs, acc, fn ih, a ->
          Map.update(a, ih, [nodev4], &[nodev4 | &1])
        end)
      end)
    total_ihs = map_size(ih_sources)
    {new_idx, to_send} =
      Enum.reduce(ih_sources, {ih_idx, []}, fn {ih, _sources}, {idx, send_acc} ->
        case ETSLookup.new_infohash?(ih) do
          false -> {idx, send_acc}
          true -> process_new_ih(ih, ih_sources, idx, send_acc)
        end
      end)
    gp_count = Sender.many_get_peers_samples(to_send)
    {total_ihs, gp_count, new_idx}
  end
  defp update_yielding_table(_nv4, _fc, _now_s) do
    :noop
  end
  defp process_new_ih(ih, ih_sources, idx, send_acc) do
    new_idx = track_ih_frequency(ih, idx)
    targets = ETSLookup.samples_gp_targets(ih, ih_sources)
    exp = expires_in(@asked_ttl_s)
    pairs = Enum.map(targets, &{ih, &1})
    asked_rows = Enum.map(targets, &{ih, &1, exp})
    TryETS.insert(@ets_ih_asked, asked_rows)
    {new_idx, pairs ++ send_acc}
  end
  defp process_peers(peer_items) do
    by_ih =
      Enum.reduce(peer_items, %{}, fn {{ih, peers, source}}, acc ->
        Map.update(acc, ih, [{peers, source}], &[{peers, source} | &1])
      end)
    Enum.each(by_ih, fn {ih, entries} ->
      all_peers =
        entries
        |> Enum.flat_map(fn {peers, _source} -> peers end)
        |> Enum.uniq()
      source =
        case entries do
          [{_peers, src} | _rest] -> src
          [_first | _rest] -> <<0, 0, 0, 0, 0, 0>>
        end
      GenS.PeerManager.record_unv_peers(ih, all_peers, source)
    end)
    map_size(by_ih)
  end
  defp track_ih_frequency(ih, current_idx) do
    case TryETS.member?(@ets_ih_frequent, ih) do
      true -> upd_return(ih, current_idx)
      false -> process_not_frequent(ih, current_idx)
    end
  end
  defp process_not_frequent(ih, current_idx) do
    case TryETS.lookup(@ets_ih_recent_idx, ih) do
      [{^ih, idx}] ->
        TryETS.delete(@ets_ih_recent, idx)
        TryETS.delete(@ets_ih_recent_idx, ih)
        if TryETS.size(@ets_ih_frequent) < @max_ih_frequent do
          TryETS.insert(@ets_ih_frequent, {ih, 2})
        end
        current_idx
      [] ->
        idx = rem(current_idx, @max_ih_recent)
        case TryETS.lookup(@ets_ih_recent, idx) do
          [{^idx, old_ih}] -> TryETS.delete(@ets_ih_recent_idx, old_ih)
          [] -> :ok
        end
        TryETS.insert(@ets_ih_recent, {idx, ih})
        TryETS.insert(@ets_ih_recent_idx, {ih, idx})
        rem(current_idx + 1, @max_ih_recent)
    end
  end
  defp upd_return(ih, current_idx) do
    TryETS.update_counter(@ets_ih_frequent, ih, :key, :infinite)
    current_idx
  end
  defp do_discard() do
    case TryETS.size(@ets_ih_frequent) do
      size when size > @discard_num_ihs ->
        _selected = TryETS.random_select(@ets_ih_frequent, @discard_num_ihs)
      _ ->
        :ok
    end
    case TryETS.size(@ets_yield_nodes) do
      size when size >= @max_yield_nodes ->
        selected = TryETS.random_select(@ets_yield_nodes, @discard_num_nodes)
        Logger.debug("sc to delete #{length(selected)} nodes")
        Enum.each(selected, &TryETS.delete(@ets_yield_nodes, &1))
      _ ->
        :ok
    end
  end
  defp reset_stats(st) do
    %{
      st
      | total_samples_sent: 0,
        total_ihs_received: 0,
        total_gp_sent: 0,
        total_batched_to_pm: 0,
        last_log_ms: mono_ms()
    }
  end
  defp log_stats(st) do
    elapsed_ms = mono_ms() - st.last_log_ms
    _elapsed_s = elapsed_ms / 1000
    freq_count = TryETS.size(@ets_ih_frequent)
    recent_count = TryETS.size(@ets_ih_recent_idx)
    yielding_count = TryETS.size(@ets_yield_nodes)
    asked_count = TryETS.size(@ets_ih_asked)
    ihs_rate = safe_s_rate(st.total_ihs_received, elapsed_ms)
    gp_rate = safe_s_rate(st.total_gp_sent, elapsed_ms)
    inbox_size = TryETS.size(@ets_sample_inbox) + TryETS.size(@ets_peers_smp_inbox)
    unless st.total_ihs_received == 0 do
      Logger.info(
        "[Samples] " <>
          "ihs: #{st.total_ihs_received} (#{ihs_rate}/s), " <>
          "gp: #{st.total_gp_sent} (#{gp_rate}/s), " <>
          "bd: #{st.total_batched_to_pm} | " <>
          "yld: #{yielding_count}, askd: #{asked_count}"
      )
      Logger.info(
        "[Samples] [PF] freq: #{freq_count} " <>
          "buf: #{recent_count}/#{@max_ih_recent}, " <>
          "inbox: #{inbox_size}"
      )
    end
  end
end