# utmc_encoder.exs

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

  defp parse_string(_rest, _acc), do: throw({:error, :invalid_string_len})
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
      _any -> eat_safe(bin, n + 1)
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
end

# ============================================================================
# Module 1: EncoderStatic — all constants, ranges, MIME classification
# ============================================================================
defmodule EncoderStatic do
  import Bitwise

  @moduledoc """
  All constants for utmc encoding: filesize ranges, MIME extension classification,
  piece size enums, date encoding, bloom/simhash parameters.
  """

  # --- Size constants ---
  @kb 1_024
  @mb 1_024 * 1_024
  @gb 1_024 * 1_024 * 1_024

  def kb, do: @kb
  def mb, do: @mb
  def gb, do: @gb

  # --- Filesize ranges (24 ranges = 24 bits = 3 bytes) ---
  # Each tuple: {upper_bound_exclusive, label}
  # Last entry has :infinity upper bound
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

  def filesize_ranges, do: @filesize_ranges

  @doc "Returns the 0-based range index for a file size in bytes."
  def filesize_range_index(size) when is_integer(size) and size >= 0 do
    @filesize_ranges
    |> Enum.with_index()
    |> Enum.find_value(fn
      {{:infinity, _}, idx} -> idx
      {{upper, _}, idx} -> if size < upper, do: idx, else: nil
    end)
  end

  # --- Piece size enum ---
  # 14 standard values: 2^14 to 2^26, plus sentinel 0xFF for non-standard
  @piece_sizes [
    # 2^14
    {16_384, 0},
    # 2^15
    {32_768, 1},
    # 2^16
    {65_536, 2},
    # 2^17
    {131_072, 3},
    # 2^18
    {262_144, 4},
    # 2^19
    {524_288, 5},
    # 2^20
    {1_048_576, 6},
    # 2^21
    {2_097_152, 7},
    # 2^22
    {4_194_304, 8},
    # 2^23
    {8_388_608, 9},
    # 2^24
    {16_777_216, 10},
    # 2^25
    {33_554_432, 11},
    # 2^26
    {67_108_864, 12}
  ]
  @piece_size_nonstandard 0xFF

  def piece_size_enum(piece_length) do
    case Enum.find(@piece_sizes, fn {sz, _} -> sz == piece_length end) do
      {_, idx} -> idx
      nil -> @piece_size_nonstandard
    end
  end

  # --- Date encoding ---
  # Quarter counter from Q1 2000. Sentinel values:
  @date_no_date 253
  @date_earlier 254
  @date_later 255
  @date_epoch_year 2000
  # Q1 2000 = index 0
  @date_epoch_quarter 1

  def date_no_date, do: @date_no_date
  def date_earlier, do: @date_earlier
  def date_later, do: @date_later

  @doc "Encode a unix timestamp to quarter index byte."
  def encode_date(nil), do: @date_no_date

  def encode_date(unix_ts) when is_integer(unix_ts) do
    # Convert to {{year, month, day}, _time}
    secs = unix_ts
    # epoch offset
    dt = :calendar.gregorian_seconds_to_datetime(secs + 62_167_219_200)
    {{year, month, _day}, _time} = dt
    # 1-4
    quarter = div(month - 1, 3) + 1
    quarter_index = (year - @date_epoch_year) * 4 + (quarter - @date_epoch_quarter)

    cond do
      quarter_index < 0 -> @date_earlier
      quarter_index > 252 -> @date_later
      true -> quarter_index
    end
  end

  # --- MIME / extension classification ---
  # Returns a list of category atoms for a given lowercase extension

  # 4.1a base bits (12 bits): audio, image, anim_image, video, text_article, book_comic,
  #   archive, reserved1, reserved2, reserved3, multitype, any_base
  # 4.1b exploration bits (4 bits): links, mdf_file, ptr, reserved4
  # 4.2 lingual script bits (8 bits): cyrillic, non_english_latin, cjk_jp, cjk_zh, cjk_k,
  #   no_latin_cyr_cjk, reserved5, reserved6
  # 4.3 remaining bits (32 bits): spec_audio, playlist, spec_image, spec_video, disc_video,
  #   spec_text, subtitles, spec_arch, exec_win, exec_linux, exec_mac,
  #   ai_weights, ai_lora, mount_disc, consoles,
  #   spec_exec, exec_firmware, exec_mobile, source_code, dev_web_project,
  #   dev_config, binary_file,
  #   data_creative, data_software_assets, data_game_assets, data_database,
  #   data_json, data_xml, data_tabular, data_3d_model, data_scientific, data_geospatial
  # (some bits compressed to fit 32)
  # 4.4 (8 bits): data_font, reserved7, noise_encryption, noise_bitcomet, noise_temp,
  #   noise_checksum, unknown_mime, tokenization_error

  # todo: ai lora filename pattern
  # todo: disambiguate .ts/.mdf/.rom by size
  # todo: check: "But some modern torrents use 2^27 (134,217,728) or even 2^28"
  # todo: change simhash to cross-torrent, batch by batch
  # todo: only keep ext ".abc" as a token if torrent fell into "unknown" fmime bucket

  # We'll define a flat ordered list of all 64 bit names for the fmimes bitmap
  @fmime_bits [
    # base (12)
    :audio,
    :image,
    :anim_image,
    :video,
    :text_article,
    :book_comic,
    :archive,
    :base_res1,
    :base_res2,
    :base_res3,
    :multitype,
    :any_base,
    # exploration (4)
    :links,
    :mdf_file,
    :ptr,
    :exploration_reserved,
    # lingual (8)
    :cyrillic,
    :non_english_latin,
    :cjk_jp,
    :cjk_zh,
    :cjk_k,
    :no_latin_cyr_cjk,
    :lingual_res1,
    :lingual_res2,
    # specialized (23)
    :spec_audio,
    :playlist,
    :spec_image,
    :spec_video,
    :disc_video,
    :spec_text,
    :subtitles,
    :spec_arch,
    :exec_win,
    :exec_linux,
    :exec_mac,
    :ai_weights,
    :ai_lora,
    :mount_disc,
    :consoles,
    :spec_exec,
    :exec_firmware,
    :exec_mobile,
    :source_code,
    :dev_web_project,
    :dev_config,
    :binary_file,
    :spec_res1,
    # data (11)
    :data_creative,
    :data_software_assets,
    :data_game_assets,
    :data_database,
    :data_json,
    :data_xml,
    :data_tabular,
    :data_3d_model,
    :data_scientific,
    :data_geospatial,
    :data_font,
    # remaining (6)
    :noise_encryption,
    :noise_bitcomet,
    :noise_temp,
    :noise_checksum,
    :unknown_mime,
    :tokenization_error
  ]

  def fmime_bits, do: @fmime_bits
  # should be 64
  def fmime_bit_count, do: length(@fmime_bits)

  def fmime_bit_index(atom) do
    Enum.find_index(@fmime_bits, &(&1 == atom))
  end

  @doc "Build a 64-bit (8-byte) integer from a MapSet of category atoms."
  def fmime_bitmap(categories) when is_map(categories) or is_list(categories) do
    cat_set = if is_list(categories), do: MapSet.new(categories), else: categories

    Enum.reduce(@fmime_bits |> Enum.with_index(), 0, fn {bit_name, idx}, acc ->
      if MapSet.member?(cat_set, bit_name) do
        # bit 0 is MSB of the 8-byte big-endian
        acc ||| 1 <<< (63 - idx)
      else
        acc
      end
    end)
  end

  # --- Extension -> categories mapping ---
  # Returns list of category atoms
  @ext_map %{
    # audio (base)
    "mp3" => [:audio],
    "ogg" => [:audio],
    "wav" => [:audio],
    "flac" => [:audio],
    "m4a" => [:audio],
    "aac" => [:audio],
    "wma" => [:audio],
    "opus" => [:audio],
    # image (base)
    "jpg" => [:image],
    "jpeg" => [:image],
    "png" => [:image],
    "webp" => [:image],
    "avif" => [:image],
    # anim_image (base)
    "apng" => [:anim_image],
    "gif" => [:anim_image],
    "ugoira" => [:anim_image],
    # video (base)
    "mkv" => [:video],
    "mp4" => [:video],
    "mp2" => [:video],
    "mpg" => [:video],
    "mpeg" => [:video],
    "avi" => [:video],
    "mov" => [:video],
    "wmv" => [:video],
    "flv" => [:video],
    "webm" => [:video],
    "m4v" => [:video],
    "3gp" => [:video],
    # text/article (base)
    "txt" => [:text_article],
    "md" => [:text_article],
    "nfo" => [:text_article],
    "doc" => [:text_article],
    "docx" => [:text_article],
    "odt" => [:text_article],
    "rtf" => [:text_article],
    "csv" => [:text_article],
    "htm" => [:text_article],
    "html" => [:text_article],
    "mhtml" => [:text_article],
    # book/comic (base)
    "pdf" => [:book_comic],
    "cbz" => [:book_comic],
    "cbr" => [:book_comic],
    "cb7" => [:book_comic],
    "cba" => [:book_comic],
    "cbt" => [:book_comic],
    "fb2" => [:book_comic],
    "epub" => [:book_comic],
    "mobi" => [:book_comic],
    # archive (base)
    "zip" => [:archive],
    "gz" => [:archive],
    "gzip" => [:archive],
    "rar" => [:archive],
    "7z" => [:archive],
    "tar" => [:archive],
    # links (exploration)
    "torrent" => [:links],
    "url" => [:links],
    "webloc" => [:links],
    # mdf_file (exploration) — note: .mdf by size handled in encoder
    "mdf" => [:mdf_file],
    # spec_audio
    "fm" => [:audio, :spec_audio],
    "oga" => [:audio, :spec_audio],
    "aif" => [:audio, :spec_audio],
    "aiff" => [:audio, :spec_audio],
    "ape" => [:audio, :spec_audio],
    "wave" => [:audio, :spec_audio],
    "wv" => [:audio, :spec_audio],
    "tak" => [:audio, :spec_audio],
    "dsf" => [:audio, :spec_audio],
    "dff" => [:audio, :spec_audio],
    "it" => [:audio, :spec_audio],
    "s3m" => [:audio, :spec_audio],
    "mptm" => [:audio, :spec_audio],
    "mid" => [:audio, :spec_audio],
    "midi" => [:audio, :spec_audio],
    "kar" => [:audio, :spec_audio],
    "rmi" => [:audio, :spec_audio],
    "m4b" => [:audio, :spec_audio],
    "aa" => [:audio, :spec_audio],
    "aax" => [:audio, :spec_audio],
    "cdg" => [:audio, :spec_audio],
    "lrc" => [:audio, :spec_audio],
    "mod" => [:audio, :spec_audio],
    "xm" => [:audio, :spec_audio],
    "ra" => [:audio, :spec_audio],
    "tta" => [:audio, :spec_audio],
    # playlist
    "m3u" => [:playlist],
    "m3u8" => [:playlist],
    "pls" => [:playlist],
    "xspf" => [:playlist],
    "asx" => [:playlist],
    "cue" => [:playlist],
    # spec_image
    "bmp" => [:image, :spec_image],
    "heic" => [:image, :spec_image],
    "heif" => [:image, :spec_image],
    "jxl" => [:image, :spec_image],
    "qoi" => [:image, :spec_image],
    "tif" => [:image, :spec_image],
    "tiff" => [:image, :spec_image],
    "cr2" => [:image, :spec_image],
    "cr3" => [:image, :spec_image],
    "nef" => [:image, :spec_image],
    "arw" => [:image, :spec_image],
    "dng" => [:image, :spec_image],
    "orf" => [:image, :spec_image],
    "rw2" => [:image, :spec_image],
    "raf" => [:image, :spec_image],
    "pef" => [:image, :spec_image],
    "srw" => [:image, :spec_image],
    "eps" => [:image, :spec_image],
    "cdr" => [:image, :spec_image],
    "wmf" => [:image, :spec_image],
    "emf" => [:image, :spec_image],
    "psb" => [:image, :spec_image],
    "xcf" => [:image, :spec_image],
    "kra" => [:image, :spec_image],
    "afphoto" => [:image, :spec_image],
    "ktx" => [:image, :spec_image],
    "ktx2" => [:image, :spec_image],
    "exr" => [:image, :spec_image],
    "hdr" => [:image, :spec_image],
    "svg" => [:image, :spec_image],
    "ai" => [:image, :spec_image],
    "dds" => [:image, :spec_image],
    "tga" => [:image, :spec_image],
    "psd" => [:image, :spec_image],
    # spec_video
    "ogm" => [:video, :spec_video],
    "ogv" => [:video, :spec_video],
    "rm" => [:video, :spec_video],
    "rmvb" => [:video, :spec_video],
    "asf" => [:video, :spec_video],
    "swf" => [:video, :spec_video],
    "qt" => [:video, :spec_video],
    "rv" => [:video, :spec_video],
    "av1" => [:video, :spec_video],
    # disc_video
    "vob" => [:video, :disc_video],
    "m2ts" => [:video, :disc_video],
    # ts — by size: handled in encoder; default to disc_video
    "ts" => [:video, :disc_video],
    # spec_text
    "azw" => [:book_comic, :spec_text],
    "azw3" => [:book_comic, :spec_text],
    "chm" => [:spec_text],
    "hlp" => [:spec_text],
    "log" => [:spec_text],
    "diz" => [:spec_text],
    "djvu" => [:book_comic, :spec_text],
    "djv" => [:book_comic, :spec_text],
    "pages" => [:spec_text],
    "wpd" => [:spec_text],
    "asc" => [:spec_text],
    "ppt" => [:spec_text],
    "pptx" => [:spec_text],
    "odp" => [:spec_text],
    "key" => [:spec_text],
    "tex" => [:spec_text],
    "bib" => [:spec_text],
    "sty" => [:spec_text],
    "cls" => [:spec_text],
    "lytx" => [:spec_text],
    "indd" => [:spec_text],
    "qxp" => [:spec_text],
    "pub" => [:spec_text],
    "sla" => [:spec_text],
    "xls" => [:spec_text],
    "xlsx" => [:spec_text],
    # subtitles
    "srt" => [:subtitles],
    "ass" => [:subtitles],
    "ssa" => [:subtitles],
    "vtt" => [:subtitles],
    "smi" => [:subtitles],
    "sub" => [:subtitles],
    "sup" => [:subtitles],
    "pgs" => [:subtitles],
    # spec_arch
    "bz2" => [:archive, :spec_arch],
    "zst" => [:archive, :spec_arch],
    "xz" => [:archive, :spec_arch],
    "001" => [:archive, :spec_arch],
    "lz4" => [:archive, :spec_arch],
    "br" => [:archive, :spec_arch],
    # ai_weights
    "gguf" => [:ai_weights],
    "safetensors" => [:ai_weights],
    "pt" => [:ai_weights],
    "pth" => [:ai_weights],
    "ckpt" => [:ai_weights],
    "onnx" => [:ai_weights],
    "h5" => [:ai_weights],
    "hdf5" => [:ai_weights],
    "pb" => [:ai_weights],
    "tflite" => [:ai_weights],
    # mount/disc
    "iso" => [:mount_disc],
    "mds" => [:mount_disc],
    "nrg" => [:mount_disc],
    "ccd" => [:mount_disc],
    "img" => [:mount_disc],
    "cdi" => [:mount_disc],
    "wim" => [:mount_disc],
    "esd" => [:mount_disc],
    "swm" => [:mount_disc],
    "ima" => [:mount_disc],
    "fdi" => [:mount_disc],
    "vmdk" => [:mount_disc],
    "vdi" => [:mount_disc],
    "wasm" => [:mount_disc],
    # consoles
    "nes" => [:consoles],
    "smc" => [:consoles],
    "sfc" => [:consoles],
    "gen" => [:consoles],
    "smd" => [:consoles],
    "gb" => [:consoles],
    "gbc" => [:consoles],
    "gba" => [:consoles],
    "n64" => [:consoles],
    "nds" => [:consoles],
    "nsp" => [:consoles],
    "xci" => [:consoles],
    "pbp" => [:consoles],
    "cso" => [:consoles],
    "chd" => [:consoles],
    "psv" => [:consoles],
    "gdi" => [:consoles],
    "a26" => [:consoles],
    "pce" => [:consoles],
    "neo" => [:consoles],
    "cia" => [:consoles],
    "wad" => [:consoles],
    "wbfs" => [:consoles],
    # exec_win
    "exe" => [:exec_win],
    "msi" => [:exec_win],
    "ocx" => [:exec_win],
    # exec_linux
    "deb" => [:exec_linux],
    "rpm" => [:exec_linux],
    "appimage" => [:exec_linux],
    # exec_mac
    "dmg" => [:exec_mac],
    "app" => [:exec_mac],
    "mpkg" => [:exec_mac],
    # spec_exec
    "flatpak" => [:spec_exec],
    "flatpakref" => [:spec_exec],
    "snap" => [:spec_exec],
    "so" => [:spec_exec],
    "dll" => [:spec_exec],
    "scr" => [:spec_exec],
    "com" => [:spec_exec],
    "sys" => [:spec_exec],
    "jar" => [:spec_exec],
    "war" => [:spec_exec],
    "ear" => [:spec_exec],
    "class" => [:spec_exec],
    "cmd" => [:spec_exec],
    "ps1" => [:spec_exec],
    "vbs" => [:spec_exec],
    "wsf" => [:spec_exec],
    "msix" => [:spec_exec],
    "msp" => [:spec_exec],
    # exec_firmware
    "inf" => [:exec_firmware],
    "fw" => [:exec_firmware],
    "uef" => [:exec_firmware],
    # exec_mobile
    "apk" => [:exec_mobile],
    "aab" => [:exec_mobile],
    "xapk" => [:exec_mobile],
    "obb" => [:exec_mobile],
    "ipa" => [:exec_mobile],
    # source_code
    "bat" => [:source_code],
    "sh" => [:source_code],
    "py" => [:source_code],
    "ex" => [:source_code],
    "erl" => [:source_code],
    "cpp" => [:source_code],
    "c" => [:source_code],
    "h" => [:source_code],
    "hpp" => [:source_code],
    "rs" => [:source_code],
    "go" => [:source_code],
    "java" => [:source_code],
    "cs" => [:source_code],
    "swift" => [:source_code],
    "kt" => [:source_code],
    "scala" => [:source_code],
    "hs" => [:source_code],
    "js" => [:source_code],
    "rb" => [:source_code],
    "php" => [:source_code],
    "lua" => [:source_code],
    "pl" => [:source_code],
    "r" => [:source_code],
    "bash" => [:source_code],
    "zsh" => [:source_code],
    "fish" => [:source_code],
    # dev_web_project
    "css" => [:dev_web_project],
    # dev_config
    "yaml" => [:dev_config],
    "yml" => [:dev_config],
    "toml" => [:dev_config],
    "ini" => [:dev_config],
    "conf" => [:dev_config],
    "env" => [:dev_config],
    # binary
    "bin" => [:binary_file],
    # data_creative
    "als" => [:data_creative],
    "flp" => [:data_creative],
    "rpp" => [:data_creative],
    "band" => [:data_creative],
    "cproj" => [:data_creative],
    "logic" => [:data_creative],
    # data_software_assets
    "ico" => [:data_software_assets],
    "icon" => [:data_software_assets],
    "icns" => [:data_software_assets],
    "cur" => [:data_software_assets],
    # data_database
    "sqlite" => [:data_database],
    "db" => [:data_database],
    "sqlite3" => [:data_database],
    "sql" => [:data_database],
    "mdb" => [:data_database],
    "accdb" => [:data_database],
    # data_json
    "json" => [:data_json],
    "jsonl" => [:data_json],
    "ndjson" => [:data_json],
    # data_xml
    "xml" => [:data_xml],
    "xsd" => [:data_xml],
    "xslt" => [:data_xml],
    # data_tabular
    "tsv" => [:data_tabular],
    "parquet" => [:data_tabular],
    "arrow" => [:data_tabular],
    "feather" => [:data_tabular],
    "orc" => [:data_tabular],
    # data_3d_model
    "obj" => [:data_3d_model],
    "stl" => [:data_3d_model],
    "fbx" => [:data_3d_model],
    "gltf" => [:data_3d_model],
    "glb" => [:data_3d_model],
    "blend" => [:data_3d_model],
    "3ds" => [:data_3d_model],
    "dae" => [:data_3d_model],
    "usdz" => [:data_3d_model],
    "usd" => [:data_3d_model],
    "dwg" => [:data_3d_model],
    "dxf" => [:data_3d_model],
    "step" => [:data_3d_model],
    "stp" => [:data_3d_model],
    "iges" => [:data_3d_model],
    "igs" => [:data_3d_model],
    "f3d" => [:data_3d_model],
    "fcstd" => [:data_3d_model],
    # data_scientific
    "netcdf" => [:data_scientific],
    "nc" => [:data_scientific],
    "fits" => [:data_scientific],
    "nii" => [:data_scientific],
    "root" => [:data_scientific],
    "mat" => [:data_scientific],
    "dcm" => [:data_scientific],
    # data_geospatial
    "shp" => [:data_geospatial],
    "dbf" => [:data_geospatial],
    "geotiff" => [:data_geospatial],
    "kml" => [:data_geospatial],
    "kmz" => [:data_geospatial],
    "gpx" => [:data_geospatial],
    "osm" => [:data_geospatial],
    "geojson" => [:data_geospatial],
    # data_font
    "ttf" => [:data_font],
    "otf" => [:data_font],
    "woff" => [:data_font],
    "woff2" => [:data_font],
    "eot" => [:data_font],
    # noise_encryption
    "gpg" => [:noise_encryption],
    "pgp" => [:noise_encryption],
    "enc" => [:noise_encryption],
    "lock" => [:noise_encryption],
    # noise_checksum
    "sfv" => [:noise_checksum],
    "md5" => [:noise_checksum],
    "sha1" => [:noise_checksum],
    "sha256" => [:noise_checksum],
    "crc32" => [:noise_checksum],
    # ELF treated as linux exec
    "elf" => [:exec_linux]
  }

  def ext_map, do: @ext_map

  @doc "Classify a filename (basename) into category atoms list."
  def classify_file(filename) when is_binary(filename) do
    lower = String.downcase(filename)

    # Check noise patterns first
    noise = check_noise_patterns(lower)

    # Get extension-based categories
    ext_cats =
      case extract_compound_extension(lower) do
        nil -> [:unknown_mime]
        ext -> Map.get(@ext_map, ext, [:unknown_mime])
      end

    Enum.uniq(noise ++ ext_cats)
  end

  defp check_noise_patterns(lower) do
    cond do
      lower == "thumbs.db" -> [:noise_temp]
      lower == ".ds_store" -> [:noise_temp]
      lower == "desktop.ini" -> [:noise_temp]
      String.starts_with?(lower, "__macosx") -> [:noise_temp]
      String.starts_with?(lower, ".spotlight-v100") -> [:noise_temp]
      String.starts_with?(lower, "~$") -> [:noise_temp]
      String.ends_with?(lower, ".tmp") -> [:noise_temp]
      String.ends_with?(lower, ".bak") -> [:noise_temp]
      String.ends_with?(lower, ".crdownload") -> [:noise_temp]
      String.contains?(lower, "_____padding") -> [:noise_bitcomet]
      true -> []
    end
  end

  # Handle compound extensions like .tar.gz, .tar.xz, .tar.bz2, .pkg.tar.zst, etc.
  defp extract_compound_extension(filename) do
    compounds = [
      ".pkg.tar.zst",
      ".pkg.tar.xz",
      ".tar.gz",
      ".tar.xz",
      ".tar.bz2",
      # partial
      ".part1.rar",
      ".part2.rar",
      ".part3.rar"
    ]

    found = Enum.find(compounds, fn c -> String.ends_with?(filename, c) end)

    case found do
      ".pkg.tar.zst" -> "zst"
      ".pkg.tar.xz" -> "xz"
      ".tar.gz" -> "gz"
      ".tar.xz" -> "xz"
      ".tar.bz2" -> "bz2"
      ".part1.rar" -> "rar"
      ".part2.rar" -> "rar"
      ".part3.rar" -> "rar"
      nil -> process_nil(filename)
    end
  end

  def process_nil(filename) do
    case Path.extname(filename) do
      "." <> ext when ext != "" -> ext
      _any -> nil
    end
  end

  # --- Lingual script detection (from Unicode codepoints) ---

  @doc "Detect lingual script categories from a string."
  def detect_scripts(text) when is_binary(text) do
    codepoints = String.to_charlist(text)

    cats = []
    cats = if Enum.any?(codepoints, &cyrillic?/1), do: [:cyrillic | cats], else: cats

    cats =
      if Enum.any?(codepoints, &non_english_latin?/1), do: [:non_english_latin | cats], else: cats

    cats = if Enum.any?(codepoints, &kana?/1), do: [:cjk_jp | cats], else: cats
    cats = if Enum.any?(codepoints, &han?/1), do: [:cjk_zh | cats], else: cats
    cats = if Enum.any?(codepoints, &hangul?/1), do: [:cjk_k | cats], else: cats

    has_latin = Enum.any?(codepoints, fn cp -> cp in ?a..?z or cp in ?A..?Z end)
    has_cyr = :cyrillic in cats
    has_cjk = :cjk_jp in cats or :cjk_zh in cats or :cjk_k in cats

    cats =
      if not has_latin and not has_cyr and not has_cjk, do: [:no_latin_cyr_cjk | cats], else: cats

    cats
  end

  defp cyrillic?(cp), do: cp in 0x0400..0x04FF or cp in 0x0500..0x052F

  defp non_english_latin?(cp) do
    # Latin Extended-A, Extended-B, common diacritics not in basic ASCII
    (cp in 0x00C0..0x00FF and cp not in [0x00D7, 0x00F7]) or
      cp in 0x0100..0x024F or
      cp in 0x1E00..0x1EFF
  end

  defp kana?(cp), do: cp in 0x3040..0x309F or cp in 0x30A0..0x30FF or cp in 0x31F0..0x31FF
  defp han?(cp), do: cp in 0x4E00..0x9FFF or cp in 0x3400..0x4DBF or cp in 0x20000..0x2A6DF
  defp hangul?(cp), do: cp in 0xAC00..0xD7AF or cp in 0x1100..0x11FF or cp in 0x3130..0x318F

  # --- Bloom filter parameters ---
  # 128 bytes
  @bloom_bits 1024
  # number of hash functions
  @bloom_k 7
  @bloom_max_tokens 128

  def bloom_bits, do: @bloom_bits
  def bloom_k, do: @bloom_k
  def bloom_max_tokens, do: @bloom_max_tokens
  # 128 bytes
  def bloom_byte_size, do: div(@bloom_bits, 8)

  # --- SimHash parameters ---
  # 8 bytes
  @simhash_bits 64

  def simhash_bits, do: @simhash_bits
  # 8 bytes
  def simhash_byte_size, do: div(@simhash_bits, 8)

  # --- Token weight constants for SimHash ---
  @weight_first_word 5
  @weight_year 3
  @weight_normal 1

  def weight_first_word, do: @weight_first_word
  def weight_year, do: @weight_year
  def weight_normal, do: @weight_normal

  # --- Structural flags bit positions (1 byte) ---
  # bit 7 (MSB): truncated_bloom
  # bit 6: heuristic_screenshots
  # bit 5: heuristic_cover
  # bit 4: heuristic_desc_readme
  # bit 3: has_english
  # bits 2-0: reserved
  @flag_truncated_bloom 7
  @flag_screenshots 6
  @flag_cover 5
  @flag_desc_readme 4
  @flag_has_english 3

  def flag_truncated_bloom, do: @flag_truncated_bloom
  def flag_screenshots, do: @flag_screenshots
  def flag_cover, do: @flag_cover
  def flag_desc_readme, do: @flag_desc_readme
  def flag_has_english, do: @flag_has_english

  # --- Screenshot/cover/readme heuristic patterns ---
  @screenshot_patterns ~w(screenshot screenshots screen screens scr caps capture)
  @cover_patterns ~w(cover covers folder front artwork album poster thumb thumbnail)
  @readme_patterns ~w(readme read_me readme.txt readme.md readme.nfo description info.txt info.nfo)

  def screenshot_patterns, do: @screenshot_patterns
  def cover_patterns, do: @cover_patterns
  def readme_patterns, do: @readme_patterns

  # --- English letter set ---
  @english_letters MapSet.new(?a..?z)
  def english_letters, do: @english_letters

  # --- Token length constraints ---
  @min_token_len 3
  @max_token_len 19
  @min_cjk_token_len 1

  def min_token_len, do: @min_token_len
  def max_token_len, do: @max_token_len
  def min_cjk_token_len, do: @min_cjk_token_len
