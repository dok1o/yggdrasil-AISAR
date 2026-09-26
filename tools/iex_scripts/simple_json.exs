defmodule SimpleJson do
  def encode!(term), do: IO.iodata_to_binary(enc(term))

  def decode(json) when is_binary(json) do
    case parse_value(json, 0) do
      {:ok, value, _rest} -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  def decode!(json) when is_binary(json) do
    case decode(json) do
      {:ok, value} -> value
      {:error, reason} -> raise "JSON decode error: #{reason}"
    end
  end

  # Encoding functions (unchanged)
  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(n) when is_integer(n), do: Integer.to_string(n)

  defp enc(f) when is_float(f) do
    :io_lib.format("~g", [f])
    |> IO.iodata_to_binary()
  end

  defp enc(a) when is_atom(a), do: enc(Atom.to_string(a))
  defp enc(s) when is_binary(s), do: [?", escape(s, []), ?"]
  defp enc(l) when is_list(l), do: [?[, join(l), ?]]

  defp enc(m) when is_map(m) do
    kvs =
      m
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [enc(to_key(k)), ?:, enc(v)] end)

    [?{, Enum.intersperse(kvs, ?,), ?}]
  end

  defp join([]), do: []

  defp join(items) do
    items
    |> Enum.map(&enc/1)
    |> Enum.intersperse(?,)
  end

  defp to_key(k) when is_binary(k), do: k
  defp to_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_key(k), do: inspect(k)

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?\", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])

  defp escape(<<c, rest::binary>>, acc) when c < 0x20,
    do: escape(rest, [encode_unicode(c) | acc])

  defp escape(bin, acc) do
    {safe, rest} = eat_safe(bin, 0)
    escape(rest, [safe | acc])
  end

  defp eat_safe(bin, n) when n < byte_size(bin) do
    case :binary.at(bin, n) do
      c when c in [?", ?\\, ?\n, ?\r, ?\t, ?\b, ?\f] -> split_at(bin, n)
      c when c < 0x20 -> split_at(bin, n)
      _ -> eat_safe(bin, n + 1)
    end
  end

  defp eat_safe(bin, _n), do: {bin, <<>>}

  defp split_at(bin, 0), do: {<<>>, bin}

  defp split_at(bin, n) do
    <<head::binary-size(n), tail::binary>> = bin
    {head, tail}
  end

  defp encode_unicode(c) do
    hex =
      c
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")

    "\\u" <> hex
  end

  # Decoding functions
  defp parse_value(json, pos) do
    pos = skip_whitespace(json, pos)

    if pos >= byte_size(json) do
      {:error, "unexpected end of input"}
    else
      case :binary.at(json, pos) do
        ?{ -> parse_object(json, pos + 1)
        ?[ -> parse_array(json, pos + 1)
        ?" -> parse_string(json, pos + 1)
        ?t -> parse_literal(json, pos, "true", true)
        ?f -> parse_literal(json, pos, "false", false)
        ?n -> parse_literal(json, pos, "null", nil)
        c when c in [?-, ?0, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9] -> parse_number(json, pos)
        _ -> {:error, "unexpected character at position #{pos}"}
      end
    end
  end

  defp parse_object(json, pos) do
    pos = skip_whitespace(json, pos)

    if pos < byte_size(json) and :binary.at(json, pos) == ?} do
      {:ok, %{}, pos + 1}
    else
      parse_object_members(json, pos, %{})
    end
  end

  defp parse_object_members(json, pos, acc) do
    pos = skip_whitespace(json, pos)

    with {:ok, key, pos} <- parse_string(json, pos + 1),
         pos <- skip_whitespace(json, pos),
         true <- pos < byte_size(json) and :binary.at(json, pos) == ?:,
         {:ok, value, pos} <- parse_value(json, pos + 1) do
      acc = Map.put(acc, key, value)
      pos = skip_whitespace(json, pos)

      cond do
        pos >= byte_size(json) ->
          {:error, "unexpected end of input in object"}

        :binary.at(json, pos) == ?} ->
          {:ok, acc, pos + 1}

        :binary.at(json, pos) == ?, ->
          parse_object_members(json, pos + 1, acc)

        true ->
          {:error, "expected ',' or '}' in object"}
      end
    else
      {:error, _} = error -> error
      false -> {:error, "expected ':' in object"}
    end
  end

  defp parse_array(json, pos) do
    pos = skip_whitespace(json, pos)

    if pos < byte_size(json) and :binary.at(json, pos) == ?] do
      {:ok, [], pos + 1}
    else
      parse_array_elements(json, pos, [])
    end
  end

  defp parse_array_elements(json, pos, acc) do
    with {:ok, value, pos} <- parse_value(json, pos) do
      acc = [value | acc]
      pos = skip_whitespace(json, pos)

      cond do
        pos >= byte_size(json) ->
          {:error, "unexpected end of input in array"}

        :binary.at(json, pos) == ?] ->
          {:ok, Enum.reverse(acc), pos + 1}

        :binary.at(json, pos) == ?, ->
          parse_array_elements(json, pos + 1, acc)

        true ->
          {:error, "expected ',' or ']' in array"}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp parse_string(json, pos) do
    parse_string_chars(json, pos, [])
  end

  defp parse_string_chars(json, pos, acc) when pos < byte_size(json) do
    case :binary.at(json, pos) do
      ?" ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc)), pos + 1}

      ?\\ ->
        if pos + 1 < byte_size(json) do
          case :binary.at(json, pos + 1) do
            ?" -> parse_string_chars(json, pos + 2, [?" | acc])
            ?\\ -> parse_string_chars(json, pos + 2, [?\\ | acc])
            ?/ -> parse_string_chars(json, pos + 2, [?/ | acc])
            ?b -> parse_string_chars(json, pos + 2, [?\b | acc])
            ?f -> parse_string_chars(json, pos + 2, [?\f | acc])
            ?n -> parse_string_chars(json, pos + 2, [?\n | acc])
            ?r -> parse_string_chars(json, pos + 2, [?\r | acc])
            ?t -> parse_string_chars(json, pos + 2, [?\t | acc])
            ?u -> parse_unicode_escape(json, pos + 2, acc)
            _ -> {:error, "invalid escape sequence"}
          end
        else
          {:error, "unexpected end of input in string"}
        end

      c ->
        parse_string_chars(json, pos + 1, [c | acc])
    end
  end

  defp parse_string_chars(_json, _pos, _acc) do
    {:error, "unexpected end of input in string"}
  end

  defp parse_unicode_escape(json, pos, acc) do
    if pos + 3 < byte_size(json) do
      hex = binary_part(json, pos, 4)

      case Integer.parse(hex, 16) do
        {codepoint, ""} ->
          char = <<codepoint::utf8>>
          parse_string_chars(json, pos + 4, [char | acc])

        _ ->
          {:error, "invalid unicode escape"}
      end
    else
      {:error, "unexpected end of input in unicode escape"}
    end
  end

  defp parse_number(json, pos) do
    {num_str, new_pos} = extract_number(json, pos, [])

    case parse_number_value(num_str) do
      {:ok, value} -> {:ok, value, new_pos}
      {:error, _} = error -> error
    end
  end

  defp extract_number(json, pos, acc) when pos < byte_size(json) do
    c = :binary.at(json, pos)

    if c in [?-, ?+, ?., ?e, ?E] or (c >= ?0 and c <= ?9) do
      extract_number(json, pos + 1, [c | acc])
    else
      {IO.iodata_to_binary(Enum.reverse(acc)), pos}
    end
  end

  defp extract_number(_json, pos, acc) do
    {IO.iodata_to_binary(Enum.reverse(acc)), pos}
  end

  defp parse_number_value(str) do
    cond do
      String.contains?(str, ".") or String.contains?(str, "e") or String.contains?(str, "E") ->
        case Float.parse(str) do
          {float, ""} -> {:ok, float}
          _ -> {:error, "invalid number"}
        end

      true ->
        case Integer.parse(str) do
          {int, ""} -> {:ok, int}
          _ -> {:error, "invalid number"}
        end
    end
  end

  defp parse_literal(json, pos, literal, value) do
    len = byte_size(literal)

    if pos + len <= byte_size(json) and binary_part(json, pos, len) == literal do
      {:ok, value, pos + len}
    else
      {:error, "expected '#{literal}'"}
    end
  end

  defp skip_whitespace(json, pos) when pos < byte_size(json) do
    case :binary.at(json, pos) do
      c when c in [?\s, ?\t, ?\n, ?\r] -> skip_whitespace(json, pos + 1)
      _ -> pos
    end
  end

  defp skip_whitespace(_json, pos), do: pos
end
