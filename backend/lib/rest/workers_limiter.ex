defmodule GenS.ResourceLimiter do
  import TimeSync
  require Logger
  @moduledoc """
  FD-aware resource limiter with circuit breaker.
  Workers acquire slots before spawning, release on termination.
  """
  use GenServer
  @fd_safety_margin 0.975
  @fd_reserve 64
  @fds_per_worker 8
  @check_interval 60_000
  @circuit_cooldown_ms 10_000
  @stability_window_ms 20_000
  defstruct [
    :max_fds,
    :base_max_workers,
    :max_workers,
    last_successful_limit: 1,
    limit_established_at: 0,
    probing?: true,
    active: 0,
    current_fds: 0,
    circuit_open_until: nil,
    pending: :queue.new(),
    pending_count: 0
  ]
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @doc "Request a slot. Returns :ok | {:error, reason}"
  def acquire(timeout \\ 5_000) do
    GenServer.call(__MODULE__, :acquire, timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("[ workers limiter ] acquire timeout after #{timeout}ms")
      {:error, :limiter_timeout}
    :exit, {:noproc, _} ->
      {:error, :limiter_not_running}
    :exit, {:shutdown, _} ->
      {:error, :limiter_shutdown}
    :exit, reason ->
      Logger.warning("[ workers limiter ] acquire exit: #{inspect(reason)}")
      {:error, :limiter_down}
  end
  @doc "Release slot when worker terminates"
  def release, do: GenServer.cast(__MODULE__, :release)
  @doc "Report EMFILE/ENFILE - triggers circuit breaker"
  def fd_exhausted, do: GenServer.cast(__MODULE__, :fd_exhausted)
  @doc "Current capacity info"
  def stats, do: GenServer.call(__MODULE__, :stats)
  def available_slots() do
    case GenServer.call(__MODULE__, :available_slots, 1_000) do
      n when is_integer(n) -> n
      _any -> 0
    end
  catch
    :exit, _reason -> 0
  end
  def init(_opts) do
    Process.flag(:trap_exit, true)
    max_fds = detect_fd_limit()
    convergent_usable = trunc(max_fds * @fd_safety_margin) - @fd_reserve
    max_workers_conv = max(div(convergent_usable, @fds_per_worker), 1)
    _max_workers_static = 152
    st = %__MODULE__{
      max_fds: max_fds,
      max_workers: max_workers_conv,
      base_max_workers: max_workers_conv,
      last_successful_limit: max_workers_conv,
      limit_established_at: mono_ms()
    }
    schedule_check()
    {:ok, st}
  end
  def handle_call(:acquire, from, st) do
    now = mono_ms()
    cond do
      circuit_open?(st, now) ->
        remaining = st.circuit_open_until - now
        :erlang.display(
          " [ workers limiter ] acquire BLOCKED (circuit open), worker limit: #{st.max_workers}, remaining: #{remaining}ms "
        )
        {:reply, {:error, :circuit_open}, st}
      st.active < st.max_workers ->
        {:reply, :ok, %{st | active: st.active + 1}}
      true ->
        new_pending = :queue.in(from, st.pending)
        {:noreply, %{st | pending: new_pending, pending_count: st.pending_count + 1}}
    end
  end
  def handle_call(:available_slots, _from, st) do
    now = mono_ms()
    available =
      if circuit_open?(st, now) do
        0
      else
        max(0, st.max_workers - st.active)
      end
    {:reply, available, st}
  end
  def handle_cast(:release, st) do
    new_active = max(0, st.active - 1)
    {:noreply, drain_one_pending(%{st | active: new_active})}
  end
  def handle_cast(:fd_exhausted, st) do
    if MathSync.rolled?(1, 50), do: Logger.debug("[workers limiter] === EMFILE DETECTED ===")
    {:noreply, st}
  end
  def handle_cast(
        :fd_exhausted2,
        %{last_successful_limit: old_limit, max_workers: max_workers} = st
      ) do
    now = mono_ms()
    if circuit_open?(st, now) do
      {:noreply, st}
    else
      new_max = calculate_reduced_limit(old_limit, max_workers)
      :erlang.display(
        " [ workers limiter ] === EMFILE CRITICAL === Active: #{st.active}, reducing limit to #{new_max} by #{new_max - old_limit} "
      )
      old_pending = st.pending
      spawn(fn -> reject_all_pending(old_pending) end)
      new_st = %{
        st
        | circuit_open_until: now + @circuit_cooldown_ms,
          pending: :queue.new(),
          pending_count: 0,
          max_workers: new_max,
          last_successful_limit: new_max,
          limit_established_at: now,
          probing?: false
      }
      {:noreply, new_st}
    end
  end
  defp calculate_reduced_limit(old_limit, max_workers) do
    if max_workers <= old_limit do
      reduction = max(trunc(max_workers * 0.1), 5)
      max(max_workers - reduction, 5)
    else
      old_limit
    end
  end
  def handle_info(:check_fds, st) do
    current_fds = count_open_fds()
    now = mono_ms()
    {circuited_st, just_closed?} = maybe_close_circuit(st, now)
    new_st =
      circuited_st
      |> maybe_update_baseline(now)
      |> update_limits_logic(current_fds, now)
    if just_closed? do
      :erlang.display(
        " [ workers limiter ] resumed: #{new_st.active}/#{new_st.max_workers}, probing: #{new_st.probing?} "
      )
    end
    schedule_check()
    {:noreply, new_st}
  end
  def handle_info({:EXIT, pid, reason}, st) do
    :erlang.display(
      " [ workers limiter ] Linked process #{inspect(pid)} exited: #{inspect(reason)} "
    )
    {:noreply, st}
  end
  def handle_info(msg, st) do
    :erlang.display(" [ workers limiter ] Unexpected message: #{inspect(msg)} ")
    {:noreply, st}
  end
  defp maybe_update_baseline(st, now) do
    if now - st.limit_established_at > @stability_window_ms and
         st.max_workers > st.last_successful_limit do
      :erlang.display(" [ workers limiter ] New baseline: #{st.max_workers} ")
      %{st | last_successful_limit: st.max_workers}
    else
      st
    end
  end
  defp maybe_close_circuit(%{circuit_open_until: nil} = st, _now), do: {st, false}
  defp maybe_close_circuit(%{circuit_open_until: until} = st, now) when until <= now do
    :erlang.display(" [ResourceLimiter] Circuit CLOSED ")
    {%{st | circuit_open_until: nil, probing?: true}, true}
  end
  defp maybe_close_circuit(st, _now), do: {st, false}
  defp update_limits_logic(%{max_workers: old_max} = st, current_fds, now) do
    usage_ratio = current_fds / st.max_fds
    if circuit_open?(st, now) do
      st
    else
      {new_max, reason} =
        cond do
          usage_ratio > 0.95 ->
            {max(st.active - 10, 5), :fd_critical}
          st.probing? and st.active >= old_max * 0.9 ->
            {old_max + 2, :probe_expand}
          not st.probing? and usage_ratio < 0.70 ->
            {max(old_max - 1, st.base_max_workers), :recovery}
          true ->
            {old_max, :stable}
        end
      if new_max != old_max do
        new_probing =
          cond do
            usage_ratio > 0.85 -> false
            new_max >= st.base_max_workers -> true
            true -> st.probing?
          end
        :erlang.display(
          " [ workers limiter ] limit change: #{old_max} -> #{new_max} (#{reason}) "
        )
        %{st | max_workers: new_max, probing?: new_probing, limit_established_at: now}
      else
        st
      end
    end
  end
  defp drain_one_pending(%{active: active, max_workers: max} = st) when active >= max, do: st
  defp drain_one_pending(st) do
    case :queue.out(st.pending) do
      {:empty, _} ->
        st
      {{:value, from}, rest} ->
        GenServer.reply(from, :ok)
        %{st | active: st.active + 1, pending: rest, pending_count: st.pending_count - 1}
    end
  end
  defp circuit_open?(%{circuit_open_until: nil}, _now), do: false
  defp circuit_open?(%{circuit_open_until: until}, now), do: until > now
  defp reject_all_pending(queue) do
    case :queue.out(queue) do
      {:empty, _} ->
        :ok
      {{:value, from}, rest} ->
        GenServer.reply(from, {:error, :fd_exhausted})
        reject_all_pending(rest)
    end
  end
  defp detect_fd_limit do
    case :os.type() do
      {:unix, _} -> detect_unix_limit()
      {:win32, _} -> 2048
    end
  end
  defp detect_unix_limit do
    with {:error, :error_failed_internal} <- read_proc_limits(),
         {:error, :error_failed_internal} <- parse_ulimit() do
      1024
    else
      {:ok, n} -> n
    end
  end
  defp read_proc_limits() do
    with {:ok, content} <- File.read("/proc/self/limits"),
         [_, soft, _hard] <- Regex.run(~r/Max open files\s+(\d+)\s+(\d+)/, content) do
      {:ok, String.to_integer(soft)}
    else
      _err -> {:error, :error_failed_internal}
    end
  end
  defp parse_ulimit() do
    case System.cmd("sh", ["-c", "ulimit -n"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out |> String.trim() |> String.to_integer()}
      _ -> {:error, :failed}
    end
  rescue
    _err -> {:error, :error_failed_internal}
  end
  defp count_open_fds() do
    :erlang.system_info(:port_count)
  end
  defp schedule_check, do: Process.send_after(self(), :check_fds, @check_interval)
  def terminate(reason, st) do
    :erlang.display(
      " [ workers limiter ] UNEXPECTED Termination: #{inspect(reason)}, state: active=#{st.active}, pending=#{st.pending_count} "
    )
    :ok
  end
end