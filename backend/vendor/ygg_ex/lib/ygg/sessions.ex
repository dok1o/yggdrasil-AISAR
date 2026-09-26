defmodule Ygg.Sessions do
  @moduledoc """
  ironwood `encrypted` over a `network` router (STAGE2_CONTRACTS.md §4.4): the
  `sessionManager` of `encrypted/session.go:36-191` plus `PacketConn.WriteTo`/`MTU`
  (`packetconn.go:66-89`) and `Debug.GetSessions` (`debug.go:25-36`). One GenServer per node,
  registered as `Ygg.Node.via(ctx, Ygg.Sessions)`, started by `Ygg.Datagram.child_specs/1` when
  the chain is `:sessions`. It subscribes to the router (`{:ygg_net, node_id, src_key, payload}`),
  sends with `Ygg.Router.impl(ctx).send/3`, and delivers decrypted datagrams to its subscribers
  (normally `Ygg.Core`) as `{:ygg_datagram, node_id, src_key, payload}`. The per-session state
  machine is `Ygg.Session`; this module owns the table, the handshake buffers and the timers.
  * `handleData` (78-102): first byte 0 dummy, 1 Init, 2 Ack (both 193 bytes, decrypted with our
    X25519 key = `Ed2Curve.priv(seed)`, signature checked with the group secret), 3 Traffic.
  * `_handleInit`/`_handleAck`/`_sessionForInit` (61-125): an Init/Ack from an unknown key creates
    the session; a pending buffer donates the keys of our own Init and its datagrams are sent
    right after the update. An Ack for a session we did not have is handled as an Init (answered).
  * `_handleTraffic` (127-140): traffic from an unknown key is answered with an Init made of
    one-off keys we forget at once (anti-spoof: no state for unauthenticated senders).
  * `writeTo`/`_bufferAndInit` (142-178): no session yet -> buffer and (re)send our Init; the
    buffer lives 1 min after the last write. Deviation: Go keeps only the last datagram, here the
    last #{16} are kept (oldest dropped), sent in order once the session is up.
  * Timers (`_resetTimer`, 250-261, and the buffer timer): `expires_at` fields swept by a 1 s tick.
  * MTU = router MTU - 79 (`sessionTrafficOverhead`), 130_914 over a 130_993 network MTU.
  `send/3` is a `call`: the datagram is sealed here and handed to the router, whose result for
  that packet (the Init while handshaking) is the reply; the router never calls back into this
  process. Group password: `ctx.routing.password` (config `Routing.GroupPassword`).
  Nonces live only in this process: if it dies the node (one_for_all) restarts and every session
  is re-handshaked with fresh keys, so a nonce is never reused under the same key.
  """
  use GenServer
  require Logger
  alias Ygg.{Identity, Node, Router, Session}
  alias Ygg.Crypto.{Box, Ed2Curve}
  @type_dummy 0
  @type_init 1
  @type_ack 2
  @type_traffic 3
  @tick_ms 1_000
  @buffer_max 16
  @buffer_ms 60_000
  @derive {Inspect, except: [:x_priv, :group]}
  defstruct [
    :ctx,
    :router,
    :identity,
    :x_priv,
    :group,
    :mtu,
    sessions: %{},
    buffers: %{},
    subscribers: %{},
    stats: %{}
  ]
  @spec child_spec(Node.t()) :: Supervisor.child_spec()
  def child_spec(ctx), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [ctx]}}
  @doc "`opts[:router]` replaces `Ygg.Router.impl(ctx)` (tests)."
  @spec start_link(Node.t(), keyword()) :: GenServer.on_start()
  def start_link(ctx, opts \\ []),
    do: GenServer.start_link(__MODULE__, {ctx, opts}, name: Node.via(ctx, __MODULE__))
  @doc """
  Encrypt and send a datagram (`PacketConn.WriteTo`); without a session it is buffered and our
  Init is (re)sent. Replies with the router's result for the packet it sent, or
  `{:error, {:oversized, size, mtu}}` / `{:error, :bad_key}`.
  """
  @spec send(Node.t(), <<_::256>>, iodata()) :: :ok | {:error, term()}
  def send(ctx, <<_::binary-size(32)>> = key, payload), do: call(ctx, {:send, key, payload})
  def send(_ctx, _key, _payload), do: {:error, :bad_key}
  @doc "Deliver `{:ygg_datagram, node_id, src_key, payload}` to `pid`."
  @spec subscribe(Node.t(), pid()) :: :ok | {:error, term()}
  def subscribe(ctx, pid), do: call(ctx, {:subscribe, pid})
  @spec unsubscribe(Node.t(), pid()) :: :ok | {:error, term()}
  def unsubscribe(ctx, pid), do: call(ctx, {:unsubscribe, pid})
  @doc "Router MTU minus `sessionTrafficOverhead` (130914 over the native router)."
  @spec mtu(Node.t()) :: non_neg_integer() | {:error, term()}
  def mtu(ctx) do
    case Router.impl(ctx).mtu(ctx) do
      n when is_integer(n) -> max(n - Session.overhead(), 0)
      other -> other
    end
  end
  @doc ~S'`"sessions"` of the routing dump: `[%{"key" => hex, "uptime_ms" => ms, "rx" => n, "tx" => n}]`.'
  @spec dump(Node.t()) :: [map()]
  def dump(ctx) do
    case call(ctx, :dump) do
      list when is_list(list) -> list
      _ -> []
    end
  end
  @spec stats(Node.t()) :: map() | {:error, term()}
  def stats(ctx), do: call(ctx, :stats)
  defp call(ctx, msg) do
    GenServer.call(Node.via(ctx, __MODULE__), msg)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end
  @impl true
  def init({%Node{identity: %Identity{} = id} = ctx, opts}) do
    password = Map.get(ctx.routing || %{}, :password, "") || ""
    st = %__MODULE__{
      ctx: ctx,
      router: Keyword.get(opts, :router, Router.impl(ctx)),
      identity: id,
      x_priv: Ed2Curve.priv(id.seed),
      group: Ygg.Crypto.group_secret(password),
      stats: %{
        tx_packets: 0,
        rx_packets: 0,
        tx_bytes: 0,
        rx_bytes: 0,
        init_sent: 0,
        ack_sent: 0,
        init_recv: 0,
        ack_recv: 0,
        bad_handshake: 0,
        reinit: 0,
        dropped: 0,
        buffered_dropped: 0,
        expired: 0
      }
    }
    {:ok, st, {:continue, :subscribe}}
  end
  @impl true
  def handle_continue(:subscribe, %{ctx: ctx, router: router} = st) do
    with :ok <- router.subscribe(ctx, self()),
         n when is_integer(n) <- router.mtu(ctx) do
      Process.send_after(self(), :tick, @tick_ms)
      {:noreply, %{st | mtu: max(n - Session.overhead(), 0)}}
    else
      other -> {:stop, {:router_subscribe_failed, other}, st}
    end
  end
  @impl true
  def handle_call({:send, key, payload}, _from, %{mtu: mtu} = st) do
    size = IO.iodata_length(payload)
    if size > mtu do
      {:reply, {:error, {:oversized, size, mtu}}, st}
    else
      {reply, st} = write_to(st, key, IO.iodata_to_binary(payload), env(st))
      {:reply, reply, st}
    end
  end
  def handle_call({:subscribe, pid}, _from, %{subscribers: subs} = st) do
    subs = if Map.has_key?(subs, pid), do: subs, else: Map.put(subs, pid, Process.monitor(pid))
    {:reply, :ok, %{st | subscribers: subs}}
  end
  def handle_call({:unsubscribe, pid}, _from, %{subscribers: subs} = st) do
    {ref, subs} = Map.pop(subs, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{st | subscribers: subs}}
  end
  def handle_call(:dump, _from, st) do
    now = System.monotonic_time(:millisecond)
    list =
      for {key, s} <- st.sessions do
        %{
          "key" => Base.encode16(key, case: :lower),
          "uptime_ms" => now - s.since,
          "rx" => s.rx,
          "tx" => s.tx
        }
      end
    {:reply, list, st}
  end
  def handle_call(:stats, _from, st) do
    stats =
      Map.merge(st.stats, %{
        sessions: map_size(st.sessions),
        buffers: map_size(st.buffers),
        subscribers: map_size(st.subscribers),
        mtu: st.mtu
      })
    {:reply, stats, st}
  end
  @impl true
  def handle_info({:ygg_net, _node, src, <<_, _::binary>> = data}, st),
    do: {:noreply, handle_data(st, src, data, env(st))}
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, sweep(st, System.monotonic_time(:millisecond))}
  end
  def handle_info({:DOWN, _ref, :process, pid, _}, st),
    do: {:noreply, %{st | subscribers: Map.delete(st.subscribers, pid)}}
  def handle_info(_msg, st), do: {:noreply, st}
  defp env(st) do
    %{
      identity: st.identity,
      group: st.group,
      now: System.monotonic_time(:millisecond),
      unix: System.os_time(:second)
    }
  end
  defp handle_data(st, _src, <<@type_dummy, _::binary>>, _env), do: st
  defp handle_data(st, src, <<type, _::binary>> = data, env)
       when type in [@type_init, @type_ack] do
    case Session.decode_handshake(data, st.x_priv, src, st.group) do
      {:ok, @type_init, init} -> st |> bump(:init_recv) |> handle_init(src, init, env)
      {:ok, @type_ack, init} -> st |> bump(:ack_recv) |> handle_ack(src, init, env)
      :error -> bump(st, :bad_handshake)
    end
  end
  defp handle_data(st, src, <<@type_traffic, _::binary>> = data, env),
    do: handle_traffic(st, src, data, env)
  defp handle_data(st, _src, _data, _env), do: st
  defp session_for_init(st, src, init, env) do
    case st.sessions do
      %{^src => s} ->
        {s, nil, st}
      _ ->
        s = Session.new(src, init.current, init.next, init.seq, env.now)
        case Map.pop(st.buffers, src) do
          {nil, _} ->
            {s, nil, st}
          {buf, buffers} ->
            s = Session.adopt(s, buf.current, buf.next)
            {s, buf, %{st | buffers: buffers}}
        end
    end
  end
  defp handle_init(st, src, init, env) do
    {s, buf, st} = session_for_init(st, src, init, env)
    {s, ack} = Session.handle_init(s, init, env)
    st = st |> put_session(s) |> transmit(src, ack, :ack_sent)
    flush_buffer(st, s, buf, env)
  end
  defp handle_ack(st, src, init, env) do
    old? = Map.has_key?(st.sessions, src)
    {s, buf, st} = session_for_init(st, src, init, env)
    {s, st} =
      if old? do
        {Session.handle_ack(s, init, env), st}
      else
        {s, ack} = Session.handle_init(s, init, env)
        {s, transmit(st, src, ack, :ack_sent)}
      end
    flush_buffer(put_session(st, s), s, buf, env)
  end
  defp flush_buffer(st, _s, nil, _env), do: st
  defp flush_buffer(st, s, %{data: data}, env) do
    {s, st} =
      Enum.reduce(:queue.to_list(data), {s, st}, fn msg, {s, st} ->
        {s, bin} = Session.send(s, msg, env)
        {s, st |> transmit(s.ed, bin, :tx_packets) |> add(:tx_bytes, byte_size(msg))}
      end)
    put_session(st, s)
  end
  defp handle_traffic(st, src, data, env) do
    case st.sessions do
      %{^src => s} ->
        recv(st, s, data, env)
      _ ->
        {cp, _} = Box.keypair()
        {np, _} = Box.keypair()
        init = Session.new_init(cp, np, 0, env.unix)
        send_init(st, src, init)
    end
  end
  defp recv(st, s, data, env) do
    case Session.recv(s, data, env) do
      {:deliver, s, payload} ->
        for {pid, _} <- st.subscribers,
            do: Kernel.send(pid, {:ygg_datagram, st.ctx.id, s.ed, payload})
        st |> put_session(s) |> bump(:rx_packets) |> add(:rx_bytes, byte_size(payload))
      {:reinit, s, init, reason} ->
        Logger.debug(fn -> "Session #{short(s.ed)}: re-Init (#{reason})" end)
        st |> put_session(s) |> bump(:reinit) |> transmit(s.ed, init, :init_sent)
      {:drop, s, _reason} ->
        st |> put_session(s) |> bump(:dropped)
    end
  end
  defp write_to(st, key, msg, env) do
    case st.sessions do
      %{^key => s} ->
        {s, bin} = Session.send(s, msg, env)
        st = st |> put_session(s) |> bump(:tx_packets) |> add(:tx_bytes, byte_size(msg))
        {router_send(st, key, bin), st}
      _ ->
        buffer_and_init(st, key, msg, env)
    end
  end
  defp buffer_and_init(st, key, msg, env) do
    buf =
      case st.buffers do
        %{^key => buf} ->
          buf
        _ ->
          {cp, _} = current = Box.keypair()
          {np, _} = next = Box.keypair()
          %{
            init: Session.new_init(cp, np, 0, env.unix),
            current: current,
            next: next,
            data: :queue.new(),
            expires_at: 0
          }
      end
    {data, st} = push_data(buf.data, msg, st)
    buf = %{buf | data: data, expires_at: env.now + @buffer_ms}
    encode_init(%{st | buffers: Map.put(st.buffers, key, buf)}, key, buf.init)
  end
  defp push_data(q, msg, st) do
    q = :queue.in(msg, q)
    if :queue.len(q) > @buffer_max,
      do: {:queue.drop(q), bump(st, :buffered_dropped)},
      else: {q, st}
  end
  defp encode_init(st, key, init) do
    case Session.encode_handshake(@type_init, init, st.identity, key, st.group) do
      {:ok, bin} -> {router_send(st, key, bin), bump(st, :init_sent)}
      :error -> {{:error, :bad_key}, st}
    end
  end
  defp send_init(st, key, init), do: elem(encode_init(st, key, init), 1)
  defp transmit(st, _key, nil, _stat), do: st
  defp transmit(st, key, bin, stat) do
    router_send(st, key, bin)
    bump(st, stat)
  end
  defp router_send(%{ctx: ctx, router: router}, key, bin) do
    case router.send(ctx, key, bin) do
      :ok ->
        :ok
      err ->
        Logger.debug(fn -> "Session packet to #{short(key)} not sent: #{inspect(err)}" end)
        err
    end
  end
  defp put_session(st, %Session{ed: ed} = s), do: %{st | sessions: Map.put(st.sessions, ed, s)}
  defp sweep(st, now) do
    {dead, live} = Enum.split_with(st.sessions, fn {_k, s} -> Session.expired?(s, now) end)
    buffers = for {k, b} <- st.buffers, b.expires_at > now, into: %{}, do: {k, b}
    st = %{st | sessions: Map.new(live), buffers: buffers}
    if dead == [], do: st, else: add(st, :expired, length(dead))
  end
  defp bump(st, key), do: add(st, key, 1)
  defp add(st, key, n), do: %{st | stats: Map.update(st.stats, key, n, &(&1 + n))}
  defp short(key), do: key |> binary_part(0, 4) |> Base.encode16(case: :lower)
end