defmodule MagnetSorter.Application do
  use Application
  def start(_type, _args) do
    {children, opts} = get_supervisor_tree()
    IO.inspect(System.version(), label: "Runtime Elixir")
    Supervisor.start_link(children, opts)
  end
  defp get_supervisor_tree() do
    children =
      registries() ++
        infrastructure() ++
        task_and_dynamic_supervisors() ++
        node_supervisors() ++
        pf_supervisors() ++
        ygg_supervisors() ++
        ygg_pf_supervisors() ++
        gui_bridge() ++
        control_plane()
    opts = [strategy: :one_for_one, name: MagnetSorter.Supervisor]
    {children, opts}
  end
  defp registries() do
    [
      {Registry, keys: :unique, name: Reg.UDPShardRegistry},
      {Registry, keys: :unique, name: Reg.UTPConnRegistry}
    ]
  end
  defp infrastructure() do
    [
      MagnetSorter.Repo,
      GenS.SettingsManager,
      Spv.SQLBatcherSup,
      GenS.PeerManager,
      GenS.IdStorage,
      GenS.NATChk
    ]
  end
  defp task_and_dynamic_supervisors() do
    mcn = 1_024 * 12
    [
      {Task.Supervisor, name: Spv.FetchTask, max_children: mcn, checkpoint: 5_000},
      {Task.Supervisor, name: Spv.ConnTask, max_children: mcn, checkpoint: 5_000},
      Spv.UTPIncomingConnSup,
      Spv.InfohashWorkerSup,
      Spv.HydraWorkerSup
    ]
  end
  defp node_supervisors() do
    [
      Spv.SocketSup,
      Spv.MainlineDHTSup,
      Spv.LegacyNodeSup
    ]
  end
  defp pf_supervisors() do
    [
      Spv.FnodeSup
    ]
  end
  defp ygg_supervisors() do
    [
      Supervisor.child_spec(Spv.YggSup, restart: :temporary),
      Spv.YggSup.watch_spec()
    ]
  end
  # SDP bootstrap over Mainline DHT. Starts after ygg_supervisors/0 because
  # candidate validation needs the embedded Ygg node (spec section 34), and is skipped
  # entirely when Yggdrasil is disabled.
  defp ygg_pf_supervisors() do
    Spv.YggPFSup.child_spec_if_enabled()
  end
  defp gui_bridge() do
    [
      GenS.Metrics,
      GenS.GUIServer,
      GenS.GUIExit
    ]
  end
  defp control_plane() do
    [
      GenS.Guardian,
      GenS.ExtSaver
    ]
  end
end
defmodule Spv.SQLBatcherSup do
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts) do
    children = [
      GenS.SQLiteBatcher
    ]
    Supervisor.init(children, strategy: :one_for_all)
  end
end
defmodule Spv.UTPIncomingConnSup do
  use DynamicSupervisor
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
  def start_conn(args) do
    DynamicSupervisor.start_child(__MODULE__, {GenS.UTPConn, args})
  end
end
defmodule Spv.InfohashWorkerSup do
  use DynamicSupervisor
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
  def start_worker(args) do
    DynamicSupervisor.start_child(__MODULE__, {GenS.InfohashWorker, args})
  end
end
defmodule Spv.HydraWorkerSup do
  use DynamicSupervisor
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
  def start_worker(args) do
    DynamicSupervisor.start_child(__MODULE__, {GenS.HydraWorker, args})
  end
end
defmodule Spv.SocketSup do
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts) do
    num_schedulers = System.schedulers_online()
    num_shards =
      case OSChkSync.os_rules() do
        :non_unix_rules -> 1
        r when r in [:linux_rules, :mac_rules] -> max(1, num_schedulers - 1)
      end
    KeyStorageSync.set_num_udp_shards(num_shards)
    udp_socket_shards = %{
      id: :shard_supervisor,
      start:
        {Supervisor, :start_link,
         [
           shard_specs(num_shards),
           [strategy: :one_for_one, name: __MODULE__.Shards]
         ]}
    }
    children = [
      udp_socket_shards
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
  defp shard_specs(num_shards) do
    for shard_id <- 1..num_shards do
      %{
        id: {:shard, shard_id},
        start: {GenS.UDPSocketShard, :start_link, [shard_id]}
      }
    end
  end
end
defmodule Spv.MainlineDHTSup do
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts) do
    children = [
      GenS.SampleCoordinator,
      GenS.RoutingBootstrap,
      GenS.RoutingTable,
      GenS.MainlineOutgoing
    ]
    Supervisor.init(children, strategy: :one_for_all)
  end
