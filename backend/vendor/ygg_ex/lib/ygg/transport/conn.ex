defmodule Ygg.Transport.Conn do
  @moduledoc """
  Process that owns one link socket (`:gen_tcp` or `:ssl` via a `Ygg.Transport.Behaviour`
  module), accumulates received bytes in a binary buffer and serves receive requests from
  a queue. Plays the role of `linkConn` (`reference/yggdrasil-go/src/core/link.go:771-795`: byte counters `rx`/`tx`
  are `:counters` here, updated on every read and write like the Go atomics) plus the
  reader side of ironwood's peer (`peer.handler`, `network/peers.go:228-266`). A live link
  writes through `Ygg.Transport.Writer`, a separate process on this socket (`:writer_args`
  hands it out), so this process keeps reading while a write blocks; `{:send, data}` writes
  from here and is for the handshake only.
  Adapted from `context/tcp_conn.ex`. Kept: `active: :once` with re-arming only while the
  buffer is under `@max_buffer_size`, buffer + waiter queue, dial inside `handle_continue`,
  socket shutdown + close in `terminate/2` with every waiter answered. Changed: no hidden
  idle timeout (ironwood's 3 s read deadline lives in `Ygg.Peer`), no exit trapping and no
  `Conn.Lifecycle` (the conn is `start_link`ed by `Ygg.Link` and dies with it; it monitors
  only its current reader), receive of link frames by uvarint length (`recv_frame`, async),
  frame errors stop the conn, an already accepted socket can be adopted (`socket:` option,
  `controlling_process` then `activate/1`), and a `{:connected, pid}` message goes to the
  owner instead of a `peer_pid`.
  """
  use GenServer, restart: :temporary
  alias Ygg.Transport.{Buffer, WaiterQueue}
  alias Ygg.Wire
  require Logger
  @max_buffer_size 2 * Wire.peer_max_message_size()
  @rx 1
  @tx 2
  defstruct [
    :mod,
    :sock,
    :owner,
    :reader,
    :reader_ref,
    :counters,
    :tags,
    :connect,
    buffer: <<>>,
    waiters: nil,
    connected: false
  ]
  @type option ::
          {:transport, module()}
          | {:owner, pid()}
          | {:connect, {:inet.ip_address(), :inet.port_number(), keyword(), timeout()}}
          | {:socket, term()}
  def max_buffer_size, do: @max_buffer_size
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @doc "For an adopted socket: call after `controlling_process/2` succeeded."
  def activate(conn), do: GenServer.cast(conn, :activate)
  @impl true
  def init(opts) do
    mod = Keyword.fetch!(opts, :transport)
    owner = Keyword.get(opts, :owner, self())
    st = %__MODULE__{
      mod: mod,
      owner: owner,
      reader: owner,
      reader_ref: Process.monitor(owner),
      counters: :counters.new(2, []),
      tags: mod.tags(),
      waiters: WaiterQueue.new(),
      connect: Keyword.get(opts, :connect),
      sock: Keyword.get(opts, :socket)
    }
    case st.connect do
      nil when st.sock != nil -> {:ok, st}
      nil -> {:stop, :missing_socket_or_connect}
      _ -> {:ok, st, {:continue, :connect}}
    end
  end
  @impl true
  def handle_continue(:connect, %{mod: mod, connect: {ip, port, copts, timeout}} = st) do
    case mod.connect(ip, port, copts, timeout) do
      {:ok, sock} -> {:noreply, up(%{st | sock: sock, connect: nil})}
      {:error, reason} -> {:stop, {:shutdown, reason}, st}
    end
  end
  @impl true
  def handle_cast(:activate, %{connected: false} = st), do: {:noreply, up(st)}
  def handle_cast(:activate, st), do: {:noreply, st}
  def handle_cast({:recv_frame, max, from}, st), do: recv(from, {:frame, max}, st)
  @impl true
  def handle_call({:recv, bytes}, from, st), do: recv(from, bytes, st)
  def handle_call({:send, _data}, _from, %{connected: false} = st),
    do: {:reply, {:error, :not_connected}, st}
  def handle_call({:send, data}, _from, %{mod: mod, sock: sock, counters: c} = st) do
    case mod.send(sock, data) do
      :ok ->
        :counters.add(c, @tx, IO.iodata_length(data))
        {:reply, :ok, st}
      {:error, reason} = err ->
        {:stop, {:shutdown, {:send, reason}}, err, st}
    end
  end
  def handle_call(:writer_args, _from, %{connected: false} = st),
    do: {:reply, {:error, :not_connected}, st}
  def handle_call(:writer_args, _from, %{mod: mod, sock: sock, counters: c} = st),
    do: {:reply, {:ok, mod, sock, c}, st}
  def handle_call({:attach_reader, pid}, _from, %{reader_ref: ref} = st) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, %{st | reader: pid, reader_ref: Process.monitor(pid)}}
  end
  def handle_call(:info, _from, %{mod: mod, sock: sock, counters: c} = st) do
    info = %{
      counters: c,
      peername: ok_or_nil(mod.peername(sock)),
      sockname: ok_or_nil(mod.sockname(sock)),
      transport: mod
    }
    {:reply, info, st}
  end
  @impl true
  def handle_info({tag, sock, data}, %{tags: {tag, _, _}, sock: sock, counters: c} = st) do
    :counters.add(c, @rx, byte_size(data))
    buffer = st.buffer <> data
    if byte_size(buffer) > @max_buffer_size do
      {:stop, {:shutdown, :buffer_overflow}, %{st | buffer: buffer}}
    else
      case WaiterQueue.satisfy_while(st.waiters, buffer) do
        {:ok, waiters, buffer} ->
          rearm(st, buffer)
          {:noreply, %{st | buffer: buffer, waiters: waiters}}
        {:error, reason, waiters, buffer} ->
          {:stop, {:shutdown, reason}, %{st | buffer: buffer, waiters: waiters}}
      end
    end
  end
  def handle_info({tag, sock}, %{tags: {_, tag, _}, sock: sock} = st),
    do: {:stop, {:shutdown, :closed}, st}
  def handle_info({tag, sock, reason}, %{tags: {_, _, tag}, sock: sock} = st),
    do: {:stop, {:shutdown, reason}, st}
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{reader_ref: ref} = st),
    do: {:stop, {:shutdown, :reader_down}, st}
  def handle_info(_msg, st), do: {:noreply, st}
  @impl true
  def terminate(reason, %{mod: mod, sock: sock, waiters: waiters}) do
    WaiterQueue.reply_all(waiters, {:error, Ygg.Transport.reason(reason)})
    if sock do
      _ = mod.shutdown(sock)
      mod.close(sock)
    end
    :ok
  end
  defp up(%{mod: mod, sock: sock, owner: owner} = st) do
    :ok = mod.setopts_active_once(sock)
    send(owner, {:connected, self()})
    %{st | connected: true}
  end
  defp recv(from, request, %{waiters: waiters, buffer: buffer} = st) do
    if WaiterQueue.empty?(waiters) do
      case Buffer.try_satisfy(buffer, request) do
        {:ok, data, rest} ->
          GenServer.reply(from, {:ok, data})
          rearm(st, rest)
          {:noreply, %{st | buffer: rest}}
        :insufficient ->
          rearm(st, buffer)
          {:noreply, %{st | waiters: WaiterQueue.enqueue(waiters, from, request)}}
        {:error, reason} ->
          GenServer.reply(from, {:error, reason})
          {:stop, {:shutdown, reason}, st}
      end
    else
      {:noreply, %{st | waiters: WaiterQueue.enqueue(waiters, from, request)}}
    end
  end
  defp rearm(%{mod: mod, sock: sock, connected: true}, buffer)
       when byte_size(buffer) < @max_buffer_size,
       do: mod.setopts_active_once(sock)
  defp rearm(_st, _buffer), do: :ok
  defp ok_or_nil({:ok, v}), do: v
  defp ok_or_nil(_), do: nil
end