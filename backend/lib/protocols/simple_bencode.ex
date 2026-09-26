defmodule SimpleBencodeSync do
  @max_message_size 1_024 * 1_024 * 16
  @max_key_nesting 64
  @max_digits 16
  @explicit_zero 0
  def encode(term), do: :erlang.iolist_to_binary(enc(term))
  def decode_consuming(data) when is_binary(data) do
    with {:ok, term, rest} <- decode_with_rest(data) do
      consumed = byte_size(data) - byte_size(rest)
      {:ok, term, consumed}
    end
  end
  def decode_with_rest(data) when byte_size(data) > @max_message_size,
    do: {:error, :bencode_overflow}
  def decode_with_rest(data) when is_binary(data) do
    try do
      {term, rest} = decode_value(data)
      {:ok, term, rest}
    catch
      {:error, reason} -> {:error, reason}
    end
  end
  def decode(data) when byte_size(data) > @max_message_size,
    do: {:error, :bencode_overflow}
  def decode(data) do
    try do
      case decode_value(data) do
        {term, <<>>} -> {:ok, term}
        {_term, _r} -> {:error, :trailing_data}
      end
    catch
      {:error, reason} -> {:error, reason}
    end
  end
  def decode_torrent(data) when is_binary(data) do
    with {:ok, torrent_file} when is_map(torrent_file) <- decode(data),
         {:ok, info} when is_map(info) <- Map.fetch(torrent_file, "info"),
         infohash <- :crypto.hash(:sha, enc_for_infohash(info)) do
      {:ok, info, infohash}
    else
      err -> err
    end
  end
  defguardp digit?(d) when d in ?0..?9
  defp enc(n) when is_integer(n), do: [?i, Integer.to_string(n), ?e]
  defp enc(s) when is_binary(s), do: [Integer.to_string(byte_size(s)), ":", s]
  defp enc(list) when is_list(list), do: [?l, Enum.map(list, &enc/1), ?e]
  defp enc(m) when is_map(m), do: [?d, sort_map(m), ?e]
  defp enc_for_infohash(m) when is_map(m), do: :erlang.iolist_to_binary([?d, sort_map(m), ?e])
  defp decode_value(data), do: decode_value(data, 0)
  defp decode_value(_data, depth) when depth > @max_key_nesting,
    do: throw({:error, :nesting_overflow})
  defp decode_value(<<?i, ?0, ?e, rest::binary>>, _depth), do: {@explicit_zero, rest}
  defp decode_value(<<?i, ?0, _r::binary>>, _depth), do: throw({:error, :bad_zero})
  defp decode_value(<<?i, ?-, rest::binary>>, _depth), do: parse_negative_int(rest, 0, 0)
  defp decode_value(<<?i, rest::binary>>, _depth), do: parse_positive_int(rest, 0, 0)
  defp decode_value(<<?l, rest::binary>>, depth), do: decode_list(rest, [], depth + 1)
  defp decode_value(<<?d, rest::binary>>, depth), do: decode_dict(rest, %{}, depth + 1)
  defp decode_value(<<d, _r::binary>> = b, _depth) when digit?(d), do: parse_string(b, 0, 0)
  defp decode_value(_malformed, _depth), do: throw({:error, :malformed_bencode})
  defp decode_list(<<?e, rest::binary>>, acc, _depth), do: {Enum.reverse(acc), rest}
  defp decode_list(rest, acc, depth) do
    {val, rem} = decode_value(rest, depth)
    decode_list(rem, [val | acc], depth)
  end
  defp decode_dict(<<?e, rest::binary>>, acc, _depth), do: {acc, rest}
  defp decode_dict(rest, acc, depth) do
    {key, rem1} = decode_value(rest, depth)
    if not is_binary(key), do: throw({:error, :malformed_bencode})
    {val, rem2} = decode_value(rem1, depth)
    decode_dict(rem2, Map.put(acc, key, val), depth)
  end
  defp parse_negative_int(_r, _acc, cnt) when cnt >= @max_digits,
    do: throw({:error, :integer_overflow})
  defp parse_negative_int(<<?0, ?e, _r::binary>>, 0, 0), do: throw({:error, :bad_zero})
  defp parse_negative_int(<<?0, _r::binary>>, 0, 0), do: throw({:error, :bad_zero})
  defp parse_negative_int(<<?e, _r::binary>>, 0, 0), do: throw({:error, :empty_integer})
  defp parse_negative_int(<<?e, rest::binary>>, acc, _cnt), do: {-acc, rest}
  defp parse_negative_int(<<d, rest::binary>>, acc, cnt) when digit?(d),
    do: parse_negative_int(rest, acc * 10 + (d - ?0), cnt + 1)
  defp parse_negative_int(_r, _acc, _cnt), do: throw({:error, :bad_integer})
  defp parse_positive_int(_r, _acc, cnt) when cnt >= @max_digits,
    do: throw({:error, :integer_overflow})
  defp parse_positive_int(<<?e, _r::binary>>, 0, 0), do: throw({:error, :empty_integer})
  defp parse_positive_int(<<?e, rest::binary>>, acc, _cnt), do: {acc, rest}
  defp parse_positive_int(<<d, rest::binary>>, acc, cnt) when digit?(d),
    do: parse_positive_int(rest, acc * 10 + (d - ?0), cnt + 1)
  defp parse_positive_int(_r, _acc, _cnt), do: throw({:error, :bad_integer})
  defp parse_string(_r, _acc, cnt) when cnt >= @max_digits,
    do: throw({:error, :string_overflow})
  defp parse_string(<<?0, ?:, rest::binary>>, 0, 0), do: {"", rest}
  defp parse_string(<<?0, d, _r::binary>>, 0, 0) when digit?(d),
    do: throw({:error, :bad_string})
  defp parse_string(<<?:, rest::binary>>, len, _cnt) do
    if len > @max_message_size, do: throw({:error, :string_overflow})
    if byte_size(rest) < len, do: throw({:error, :truncated_string})
    <<str::binary-size(len), rem::binary>> = rest
    {str, rem}
  end
  defp parse_string(<<d, rest::binary>>, acc, cnt) when digit?(d),
    do: parse_string(rest, acc * 10 + (d - ?0), cnt + 1)
  defp parse_string(_r, _acc, _cnt),
    do: throw({:error, :bad_string})
  defp sort_map(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {k, v} -> [enc(k), enc(v)] end)
  end
end