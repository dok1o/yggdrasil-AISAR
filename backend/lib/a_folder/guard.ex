defmodule GenS.Guardian do
  use GenServer
  require Logger
  @mem_gb_limit 4
  @short_pause 1_000
  @memory_check_interval 20_000
  @reboot_interval_h 24 * 30
  @reboot_interval 1_000 * 60 * 60 * @reboot_interval_h
  @bar1 1_024 * 1_024 * 1_024 * @mem_gb_limit * 0.9
  @bar2 1_024 * 1_024 * 1_024 * @mem_gb_limit
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def request_own_uaddr, do: GenServer.cast(__MODULE__, :request_own_uaddr)
  defp schedule_fd_check(), do: Process.send_after(self(), :check_fds, 10_000)
  defp schedule_memory_check,
    do: Process.send_after(self(), :check_memory, @memory_check_interval)
  defp schedule_periodic_reboot do
    Process.send_after(self(), :periodic_reboot, @reboot_interval)
  end
  def init(_opts) do
    KeyStorageSync.set_id_mgr_ready()
    available = read_memory_data()
    Logger.info(
      "[Guard] System memory available at init: #{fmt_bytes(available)}, program auto-restart interval: each #{@reboot_interval_h} hours"
    )
    send(self(), :setup_monitors)
    Process.send_after(self(), :check_memory, @short_pause)
    schedule_periodic_reboot()
    {:ok, %{refs: %{}, init_available: available, restart_requested: false}}
  end
  def handle_cast(:request_own_uaddr, st) do
    GenS.NATChk.start_analysis(self())
    {:noreply, st}
  end
  def handle_info(:periodic_reboot, st) do
    Logger.info("[Guard] Periodic reboot triggered")
    request_supervised_restart()
    {:noreply, %{st | restart_requested: true}}
  end
  def handle_info({:nat_analysis_complete, uaddrs, _nat_type}, st) do
    Logger.info("[Guardian] NAT analysis complete. Sending addresses to GUI.")
    send_uaddrs_to_gui(uaddrs)
    {:noreply, st}
  end
  def handle_info(:setup_monitors, st) do
    refs = setup_critical_monitors([Spv.ConnSup, GenS.ConnectionsOut])
    {:noreply, %{st | refs: refs}}
  end
  def handle_info({:DOWN, ref, :process, pid, reason}, %{refs: refs} = st) do
    case Map.get(refs, ref) do
      nil ->
        {:noreply, st}
      name ->
        Logger.error("[Guard] #{name} died: #{inspect(reason)}, pid: #{inspect(pid)}")
        Process.send_after(self(), {:remonitor, name}, 1_000)
        {:noreply, %{st | refs: Map.delete(refs, ref)}}
    end
  end
  def handle_info({:remonitor, name}, st) do
    new_refs =
      case Process.whereis(name) do
        nil ->
          st.refs
        pid ->
          ref = Process.monitor(pid)
          Map.put(st.refs, ref, name)
      end
    {:noreply, %{st | refs: new_refs}}
  end
  def handle_info(:check_fds, st) do
    poll_info = :erlang.system_info(:check_io)
    used =
      Enum.reduce(poll_info, 0, fn thread, acc ->
        acc + (thread[:active_fds] || 0)
      end)
    actual_max = List.first(poll_info)[:max_fds] || 1024
    if used > actual_max * 0.8 do
      Logger.error("[Guard] FD usage critical: #{used}/#{actual_max}")
    end
    if MathSync.rolled?(1, 10) do
      Logger.info("[Guard] FD Health: #{used} used, #{actual_max} system limit")
    end
    schedule_fd_check()
    {:noreply, st}
  end
  def handle_info(:check_memory, %{restart_requested: true} = st) do
    schedule_memory_check()
    {:noreply, st}
  end
  def handle_info(:check_memory, st) do
    rss_used = MemoryReader.get_process_rss()
    beam_used = :erlang.memory(:total)
    sys = MemoryReader.get_system_stats()
    Logger.info(
      "[Guard] MEM: RSS: #{fmt_bytes(rss_used)}, BEAM: #{fmt_bytes(beam_used)}, OS: #{fmt_bytes(sys.total)} (#{sys.usage_pct}% used)"
    )
    cond do
      rss_used > @bar2 ->
        Logger.error(
          "[Guard] MEM CRITICAL: Process RSS (#{fmt_bytes(rss_used)}) exceeding #{@mem_gb_limit}GB limit! Restarting."
        )
        request_supervised_restart()
        schedule_memory_check()
        {:noreply, %{st | restart_requested: true}}
      rss_used > @bar1 ->
        Logger.error(
          "[Guard] MEM 90% threshold: Process RSS (#{fmt_bytes(rss_used)}) exceeding #{@mem_gb_limit}GB limit! Restart at 100% thr"
        )
        schedule_memory_check()
        garbage_collect()
        {:noreply, st}
      true ->
        schedule_memory_check()
        {:noreply, st}
    end
  end
  defp send_uaddrs_to_gui(uaddrs) do
    {:ok, payload} =
      Jason.encode(%{
        "event" => "backend.pf.uaddrs_list",
        "metadata" => %{
          "uaddrs" => uaddrs
        }
      })
    GenS.GUIServer.send_event(payload)
  end
  defp setup_critical_monitors(names) do
    for name <- names, pid = Process.whereis(name), pid != nil, into: %{} do
      {Process.monitor(pid), name}
    end
  end
  defp read_memory_data() do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        case Regex.run(~r/MemAvailable:\s+(\d+)\s+kB/, content) do
          [_, kb] ->
            String.to_integer(kb) * 1024
          nil ->
            case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, content) do
              [_, kb] -> String.to_integer(kb) * 1024
              nil -> default_4gb()
            end
        end
      {:error, _reason} ->
        Logger.warning("[Guard] Cannot read /proc/meminfo, assuming 4 GB")
        default_4gb()
    end
  end
  defp default_4gb, do: 4_294_967_296
  defp fmt_bytes(b) when b >= 1_073_741_824,
    do: "#{Float.round(b / 1_073_741_824, 2)} GB"
  defp fmt_bytes(b) when b >= 1_048_576,
    do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp fmt_bytes(b), do: "#{div(b, 1024)} KB"
  defp request_supervised_restart() do
    {:ok, payload} =
      Jason.encode(%{
        "event" => "backend.request_restart",
        "metadata" => %{"reason" => "memory_threshold"}
      })
    GenS.GUIServer.send_event(payload)
    drop_short_lived_tables()
    garbage_collect()
  end
  defp drop_short_lived_tables() do
    for table <- [:unv_peers, :unv_idx, :prepared_to_fetch] do
      try do
        :ets.delete_all_objects(table)
      catch
        _, _ -> :ok
      end
    end
  end
  defp garbage_collect(), do: :erlang.garbage_collect()
