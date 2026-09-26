defmodule Ygg.AddressFile do
  @moduledoc """
  Writes the node's Yggdrasil address, derived from its key (`Ygg.Address.addr_for_key/1`,
  `reference/yggdrasil-go/src/address/address.go`), to a text file as one line `<ipv6> <port> <public_key_hex>`:
  the IPv6 in the `200::/7` range, the TCP port of the first bound listener (`Listen` in
  `ygg.json`, `0` when the node does not listen) and the ed25519 public key as 64 lowercase
  hex chars (appended last so readers that take the first two fields keep working; the
  private key never goes here). File name from `AddressFile` (default
  `ygg_address.txt`). Started as the last child of `Ygg.Node`, after the listeners, so the
  port is known; rewritten on every start.
  """
  use GenServer
  require Logger
  alias Ygg.{Address, Identity, Node}
  def start_link(ctx), do: GenServer.start_link(__MODULE__, ctx, name: Node.via(ctx, __MODULE__))
  @impl true
  def init(%Node{address_file: path} = ctx) do
    case write(path, ctx) do
      {:ok, line} -> Logger.info("Address file #{path}: #{String.trim(line)}")
      {:error, reason} -> Logger.warning("Cannot write address file #{path}: #{inspect(reason)}")
    end
    {:ok, ctx}
  end
  @doc "The file content for an identity and port."
  @spec content(Identity.t(), :inet.port_number()) :: String.t()
  def content(%Identity{address: addr} = id, port),
    do: "#{Address.format(addr)} #{port} #{Identity.pub_hex(id)}\n"
  @doc "Port of the first bound listener of the node, 0 without listeners."
  @spec listen_port(Node.t()) :: :inet.port_number()
  def listen_port(ctx) do
    case Node.listen_addrs(ctx) do
      [{_uri, {_ip, port}} | _] -> port
      [] -> 0
    end
  end
  @spec write(Path.t(), Node.t()) :: {:ok, String.t()} | {:error, term()}
  def write(path, %Node{identity: id} = ctx) do
    line = content(id, listen_port(ctx))
    with :ok <- File.mkdir_p(Path.dirname(Path.expand(path))),
         :ok <- File.write(path, line) do
      {:ok, line}
    end
  end
end