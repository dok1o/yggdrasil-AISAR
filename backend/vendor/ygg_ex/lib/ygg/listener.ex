defmodule Ygg.Listener do
  @moduledoc """
  `tcp://host:port` listener. Ports `links.listen` (`reference/yggdrasil-go/src/core/link.go:446-594`) and
  `linkTCP.listen` (link_tcp.go:44-52): accept loop, a link entry keyed by
  `scheme://remote_ip:port` for every accepted socket (link.go:521-527), duplicates dropped
  (link.go:544-548). The accepted socket is handed to a `Ygg.Link` of type `:incoming`
  (`controlling_process`, then `Ygg.Link.adopt/1`), which runs the handshake and owns the
  connection. Only `tcp://` at stage 1; `tls://` listen needs a certificate (deferred).
  `?priority=` on the listen URI is honoured (link.go:484-491), `?password=` is not
  (no keyed BLAKE2b, see `Ygg.Meta`).
  """
  use GenServer
  require Logger
  alias Ygg.{Links, Node, PeerURI}
  alias Ygg.Transport.TCP
  def start_link({ctx, uri}),
    do: GenServer.start_link(__MODULE__, {ctx, uri}, name: Node.via(ctx, {__MODULE__, uri}))
  @spec addr(pid()) :: {:inet.ip_address(), :inet.port_number()} | nil
  def addr(pid) do
    GenServer.call(pid, :addr)
  catch
    :exit, _ -> nil
  end
  @impl true
  def init({ctx, uri}) do
    Process.flag(:trap_exit, true)
    with {:ok, %PeerURI{scheme: :tcp} = p} <- parse(uri),
         {:ok, ip} <- listen_ip(p.host),
         {:ok, lsock} <- TCP.listen(ip, p.port),
         {:ok, {_, port}} <- :inet.sockname(lsock) do
      Logger.info("TCP listener started on #{PeerURI.info_uri(:tcp, host_str(ip), port)}")
      acceptor = spawn_link(fn -> accept_loop(ctx, lsock, p.priority) end)
      {:ok, %{ctx: ctx, uri: uri, lsock: lsock, ip: ip, port: port, acceptor: acceptor}}
    else
      {:ok, %PeerURI{scheme: other}} -> {:stop, {:listen_scheme_unsupported, other}}
      {:error, reason} -> {:stop, {:listen_failed, uri, reason}}
    end
  end
  @impl true
  def handle_call(:addr, _from, %{ip: ip, port: port} = st), do: {:reply, {ip, port}, st}
  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = st),
    do: {:stop, {:acceptor_died, reason}, st}
  def handle_info(_msg, st), do: {:noreply, st}
  @impl true
  def terminate(_reason, %{lsock: lsock, ip: ip, port: port}) do
    :gen_tcp.close(lsock)
    Logger.info("TCP listener stopped on #{PeerURI.info_uri(:tcp, host_str(ip), port)}")
    :ok
  end
  defp accept_loop(ctx, lsock, priority) do
    case TCP.accept(lsock, :infinity) do
      {:ok, sock} ->
        handoff(ctx, sock, priority)
        accept_loop(ctx, lsock, priority)
      {:error, :closed} ->
        :ok
      {:error, reason} ->
        Logger.warning("Accept error: #{inspect(reason)}")
        Process.sleep(100)
        accept_loop(ctx, lsock, priority)
    end
  end
  defp handoff(ctx, sock, priority) do
    with {:ok, {ip, port}} <- :inet.peername(sock),
         info = PeerURI.incoming_info_uri(:tcp, ip, port),
         spec = %{sock: sock, mod: TCP, info_uri: info, priority: priority, scheme: :tcp},
         {:ok, link} <- Links.add_incoming(ctx, spec),
         :ok <- TCP.controlling_process(sock, link) do
      Ygg.Link.adopt(link)
    else
      {:error, reason} ->
        Logger.debug("Dropping accepted socket: #{inspect(reason)}")
        TCP.close(sock)
    end
  end
  defp parse(uri) do
    case PeerURI.parse(uri) do
      {:ok, p} -> {:ok, p}
      {:error, :invalid_host} -> {:error, :invalid_host}
      {:error, r} -> {:error, r}
    end
  end
  defp listen_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      _ -> :inet.getaddr(String.to_charlist(host), :inet)
    end
  end
  defp host_str(ip), do: ip |> :inet.ntoa() |> List.to_string()
end