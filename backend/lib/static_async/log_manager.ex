defmodule LogManager do
  import TimeSync
  import MagnetSorter.Const
  require Logger
  @moduledoc """
  Static module for managing log files.
  Provides functions to initialize, append, refresh, increment, and delete logs.
  """
  @pf_out_log "../data/logs/pf_out.log"
  @own_uaddr_log "../data/logs/own_uaddr.log"
  @pf_reply_log "../data/logs/pf_reply.log"
  @beacons_log "../data/logs/beacons.log"
  @pingx_cnt_log "../data/logs/pingx_cnt.log"
  @logs %{
    pf_out_log: @pf_out_log,
    own_uaddr_log: @own_uaddr_log,
    pf_reply_log: @pf_reply_log,
    beacon_log: @beacons_log,
    pingx_cnt_log: @pingx_cnt_log
  }
  @doc """
  Initializes the log manager by deleting existing logs and creating fresh files.
  """
  def init() do
    Enum.each(@logs, fn {atom, _path} -> delete(atom) end)
    Enum.each(@logs, fn {_, path} ->
      File.mkdir_p(Path.dirname(path))
      File.write!(path, "")
    end)
    :ok
  end
  @doc """
  Deletes/trashes the log file using `gio trash`. Falls back to renaming to `.bak` if unavailable.
  """
  def delete(atom) do
    path = Map.fetch!(@logs, atom)
    unless File.exists?(path) do
      :ok
    else
      case System.cmd("gio", ["trash", "--force", path], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok
        _ ->
          backup = path <> ".bak"
          File.rm(backup)
          File.rename(path, backup)
          :ok
      end
    end
  end
  @doc """
  Appends a formatted line to the specified log file.
  """
  def append_line(atom, params) do
    path = Map.fetch!(@logs, atom)
    line = format_log_line(atom, params)
    File.write!(path, line <> "\n", [:append])
  end
  @doc """
  Overwrites the specified log file with a formatted line.
  """
  def refresh(atom, params) do
    path = Map.fetch!(@logs, atom)
    line = format_refresh_file(atom, params)
    tmp_path = "#{path}.tmp"
    case File.write(tmp_path, line <> "\n") do
      :ok ->
        File.rename(tmp_path, path)
      {:error, reason} ->
        Logger.debug("Failed to refresh #{atom}: #{inspect(reason)}")
        File.rm(tmp_path)
    end
  end
  @doc """
  Reads an integer from the log file, increments it by 1, and writes it back.
  """
  def increment(atom) do
    path = Map.fetch!(@logs, atom)
    current =
      case File.read(path) do
        {:ok, ""} -> 0
        {:ok, content} -> String.trim(content) |> String.to_integer()
        {:error, :enoent} -> 0
        {:error, _reason} -> 0
      end
    File.write!(path, to_string(current + 1))
  end
  def scan_ports({a, b, c, d}) do
    ip_str = "#{a}.#{b}.#{c}.#{d}"
    base_ports = [udp_port()]
    parsed_ports =
      case File.read(@pf_out_log) do
        {:ok, content} ->
          content
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.contains?(&1, ip_str))
          |> Enum.flat_map(fn line ->
            case String.split(line, " -- ", parts: 3) do
              [_date, _query, ip_port] ->
                case String.split(ip_port, ":", parts: 2) do
                  [^ip_str, port_str] ->
                    case Integer.parse(port_str) do
                      {port, ""} -> [port]
                      _ -> []
                    end
                  _ ->
                    []
                end
              _ ->
                []
            end
          end)
        {:error, :enoent} ->
          []
        {:error, reason} ->
          Logger.warning("Failed to scan log for IP #{inspect(ip_str)}: #{inspect(reason)}")
          []
      end
    (base_ports ++ parsed_ports)
    |> Enum.uniq()
  end
  defp format_log_line(:pf_out_log, {query_name, fn4}) do
    "#{log_datetime()} -- #{query_name} -- #{PrinterSync.peer(fn4)}"
  end
  defp format_log_line(:pf_reply_log, {reply_details, fn4}) do
    ip_port = "#{PrinterSync.peer(fn4)}"
    if is_nil(reply_details) do
      "#{log_datetime()} -- #{ip_port}"
    else
      "#{log_datetime()} -- #{reply_details} -- #{ip_port}"
    end
  end
  defp format_log_line(:beacon_log, {sha1_hex, freq}) do
    four_prefix = String.slice(sha1_hex, 0, 4)
    six_prefix = String.slice(sha1_hex, 0, 6)
    six_suffix = String.slice(sha1_hex, 34, 6)
    "#{four_prefix} -- #{String.pad_leading(to_string(freq), 2, " ")} -- [#{six_prefix}...#{six_suffix}]"
  end
  defp format_refresh_file(:own_uaddr_log, {ipv4, ports}) do
    port_str = Enum.map_join(ports, ", ", &to_string/1)
    "#{PrinterSync.ip(ipv4)} [#{port_str}]"
  end
  defp format_refresh_file(:beacon_log, count) do
    ETSLookup.get_filtered_freq(count)
    |> Enum.map(fn {ih, freq} ->
      format_log_line(:beacon_log, {PrinterSync.full_hex(ih), freq})
    end)
    |> Enum.join("\n")
  end
end