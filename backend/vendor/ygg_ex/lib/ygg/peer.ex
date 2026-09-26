defmodule Ygg.Peer do
  @moduledoc """
  One live link after the handshake: ironwood's `peer` (`network/peers.go`) = frame handler
  (`_handlePacket`, :269-301), packet queue (`sendDirect`/`sendQueued`/`_push`/`pop`, :303-307,
  :421-460) and keepalive monitor (`peerMonitor`, :116-178), in one process that never blocks.
  The socket is read by `Ygg.Transport.Conn` (`handler`, :228-266) and written by our own
  `Ygg.Transport.Writer` (`peerWriter`, :180-226), started in `handle_continue(:start)` and linked
  to us, so neither direction waits for the other. Speaks the Peer <-> Router protocol of
  STAGE2_CONTRACTS.md §3 with `Ygg.Router.impl(ctx)`: `peer_up/5` once before the first frame is
  requested (`router.addPeer`, :241), `frame/3` casts, the router's monitor `DOWN` is
  `removePeer`; the router writes with `send(pid, {:tx, frame, :direct | :queued})`.
  Monitor (`peers.go:137-178`, PLAN_STAGE2 §2.2): any received frame clears the 3 s read
  deadline; a received non-0/1 frame arms the 1 s keepalive only if it is not armed already
  (no re-arm); any write, keepalive included, cancels the keepalive; a non-0/1 write arms the
  deadline only if it is not armed (later writes do not extend it). Received keepalives arm
  nothing, so an idle link is silent. Go keeps the deadline per `Read`; here it is per frame
  (frames are at most 131070 bytes).
  Writing: a frame is handed to the writer's mailbox (`Ygg.Transport.Writer.write/3`), which is
  the point where Go's `_write` calls `monitor.sent` (:189) and where the frame tap sees it.
  `:direct` frames (and keepalives) are handed at once, ahead of the queue; a `:queued` one is
  handed at once when the writer is `ready`, which then becomes false, otherwise pushed to
  `Ygg.PacketQueue` (cap 131070 bytes counted as frame bodies, drop oldest, `_push` :427-447).
  Every written frame comes back as `{:written, type, t}`; when nothing handed is left unwritten
  (the `seq == w.seq` check of `_write`, :190-197) we `pop`: the next queued frame is handed, or
  the writer becomes `ready`. So at most one queued frame sits in the writer, the queue holds the
  rest, and `{:tx, ...}` from the router never waits and never piles up in our mailbox. A frame
  whose length (type byte included) exceeds `Ygg.Wire.peer_max_message_size/0` is dropped
  silently (`sendPacket` :202-205; dropped before queueing, so unlike Go it never stalls
  `ready`). `srst` is set when a SigReq is handed and replaced by the writer's `t` when it is
  written (the `done` callback of `sendSigReq`, :318-322). A failed or timed out write stops
  the writer with `{:shutdown, {:send, reason}}`, the link kills us with that reason and the conn
  follows (it monitors its reader).
  Reader, `router: :native`: SigReq answered here, statelessly, with `port` = this link's
  port (= `router._handleRequest`, contract §3.2); SigRes checked with
  `Ygg.Frames.verify_sig_res/3` (:329) and forwarded with `rtt_ns` = now minus `srst` (nil before
  our first SigReq, :332-334); Announce checked with `Ygg.Frames.verify_announce/1` (:347); a
  bad signature stops the link with `:bad_message` (`ErrBadMessage`). BloomFilter decoded
  strictly with `Ygg.Bloom.decode/1` (`bloomfilter.go:83`, error = `ErrDecode`) and forwarded as
  `{:bloom, filter}`. PathLookup/PathNotify/PathBroken/Traffic are forwarded as decoded (a
  PathNotify is verified by the pathfinder at acceptance, not here). The Peer never sends a
  SigReq by itself in this mode (contract §3.4).
  Other routers (`:stub`) keep the stage-1 reactions: our own SigReq after connect when
  `ctx.send_sig_req`, a SigRes only measures `rtt_ms` (a bad one is logged), Announce and
  BloomFilter (length only, not decoded) go to the router, Traffic not for us is answered with
  `Ygg.Frames.path_broken_for/1` (Go `_doBroken`), PathLookup is never answered.
  Frame decode errors and unknown types close the link (`ErrDecode`,
  `ErrUnrecognizedMessage`); `Ygg.Transport.Conn` enforces `ErrOversizedMessage`. Frames are
  pulled one at a time (`Ygg.Transport.recv_frame/2`); timer messages carry a ref and stale
  ones are ignored. `ctx.frame_tap` gets `{:frame, :in | :out, remote_key, bin}` (§3.5).
  """
  use GenServer, restart: :temporary
  require Logger
  import Bitwise
  alias Ygg.{Bloom, Frames, Identity, Links, Node, PacketQueue, Router, Transport, Wire}
  alias Ygg.Transport.Writer
  @compile {:inline, [recv: 2, header: 1, forward: 2, count: 2]}
  @keepalive_delay 1_000
  @peer_timeout 3_000
  @report_every 1_000
  @max_frame Wire.peer_max_message_size()
  @sig_req 2
  defstruct [
    :ctx,
    :conn,
    :conn_ref,
    :remote_key,
    :port,
    :priority,
    :link,
    :info_uri,
    :frame_ref,
    :router,
    :keepalive,
    :deadline,
    :srst,
    :writer,
    native: false,
    queue: PacketQueue.new(),
    ready: true,
    inflight: 0,
    tx_dropped: 0,
    pending: nil,
    rtt_ms: nil,
    announce: nil,
    bloom_size: nil,
    counts: %{},
    seq: 0
  ]
  def start_link(%{} = opts), do: GenServer.start_link(__MODULE__, opts)
  @doc "Test hook: send a SigReq now (RTT probe; with `:stub` also sets `rtt_ms`)."
  def send_sig_req(pid), do: GenServer.cast(pid, :send_sig_req)
  @spec info(pid()) :: map()
  def info(pid), do: GenServer.call(pid, :info)
  @impl true
  def init(%{ctx: %Node{} = ctx, conn: conn} = opts) do
    router = Router.impl(ctx)
    st = %__MODULE__{
      ctx: ctx,
      conn: conn,
      conn_ref: Process.monitor(conn),
      remote_key: opts.remote_key,
      port: opts.port,
      priority: Map.get(opts, :priority, 0),
      link: Map.get(opts, :link),
      info_uri: Map.get(opts, :info_uri),
      router: router,
      native: router == Ygg.Router.Native
    }
    {:ok, st, {:continue, :start}}
  end
  @impl true
  def handle_continue(:start, %{ctx: ctx, conn: conn} = st) do
    case Transport.start_writer(conn) do
      {:ok, writer} ->
        st = %{st | writer: writer}
        st.router.peer_up(ctx, self(), st.remote_key, st.port, st.priority)
        Process.send_after(self(), :report, @report_every)
        st = request_frame(st)
        if ctx.send_sig_req and not st.native, do: sig_req(st), else: {:noreply, st}
      {:error, reason} ->
        {:stop, {:shutdown, reason}, st}
    end
  end
  @impl true
  def handle_cast(:send_sig_req, st), do: sig_req(st)
  @impl true
  def handle_call(:info, _from, st), do: {:reply, peer_info(st), st}
  @impl true
  def handle_info({ref, {:ok, frame}}, %{frame_ref: ref} = st) do
    tap(st, :in, frame)
    case handle_frame(frame, recv(st, frame)) do
      {:ok, st} -> {:noreply, request_frame(st)}
      {:error, reason} -> {:stop, {:shutdown, reason}, st}
    end
  end
  def handle_info({ref, {:error, reason}}, %{frame_ref: ref} = st),
    do: {:stop, {:shutdown, reason}, st}
  def handle_info({:tx, frame, :direct}, st), do: {:noreply, write(frame, st)}
  def handle_info({:tx, frame, :queued}, st), do: {:noreply, push(frame, st)}
  def handle_info({:written, type, t}, %{inflight: n} = st) do
    st = if type == @sig_req, do: %{st | srst: t, inflight: n - 1}, else: %{st | inflight: n - 1}
    {:noreply, if(n == 1, do: pop(st), else: st)}
  end
  def handle_info({:keepalive, ref}, %{keepalive: {_, ref}} = st),
    do: {:noreply, write(Frames.keepalive_frame(), %{st | keepalive: nil})}
  def handle_info({:deadline, ref}, %{deadline: {_, ref}} = st),
    do: {:stop, {:shutdown, :peer_timeout}, st}
  def handle_info(:report, %{ctx: ctx, info_uri: info} = st) do
    Process.send_after(self(), :report, @report_every)
    if info, do: Links.peer_info(ctx, info, peer_info(st))
    {:noreply, st}
  end
  def handle_info({:DOWN, ref, :process, _conn, reason}, %{conn_ref: ref} = st),
    do: {:stop, {:shutdown, Transport.reason(reason)}, st}
  def handle_info(_stale, st), do: {:noreply, st}
  defp handle_frame(<<5, body::binary>>, st), do: on_bloom(body, count(st, :bloom))
  defp handle_frame(<<type, _::binary>> = bin, st) do
    case Frames.decode(bin) do
      {:ok, {name, body}} -> on_frame(name, body, count(st, name))
      {:error, :decode} -> {:error, {:decode, type}}
      {:error, :unrecognized} -> {:error, {:unrecognized_message, type}}
    end
  end
  defp handle_frame(<<>>, _st), do: {:error, {:decode, :empty}}
  defp on_frame(:dummy, _, st), do: {:ok, st}
  defp on_frame(:keepalive, _, st), do: {:ok, st}
  defp on_frame(:sig_req, %{seq: seq, nonce: nonce}, %{ctx: ctx, remote_key: rk, port: port} = st) do
    psig =
      Identity.sign(ctx.identity, Frames.bytes_for_sig(rk, ctx.identity.pub, seq, nonce, port))
    {:ok,
     write(Frames.encode_frame({:sig_res, %{seq: seq, nonce: nonce, port: port, psig: psig}}), st)}
  end
  defp on_frame(:sig_res, res, %{native: true, ctx: ctx, remote_key: rk} = st) do
    if Frames.verify_sig_res(res, ctx.identity.pub, rk) do
      rtt = st.srst && System.monotonic_time(:nanosecond) - st.srst
      forward(st, {:sig_res, Map.put(res, :rtt_ns, rtt)})
      {:ok, if(rtt, do: %{st | rtt_ms: div(rtt, 1_000_000)}, else: st)}
    else
      {:error, :bad_message}
    end
  end
  defp on_frame(:announce, a, %{native: true} = st) do
    if Frames.verify_announce(a), do: on_announce(a, st), else: {:error, :bad_message}
  end
  defp on_frame(name, body, %{native: true} = st) do
    forward(st, {name, body})
    {:ok, st}
  end
  defp on_frame(:sig_res, %{seq: seq, nonce: nonce} = res, %{pending: {seq, nonce}} = st) do
    %{ctx: ctx, remote_key: rk} = st
    if Frames.verify_sig_res(res, ctx.identity.pub, rk) and st.srst do
      rtt = System.monotonic_time(:nanosecond) - st.srst
      {:ok, %{st | pending: nil, rtt_ms: div(rtt, 1_000_000)}}
    else
      Logger.warning("SigRes from #{short(rk)} has a bad signature")
      {:ok, %{st | pending: nil}}
    end
  end
  defp on_frame(:sig_res, _res, st), do: {:ok, st}
  defp on_frame(:announce, a, st), do: on_announce(a, st)
  defp on_frame(:traffic, %{dest: dest} = t, %{ctx: %{identity: %{pub: dest}}} = st) do
    Logger.info(
      "Traffic for us from #{short(t.source)} (#{byte_size(t.payload)} bytes), no sessions yet"
    )
    {:ok, st}
  end
  defp on_frame(:traffic, t, st),
    do: {:ok, push(Frames.encode_frame(Frames.path_broken_for(t)), st)}
  defp on_frame(:path_lookup, %{dest: dest} = l, %{ctx: %{identity: %{pub: dest}}} = st) do
    Logger.debug("PathLookup for us from #{short(l.source)} (stage 2)")
    {:ok, st}
  end
  defp on_frame(_other, _body, st), do: {:ok, st}
  defp on_announce(a, st) do
    forward(st, {:announce, a})
    {:ok, %{st | announce: %{key: a.key, parent: a.parent, seq: a.seq, port: a.port}}}
  end
  defp on_bloom(body, %{native: true} = st) do
    case Bloom.decode(body) do
      {:ok, f} ->
        forward(st, {:bloom, f})
        {:ok, %{st | bloom_size: popcount(f, 0)}}
      {:error, _} ->
        {:error, {:decode, 5}}
    end
  end
  defp on_bloom(body, st) do
    forward(st, {:bloom, byte_size(body)})
    {:ok, %{st | bloom_size: byte_size(body)}}
  end
  defp forward(%{router: router, ctx: ctx}, frame), do: router.frame(ctx, self(), frame)
  defp push(frame, st) do
    case header(frame) do
      {len, type} when len <= @max_frame -> push(frame, len, type, st)
      _ -> %{st | tx_dropped: st.tx_dropped + 1}
    end
  end
  defp push(frame, _len, type, %{ready: true} = st), do: %{hand(frame, type, st) | ready: false}
  defp push(frame, len, _type, %{queue: q, tx_dropped: n} = st) do
    {q, dropped} = PacketQueue.push(q, frame, max(len - 1, 0))
    %{st | queue: q, tx_dropped: n + dropped}
  end
  defp pop(%{queue: q} = st) do
    case PacketQueue.pop(q) do
      {:ok, frame, q} -> hand(frame, elem(header(frame), 1), %{st | queue: q})
      :empty -> %{st | ready: true}
    end
  end
  defp write(frame, st) do
    case header(frame) do
      {len, type} when len <= @max_frame -> hand(frame, type, st)
      _ -> %{st | tx_dropped: st.tx_dropped + 1}
    end
  end
  defp hand(frame, type, %{writer: w, inflight: n} = st) do
    :ok = Writer.write(w, frame, type)
    st = tap_out(%{sent(st, type) | inflight: n + 1}, frame)
    if type == @sig_req, do: %{st | srst: System.monotonic_time(:nanosecond)}, else: st
  end
  defp header([<<_, _::binary>> = len_bin, type | _]) when is_integer(type) do
    case Wire.decode_uvarint(len_bin) do
      {:ok, len, <<>>} -> {len, type}
      _ -> :error
    end
  end
  defp header(frame) do
    case Wire.decode_uvarint(IO.iodata_to_binary(frame)) do
      {:ok, len, <<type, _::binary>>} -> {len, type}
      _ -> :error
    end
  end
  defp sent(%{keepalive: ka} = st, type) do
    cancel(ka)
    st = %{st | keepalive: nil}
    if type > 1, do: arm_deadline(st), else: st
  end
  defp recv(st, <<type, _::binary>>) when type > 1, do: st |> clear_deadline() |> arm_keepalive()
  defp recv(st, _frame), do: clear_deadline(st)
  defp arm_keepalive(%{keepalive: nil} = st) do
    ref = make_ref()
    %{st | keepalive: {Process.send_after(self(), {:keepalive, ref}, @keepalive_delay), ref}}
  end
  defp arm_keepalive(st), do: st
  defp arm_deadline(%{deadline: nil} = st) do
    ref = make_ref()
    %{st | deadline: {Process.send_after(self(), {:deadline, ref}, @peer_timeout), ref}}
  end
  defp arm_deadline(st), do: st
  defp clear_deadline(%{deadline: nil} = st), do: st
  defp clear_deadline(%{deadline: d} = st) do
    cancel(d)
    %{st | deadline: nil}
  end
  defp cancel(nil), do: :ok
  defp cancel({tref, _ref}), do: Process.cancel_timer(tref)
  defp sig_req(%{seq: seq} = st) do
    seq = seq + 1
    <<nonce::64>> = :crypto.strong_rand_bytes(8)
    st = %{st | seq: seq, pending: {seq, nonce}}
    {:noreply, write(Frames.encode_frame({:sig_req, %{seq: seq, nonce: nonce}}), st)}
  end
  defp request_frame(%{conn: conn} = st), do: %{st | frame_ref: Transport.recv_frame(conn)}
  defp count(%{counts: counts} = st, name),
    do: %{st | counts: Map.update(counts, name, 1, &(&1 + 1))}
  defp popcount(0, n), do: n
  defp popcount(f, n), do: popcount(f &&& f - 1, n + 1)
  defp peer_info(%{announce: a} = st) do
    %{
      rtt_ms: st.rtt_ms,
      parent: a && Identity.pub_hex(a.parent),
      seq: a && a.seq,
      bloom_size: st.bloom_size,
      counts: st.counts,
      port: st.port,
      queued: PacketQueue.size(st.queue),
      tx_dropped: st.tx_dropped
    }
  end
  defp tap(%{ctx: %{frame_tap: pid}, remote_key: rk}, dir, frame) when is_pid(pid),
    do: send(pid, {:frame, dir, rk, frame})
  defp tap(_st, _dir, _frame), do: :ok
  defp tap_out(%{ctx: %{frame_tap: pid}} = st, data) when is_pid(pid) do
    {:ok, _len, frame} = data |> IO.iodata_to_binary() |> Wire.decode_uvarint()
    tap(st, :out, frame)
    st
  end
  defp tap_out(st, _data), do: st
  defp short(key), do: key |> Identity.pub_hex() |> binary_part(0, 8)
end