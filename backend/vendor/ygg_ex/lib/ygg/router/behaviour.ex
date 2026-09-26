defmodule Ygg.Router.Behaviour do
  @moduledoc """
  The network layer of a node (PLAN_STAGE2.md §3.3): what ironwood's `network.PacketConn`
  offers to its user (`network/packetconn.go`: `WriteTo`, `ReadFrom`, `SendLookup`, `MTU`,
  `HandleConn`, `Debug.*`). Two implementations, selected by `ctx.router` through
  `Ygg.Router.impl/1`: `Ygg.Router.Native` (the Elixir port) and `Ygg.Router.Stub` (stage 1,
  no routing, test default).
  `send/3` writes raw network traffic (no Yggdrasil type byte handling, no sessions: that is
  `Ygg.Datagram`/`Ygg.Core`/`Ygg.Sessions` above). Subscribers receive
  `{:ygg_net, node_id, src_key, payload}` for traffic addressed to us and
  `{:ygg_path, node_id, key}` when a path to `key` was learned (`config.pathNotify`).
  `peer_up/5` and `frame/3` are the casts `Ygg.Peer` uses (STAGE2_CONTRACTS.md §3).
  """
  alias Ygg.{Frames, Node}
  @type key :: <<_::256>>
  @callback child_specs(Node.t()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  @callback send(Node.t(), key(), iodata()) :: :ok | {:error, term()}
  @callback lookup(Node.t(), key()) :: :ok | {:error, term()}
  @callback subscribe(Node.t(), pid()) :: :ok | {:error, term()}
  @callback unsubscribe(Node.t(), pid()) :: :ok | {:error, term()}
  @callback routing(Node.t()) :: map() | nil | {:error, term()}
  @callback request_dump(Node.t()) :: :ok | {:error, term()}
  @callback stats(Node.t()) :: map() | {:error, term()}
  @callback mtu(Node.t()) :: non_neg_integer() | {:error, term()}
  @callback peer_up(Node.t(), pid(), key(), pos_integer(), byte()) :: :ok
  @callback frame(Node.t(), pid(), Frames.frame()) :: :ok
end