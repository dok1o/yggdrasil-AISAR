defmodule Ygg.Crypto.Box do
  @moduledoc """
  NaCl `crypto_box` after precomputation (X25519 + XSalsa20-Poly1305), byte-compatible with
  `golang.org/x/crypto/nacl/box` v0.51.0 as ironwood uses it (`encrypted/crypto.go:88-139`:
  `newBoxKeys`, `getShared`, `boxSeal`, `boxOpen`, `nonceForUint64`).
  - `precompute/2` = `box.Precompute` (box.go): `HSalsa20(X25519(priv, pub), 0^16)`. Go zeroes
    the DH output for low-order peer points and carries on with `HSalsa20(0, 0)`; here that
    case is `:error` (OpenSSL refuses the all-zero result), which callers treat as a failed open.
  - `seal/3`/`open/3` = `secretbox.Seal`/`Open` (secretbox.go `setup`, `Seal`, `Open`): subkey =
    `HSalsa20(shared, nonce[0:16])`, Salsa20 over `nonce[16:24]` from block 0; keystream bytes
    0..31 are the Poly1305 key, the message is XORed with the keystream from byte 32 on; output
    is `tag(16) ++ ciphertext`.
  - ironwood's nonce is `0^16 ++ BE64(n)` (`nonceForUint64`), so the HSalsa20 subkey depends
    on the shared key only: `subkey/1` once per shared key, then `seal_with_subkey/3` and
    `open_with_subkey/3` with the 8-byte tail `<<n::64>>` give the same bytes as `seal/3`/`open/3`.
  """
  alias Ygg.Crypto.Salsa
  @compile {:inline, [nonce: 1]}
  @overhead 16
  @doc "Bytes added by `seal/3` (Go `box.Overhead`)."
  def overhead, do: @overhead
  @doc "Fresh X25519 key pair `{pub, priv}` (Go `box.GenerateKey`)."
  @spec keypair() :: {<<_::256>>, <<_::256>>}
  def keypair, do: :crypto.generate_key(:ecdh, :x25519)
  @doc "X25519 public key for a 32-byte private scalar (clamped by X25519 itself)."
  @spec pub_of(<<_::256>>) :: <<_::256>>
  def pub_of(<<_::binary-32>> = priv) do
    {pub, _} = :crypto.generate_key(:ecdh, :x25519, priv)
    pub
  end
  @doc "`box.Precompute`: `{:ok, HSalsa20(X25519(my_priv, their_pub), 0^16)}`; `:error` on low-order points."
  @spec precompute(binary(), binary()) :: {:ok, <<_::256>>} | :error
  def precompute(<<_::binary-32>> = their_pub, <<_::binary-32>> = my_priv) do
    case :crypto.compute_key(:ecdh, their_pub, my_priv, :x25519) do
      <<0::256>> -> :error
      <<_::binary-32>> = dh -> {:ok, Salsa.hsalsa20(dh, <<0::128>>)}
    end
  rescue
    _ in [ErlangError, ArgumentError] -> :error
  end
  def precompute(_their_pub, _my_priv), do: :error
  @doc "ironwood `nonceForUint64`: 16 zero bytes ++ big-endian uint64."
  @spec nonce(non_neg_integer()) :: <<_::192>>
  def nonce(n), do: <<0::128, n::64>>
  @doc "HSalsa20 subkey for ironwood nonces (first 16 nonce bytes zero)."
  @spec subkey(<<_::256>>) :: <<_::256>>
  def subkey(shared), do: Salsa.hsalsa20(shared, <<0::128>>)
  @doc "`box.SealAfterPrecomputation` / `secretbox.Seal`: `tag(16) ++ ciphertext`."
  @spec seal(<<_::256>>, <<_::192>>, iodata()) :: binary()
  def seal(shared, <<n16::binary-16, n8::binary-8>>, msg),
    do: seal_with_subkey(Salsa.hsalsa20(shared, n16), n8, msg)
  @doc "`box.OpenAfterPrecomputation` / `secretbox.Open`; tag compared in constant time."
  @spec open(<<_::256>>, <<_::192>>, binary()) :: {:ok, binary()} | :error
  def open(shared, <<n16::binary-16, n8::binary-8>>, boxed),
    do: open_with_subkey(Salsa.hsalsa20(shared, n16), n8, boxed)
  @doc "`seal/3` with a precomputed `subkey/1` and the last 8 nonce bytes."
  @spec seal_with_subkey(<<_::256>>, <<_::64>>, iodata()) :: binary()
  def seal_with_subkey(sub, <<_::binary-8>> = n8, msg) do
    msg = IO.iodata_to_binary(msg)
    <<poly_key::binary-32, ks::binary>> = Salsa.stream(sub, n8, 0, 32 + byte_size(msg))
    ct = :crypto.exor(msg, ks)
    <<:crypto.mac(:poly1305, poly_key, ct)::binary, ct::binary>>
  end
  @doc "`open/3` with a precomputed `subkey/1` and the last 8 nonce bytes."
  @spec open_with_subkey(<<_::256>>, <<_::64>>, binary()) :: {:ok, binary()} | :error
  def open_with_subkey(sub, <<_::binary-8>> = n8, <<tag::binary-16, ct::binary>>) do
    <<poly_key::binary-32, ks0::binary-32>> = Salsa.block(sub, n8, 0)
    if :crypto.hash_equals(:crypto.mac(:poly1305, poly_key, ct), tag) do
      {:ok, decrypt(sub, n8, ks0, ct)}
    else
      :error
    end
  end
  def open_with_subkey(_sub, _n8, _boxed), do: :error
  defp decrypt(_sub, _n8, ks0, ct) when byte_size(ct) <= 32,
    do: :crypto.exor(ct, binary_part(ks0, 0, byte_size(ct)))
  defp decrypt(sub, n8, ks0, ct),
    do: :crypto.exor(ct, ks0 <> Salsa.stream(sub, n8, 1, byte_size(ct) - 32))
end