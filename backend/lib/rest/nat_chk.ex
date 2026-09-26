defmodule GenS.NATChk do
  @moduledoc """
  Comprehensive NAT type detection with traversal hints.
  """
  use GenServer
  import MagnetSorter.Const
  require Logger
  @min_observations 20
  @max_tracked_ports 5
  @local_port udp_port()
  @refresh_tick 5_000
  defstruct [
    :nat_type,
    :external_ip,
    :port_preserved,
    :port_delta,
    :predictable,
    observations_target: @min_observations,
    observations: [],
    analyzed?: false,
    refresh?: true
  ]
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  def start_analysis(target_count \\ @min_observations) do
    :telemetry.attach(
      "nat-chk-listener",
      [:gens, :udp, :packet],
      &__MODULE__.handle_telemetry/4,
      nil
    )
    GenServer.cast(__MODULE__, {:reset_stats, target_count})
  end
  def stop_analysis do
    :telemetry.detach("nat-chk-listener")
  end
  def handle_telemetry(_event, _measurements, metadata, _config) do
    %{packet: packet, ip: {a, b, c, d}, port: port} = metadata
    case packet do
      <<0x64, _rest::binary>> ->
        remote_nodev4 = <<a, b, c, d, port::16>>
        analyze(packet, remote_nodev4)
      _other ->
        :ok
    end
  end
  def analyze(packet, remote_nodev4),
    do: GenServer.cast(__MODULE__, {:analyze, packet, remote_nodev4})
  def get_nat_info(), do: GenServer.call(__MODULE__, :get_info)
  defp open_chk?(ext_ports), do: length(ext_ports) == 1 and hd(ext_ports) == @local_port
  def init(st) do
    {:ok, st, {:continue, :refresh_st_check}}
  end
  def handle_continue(:refresh_st_check, st) do
    {:noreply, st}
  end
  def handle_call(:get_info, _from, st), do: {:reply, st, st}
  def handle_cast({:reset_stats, tc}, st) do
    {:noreply, %{st | observations: [], analyzed?: false, observations_target: tc}}
  end
  def handle_cast({:analyze, packet, remote_nodev4}, %{observations_target: tc} = st)
      when is_integer(tc) do
    with {:ok, remote_ip, remote_port} <- parse_remote(remote_nodev4),
         {:ok, ext_ip, ext_port} <- parse_packet(packet) do
      obs = %{
        remote_ip: remote_ip,
        remote_port: remote_port,
        ext_ip: ext_ip,
        ext_port: ext_port,
        timestamp: System.monotonic_time(:millisecond)
      }
      new_obs =
        [obs | st.observations]
        |> Enum.take(20)
      new_st = %{st | observations: new_obs}
      case length(new_obs) >= tc and not st.analyzed? do
        false -> {:noreply, new_st}
        true -> {:noreply, analyze_nat(new_st)}
      end
    else
      {:error, _no_ip_field} ->
        {:noreply, st}
    end
  end
  def handle_info(:collect_pkts, st) do
    Process.send_after(self(), :collect_pkts, @refresh_tick)
    case length(st.observations) >= st.observations_target do
      true -> {:noreply, analyze_nat(st)}
      false -> {:noreply, st}
    end
  end
  defp parse_remote(<<a, b, c, d, port::16>>) do
    {:ok, {a, b, c, d}, port}
  end
  defp parse_remote(_malformed), do: {:error, :invalid_remote}
  defp parse_packet(packet) do
    with {:ok, map} <- SimpleBencodeSync.decode(packet),
         res_map = Map.get(map, "r", %{}),
         u_bin when is_binary(u_bin) <- Map.get(map, "ip") || Map.get(res_map, "ip"),
         <<a, b, c, d, port::16>> <- u_bin do
      {:ok, {a, b, c, d}, port}
    else
      _no_ip_field -> {:error, :no_ip_field}
    end
  end
  defp analyze_nat(st) do
    obs = st.observations
    ext_ips =
      obs
      |> Enum.map(& &1.ext_ip)
      |> Enum.uniq()
    ext_ports =
      obs
      |> Enum.map(& &1.ext_port)
      |> Enum.uniq()
    port_preserved = Enum.any?(obs, &(&1.ext_port == @local_port))
    {predictable, delta} = analyze_port_pattern(obs)
    nat_type =
      cond do
        length(ext_ips) > 1 -> :symmetric_multi_ip
        open_chk?(ext_ports) -> :open
        length(ext_ports) == 1 -> :cone
        predictable -> :symmetric_predictable
        true -> :symmetric_random
      end
    stop_analysis()
    own_ip = hd(ext_ips)
    ip_bin = <<elem(own_ip, 0), elem(own_ip, 1), elem(own_ip, 2), elem(own_ip, 3)>>
    own_port = hd(ext_ports)
    KeyStorageSync.set_nat_type(nat_type)
    KeyStorageSync.set_own_ip(ip_bin)
    KeyStorageSync.set_own_uaddr(ip_bin <> <<own_port::16>>)
    KeyStorageSync.set_nat_analyzed()
    LogManager.refresh(:own_uaddr_log, {own_ip, ext_ports})
    Logger.info("""
    [NAT] Analysis complete:
      Type: #{nat_type}
      External Identity: #{PrinterSync.ip(own_ip)}
      Port preserved: #{port_preserved}
      Predictable: #{predictable} (delta: #{inspect(delta)})
      Unique ports: #{inspect(ext_ports)}
    """)
    %{st | nat_type: nat_type, external_ip: own_ip, analyzed?: true}
  end
  defp analyze_port_pattern(obs) when length(obs) < 3, do: {false, nil}
  defp analyze_port_pattern(obs) do
    ports =
      obs
      |> Enum.sort_by(& &1.timestamp)
      |> Enum.map(& &1.ext_port)
    deltas =
      ports
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)
    case length(deltas) == 0 do
      true ->
        {false, nil}
      false ->
        avg_delta = Enum.sum(deltas) / length(deltas)
        variance = Enum.map(deltas, &abs(&1 - avg_delta)) |> Enum.sum()
        predictable = variance / length(deltas) < @max_tracked_ports
        delta = if predictable, do: round(avg_delta), else: nil
        {predictable, delta}
    end
  end
end