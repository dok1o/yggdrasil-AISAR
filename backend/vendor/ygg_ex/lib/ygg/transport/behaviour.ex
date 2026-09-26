defmodule Ygg.Transport.Behaviour do
  @moduledoc """
  Socket-level contract a link carrier must implement (`linkProtocol` in
  `reference/yggdrasil-go/src/core/link.go:48-51`: `dial` and `listen`), plus the few socket operations
  `Ygg.Transport.Conn` needs so that it can own a `:gen_tcp` or an `:ssl` socket without
  knowing which. Shaped after `Transport.Behaviour` in `context/all_transports.ex`.
  Only `Ygg.Transport.TCP` and `Ygg.Transport.TLS` exist; QUIC/WS/SOCKS/UNIX are not ported.
  """
  @type sock :: term()
  @type tags :: {data :: atom(), closed :: atom(), error :: atom()}
  @callback connect(:inet.ip_address(), :inet.port_number(), keyword(), timeout()) ::
              {:ok, sock()} | {:error, term()}
  @callback listen(:inet.ip_address(), :inet.port_number()) :: {:ok, sock()} | {:error, term()}
  @callback accept(sock(), timeout()) :: {:ok, sock()} | {:error, term()}
  @callback send(sock(), iodata()) :: :ok | {:error, term()}
  @callback setopts_active_once(sock()) :: :ok | {:error, term()}
  @callback controlling_process(sock(), pid()) :: :ok | {:error, term()}
  @callback shutdown(sock()) :: :ok | {:error, term()}
  @callback close(sock()) :: :ok
  @callback peername(sock()) ::
              {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  @callback sockname(sock()) ::
              {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  @callback tags() :: tags()
  @doc "Socket option selecting the address family for an IP tuple."
  @spec family(:inet.ip_address()) :: :inet | :inet6
  def family({_, _, _, _}), do: :inet
  def family({_, _, _, _, _, _, _, _}), do: :inet6
end