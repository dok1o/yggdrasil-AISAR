defmodule Ygg.Application do
  @moduledoc """
  OTP application entry point. Ports the node bootstrap of `reference/yggdrasil-go/_other/cmd/yggdrasil/main.go`
  in a reduced form: read `ygg.json` (`Ygg.Config`), load or create the key
  (`Ygg.Identity`), print key/address/subnet, start the default `Ygg.Node` instance named
  `Ygg.Node`. With `config :ygg_ex, autostart: false` (tests) only `Ygg.Registry` starts and
  nodes are started by hand, or by a host application through `Ygg.Embedded`.
  """
  use Application
  require Logger
  alias Ygg.{Config, Embedded, Node}
  @impl true
  def start(_type, _args) do
    children = [{Registry, keys: :unique, name: Node.registry()} | node_children()]
    Supervisor.start_link(children, strategy: :one_for_one, name: Ygg.Supervisor)
  end
  defp node_children do
    if Application.get_env(:ygg_ex, :autostart, true) do
      path = Application.get_env(:ygg_ex, :config_file, "ygg.json")
      with {:ok, cfg} <- Config.load(path),
           {:ok, opts} <- Embedded.prepare(cfg, name: Node, log_filter: :all) do
        [{Node, opts}]
      else
        {:error, reason} ->
          Logger.error("Cannot start node: #{inspect(reason)}")
          []
      end
    else
      []
    end
  end
end