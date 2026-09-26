defmodule GenS.ExtSaver do
  use GenServer
  require Logger
  @date Calendar.strftime(Date.utc_today(), "%Y%m%d")
  @journals_dir "../data/journals"
  @torr_dir "../data/torrents"
  @ext_file "../data/journals/ut_ext_journal_#{@date}.jsonl"
  @queue_warn 50
  @flush_interval 50
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def save_utm(ih, md_payload), do: GenServer.cast(__MODULE__, {:save_utm, ih, md_payload})
  def save_ext(peer, ih, mse?, ext_map, utm_status_atom),
    do: GenServer.cast(__MODULE__, {:save_ext, peer, ih, mse?, ext_map, utm_status_atom})
  def init(_opts) do
    File.mkdir_p!(@journals_dir)
    {:ok, _} = :timer.send_interval(@flush_interval, :flush)
    {:ok,
     %{
       utm_file: nil,
       ext_file: open_file(@ext_file),
       utm_buf: [],
       ext_buf: []
     }}
  end
  def handle_cast({:save_utm, ih, md_payload}, st) do
    write_torrent(ih, md_payload)
    {:noreply, %{st | utm_buf: [ih | st.utm_buf]}}
  end
  def handle_cast({:save_ext, peer, ih, mse?, ext_map, status}, st) do
    entry = build_entry(peer, ih, mse?, ext_map, status)
    GenS.Metrics.increment(:peer_ext)
    {:noreply, %{st | ext_buf: [entry | st.ext_buf]}}
  end
  def handle_info(:flush, st) do
    check_queue()
    {:noreply, flush(st)}
  end
  defp flush(%{utm_buf: [], ext_buf: []} = st), do: st
  defp flush(st), do: st |> flush_utm() |> flush_ext()
  defp flush_utm(%{utm_file: nil} = st), do: %{st | utm_buf: []}
  defp flush_utm(%{utm_buf: []} = st), do: st
  defp flush_utm(%{utm_file: f, utm_buf: buf} = st) do
    iodata = Enum.map(buf, &[Base.encode16(&1, case: :lower), ?\n])
    IO.write(f, Enum.reverse(iodata))
    %{st | utm_buf: []}
  end
  defp flush_ext(%{ext_file: nil} = st), do: %{st | ext_buf: []}
  defp flush_ext(%{ext_buf: []} = st), do: st
  defp flush_ext(%{ext_file: f, ext_buf: buf} = st) do
    iodata =
      Enum.reduce(buf, [], fn entry, acc ->
        case Jason.encode(entry) do
          {:ok, json} -> [[json, ?\n] | acc]
          {:error, _reason} -> acc
        end
      end)
    if iodata != [], do: IO.write(f, iodata)
    %{st | ext_buf: []}
  end
  defp build_entry(peer, ih, mse?, ext_map, status) do
    peer_str =
      case peer do
        <<_::48>> -> PrinterSync.peer(peer)
        _ -> inspect(peer)
      end
    utm_status =
      case status do
        :utm_dwld -> "OK"
        :utm_not_dwld -> "no"
      end
    ext_map
    |> flatten_map()
    |> Map.merge(%{
      "peer" => peer_str,
      "ih" => Base.encode16(ih, case: :lower),
      "mse" => mse?,
      "utm" => utm_status
    })
  end
  defp flatten_map(ext_map) do
    {m_map, rest} = Map.pop(ext_map, "m", %{})
    m_flat =
      if is_map(m_map),
        do: Map.new(m_map, fn {k, v} -> {"m.#{k}", format_val(v)} end),
        else: %{}
    rest
    |> Map.drop(["yourip", "ipv4", "ipv6", "tr"])
    |> Map.new(fn {k, v} -> {k, format_val(v)} end)
    |> Map.merge(m_flat)
  end
  defp format_val(v) when is_binary(v) do
    if String.printable?(v), do: v, else: "0x" <> Base.encode16(v, case: :lower)
  end
  defp format_val(v) when is_integer(v), do: v
  defp format_val(v) when is_boolean(v), do: v
  defp format_val(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp format_val(nil), do: nil
  defp format_val(v), do: inspect(v)
  defp open_file(path) do
    case File.open(path, [:append, :utf8, :delayed_write]) do
      {:ok, f} ->
        f
      {:error, reason} ->
        Logger.debug("[ExtSaver] Failed to open #{path}: #{inspect(reason)}")
        nil
    end
  end
  defp check_queue do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    if len >= @queue_warn, do: Logger.warning("[ExtSaver] Queue: #{len}")
  end
  defp write_torrent(ih, md_payload) do
    case SimpleBencodeSync.decode(md_payload) do
      {:ok, info} ->
        data = SimpleBencodeSync.encode(%{"info" => info})
        path = Path.join(@torr_dir, Base.encode16(ih, case: :lower) <> ".torrent")
        File.write(path, data)
      {:error, reason} ->
        Logger.error("[ExtSaver] Bencode error: #{inspect(reason)}")
    end
  end
  def terminate(_reason, st) do
    try do
      flush(st)
    rescue
      e -> Logger.error("ExtSaver failed to flush during terminate: #{inspect(e)}")
    after
      if is_map(st) do
        if st[:utm_file], do: File.close(st.utm_file)
        if st[:ext_file], do: File.close(st.ext_file)
      end
    end
    :ok
  end
end