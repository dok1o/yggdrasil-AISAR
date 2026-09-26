defmodule Ygg.Transport do
  @moduledoc """
  Client API over a `Ygg.Transport.Conn` process (shaped after `Transport` in
  `context/all_transports.ex`). A conn handle is the conn pid.
  `send/3` and `recv_exact/3` are synchronous (used by `Ygg.Link` for the `meta` handshake,
  `link.go:627-659`); `send/3` writes from the conn process, so the conn does not read while
  it blocks: it is for the handshake, not for a live `Ygg.Peer`.
  `recv_frame/2` is asynchronous: it queues one frame request and the answer arrives in the
  caller's mailbox as `{ref, {:ok, frame} | {:error, reason}}`, so `Ygg.Peer` keeps handling
  timers and writes while a frame is pending and the socket process never blocks on frame
  handling. `start_writer/1` gives a live link its own `Ygg.Transport.Writer` (ironwood's
  `peerWriter`), which writes on the conn's socket from another process, so reading never
  waits for writing (`network/peers.go:180-266`).
  A `recv_exact` that times out leaves its waiter queued in the conn: the caller must stop
  the conn afterwards (Go closes the socket on every handshake failure, link.go:648).
  """
  alias Ygg.Transport.{Conn, Writer}
  alias Ygg.Wire
  @compile {:inline, [recv_frame: 2, send: 3]}
  @call_timeout 10_000
  @type conn :: pid()
  @spec start(module(), pid(), {:inet.ip_address(), :inet.port_number(), keyword(), timeout()}) ::
          GenServer.on_start()
  def start(mod, owner, connect),
    do: Conn.start_link(transport: mod, owner: owner, connect: connect)
  @doc "Adopts an accepted socket: starts the conn, hands the socket over, arms it."
  @spec adopt(module(), pid(), term()) :: {:ok, conn()} | {:error, term()}
  def adopt(mod, owner, sock) do
    with {:ok, pid} <- Conn.start_link(transport: mod, owner: owner, socket: sock),
         :ok <- mod.controlling_process(sock, pid) do
      Conn.activate(pid)
      {:ok, pid}
    end
  end
  @spec send(conn(), iodata(), timeout()) :: :ok | {:error, term()}
  def send(conn, data, timeout \\ @call_timeout) do
    GenServer.call(conn, {:send, data}, timeout)
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end
  @spec recv_exact(conn(), pos_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv_exact(conn, bytes, timeout) do
    GenServer.call(conn, {:recv, bytes}, timeout)
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end
  @doc """
  Starts a `Ygg.Transport.Writer` on the conn's socket, linked to the caller, which gets its
  `{:written, type, t}` acks. The conn must be connected.
  """
  @spec start_writer(conn()) :: {:ok, pid()} | {:error, term()}
  def start_writer(conn) do
    with {:ok, mod, sock, counters} <- GenServer.call(conn, :writer_args, @call_timeout),
         do: Writer.start_link(mod, sock, counters, self())
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end
  @doc "Queues one frame request; the reply comes as `{ref, result}`."
  @spec recv_frame(conn(), pos_integer()) :: reference()
  def recv_frame(conn, max \\ Wire.peer_max_message_size()) do
    ref = make_ref()
    GenServer.cast(conn, {:recv_frame, max, {self(), ref}})
    ref
  end
  @spec attach_reader(conn(), pid()) :: :ok | {:error, term()}
  def attach_reader(conn, pid) do
    GenServer.call(conn, {:attach_reader, pid}, @call_timeout)
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end
  @spec info(conn()) :: map() | nil
  def info(conn) do
    GenServer.call(conn, :info, @call_timeout)
  catch
    :exit, _reason -> nil
  end
  @spec close(conn()) :: :ok
  def close(conn) do
    GenServer.stop(conn, :shutdown, 1_000)
  catch
    :exit, _reason -> :ok
  end
  @spec read_counters(:counters.counters_ref()) ::
          {rx :: non_neg_integer(), tx :: non_neg_integer()}
  def read_counters(ref), do: {:counters.get(ref, 1), :counters.get(ref, 2)}
  @doc "Flattens a conn exit reason into the link error atom/term."
  def reason({:shutdown, r}), do: reason(r)
  def reason(:normal), do: :closed
  def reason(:shutdown), do: :closed
  def reason(r), do: r
  defp exit_reason({:timeout, _}), do: :timeout
  defp exit_reason({:noproc, _}), do: :closed
  defp exit_reason({reason, _call}), do: reason(reason)
  defp exit_reason(reason), do: reason(reason)
end