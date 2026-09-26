defmodule GenS.PFLog do
  use GenServer
  require Logger
  @compile {:inline, []}
  @tick_ms 1_000
  @beacon_refresh_ms 5_000
  @show_most_freq 64
  @schedule_m %{
    tick: @tick_ms,
    refresh_beacon_log: @beacon_refresh_ms
  }
  defstruct []
  def log_pong(fn4) do
    LogManager.append_line(:pf_reply_log, {nil, fn4})
    Logger.debug("[PF] === PONG DETECTED === from #{PrinterSync.peer(fn4)} ===")
  end
  def log_beacon() do
  end
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  defp schedule(msg), do: Process.send_after(self(), msg, Map.fetch!(@schedule_m, msg))
  def init(_opts) do
    st = %__MODULE__{}
    LogManager.init()
    Enum.each(Map.keys(@schedule_m), &schedule/1)
    {:ok, st}
  end
  def handle_info(:tick, st) do
    no_reply_schedule(st, :tick)
  end
  def handle_info(:refresh_beacon_log, st) do
    LogManager.refresh(:beacon_log, @show_most_freq)
    no_reply_schedule(st, :refresh_beacon_log)
  end
  defp no_reply_schedule(st, msg) do
    schedule(msg)
    {:noreply, st}
  end
end