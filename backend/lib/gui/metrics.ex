defmodule GenS.Metrics do
  @moduledoc """
  High-performance metrics collector using ETS for atomic increments
  and a GenServer for periodic broadcasting.
  """
  use GenServer
  import TimeSync
  require Logger
  @ets_metrics :gui_metrics
  @ets_dht_blacklist :dht_blacklist
  @ets_failed_peers :failed_peers
  @gui_tick 150
  @utm_rate_min_samples 25
  @diff_metrics [
    :recvd,
    :excluded_node,
    :infohash,
    :ping,
    :announce,
    :dropped_packets,
    :announce_failed,
    :dht_node_blacklisted,
    :peers_tried,
    :peer_ext,
    :utm_downloaded_via_utp,
    :utm_downloaded_via_tcp,
    :gp_replies,
    :utp_attempts,
    :utp_resets,
    :utp_data_ok,
    :utp_connected,
    :base_worker,
    :announce_worker,
    :fnode,
    :fping,
    :fnx,
    :fnode_ack,
    :pf_signals,
    :pf_seek,
    :pf_rdv_hit,
    :pf_file_chunks,
    :pf_file_ok,
    :pf_file_fail
  ]
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def increment(m) when m in @diff_metrics, do: TryETS.update_counter(@ets_metrics, m)
  defp schedule_broadcast(), do: Process.send_after(self(), :broadcast_metrics, @gui_tick)
  def init(_opts) do
    TryETS.create_named(@ets_metrics, :set, :public, true, true)
    initial_counts =
      Map.new(@diff_metrics, fn k ->
        TryETS.insert(@ets_metrics, {k, 0})
        {k, 0}
      end)
    st = %{last_sent: initial_counts, started_at: mono_ms()}
    schedule_broadcast()
    KeyStorageSync.set_gui_metrics_ready()
    {:ok, st}
  end
  def handle_info(:broadcast_metrics, %{last_sent: ls, started_at: strd} = st) do
    current_counts = read_diff_counters()
    diffs = compute_diffs(current_counts, ls)
    abs = compute_abs_metrics(strd, current_counts)
    send_metrics_to_gui(diffs, abs, current_counts)
    new_st = %{st | last_sent: current_counts}
    schedule_broadcast()
    {:noreply, new_st}
  end
  def handle_info(_msg, st), do: {:noreply, st}
  defp read_diff_counters() do
    Map.new(@diff_metrics, fn k ->
      case TryETS.lookup(@ets_metrics, k) do
        [{_key, v}] -> {k, v}
        [] -> {k, 0}
      end
    end)
  end
  defp compute_diffs(current, last) do
    Map.new(@diff_metrics, fn k ->
      {k, Map.get(current, k, 0) - Map.get(last, k, 0)}
    end)
  end
  defp compute_abs_metrics(started_at, counts) do
    runtime = mono_ms() - started_at
    utm_total =
      Map.get(counts, :utm_downloaded_via_utp, 0) +
        Map.get(counts, :utm_downloaded_via_tcp, 0)
    enough_utms? = utm_total >= @utm_rate_min_samples
    utm_rate =
      case enough_utms? do
        false -> 0.0
        true -> safe_h_rate(utm_total, runtime)
      end
    %{
      runtime: runtime,
      utm_rate: utm_rate,
      dht_blacklist_size: TryETS.size(@ets_dht_blacklist),
      failed_peers_size: TryETS.size(@ets_failed_peers)
    }
  end
  defp send_metrics_to_gui(diffs, abs, totals) do
    payload = %{
      event: "backend.status.update",
      metadata: %{
        diffs: diffs,
        abs: abs,
        totals: totals
      }
    }
    with {:ok, json} <- Jason.encode(payload),
         pid when is_pid(pid) <- Process.whereis(GenS.GUIServer) do
      GenServer.cast(pid, {:send, json <> "\n"})
    else
      nil -> :ok
      {:error, reason} -> Logger.error("[Metrics] JSON error: #{inspect(reason)}")
    end
  end
end