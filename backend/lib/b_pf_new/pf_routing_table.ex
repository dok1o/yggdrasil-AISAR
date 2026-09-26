defmodule GenS.PFRoutingTable do
  use GenServer
  require Logger
  import MagnetSorter.Const
  import TimeSync
  def start_link(o \\ []), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  @compile {:inline, []}
  @type target :: <<_::160>>
  @type frid :: target()
  @type nodev4 :: <<_::48>>
  @type fn4 :: nodev4()
  @ets_tables %{
    fnodes: %{name: :fnodes, type: :set},
    fnodes_rev: %{name: :fnodes_rev, type: :set},
    pf_inbox: %{name: :pf_inbox, type: :set}
  }
  for {key, %{name: name}} <- @ets_tables do
    Module.put_attribute(__MODULE__, :"ets_#{key}", name)
  end
  @sets for {_k, v} <- @ets_tables, v.type == :set, do: v.name
  @max_pf_nodes_size 1
  def full?(), do: TryETS.size(@ets_fnodes) >= @max_pf_nodes_size
  defp init_await(), do: Process.sleep(sleep_ms())
  def init(_opts) do
    TryETS.create_many_named(@sets, :set, :public, true, true)
    st = %{start_ms: mono_ms()}
    {:ok, st, {:continue, :genserver_pf_bootstrap_await}}
  end
  def handle_continue(:genserver_pf_bootstrap_await, %{start_ms: start_ms} = st) do
    case full?() do
      false ->
        init_await()
        {:noreply, st, {:continue, :genserver_pf_bootstrap_await}}
      true ->
        KeyStorageSync.set_pf_rt_filled()
        log_bootstrap(start_ms)
        {:noreply, st}
    end
  end
  defp count_addrs(nodes) do
    addrs =
      nodes
      |> Enum.map(fn {_rid, nodev4} -> nodev4 end)
      |> Enum.uniq()
    subnets =
      addrs
      |> Enum.map(fn <<subnet_pr::binary-2, _rest::binary>> -> subnet_pr end)
      |> Enum.uniq()
    {length(addrs), length(subnets)}
  end
  defp log_bootstrap(start_ms) do
    nodes = TryETS.tab2list(@ets_fnodes_rev)
    {ip_cnt, subnet_cnt} = count_addrs(nodes)
    elapsed_s = div(mono_ms() - start_ms, 1_000)
    Logger.info(
      "[DHT] Routing Table populated in #{elapsed_s} seconds with #{ip_cnt} IPs of #{subnet_cnt} /16 subnets, PF RT max size: #{@max_pf_nodes_size}"
    )
  end
end