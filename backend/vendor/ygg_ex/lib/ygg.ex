defmodule Ygg do
  @moduledoc """
  Public API of the node, the replacement for the admin socket (`Core.GetSelf`, `GetPeers`,
  `AddPeer`, `RemovePeer`, `RetryPeersNow` in `reference/yggdrasil-go/src/core/api.go` / `core.go`, `GetNodeInfo` in
  `nodeinfo.go`). Every function takes the node id (the `name` given to
  `Ygg.Node.start_link/1`); the default instance started by `Ygg.Application` is `Ygg.Node`.
  Traffic goes through `Ygg.Datagram` (the Yggdrasil layer), routing data through the router
  selected by `Ygg.Router.impl/1`.
  """
  alias Ygg.{Address, Core, Datagram, Identity, Links, Node, Router, Sessions}
  @default Node
  @doc "Send a datagram (Yggdrasil type byte included) to a node key (hex or raw 32 bytes)."
  @spec send_traffic(String.t() | <<_::256>>, iodata(), term()) :: :ok | {:error, term()}
  def send_traffic(key, payload, node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node),
         {:ok, raw} <- key_bytes(key),
         do: Datagram.send(ctx, raw, payload)
  end
  @doc "Ask the router for a path lookup of a (possibly partial) key."
  @spec lookup(String.t() | <<_::256>>, term()) :: :ok | {:error, term()}
  def lookup(key, node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node),
         {:ok, raw} <- key_bytes(key),
         do: Datagram.lookup(ctx, raw)
  end
  @doc """
  Routing dump of the router (`dump.go` shape: peers, tree, paths, blooms, sessions); with
  `Ygg.Sessions` underneath, `"sessions"` comes from `Ygg.Sessions.dump/1`.
  """
  @spec routing(term()) :: map() | nil | {:error, term()}
  def routing(node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node) do
      case {Router.impl(ctx).routing(ctx), Datagram.chain(ctx)} do
        {%{} = dump, :sessions} -> Map.put(dump, "sessions", Sessions.dump(ctx))
        {other, _} -> other
      end
    end
  end
  @doc "Request a routing dump now (logged and available via `routing/1`)."
  @spec dump_routing(term()) :: :ok | {:error, term()}
  def dump_routing(node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node), do: Router.impl(ctx).request_dump(ctx)
  end
  @doc "Receive `{:ygg_traffic, node_id, src_key, payload}` for traffic addressed to us."
  @spec subscribe_traffic(term(), pid()) :: :ok | {:error, term()}
  def subscribe_traffic(node \\ @default, pid \\ self()) do
    with {:ok, ctx} <- Node.ctx(node), do: Datagram.subscribe(ctx, pid)
  end
  @spec router_stats(term()) :: map() | {:error, term()}
  def router_stats(node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node), do: Router.impl(ctx).stats(ctx)
  end
  @doc """
  NodeInfo of a remote node (`yggdrasilctl getNodeInfo`, `nodeinfo.go` `sendReq`): the
  request is resent every 500 ms (a session needs a moment) until a response arrives or
  `timeout` ms pass.
  """
  @spec node_info(String.t() | <<_::256>>, term(), timeout()) :: {:ok, map()} | {:error, term()}
  def node_info(key, node \\ @default, timeout \\ 10_000) do
    with {:ok, ctx} <- Node.ctx(node),
         {:ok, raw} <- key_bytes(key) do
      await_node_info(ctx, raw, System.monotonic_time(:millisecond) + timeout)
    end
  end
  defp await_node_info(%{id: id} = ctx, key, deadline) do
    with :ok <- Core.request_node_info(ctx, key, self()) do
      wait = min(500, max(deadline - System.monotonic_time(:millisecond), 0))
      receive do
        {:ygg_node_info, ^id, ^key, json} -> Jason.decode(json)
      after
        wait ->
          if System.monotonic_time(:millisecond) >= deadline,
            do: {:error, :timeout},
            else: await_node_info(ctx, key, deadline)
      end
    end
  end
  defp key_bytes(<<_::binary-size(32)>> = raw), do: {:ok, raw}
  defp key_bytes(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(32)>> = raw} -> {:ok, raw}
      _ -> {:error, :bad_key}
    end
  end
  defp key_bytes(_), do: {:error, :bad_key}
  @doc "Status maps of all links (see `Ygg.Links.to_status/1`)."
  @spec status(term()) :: [map()]
  def status(node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node), do: Links.list(ctx)
  end
  @doc "Our key, address and subnet (cf. `GetSelf`)."
  @spec self_info(term()) :: map() | {:error, :not_running}
  def self_info(node \\ @default) do
    with {:ok, %{identity: id} = ctx} <- Node.ctx(node) do
      %{
        key: Identity.pub_hex(id),
        address: Address.format(id.address),
        subnet: Address.format(id.subnet),
        listen: Node.listen_addrs(ctx)
      }
    end
  end
  @spec add_peer(String.t(), term()) :: :ok | {:error, term()}
  def add_peer(uri, node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node), do: Links.add(ctx, uri)
  end
  @spec remove_peer(String.t(), term()) :: :ok | {:error, term()}
  def remove_peer(uri, node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node), do: Links.remove(ctx, uri)
  end
  @spec retry_peers_now(term()) :: :ok | {:error, term()}
  def retry_peers_now(node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node), do: Links.retry_now(ctx)
  end
  @doc "Prints the status table once."
  def print_status(node \\ @default) do
    with {:ok, ctx} <- Node.ctx(node) do
      IO.puts(Ygg.StatusPrinter.format(Links.list(ctx), ctx.identity))
    end
  end
end