defmodule Ygg.Datagram do
  @moduledoc """
  Application-facing datagram API of a node (PLAN_STAGE2.md §3.1): what Yggdrasil's
  `core.Core` offers as a `net.PacketConn` (`reference/yggdrasil-go/src/core/core.go:166-220` `MTU`, `ReadFrom`,
  `WriteTo`) plus `lookup/2`. Payloads carry the Yggdrasil type byte (`1` session traffic,
  `2` proto); `Ygg.Core` answers proto requests and fans datagrams out to subscribers as
  `{:ygg_traffic, node_id, src_key, payload}`.
  The underlay chain is chosen once per node by `chain/1`:
  * `:sessions`: `Ygg.Sessions` (ironwood `encrypted`) on top of the `network` router,
    `router: :native`.
  * `:passthrough`: the router delivers datagrams as they are; only the test stub
    (`router: :stub`), which has no routing and no datagram processes.
  `child_specs/1` gives the processes of this layer for `Ygg.Node`: `Ygg.Sessions`,
  `Ygg.Core`, `Ygg.PingResponder`; none with the stub router.
  """
  alias Ygg.{Core, Node, Router, Sessions}
  @type chain :: :passthrough | :sessions
  @spec chain(Node.t()) :: chain()
  def chain(%{router: :native}), do: :sessions
  def chain(_ctx), do: :passthrough
  @spec child_specs(Node.t()) :: [{module(), Node.t()}]
  def child_specs(%{router: :stub}), do: []
  def child_specs(ctx) do
    sessions = if chain(ctx) == :sessions, do: [{Sessions, ctx}], else: []
    sessions ++ [{Core, ctx}, {Ygg.PingResponder, ctx}]
  end
  @doc "Send a datagram (type byte included) to a node key."
  @spec send(Node.t(), <<_::256>>, iodata()) :: :ok | {:error, term()}
  def send(ctx, <<_::binary-size(32)>> = key, payload) do
    case chain(ctx) do
      :passthrough -> Router.impl(ctx).send(ctx, key, payload)
      :sessions -> Sessions.send(ctx, key, payload)
    end
  end
  def send(_ctx, _key, _payload), do: {:error, :bad_key}
  @doc "Receive `{:ygg_traffic, node_id, src_key, payload}` for datagrams addressed to us."
  @spec subscribe(Node.t(), pid()) :: :ok | {:error, term()}
  def subscribe(ctx, pid \\ self()), do: Core.subscribe(ctx, pid)
  @spec unsubscribe(Node.t(), pid()) :: :ok | {:error, term()}
  def unsubscribe(ctx, pid \\ self()), do: Core.unsubscribe(ctx, pid)
  @doc "Path lookup for a (possibly partial) key, straight to the router."
  @spec lookup(Node.t(), <<_::256>>) :: :ok | {:error, term()}
  def lookup(ctx, key), do: Router.impl(ctx).lookup(ctx, key)
  @doc "Largest datagram `send/3` accepts, type byte included (the underlay's MTU)."
  @spec mtu(Node.t()) :: non_neg_integer() | {:error, term()}
  def mtu(ctx) do
    case chain(ctx) do
      :passthrough -> Router.impl(ctx).mtu(ctx)
      :sessions -> Sessions.mtu(ctx)
    end
  end
  @doc false
  @spec subscribe_underlay(Node.t(), pid()) :: :ok | {:error, term()}
  def subscribe_underlay(ctx, pid) do
    case chain(ctx) do
      :passthrough -> Router.impl(ctx).subscribe(ctx, pid)
      :sessions -> Sessions.subscribe(ctx, pid)
    end
  end
end