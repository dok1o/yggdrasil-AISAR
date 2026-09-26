defmodule TimeSync do
  import Bitwise
  @doc "Current monotonic time in milliseconds."
  def mono_ms(), do: System.monotonic_time(:millisecond)
  @doc "Current monotonic time in microseconds, masked to 32-bit."
  def mono_micro() do
    System.monotonic_time(:microsecond) &&& 0xFFFFFFFF
  end
  @doc "Calculates milliseconds remaining until the given deadline."
  def deadline_in(deadline_ms) do
    max(0, deadline_ms - System.monotonic_time(:millisecond))
  end
  def set_deadline(timeout_ms) do
    timeout_ms + System.monotonic_time(:millisecond)
  end
  @doc "Returns true if the monotonic deadline has been passed."
  def deadline?(deadline_ms) do
    deadline_ms < System.monotonic_time(:millisecond)
  end
  @doc """
  Calculates remaining time based on a start time and a duration (timeout).
  Returns 0 if the timeout has already passed.
  """
  def remaining_ms(start_ms, timeout_ms) do
    max(0, timeout_ms - (System.monotonic_time(:millisecond) - start_ms))
  end
  @doc """
  Checks if the elapsed time since `start_ms` has exceeded the `timeout_ms`.
  """
  def timeout?(start_ms, timeout_ms) do
    System.monotonic_time(:millisecond) - start_ms > timeout_ms
  end
  @doc "Current system time in seconds."
  def now(), do: System.system_time(:second)
  @doc "Current system time in milliseconds."
  def now_ms(), do: System.system_time(:millisecond)
  @doc "Calculates a future system time (seconds) based on a TTL."
  def expires_in(seconds) do
    max(0, System.system_time(:second) + seconds)
  end
  @doc "Returns true if the system time has passed the given TTL timestamp."
  def expired?(ttl_seconds) do
    ttl_seconds < System.system_time(:second)
  end
  def safe_h_rate(total, time) when time > 0, do: Float.round(total / time * 3_600_000, 1)
  def safe_h_rate(_total, _time), do: 0.0
  def safe_s_rate(total, time) when time > 0, do: Float.round(total / time * 1_000, 1)
  def safe_s_rate(_total, _time), do: 0.0
  def log_datetime() do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d_%H%M%S")
  end
end