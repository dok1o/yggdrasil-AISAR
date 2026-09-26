# torrent_compactor.exs

defmodule SimpleBencode do
  def decode(data) do
    try do
      case decode_value(data) do
        {term, <<>>} -> {:ok, term}
        {_term, _rest} -> {:error, :trailing_data}
      end
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_value(<<?i, ?0, ?e, rest::binary>>), do: {0, rest}
  defp decode_value(<<?i, ?0, _rest::binary>>), do: throw({:error, :leading_zero})
  defp decode_value(<<?i, ?-, rest::binary>>), do: parse_negative_int(rest, 0)
  defp decode_value(<<?i, rest::binary>>), do: parse_positive_int(rest, 0)
  defp decode_value(<<?l, rest::binary>>), do: decode_list(rest, [])
  defp decode_value(<<?d, rest::binary>>), do: decode_dict(rest, %{})
  defp decode_value(<<c, _rest::binary>> = bin) when c in ?0..?9, do: parse_string(bin, 0)
  defp decode_value(_malformed), do: throw({:error, :invalid_format})
  defp decode_list(<<?e, rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp decode_list(rest, acc) do
    {val, rem} = decode_value(rest)
    decode_list(rem, [val | acc])
  end

  defp decode_dict(<<?e, rest::binary>>, acc), do: {acc, rest}

  defp decode_dict(rest, acc) do
    {key, rem1} = decode_value(rest)
    if not is_binary(key), do: throw({:error, :non_binary_key})
    {val, rem2} = decode_value(rem1)
    decode_dict(rem2, Map.put(acc, key, val))
  end

  def encode(term) do
    try do
      IO.iodata_to_binary(enc(term))
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  defp enc(n) when is_integer(n), do: [?i, Integer.to_string(n), ?e]
  defp enc(s) when is_binary(s), do: [Integer.to_string(byte_size(s)), ":", s]
  defp enc(list) when is_list(list), do: [?l, Enum.map(list, &enc/1), ?e]

  defp enc(map) when is_map(map) do
    Enum.each(map, fn {k, _v} ->
      if not is_binary(k), do: throw({:error, :non_binary_dict_key})
    end)

    sorted_kv =
      map
      |> Enum.sort(fn {k1, _v1}, {k2, _v2} -> k1 < k2 end)
      |> Enum.map(fn {k, v} -> [enc(k), enc(v)] end)

    [?d, sorted_kv, ?e]
  end

  defp parse_negative_int(<<?0, ?e, _rest::binary>>, 0), do: throw({:error, :negative_zero})
  defp parse_negative_int(<<?0, _rest::binary>>, 0), do: throw({:error, :leading_zero})
  defp parse_negative_int(<<?e, _rest::binary>>, 0), do: throw({:error, :empty_integer})
  defp parse_negative_int(<<?e, rest::binary>>, acc), do: {-acc, rest}

  defp parse_negative_int(<<digit, rest::binary>>, acc) when digit in ?0..?9,
    do: parse_negative_int(rest, acc * 10 + (digit - ?0))

  defp parse_negative_int(_rest, _acc), do: throw({:error, :bad_integer})
  defp parse_positive_int(<<?e, _rest::binary>>, 0), do: throw({:error, :empty_integer})
  defp parse_positive_int(<<?e, rest::binary>>, acc), do: {acc, rest}

  defp parse_positive_int(<<digit, rest::binary>>, acc) when digit >= ?0 and digit <= ?9,
    do: parse_positive_int(rest, acc * 10 + (digit - ?0))

  defp parse_positive_int(_rest, _acc), do: throw({:error, :bad_integer})
  defp parse_string(<<?0, ?:, rest::binary>>, 0), do: {"", rest}
  defp parse_string(<<?0, _rest::binary>>, 0), do: throw({:error, :leading_zero_in_string_length})

  defp parse_string(<<?:, rest::binary>>, len) do
    if byte_size(rest) < len, do: throw({:error, :truncated_string})
    <<str::binary-size(len), rem::binary>> = rest
    {str, rem}
  end

  defp parse_string(<<digit, rest::binary>>, acc) when digit >= ?0 and digit <= ?9,
    do: parse_string(rest, acc * 10 + (digit - ?0))

  defp parse_string(_rest, _acc),
    do: throw({:error, :invalid_string_len})
end

defmodule SimpleJson do
  def encode!(term), do: IO.iodata_to_binary(enc(term))

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(n) when is_integer(n), do: Integer.to_string(n)
  defp enc(f) when is_float(f), do: Float.to_string(f)
  defp enc(a) when is_atom(a), do: enc(Atom.to_string(a))
  defp enc(s) when is_binary(s), do: [?", escape(s, []), ?"]
  defp enc(l) when is_list(l), do: [?[, join(l), ?]]

  defp enc(m) when is_map(m) do
    kvs =
      m
      |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
      |> Enum.map(fn {k, v} -> [enc(to_key(k)), ?:, enc(v)] end)

    [?{, Enum.intersperse(kvs, ?,), ?}]
  end

  defp join([]), do: []
  defp join(items), do: items |> Enum.map(&enc/1) |> Enum.intersperse(?,)

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
    hex = c |> Integer.to_string(16) |> String.pad_leading(4, "0")
    "\\u" <> hex
  end
end

defmodule TorrentCompactor do
  @moduledoc """
  Recursively reads .torrent files, strips bulk data (piece hashes,
  per-file checksums, padding files), nests directory paths, and
  writes a compact JSONL archive.

  Requires: `jason` hex package.

  ## Usage

      TorrentCompactor.run()
      TorrentCompactor.run("path/to/torrents", "output.jsonl")
  """

  @default_input "./torrents"
  @default_output "./torrents.jsonl"

  # ── Public ─────────────────────────────────────────────────

  def run(input \\ @default_input, output \\ @default_output) do
    paths = Path.wildcard(Path.join(input, "**/*.torrent"))
    n = length(paths)
    IO.puts("[compact] found #{n} .torrent file(s) in #{input}")

    fd = File.open!(output, [:write, :raw, :binary])

    {ok, err} =
      paths
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0}, fn {path, i}, {ok, err} ->
        if n >= 1_000 and rem(i, 1_000) == 0,
          do: IO.puts("[compact] #{i}/#{n} …")

        case process(path) do
          {:ok, entry} ->
            IO.binwrite(fd, [SimpleJson.encode!(entry), ?\n])
            {ok + 1, err}

          {:error, reason} ->
            IO.puts(:stderr, "[skip] #{Path.relative_to_cwd(path)}: #{inspect(reason)}")
            {ok, err + 1}
        end
      end)

    File.close(fd)
    IO.puts("[compact] wrote #{ok} entries (#{err} skipped) → #{output}")
    %{ok: ok, errors: err}
  end

  # ── Core ───────────────────────────────────────────────────

  defp process(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, meta} <- SimpleBencode.decode(raw),
         %{"info" => %{} = info} <- meta,
         {:ok, info_bin} <- extract_info_raw(raw) do
      ih = :crypto.hash(:sha, info_bin) |> Base.encode16(case: :lower)
      name = safe(info["name.utf-8"] || info["name"]) || "unknown"

      entry =
        %{"infohash" => ih, "name" => name}
        |> attach_files(info)
        |> opt("piece_length", info["piece length"])
        |> opt("private", if(info["private"] == 1, do: true))
        |> opt("source", safe(info["source"]))
        |> opt("comment", safe(meta["comment"]))
        |> opt("created_by", safe(meta["created by"]))
        |> opt("creation_date", meta["creation date"])
        |> attach_trackers(meta)

      {:ok, entry}
    else
      {:error, _} = e -> e
      _ -> {:error, :bad_torrent}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Files ──────────────────────────────────────────────────

  defp attach_files(entry, %{"files" => files}) when is_list(files) do
    {tree, total, cnt} =
      Enum.reduce(files, {%{}, 0, 0}, fn f, {t, s, c} ->
        if pad?(f) do
          {t, s, c}
        else
          len = f["length"] || 0
          segs = (f["path.utf-8"] || f["path"] || []) |> Enum.map(&safe/1)
          {nest(t, segs, len), s + len, c + 1}
        end
      end)

    entry
    |> Map.put("size", total)
    |> Map.put("file_count", cnt)
    |> Map.put("files", tree)
  end

  defp attach_files(entry, %{"length" => len}),
    do: Map.put(entry, "size", len)

  defp attach_files(entry, _), do: entry

  defp nest(tree, [name], sz), do: Map.put(tree, name, sz)

  defp nest(tree, [dir | rest], sz),
    do: Map.update(tree, dir, nest(%{}, rest, sz), &nest(&1, rest, sz))

  defp nest(tree, [], _), do: tree

  # ── Padding detection ──────────────────────────────────────

  defp pad?(f), do: pad_attr?(f) or pad_path?(f)

  defp pad_attr?(%{"attr" => a}) when is_binary(a), do: String.contains?(a, "p")
  defp pad_attr?(_), do: false

  defp pad_path?(%{"path" => [".pad" | _]}), do: true

  defp pad_path?(%{"path" => p}) when is_list(p) do
    case List.last(p) do
      n when is_binary(n) -> String.starts_with?(n, "_____padding")
      _ -> false
    end
  end

  defp pad_path?(_), do: false

  # ── Trackers ───────────────────────────────────────────────

  defp attach_trackers(entry, meta) do
    al =
      case meta["announce-list"] do
        t when is_list(t) -> t |> List.flatten() |> Enum.filter(&is_binary/1)
        _ -> []
      end

    a =
      case meta["announce"] do
        u when is_binary(u) -> [u]
        _ -> []
      end

    urls = Enum.uniq(al ++ a)
    if urls == [], do: entry, else: Map.put(entry, "trackers", urls)
  end

  # ── Infohash: slice raw bencoded "info" value ──────────────
  #    We extract the original bytes (not re-encoded) so the
  #    SHA-1 matches regardless of key ordering in the file.

  defp extract_info_raw(<<"d", rest::binary>> = orig), do: find_key(rest, orig)
  defp extract_info_raw(_), do: {:error, :not_a_dict}

  defp find_key(<<"e", _::binary>>, _orig), do: {:error, :no_info_key}

  defp find_key(data, orig) do
    with {:ok, key, after_key} <- SimpleBencode.decode_with_rest(data) do
      if key == "info" do
        offset = byte_size(orig) - byte_size(after_key)

        with {:ok, _, after_val} <- SimpleBencode.decode_with_rest(after_key) do
          len = byte_size(after_key) - byte_size(after_val)
          {:ok, binary_part(orig, offset, len)}
        end
      else
        with {:ok, _, after_val} <- SimpleBencode.decode_with_rest(after_key),
             do: find_key(after_val, orig)
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────

  defp opt(m, _, nil), do: m
  defp opt(m, _, ""), do: m
  defp opt(m, k, v), do: Map.put(m, k, v)

  defp safe(nil), do: nil

  defp safe(b) when is_binary(b),
    do: if(String.valid?(b), do: b, else: scrub(b, []))

  defp safe(x), do: inspect(x)

  defp scrub(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp scrub(<<cp::utf8, rest::binary>>, acc), do: scrub(rest, [<<cp::utf8>> | acc])
  defp scrub(<<_, rest::binary>>, acc), do: scrub(rest, ["\uFFFD" | acc])
end

# input, output
TorrentCompactor.run()
