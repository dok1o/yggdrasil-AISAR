defmodule UnpackSync do
  @dht_bytes 20
  @dht_bits 160
  @nodev4_bytes 6
  def nodes(nodes_bin), do: unpack_and_filter_nodes(nodes_bin)
  def peers(bin_or_list), do: unpack_and_filter_peers(bin_or_list)
  def samples(bin_or_list), do: unpack_and_filter_samples(bin_or_list)
  def fnodes(fnodes_bin), do: unpack_and_filter_nodes(fnodes_bin)
  def saddrs(saddrs_bin), do: unpack_and_filter_peers(saddrs_bin)
  defp unpack_and_filter_nodes(nodes_bin) when is_binary(nodes_bin) do
    unpack_fast(nodes_bin, [])
  end
  defp unpack_and_filter_nodes(_not_bin), do: []
  defp unpack_fast(<<0::size(@dht_bits), _nodev4::binary-@nodev4_bytes, rest::binary>>, acc) do
    unpack_fast(rest, acc)
  end
  defp unpack_fast(<<rid::binary-@dht_bytes, nodev4::binary-@nodev4_bytes, rest::binary>>, acc) do
    case UAddrChkSync.good?(nodev4) do
      false -> unpack_fast(rest, acc)
      true -> unpack_fast(rest, [{rid, nodev4} | acc])
    end
  end
  defp unpack_fast(_no_good_left, acc), do: acc
  defp unpack_and_filter_peers(values) when is_list(values) do
    for peer <- values,
        is_binary(peer),
        byte_size(peer) == @nodev4_bytes,
        UAddrChkSync.good?(peer),
        do: peer
  end
  defp unpack_and_filter_peers(peers_bin)
       when is_binary(peers_bin) and byte_size(peers_bin) >= @nodev4_bytes do
    for <<peer::binary-@nodev4_bytes <- peers_bin>>,
        UAddrChkSync.good?(peer),
        do: peer
  end
  defp unpack_and_filter_peers(_no_good_left), do: []
  defp unpack_and_filter_samples(samples_bin) when is_binary(samples_bin) do
    for <<s_ih::binary-@dht_bytes <- samples_bin>>, WireSync.ihv?(s_ih), do: s_ih
  end
  defp unpack_and_filter_samples(s_list) when is_list(s_list) do
    for s_ih <- s_list, WireSync.ihv?(s_ih), do: s_ih
  end
  defp unpack_and_filter_samples(_no_good_left), do: []
end