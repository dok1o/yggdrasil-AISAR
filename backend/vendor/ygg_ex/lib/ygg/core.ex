defmodule Ygg.Core do
  @moduledoc """
  The Yggdrasil layer over ironwood datagrams: `core.ReadFrom` type-byte dispatch
  (`reference/yggdrasil-go/src/core/core.go:175-208`), the proto handler (`proto.go` `handleProto`) and the
  NodeInfo responder (`nodeinfo.go:81-132`). One GenServer per node, registered as
  `Ygg.Node.via(ctx, Ygg.Core)`; it subscribes to the underlay chosen by `Ygg.Datagram`
  (the router for pass-through, `Ygg.Sessions` otherwise) and receives
  `{:ygg_net | :ygg_datagram, node_id, src_key, payload}`.
  First payload byte: `1` session traffic (an IPv6 packet for Yggdrasil) goes to the
  subscribers as `{:ygg_traffic, node_id, src_key, payload}` with the type byte kept;
  `2` proto: `<<2, 1>>` NodeInfoRequest is answered with `<<2, 2>> <> json`,
  `<<2, 2, json>>` NodeInfoResponse goes to `request_node_info/2` callers as
  `{:ygg_node_info, node_id, key, json}`, Debug (`<<2, 255, ...>>`) is ignored (the Go
  requester times out after 6 s). Deviation: Go drops every other first byte; here they reach
  the subscribers like type 1, so application datagrams need no Yggdrasil framing between
  `ygg_ex` nodes (PLAN_STAGE2.md §10 q.3).
  NodeInfo JSON = `ctx.node_info` plus `buildname`/`buildversion`/`buildplatform`/`buildarch`
  unless `ctx.node_info_privacy` (`_setNodeInfo`), at most 16384 bytes.
  A subscriber whose `message_queue_len` exceeds #{1_000} gets nothing until it catches up
  (Go bounds its read queue to 131070 bytes, `packetconn.go:215-217`); drops are counted.
  """
  use GenServer
  require Logger
  alias Ygg.{Datagram, Identity, Node}
  @proto 2
  @proto_nodeinfo_req 1
  @proto_nodeinfo_res 2
  @max_queue 1_000
  @max_nodeinfo 16_384
  defstruct [:ctx, :node_info, subscribers: %{}, waiters: %{}, stats: %{}]
  def start_link(ctx), do: GenServer.start_link(__MODULE__, ctx, name: Node.via(ctx, __MODULE__))
  @doc "Deliver `{:ygg_traffic, node_id, src_key, payload}` to `pid`."
  @spec subscribe(Node.t(), pid()) :: :ok | {:error, term()}
  def subscribe(ctx, pid), do: call(ctx, {:subscribe, pid})
  @spec unsubscribe(Node.t(), pid()) :: :ok | {:error, term()}
  def unsubscribe(ctx, pid), do: call(ctx, {:unsubscribe, pid})
  @doc """
  Send a NodeInfoRequest to `key`; the answer arrives in `pid` as
  `{:ygg_node_info, node_id, key, json}` (waiters are served by the first response only).
  """
  @spec request_node_info(Node.t(), <<_::256>>, pid()) :: :ok | {:error, term()}
  def request_node_info(ctx, key, pid \\ self()), do: call(ctx, {:node_info_req, key, pid})
  @spec stats(Node.t()) :: map() | {:error, term()}
  def stats(ctx), do: call(ctx, :stats)
  @doc "Our NodeInfo JSON as it is sent (`_setNodeInfo`)."
  @spec node_info_json(map(), boolean()) :: {:ok, binary()} | {:error, term()}
  def node_info_json(given, privacy) do
    info = if privacy, do: given, else: Map.merge(given, build_info())
    case Jason.encode(info) do
      {:ok, json} when byte_size(json) > @max_nodeinfo -> {:error, :nodeinfo_too_long}
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:nodeinfo_json, reason}}
    end
  end
  defp build_info do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()
    %{
      "buildname" => "ygg_ex",
      "buildversion" => Application.spec(:ygg_ex, :vsn) |> to_string(),
      "buildplatform" => :os.type() |> elem(1) |> Atom.to_string(),
      "buildarch" => goarch(arch)
    }
  end
  defp goarch("x86_64" <> _), do: "amd64"
  defp goarch("aarch64" <> _), do: "arm64"
  defp goarch("arm" <> _), do: "arm"
  defp goarch(other), do: other |> String.split("-") |> hd()
  defp call(ctx, msg) do
    GenServer.call(Node.via(ctx, __MODULE__), msg)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end
  @impl true
  def init(%Node{} = ctx) do
    case node_info_json(ctx.node_info || %{}, ctx.node_info_privacy) do
      {:ok, json} ->
        stats = %{delivered: 0, dropped: 0, no_subscriber: 0, proto: 0, node_info_req: 0}
        st = %__MODULE__{ctx: ctx, node_info: json, stats: stats}
        {:ok, st, {:continue, :subscribe}}
      {:error, reason} ->
        {:stop, reason}
    end
  end
  @impl true
  def handle_continue(:subscribe, %{ctx: ctx} = st) do
    case Datagram.subscribe_underlay(ctx, self()) do
      :ok -> {:noreply, st}
      {:error, reason} -> {:stop, {:subscribe_failed, reason}, st}
    end
  end
  @impl true
  def handle_call({:subscribe, pid}, _from, %{subscribers: subs} = st) do
    subs = if Map.has_key?(subs, pid), do: subs, else: Map.put(subs, pid, Process.monitor(pid))
    {:reply, :ok, %{st | subscribers: subs}}
  end
  def handle_call({:unsubscribe, pid}, _from, %{subscribers: subs} = st) do
    {ref, subs} = Map.pop(subs, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{st | subscribers: subs}}
  end
  def handle_call({:node_info_req, key, pid}, _from, %{ctx: ctx, waiters: w} = st) do
    reply = Datagram.send(ctx, key, <<@proto, @proto_nodeinfo_req>>)
    {:reply, reply, %{st | waiters: Map.update(w, key, [pid], &Enum.uniq([pid | &1]))}}
  end
  def handle_call(:stats, _from, st),
    do: {:reply, Map.put(st.stats, :subscribers, map_size(st.subscribers)), st}
  @impl true
  def handle_info({tag, _node, src, <<@proto, rest::binary>>}, st)
      when tag in [:ygg_net, :ygg_datagram],
      do: {:noreply, proto(src, rest, bump(st, :proto))}
  def handle_info({tag, _node, src, <<_type, _::binary>> = payload}, st)
      when tag in [:ygg_net, :ygg_datagram],
      do: {:noreply, deliver(src, payload, st)}
  def handle_info({:DOWN, _ref, :process, pid, _}, st),
    do: {:noreply, %{st | subscribers: Map.delete(st.subscribers, pid)}}
  def handle_info(_msg, st), do: {:noreply, st}
  defp deliver(src, payload, %{subscribers: subs} = st) when map_size(subs) == 0 do
    Logger.debug(fn ->
      "Datagram from #{short(src)} (#{byte_size(payload)} bytes, type #{:binary.first(payload)}), no subscriber"
    end)
    bump(st, :no_subscriber)
  end
  defp deliver(src, payload, %{ctx: ctx, subscribers: subs} = st) do
    msg = {:ygg_traffic, ctx.id, src, payload}
    Enum.reduce(subs, st, fn {pid, _ref}, st ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} when n > @max_queue ->
          bump(st, :dropped)
        _ ->
          send(pid, msg)
          bump(st, :delivered)
      end
    end)
  end
  defp proto(src, <<@proto_nodeinfo_req, _::binary>>, %{ctx: ctx} = st) do
    case Datagram.send(ctx, src, [<<@proto, @proto_nodeinfo_res>>, st.node_info]) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("NodeInfo reply to #{short(src)}: #{inspect(reason)}")
    end
    bump(st, :node_info_req)
  end
  defp proto(src, <<@proto_nodeinfo_res, json::binary>>, %{ctx: ctx, waiters: w} = st) do
    {pids, w} = Map.pop(w, src, [])
    for pid <- pids, do: send(pid, {:ygg_node_info, ctx.id, src, json})
    %{st | waiters: w}
  end
  defp proto(_src, _other, st), do: st
  defp bump(%{stats: s} = st, key), do: %{st | stats: Map.update(s, key, 1, &(&1 + 1))}
  defp short(key), do: key |> Identity.pub_hex() |> binary_part(0, 8)
end