end

# ============================================================================
# Module 2: Encoder — takes .torrent path, outputs 184-byte utmc binary
# ============================================================================
defmodule Encoder do
  import Bitwise

  @sentinel_file_count 0xFFFF
  @sentinel_total_size 0xFFFFFFFFFFFFFFFF
  @sentinel_leaf_dir 0xFFFF

  @doc "Encode a .torrent file to utmc binary. Returns {:ok, binary, debug_info} or {:error, reason}."
  def encode(torrent_path) do
    with {:ok, raw} <- File.read(torrent_path),
         {:ok, meta} <- SimpleBencode.decode(raw) do
      do_encode(meta)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_encode(meta) do
    info = Map.get(meta, "info", %{})

    # --- Infohash (SHA1 of bencoded info dict) ---
    info_bencoded = SimpleBencode.encode(info)

    if not is_binary(info_bencoded),
      do: raise("Failed to re-encode info dict: #{inspect(info_bencoded)}")

    infohash = :crypto.hash(:sha, info_bencoded)

    # --- Files list ---
    files = extract_files(info)

    # --- Torrent name ---
    torrent_name = Map.get(info, "name", "")

    # --- All paths (for tokenization / heuristics) ---
    all_paths = Enum.map(files, fn {path, _size} -> path end)

    # --- Date ---
    creation_date = Map.get(meta, "creation date", nil)
    date_byte = EncoderStatic.encode_date(creation_date)

    # --- Piece size ---
    piece_length = Map.get(info, "piece length", 0)
    piece_byte = EncoderStatic.piece_size_enum(piece_length)

    # --- File sizes ---
    file_sizes = Enum.map(files, fn {_path, size} -> size end)
    total_size = Enum.sum(file_sizes)
    file_count = length(files)

    # --- Most frequent filesize range ---
    freq_size_byte = most_frequent_filesize_range(file_sizes)

    # --- Filesize ranges bitmap (24 bits = 3 bytes) ---
    ranges_bitmap = compute_filesize_ranges_bitmap(file_sizes)

    # --- Leaf directory count ---
    leaf_dir_count = compute_leaf_dir_count(all_paths)

    # --- Sentineled values ---
    file_count_u16 = if file_count > 0xFFFE, do: @sentinel_file_count, else: file_count

    total_size_u64 =
      if total_size > 0xFFFFFFFFFFFFFFFE, do: @sentinel_total_size, else: total_size

    leaf_dir_u16 = if leaf_dir_count > 0xFFFE, do: @sentinel_leaf_dir, else: leaf_dir_count

    # --- MIME classification ---
    fmime_categories = classify_all_files(files)

    # --- Lingual script detection (from torrent name + file paths) ---
    all_text = torrent_name <> " " <> Enum.join(all_paths, " ")
    script_cats = EncoderStatic.detect_scripts(all_text)
    fmime_categories = MapSet.union(fmime_categories, MapSet.new(script_cats))

    # --- Compute multitype and any_base ---
    base_types =
      MapSet.new([:audio, :image, :anim_image, :video, :text_article, :book_comic, :archive])

    active_base = MapSet.intersection(fmime_categories, base_types)

    fmime_categories =
      if MapSet.size(active_base) > 0,
        do: MapSet.put(fmime_categories, :any_base),
        else: fmime_categories

    fmime_categories =
      if MapSet.size(active_base) > 1,
        do: MapSet.put(fmime_categories, :multitype),
        else: fmime_categories

    fmimes_u64 = EncoderStatic.fmime_bitmap(fmime_categories)

    # --- Structural flags ---
    structural_flags = compute_structural_flags(torrent_name, all_paths)

    # --- Tokenization ---
    {utm_tokens, name_tokens, token_freqs, debug_token_info} =
      tokenize_torrent(torrent_name, files)

    # --- Select top 128 tokens for bloom ---
    {selected_tokens, truncated} = select_bloom_tokens(token_freqs, name_tokens)

    # Update truncated_bloom flag
    structural_flags =
      case truncated do
        true -> structural_flags ||| 1 <<< EncoderStatic.flag_truncated_bloom()
        false -> structural_flags
      end

    # --- Bloom filter ---
    bloom = compute_bloom(selected_tokens)

    # --- SimHash ---
    simhash = compute_simhash(utm_tokens, name_tokens, torrent_name)

    fmimes_res_last = 0

    # --- Pack binary ---
    utmc = <<
      structural_flags::8,
      date_byte::8,
      piece_byte::8,
      freq_size_byte::8,
      infohash::binary-size(20),
      file_count_u16::big-unsigned-16,
      total_size_u64::big-unsigned-64,
      leaf_dir_u16::big-unsigned-16,
      ranges_bitmap::big-unsigned-24,
      fmimes_u64::big-unsigned-64,
      fmimes_res_last::big-unsigned-8,
      simhash::binary-size(8),
      bloom::binary-size(128)
    >>

    infohash_hex = Base.encode16(infohash, case: :lower)

    debug_info = %{
      infohash_hex: infohash_hex,
      torrent_name: torrent_name,
      name_tokens: name_tokens,
      all_tokens_count: map_size(token_freqs),
      selected_tokens: selected_tokens,
      truncated_bloom: truncated,
      file_count: file_count,
      total_size: total_size,
      leaf_dir_count: leaf_dir_count,
      fmime_categories: MapSet.to_list(fmime_categories) |> Enum.sort(),
      structural_flags: structural_flags,
      date_byte: date_byte,
      piece_byte: piece_byte,
      freq_size_byte: freq_size_byte,
      debug_token_info: debug_token_info
    }

    {:ok, utmc, debug_info}
  end

  # --- Extract files from info dict ---
  # Returns list of {path_string, size_integer}
  defp extract_files(info) do
    case Map.get(info, "files") do
      nil ->
        # Single file mode
        name = Map.get(info, "name", "unknown")
        size = Map.get(info, "length", 0)
        [{name, size}]

      files when is_list(files) ->
        Enum.map(files, fn file_dict ->
          path_parts = Map.get(file_dict, "path", ["unknown"])
          path = Enum.join(path_parts, "/")
          size = Map.get(file_dict, "length", 0)
          {path, size}
        end)
    end
  end

  # --- Most frequent filesize range ---
  defp most_frequent_filesize_range([]), do: 0

  defp most_frequent_filesize_range(file_sizes) do
    file_sizes
    |> Enum.map(&EncoderStatic.filesize_range_index/1)
    |> Enum.frequencies()
    |> Enum.max_by(fn {range_idx, count} -> {count, range_idx} end)
    |> elem(0)
  end

  # --- Filesize ranges bitmap ---
  defp compute_filesize_ranges_bitmap(file_sizes) do
    Enum.reduce(file_sizes, 0, fn size, acc ->
      idx = EncoderStatic.filesize_range_index(size)
      acc ||| 1 <<< (23 - idx)
    end)
  end

  # --- Leaf directory count ---
  defp compute_leaf_dir_count(paths) do
    dirs =
      paths
      |> Enum.map(fn path ->
        parts = String.split(path, "/")

        if length(parts) > 1 do
          parts |> Enum.drop(-1) |> Enum.join("/")
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    parent_dirs =
      Enum.reduce(dirs, MapSet.new(), fn dir, parents ->
        parts = String.split(dir, "/")

        if length(parts) > 1 do
          ancestor_parts =
            1..(length(parts) - 1)
            |> Enum.map(fn n -> parts |> Enum.take(n) |> Enum.join("/") end)

          Enum.reduce(ancestor_parts, parents, fn anc, acc ->
            if MapSet.member?(dirs, anc), do: MapSet.put(acc, anc), else: acc
          end)
        else
          parents
        end
      end)

    leaf_count = MapSet.size(MapSet.difference(dirs, parent_dirs))
    max(leaf_count, 0)
  end

  # --- MIME classification for all files ---
  defp classify_all_files(files) do
    file_categories_list =
      Enum.map(files, fn {path, _size} ->
        basename = Path.basename(path)
        cats = EncoderStatic.classify_file(basename)
        {path, cats}
      end)

    file_categories_list
    |> Enum.flat_map(fn {_path, cats} -> cats end)
    |> MapSet.new()
  end

  # --- Structural flags ---
  defp compute_structural_flags(torrent_name, all_paths) do
    flags = 0

    # Check screenshots heuristic
    all_lower = Enum.map(all_paths, &String.downcase/1)
    name_lower = String.downcase(torrent_name)

    has_screenshots =
      Enum.any?(EncoderStatic.screenshot_patterns(), fn pat ->
        Enum.any?(all_lower, &String.contains?(&1, pat)) or String.contains?(name_lower, pat)
      end)

    flags = if has_screenshots, do: flags ||| 1 <<< EncoderStatic.flag_screenshots(), else: flags

    # Check cover heuristic
    has_cover =
      Enum.any?(EncoderStatic.cover_patterns(), fn pat ->
        Enum.any?(all_lower, &String.contains?(&1, pat)) or String.contains?(name_lower, pat)
      end)

    flags = if has_cover, do: flags ||| 1 <<< EncoderStatic.flag_cover(), else: flags

    # Check readme/description heuristic
    has_readme =
      Enum.any?(EncoderStatic.readme_patterns(), fn pat ->
        Enum.any?(all_lower, fn p ->
          Path.basename(p) == pat or String.contains?(p, pat)
        end)
      end)

    flags = if has_readme, do: flags ||| 1 <<< EncoderStatic.flag_desc_readme(), else: flags

    # Check has_english: at least one token contains a-z characters
    # (will be refined after tokenization; set preliminary based on name)
    has_english =
      String.to_charlist(name_lower)
      |> Enum.any?(fn cp -> cp in ?a..?z end)

    flags = if has_english, do: flags ||| 1 <<< EncoderStatic.flag_has_english(), else: flags

    flags
  end

  # --- Tokenization ---
  @doc """
  Tokenize torrent name and file paths.
  Returns {all_tokens_list, name_tokens_list, token_freq_map, debug_info}
  """
  def tokenize_torrent(torrent_name, files) do
    name_tokens = tokenize_string(torrent_name)

    # Tokenize all file/dir paths
    path_tokens =
      files
      |> Enum.flat_map(fn {path, _size} ->
        path
        |> String.split("/")
        |> Enum.flat_map(&tokenize_string/1)
      end)

    utm_tokens = name_tokens ++ path_tokens

    # Build frequency map
    token_freqs = Enum.frequencies(utm_tokens)

    # Check for "long_words" - any token > 19 chars before truncation
    raw_name_words = split_to_words(torrent_name)

    # Check for "numbers_only" tokens: tokens that are only digits, 2- or 7+ digits
    number_tokens =
      utm_tokens
      |> Enum.filter(fn t -> Regex.match?(~r/^\d+$/, t) end)

    system_tokens =
      []
      |> has_long?(raw_name_words)
      |> numbers_only?(number_tokens)
      |> no_utm_tokens?(utm_tokens)

    # Add system tokens to freq map with freq 1 if not already present
    token_freqs =
      Enum.reduce(system_tokens, token_freqs, fn st, acc ->
        Map.update(acc, st, 1, & &1)
      end)

    debug_info = %{
      name_tokens: name_tokens,
      path_token_count: length(path_tokens),
      system_tokens: system_tokens,
      total_unique: map_size(token_freqs)
    }

    {utm_tokens, name_tokens, token_freqs, debug_info}
  end

  defp has_long?(all_t, raw_nw) do
    hl? = Enum.any?(raw_nw, fn w -> String.length(w) > EncoderStatic.max_token_len() end)

    case hl? do
      true -> ["long_words" | all_t]
      false -> all_t
    end
  end

  defp numbers_only?(all_t, number_t) do
    no? =
      Enum.any?(number_t, fn t ->
        len = String.length(t)
        len <= 2 or len >= 7
      end)

    case no? do
      true -> ["numbers_only" | all_t]
      false -> all_t
    end
  end

  defp no_utm_tokens?(all_t, utm_t) do
    case utm_t == [] do
      true -> ["tokenization_error" | all_t]
      false -> all_t
    end
  end

  @doc "Tokenize a single string (name or path component)."
  def tokenize_string(str) do
    str
    |> normalize_string()
    |> split_to_words()
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&valid_token?/1)
    |> Enum.map(fn t ->
      if String.length(t) > EncoderStatic.max_token_len() do
        String.slice(t, 0, EncoderStatic.max_token_len())
      else
        t
      end
    end)
  end

  defp normalize_string(str) do
    str
    |> String.replace(~r/[._\-\[\]\(\)\{\}~!@#\$%\^&\*\+=,;:'"`]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp split_to_words(str) do
    str
    |> normalize_string()
    |> String.split(" ", trim: true)
  end

  defp valid_token?(word) do
    len = String.length(word)
    codepoints = String.to_charlist(word)

    has_cjk =
      Enum.any?(codepoints, fn cp ->
        cp in 0x4E00..0x9FFF or cp in 0x3400..0x4DBF or
          cp in 0x3040..0x309F or cp in 0x30A0..0x30FF or
          cp in 0xAC00..0xD7AF
      end)

    min_len =
      if has_cjk, do: EncoderStatic.min_cjk_token_len(), else: EncoderStatic.min_token_len()

    len >= min_len
  end

  # --- Select top 128 tokens for bloom filter ---
  # Tie-breaking: present in torrent name -> longer word -> lexicographic
  defp select_bloom_tokens(token_freqs, name_tokens) do
    max = EncoderStatic.bloom_max_tokens()
    name_set = MapSet.new(name_tokens)

    sorted =
      token_freqs
      |> Enum.sort_by(fn {token, freq} ->
        in_name = if MapSet.member?(name_set, token), do: 1, else: 0

        # Sort descending by freq, then by in_name (1 first), then by length desc, then lexicographic asc
        {-freq, -in_name, -String.length(token), token}
      end)
      |> Enum.map(fn {token, _freq} -> token end)

    truncated = length(sorted) > max
    selected = Enum.take(sorted, max)

    {selected, truncated}
  end

  # --- Bloom filter ---
  defp compute_bloom(tokens) do
    bits = EncoderStatic.bloom_bits()
    k = EncoderStatic.bloom_k()

    bit_array = :atomics.new(bits, signed: false)

    Enum.each(tokens, fn token ->
      positions = bloom_positions(token, k, bits)

      Enum.each(positions, fn pos ->
        # atomics is 1-indexed
        :atomics.put(bit_array, pos + 1, 1)
      end)
    end)

    # Convert to binary
    bytes =
      for byte_idx <- 0..(div(bits, 8) - 1) do
        byte_val =
          Enum.reduce(0..7, 0, fn bit_idx, acc ->
            global_bit = byte_idx * 8 + bit_idx
            val = :atomics.get(bit_array, global_bit + 1)
            if val == 1, do: acc ||| 1 <<< (7 - bit_idx), else: acc
          end)

        byte_val
      end

    :binary.list_to_bin(bytes)
  end

  # Generate k bloom filter bit positions using double hashing
  defp bloom_positions(token, k, m) do
    h1_full = :crypto.hash(:sha, token)
    h2_full = :crypto.hash(:sha, <<token::binary, 0xFF>>)

    <<h1::unsigned-big-64, _::binary>> = h1_full
    <<h2::unsigned-big-64, _::binary>> = h2_full

    for i <- 0..(k - 1) do
      Integer.mod(h1 + i * h2, m)
    end
  end

  @doc "Check if a token might be in the bloom filter."
  def bloom_check?(bloom_binary, token) do
    bits = EncoderStatic.bloom_bits()
    k = EncoderStatic.bloom_k()
    positions = bloom_positions(token, k, bits)

    Enum.all?(positions, fn pos ->
      byte_idx = div(pos, 8)
      bit_idx = rem(pos, 8)
      <<_::binary-size(byte_idx), byte_val::8, _::binary>> = bloom_binary
      (byte_val &&& 1 <<< (7 - bit_idx)) != 0
    end)
  end

  # --- SimHash ---
  defp compute_simhash(utm_tokens, name_tokens, torrent_name) do
    bits = EncoderStatic.simhash_bits()
    name_set = MapSet.new(name_tokens)

    # Determine first word and year tokens for weighting
    first_word =
      case tokenize_string(torrent_name) do
        [fw | _] -> fw
        [] -> nil
      end

    year_pattern = ~r/^(19|20)\d{2}$/

    # Build weighted token list
    weighted_tokens =
      utm_tokens
      |> Enum.uniq()
      |> Enum.map(fn token ->
        weight =
          cond do
            token == first_word -> EncoderStatic.weight_first_word()
            Regex.match?(year_pattern, token) -> EncoderStatic.weight_year()
            MapSet.member?(name_set, token) -> EncoderStatic.weight_normal() + 1
            true -> EncoderStatic.weight_normal()
          end

        {token, weight}
      end)

    # Accumulate bit vectors
    accum = :atomics.new(bits, signed: true)

    Enum.each(weighted_tokens, fn {token, weight} ->
      hash = token_hash_64(token)

      for i <- 0..(bits - 1) do
        bit = hash >>> (bits - 1 - i) &&& 1
        delta = if bit == 1, do: weight, else: -weight
        :atomics.add(accum, i + 1, delta)
      end
    end)

    # Build result
    result =
      Enum.reduce(0..(bits - 1), 0, fn i, acc ->
        if :atomics.get(accum, i + 1) > 0 do
          acc ||| 1 <<< (bits - 1 - i)
        else
          acc
        end
      end)

    <<result::big-unsigned-64>>
  end

  defp token_hash_64(token) do
    <<h::unsigned-big-64, _::binary>> = :crypto.hash(:sha, token)
    h
  end

  @doc "Compute Hamming distance between two simhash binaries."
  def simhash_distance(<<a::big-unsigned-64>>, <<b::big-unsigned-64>>) do
    xor = Bitwise.bxor(a, b)
    popcount(xor, 0)
  end

  defp popcount(0, acc), do: acc
  defp popcount(n, acc), do: popcount(Bitwise.band(n, n - 1), acc + 1)
end

# ============================================================================
# Module 3: Search — batch encode, JSONL output, debug log, interactive search
# ============================================================================
defmodule Search do
  @moduledoc """
  Recursively scans a folder of .torrent files, encodes each to utmc,
  outputs a JSONL file and debug log, provides interactive search.
  """

  # --- Constants: adjust these paths ---
  @torrents_dir "./test_torrents"
  @output_jsonl "./utmc_output.jsonl"
  @debug_log "./utmc_debug.log"

  def torrents_dir, do: @torrents_dir
  def output_jsonl, do: @output_jsonl
  def debug_log, do: @debug_log

  @doc "Scan all torrents, encode, write JSONL and debug log. Returns list of utmc records."
  def encode_all do
    torrent_files = find_torrent_files(@torrents_dir)
    IO.puts("Found #{length(torrent_files)} .torrent files in #{@torrents_dir}")

    # Open output files
    {:ok, jsonl_file} = File.open(@output_jsonl, [:write, :utf8])
    {:ok, log_file} = File.open(@debug_log, [:write, :utf8])

    IO.write(log_file, "utmc Encoder Debug Log\n")
    IO.write(log_file, "Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}\n")
    IO.write(log_file, "Source: #{@torrents_dir}\n")
    IO.write(log_file, String.duplicate("=", 80) <> "\n\n")

    results =
      torrent_files
      |> Enum.map(fn path ->
        case Encoder.encode(path) do
          {:ok, utmc_binary, debug_info} ->
            # Write JSONL line
            jsonl_entry = %{
              "infohash" => debug_info.infohash_hex,
              "torrent_name" => debug_info.torrent_name,
              "utmc_hex" => Base.encode16(utmc_binary, case: :lower),
              "utmc_size" => byte_size(utmc_binary),
              "file_count" => debug_info.file_count,
              "total_size" => debug_info.total_size,
              "fmime_categories" => Enum.map(debug_info.fmime_categories, &Atom.to_string/1)
            }

            # Simple JSON serialization (no dependency)
            json_line = SimpleJson.encode!(jsonl_entry)

            IO.write(jsonl_file, json_line <> "\n")

            # Write debug log
            write_debug_entry(log_file, path, debug_info)

            {:ok, debug_info.infohash_hex, utmc_binary, debug_info}

          {:error, reason} ->
            IO.puts("  ERROR encoding #{path}: #{inspect(reason)}")
            IO.write(log_file, "ERROR: #{path} — #{inspect(reason)}\n\n")
            {:error, path, reason}
        end
      end)

    File.close(jsonl_file)
    File.close(log_file)

    successful =
      Enum.filter(results, fn
        {:ok, _, _, _} -> true
        _ -> false
      end)

    IO.puts("\nEncoded #{length(successful)}/#{length(torrent_files)} torrents")
    IO.puts("JSONL output: #{@output_jsonl}")
    IO.puts("Debug log: #{@debug_log}")

    successful
  end

  @doc "Interactive search: user types a normalized word, scan blooms and simhashes."
  def search do
    results = encode_all()

    if results == [] do
      IO.puts("No torrents encoded. Nothing to search.")
    else
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Interactive utmc Search")
      IO.puts("Type a word (already normalized) to search blooms and simhashes.")
      IO.puts("Type 'quit' to exit.\n")

      search_loop(results)
    end
  end

  defp search_loop(results) do
    word = IO.gets("search> ") |> String.trim() |> String.downcase()

    case word do
      "quit" ->
        IO.puts("Goodbye.")
        :ok

      "" ->
        search_loop(results)

      query ->
        # Search bloom filters
        bloom_matches =
          Enum.filter(results, fn {:ok, _ih, utmc_binary, _debug} ->
            # Extract bloom from utmc binary (last 128 bytes)
            bloom_offset = byte_size(utmc_binary) - 128
            <<_::binary-size(bloom_offset), bloom::binary-size(128)>> = utmc_binary
            Encoder.bloom_check?(bloom, query)
          end)

        # Search simhash: compute simhash of the query word, find close matches
        query_simhash = compute_query_simhash(query)

        simhash_matches =
          results
          |> Enum.map(fn {:ok, ih, utmc_binary, debug} ->
            # Extract simhash (8 bytes starting at offset 47 in our layout)
            # Layout: flags(1) + date(1) + piece(1) + freq(1) + infohash(20) +
            #         fc(2) + ts(8) + ld(2) + ranges(3) + fmimes(8) = 47
            simhash_offset = 1 + 1 + 1 + 1 + 20 + 2 + 8 + 2 + 3 + 8
            <<_::binary-size(simhash_offset), simhash::binary-size(8), _::binary>> = utmc_binary
            distance = Encoder.simhash_distance(query_simhash, simhash)
            {ih, debug.torrent_name, distance}
          end)
          |> Enum.sort_by(fn {_, _, d} -> d end)
          |> Enum.take(10)

        IO.puts("\n--- Bloom filter matches for '#{query}': #{length(bloom_matches)} ---")

        Enum.each(bloom_matches, fn {:ok, ih, _utmc, debug} ->
          IO.puts("  #{ih}  #{debug.torrent_name}")
        end)

        IO.puts("\n--- SimHash closest (top 10, Hamming distance) ---")

        Enum.each(simhash_matches, fn {ih, name, dist} ->
          IO.puts("  #{ih}  dist=#{dist}  #{name}")
        end)

        IO.puts("")
        search_loop(results)
    end
  end

  defp compute_query_simhash(query) do
    _bits = EncoderStatic.simhash_bits()
    <<h::unsigned-big-64, _rest::binary>> = :crypto.hash(:sha, query)

    # For a single word, simhash is just the hash
    <<h::big-unsigned-64>>
  end

  # --- Find all .torrent files recursively ---
  defp find_torrent_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          full_path = Path.join(dir, entry)

          cond do
            File.dir?(full_path) ->
              find_torrent_files(full_path)

            String.ends_with?(String.downcase(entry), ".torrent") ->
              [full_path]

            true ->
              []
          end
        end)

      {:error, reason} ->
        IO.puts("Warning: cannot read directory #{dir}: #{inspect(reason)}")
        []
    end
  end

  # --- Write debug log entry ---
  defp write_debug_entry(log_file, path, debug) do
    IO.write(log_file, "--- #{debug.infohash_hex} ---\n")
    IO.write(log_file, "File: #{path}\n")
    IO.write(log_file, "Name: #{debug.torrent_name}\n")
    IO.write(log_file, "Files: #{debug.file_count}, Total: #{format_size(debug.total_size)}\n")
    IO.write(log_file, "Leaf dirs: #{debug.leaf_dir_count}\n")
    IO.write(log_file, "Date byte: #{debug.date_byte}, Piece byte: #{debug.piece_byte}\n")
    IO.write(log_file, "Freq size range: #{debug.freq_size_byte}\n")

    IO.write(
      log_file,
      "Structural flags: 0b#{Integer.to_string(debug.structural_flags, 2) |> String.pad_leading(8, "0")}\n"
    )

    IO.write(log_file, "FMIME categories: #{inspect(debug.fmime_categories)}\n")
    IO.write(log_file, "Name tokens: #{inspect(debug.name_tokens)}\n")

    IO.write(
      log_file,
      "Selected bloom tokens (#{length(debug.selected_tokens)}): #{inspect(debug.selected_tokens)}\n"
    )

    IO.write(log_file, "Truncated bloom: #{debug.truncated_bloom}\n")
    IO.write(log_file, "Token debug: #{inspect(debug.debug_token_info)}\n")
    IO.write(log_file, "\n")
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"
end

# ============================================================================
# Main entry point
# ============================================================================
IO.puts("utmc Encoder v0.1 — BitTorrent v1 / SHA1 / 184-byte fingerprint")
IO.puts("")

case System.argv() do
  ["--search"] ->
    Search.search()

  ["--encode", path] ->
    case Encoder.encode(path) do
      {:ok, utmc, debug} ->
        IO.puts("Infohash: #{debug.infohash_hex}")
        IO.puts("utmc (#{byte_size(utmc)} bytes): #{Base.encode16(utmc, case: :lower)}")
        IO.puts("Name: #{debug.torrent_name}")
        IO.puts("Files: #{debug.file_count}, Size: #{debug.total_size}")
        IO.puts("Categories: #{inspect(debug.fmime_categories)}")
        IO.puts("Bloom tokens: #{inspect(debug.selected_tokens)}")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end

  ["--batch"] ->
    Search.encode_all()

  _ ->
    IO.puts("Usage:")
    IO.puts("  elixir utmc_encoder.exs --encode <file.torrent>")
    IO.puts("  elixir utmc_encoder.exs --batch")
    IO.puts("  elixir utmc_encoder.exs --search")
end
