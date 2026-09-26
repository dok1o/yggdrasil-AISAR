defmodule GenS.GUIServer do
  use GenServer
  require Logger
  @port 4040
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def send_event(json_line) when is_binary(json_line) do
    GenServer.cast(__MODULE__, {:send, json_line})
  end
  def init(_opts) do
    case :gen_tcp.listen(@port, [:binary, packet: :line, active: false, reuseaddr: true]) do
      {:ok, listen_socket} ->
        Task.start_link(fn -> loop_acceptor(listen_socket) end)
        st = %{l_socket: nil}
        {:ok, st}
      {:error, reason} ->
        Logger.error("[Backend] Could not listen on local socket: #{inspect(reason)}")
        Stop.app_stop(reason)
    end
  end
  def handle_cast({:send, msg}, %{l_socket: l_socket} = st) when is_port(l_socket) do
    :gen_tcp.send(l_socket, msg <> "\n")
    {:noreply, st}
  end
  def handle_cast({:send, _msg}, st), do: {:noreply, st}
  def handle_info({:set_socket, socket}, st) do
    :inet.setopts(socket, active: true)
    :gen_tcp.send(socket, "Open the gates!\n")
    {:noreply, %{st | l_socket: socket}}
  end
  def handle_info({:tcp, l_socket, data}, %{l_socket: l_socket} = st) do
    case Jason.decode(String.trim(data)) do
      {:ok, json_map} -> GUIEvents.handle(json_map, l_socket)
      {:error, _reason} -> Logger.info("Received non-JSON message: #{inspect(data)}")
    end
    {:noreply, st}
  end
  def handle_info(_msg, st), do: {:noreply, st}
  defp loop_acceptor(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        :gen_tcp.controlling_process(client_socket, Process.whereis(__MODULE__))
        send(GenS.GUIServer, {:set_socket, client_socket})
      {:error, _reason} ->
        loop_acceptor(listen_socket)
    end
  end
end