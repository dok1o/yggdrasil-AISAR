defmodule CharsSync do
  def safe_utf8(term) do
    term
    |> to_string()
    |> sanitize_bin()
  end
  defp sanitize_bin(binary) do
    case String.valid?(binary) do
      true -> binary
      false -> do_sanitize(binary, [])
    end
  end
  defp do_sanitize(<<>>, acc) do
    acc
    |> Enum.reverse()
    |> :erlang.iolist_to_binary()
  end
  defp do_sanitize(<<c::utf8, rest::binary>>, acc), do: do_sanitize(rest, [<<c::utf8>> | acc])
  defp do_sanitize(<<_c, rest::binary>>, acc), do: do_sanitize(rest, acc)
end