end
defmodule Spv.LegacyNodeSup do
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts) do
    children = [
      GenS.KRPCPayloadFactory,
      GenS.IHWorkerRouter,
      GenS.TJFWriter,
      GenS.ResourceLimiter,
      GenS.ConnectionsOut,
      Spv.ConnSup,
      GenS.InfohashWorkerPool,
      GenS.InfohashCollector,
      GenS.SearchManager
    ]
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
defmodule Spv.FnodeSup do
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts) do
    children = [
      GenS.PFLog,
      GenS.PFNodesProcessor,
      GenS.PFRoutingBootstrap,
      GenS.PFRoutingTable
    ]
    Supervisor.init(children, strategy: :one_for_all)
  end
end
defmodule Spv.ConnSup do
  use DynamicSupervisor
  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
  def start_connection(:tcp, {peer, owner, waiter, continuation?}) do
    case GenS.ConnectionsOut.acquire(:tcp, peer, continuation?) do
      :ok ->
        start_and_handle(:tcp, peer, {GenS.TCPConn, {peer, owner, waiter}})
      {:error, _reason} = err ->
        err
    end
  end
  def start_connection(:utp, {peer, owner, waiter, continuation?}) do
    case GenS.ConnectionsOut.acquire(:utp, peer, continuation?) do
      :ok ->
        GenS.Metrics.increment(:utp_attempts)
        start_and_handle(:utp, peer, {GenS.UTPConn, {peer, owner, waiter}})
      {:error, _reason} = err ->
        err
    end
  end
  defp start_and_handle(type, peer, child_spec) do
    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        GenS.ConnectionsOut.release(type, peer)
        {:ok, pid}
      {:error, _reason} = err ->
        GenS.ConnectionsOut.release(type, peer)
        err
    end
  end
  def stop_connection(pid), do: DynamicSupervisor.terminate_child(__MODULE__, pid)
end
defmodule Spv.YggSup do
  use Supervisor
  require Logger
  @ygg_opts [
    base_dir: "../data/ygg",
    config_file: "../data/ygg/ygg.json",
    log_file: "../data/logs/ygg.log"
  ]
  def start_link(opts \\ []) do
    case Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      {:error, reason} ->
        Logger.error("[Ygg] Yggdrasil disabled until restart: #{inspect(start_error(reason))}")
        :ignore
      other ->
        other
    end
  end
  def init(opts) do
    if KeyStorageSync.use_ygg?() do
      ygg_opts = Keyword.merge(@ygg_opts, opts)
      children = [
        Supervisor.child_spec({Ygg.Embedded, ygg_opts},
          start: {__MODULE__, :start_node, [ygg_opts]}
        )
      ]
      Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
    else
      :ignore
    end
  end
  @doc false
  def start_node(ygg_opts) do
    await_unregistered(Keyword.get(ygg_opts, :name, Ygg.Node), 40)
    Ygg.Embedded.start_link(ygg_opts)
  end
  @doc false
  def watch_spec(),
    do: %{id: :ygg_watch, start: {__MODULE__, :start_watch, []}, restart: :temporary}
  @doc false
  def start_watch() do
    case Process.whereis(__MODULE__) do
      nil -> :ignore
      pid -> Task.start_link(fn -> watch(Process.monitor(pid)) end)
    end
  end
  defp watch(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, reason} ->
        Logger.error("[Ygg] Yggdrasil stopped until restart: #{inspect(reason)}")
    end
  end
  defp start_error({:shutdown, {:failed_to_start_child, _id, reason}}), do: reason
  defp start_error(reason), do: reason
  defp await_unregistered(_id, 0), do: :ok
  defp await_unregistered(id, n) do
    case Registry.select(Ygg.Registry, [{{{id, :_}, :_, :_}, [], [true]}]) do
      [] ->
        :ok
      _ ->
        Process.sleep(50)
        await_unregistered(id, n - 1)
    end
  end
end