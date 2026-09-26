defmodule UTMFConstructorSync do
  import Bitwise
  @type input :: %{
          total_size: non_neg_integer(),
          fr_bitmap: <<_::24>>,
          mime_bitmap: <<_::16>>,
          token_flags: <<_::8>>,
          file_count: non_neg_integer(),
          leaf_dir_count: non_neg_integer(),
          piece_size_index: <<_::8>>,
          freq_size_index: <<_::8>>,
          bloom: <<_::1024>>,
          simhash: <<_::64>>
        }
  @type ih :: <<_::160>>
  @type utmf_v1_part :: <<_::1248>>
  @type utmf_v1_tuple :: {ih(), utmf_v1_part()}
  @type utmf_v1_bin() :: <<_::1408>>
  @type result :: utmf_v1_bin()
  @reserved_byte 0x00
  @u8_max (1 <<< 8) - 1
  @u16_max (1 <<< 16) - 1
  @kb 1_024
  @mb 1_024 * @kb
  @gb 1_024 * @mb
  @filesize_ranges [
    {1 * @kb, "0 - 1 KB"},
    {4 * @kb, "1 - 4 KB"},
    {16 * @kb, "4 - 16 KB"},
    {32 * @kb, "16 - 32 KB"},
    {64 * @kb, "32 - 64 KB"},
    {128 * @kb, "64 - 128 KB"},
    {256 * @kb, "128 - 256 KB"},
    {512 * @kb, "256 - 512 KB"},
    {768 * @kb, "512 - 768 KB"},
    {1 * @mb, "768 KB - 1 MB"},
    {2 * @mb, "1 - 2 MB"},
    {4 * @mb, "2 - 4 MB"},
    {8 * @mb, "4 - 8 MB"},
    {12 * @mb, "8 - 12 MB"},
    {16 * @mb, "12 - 16 MB"},
    {32 * @mb, "16 - 32 MB"},
    {64 * @mb, "32 - 64 MB"},
    {128 * @mb, "64 - 128 MB"},
    {256 * @mb, "128 - 256 MB"},
    {512 * @mb, "256 - 512 MB"},
    {1 * @gb, "512 MB - 1 GB"},
    {2 * @gb, "1 - 2 GB"},
    {4 * @gb, "2 - 4 GB"},
    {:infinity, "4 GB+"}
  ]
  @common_plen_exponent_range 14..26
  @piece_size_table (for {exp, idx} <- Enum.with_index(@common_plen_exponent_range, 1),
                         into: %{} do
                       {1 <<< exp, idx}
                     end)
  def build(
        ih,
        utmf_v1_part
      ) do
    utmf_v1 = <<ih::binary-size(20), utmf_v1_part::binary-size(156)>>
    {:ok, utmf_v1}
  end
  def construct(ih, extracted, cutoff_freqs, info_dict, flags) do
    filesizes_bitmap = build_fr_bitmap(extracted.sizes)
    piece_len_idx = Map.get(@piece_size_table, get_integer(info_dict, "piece length", 0), 0)
    token_flags_byte = 0
    token_flags_byte = if flags.has_long?, do: token_flags_byte ||| 0x80, else: token_flags_byte
    token_flags_byte = if flags.has_en?, do: token_flags_byte ||| 0x40, else: token_flags_byte
    token_flags_byte =
      if flags.dominant_en?, do: token_flags_byte ||| 0x20, else: token_flags_byte
    token_flags_byte = if flags.has_other?, do: token_flags_byte ||| 0x10, else: token_flags_byte
    token_flags_byte = if flags.has_ry_num?, do: token_flags_byte ||| 0x08, else: token_flags_byte
    token_flags_byte =
      if flags.has_more_tokens?, do: token_flags_byte ||| 0x04, else: token_flags_byte
    bloom_binary = build_bloom_filter(Enum.map(cutoff_freqs, &elem(&1, 0)))
    {:ok, utmf_part} =
      UTMFConstructorSync.build_part(
        extracted.total_size,
        filesizes_bitmap,
        <<0, 0>>,
        <<token_flags_byte::8>>,
        min(extracted.file_count, @u16_max),
        min(extracted.leaf_dir_count, @u8_max),
        piece_len_idx,
        0,
        bloom_binary,
        <<0::64>>
      )
    {:ok, utmf_v1} = UTMFConstructorSync.build(ih, utmf_part)
    result = utmf_v1
    {:ok, result}
  end
  def build_part(
        total_size,
        filesizes_bitmap,
        mime_bitmap,
        token_flags,
        file_count,
        leaf_dir_count,
        piece_size_index,
        freq_size_index,
        bloom,
        simhash
      ) do
    utmf_v1_part = <<
      total_size::unsigned-big-64,
      filesizes_bitmap::binary-size(3),
      mime_bitmap::binary-size(2),
      token_flags::binary-size(1),
      file_count::unsigned-big-16,
      leaf_dir_count::unsigned-big-8,
      piece_size_index::unsigned-big-8,
      freq_size_index::unsigned-big-8,
      @reserved_byte::8,
      bloom::binary-size(128),
      simhash::binary-size(8)
    >>
    {:ok, utmf_v1_part}
  end
  defp build_fr_bitmap(sizes) do
    bitmask =
      Enum.reduce(sizes, 0, fn size, acc ->
        bit = find_range_index(size)
        acc ||| 1 <<< bit
      end)
    <<bitmask::24-little>>
  end
  defp find_range_index(size) do
    @filesize_ranges
    |> Enum.with_index()
    |> Enum.find_value(fn {{limit, _label}, idx} ->
      case limit do
        :infinity -> idx
        threshold when size < threshold -> idx
        _ -> nil
      end
    end)
  end
  defp build_bloom_filter(words) do
    bits =
      Enum.reduce(words, 0, fn word, acc ->
        idx1 = :erlang.phash2({word, 1}, 1024)
        idx2 = :erlang.phash2({word, 2}, 1024)
        idx3 = :erlang.phash2({word, 3}, 1024)
        acc |||
          1 <<< idx1 |||
          1 <<< idx2 |||
          1 <<< idx3
      end)
    <<bits::1024>>
  end
  defp get_integer(map, key, default) do
    value = Map.get(map, key)
    case is_integer(value) do
      false -> default
      true -> value
    end
  end
end