import Bitwise

[target_str | rest] = System.argv()
count = case rest do [c | _] -> String.to_integer(c); _ -> 4 end

{:ok, node_name} =
  case :erl_epmd.names() do
    {:ok, names} ->
      case Enum.find(names, fn {n, _} -> String.starts_with?(to_string(n), "magnet_sorter_") end) do
        {n, _} -> {:ok, String.to_atom("#{n}@127.0.0.1")}
        nil -> {:error, :no_node}
      end
  end

true = Node.connect(node_name)
IO.puts("connected to #{node_name}")
rpc = fn m, f, a -> :erpc.call(node_name, m, f, a, 30_000) end

{:ok, t} = :inet.parse_ipv6strict_address(String.to_charlist(target_str))
target = t |> Tuple.to_list() |> Enum.map(&<<&1::16>>) |> IO.iodata_to_binary()

self = rpc.(Ygg, :self_info, [])
{:ok, s} = :inet.parse_ipv6strict_address(String.to_charlist(self.address))
my_addr = s |> Tuple.to_list() |> Enum.map(&<<&1::16>>) |> IO.iodata_to_binary()
IO.puts("self #{self.address}")

matches? = fn hex ->
  {:ok, raw} = Base.decode16(hex, case: :mixed)
  rpc.(Ygg.Address, :addr_for_key, [raw]) == target
end

find_known = fn ->
  r = rpc.(Ygg, :routing, [])
  keys =
    Enum.map(r["paths"] || [], & &1["key"]) ++
      Enum.map(r["tree"] || [], &(&1["key"] || "")) ++
      Enum.map(r["peers"] || [], &(&1["key"] || ""))
  keys |> Enum.filter(&(byte_size(&1) == 64)) |> Enum.uniq() |> Enum.find(matches?)
end

partial = rpc.(Ygg.Address, :addr_get_key, [target])
IO.puts("partial key #{Base.encode16(partial, case: :lower)}")

t0 = System.monotonic_time(:millisecond)

full =
  find_known.() ||
    Enum.reduce_while(1..40, nil, fn i, _ ->
      if rem(i, 6) == 1, do: rpc.(Ygg, :lookup, [partial])
      Process.sleep(500)
      case find_known.() do
        nil -> {:cont, nil}
        k -> {:halt, k}
      end
    end)

case full do
  nil ->
    IO.puts("LOOKUP FAILED: no path to #{target_str} after #{System.monotonic_time(:millisecond) - t0} ms")
    System.halt(2)

  k ->
    IO.puts("full key #{k} (lookup #{System.monotonic_time(:millisecond) - t0} ms)")
end

{:ok, full_raw} = Base.decode16(full, case: :lower)

Process.sleep(200)

sum16 = fn bin ->
  bin = if rem(byte_size(bin), 2) == 1, do: bin <> <<0>>, else: bin
  s = for <<w::16 <- bin>>, reduce: 0, do: (acc -> acc + w)
  s = (s &&& 0xFFFF) + (s >>> 16)
  s = (s &&& 0xFFFF) + (s >>> 16)
  bnot(s) &&& 0xFFFF
end

id = :rand.uniform(0xFFFF)
data = :binary.copy(<<0xAB>>, 56)
log = Path.expand("../../data/logs/ygg.log")
short = binary_part(full, 0, 8)
utc_off = :calendar.datetime_to_gregorian_seconds(:calendar.local_time()) - :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())

log_ms = fn line ->
  {:ok, nd} = NaiveDateTime.from_iso8601(String.slice(line, 0, 23))
  DateTime.from_naive!(nd, "Etc/UTC") |> DateTime.to_unix(:millisecond) |> Kernel.-(utc_off * 1000)
end

IO.puts("\nPING #{target_str} (key #{short}...) 56 bytes of data, #{count} packets\n")

results =
  for seq <- 1..count do
    body0 = <<128, 0, 0::16, id::16, seq::16, data::binary>>
    plen = byte_size(body0)
    csum = sum16.(<<my_addr::binary, target::binary, plen::32, 0::24, 58, body0::binary>>)
    <<h::binary-size(2), _::16, tl::binary>> = body0
    body = <<h::binary, csum::16, tl::binary>>
    pkt = <<6::4, 0::8, 0::20, plen::16, 58, 64, my_addr::binary, target::binary, body::binary>>
    %{size: pos} = File.stat!(log)
    sent = System.system_time(:millisecond)
    :ok = rpc.(Ygg, :send_traffic, [full_raw, <<1, pkt::binary>>])

    rtt =
      Enum.reduce_while(1..30, nil, fn _, _ ->
        Process.sleep(100)
        {:ok, f} = File.open(log, [:read, :binary])
        {:ok, _} = :file.position(f, pos)
        chunk = IO.binread(f, :eof)
        File.close(f)
        chunk = if is_binary(chunk), do: chunk, else: ""
        case chunk |> String.split("\n") |> Enum.find(&(String.contains?(&1, "from " <> short) and String.contains?(&1, "{:icmpv6, 129, 0}"))) do
          nil -> {:cont, nil}
          line -> {:halt, log_ms.(line) - sent}
        end
      end)

    if rtt,
      do: IO.puts("reply from #{target_str}: seq=#{seq} time=#{rtt} ms"),
      else: IO.puts("seq=#{seq}: no reply within 3 s")

    Process.sleep(max(0, 1000 - (System.system_time(:millisecond) - sent)))
    rtt
  end

ok = Enum.reject(results, &is_nil/1)
IO.puts("\n--- #{target_str} ping statistics ---")
IO.puts("#{count} packets transmitted, #{length(ok)} received, #{round((count - length(ok)) * 100 / count)}% packet loss")
if ok != [], do: IO.puts("rtt min/avg/max = #{Enum.min(ok)}/#{round(Enum.sum(ok) / length(ok))}/#{Enum.max(ok)} ms")

case rpc.(Ygg, :node_info, [full_raw, Ygg.Node, 8_000]) do
  {:ok, info} -> IO.puts("nodeinfo: #{inspect(info)}")
  other -> IO.puts("nodeinfo: #{inspect(other)}")
end
