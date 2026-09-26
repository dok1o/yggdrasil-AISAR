defmodule PrinterSync do
  require Logger
  def short_hex(<<pr::binary-8, _rest::binary>>), do: Base.encode16(pr, case: :lower)
  def full_hex(ihv), do: Base.encode16(ihv, case: :lower)
  def peer(<<a, b, c, d, port::16>>), do: "#{a}.#{b}.#{c}.#{d}:#{port}"
  def ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  def subnet({a, b, c}), do: "#{a}.#{b}.#{c}.0/24"
  def peer_tuple({a, b, c, d}, port), do: "#{a}.#{b}.#{c}.#{d}:#{port}"
  def pretty_print(ih, md_payload) do
    case SimpleBencodeSync.decode(md_payload) do
      {:ok, info_dict} ->
        do_pretty_print(ih, info_dict)
      {:error, reason} ->
        Logger.error("[Printer] Failed to decode metadata: #{inspect(reason)}")
        {:error, :decode_failed}
    end
  end
  defp do_pretty_print(ih, info) when is_map(info) do
    name = Map.get(info, "name", "(unnamed)")
    files = Map.get(info, "files")
    ih_hex = if is_binary(ih), do: Base.encode16(ih), else: inspect(ih)
    IO.puts(["\n—— Torrent: ", name, " (", ih_hex, ") ——"])
    cond do
      is_list(files) ->
        print_multifile(files)
      Map.has_key?(info, "length") ->
        size = human_bytes(Map.get(info, "length"))
        IO.puts("  Single file: #{name}  (#{size})")
      true ->
        IO.puts("[Printer] Unrecognized torrent structure")
    end
    :ok
  end
  defp do_pretty_print(_ih, _other) do
    Logger.warning("Decoded metadata is not a map")
    {:error, :invalid_structure}
  end
  defp print_multifile(files) when is_list(files) do
    files
    |> Enum.take(3)
    |> Enum.with_index(1)
    |> Enum.each(fn {entry, idx} ->
      path = Enum.join(Map.get(entry, "path", []), "/")
      length = Map.get(entry, "length", 0)
      IO.puts("  #{idx}. #{path} (#{human_bytes(length)})")
    end)
    total_files = length(files)
    IO.puts("  …and #{max(total_files - 3, 0)} more files")
  end
  defp human_bytes(n) when is_integer(n) and n > 0 do
    units = ["B", "KB", "MB", "GB", "TB"]
    exp = trunc(min(:math.floor(:math.log(n) / :math.log(1024)), length(units) - 1))
    val = n / :math.pow(1024, exp)
    :io_lib.format("~.2f ~s", [val, Enum.at(units, exp)])
    |> IO.iodata_to_binary()
  end
  defp human_bytes(_), do: "0 B"
end