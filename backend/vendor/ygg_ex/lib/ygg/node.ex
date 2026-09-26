defmodule Ygg.Node do
  @moduledoc """
  One Yggdrasil node instance: the supervisor and the `%Ygg.Node{}` context handed to every
  process of the instance. Plays the role of `core.Core` / `core.New` (`reference/yggdrasil-go/src/core/core.go:50-136`):
  identity, options, then links and listeners last (core.go:111-134). Children: `Ygg.Peers`,
  the router (`Ygg.Router.impl/1`, before `Ygg.Links`, whose peers report to it), the
  datagram layer (`Ygg.Datagram.child_specs/1`), links, listeners, printers.
  Several instances can run in one VM (the loopback test), so nothing is registered under a fixed name: processes are
  found through `Ygg.Registry` under `{node_id, Module}` (see `via/2`). The context holds no
  pids, so child restarts are safe; the supervisor is `one_for_all` with zero restarts, a
  crashed core process therefore restarts the whole node from the application supervisor.
  """
  use Supervisor
  alias Ygg.Identity
  @registry Ygg.Registry
  defstruct [
    :id,
    :identity,
    peers: [],
    listen: [],
    allowed_keys: MapSet.new(),
    send_sig_req: true,
    handshake_timeout: 6_000,
    status_interval_ms: 10_000,
    node_info: %{},
    node_info_privacy: false,
    frame_tap: nil,
    public_peers: %{enabled: false},
    router: :stub,
    routing: %{},
    address_file: nil
  ]
  @type t :: %__MODULE__{id: term(), identity: Identity.t()}
  def registry, do: @registry
  @doc """
  Options: `identity` (required), `name` (registered supervisor name, also the node id),
  `peers` (URIs), `listen` (URIs), `allowed_keys` (raw 32-byte keys), `send_sig_req`,
  `handshake_timeout`, `status_interval_ms` (0 disables the printer), `router`
  (`:native` for `Ygg.Router.Native`, what `ygg.json` always gives; `:stub`, the default here,
  is the stage-1 `Ygg.Router.Stub` for tests; see `Ygg.Router.impl/1`) and `routing` (options
  map for the native router and sessions, see `Ygg.Config.routing_opts/1`), `node_info` /
  `node_info_privacy` (`Ygg.Core`), `frame_tap`
  (pid receiving `{:frame, :in | :out, remote_key, frame}` from every `Ygg.Peer`, nil for
  none), `address_file` (path for `Ygg.AddressFile`, nil writes nothing).
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    id = name || {:node, make_ref()}
    sup_opts = if name, do: [name: name], else: []
    Supervisor.start_link(__MODULE__, {id, opts}, sup_opts)
  end
  @impl true
  def init({id, opts}) do
    ctx = %__MODULE__{
      id: id,
      identity: Keyword.fetch!(opts, :identity),
      peers: Keyword.get(opts, :peers, []),
      listen: Keyword.get(opts, :listen, []),
      allowed_keys: MapSet.new(Keyword.get(opts, :allowed_keys, [])),
      send_sig_req: Keyword.get(opts, :send_sig_req, true),
      handshake_timeout: Keyword.get(opts, :handshake_timeout, 6_000),
      status_interval_ms: Keyword.get(opts, :status_interval_ms, 10_000),
      node_info: Keyword.get(opts, :node_info, %{}),
      node_info_privacy: Keyword.get(opts, :node_info_privacy, false),
      frame_tap: Keyword.get(opts, :frame_tap),
      public_peers: Keyword.get(opts, :public_peers, %{enabled: false}),
      router: Keyword.get(opts, :router, :stub),
      routing: Keyword.get(opts, :routing, %{}),
      address_file: Keyword.get(opts, :address_file)
    }
    listeners =
      for {uri, i} <- Enum.with_index(ctx.listen),
          do: Supervisor.child_spec({Ygg.Listener, {ctx, uri}}, id: {Ygg.Listener, i})
    printer = if ctx.status_interval_ms > 0, do: [{Ygg.StatusPrinter, ctx}], else: []
    children =
      [{Ygg.Peers, ctx}] ++
        Ygg.Router.impl(ctx).child_specs(ctx) ++
        Ygg.Datagram.child_specs(ctx) ++
        [
          {DynamicSupervisor, name: via(ctx, Ygg.LinkSupervisor), strategy: :one_for_one},
          {Ygg.Links, ctx}
        ] ++ listeners ++ printer ++ public_peers(ctx) ++ address_file(ctx)
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end
  defp address_file(%{address_file: path} = ctx) when is_binary(path) and path != "",
    do: [{Ygg.AddressFile, ctx}]
  defp address_file(_ctx), do: []
  defp public_peers(%{public_peers: %{enabled: true}} = ctx), do: [{Ygg.PublicPeers, ctx}]
  defp public_peers(_ctx), do: []
  @doc "Registered name of an instance process."
  @spec via(t() | term(), term()) :: {:via, Registry, {atom(), term()}}
  def via(%__MODULE__{id: id}, key), do: {:via, Registry, {@registry, {id, key}}}
  def via(id, key), do: {:via, Registry, {@registry, {id, key}}}
  @doc "Context of a running node by id (registered by `Ygg.Links`)."
  @spec ctx(term()) :: {:ok, t()} | {:error, :not_running}
  def ctx(%__MODULE__{} = ctx), do: {:ok, ctx}
  def ctx(id) do
    case Registry.lookup(@registry, {id, :ctx}) do
      [{_pid, ctx}] -> {:ok, ctx}
      [] -> {:error, :not_running}
    end
  end
  @doc "Bound addresses of the node's listeners as `{uri, {ip, port}}`."
  @spec listen_addrs(term()) :: [{String.t(), {:inet.ip_address(), :inet.port_number()}}]
  def listen_addrs(%__MODULE__{id: id}), do: listen_addrs(id)
  def listen_addrs(id) do
    spec = [{{{id, {Ygg.Listener, :"$1"}}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}]
    for {uri, pid} <- Registry.select(@registry, spec),
        addr = Ygg.Listener.addr(pid),
        addr != nil do
      {uri, addr}
    end
  end
end