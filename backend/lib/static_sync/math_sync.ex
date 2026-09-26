defmodule MathSync do
  import MagnetSorter.Const
  import Bitwise
  @compile {:inline, [select_udp_shard: 1, s_prefix: 1, safe_rate: 3, sha1?: 2, xor_distance: 2]}
  @dht_bytes 20
  @len samples_prefix_length()
  @rem_len @dht_bytes - @len
  def safe_rate(numen, denom, decimals)
  def safe_rate(_numen, denom, 0) when denom <= 0, do: 0
  def safe_rate(numen, denom, 0), do: round(numen / denom)
  def safe_rate(_numen, denom, 2) when denom <= 0, do: 0.0
  def safe_rate(numen, denom, 2), do: Float.round(numen / denom * 100, 2)
  def rolled?(n, m), do: :rand.uniform(m) == n
  def sha1?(hash, payload) do
    case :crypto.hash(:sha, payload) do
      ^hash -> true
      _any -> false
    end
  end
  def select_udp_shard(<<ipv4::32, port::16>>) do
    num = KeyStorageSync.get_num_udp_shards()
    :erlang.phash2({ipv4, port}, num) + 1
  end
  def s_prefix(<<prefix::binary-size(@len), _rest::binary-size(@rem_len)>>), do: prefix
  def xor_distance(
        <<left::binary-size(@dht_bytes)>>,
        <<right::binary-size(@dht_bytes)>>
      ) do
    :binary.decode_unsigned(left, :big)
    |> bxor(:binary.decode_unsigned(right, :big))
  end
end