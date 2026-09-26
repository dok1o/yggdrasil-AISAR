defmodule GenS.TJFWriter do
  use GenServer
  import TimeSync
  require Logger
  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  @main_tjf_dir "../data/tjf"
  def write(ih, data, start_ms) do
    GenServer.cast(__MODULE__, {:write, ih, data, start_ms})
  end
  def init(_opts) do
    dir = @main_tjf_dir
    File.mkdir_p!(dir)
    current_written = count_lines(build_filepath(dir))
    {:ok, %{dir: dir, written: current_written}}
  end
  def handle_cast({:write, ih, data, start_ms}, %{dir: dir, written: writes} = st) do
    path = build_filepath(dir)
    JsonHelper.append_l(path, data)
    new_writes = writes + 1
    new_st = %{st | written: new_writes}
    maybe_log_tjf_time(ih, start_ms)
    {:noreply, new_st}
  end
  defp count_lines(path) do
    case File.exists?(path) do
      true ->
        path
        |> File.stream!()
        |> Enum.count()
      false ->
        0
    end
  end
  defp build_filepath(dir) do
    date = Calendar.strftime(Date.utc_today(), "%Y%m%d")
    Path.join(dir, "tjf_#{date}.jsonl")
  end
  defp maybe_log_tjf_time(ih, start_ms) do
    elapsed = now_ms() - start_ms
    if MathSync.rolled?(1, 20) and elapsed > 2 do
      Logger.debug("[TJF Writer] [#{PrinterSync.short_hex(ih)}] tjf file written in #{elapsed}ms")
    end
  end
end