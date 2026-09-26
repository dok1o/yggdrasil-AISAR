defmodule TCompactSync.Acc do
  @type t :: %__MODULE__{
          total_size: non_neg_integer(),
          file_count: non_neg_integer(),
          sizes: [non_neg_integer()],
          filenames: [String.t()],
          leaf_dirs: MapSet.t([String.t()]),
          extensions: MapSet.t(String.t())
        }
  defstruct total_size: 0,
            file_count: 0,
            sizes: [],
            filenames: [],
            leaf_dirs: MapSet.new(),
            extensions: MapSet.new()
end
defmodule TCompactSync do
  alias TCompactSync.Acc
  import Bitwise
  @moduledoc """
  Normalizes a decoded torrent info dict (single-file or multi-file)
  into one flat shape: sizes, filenames, directory names (deduped by
  full path, not by name), and extensions.
  """
  @u8_max (1 <<< 8) - 1
  @u16_max (1 <<< 16) - 1
  @u64_max (1 <<< 64) - 1
  @max_ext_len 12
  @utf_enc_flags [nil, "", "UTF-8", "utf-8", "utf8", "UTF8"]
  def build(info_dict), do: do_build(info_dict)
  defguardp digit?(d) when d in ?0..?9
  defguardp alphanum?(char) when char in ?a..?z or char in ?0..?9
  defp do_build(info_dict) do
    utf8? = Map.get(info_dict, "encoding", "") not in @utf_enc_flags
    torr_name = get_string(info_dict, "name", "", utf8?)
    tcompact_base =
      info_dict
      |> collect(torr_name, path_getter(utf8?))
      |> finalize(torr_name)
    bc_result = PFClassifierSync.classify_ext_list(tcompact_base.extensions)
    basic_categories = Map.get(bc_result, :base_fmimes, [])
    other_categories =
      Map.get(bc_result, :spec_fmimes, []) ++ Map.get(bc_result, :data_fmimes, [])
    tcompact =
      Map.merge(tcompact_base, %{
        basic_categories: basic_categories,
        other_categories: other_categories
      })
    {:ok, tcompact}
  end
  defp collect(%{"length" => len}, torr_name, _get_path) when is_integer(len) do
    add_file(%Acc{}, [torr_name], len)
  end
  defp collect(%{"files" => files}, _torr_name, get_path) when is_list(files) do
    Enum.reduce(files, %Acc{}, fn file, acc ->
      add_file(acc, get_path.(file), get_integer(file, "length", 0))
    end)
  end
  defp collect(_info_dict, _torr_name, _get_path), do: %Acc{}
  defp add_file(%Acc{} = acc, parts, size) do
    acc
    |> add_size(size)
    |> add_path(parts)
  end
  defp add_size(%Acc{} = acc, size) do
    %{
      acc
      | total_size: min(acc.total_size + size, @u64_max),
        file_count: acc.file_count + 1,
        sizes: [size | acc.sizes]
    }
  end
  defp add_path(%Acc{} = acc, []), do: acc
  defp add_path(%Acc{} = acc, parts) do
    [filename | rev_dirs] = Enum.reverse(parts)
    {base, ext} = split_fname(filename)
    %{
      acc
      | filenames: [base | acc.filenames],
        extensions: put_valid_ext(acc.extensions, ext),
        leaf_dirs: put_dir(acc.leaf_dirs, rev_dirs)
    }
  end
  defp put_dir(set, []), do: set
  defp put_dir(set, rev_dirs), do: MapSet.put(set, rev_dirs)
  defp path_getter(false) do
    fn file -> file |> get_list("path") |> clean_path() end
  end
  defp path_getter(true) do
    fn file ->
      file
      |> get_list("path.utf-8")
      |> non_empty_or(get_list(file, "path"))
      |> clean_path()
    end
  end
  defp clean_path(parts), do: Enum.map(parts, &CharsSync.safe_utf8/1)
  defp finalize(%Acc{} = acc, torr_name) do
    tree_dirs = Enum.reduce(acc.leaf_dirs, MapSet.new(), &put_ancestors(&2, tl(&1)))
    %{
      torr_name: torr_name,
      total_size: max(acc.total_size, @u64_max),
      file_count: max(acc.file_count, @u16_max),
      leaf_dir_count: max(MapSet.size(acc.leaf_dirs), @u8_max),
      sizes: Enum.reverse(acc.sizes),
      filenames_raw: Enum.reverse(acc.filenames),
      leafdirs_raw: Enum.map(acc.leaf_dirs, &hd/1),
      tree_dirs_raw: Enum.map(tree_dirs, &hd/1),
      extensions: MapSet.to_list(acc.extensions)
    }
  end
  defp put_ancestors(set, []), do: set
  defp put_ancestors(set, [_ | parent] = path) do
    case MapSet.member?(set, path) do
      true -> set
      false -> set |> MapSet.put(path) |> put_ancestors(parent)
    end
  end
  defp split_fname(filename), do: split_fname(filename, byte_size(filename) - 1)
  defp split_fname(filename, pos) when pos < 0, do: {filename, ""}
  defp split_fname(filename, pos) do
    byte = :binary.at(filename, pos)
    delimiter? = byte == ?.
    case delimiter? do
      false -> split_fname(filename, pos - 1)
      true -> finalize_split(filename, pos)
    end
  end
  defp finalize_split(filename, pos) do
    <<name::binary-size(pos), ?., ext::binary>> = filename
    {name, String.downcase(ext)}
  end
  defp put_valid_ext(set, ext) do
    case valid_ext?(ext) do
      false -> set
      true -> MapSet.put(set, ext)
    end
  end
  defp valid_ext?(ext) do
    cond do
      ext == "" -> false
      byte_size(ext) > @max_ext_len -> false
      all_digits?(ext) -> false
      true -> valid_chars?(ext)
    end
  end
  defp all_digits?(<<c, rest::binary>>) when digit?(c), do: all_digits?(rest)
  defp all_digits?(<<>>), do: true
  defp all_digits?(_), do: false
  defp valid_chars?(<<>>), do: true
  defp valid_chars?(<<c, rest::binary>>) when alphanum?(c), do: valid_chars?(rest)
  defp valid_chars?(_other), do: false
  defp get_integer(map, key, default) do
    value = Map.get(map, key)
    case is_integer(value) do
      false -> default
      true -> value
    end
  end
  defp get_list(map, key) do
    value = Map.get(map, key)
    case is_list(value) do
      false -> []
      true -> value
    end
  end
  defp get_string(map, key, default, try_utf8_keys?) do
    value =
      case try_utf8_keys? do
        false -> Map.get(map, key)
        true -> Map.get(map, "#{key}.utf-8", Map.get(map, key))
      end
    case value do
      nil -> default
      v -> CharsSync.safe_utf8(v)
    end
  end
  defp non_empty_or([], fallback), do: fallback
  defp non_empty_or(list, _fallback), do: list
end