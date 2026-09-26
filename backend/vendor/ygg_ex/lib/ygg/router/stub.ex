defmodule Ygg.Router.Stub do
  @moduledoc """
  Stage-1 router (`router: :stub`): no spanning tree, nothing forwarded. `Ygg.Peer` answers
  SigReq itself and hands the frames it decodes to `frame/3`; Announce and BloomFilter are
  logged at debug level, as the stage-1 `Ygg.Router` did. Implements `Ygg.Router.Behaviour`
  with `{:error, :not_supported}` for traffic, lookups and dumps.
  """
  @behaviour Ygg.Router.Behaviour
  use GenServer
  require Logger
  alias Ygg.{Identity, Node}
  def start_link(ctx), do: GenServer.start_link(__MODULE__, ctx, name: Node.via(ctx, __MODULE__))
  @impl Ygg.Router.Behaviour
  def child_specs(ctx), do: [{__MODULE__, ctx}]
  @impl Ygg.Router.Behaviour
  def send(_ctx, _key, _payload), do: {:error, :not_supported}
  @impl Ygg.Router.Behaviour
  def lookup(_ctx, _key), do: {:error, :not_supported}
  @impl Ygg.Router.Behaviour
  def subscribe(_ctx, _pid), do: {:error, :not_supported}
  @impl Ygg.Router.Behaviour
  def unsubscribe(_ctx, _pid), do: :ok
  @impl Ygg.Router.Behaviour
  def routing(_ctx), do: nil
  @impl Ygg.Router.Behaviour
  def request_dump(_ctx), do: {:error, :not_supported}
  @impl Ygg.Router.Behaviour
  def stats(_ctx), do: {:error, :not_supported}
  @impl Ygg.Router.Behaviour
  def mtu(_ctx), do: 0
  @impl Ygg.Router.Behaviour
  def peer_up(ctx, pid, key, port, prio),
    do: GenServer.cast(Node.via(ctx, __MODULE__), {:peer_up, pid, key, port, prio})
  @impl Ygg.Router.Behaviour
  def frame(ctx, pid, frame), do: GenServer.cast(Node.via(ctx, __MODULE__), {:frame, pid, frame})
  @impl GenServer
  def init(_ctx), do: {:ok, %{}}
  @impl GenServer
  def handle_cast({:peer_up, _pid, key, port, prio}, st) do
    Logger.debug(fn -> "Peer up #{short(key)} port #{port} prio #{prio}" end)
    {:noreply, st}
  end
  def handle_cast({:frame, pid, {:announce, a}}, st) do
    Logger.debug(fn ->
      "Announce via #{inspect(pid)}: key=#{short(a.key)} parent=#{short(a.parent)} seq=#{a.seq} port=#{a.port}"
    end)
    {:noreply, st}
  end
  def handle_cast({:frame, pid, {:bloom, size}}, st) do
    Logger.debug(fn -> "BloomFilter via #{inspect(pid)}: #{inspect(size)}" end)
    {:noreply, st}
  end
  def handle_cast({:frame, _pid, _frame}, st), do: {:noreply, st}
  defp short(key), do: key |> Identity.pub_hex() |> binary_part(0, 8)
end