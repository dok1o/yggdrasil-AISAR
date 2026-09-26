defmodule Ygg.Transport.Buffer do
  @moduledoc """
  Pure functions over the receive buffer of `Ygg.Transport.Conn`.
  Adapted from `context/conn_buffer.ex`: `try_satisfy_exact/2` is unchanged; the BitTorrent
  4-byte `try_satisfy_stream` is replaced by `try_satisfy_frame/2`, which cuts one ironwood
  link frame (`uvarint(len)` then `len` bytes = type + payload, PROMPT_ELIXIR_PORT.md §3).
  A frame longer than `max` is `{:error, :oversized}` (ironwood `ErrOversizedMessage`),
  a zero length or an unparseable length prefix is `{:error, :decode}`; the link must close
  on both. The returned frame excludes the length prefix.
  """
  alias Ygg.Wire
  @compile {:inline, [try_satisfy: 2, try_satisfy_exact: 2, try_satisfy_frame: 2]}
  @max_uvarint 10
  @type result :: {:ok, binary(), binary()} | :insufficient | {:error, :oversized | :decode}
  @spec try_satisfy(binary(), pos_integer() | {:frame, pos_integer()}) :: result()
  def try_satisfy(buffer, {:frame, max}), do: try_satisfy_frame(buffer, max)
  def try_satisfy(buffer, bytes) when is_integer(bytes), do: try_satisfy_exact(buffer, bytes)
  @spec try_satisfy_exact(binary(), non_neg_integer()) :: result()
  def try_satisfy_exact(buffer, bytes) when byte_size(buffer) >= bytes do
    <<data::binary-size(bytes), rest::binary>> = buffer
    {:ok, data, rest}
  end
  def try_satisfy_exact(_buf, _bytes), do: :insufficient
  @spec try_satisfy_frame(binary(), pos_integer()) :: result()
  def try_satisfy_frame(buffer, max) do
    case Wire.decode_uvarint(buffer) do
      {:ok, len, _rest} when len > max ->
        {:error, :oversized}
      {:ok, 0, _rest} ->
        {:error, :decode}
      {:ok, len, rest} when byte_size(rest) >= len ->
        <<frame::binary-size(len), rest::binary>> = rest
        {:ok, frame, rest}
      {:ok, _len, _rest} ->
        :insufficient
      :error when byte_size(buffer) >= @max_uvarint ->
        {:error, :decode}
      :error ->
        :insufficient
    end
  end
end