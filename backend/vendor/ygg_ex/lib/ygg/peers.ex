defmodule Ygg.Peers do
  @moduledoc """
  Local port numbers for remote nodes, needed to answer SigReq (PROMPT_ELIXIR_PORT.md §5:
  "the port *we* assigned to this peer, numbered from 1, one port per public key").
  Mirrors the port bookkeeping of ironwood's `peers` actor (its sources are not in the repo);
  a key keeps its port while at least one link to it is up (reference counted, Go allows
  several links per key, `link.go` never dedups by key), the lowest free port is reused.
  Port 0 is never handed out: in the tree protocol `port == 0` marks the root's own parent
  slot (PROMPT §"Правила работы"), kept as is.
  """
  use GenServer
  alias Ygg.Node
  @compile {:inline, [acquire: 2, release: 2]}
  def start_link(ctx), do: GenServer.start_link(__MODULE__, ctx, name: Node.via(ctx, __MODULE__))
  @spec acquire(Node.t(), <<_::256>>) :: pos_integer()
  def acquire(ctx, key), do: GenServer.call(Node.via(ctx, __MODULE__), {:acquire, key})
  @spec release(Node.t(), <<_::256>>) :: :ok
  def release(ctx, key), do: GenServer.cast(Node.via(ctx, __MODULE__), {:release, key})
  @spec list(Node.t()) :: %{<<_::256>> => pos_integer()}
  def list(ctx), do: GenServer.call(Node.via(ctx, __MODULE__), :list)
  @impl true
  def init(_ctx), do: {:ok, %{ports: %{}, used: MapSet.new()}}
  @impl true
  def handle_call({:acquire, key}, _from, %{ports: ports, used: used} = st) do
    case Map.get(ports, key) do
      {port, n} ->
        {:reply, port, %{st | ports: Map.put(ports, key, {port, n + 1})}}
      nil ->
        port = lowest_free(used, 1)
        {:reply, port,
         %{st | ports: Map.put(ports, key, {port, 1}), used: MapSet.put(used, port)}}
    end
  end
  def handle_call(:list, _from, %{ports: ports} = st),
    do: {:reply, Map.new(ports, fn {k, {p, _}} -> {k, p} end), st}
  @impl true
  def handle_cast({:release, key}, %{ports: ports, used: used} = st) do
    case Map.get(ports, key) do
      {_port, n} when n > 1 ->
        {:noreply, %{st | ports: Map.update!(ports, key, fn {p, n} -> {p, n - 1} end)}}
      {port, 1} ->
        {:noreply, %{st | ports: Map.delete(ports, key), used: MapSet.delete(used, port)}}
      nil ->
        {:noreply, st}
    end
  end
  defp lowest_free(used, n),
    do: if(MapSet.member?(used, n), do: lowest_free(used, n + 1), else: n)
end