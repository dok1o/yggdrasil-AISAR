defmodule Ygg.Router.Native do
  @moduledoc """
  The Elixir port of ironwood's `router` actor (`network/router.go`), wire compatible with
  the real Yggdrasil network (Go ironwood `d50055b`). One GenServer per node, registered as
  `Ygg.Node.via(ctx, Ygg.Router.Native)`, selected with `router: :native` (config
  `"Router": "native"`). It owns the state of three pure modules and turns their effects into
  messages to `Ygg.Peer` processes:
    * `Ygg.Tree`: spanning tree (`router.go` `infos/sent/requests/responses/lags`, `_fix`,
      `_sendAnnounces`, `_lookup`);
    * `Ygg.Bloom` per-peer table (`bloomfilter.go:122-332` `blooms`);
    * `Ygg.Pathfinder`: paths, rumors, traffic (`pathfinder.go`, `router.go:583-605`,
      `packetconn.go:72-95, 288-294`).
  Protocol with the peers (STAGE2_CONTRACTS.md §3), cast/send only, the router never calls a
  peer: `peer_up/5` = `router.addPeer` (`router.go:117-145`: replay `sent[key]`, SigReq shared
  per key, then `blooms._sendBloom`), the monitor `DOWN` of the peer pid = `router.removePeer`
  (`router.go:147-173`: forget the key with its last link, otherwise resend the last bloom to
  the remaining links), `frame/3` carries every decoded frame the peer does not handle itself.
  Frames go out as `{:tx, iodata, :direct | :queued}` to the peer pid: SigReq/SigRes/Announce/
  Bloom direct (`sendDirect`), PathLookup/PathNotify/PathBroken/Traffic queued (`sendQueued`,
  `peers.go:303, 421`, `bloomfilter.go:328`). Link refs of the pure modules are the peer pids.
  Maintenance every second (`_doMaintenance`, `router.go:89-100`): `Tree.tick/2` (timers,
  `_fix`, `_sendAnnounces`), `Bloom.maintenance/3` with the tree's on-tree keys
  (`blooms._doMaintenance`, `bloomfilter.go:226-229`), then `Pathfinder.tick/2` (path/rumor
  expiry; Go uses per-entry timers). A `:tick` message runs one extra maintenance round
  (used by tests to converge faster; it does not move the 1 s schedule).
  Upward: traffic for us goes to subscribers as `{:ygg_net, node_id, src_key, payload}`
  (`pconn.handleTraffic`), an accepted PathNotify as `{:ygg_path, node_id, key}`
  (`config.pathNotify`). `send/3` and `lookup/2` validate in the caller and cast
  (`router.sendTraffic` and `PacketConn.SendLookup` are non-blocking). Multicast (lookups) goes
  to one link per on-tree key, the one with the lowest `prio` (`_sendMulticast`,
  `bloomfilter.go:315-332`; ties by the older link).
  `routing/1` returns the `dumpJSON` shape of the former Go sidecar (STAGE2_CONTRACTS.md
  §5) built from `Debug.GetSelf/GetPeers/GetTree/GetPaths/GetBlooms` (`debug.go:61-135`); with
  `ctx.routing.routing_log_file` set, dumps (every `dump_interval_ms`), link up/down, path
  notifies and received lookups are appended through `Ygg.RoutingLog`.
  RTT: the peer reports `rtt_ns` (nil before its first SigReq write), passed to `Ygg.Tree` as is.
  """
  @behaviour Ygg.Router.Behaviour
  use GenServer
  require Logger
  alias Ygg.{Bloom, Frames, Node, Pathfinder, RoutingLog, Tree}
  @mtu 130_993
  @tick_ms 1_000
  @bloom_type 5
  @compile {:inline, [tx: 3, mode: 1, now_ms: 0]}
  defstruct [
    :ctx,
    :key,
    :tree,
    :pf,
    :log_file,
    dump_ms: 0,
    bloom_full: false,
    blooms: %{},
    links: %{},
    order: 0,
    subs: %{},
    frames_in: %{},
    frames_out: %{},
    stats: %{
      recv: 0,
      sent: 0,
      links_up: 0,
      links_down: 0,
      lookups: 0,
      path_notify: 0,
      dumps: 0
    }
  ]
  @type key :: <<_::256>>
  def start_link(ctx), do: GenServer.start_link(__MODULE__, ctx, name: Node.via(ctx, __MODULE__))
  @impl Ygg.Router.Behaviour
  def child_specs(ctx), do: [{__MODULE__, ctx}]
  @doc "`addPeer`: cast by `Ygg.Peer` once, right after it started on a live link."
  @impl Ygg.Router.Behaviour
  @spec peer_up(Node.t(), pid(), key(), pos_integer(), byte()) :: :ok
  def peer_up(ctx, pid, key, port, prio),
    do: GenServer.cast(Node.via(ctx, __MODULE__), {:peer_up, pid, key, port, prio})
  @doc "A decoded (and, for Announce/SigRes, verified) frame from the link of `pid`."
  @impl Ygg.Router.Behaviour
  @spec frame(Node.t(), pid(), Ygg.Frames.frame()) :: :ok
  def frame(ctx, pid, frame), do: GenServer.cast(Node.via(ctx, __MODULE__), {:frame, pid, frame})
  @doc """
  `PacketConn.WriteTo` (`packetconn.go:72-95`): network-level traffic to `dest`. Validated here,
  then cast; never blocks on the network.
  """
  @impl Ygg.Router.Behaviour
  @spec send(Node.t(), key(), iodata()) :: :ok | {:error, term()}
  def send(ctx, <<_::binary-size(32)>> = dest, payload) do
    size = IO.iodata_length(payload)
    if size > @mtu,
      do: {:error, {:oversized, size, @mtu}},
      else: cast(ctx, {:send, dest, IO.iodata_to_binary(payload)})
  end
  def send(_ctx, _dest, _payload), do: {:error, :bad_key}
  @doc "`PacketConn.SendLookup` (`packetconn.go:288-294`): lookup of a (possibly partial) key."
  @impl Ygg.Router.Behaviour
  @spec lookup(Node.t(), key()) :: :ok | {:error, term()}
  def lookup(ctx, <<_::binary-size(32)>> = key), do: cast(ctx, {:lookup, key})
  def lookup(_ctx, _key), do: {:error, :bad_key}
  @impl Ygg.Router.Behaviour
  def subscribe(ctx, pid \\ self()), do: call(ctx, {:subscribe, pid})
  @impl Ygg.Router.Behaviour
  def unsubscribe(ctx, pid \\ self()), do: call(ctx, {:unsubscribe, pid})
  @impl Ygg.Router.Behaviour
  def routing(ctx), do: call(ctx, :routing)
  @impl Ygg.Router.Behaviour
  def request_dump(ctx), do: call(ctx, :request_dump)
  @impl Ygg.Router.Behaviour
  def stats(ctx), do: call(ctx, :stats)
  @impl Ygg.Router.Behaviour
  def mtu(_ctx), do: @mtu
  defp call(ctx, msg) do
    GenServer.call(Node.via(ctx, __MODULE__), msg)
  catch
    :exit, {:noproc, _} -> {:error, :router_not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end
  defp cast(ctx, msg) do
    case GenServer.whereis(Node.via(ctx, __MODULE__)) do
      nil -> {:error, :router_not_running}
      pid -> GenServer.cast(pid, msg)
    end
  end
  @impl GenServer
  def init(%Node{identity: id} = ctx) do
    sc = ctx.routing || %{}
    now = now_ms()
    st = %__MODULE__{
      ctx: ctx,
      key: id.pub,
      tree: Tree.new(id, now),
      pf: Pathfinder.new(identity: id),
      log_file: Map.get(sc, :routing_log_file),
      dump_ms: Map.get(sc, :dump_interval_ms, 0),
      bloom_full: Map.get(sc, :bloom_full, false)
    }
    Process.send_after(self(), :maintenance, @tick_ms)
    if st.dump_ms > 0, do: Process.send_after(self(), :dump, st.dump_ms)
    {:ok, st}
  end
  @impl GenServer
  def handle_call({:subscribe, pid}, _from, %{subs: subs} = st) do
    subs = if Map.has_key?(subs, pid), do: subs, else: Map.put(subs, pid, Process.monitor(pid))
    {:reply, :ok, %{st | subs: subs}}
  end
  def handle_call({:unsubscribe, pid}, _from, %{subs: subs} = st) do
    {mref, subs} = Map.pop(subs, pid)
    if mref, do: Process.demonitor(mref, [:flush])
    {:reply, :ok, %{st | subs: subs}}
  end
  def handle_call(:routing, _from, st), do: {:reply, dump(st), st}
  def handle_call(:request_dump, _from, st) do
    d = dump(st)
    Logger.info(RoutingLog.summary(d))
    RoutingLog.append(st.log_file, st.ctx.id, "dump", d)
    {:reply, :ok, bump(st, :dumps)}
  end
  def handle_call(:stats, _from, st) do
    stats =
      Map.merge(st.stats, %{
        mtu: @mtu,
        links: map_size(st.links),
        peers: map_size(st.blooms),
        subscribers: map_size(st.subs),
        routing_entries: map_size(Tree.infos(st.tree)),
        paths: map_size(Pathfinder.paths(st.pf)),
        frames: st.frames_in,
        frames_out: st.frames_out
      })
    {:reply, stats, st}
  end
  @impl GenServer
  def handle_cast({:frame, pid, {name, body}}, %{links: links} = st) do
    case links do
      %{^pid => link} ->
        st = %{st | frames_in: Map.update(st.frames_in, name, 1, &(&1 + 1))}
        {:noreply, on_frame(name, body, pid, link, st)}
      _ ->
        {:noreply, st}
    end
  end
  def handle_cast({:send, dest, payload}, st) do
    st = bump(st, :sent)
    {:noreply, run_pf(st, &Pathfinder.send_traffic(&1, dest, payload, &2))}
  end
  def handle_cast({:lookup, key}, st) do
    st = bump(st, :lookups)
    {:noreply, run_pf(st, &Pathfinder.lookup(&1, key, &2))}
  end
  def handle_cast({:peer_up, pid, key, port, prio}, st) do
    st = if Map.has_key?(st.links, pid), do: drop_link(st, pid), else: st
    {tree, effects} = Tree.add_link(st.tree, pid, key, port, prio, now_ms())
    mref = Process.monitor(pid)
    link = %{key: key, port: port, prio: prio, order: st.order, mref: mref, rtt_ns: nil}
    st = %{st | tree: tree, links: Map.put(st.links, pid, link), order: st.order + 1}
    st = send_effects(st, effects)
    {blooms, f} = Bloom.add_peer(st.blooms, key)
    st = tx_bloom(%{st | blooms: blooms}, [pid], f)
    log_link(st, key, prio, true)
    {:noreply, bump(st, :links_up)}
  end
  @impl GenServer
  def handle_info(:maintenance, st) do
    Process.send_after(self(), :maintenance, @tick_ms)
    {:noreply, maintenance(st)}
  end
  def handle_info(:tick, st), do: {:noreply, maintenance(st)}
  def handle_info(:dump, st) do
    Process.send_after(self(), :dump, st.dump_ms)
    d = dump(st)
    Logger.info(RoutingLog.summary(d))
    RoutingLog.append(st.log_file, st.ctx.id, "dump", d)
    {:noreply, bump(st, :dumps)}
  end
  def handle_info({:DOWN, mref, :process, pid, _reason}, st) do
    case st.links do
      %{^pid => %{mref: ^mref, key: key, prio: prio}} ->
        st = drop_link(st, pid)
        log_link(st, key, prio, false)
        {:noreply, bump(st, :links_down)}
      _ ->
        {:noreply, %{st | subs: Map.delete(st.subs, pid)}}
    end
  end
  def handle_info(_msg, st), do: {:noreply, st}
  defp drop_link(st, pid) do
    {%{key: key, mref: mref}, links} = Map.pop(st.links, pid)
    Process.demonitor(mref, [:flush])
    {tree, effects} = Tree.remove_link(st.tree, pid, now_ms())
    st = send_effects(%{st | tree: tree, links: links}, effects)
    case links_of(links, key) do
      [] -> %{st | blooms: Bloom.remove_peer(st.blooms, key)}
      pids -> tx_bloom(st, pids, Bloom.sent(st.blooms, key))
    end
  end
  defp links_of(links, key), do: for({pid, %{key: ^key}} <- links, do: pid)
  defp best_link(links, key) do
    links
    |> Enum.filter(fn {_pid, l} -> l.key == key end)
    |> Enum.min_by(fn {_pid, l} -> {l.prio, l.order} end, fn -> nil end)
    |> case do
      nil -> nil
      {pid, _} -> pid
    end
  end
  defp on_frame(:sig_res, res, pid, link, st) do
    rtt_ns = Map.get(res, :rtt_ns)
    st = if rtt_ns, do: put_in(st.links[pid], %{link | rtt_ns: rtt_ns}), else: st
    {tree, effects} = Tree.handle_sig_res(st.tree, pid, res, rtt_ns, now_ms())
    send_effects(%{st | tree: tree}, effects)
  end
  defp on_frame(:announce, ann, pid, _link, st) do
    {tree, effects} = Tree.handle_announce(st.tree, pid, ann, now_ms())
    send_effects(%{st | tree: tree}, effects)
  end
  defp on_frame(:bloom, f, _pid, %{key: key}, st) when is_integer(f),
    do: %{st | blooms: Bloom.recv(st.blooms, key, f)}
  defp on_frame(:bloom, bin, pid, link, st) when is_binary(bin) do
    case Bloom.decode(bin) do
      {:ok, f} -> on_frame(:bloom, f, pid, link, st)
      {:error, _} -> st
    end
  end
  defp on_frame(:path_lookup, lookup, pid, _link, st) do
    if st.log_file do
      RoutingLog.append(st.log_file, st.ctx.id, "lookup", %{
        key: hex(lookup.source),
        path: lookup.from,
        target: hex(lookup.dest)
      })
    end
    run_pf(st, &Pathfinder.handle_lookup(&1, pid, lookup, &2))
  end
  defp on_frame(:path_notify, notify, pid, _link, st),
    do: run_pf(st, &Pathfinder.handle_notify(&1, pid, notify, &2))
  defp on_frame(:path_broken, broken, pid, _link, st),
    do: run_pf(st, &Pathfinder.handle_broken(&1, pid, broken, &2))
  defp on_frame(:traffic, tr, pid, _link, st),
    do: run_pf(st, &Pathfinder.handle_traffic(&1, pid, tr, &2))
  defp on_frame(_name, _body, _pid, _link, st), do: st
  defp maintenance(st) do
    now = now_ms()
    {tree, effects} = Tree.tick(st.tree, now)
    st = send_effects(%{st | tree: tree}, effects)
    {blooms, sends} = Bloom.maintenance(st.blooms, st.key, Tree.on_tree_keys(tree))
    st = %{st | blooms: blooms}
    st =
      Enum.reduce(sends, st, fn {:send, key, f}, st ->
        tx_bloom(st, links_of(st.links, key), f)
      end)
    %{st | pf: Pathfinder.tick(st.pf, now)}
  end
  defp run_pf(st, fun) do
    case fun.(st.pf, env(st)) do
      {:error, _reason} -> st
      {pf, effects} -> pf_effects(%{st | pf: pf}, effects)
    end
  end
  defp env(%{tree: tree, blooms: blooms, links: links, key: me}) do
    %{
      now: now_ms(),
      unix: System.os_time(:second),
      coords: Tree.coords(tree, me),
      route: &Tree.lookup(tree, &1, &2),
      multicast: fn x_dest, from -> multicast(blooms, links, x_dest, from) end,
      on_tree?: fn pid ->
        case links do
          %{^pid => %{key: k}} -> Bloom.on_tree?(blooms, k)
          _ -> false
        end
      end
    }
  end
  defp multicast(blooms, links, x_dest, from) do
    from_key =
      case links do
        %{^from => %{key: k}} -> k
        _ -> nil
      end
    for k <- Bloom.multicast_targets(blooms, x_dest, from_key),
        pid = best_link(links, k),
        pid != nil,
        do: pid
  end
  defp pf_effects(st, effects) do
    {st, _memo} =
      Enum.reduce(effects, {st, nil}, fn
        {:send, pid, frame, mode}, {st, memo} ->
          tx_frame(st, pid, frame, mode, memo)
        {:deliver, src, payload}, {st, memo} ->
          {deliver(st, src, payload), memo}
        {:path_notify_event, key}, {st, memo} ->
          {path_notify(st, key), memo}
      end)
    st
  end
  defp deliver(%{subs: subs, ctx: ctx} = st, src, payload) do
    if map_size(subs) == 0 do
      Logger.debug(fn -> "Native router: traffic from #{short(src)}, no subscriber" end)
    else
      for {pid, _} <- subs, do: Kernel.send(pid, {:ygg_net, ctx.id, src, payload})
    end
    bump(st, :recv)
  end
  defp path_notify(%{subs: subs, ctx: ctx} = st, key) do
    Logger.debug(fn -> "Native router: path notify for #{short(key)}" end)
    RoutingLog.append(st.log_file, ctx.id, "path_notify", %{key: hex(key)})
    for {pid, _} <- subs, do: Kernel.send(pid, {:ygg_path, ctx.id, key})
    bump(st, :path_notify)
  end
  defp send_effects(st, effects) do
    {st, _memo} =
      Enum.reduce(effects, {st, nil}, fn {:send, pid, {name, _} = frame}, {st, memo} ->
        tx_frame(st, pid, frame, mode(name), memo)
      end)
    st
  end
  defp tx_frame(st, pid, frame, mode, memo) do
    data =
      case memo do
        {^frame, data} -> data
        _ -> Frames.encode_frame(frame)
      end
    tx(pid, data, mode)
    {count_out(st, elem(frame, 0)), {frame, data}}
  end
  defp tx_bloom(st, [], _f), do: st
  defp tx_bloom(st, pids, f) do
    data = Frames.frame(@bloom_type, Bloom.encode(f))
    for pid <- pids, do: tx(pid, data, :direct)
    Enum.reduce(pids, st, fn _, st -> count_out(st, :bloom) end)
  end
  defp tx(pid, data, mode), do: Kernel.send(pid, {:tx, data, mode})
  defp mode(name) when name in [:sig_req, :sig_res, :announce, :bloom], do: :direct
  defp mode(_name), do: :queued
  defp count_out(%{frames_out: f} = st, name),
    do: %{st | frames_out: Map.update(f, name, 1, &(&1 + 1))}
  defp dump(st) do
    infos = Tree.infos(st.tree)
    self_hex = hex(st.key)
    tree =
      for {k, i} <- Enum.sort(infos),
          do: %{"key" => hex(k), "parent" => hex(i.parent), "seq" => i.seq}
    parents = Map.new(tree, &{&1["key"], &1["parent"]})
    {root, depth} = walk_to_root(self_hex, parents, 0)
    peers =
      for p <- Tree.peers(st.tree) do
        rtt = get_in(st.links, [p.ref, :rtt_ns])
        %{
          "key" => hex(p.key),
          "port" => p.port,
          "cost" => p.cost,
          "priority" => p.prio,
          "latency_ms" => if(rtt, do: Float.round(rtt / 1_000_000, 2), else: 0.0),
          "remote" => ""
        }
      end
    paths =
      for {k, i} <- Enum.sort(Pathfinder.paths(st.pf)),
          do: %{"key" => hex(k), "path" => i.path, "seq" => i.seq}
    blooms =
      for {k, %Bloom.Info{send: s, recv: r}} <- Enum.sort(st.blooms) do
        b = %{"key" => hex(k), "send_bits" => popcount(s), "recv_bits" => popcount(r)}
        if st.bloom_full,
          do: Map.merge(b, %{"send_hex" => bloom_hex(s), "recv_hex" => bloom_hex(r)}),
          else: b
      end
    %{
      "ts_ms" => System.system_time(:millisecond),
      "mode" => "native",
      "self" => %{"key" => self_hex, "routing_entries" => map_size(infos)},
      "root" => root,
      "parent" => Map.get(parents, self_hex, ""),
      "depth" => depth,
      "peers" => peers,
      "tree" => tree,
      "paths" => paths,
      "blooms" => blooms
    }
  end
  defp walk_to_root(cur, _parents, 4096), do: {cur, 4096}
  defp walk_to_root(cur, parents, depth) do
    case parents do
      %{^cur => p} when p != cur and p != "" -> walk_to_root(p, parents, depth + 1)
      _ -> {cur, depth}
    end
  end
  defp popcount(f),
    do: for(<<(b::1 <- <<f::unsigned-big-size(8192)>>)>>, reduce: 0, do: (n -> n + b))
  defp bloom_hex(f), do: Base.encode16(<<f::unsigned-big-size(8192)>>, case: :lower)
  defp log_link(st, key, prio, up?) do
    Logger.debug(fn ->
      "Native router: link #{if up?, do: "up", else: "down"} #{short(key)} prio #{prio}"
    end)
    RoutingLog.append(st.log_file, st.ctx.id, "link", %{
      key: hex(key),
      priority: prio,
      up: up?,
      error: ""
    })
  end
  defp bump(%{stats: stats} = st, key), do: %{st | stats: Map.update!(stats, key, &(&1 + 1))}
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp hex(key), do: Base.encode16(key, case: :lower)
  defp short(key), do: key |> hex() |> binary_part(0, 8)
end