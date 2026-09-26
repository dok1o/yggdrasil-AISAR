defmodule Ygg.Transport.TCP do
  @moduledoc """
  `tcp://` carrier over `:gen_tcp`. Ports `linkTCP.dial`/`listen` from
  `reference/yggdrasil-go/src/core/link_tcp.go`: dial timeout 5 s (link_tcp.go:64), TCP keepalive disabled
  (`KeepAlive: -1`, link_tcp.go:24,65 - ironwood keepalives replace it), no source-interface
  binding (`InterfacePeers` is not ported). Socket options come from `context/tcp_conn.ex`
  minus `linger: {true, 0}` (would RST instead of FIN on close) and `reuseaddr` on the
  client side; `send_timeout` is 10 s so a slow public peer does not get dropped spuriously.
  """
  @behaviour Ygg.Transport.Behaviour
  alias Ygg.Transport.Behaviour
  @dial_timeout 5_000
  @send_timeout 10_000
  @base_opts [
    :binary,
    packet: :raw,
    active: false,
    nodelay: true,
    keepalive: false,
    send_timeout: @send_timeout,
    send_timeout_close: true
  ]
  def dial_timeout, do: @dial_timeout
  @impl true
  def connect(ip, port, _opts, timeout),
    do: :gen_tcp.connect(ip, port, [Behaviour.family(ip) | @base_opts], timeout)
  @impl true
  def listen(ip, port),
    do: :gen_tcp.listen(port, [Behaviour.family(ip), {:ip, ip}, {:reuseaddr, true} | @base_opts])
  @impl true
  def accept(lsock, timeout), do: :gen_tcp.accept(lsock, timeout)
  @impl true
  def send(sock, data), do: :gen_tcp.send(sock, data)
  @impl true
  def setopts_active_once(sock), do: :inet.setopts(sock, active: :once)
  @impl true
  def controlling_process(sock, pid), do: :gen_tcp.controlling_process(sock, pid)
  @impl true
  def shutdown(sock), do: :gen_tcp.shutdown(sock, :read_write)
  @impl true
  def close(sock), do: :gen_tcp.close(sock)
  @impl true
  def peername(sock), do: :inet.peername(sock)
  @impl true
  def sockname(sock), do: :inet.sockname(sock)
  @impl true
  def tags, do: {:tcp, :tcp_closed, :tcp_error}
end