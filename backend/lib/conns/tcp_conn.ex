defmodule GenS.TCPConn do
  use GenServer, restart: :temporary
  alias Conn.{WaiterQueue, Lifecycle, Buffer}
  @max_buffer_size 1_024 * 1_024 * 2
  @connect_timeout 3_500
  @stale_timeout 8_000
  @tcp_opts [
    :binary,
    active: :once,
    packet: :raw,
    nodelay: true,
    reuseaddr: true,
    linger: {true, 0},
    send_timeout: @connect_timeout,
    send_timeout_close: true
  ]
  defstruct [
    :peer,
    :owner_pid,
    :peer_pid,
    :owner_ref,
    :peer_pid_ref,
    :sock,
    connected: false,
    buffer: <<>>,
    recv_waiters: nil
  ]
  def start_link({peer, owner_pid, peer_pid}),
    do: GenServer.start_link(__MODULE__, {peer, owner_pid, peer_pid})
  defp stop(reason, st) when is_atom(reason), do: {:stop, {:shutdown, reason}, st}
  def init({peer, owner_pid, peer_pid}) do
    Process.flag(:trap_exit, true)
    {:ok, o_ref, p_ref} = Lifecycle.setup_monitors(owner_pid, peer_pid)
    st = %__MODULE__{
      peer: peer,
      owner_pid: owner_pid,
      owner_ref: o_ref,
      peer_pid: peer_pid,
      peer_pid_ref: p_ref,
      recv_waiters: WaiterQueue.new()
    }
    {:ok, st, {:continue, :connect}}
  end
  def handle_continue(:connect, %{peer: peer, peer_pid: p_pid} = st) do
    <<a, b, c, d, port::16>> = peer
    case :gen_tcp.connect({a, b, c, d}, port, @tcp_opts, @connect_timeout) do
      {:ok, sock} ->
        notify_connected(p_pid)
        {:noreply, %{st | sock: sock, connected: true}, @stale_timeout}
      {:error, :emfile} ->
        GenS.ResourceLimiter.fd_exhausted()
        stop(:emfile, st)
      {:error, reason} ->
        stop(reason, st)
    end
  end
  def handle_info({:tcp, sock, data}, %{buffer: buffer, recv_waiters: rw} = st) do
    new_buf = buffer <> data
    case byte_size(new_buf) > @max_buffer_size do
      true ->
        stop(:buffer_overflow, st)
      false ->
        {new_w, final_buf} = WaiterQueue.satisfy_while(rw, new_buf)
        maybe_rearm_socket(sock, final_buf)
        {:noreply, %{st | buffer: final_buf, recv_waiters: new_w}, @stale_timeout}
    end
  end
  def handle_info({:tcp_closed, _var}, st), do: stop(:closed, st)
  def handle_info({:tcp_error, _var, reason}, st), do: stop(reason, st)
  def handle_info(:timeout, st), do: stop(:stale, st)
  def handle_info({:EXIT, pid, reason}, st) do
    case Lifecycle.handle_exit(pid, reason, st) do
      {:clear_owner, nil} -> {:noreply, %{st | owner_pid: nil}, @stale_timeout}
      :ignore -> {:noreply, st, @stale_timeout}
      :stop -> stop(:owner_died, st)
    end
  end
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{recv_waiters: recv_waiters} = st) do
    case Lifecycle.handle_down(ref, pid, st, recv_waiters) do
      :stop ->
        stop(:orphaned, st)
      :clear_owner ->
        {:noreply, %{st | owner_pid: nil, owner_ref: nil}, @stale_timeout}
      :clear_peer_pid ->
        {:noreply, %{st | peer_pid: nil, peer_pid_ref: nil}, @stale_timeout}
      {:remove_waiter, ref} ->
        new_waiters = WaiterQueue.remove_by_ref(recv_waiters, ref)
        {:noreply, %{st | recv_waiters: new_waiters}, @stale_timeout}
      :ignore ->
        {:noreply, st, @stale_timeout}
    end
  end
  def handle_call(:check_connected, {pid, _ref}, %{connected: conn?} = st) do
    if conn?, do: notify_connected(pid)
    {:reply, conn?, st, @stale_timeout}
  end
  def handle_call({:recv, bytes}, from, %{sock: s, buffer: buf, recv_waiters: rw} = st) do
    case WaiterQueue.empty?(rw) do
      false ->
        maybe_rearm_socket(s, buf)
        enqueue_no_reply(st, rw, from, bytes)
      true ->
        case Buffer.try_satisfy_exact(buf, bytes) do
          {:ok, data, rest} ->
            maybe_rearm_socket(s, rest)
            {:reply, {:ok, data}, %{st | buffer: rest}, @stale_timeout}
          :insufficient ->
            maybe_rearm_socket(s, buf)
            enqueue_no_reply(st, rw, from, bytes)
        end
    end
  end
  def handle_call({:recv_any, max_size}, _from, %{sock: s, buffer: buf} = st) do
    case Buffer.try_satisfy_any(buf, max_size) do
      :insufficient ->
        {:reply, :insufficient, st, @stale_timeout}
      {:ok, data, rest} ->
        maybe_rearm_socket(s, rest)
        {:reply, {:ok, data}, %{st | buffer: rest}, @stale_timeout}
    end
  end
  def handle_call({:recv_stream, max_size}, from, %{sock: s, buffer: buf, recv_waiters: rw} = st) do
    case WaiterQueue.empty?(rw) do
      false ->
        enqueue_no_reply(st, rw, from, {:message, max_size})
      true ->
        case Buffer.try_satisfy_stream(buf, max_size) do
          {:ok, data, rest} ->
            maybe_rearm_socket(s, rest)
            {:reply, {:ok, data}, %{st | buffer: rest}, @stale_timeout}
          {:error, _reason} = err ->
            {:reply, err, %{st | buffer: <<>>}, @stale_timeout}
          :insufficient ->
            enqueue_no_reply(st, rw, from, {:message, max_size})
        end
    end
  end
  def handle_call({:wrapped_send, _data}, _from, %{connected: false} = st),
    do: {:reply, {:error, :not_connected}, st}
  def handle_call({:wrapped_send, data}, _from, %{sock: sock} = st) do
    {:reply, :gen_tcp.send(sock, data), st, @stale_timeout}
  end
  defp enqueue_no_reply(st, rw, from, request) do
    new_w = WaiterQueue.enqueue(rw, from, request)
    {:noreply, %{st | recv_waiters: new_w}, @stale_timeout}
  end
  defp notify_connected(nil), do: :noop
  defp notify_connected(pid), do: send(pid, {:connected, {:tcp, self()}})
  defp maybe_rearm_socket(sock, buffer) when byte_size(buffer) < @max_buffer_size,
    do: :inet.setopts(sock, active: :once)
  defp maybe_rearm_socket(_sock, _buf), do: :noop
  def terminate(reason, %{sock: sock, peer: peer, recv_waiters: rw} = _st) do
    if sock do
      :gen_tcp.shutdown(sock, :read_write)
      :gen_tcp.close(sock)
    end
    try do
      GenS.ConnectionsOut.release(:tcp, peer)
      WaiterQueue.reply_all(rw, {:error, Conn.Error.normalize(reason)})
      if sock, do: :gen_tcp.close(sock)
    catch
      _kind, _reason ->
        :noop
    end
  end
end