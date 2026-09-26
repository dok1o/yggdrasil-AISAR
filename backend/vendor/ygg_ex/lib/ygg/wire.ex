defmodule Ygg.Wire do
  @moduledoc """
  Wire primitives shared by the ironwood link framing and the Yggdrasil handshake.
  Ports Go `encoding/binary.Uvarint`/`AppendUvarint` (LEB128, at most 10 bytes, 64-bit
  overflow is an error) and the ironwood `path` encoding (uvarint ports terminated by 0)
  described in PROMPT_ELIXIR_PORT.md §3. `peer_max_message_size/0` is the value Yggdrasil
  hands to ironwood in `reference/yggdrasil-go/src/core/core.go:102` (`WithPeerMaxMessageSize(65535*2)`).
  Fixed-size readers `take_key/1` (32 bytes) and `take_sig/1` (64 bytes) are used by
  `Ygg.Frames`.
  """
  import Bitwise
  @compile {:inline, [encode_uvarint: 1, decode_uvarint: 1, take_key: 1, take_sig: 1]}
  @peer_max_message_size 65_535 * 2
  @key_size 32
  @sig_size 64
  @max_shift 63
  def peer_max_message_size, do: @peer_max_message_size
  def key_size, do: @key_size
  def sig_size, do: @sig_size
  @spec encode_uvarint(non_neg_integer()) :: binary()
  def encode_uvarint(n) when is_integer(n) and n >= 0 and n < 128, do: <<n>>
  def encode_uvarint(n) when is_integer(n) and n >= 128,
    do: <<1::1, n::7, encode_uvarint(n >>> 7)::binary>>
  @spec decode_uvarint(binary()) :: {:ok, non_neg_integer(), binary()} | :error
  def decode_uvarint(bin), do: uvarint(bin, 0, 0)
  defp uvarint(<<0::1, b::7, rest::binary>>, acc, shift) when shift < @max_shift,
    do: {:ok, acc ||| b <<< shift, rest}
  defp uvarint(<<0::1, b::7, rest::binary>>, acc, @max_shift) when b <= 1,
    do: {:ok, acc ||| b <<< @max_shift, rest}
  defp uvarint(<<1::1, b::7, rest::binary>>, acc, shift) when shift < @max_shift,
    do: uvarint(rest, acc ||| b <<< shift, shift + 7)
  defp uvarint(_bin, _acc, _shift), do: :error
  @spec encode_path([non_neg_integer()]) :: iodata()
  def encode_path(ports) when is_list(ports), do: [Enum.map(ports, &encode_uvarint/1), 0]
  @spec decode_path(binary()) :: {:ok, [pos_integer()], binary()} | :error
  def decode_path(bin), do: path(bin, [])
  defp path(bin, acc) do
    case decode_uvarint(bin) do
      {:ok, 0, rest} -> {:ok, Enum.reverse(acc), rest}
      {:ok, port, rest} -> path(rest, [port | acc])
      :error -> :error
    end
  end
  @spec take_key(binary()) :: {:ok, <<_::256>>, binary()} | :error
  def take_key(<<key::binary-size(@key_size), rest::binary>>), do: {:ok, key, rest}
  def take_key(_bin), do: :error
  @spec take_sig(binary()) :: {:ok, <<_::512>>, binary()} | :error
  def take_sig(<<sig::binary-size(@sig_size), rest::binary>>), do: {:ok, sig, rest}
  def take_sig(_bin), do: :error
end