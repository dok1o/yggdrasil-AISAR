defmodule Ygg.Link do
  @moduledoc """
  One peering: dial loop with backoff, the `meta` handshake and the lifetime of the resulting
  connection. Ports the per-link goroutine of `links.add` (`reference/yggdrasil-go/src/core/link.go:306-414`),
  `backoffNow`/`resetBackoff` (link.go:262-300), `findSuitableIP` (link.go:720-764),
  `handler` (link.go:627-718) and the accepted-connection branch of `links.listen`
  (link.go:515-590). After the handshake the connection goes to `Ygg.Peer` (link.go:708
  `HandleConn`), which parses the ironwood frames in Elixir.
  Explicit state machine, no blocking `receive`: `{:connected, conn}` and
  `EXIT`s are messages, `kick` (link.go:239, `RetryPeersNow`) is always serviced.
  Backoff exactly as Go: the counter is incremented *before* the wait, so the first retry
  waits 2 s, then 4, 8 ... capped at `maxbackoff` (default 1 s << 12); `-1` after
  `ErrLinkToSelf` means wait for a kick. Go has no jitter (PROMPT_ELIXIR_PORT.md mentions
  one; the code has none) and none is added here. `resetBackoff` runs right after a
  successful handshake, before the connection is used (link.go:704-706).
  Deviation: the address list is `AAAA ++ A` from `:inet.getaddrs/2`; Go uses the system
  resolver order.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Ygg.{Address, Identity, Links, Meta, PeerURI, Peers, Transport}
  alias Ygg.Transport.{TCP, TLS}
  @max_shift 32
  defstruct [
    :ctx,
    :uri,
    :type,
    :mod,
    :info_uri,
    :conn,
    :peer,
    :sock,
    :remote_key,
    :port,
    phase: :idle,
    ips: [],
    backoff: 0,
    timer: nil,
    err: nil
  ]
  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
  @doc "Retry now if backing off (link.go:239, 285)."
  def kick(pid), do: send(pid, :kick)
  @doc "Incoming only: the listener transferred socket ownership, adopt it."
  def adopt(pid), do: GenServer.cast(pid, :adopt)
  @doc "Pure backoff step (link.go:270-283): returns `{counter, wait_ms | :infinity}`."
  @spec next_backoff(integer(), pos_integer()) :: {integer(), pos_integer() | :infinity}
  def next_backoff(backoff, _max) when backoff < 0, do: {backoff, :infinity}
  def next_backoff(backoff, max_ms) do
    backoff = if backoff < @max_shift, do: backoff + 1, else: backoff
    {backoff, min(Bitwise.bsl(1_000, backoff), max_ms)}
  end
  @impl true
  def init({ctx, %PeerURI{} = uri, :persistent}) do
    Process.flag(:trap_exit, true)
    st = %__MODULE__{
      ctx: ctx,
      uri: uri,
      type: :persistent,
      mod: mod(uri.scheme),
      info_uri: uri.info_uri
    }
    {:ok, st, {:continue, :dial}}
  end
  def init(
        {ctx, %{sock: sock, mod: mod, info_uri: info, priority: prio, scheme: scheme}, :incoming}
      ) do
    Process.flag(:trap_exit, true)
    uri = %PeerURI{scheme: scheme, priority: prio, info_uri: info, uri: info}
    st = %__MODULE__{ctx: ctx, uri: uri, type: :incoming, mod: mod, info_uri: info, sock: sock}
    {:ok, st}
  end
  @impl true
  def handle_continue(:dial, st), do: {:noreply, dial(st)}
  @impl true
  def handle_cast(:adopt, %{mod: mod, sock: sock} = st) do
    case Transport.adopt(mod, self(), sock) do
      {:ok, conn} -> {:noreply, %{st | conn: conn, sock: nil, phase: :adopting}}
      {:error, reason} -> {:stop, :normal, report_down(reason, st)}
    end
  end
  @impl true
  def handle_info({:connected, conn}, %{conn: conn, phase: phase} = st)
      when phase in [:dialing, :adopting],
      do: handshake(st)
  def handle_info({:EXIT, conn, reason}, %{conn: conn, phase: :dialing} = st) do
    Logger.debug("Dialling #{st.info_uri} reported error: #{inspect(reason)}")
    {:noreply, try_ips(%{st | conn: nil, err: Transport.reason(reason)})}
  end
  def handle_info({:EXIT, conn, reason}, %{conn: conn, phase: :adopting} = st),
    do: {:stop, :normal, report_down(Transport.reason(reason), st)}
  def handle_info({:EXIT, pid, reason}, %{phase: :up, conn: conn, peer: peer} = st)
      when pid == conn or pid == peer,
      do: down(pid, reason, st)
  def handle_info({:EXIT, _pid, _reason}, st), do: {:noreply, st}
  def handle_info(:kick, %{phase: :backoff, timer: timer} = st) do
    if timer, do: Process.cancel_timer(timer)
    {:noreply, dial(%{st | timer: nil})}
  end
  def handle_info(:kick, st), do: {:noreply, st}
  def handle_info(:redial, %{phase: :backoff} = st), do: {:noreply, dial(%{st | timer: nil})}
  def handle_info(_msg, st), do: {:noreply, st}
  defp dial(%{uri: uri} = st) do
    Links.update(st.ctx, st.info_uri, %{state: :connecting})
    case resolve(uri.host) do
      {:ok, ips} -> try_ips(%{st | ips: ips, err: nil, phase: :resolving})
      {:error, reason} -> backoff_after(reason, st)
    end
  end
  defp try_ips(%{ips: []} = st), do: backoff_after(st.err || :no_suitable_ips, st)
  defp try_ips(%{ips: [ip | rest], uri: uri, mod: mod} = st) do
    {:ok, conn} = Transport.start(mod, self(), {ip, uri.port, [sni: uri.sni], TCP.dial_timeout()})
    %{st | conn: conn, ips: rest, phase: :dialing}
  end
  @doc false
  def resolve(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        {:ok, [ip]}
      _ ->
        ips = getaddrs(host, :inet6) ++ getaddrs(host, :inet)
        case Enum.reject(ips, &unsuitable?/1) do
          [] -> {:error, :no_suitable_ips}
          ips -> {:ok, Enum.uniq(ips)}
        end
    end
  end
  defp getaddrs(host, family) do
    case :inet.getaddrs(String.to_charlist(host), family) do
      {:ok, ips} -> ips
      {:error, _} -> []
    end
  end
  defp unsuitable?({0, 0, 0, 0}), do: true
  defp unsuitable?({a, _, _, _}) when a >= 224 and a <= 239, do: true
  defp unsuitable?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp unsuitable?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: true
  defp unsuitable?(_ip), do: false
  defp handshake(%{conn: conn} = st) do
    case do_handshake(st) do
      {:ok, key, priority} ->
        up(key, priority, st)
      {:error, reason} ->
        Transport.close(conn)
        st = %{st | conn: nil, phase: :idle}
        Logger.info("Handshake with #{st.info_uri} failed: #{inspect(reason)}")
        if st.type == :incoming,
          do: {:stop, :normal, report_down(reason, st)},
          else:
            {:noreply,
             backoff_after(reason, %{
               st
               | backoff: if(reason == :link_to_self, do: -1, else: st.backoff)
             })}
    end
  end
  defp do_handshake(%{ctx: ctx, conn: conn, uri: uri, type: type}) do
    deadline = System.monotonic_time(:millisecond) + ctx.handshake_timeout
    remaining = fn -> max(deadline - System.monotonic_time(:millisecond), 1) end
    with {:ok, ours} <- Meta.encode_local(ctx.identity, uri.priority, uri.password),
         :ok <- Transport.send(conn, ours, remaining.()),
         {:ok, header} <- recv(conn, Meta.header_size(), remaining.()),
         {:ok, hl} <- Meta.parse_header(header),
         {:ok, body} <- recv(conn, hl, remaining.()),
         {:ok, meta} <- Meta.decode_body(body, uri.password),
         true <- Meta.check(meta) || {:error, {:incompatible_version, meta.major, meta.minor}},
         :ok <- check_self(meta.pubkey, ctx.identity),
         :ok <- check_pinned(meta.pubkey, uri.pinned_keys),
         :ok <- check_allowed(meta.pubkey, type, ctx.allowed_keys) do
      {:ok, meta.pubkey, max(uri.priority, meta.priority)}
    end
  end
  defp recv(conn, n, timeout) do
    case Transport.recv_exact(conn, n, timeout) do
      {:error, :timeout} -> {:error, :handshake_timeout}
      other -> other
    end
  end
  defp check_self(key, %Identity{pub: key}), do: {:error, :link_to_self}
  defp check_self(_key, _id), do: :ok
  defp check_pinned(key, pinned) do
    if MapSet.size(pinned) == 0 or MapSet.member?(pinned, key),
      do: :ok,
      else: {:error, :pinned_key_mismatch}
  end
  defp check_allowed(key, :incoming, allowed) do
    if MapSet.size(allowed) == 0 or MapSet.member?(allowed, key),
      do: :ok,
      else: {:error, :not_allowed}
  end
  defp check_allowed(_key, _type, _allowed), do: :ok
  defp up(key, priority, %{ctx: ctx, conn: conn} = st) do
    info = Transport.info(conn) || %{}
    port = Peers.acquire(ctx, key)
    {:ok, peer} =
      Ygg.Peer.start_link(%{
        ctx: ctx,
        conn: conn,
        remote_key: key,
        port: port,
        priority: priority,
        link: self(),
        info_uri: st.info_uri
      })
    case Transport.attach_reader(conn, peer) do
      :ok ->
        dir = if st.type == :incoming, do: "inbound", else: "outbound"
        Logger.info(
          "Connected #{dir}: #{remote_str(key, info)}, source #{fmt_addr(info[:sockname])}"
        )
        Links.update(ctx, st.info_uri, %{
          state: :up,
          up_since: System.monotonic_time(:millisecond),
          counters: info[:counters],
          remote_key: key,
          priority: priority,
          port: port,
          peer_pid: peer
        })
        {:noreply,
         %{st | phase: :up, peer: peer, remote_key: key, port: port, backoff: 0, err: nil}}
      {:error, reason} ->
        Process.exit(peer, :shutdown)
        Peers.release(ctx, key)
        st = %{st | conn: nil, peer: nil, phase: :idle, backoff: 0}
        Logger.info("Connection to #{st.info_uri} lost after handshake: #{inspect(reason)}")
        if st.type == :incoming,
          do: {:stop, :normal, report_down(reason, st)},
          else: {:noreply, backoff_after(reason, st)}
    end
  end
  defp down(pid, reason, %{ctx: ctx, conn: conn, peer: peer, remote_key: key} = st) do
    other = if pid == conn, do: peer, else: conn
    Process.exit(other, :shutdown)
    Peers.release(ctx, key)
    err = if reason == :normal, do: :remote_closed, else: Transport.reason(reason)
    info = Transport.info(conn) || %{}
    dir = if st.type == :incoming, do: "inbound", else: "outbound"
    Logger.info("Disconnected #{dir}: #{remote_str(key, info)}; error: #{inspect(err)}")
    st = %{st | conn: nil, peer: nil, remote_key: nil, port: nil, phase: :idle}
    if st.type == :incoming,
      do: {:stop, :normal, report_down(err, st)},
      else: {:noreply, backoff_after(err, st)}
  end
  defp report_down(err, %{ctx: ctx, info_uri: info} = st) do
    Links.update(ctx, info, %{
      state: :down,
      err: err,
      errtime: System.monotonic_time(:millisecond)
    })
    %{st | err: err}
  end
  defp backoff_after(err, st) do
    st = report_down(err, st)
    {backoff, wait} = next_backoff(st.backoff, st.uri.max_backoff_ms)
    timer = if wait == :infinity, do: nil, else: Process.send_after(self(), :redial, wait)
    %{st | backoff: backoff, timer: timer, phase: :backoff, conn: nil, peer: nil}
  end
  defp mod(:tcp), do: TCP
  defp mod(:tls), do: TLS
  defp remote_str(key, info) do
    addr = key |> Address.addr_for_key() |> Address.format()
    "#{addr}@#{fmt_addr(info[:peername])}"
  end
  defp fmt_addr({ip, port}),
    do:
      PeerURI.info_uri("", ip |> :inet.ntoa() |> List.to_string(), port)
      |> String.trim_leading("://")
  defp fmt_addr(_), do: "?"
end