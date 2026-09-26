defmodule Ygg.Transport.TLS do
  @moduledoc """
  `tls://` carrier over `:ssl`. Ports `linkTLS.dial` (`reference/yggdrasil-go/src/core/link_tls.go:34-57`) and the
  client side of `generateTLSConfig` (`reference/yggdrasil-go/src/core/tls.go:8-21`): certificates are never
  verified (`verify: :verify_none`, identity comes from the `meta` handshake), TLS 1.2 or 1.3
  for dialing (link_tls.go:38-39), SNI = URI host or `?sni=` and none for IP literals
  (`Ygg.PeerURI` decides, `opts[:sni]` here). `:ssl.connect/4`'s timeout covers TCP connect
  plus handshake like Go's `tls.Dialer` with a 5 s `net.Dialer`.
  `listen/2` is not implemented at stage 1: it needs a self-signed ed25519 certificate
  (config.go:159-202) and TLS 1.3 only (tls.go:18).
  """
  @behaviour Ygg.Transport.Behaviour
  alias Ygg.Transport.Behaviour
  @send_timeout 10_000
  @base_opts [
    mode: :binary,
    packet: :raw,
    active: false,
    nodelay: true,
    keepalive: false,
    send_timeout: @send_timeout,
    send_timeout_close: true,
    verify: :verify_none,
    versions: [:"tlsv1.2", :"tlsv1.3"],
    log_level: :error
  ]
  @impl true
  def connect(ip, port, opts, timeout) do
    sni =
      case Keyword.get(opts, :sni) do
        nil -> :disable
        host when is_binary(host) -> String.to_charlist(host)
        host when is_list(host) -> host
      end
    ssl_opts = [Behaviour.family(ip), {:server_name_indication, sni} | @base_opts]
    :ssl.connect(ip, port, ssl_opts, timeout)
  end
  @impl true
  def listen(_ip, _port), do: {:error, :tls_listen_not_supported}
  @impl true
  def accept(_lsock, _timeout), do: {:error, :tls_listen_not_supported}
  @impl true
  def send(sock, data), do: :ssl.send(sock, data)
  @impl true
  def setopts_active_once(sock), do: :ssl.setopts(sock, active: :once)
  @impl true
  def controlling_process(sock, pid), do: :ssl.controlling_process(sock, pid)
  @impl true
  def shutdown(sock), do: :ssl.shutdown(sock, :read_write)
  @impl true
  def close(sock), do: :ssl.close(sock)
  @impl true
  def peername(sock), do: :ssl.peername(sock)
  @impl true
  def sockname(sock), do: :ssl.sockname(sock)
  @impl true
  def tags, do: {:ssl, :ssl_closed, :ssl_error}
end