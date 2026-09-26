defmodule GenS.UDPSocketShard do
  @moduledoc """
  Individual UDP socket shard. Handles both DHT and uTP traffic.
  Key optimizations:
  - SO_REUSEPORT allows multiple sockets on same port
  - Kernel load-balances by 4-tuple hash
  - Protocol detection inline (no function call overhead)
  - uTP routing via ETS (lock-free concurrent reads)
  """
  use GenServer
  import MagnetSorter.Const
  require Logger
  defp via(shard_id), do: {:via, Registry, {Reg.UDPShardRegistry, {:shard, shard_id}}}
  def start_link(shard_id), do: GenServer.start_link(__MODULE__, shard_id, name: via(shard_id))
  @port udp_port()
  @active 96
  @max_buffer_size 1024 * 1024 * 4
  @max_mainline_msg_size 1420
  @udp_port_opts [
    :binary,
    {:active, @active},
    {:reuseaddr, true},
    {:recbuf, @max_buffer_size},
    {:sndbuf, @max_buffer_size}
  ]
  @st_fin 1
  @st_state 2
  @st_reset 3
  @st_syn 4
  @max_udp_queue 1024 * 8
  @min_pkt_size 16
  @max_send_queue 1_024 * 8
  @ets_utp_conns :utp_connections
  @dht_marker 0x64
  @pf_marker 0x66
  @pf_ver 0x01
  @pf_header_size 32
  @max_pf_pkt_size 1200
  defstruct [
    :socket,
    :shard_id,
    :so_reuseport
  ]
  def send_packet(shard_id, ip_tuple, port, packet),
    do: GenServer.cast(via(shard_id), {:send, ip_tuple, port, packet})
  def init(shard_id) do
    so_reuseport_arg =
      case KeyStorageSync.get_os_rules_atom() do
        :linux_rules -> [{:raw, 1, 15, <<1::32-native>>}]
        :mac_rules -> [{:reuseport, true}]
        :non_unix_rules -> []
      end
    st = %__MODULE__{shard_id: shard_id, so_reuseport: so_reuseport_arg}
    {:ok, st, {:continue, :start_shard}}
  end
  def handle_continue(:start_shard, %{shard_id: shard_id, so_reuseport: so_reuseport_arg} = st) do
    udp_args = @udp_port_opts ++ so_reuseport_arg
    case :gen_udp.open(@port, udp_args) do
      {:ok, socket} ->
        Registry.update_value(
          Reg.UDPShardRegistry,
          {:shard, shard_id},
          fn _old_val -> socket end
        )
        new_st = %{st | socket: socket}
        {:noreply, new_st}
      {:error, reason} ->
        Logger.error("[UDP #{shard_id}] Failed to bind port #{@port}: #{inspect(reason)}")
        Stop.app_stop(reason)
    end
  end
  def handle_cast({:send, ip_tuple, port, packet}, %{socket: socket} = st) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    cond do
      len > @max_send_queue and MathSync.rolled?(1, 1500) ->
        Logger.debug("[UDP #{st.shard_id}] Dropping outgoing, queue: #{len}")
      true ->
        do_send(socket, ip_tuple, port, packet)
    end
    {:noreply, st}
  end
  def handle_info({:udp, _socket, _ipv4, 0, _packet}, st), do: {:noreply, st}
  def handle_info(
        {:udp, _socket, {a, b, c, d}, port, packet},
        %{shard_id: shard_id} = st
      )
      when byte_size(packet) > @min_pkt_size do
    process_packet(packet, {a, b, c, d}, port, shard_id)
    {:noreply, st}
  end
  def handle_info({:udp, _socket, _ip, _port, _packet}, st), do: {:noreply, st}
  def handle_info({:udp_passive, socket}, st) do
    case :inet.setopts(socket, active: @active) do
      :ok ->
        {:noreply, st}
      {:error, reason} ->
        Logger.error("[UDP] Failed to reactivate socket: #{inspect(reason)}")
        {:stop, {:socket_error, reason}, st}
    end
  end
  def handle_info({:utp_data, conn_pid, data}, st) do
    Logger.warning(
      "[UDP] Received utp_data from #{inspect(conn_pid)}, " <>
        "shard should not be owner. Data: #{byte_size(data)} bytes"
    )
    {:noreply, st}
  end
  def handle_info(msg, st) do
    Logger.warning("[UDP recv] Unexpected message: #{inspect(msg)}")
    {:noreply, st}
  end
  defp do_send(socket, ip_tuple, port, packet) do
    case :gen_udp.send(socket, ip_tuple, port, packet) do
      :ok ->
        :ok
      {:error, r} when r in [:eperm, :eagain] ->
        :ok
      {:error, :einval} ->
        Logger.debug("[UDP] Send error: :einval, addr: #{inspect(ip_tuple)}:#{inspect(port)}")
      {:error, reason} ->
        Logger.debug("[UDP] Send error: #{inspect(reason)}")
    end
  end
  defp process_packet(<<@dht_marker, _rest::binary>> = pkt, ipv4, port, sh_id)
       when byte_size(pkt) <= @max_mainline_msg_size,
       do: work_dht_pkt(pkt, ipv4, port, sh_id)
  defp process_packet(<<@pf_marker, @pf_ver, _rest::binary>> = pkt, ipv4, port, _sh_id)
       when byte_size(pkt) >= @pf_header_size and byte_size(pkt) <= @max_pf_pkt_size do
    work_pf_pkt(pkt, ipv4, port)
  end
  defp process_packet(
         <<type::4, 1::4, _ext, conn_id::16, _rest::binary>> = packet,
         {a, b, c, d} = _ipv4,
         port,
         shard_id
       ) do
    peer = <<a, b, c, d, port::16>>
    case :ets.lookup(@ets_utp_conns, {peer, conn_id}) do
      [{{^peer, ^conn_id}, pid}] when is_pid(pid) ->
        case Process.alive?(pid) do
          true ->
            send(pid, {:utp_packet, :binary.copy(packet)})
          false ->
            :ets.delete(@ets_utp_conns, {peer, conn_id})
            route_utp_packet(type, conn_id, packet, peer, shard_id)
        end
      _miss ->
        if MathSync.rolled?(1, 6000),
          do:
            Logger.debug(fn ->
              "[UDP] uTP ETS miss type=#{type} conn_id=#{conn_id} peer=#{PrinterSync.peer(peer)}"
            end)
        route_utp_packet(type, conn_id, packet, peer, shard_id)
    end
  end
  defp process_packet(<<first_byte, _rest::binary>> = packet, _ip_t, _port, _shard_id)
       when first_byte in [0x40, 0xC3, 0xC2, ?A, 0x00, 0x4C] do
    case packet do
      <<0x40, _rest::binary>> ->
        :biglybt_new_dht_noise
      <<0xC3, _rest::binary>> ->
        :azureus_dht_msg
      <<0xC2, _rest::binary>> ->
        :azureus_keepalive_old
      <<?A, ?Z, _rest::binary>> ->
        :azureus_tcp_spillover
      <<0::size(512), _rest2::binary>> ->
        :azureus_keepalive_64zero
      <<0x4C, _rest::binary-9, 0, 0, 0, 24, _rest2::binary>> ->
        :xunlei_holepunching
      _other ->
        :noop
    end
  end
  defp process_packet(<<_fb, _rest::binary>> = _packet, _ip_t, _port, _shard_id) do
    :noop
  end
  defp route_utp_packet(type, _conn_id, packet, peer, shard_id)
       when type in [@st_syn, @st_state] do
    case type do
      @st_syn ->
        maybe_start_incoming_conn(peer, packet, shard_id)
      @st_state ->
        :noop
    end
  rescue
    ArgumentError -> :noop
  end
  defp route_utp_packet(@st_reset, _conn_id, _packet, _peer, _shard_id) do
    GenS.Metrics.increment(:utp_resets)
    :noop
  end
  defp route_utp_packet(@st_fin, _conn_id, _packet, _peer, _shard_id), do: :noop
  defp route_utp_packet(type, conn_id, _packet, peer, _shard_id) do
    if MathSync.rolled?(1, 10000) do
      if type == 0 do
        Logger.error(
          "[UDP] DATA packet missed ETS! conn_id=#{conn_id} peer=#{PrinterSync.peer(peer)}"
        )
      end
      Logger.debug(fn ->
        "[UDP] Stray uTP type=#{type} conn_id=#{conn_id} from=#{PrinterSync.peer(peer)}"
      end)
    end
  end
  defp work_dht_pkt(packet, ipv4, port, shard_id) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} when len < @max_udp_queue ->
        Spawn.krpc_worker_task(packet, ipv4, port, shard_id)
      _busy ->
        GenS.Metrics.increment(:dropped_packets)
    end
  end
  defp work_pf_pkt(
         <<_marker_and_ver::16, pf_txid::32, _reserved::32, frid::160, opcode::16, msg::binary>> =
           _packet,
         ipv4,
         port
       ) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} when len < @max_udp_queue ->
        Spawn.pf_worker_task(pf_txid, frid, opcode, msg, ipv4, port)
      _busy ->
        GenS.Metrics.increment(:dropped_packets)
    end
  end
  defp work_pf_pkt(_packet, _ipv4, _port) do
    GenS.Metrics.increment(:dropped_packets)
    :noop
  end
  defp maybe_start_incoming_conn(peer, packet, shard_id) do
    if GenS.ConnectionsOut.utp_syn_allowed?(peer) do
      {owner_pid, peed_pid} = {nil, nil}
      args = {peer, {:incoming, :binary.copy(packet)}, owner_pid, peed_pid, shard_id}
      case Spv.UTPIncomingConnSup.start_conn(args) do
        {:ok, _pid} ->
          :ok
        {:error, reason} ->
          if MathSync.rolled?(1, 1000) do
            Logger.debug(
              "[UDP] Failed to start UTP conn with #{PrinterSync.peer(peer)}, reason: #{inspect(reason)}"
            )
          end
          :noop
      end
    end
  end
end