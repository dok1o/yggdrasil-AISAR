defmodule GUIEvents do
  require Logger
  def handle(%{"event" => "gui.system.start"} = _evt, local_socket) do
    Logger.info("GUI Start")
    reply(local_socket, "EVENT_ACK: gui.system.start")
  end
  def handle(%{"event" => "gui.system.exit"} = _evt, local_socket) do
    Logger.info("GUI Stop")
    GenS.GUIExit.shutdown(:gui_exit)
    reply(local_socket, "EVENT_ACK: gui.system.exit")
  end
  def handle(%{"event" => "gui.input.loadmagnets", "payload" => payload} = evt, local_socket) do
    Logger.info("[GUIEvent] Received magnet load request:\n#{inspect(evt, pretty: true)}")
    handle_loadmagnets(payload)
    reply(local_socket, "EVENT_ACK: gui.input.loadmagnets")
  end
  def handle(%{"event" => "gui.input.ping_x", "payload" => json_ip_str} = evt, local_socket) do
    Logger.info("[GUIEvent] Received ping_x request:\n#{inspect(evt, pretty: true)}")
    case :inet.parse_address(String.to_charlist(json_ip_str)) do
      {:ok, {a, b, c, d}} ->
        GenS.PFNodesProcessor.ping_request({a, b, c, d})
      {:error, reason} ->
        Logger.warning(
          "[GUIEvent] Invalid IPv4 payload: #{inspect(json_ip_str)} (#{inspect(reason)})"
        )
    end
    reply(local_socket, "EVENT_ACK: gui.input.ping_x")
  end
  def handle(%{"event" => "gui.ygg.scrape_peers", "payload" => payload}, local_socket)
      when is_map(payload) do
    region = Map.get(payload, "region", "europe")
    limit = Map.get(payload, "limit", 20)

    if is_binary(region) and String.match?(region, ~r/^[a-z0-9]+$/) and
         is_integer(limit) and limit in 1..200 do
      Task.start(fn ->
        case YggPF.WebPeers.fetch(region: region, limit: limit) do
          {:ok, peers} ->
            added =
              Enum.count(peers, fn peer ->
                add_ygg_peer(peer.uri)
              end)

            Logger.info("[YggPF.WebPeers] added #{added}/#{length(peers)} peers from #{region}")

          {:error, reason} ->
            Logger.warning("[YggPF.WebPeers] scrape failed: #{inspect(reason)}")
        end
      end)

      reply(local_socket, "EVENT_ACK: gui.ygg.scrape_peers")
    else
      Logger.warning("[YggPF.WebPeers] rejected invalid scrape request")
      reply(local_socket, "EVENT_ERROR: gui.ygg.scrape_peers")
    end
  end
  defp add_ygg_peer(uri) do
    case Ygg.add_peer(uri) do
      :ok -> true
      {:error, reason} ->
        Logger.warning("[YggPF.WebPeers] #{uri}: #{inspect(reason)}")
        false
    end
  rescue
    error ->
      Logger.warning("[YggPF.WebPeers] #{uri}: #{inspect(error)}")
      false
  catch
    :exit, reason ->
      Logger.warning("[YggPF.WebPeers] #{uri}: #{inspect(reason)}")
      false
  end
  defp handle_loadmagnets(payload) do
    case payload do
      path when is_binary(path) ->
        cond do
          String.starts_with?(path, "/") and String.ends_with?(path, ".torrent") ->
            handle_local_torrent(path)
          String.starts_with?(path, "magnet:") or
              (byte_size(path) == 40 and String.match?(path, ~r/^[0-9A-Za-z]+$/)) ->
            ih = Base.decode16!(String.upcase(path))
            GenS.SearchManager.user_input(ih)
            Logger.info("Loaded infohash: #{path}")
          true ->
            Logger.info("Ignoring unsupported string payload: #{inspect(path)}")
            :noop
        end
      items when is_list(items) ->
        Enum.each(items, &handle_loadmagnets/1)
      other ->
        Logger.info("Ignoring unrecognized loadmagnets payload: #{inspect(other)}")
        :noop
    end
  end
  defp handle_local_torrent(path) do
    case File.read(path) do
      {:ok, data} ->
        Logger.info("Loading local .torrent file: #{path}")
        case SimpleBencodeSync.decode(data) do
          {:ok, parsed} ->
            PrinterSync.pretty_print(:local, parsed)
          {:error, reason} ->
            Logger.warning("Could not decode #{path}: #{inspect(reason)}")
        end
      {:error, reason} ->
        Logger.error("Cannot read #{path}: #{inspect(reason)}")
    end
  end
  defp reply(local_socket, message) do
    :gen_tcp.send(local_socket, message <> "\n")
    :ok
  end
end