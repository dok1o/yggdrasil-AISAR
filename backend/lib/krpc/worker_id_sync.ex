defmodule WorkerIDSync do
  import Bitwise
  import MagnetSorter.Const
  @min_dist_bits 4
  @max_dist_bits 8
  @ets_worker_ids :ids_prefixes
  @zero_pads_tuple List.to_tuple(for i <- 0..20, do: :binary.copy(<<0>>, i))
  def create_work_id(target_ih) do
    work_id = gen_proximity_id(target_ih)
    GenS.IdStorage.update_lookup(work_id, target_ih)
    work_id
  end
  def select_work_id_for_nodev4(<<ipv4::32, _port::16>>) do
    prefix = prefix_from_ipv4(ipv4)
    get_id_by_prefix(prefix)
  end
  def select_work_id_for_target(<<ihv::binary-dht_bytes()>>) do
    prefix = prefix_from_binary(ihv)
    get_id_by_prefix(prefix)
  end
  def prefix_from_binary(<<prefix::size(worker_ids_lookup_bits()), _rest::bitstring>>), do: prefix
  def prefix_from_ipv4(ipv4) do
    <<prefix::size(worker_ids_lookup_bits()), _rest::bitstring>> =
      :crypto.hash(:sha, <<reverse_bits32(ipv4)::32>>)
    prefix
  end
  defp get_id_by_prefix(prefix) do
    case :ets.lookup_element(@ets_worker_ids, prefix, 2) do
      nil -> IdGenSync.rand_id()
      id -> id
    end
  end
  defp gen_proximity_id(target_ih) do
    bits = @min_dist_bits + :rand.uniform(@max_dist_bits - @min_dist_bits + 1) - 1
    distance = gen_distance_mask(bits)
    :crypto.exor(target_ih, distance)
  end
  defp gen_distance_mask(0), do: <<0::160>>
  defp gen_distance_mask(bits) do
    zero_bits = dht_bits() - bits
    zero_bytes = div(zero_bits, 8)
    partial = rem(zero_bits, 8)
    rand_len = dht_bytes() - zero_bytes
    <<first_byte, rest::binary>> = rand_bytes(rand_len)
    fb_final = bit_distance_boundary(first_byte, partial)
    pad = elem(@zero_pads_tuple, zero_bytes)
    <<pad::binary, fb_final, rest::binary>>
  end
  defp rand_bytes(n), do: :crypto.strong_rand_bytes(n)
  defp bit_distance_boundary(first_byte, partial) do
    boundary_bit = 0x80 >>> partial
    masked_byte = first_byte ||| boundary_bit
    mask = 0xFF >>> partial
    masked_byte &&& mask
  end
  defp reverse_bits32(n) do
    n = (n &&& 0x55555555) <<< 1 ||| (n &&& 0xAAAAAAAA) >>> 1
    n = (n &&& 0x33333333) <<< 2 ||| (n &&& 0xCCCCCCCC) >>> 2
    n = (n &&& 0x0F0F0F0F) <<< 4 ||| (n &&& 0xF0F0F0F0) >>> 4
    n = (n &&& 0x00FF00FF) <<< 8 ||| (n &&& 0xFF00FF00) >>> 8
    (n &&& 0x0000FFFF) <<< 16 ||| (n &&& 0xFFFF0000) >>> 16
  end
end