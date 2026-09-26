defmodule Ygg.Crypto.Ed2Curve do
  @moduledoc """
  ed25519 -> X25519 key conversion, ported from ironwood `encrypted/internal/e2c/e2c.go`
  (itself from age `internal/age/ssh.go`), used by `crypto.go:66-79` (`edPub.toBox`,
  `edPriv.toBox`).
  - `priv/1`: `sha512(seed)[0:32]`, **not** clamped (Go leaves clamping to X25519, which
    clamps on every use, so `:crypto` gives the same results).
  - `pub/1`: little-endian `y` with bit 255 (the x sign) cleared, `u = (1 + y) / (1 - y) mod p`.
    Go performs no point validation and never fails: non-canonical `y >= p` is reduced, and for
    `y = 1 (mod p)`, where `1 - y` has no inverse, `big.Int.ModInverse` leaves the denominator
    unreduced and `u` comes out 0. The same is done here, so the only `:error` is a wrong
    input size; a zero `u` is refused later by `Ygg.Crypto.Box.precompute/2`.
  """
  import Bitwise
  @p (1 <<< 255) - 19
  @y_mask (1 <<< 255) - 1
  @doc "X25519 public key for an ed25519 public key (Go `Ed25519PublicKeyToCurve25519`)."
  @spec pub(binary()) :: {:ok, <<_::256>>} | :error
  def pub(<<_::binary-32>> = ed_pub) do
    y = :binary.decode_unsigned(ed_pub, :little) &&& @y_mask
    u =
      case Integer.mod(1 - y, @p) do
        0 -> 0
        d -> rem((y + 1) * inv(d), @p)
      end
    {:ok, <<u::little-256>>}
  end
  def pub(_), do: :error
  @doc "X25519 private key for an ed25519 seed (Go `Ed25519PrivateKeyToCurve25519`); unclamped."
  @spec priv(<<_::256>>) :: <<_::256>>
  def priv(<<seed::binary-32>>) do
    <<x::binary-32, _::binary-32>> = :crypto.hash(:sha512, seed)
    x
  end
  defp inv(d), do: :binary.decode_unsigned(:crypto.mod_pow(d, @p - 2, @p))
end