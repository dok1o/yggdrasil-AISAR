defmodule RC4Sync do
  import Bitwise
  @compile {:inline, [init: 1, crypt: 2, discard: 2, next_byte: 1, swap: 3]}
  def init(key), do: do_init(key)
  def crypt(st, data), do: do_crypt(data, st, [])
  def discard(st, n), do: do_discard(st, n)
  defp next_byte({s, i, j}) do
    i = rem(i + 1, 256)
    j = rem(j + elem(s, i), 256)
    s = swap(s, i, j)
    k = elem(s, rem(elem(s, i) + elem(s, j), 256))
    {k, {s, i, j}}
  end
  defp swap(s, i, j) do
    vi = elem(s, i)
    vj = elem(s, j)
    s
    |> put_elem(i, vj)
    |> put_elem(j, vi)
  end
  defp do_init(key) do
    s = List.to_tuple(Enum.to_list(0..255))
    key_len = byte_size(key)
    {s, _} =
      Enum.reduce(0..255, {s, 0}, fn i, {s, j} ->
        j = rem(j + elem(s, i) + :binary.at(key, rem(i, key_len)), 256)
        {swap(s, i, j), j}
      end)
    {s, 0, 0}
  end
  defp do_crypt(<<>>, st, acc) do
    {:erlang.list_to_binary(:lists.reverse(acc)), st}
  end
  defp do_crypt(<<byte, rest::binary>>, st, acc) do
    {k, next_st} = next_byte(st)
    do_crypt(rest, next_st, [bxor(byte, k) | acc])
  end
  def do_discard(st, n)
  def do_discard(st, 0), do: st
  def do_discard(st, n) when n > 0 do
    {_, st} = next_byte(st)
    do_discard(st, n - 1)
  end
end