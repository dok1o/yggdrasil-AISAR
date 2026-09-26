defmodule Ygg.Crypto do
  @moduledoc """
  Shared helpers for ironwood `encrypted`: the group-password secret of `crypto.go:141-167`
  (`newGroupAuth`, `groupAuth.preimage`). Primitives live in `Ygg.Crypto.Salsa`,
  `Ygg.Crypto.Box` and `Ygg.Crypto.Ed2Curve`.
  """
  @doc """
  `sha256("ironwood/encrypted\\0" ++ password)`, prepended to every signed handshake message
  (`edSign`/`edCheck`: `append(preimage, msg...)`). An empty password disables group auth in
  Go (nil preimage), so `""` gives `<<>>` here and the prefix can always be concatenated.
  """
  @spec group_secret(binary()) :: binary()
  def group_secret(""), do: <<>>
  def group_secret(password), do: :crypto.hash(:sha256, ["ironwood/encrypted", 0, password])
end