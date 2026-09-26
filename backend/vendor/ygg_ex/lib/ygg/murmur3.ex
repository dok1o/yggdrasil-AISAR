defmodule Ygg.Murmur3 do
  @moduledoc """
  MurmurHash3 x64_128 with seed 0, as used by `github.com/bits-and-blooms/bloom/v3` v3.7.1
  (`murmur.go`: `bmix_words` :85-105, `sum128` :113-224, `fmix64` :226-233). All arithmetic
  is masked to 64 bits; blocks and the zero-padded tail are read little-endian, which is
  exactly the fallthrough `switch` in `sum128`.
  `sum256/1` is `murmur.go:248-280` (`baseHashes` in `bloom.go:111-117`): the documented
  equivalent `{h1, h2} = x64_128(data)`, `{h3, h4} = x64_128(data <> <<1>>)`.
  """
  import Bitwise
  @compile {:inline, [mul: 2, rotl: 2, mix_k1: 1, mix_k2: 1, fmix64: 1]}
  @m64 0xFFFF_FFFF_FFFF_FFFF
  @c1 0x87C37B91114253D5
  @c2 0x4CF5AD432745937F
  @type u64 :: non_neg_integer()
  @spec x64_128(binary()) :: {u64(), u64()}
  def x64_128(data) when is_binary(data), do: blocks(data, 0, 0, byte_size(data))
  @spec sum256(binary()) :: {u64(), u64(), u64(), u64()}
  def sum256(data) when is_binary(data) do
    {h1, h2} = x64_128(data)
    {h3, h4} = x64_128(<<data::binary, 1>>)
    {h1, h2, h3, h4}
  end
  defp blocks(<<k1::little-64, k2::little-64, rest::binary>>, h1, h2, len) do
    h1 = bxor(h1, mix_k1(k1)) |> rotl(27) |> Kernel.+(h2) |> mul(5) |> Kernel.+(0x52DCE729)
    h1 = h1 &&& @m64
    h2 = bxor(h2, mix_k2(k2)) |> rotl(31) |> Kernel.+(h1) |> mul(5) |> Kernel.+(0x38495AB5)
    blocks(rest, h1, h2 &&& @m64, len)
  end
  defp blocks(tail, h1, h2, len) do
    n = byte_size(tail)
    <<k1::little-64, k2::little-64>> = <<tail::binary, 0::size((16 - n) * 8)>>
    h2 = if n > 8, do: bxor(h2, mix_k2(k2)), else: h2
    h1 = if n > 0, do: bxor(h1, mix_k1(k1)), else: h1
    h1 = bxor(h1, len)
    h2 = bxor(h2, len)
    h1 = h1 + h2 &&& @m64
    h2 = h2 + h1 &&& @m64
    h1 = fmix64(h1)
    h2 = fmix64(h2)
    h1 = h1 + h2 &&& @m64
    {h1, h2 + h1 &&& @m64}
  end
  defp mix_k1(k), do: k |> mul(@c1) |> rotl(31) |> mul(@c2)
  defp mix_k2(k), do: k |> mul(@c2) |> rotl(33) |> mul(@c1)
  defp mul(a, b), do: a * b &&& @m64
  defp rotl(x, r), do: (x <<< r ||| x >>> (64 - r)) &&& @m64
  defp fmix64(k) do
    k = bxor(k, k >>> 33) |> mul(0xFF51AFD7ED558CCD)
    k = bxor(k, k >>> 33) |> mul(0xC4CEB9FE1A85EC53)
    bxor(k, k >>> 33)
  end
end