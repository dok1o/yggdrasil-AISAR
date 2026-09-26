defmodule Ygg.Links do
  @moduledoc """
  Registry of links of one node. Ports the `links` actor from `reference/yggdrasil-go/src/core/link.go`:
  `_links` map keyed by URI-without-query (`linkInfo`, link.go:53-57, `urlForLinkInfo`
  link.go:766), `add` (link.go:160-244: duplicate -> kick + `ErrLinkAlreadyConfigured`),
  `remove` (link.go:419-444), `RetryPeersNow` (core.go:138-147), the per-second
  `_updateAverages` (link.go:106-130: `rate = rx - lastrx`) and the status view behind
  `Core.GetPeers` (api.go `PeerInfo`). Links never calls into `Ygg.Link`/`Ygg.Peer`
  (a link may sit in a 6 s handshake); state changes arrive as casts.
  The peer list from the node context is added in `handle_continue`, after the rest of the
  node is up, like `core.New` applies `Peer`/`ListenAddress` options last (core.go:111-121).
  """
  use GenServer
  require Logger
  alias Ygg.{Address, Identity, Link, Node, PeerURI, Transport}
  @tick 1_000
  @readd_delay 1_000
  def start_link(ctx), do: GenServer.start_link(__MODULE__, ctx, name: Node.via(ctx, __MODULE__))
  @spec add(Node.t(), String.t()) :: :ok | {:error, term()}
  def add(ctx, uri), do: GenServer.call(Node.via(ctx, __MODULE__), {:add, uri})
  @doc "Called by `Ygg.Listener` with an accepted socket; returns the link pid to hand it to."
  @spec add_incoming(Node.t(), map()) :: {:ok, pid()} | {:error, :duplicate}
  def add_incoming(ctx, info),
    do: GenServer.call(Node.via(ctx, __MODULE__), {:add_incoming, info})
  @spec remove(Node.t(), String.t()) :: :ok | {:error, term()}
  def remove(ctx, uri), do: GenServer.call(Node.via(ctx, __MODULE__), {:remove, uri})
  @spec retry_now(Node.t()) :: :ok
  def retry_now(ctx), do: GenServer.cast(Node.via(ctx, __MODULE__), :retry_now)
  @spec list(Node.t()) :: [map()]
  def list(ctx), do: GenServer.call(Node.via(ctx, __MODULE__), :list)
  @doc "State change from a `Ygg.Link` (cast)."
  def update(ctx, info_uri, changes),
    do: GenServer.cast(Node.via(ctx, __MODULE__), {:update, info_uri, changes})
  @doc "Periodic protocol-level info from a `Ygg.Peer` (cast)."
  def peer_info(ctx, info_uri, info),
    do: GenServer.cast(Node.via(ctx, __MODULE__), {:peer_info, info_uri, info})
  @impl true
  def init(ctx) do
    {:ok, _} = Registry.register(Node.registry(), {ctx.id, :ctx}, ctx)
    Process.send_after(self(), :tick, @tick)
    {:ok, %{ctx: ctx, links: %{}, monitors: %{}}, {:continue, :add_peers}}
  end
  @impl true
  def handle_continue(:add_peers, %{ctx: ctx} = st) do
    st =
      Enum.reduce(ctx.peers, st, fn uri, st ->
        case do_add(uri, st) do
          {:ok, st} ->
            st
          {:error, reason, st} ->
            Logger.error("Failed to add peer #{uri}: #{inspect(reason)}")
            st
        end
      end)
    {:noreply, st}
  end
  @impl true
  def handle_call({:add, uri}, _from, st) do
    case do_add(uri, st) do
      {:ok, st} -> {:reply, :ok, st}
      {:error, reason, st} -> {:reply, {:error, reason}, st}
    end
  end
  def handle_call({:add_incoming, %{info_uri: info} = spec}, _from, %{links: links} = st) do
    case Map.get(links, info) do
      %{state: :up} ->
        {:reply, {:error, :duplicate}, st}
      _other ->
        {:ok, pid} = start_child(st.ctx, {st.ctx, spec, :incoming})
        entry = new_entry(pid, :incoming, spec.scheme, info, info, spec.priority)
        {:reply, {:ok, pid}, put_entry(st, entry)}
    end
  end
  def handle_call({:remove, uri}, _from, %{links: links} = st) do
    with {:ok, %{info_uri: info}} <- PeerURI.parse(uri),
         %{pid: pid} <- Map.get(links, info) || {:error, :not_configured} do
      DynamicSupervisor.terminate_child(Node.via(st.ctx, Ygg.LinkSupervisor), pid)
      {:reply, :ok, st}
    else
      {:error, reason} -> {:reply, {:error, reason}, st}
    end
  end
  def handle_call(:list, _from, %{links: links} = st) do
    {:reply, links |> Map.values() |> Enum.map(&to_status/1), st}
  end
  @impl true
  def handle_cast(:retry_now, %{links: links} = st) do
    for %{pid: pid} <- Map.values(links), do: Link.kick(pid)
    {:noreply, st}
  end
  def handle_cast({:update, info, changes}, %{links: links} = st) do
    case Map.get(links, info) do
      nil -> {:noreply, st}
      entry -> {:noreply, %{st | links: Map.put(links, info, apply_update(entry, changes))}}
    end
  end
  def handle_cast({:peer_info, info, pinfo}, %{links: links} = st) do
    case Map.get(links, info) do
      nil -> {:noreply, st}
      entry -> {:noreply, %{st | links: Map.put(links, info, %{entry | peer: pinfo})}}
    end
  end
  @impl true
  def handle_info(:tick, %{links: links} = st) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, %{st | links: Map.new(links, fn {k, e} -> {k, averages(e)} end)}}
  end
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitors: mons, links: links} = st) do
    case Map.pop(mons, ref) do
      {nil, _} ->
        {:noreply, st}
      {info, mons} ->
        entry = Map.get(links, info)
        st = %{st | monitors: mons, links: Map.delete(links, info)}
        if (entry && entry.type == :persistent && reason not in [:normal, :shutdown]) and
             not match?({:shutdown, _}, reason) do
          Logger.error("Link #{info} crashed: #{inspect(reason)}; re-adding")
          Process.send_after(self(), {:readd, entry.uri}, @readd_delay)
        end
        {:noreply, st}
    end
  end
  def handle_info({:readd, uri}, st) do
    case do_add(uri, st) do
      {:ok, st} -> {:noreply, st}
      {:error, _reason, st} -> {:noreply, st}
    end
  end
  defp do_add(uri, %{ctx: ctx, links: links} = st) do
    case PeerURI.parse(uri) do
      {:ok, %PeerURI{info_uri: info} = p} ->
        case Map.get(links, info) do
          %{pid: pid} ->
            Link.kick(pid)
            {:error, :already_configured, st}
          nil ->
            {:ok, pid} = start_child(ctx, {ctx, p, :persistent})
            {:ok, put_entry(st, new_entry(pid, :persistent, p.scheme, uri, info, p.priority))}
        end
      {:error, reason} ->
        {:error, reason, st}
    end
  end
  defp start_child(ctx, arg),
    do: DynamicSupervisor.start_child(Node.via(ctx, Ygg.LinkSupervisor), {Link, arg})
  defp put_entry(%{links: links, monitors: mons} = st, %{pid: pid, info_uri: info} = entry) do
    ref = Process.monitor(pid)
    %{st | links: Map.put(links, info, entry), monitors: Map.put(mons, ref, info)}
  end
  defp new_entry(pid, type, proto, uri, info, priority) do
    %{
      pid: pid,
      type: type,
      proto: proto,
      uri: uri,
      info_uri: info,
      state: :connecting,
      err: nil,
      errtime: nil,
      up_since: nil,
      counters: nil,
      rx: 0,
      tx: 0,
      lastrx: 0,
      lasttx: 0,
      rx_rate: 0,
      tx_rate: 0,
      remote_key: nil,
      priority: priority,
      port: nil,
      peer: %{},
      ups: 0
    }
  end
  defp apply_update(entry, %{state: :up} = changes) do
    entry
    |> Map.merge(changes)
    |> Map.merge(%{
      err: nil,
      errtime: nil,
      rx: 0,
      tx: 0,
      lastrx: 0,
      lasttx: 0,
      rx_rate: 0,
      tx_rate: 0,
      peer: %{},
      ups: entry.ups + 1
    })
  end
  defp apply_update(entry, %{state: state} = changes) when state in [:down, :connecting] do
    entry
    |> Map.merge(changes)
    |> Map.merge(%{counters: nil, up_since: nil, rx_rate: 0, tx_rate: 0, port: nil})
  end
  defp apply_update(entry, changes), do: Map.merge(entry, changes)
  defp averages(%{counters: nil} = e), do: e
  defp averages(%{counters: c} = e) do
    {rx, tx} = Transport.read_counters(c)
    %{e | rx: rx, tx: tx, rx_rate: rx - e.lastrx, tx_rate: tx - e.lasttx, lastrx: rx, lasttx: tx}
  end
  @doc "Public status map for one link (cf. `PeerInfo` in api.go)."
  def to_status(e) do
    now = System.monotonic_time(:millisecond)
    %{
      uri: e.uri,
      info_uri: e.info_uri,
      inbound: e.type == :incoming,
      proto: e.proto,
      state: e.state,
      up: e.state == :up,
      uptime_ms: if(e.up_since, do: now - e.up_since, else: 0),
      last_error: e.err,
      last_error_age_ms: if(e.errtime, do: now - e.errtime, else: nil),
      key: e.remote_key && Identity.pub_hex(e.remote_key),
      address: e.remote_key && Address.format(Address.addr_for_key(e.remote_key)),
      priority: e.priority,
      port: e.port,
      rx_bytes: e.rx,
      tx_bytes: e.tx,
      rx_rate: e.rx_rate,
      tx_rate: e.tx_rate,
      rtt_ms: Map.get(e.peer, :rtt_ms),
      parent: Map.get(e.peer, :parent),
      seq: Map.get(e.peer, :seq),
      bloom_size: Map.get(e.peer, :bloom_size),
      frames: Map.get(e.peer, :counts, %{}),
      ups: e.ups,
      peer_pid: Map.get(e, :peer_pid)
    }
  end
end