end
defmodule MemoryReader do
  require Logger
  @doc "Reads physical memory (RSS) used by this process. Includes NIFs/C-allocations."
  @spec get_process_rss() :: integer()
  def get_process_rss do
    case File.read("/proc/self/status") do
      {:ok, content} ->
        case Regex.run(~r/VmRSS:\s+(\d+)\s+kB/, content) do
          [_, kb] -> String.to_integer(kb) * 1024
          nil -> :erlang.memory(:total)
        end
      _ ->
        :erlang.memory(:total)
    end
  end
  @doc "Reads system-wide memory stats."
  @spec get_system_stats() :: %{total: integer(), available: integer(), usage_pct: float()}
  def get_system_stats do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        total = parse_meminfo(content, "MemTotal") || 0
        avail = parse_meminfo(content, "MemAvailable") || parse_meminfo(content, "MemFree") || 0
        used = total - avail
        pct = if total > 0, do: Float.round(used / total * 100, 1), else: 0.0
        %{total: total, available: avail, usage_pct: pct}
      _ ->
        %{total: 0, available: 0, usage_pct: 0.0}
    end
  end
  defp parse_meminfo(content, key) do
    case Regex.run(~r/#{key}:\s+(\d+)\s+kB/, content) do
      [_, kb] -> String.to_integer(kb) * 1024
      nil -> nil
    end
  end
end
defmodule ETSMemory do
  @moduledoc """
  Helper to inspect memory usage of all ETS tables in the system.
  """
  @doc """
  Logs all ETS tables sorted by memory usage (largest first).
  """
  def log_all() do
    word_size = :erlang.system_info(:wordsize)
    tables =
      :ets.all()
      |> Enum.map(fn tid ->
        %{
          name: :ets.info(tid, :name),
          tid: tid,
          size: :ets.info(tid, :size) || 0,
          memory: (:ets.info(tid, :memory) || 0) * word_size,
          type: :ets.info(tid, :type)
        }
      end)
      |> Enum.sort_by(& &1.memory, :desc)
    total_bytes = Enum.sum(Enum.map(tables, & &1.memory))
    lines =
      tables
      |> Enum.map(fn t ->
        "  #{inspect(t.name)} (#{t.type}): #{format_bytes(t.memory)}, #{t.size} objects"
      end)
      |> Enum.join("\n")
    require Logger
    Logger.info("[ETS Memory] Total: #{format_bytes(total_bytes)}\n#{lines}")
    tables
  end
  @doc """
  Returns top N tables by memory usage.
  """
  def top(n \\ 10) do
    log_all() |> Enum.take(n)
  end
  @doc """
  Quick summary - just top tables with sizes.
  """
  def summary(n \\ 15) do
    word_size = :erlang.system_info(:wordsize)
    summary =
      :ets.all()
      |> Enum.map(fn tid ->
        name = :ets.info(tid, :name)
        mem = (:ets.info(tid, :memory) || 0) * word_size
        size = :ets.info(tid, :size) || 0
        {name, mem, size}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(n)
      |> Enum.map(fn {name, mem, size} ->
        "#{inspect(name)}: #{format_bytes(mem)} (#{size})"
      end)
      |> Enum.join(", ")
    require Logger
    Logger.info("[ETS Top #{n}] #{summary}")
  end
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"
end