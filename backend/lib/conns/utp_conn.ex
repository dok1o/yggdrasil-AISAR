defmodule GenS.UTPConn do
  require Logger
  @type conn_phase :: :connecting | :connected | :draining | :closing | :closed
  use GenServer, restart: :temporary
  import TimeSync
  alias Conn.{WaiterQueue, Lifecycle, Buffer}
  alias SimpleUTP.Core
  @compile {:inline,
            [total_to_send: 1, process_send_errors: 1, retransmit_failed?: 1, utp_closed?: 1]}
  @max_recv_buffer 1_024 * 1_024 * 2
  @max_outbound_queue 1_024 * 1024 * 8
  @max_packets_drain 128
  @max_retransmits 4
  @tick_interval 500
  @handshake_timeout 4_000
  @silence_timeout 7_000
  @idle_timeout 20_000
  @orphan_timeout 3_000
  @ets_utp_conns :utp_connections
  defstruct [
    :peer,
    :owner_pid,
    :peer_pid,
    :shard_id,
    :core,
    :recv_conn_id,
    :send_conn_id,
    :tick_ref,
    :pacer_ref,
    :last_activity,
    :orphan_ref,
    :owner_ref,
    :peer_pid_ref,
    :handshake_ref,
    :recv_waiters,
    peer_closed: false,
    owner_closed: false,
    half_open: false,
    acquired: false,
    connected: false,
    recv_buffer: <<>>,
    recv_buffer_bytes: 0,
    bytes_delivered: 0,
    conn_phase: :connecting
  ]
  def start_link({peer, owner_pid, peer_pid}) do
    shard_id = MathSync.select_udp_shard(peer)
    own_conn_id = Core.rand_conn_id()
    GenServer.start_link(
      __MODULE__,
      {peer, {:outgoing, own_conn_id}, owner_pid, peer_pid, shard_id},
      name: via(peer, own_conn_id)
    )
  end
  def start_link({peer, {:incoming, syn}, owner_pid, peer_pid, shard_id}) do
    inc_conn_id = Core.get_conn_id(syn)
    GenServer.start_link(__MODULE__, {peer, {:incoming, syn}, owner_pid, peer_pid, shard_id},
      name: via(peer, inc_conn_id)
    )
  end
  defp via(peer, conn_id), do: {:via, Registry, {Reg.UTPConnRegistry, peer, conn_id}}
  defp core_initialized?(core), do: core != nil
  defp has_waiters?(rw), do: rw != nil and not :queue.is_empty(rw)
  defp dispatch_pacing(st), do: dispatch(st, Core.get_pacing_acts(st.core))
  defp cancel_timer(ref), do: if(ref, do: Process.cancel_timer(ref))
  defp schedule_pacer(ms), do: Process.send_after(self(), :pacer_tick, ms)
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
  defp stop(reason, st) when is_atom(reason), do: {:stop, {:shutdown, reason}, st}
  defp stop_utp_protocol_failed(), do: {:stop, :normal}
  def init({peer, mode, owner_pid, peer_pid, shard_id}) do
    peer_bin =
      case peer do
        <<_::48>> ->
          peer
        {{a, b, c, d}, port} ->
          <<a, b, c, d, port::16>>
      end
    Process.flag(:trap_exit, true)
    hs_ref = Process.send_after(self(), :handshake_timeout, @handshake_timeout)
    {:ok, o_ref, p_ref} = Lifecycle.setup_monitors(owner_pid, peer_pid)
    case init_core(mode) do
      {:ok, %{recv_conn_id: recv_conn_id, send_conn_id: send_conn_id} = core, actions, extra} ->
        TryETS.insert(@ets_utp_conns, {{peer_bin, recv_conn_id}, self()})
        register_utp_routes(peer_bin, recv_conn_id, send_conn_id)
        st = %__MODULE__{
          peer: peer_bin,
          owner_pid: owner_pid,
          owner_ref: o_ref,
          peer_pid: peer_pid,
          peer_pid_ref: p_ref,
          shard_id: shard_id,
          core: core,
          recv_conn_id: recv_conn_id,
          send_conn_id: send_conn_id,
          last_activity: mono_ms(),
          recv_waiters: WaiterQueue.new(),
          half_open: Map.get(extra, :half_open, false),
          acquired: Map.get(extra, :acquired, false),
          orphan_ref: Map.get(extra, :orphan_ref),
          handshake_ref: hs_ref
        }
        if MathSync.rolled?(1, 10000),
          do:
            Logger.debug(fn ->
              "[UTPConn] Started #{PrinterSync.peer(peer)} recv_id=#{recv_conn_id} ho=#{st.half_open} acq=#{st.acquired}"
            end)
        {:ok, dispatch(st, actions), {:continue, :start_tick}}
      :error ->
        Logger.warning("[UTPConn] init_core failed for #{PrinterSync.peer(peer)}")
        stop_utp_protocol_failed()
    end
  end
  defp init_core({:incoming, syn}) do
    {actions, core} = Core.accept(syn)
    case core_initialized?(core) do
      false ->
        :error
      true ->
        h_ref = Process.send_after(self(), :orphan_check, @orphan_timeout)
        new_extra = %{half_open: false, acquired: false, orphan_ref: h_ref}
        {:ok, core, actions, new_extra}
    end
  end
  defp init_core({:outgoing, own_conn_id}) do
    {actions, core} = Core.connect(own_conn_id)
    {:ok, core, actions, %{half_open: true, acquired: true}}
  end
  defp register_utp_routes(peer, recv_id, send_id) do
    TryETS.insert(@ets_utp_conns, {{peer, recv_id}, self()})
    if send_id != recv_id do
      TryETS.insert(@ets_utp_conns, {{peer, send_id}, self()})
    end
  end
  defp unregister_utp_routes(peer, recv_id, send_id) do
    TryETS.delete(@ets_utp_conns, {peer, recv_id})
    if send_id != recv_id, do: TryETS.delete(@ets_utp_conns, {peer, send_id})
  end
  def handle_continue(:start_tick, st), do: {:noreply, %{st | tick_ref: schedule_tick()}}
  def handle_call(:check_connected, _from, %{connected: conn?} = st) do
    {:reply, conn?, st}
  end
  def handle_call(:graceful_close, _from, %{core: cur_core, conn_phase: phase} = st)
      when phase in [:connected, :draining] and cur_core != nil do
    {:ok, actions, new_core} = Core.close(cur_core)
    closed_st =
      st
      |> Map.merge(%{core: new_core, conn_phase: :closing, owner_closed: true})
      |> dispatch(actions)
    {:reply, :ok, closed_st}
  end
  def handle_call(:graceful_close, _from, st), do: {:reply, :ok, st}
  def handle_call({:recv, bytes}, from, %{recv_buffer: buf, recv_waiters: rw} = st) do
    case WaiterQueue.empty?(rw) do
      false ->
        enqueue_no_reply(st, from, bytes)
      true ->
        case Buffer.try_satisfy_exact(buf, bytes) do
          {:ok, data, rest} ->
            {:reply, {:ok, data}, update_buffer_and_core(st, rest)}
          :insufficient ->
            enqueue_no_reply(st, from, bytes)
        end
    end
  end
  def handle_call({:recv_any, max_size}, _from, %{recv_buffer: buf} = st) do
    case Buffer.try_satisfy_any(buf, max_size) do
      :insufficient ->
        {:reply, :insufficient, st}
      {:ok, data, rest} ->
        {:reply, {:ok, data}, update_buffer_and_core(st, rest)}
    end
  end
  def handle_call({:recv_stream, max_size}, from, %{recv_buffer: buf, recv_waiters: rw} = st) do
    case WaiterQueue.empty?(rw) do
      false ->
        enqueue_no_reply(st, from, {:message, max_size})
      true ->
        case Buffer.try_satisfy_stream(buf, max_size) do
          {:ok, data, rest} ->
            {:reply, {:ok, data}, update_buffer_and_core(st, rest)}
          {:error, reason} ->
            {:reply, {:error, reason}, update_buffer_and_core(st, <<>>)}
          :insufficient ->
            enqueue_no_reply(st, from, {:message, max_size})
        end
    end
  end
  def handle_call(
        {:wrapped_send, data},
        _from,
        %{conn_phase: conn_ph, core: %{state: core_ph}} = st
      ) do
    case send_allowed?(conn_ph, core_ph) do
      false -> {:reply, {:error, process_send_errors(conn_ph)}, st}
      true -> do_wrapped_send(st, data)
    end
  end
  def handle_call(:bytes_rcvd?, _from, %{connected: true, bytes_delivered: b} = st) when b > 0,
    do: {:reply, true, st}
  def handle_call(:bytes_rcvd?, _from, st), do: {:reply, false, st}
  def handle_info({:utp_packet, packet}, st) do
    packets = drain_packets([packet])
    next_st =
      Enum.reduce(packets, st, fn pkt, acc ->
        core = %{acc.core | unread_bytes: acc.recv_buffer_bytes}
        {actions, new_core} = Core.receive(core, pkt)
        dispatch(%{acc | core: new_core, last_activity: mono_ms()}, actions)
      end)
    case utp_closed?(next_st) do
      true ->
        stop(:normal, next_st)
      false ->
        new_st =
          next_st
          |> maybe_connected()
          |> refresh_hs_timer()
        {:noreply, %{new_st | last_activity: mono_ms()}}
    end
  end
  def handle_info(:tick, %{last_activity: last, core: cur_core, recv_waiters: rw} = st) do
    timeout? = timeout?(last, silence_limit(has_waiters?(rw)))
    status =
      cond do
        timeout? -> :stale
        retransmit_failed?(cur_core) -> :max_retransmits
        utp_closed?(st) -> :closed
        true -> :alive
      end
    case status do
      :alive ->
        {:ok, actions, new_core} = Core.tick(cur_core)
        {:noreply, %{dispatch(st, actions) | core: new_core, tick_ref: schedule_tick()}}
      :closed ->
        WaiterQueue.reply_all(rw, {:error, :closed})
        stop(:closed, st)
      err when err in [:max_retransmits, :stale] ->
        WaiterQueue.reply_all(rw, {:error, err})
        stop(err, st)
    end
  end
  def handle_info(:orphan_check, %{owner_pid: nil, bytes_delivered: 0} = st),
    do: stop(:orphan_unused, st)
  def handle_info(:orphan_check, %{owner_pid: nil, bytes_delivered: b} = st) when b > 0 do
    if MathSync.rolled?(1, 20), do: log_closed(b)
    stop(:orphan_unclaimed, st)
  end
  def handle_info(:orphan_check, st) do
    {:noreply, %{st | orphan_ref: nil}}
  end
  def handle_info(:pacer_tick, %{core: cur_core} = st) do
    case Core.pop_paced_pkt(cur_core) do
      {:ok, actions, cur_core} ->
        st
        |> Map.merge(%{core: cur_core, pacer_ref: nil})
        |> dispatch(actions)
        |> dispatch_pacing()
        |> maybe_stop()
      {:empty, _paced_core} ->
        {:noreply, %{st | pacer_ref: nil}}
    end
  end
  def handle_info(:handshake_timeout, %{connected: false} = st) do
    if MathSync.rolled?(1, 1000),
      do: Logger.debug(fn -> "[UTPConn] Handshake timeout for #{PrinterSync.peer(st.peer)}" end)
    stop(:handshake_timeout, st)
  end
  def handle_info(:handshake_timeout, st), do: {:noreply, st}
  def handle_info(:overflow_msg, st), do: stop(:buffer_overflow, st)
  def handle_info({:EXIT, pid, reason}, st) do
    if MathSync.rolled?(1, 1000),
      do:
        Logger.warning(
          "[UTPConn] EXIT from #{inspect(pid)} reason=#{inspect(reason)} " <>
            "owner=#{inspect(st.owner_pid)} peer_pid=#{inspect(st.peer_pid)} " <>
            "connected=#{st.connected} phase=#{st.conn_phase}"
        )
    case Lifecycle.handle_exit(pid, reason, st) do
      {:clear_owner, nil} -> {:noreply, %{st | owner_pid: nil}}
      :stop -> stop(:owner_died, st)
      :ignore -> {:noreply, st}
    end
  end
  def handle_info({:DOWN, ref, :process, pid, reason}, %{recv_waiters: rw} = st) do
    if MathSync.rolled?(1, 1000),
      do:
        Logger.warning(
          "[UTPConn] DOWN ref=#{inspect(ref)} pid=#{inspect(pid)} reason=#{inspect(reason)} " <>
            "owner_ref=#{inspect(st.owner_ref)} peer_ref=#{inspect(st.peer_pid_ref)} " <>
            "connected=#{st.connected}"
        )
    case Lifecycle.handle_down(ref, pid, st, rw) do
      :stop ->
        stop(:orphaned, st)
      :clear_owner ->
        {:noreply, %{st | owner_pid: nil, owner_ref: nil}}
      :clear_peer_pid ->
        {:noreply, %{st | peer_pid: nil, peer_pid_ref: nil}}
      {:remove_waiter, ref} ->
        new_waiters = WaiterQueue.remove_by_ref(rw, ref)
        {:noreply, %{st | recv_waiters: new_waiters}}
      :ignore ->
        {:noreply, st}
    end
  end
  def handle_info(_msg, st), do: {:noreply, st}
  def handle_cast(:close, %{core: cur_core} = st) do
    {:ok, actions, new_core} = Core.close(cur_core)
    %{st | core: new_core, owner_closed: true}
    |> dispatch(actions)
    |> maybe_stop()
  end
  defp do_wrapped_send(%{core: %{state: state}} = st, _data)
       when state in [:closed, :fin_sent],
       do: {:reply, {:error, :closed}, st}
  defp do_wrapped_send(%{core: core} = st, data) do
    total = total_to_send(st)
    case total > @max_outbound_queue do
      true ->
        {:reply, {:error, :busy}, st}
      false ->
        case Core.send_data(core, :erlang.iolist_to_binary(data)) do
          {:ok, actions, core} -> {:reply, :ok, dispatch(%{st | core: core}, actions)}
          {:error, :busy, _core} -> {:reply, {:error, :busy}, st}
          {:error, reason, core} -> {:reply, {:error, reason}, %{st | core: core}}
        end
    end
  end
  defp dispatch(%{peer: peer, shard_id: shard_id} = st, actions) do
    Enum.reduce(actions, st, fn
      {:send_pkt, bin}, acc ->
        <<a, b, c, d, port::16>> = peer
        GenS.UDPSocketShard.send_packet(shard_id, {a, b, c, d}, port, bin)
        acc
      {:deliver, bin}, acc ->
        inc_size = :erlang.iolist_size(bin)
        if acc.acquired and inc_size > 0, do: GenS.Metrics.increment(:utp_data_ok)
        deliver_data(acc, bin, inc_size)
      {:start_pacer, ms}, acc ->
        if acc.pacer_ref, do: cancel_timer(acc.pacer_ref)
        %{acc | pacer_ref: schedule_pacer(ms)}
      :stop_pacer, acc ->
        if acc.pacer_ref, do: cancel_timer(acc.pacer_ref)
        %{acc | pacer_ref: nil}
      :close_socket, acc ->
        if acc.owner_pid, do: send(acc.owner_pid, {:utp_closed, self()})
        %{acc | conn_phase: :closed}
      :peer_closed, acc ->
        if acc.owner_pid, do: send(acc.owner_pid, {:utp_peer_closed, self()})
        %{acc | peer_closed: true}
      :close_session, acc ->
        %{acc | conn_phase: :closed}
    end)
  end
  defp enqueue_no_reply(%{recv_waiters: rw} = st, from, request) do
    new_w = WaiterQueue.enqueue(rw, from, request)
    {:noreply, %{st | recv_waiters: new_w}}
  end
  defp silence_limit(true), do: @silence_timeout
  defp silence_limit(false), do: @idle_timeout
  defp retransmit_failed?(%{send_buffer: buf} = _core) do
    not :gb_trees.is_empty(buf) and
      elem(elem(:gb_trees.smallest(buf), 1), 3) > @max_retransmits
  end
  defp total_to_send(%{core: %{send_buffer_bytes: sbb, out_buffer: ob}} = _st),
    do: sbb + :erlang.iolist_size(ob)
  defp update_buffer_and_core(%{core: core} = st, new_buffer) do
    size = byte_size(new_buffer)
    new_core = Core.set_unread_bytes(core, size)
    %{st | recv_buffer: new_buffer, recv_buffer_bytes: size, core: new_core}
  end
  defp deliver_data(
         %{
           recv_buffer_bytes: recv_bytes,
           recv_buffer: r_buf,
           recv_waiters: rw,
           bytes_delivered: bytes_delvd
         } = st,
         data,
         inc_size
       ) do
    new_size = recv_bytes + inc_size
    case new_size > @max_recv_buffer do
      true ->
        WaiterQueue.reply_all(rw, {:error, :buffer_overflow})
        send(self(), :overflow_msg)
        %{st | recv_waiters: WaiterQueue.new()}
      false ->
        incoming = :erlang.iolist_to_binary(data)
        new_buf = r_buf <> incoming
        {new_waiters, final_buf} = WaiterQueue.satisfy_while(rw, new_buf)
        new_st = update_buffer_and_core(st, final_buf)
        %{new_st | recv_waiters: new_waiters, bytes_delivered: bytes_delvd + inc_size}
    end
  end
  defp maybe_connected(
         %{
           conn_phase: :connecting,
           core: %{state: :connected},
           half_open: ho,
           acquired: acq,
           peer: peer,
           peer_pid: peer_pid,
           handshake_ref: hs_ref
         } = st
       ) do
    process_connected(st, peer_pid, peer, ho, acq, hs_ref)
  end
  defp maybe_connected(st), do: st
  defp process_connected(st, peer_pid, _peer, ho, acq, hs_ref) do
    cancel_timer(hs_ref)
    notify_owner(peer_pid, {:connected, {:utp, self()}})
    if ho, do: GenS.ConnectionsOut.utp_connected()
    if acq, do: GenS.Metrics.increment(:utp_connected)
    %{st | conn_phase: :connected, connected: true, half_open: false, handshake_ref: nil}
  end
  defp notify_owner(pid, msg) when is_pid(pid), do: send(pid, msg)
  defp notify_owner(_pid, _msg), do: :noop
  defp refresh_hs_timer(%{connected: false, handshake_ref: hs_ref} = st) do
    cancel_timer(hs_ref)
    %{st | handshake_ref: Process.send_after(self(), :handshake_timeout, @handshake_timeout)}
  end
  defp refresh_hs_timer(st), do: st
  defp process_send_errors(:connecting), do: :not_connected
  defp process_send_errors(:draining), do: :draining
  defp process_send_errors(:closing), do: :closing
  defp process_send_errors(:closed), do: :closed
  defp process_send_errors(_other), do: :not_ready
  defp drain_packets(acc) when length(acc) >= @max_packets_drain, do: Enum.reverse(acc)
  defp drain_packets(acc) do
    receive do
      {:utp_packet, pkt} -> drain_packets([pkt | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
  defp utp_closed?(%{conn_phase: :closed}), do: true
  defp utp_closed?(%{core: %{state: :closed}}), do: true
  defp utp_closed?(_), do: false
  defp maybe_stop(st) do
    case utp_closed?(st) do
      true -> stop(:normal, st)
      false -> {:noreply, st}
    end
  end
  defp log_closed(68), do: :noop
  defp log_closed(b), do: Logger.warning("[UTPConn] Orphaned with #{b} bytes, closed")
  def terminate(
        reason,
        %{peer: peer, half_open: ho, acquired: acq, recv_conn_id: recv_id, send_conn_id: send_id} =
          st
      ) do
    try do
      normalized = Conn.Error.normalize(reason)
      if MathSync.rolled?(1, 10000) do
        Logger.warning(
          "[UTPConn] ✗ TERM peer=#{PrinterSync.peer(peer)}, bytes=#{st.bytes_delivered}, reason=#{inspect(normalized)}"
        )
      end
      unregister_utp_routes(peer, recv_id, send_id || recv_id)
      if ho, do: GenS.ConnectionsOut.utp_connected()
      if acq, do: GenS.ConnectionsOut.release(:utp, peer)
      WaiterQueue.reply_all(st.recv_waiters, {:error, normalized})
      cancel_timer(st.tick_ref)
      cancel_timer(st.pacer_ref)
    catch
      _kind, _reason ->
        :noop
    end
  end
  defp send_allowed?(conn_ph, core_ph)
       when core_ph == :connected and conn_ph in [:connecting, :connected, :draining],
       do: true
  defp send_allowed?(conn_ph, _core_ph), do: conn_ph in [:connected, :draining]
end