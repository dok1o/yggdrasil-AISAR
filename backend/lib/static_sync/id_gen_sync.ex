defmodule IdGenSync do
  import Bitwise
  @compile {:inline, [crc32c: 1, get_bep42_id: 2, build_uniform_ids: 5]}
  @compile {:inline, [make_tid: 1, tid_is_bep42?: 1]}
  @app_prefix "-UU0019-"
  def get_id() do
    random_len = 20 - byte_size(@app_prefix)
    @app_prefix <> :crypto.strong_rand_bytes(random_len)
  end
  @doc """
  Proper BEP-42 node ID generation per spec.
  - r: value 0-7, determines prefix variation and stored in byte 19
  - First 21 bits: derived from CRC32C of masked IP with r
  - Bytes 3-18: random
  - Byte 19: r value
  """
  def get_bep42_id(<<a, b, c, d>>, r) when r >= 0 and r < 8 do
    ip = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
    masked = (ip &&& 0x030F3FFF) ||| r <<< 29
    crc = crc32c(<<masked::big-32>>)
    rand_mid = :crypto.strong_rand_bytes(16)
    rand_3bits = :rand.uniform(8) - 1
    <<
      crc >>> 24::8,
      crc >>> 16 &&& 0xFF::8,
      (crc >>> 8 &&& 0xF8) ||| rand_3bits::8,
      rand_mid::binary-size(16),
      r::8
    >>
  end
  def get_bep42_id(ipv4), do: get_bep42_id(ipv4, :rand.uniform(8) - 1)
  defp crc32c(data), do: :erlang.crc32(data)
  @doc """
  Generate 8 BEP-42 IDs using all r values (0-7) for maximum keyspace coverage.
  Each r value produces a different 21-bit prefix.
  """
  def generate_bep42_ids(<<_::32>> = ipv4) do
    rand_blob = :crypto.strong_rand_bytes(8 * 16)
    for r <- 0..7 do
      offset = r * 16
      <<_::binary-size(offset), rand_mid::binary-size(16), _::binary>> = rand_blob
      <<a, b, c, d>> = ipv4
      ip = a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
      masked = (ip &&& 0x030F3FFF) ||| r <<< 29
      crc = crc32c(<<masked::big-32>>)
      rand_3bits = :rand.uniform(8) - 1
      <<
        crc >>> 24::8,
        crc >>> 16 &&& 0xFF::8,
        (crc >>> 8 &&& 0xF8) ||| rand_3bits::8,
        rand_mid::binary-size(16),
        r::8
      >>
    end
  end
  @doc """
  Generate count uniformly distributed IDs (non-BEP-42).
  Uses MSB partitioning for guaranteed uniform distribution.
  """
  def generate_uniform_ids(count) when count > 0 do
    bits_needed = max(1, ceil(:math.log2(count)))
    remaining_bits = 160 - bits_needed
    random_blob = :crypto.strong_rand_bytes(count * 20)
    indices = Enum.shuffle(0..(count - 1))
    build_uniform_ids(indices, random_blob, bits_needed, remaining_bits, [])
  end
  defp build_uniform_ids([], _blob, _bn, _rn, acc), do: acc
  defp build_uniform_ids(
         [idx | rest_idx],
         <<chunk::binary-size(20), rest_blob::binary>>,
         bn,
         rn,
         acc
       ) do
    <<_::size(bn), random_tail::bitstring-size(rn)>> = chunk
    id = <<idx::size(bn), random_tail::bitstring>>
    build_uniform_ids(rest_idx, rest_blob, bn, rn, [id | acc])
  end
  @doc """
  Generate all worker IDs: 8 BEP-42 + extra_count uniform.
  Returns {all_ids_sorted, bep42_set} where bep42_set is for O(1) membership testing.
  """
  def generate_all_worker_ids(ipv4, bep42_count \\ 0, extra_count \\ 512)
  def generate_all_worker_ids(nil, _bep42_count, total_count) do
    ids = generate_uniform_ids(total_count)
    {Enum.sort(ids), MapSet.new()}
  end
  def generate_all_worker_ids(<<_::32>> = ipv4, _bep42_count, extra_count) do
    bep42_ids = generate_bep42_ids(ipv4)
    uniform_ids = generate_uniform_ids(extra_count)
    all_ids = Enum.sort(bep42_ids ++ uniform_ids)
    bep42_set = MapSet.new(bep42_ids)
    {all_ids, bep42_set}
  end
  def rand_id(), do: :crypto.strong_rand_bytes(20)
  def rand_dht_token(), do: :crypto.strong_rand_bytes(8)
  def dht_token(ip_bin, secret) do
    :crypto.mac(:hmac, :sha256, secret, ip_bin)
    |> binary_part(0, 8)
  end
  def get_far_id(<<base_int::unsigned-big-160>>) do
    <<mask_int::unsigned-big-160>> = :crypto.strong_rand_bytes(20)
    <<Bitwise.bxor(base_int, mask_int)::160>>
  end
  def make_tid(bep42?) do
    <<n::16>> = :crypto.strong_rand_bytes(2)
    case bep42? do
      true -> <<n &&& 0xFFFE::16>>
      false -> <<n ||| 0x0001::16>>
    end
  end
  def tid_is_bep42?(<<_::15, bit::1>>), do: bit == 0
  def tid_is_bep42?(_), do: false
  def make_tid(), do: :crypto.strong_rand_bytes(2)
end