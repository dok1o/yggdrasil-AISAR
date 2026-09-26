defmodule Ygg.Crypto.Salsa do
  @moduledoc """
  Salsa20/20 and HSalsa20 in pure Elixir (OTP `:crypto` has neither). Ports
  `golang.org/x/crypto/salsa20/salsa` v0.51.0: `salsa20_ref.go` `core` (the block function,
  lines 13-205) and `genericXORKeyStream` (lines 207-233, the 16-byte counter block is
  `nonce(8) ++ little-endian uint64 block counter`, carrying across all 64 bits), and
  `hsalsa20.go` `HSalsa20` (lines 20-146: same rounds, no feed-forward, output words
  0, 5, 10, 15, 6, 7, 8, 9). Constant is `Sigma = "expand 32-byte k"`.
  The 10 double rounds are generated at compile time from the quarter-round schedule into a
  single tail-recursive function over 16 small integers (no tuples or lists per round);
  words are masked to 32 bits after every add. Keystream XOR is `:crypto.exor/2`.
  """
  import Bitwise
  @compile {:inline, [rotl: 2]}
  @m 0xFFFFFFFF
  @s0 0x61707865
  @s1 0x3320646E
  @s2 0x79622D32
  @s3 0x6B206574
  @schedule [
    {4, 0, 12, 7},
    {8, 4, 0, 9},
    {12, 8, 4, 13},
    {0, 12, 8, 18},
    {9, 5, 1, 7},
    {13, 9, 5, 9},
    {1, 13, 9, 13},
    {5, 1, 13, 18},
    {14, 10, 6, 7},
    {2, 14, 10, 9},
    {6, 2, 14, 13},
    {10, 6, 2, 18},
    {3, 15, 11, 7},
    {7, 3, 15, 9},
    {11, 7, 3, 13},
    {15, 11, 7, 18},
    {1, 0, 3, 7},
    {2, 1, 0, 9},
    {3, 2, 1, 13},
    {0, 3, 2, 18},
    {6, 5, 4, 7},
    {7, 6, 5, 9},
    {4, 7, 6, 13},
    {5, 4, 7, 18},
    {11, 10, 9, 7},
    {8, 11, 10, 9},
    {9, 8, 11, 13},
    {10, 9, 8, 18},
    {12, 15, 14, 7},
    {13, 12, 15, 9},
    {14, 13, 12, 13},
    {15, 14, 13, 18}
  ]
  defp rotl(v, n), do: (v <<< n ||| v >>> (32 - n)) &&& @m
  xs = for i <- 0..15, do: Macro.var(:"x#{i}", __MODULE__)
  x = fn i -> Enum.at(xs, i) end
  steps =
    for {t, a, b, n} <- @schedule do
      quote do
        unquote(x.(t)) =
          bxor(unquote(x.(t)), rotl(unquote(x.(a)) + unquote(x.(b)) &&& @m, unquote(n)))
      end
    end
  defp rounds(0, unquote_splicing(xs)), do: {unquote_splicing(xs)}
  defp rounds(n, unquote_splicing(xs)) do
    unquote_splicing(steps)
    rounds(n - 1, unquote_splicing(xs))
  end
  @doc "HSalsa20(key, in16) with the NaCl sigma constant (Go `salsa.HSalsa20(out, in, k, &Sigma)`)."
  @spec hsalsa20(<<_::256>>, <<_::128>>) :: <<_::256>>
  def hsalsa20(
        <<k0::little-32, k1::little-32, k2::little-32, k3::little-32, k4::little-32,
          k5::little-32, k6::little-32, k7::little-32>>,
        <<n0::little-32, n1::little-32, n2::little-32, n3::little-32>>
      ) do
    {x0, _, _, _, _, x5, x6, x7, x8, x9, x10, _, _, _, _, x15} =
      rounds(10, @s0, k0, k1, k2, k3, @s1, n0, n1, n2, n3, @s2, k4, k5, k6, k7, @s3)
    <<x0::little-32, x5::little-32, x10::little-32, x15::little-32, x6::little-32, x7::little-32,
      x8::little-32, x9::little-32>>
  end
  @doc "One 64-byte Salsa20/20 block for `key`, 8-byte `nonce` and 64-bit block `counter`."
  @spec block(<<_::256>>, <<_::64>>, non_neg_integer()) :: <<_::512>>
  def block(key, <<n0::little-32, n1::little-32>>, counter) do
    <<k0::little-32, k1::little-32, k2::little-32, k3::little-32, k4::little-32, k5::little-32,
      k6::little-32, k7::little-32>> = key
    block_words({k0, k1, k2, k3, k4, k5, k6, k7}, n0, n1, counter &&& 0xFFFFFFFFFFFFFFFF)
  end
  defp block_words({k0, k1, k2, k3, k4, k5, k6, k7}, n0, n1, ctr) do
    c0 = ctr &&& @m
    c1 = ctr >>> 32
    {x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15} =
      rounds(10, @s0, k0, k1, k2, k3, @s1, n0, n1, c0, c1, @s2, k4, k5, k6, k7, @s3)
    <<x0 + @s0 &&& @m::little-32, x1 + k0 &&& @m::little-32, x2 + k1 &&& @m::little-32,
      x3 + k2 &&& @m::little-32, x4 + k3 &&& @m::little-32, x5 + @s1 &&& @m::little-32,
      x6 + n0 &&& @m::little-32, x7 + n1 &&& @m::little-32, x8 + c0 &&& @m::little-32,
      x9 + c1 &&& @m::little-32, x10 + @s2 &&& @m::little-32, x11 + k4 &&& @m::little-32,
      x12 + k5 &&& @m::little-32, x13 + k6 &&& @m::little-32, x14 + k7 &&& @m::little-32,
      x15 + @s3 &&& @m::little-32>>
  end
  @doc """
  `len` bytes of Salsa20/20 keystream starting at block `counter` (Go `salsa.XORKeyStream`
  over zeros with `counter16 = nonce ++ <<counter::little-64>>`). The block counter wraps at 2^64.
  """
  @spec stream(<<_::256>>, <<_::64>>, non_neg_integer(), non_neg_integer()) :: binary()
  def stream(_key, _nonce, _counter, 0), do: <<>>
  def stream(key, <<n0::little-32, n1::little-32>>, counter, len) do
    <<k0::little-32, k1::little-32, k2::little-32, k3::little-32, k4::little-32, k5::little-32,
      k6::little-32, k7::little-32>> = key
    k = {k0, k1, k2, k3, k4, k5, k6, k7}
    nblocks = div(len + 63, 64)
    bin = IO.iodata_to_binary(blocks(k, n0, n1, counter, nblocks, []))
    binary_part(bin, 0, len)
  end
  defp blocks(_k, _n0, _n1, _ctr, 0, acc), do: :lists.reverse(acc)
  defp blocks(k, n0, n1, ctr, left, acc) do
    ctr = ctr &&& 0xFFFFFFFFFFFFFFFF
    blocks(k, n0, n1, ctr + 1, left - 1, [block_words(k, n0, n1, ctr) | acc])
  end
  @doc "`data` XOR Salsa20/20 keystream (encrypt = decrypt)."
  @spec xor_stream(<<_::256>>, <<_::64>>, non_neg_integer(), binary()) :: binary()
  def xor_stream(_key, _nonce, _counter, <<>>), do: <<>>
  def xor_stream(key, nonce, counter, data),
    do: :crypto.exor(data, stream(key, nonce, counter, byte_size(data)))
  @doc "XSalsa20: `data` XOR keystream for a 24-byte nonce, starting at block `counter`."
  @spec xsalsa20_xor(<<_::256>>, <<_::192>>, non_neg_integer(), binary()) :: binary()
  def xsalsa20_xor(key, <<n16::binary-16, n8::binary-8>>, counter \\ 0, data),
    do: xor_stream(hsalsa20(key, n16), n8, counter, data)
end