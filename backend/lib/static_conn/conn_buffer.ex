defmodule Conn.Buffer do
  @compile {:inline, [try_satisfy_exact: 2, try_satisfy_any: 2, try_satisfy_stream: 2]}
  def try_satisfy(buffer, {:message, max}), do: try_satisfy_stream(buffer, max)
  def try_satisfy(buffer, bytes) when is_integer(bytes), do: try_satisfy_exact(buffer, bytes)
  def try_satisfy_exact(buffer, bytes) when byte_size(buffer) >= bytes do
    <<data::binary-size(^bytes), rest::binary>> = buffer
    {:ok, data, rest}
  end
  def try_satisfy_exact(_buf, _bytes), do: :insufficient
  def try_satisfy_any(buffer, max_size) when byte_size(buffer) > 0 do
    bytes = min(byte_size(buffer), max_size)
    <<data::binary-size(^bytes), rest::binary>> = buffer
    {:ok, data, rest}
  end
  def try_satisfy_any(<<>>, _max_size), do: :insufficient
  def try_satisfy_stream(<<0::32, rest::binary>>, _bytes), do: {:ok, <<>>, rest}
  def try_satisfy_stream(<<len::32, _rest::binary>>, max) when len > max,
    do: {:error, :buffer_overflow}
  def try_satisfy_stream(<<len::32, data::binary-size(len), rest::binary>>, _bytes),
    do: {:ok, data, rest}
  def try_satisfy_stream(_buf, _bytes), do: :insufficient
end