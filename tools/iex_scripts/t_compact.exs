#!/usr/bin/env elixir

# analyze_torrents.exs - Analyzes torrent JSON files to find unclassified extensions

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

defmodule ExtCat do
  @raw_audio ~w(mp3 flac ogg m4a m4b wav wma aac opus)
  @raw_image ~w(jpg jpeg png webp avif)
  @raw_anim_image ~w(apng gif ugoira)
  @raw_video ~w(mkv mp4 avi webm flv 3gp wmv mpg mpeg mp2 mov)
  @raw_text ~w(txt md nfo info htm html mhtml mht rtf csv)
  @raw_book ~w(pdf fb2 cbz cbr epub cb7 cba cbt mobi doc docx odt djvu djv)
  @raw_archive ~w(zip zst zstd xz gz rar 7z tar gzip)
  @raw_mdf ~w(mdf blake3)
  @raw_torrent ~w(torrent)
  @raw_links ~w(url webloc website lnk link)
  @raw_ai_by_ext ~w(gguf safetensors pt pth ckpt onnx h5 hdf5 pb tflite)

  @raw_playlist ~w(m3u pls cue m3u8 xspf asx)
  @raw_subtitles ~w(srt ass ssa vtt smi sub sup pgs idx)
  @raw_spec_audio ~w(fm oga aif aiff wave wv mka ac3 ape tta tak dsf dff it s3m mptm mid midi kar aa aax cdg lrc mod xm ra accurip spx alac)
  @raw_spec_image ~w(bmp heic heif jxl qoi tif tiff cr2 cr3 nef arw dng orf rw2 raf pef srw eps cdr wmf emf psb xcf kra afphoto ktx ktx2 exr hdr svg ai dds tga psd raw jp2 j2k)
  @raw_spec_video ~w(m2v m4v ogm ogv rm rmvb asf qt rv av1 ffp swf bik bik2 bk2 braw hevc)
  @raw_disc_video ~w(vob m2ts ts ifo clpi mpls bdmv)
  @raw_spec_text ~w(man manifest readme version ver azw azw3 chm hlp log syslog diz page pages asc ppt pptx odp key keystore tex bib sty cls lytx indd qxp pub sla xls xlsx ods zim msg desc description reg opf org ics vcf par2 nzb)
  @raw_spec_arch ~w(z bz2 lzma lz4 lha lzh lzo br r00)
  @raw_mount_disc ~w(iso mds img vmdk vdi nrg ccd cdi wim esd swm ima)
  @raw_consoles ~w(nes smc sfc gen smd gb gbc gba n64 nds nsp xci pbp cso chd psv gdi a26 pce neo cia wad wbfs rom nsz)
  @raw_exec_win ~w(exe msi)
  @raw_exec_linux ~w(deb rpm appimage elf)
  @raw_exec_mac ~w(dmg app pkg mpkg)
  @raw_spec_exec ~w(ocx flatpak flatpakref snap so dll scr com sys jar war ear class cmd ps1 vbs wsf msix msp wasm bin cab gem)
  @raw_exec_firmware ~w(inf fw uef)
  @raw_exec_mobile ~w(apk aab xapk obb ipa)
  @raw_source_code ~w(c h r f bat sh py ex exs erl cpp hpp rs go java cs swift kt scala hs js svelte vue rb php lua pl bash zsh fish pas f90 f95 ipynb)
  @raw_dev_web_project ~w(css asp aspx browser)
  @raw_dev_config ~w(yaml yml toml ini conf config cfg env make cmake lib ftp properties dockerfile)
  @raw_data_creative ~w(als flp rpp band cproj logic)
  @raw_data_game_assets ~w(map umap unity unity3d u3d godot asset assets uasset res ress resource resources vpk bsp bundle pack pak rne)
  @raw_data_software_assets ~w(ico icon icns cur dat)
  @raw_data_database ~w(sqlite db sqlite3 sql mdb accdb data)
  @raw_data_json ~w(json jsonl ndjson)
  @raw_data_xml ~w(xml xsd xslt)
  @raw_data_tabular ~w(tsv parquet arrow feather orc)
  @raw_data_3d_model ~w(obj stl fbx gltf glb blend 3ds dae usdz usd dwg dxf step stp iges igs f3d fcstd)
  @raw_data_scientific ~w(netcdf nc fits nii root mat dcm)
  @raw_data_geospatial ~w(shp dbf geotiff kml kmz gpx osm geojson)
  @raw_data_font ~w(ttf otf woff woff2 eot)

  @raw_noise_by_ext ~w(tmp temp dmp dump bak back backup bup crash old crdownload part cache gpg pgp enc aes age sig crypto chk checksum sfv crc32 md5 sha sha1 sha256 hash lock crt cert csr security policy license)

  all_exts =
    [
      @raw_audio,
      @raw_image,
      @raw_anim_image,
      @raw_video,
      @raw_text,
      @raw_book,
      @raw_archive,
      @raw_mdf,
      @raw_torrent,
      @raw_links,
      @raw_ai_by_ext,
      @raw_playlist,
      @raw_subtitles,
      @raw_spec_audio,
      @raw_spec_image,
      @raw_spec_video,
      @raw_disc_video,
      @raw_spec_text,
      @raw_spec_arch,
      @raw_mount_disc,
      @raw_consoles,
      @raw_exec_win,
      @raw_exec_linux,
      @raw_exec_mac,
      @raw_spec_exec,
      @raw_exec_firmware,
      @raw_exec_mobile,
      @raw_source_code,
      @raw_dev_web_project,
      @raw_dev_config,
      @raw_data_creative,
      @raw_data_game_assets,
      @raw_data_software_assets,
      @raw_data_database,
      @raw_data_json,
      @raw_data_xml,
      @raw_data_tabular,
      @raw_data_3d_model,
      @raw_data_scientific,
      @raw_data_geospatial,
      @raw_data_font,
      @raw_noise_by_ext
    ]
    |> List.flatten()

  duplicates =
    all_exts
    |> Enum.frequencies()
    |> Enum.filter(fn {_k, v} -> v > 1 end)

  if duplicates != [] do
    raise "[ExtCat] Duplicate ext defined: #{inspect(duplicates)}"
  end

  @audio Map.new(@raw_audio, &{&1, :audio})
  @image Map.new(@raw_image, &{&1, :image})
  @anim_image Map.new(@raw_anim_image, &{&1, :anim_image})
  @video Map.new(@raw_video, &{&1, :video})
  @text Map.new(@raw_text, &{&1, :text})
  @book Map.new(@raw_book, &{&1, :book})
  @archive Map.new(@raw_archive, &{&1, :archive})
  @mdf Map.new(@raw_mdf, &{&1, :mdf})
  @torrent Map.new(@raw_torrent, &{&1, :torrent})
  @links Map.new(@raw_links, &{&1, :links})
  @ai_by_ext Map.new(@raw_ai_by_ext, &{&1, :ai_by_ext})

  @base_cats Map.merge(@audio, @image)
             |> Map.merge(@video)
             |> Map.merge(@anim_image)
             |> Map.merge(@text)
             |> Map.merge(@book)
             |> Map.merge(@archive)
             |> Map.merge(@mdf)
             |> Map.merge(@torrent)
             |> Map.merge(@links)
             |> Map.merge(@ai_by_ext)

  @spec_audio Map.new(@raw_spec_audio, &{&1, :spec_audio})
  @playlist Map.new(@raw_playlist, &{&1, :playlist})
  @spec_image Map.new(@raw_spec_image, &{&1, :spec_image})
  @spec_video Map.new(@raw_spec_video, &{&1, :spec_video})
  @disc_video Map.new(@raw_disc_video, &{&1, :disc_video})
  @spec_text Map.new(@raw_spec_text, &{&1, :spec_text})
  @subtitles Map.new(@raw_subtitles, &{&1, :subtitles})
  @spec_arch Map.new(@raw_spec_arch, &{&1, :spec_arch})
  @mount_disc Map.new(@raw_mount_disc, &{&1, :mount_disc})
  @consoles Map.new(@raw_consoles, &{&1, :consoles})
  @exec_win Map.new(@raw_exec_win, &{&1, :exec_win})
  @exec_linux Map.new(@raw_exec_linux, &{&1, :exec_linux})
  @exec_mac Map.new(@raw_exec_mac, &{&1, :exec_mac})
  @spec_exec Map.new(@raw_spec_exec, &{&1, :spec_exec})
  @exec_firmware Map.new(@raw_exec_firmware, &{&1, :exec_firmware})
  @exec_mobile Map.new(@raw_exec_mobile, &{&1, :exec_mobile})
  @source_code Map.new(@raw_source_code, &{&1, :source_code})
  @dev_web_project Map.new(@raw_dev_web_project, &{&1, :dev_web_project})
  @dev_config Map.new(@raw_dev_config, &{&1, :dev_config})
  @data_creative Map.new(@raw_data_creative, &{&1, :data_creative})
  @data_game_assets Map.new(@raw_data_game_assets, &{&1, :data_game_assets})
  @data_software_assets Map.new(@raw_data_software_assets, &{&1, :data_software_assets})
  @data_database Map.new(@raw_data_database, &{&1, :data_database})
  @data_json Map.new(@raw_data_json, &{&1, :data_json})
  @data_xml Map.new(@raw_data_xml, &{&1, :data_xml})
  @data_tabular Map.new(@raw_data_tabular, &{&1, :data_tabular})
  @data_3d_model Map.new(@raw_data_3d_model, &{&1, :data_3d_model})
  @data_scientific Map.new(@raw_data_scientific, &{&1, :data_scientific})
  @data_geospatial Map.new(@raw_data_geospatial, &{&1, :data_geospatial})
  @data_font Map.new(@raw_data_font, &{&1, :data_font})

  @add_cats Map.merge(@spec_audio, @playlist)
            |> Map.merge(@spec_image)
            |> Map.merge(@spec_video)
            |> Map.merge(@disc_video)
            |> Map.merge(@spec_text)
            |> Map.merge(@subtitles)
            |> Map.merge(@spec_arch)
            |> Map.merge(@mount_disc)
            |> Map.merge(@consoles)
            |> Map.merge(@exec_win)
            |> Map.merge(@exec_linux)
            |> Map.merge(@exec_mac)
            |> Map.merge(@spec_exec)
            |> Map.merge(@exec_firmware)
            |> Map.merge(@exec_mobile)
            |> Map.merge(@source_code)
            |> Map.merge(@dev_web_project)
            |> Map.merge(@dev_config)
            |> Map.merge(@data_creative)
            |> Map.merge(@data_game_assets)
            |> Map.merge(@data_software_assets)
            |> Map.merge(@data_database)
            |> Map.merge(@data_json)
            |> Map.merge(@data_xml)
            |> Map.merge(@data_tabular)
            |> Map.merge(@data_3d_model)
            |> Map.merge(@data_scientific)
            |> Map.merge(@data_geospatial)
            |> Map.merge(@data_font)

  @noise_by_ext Map.new(@raw_noise_by_ext, &{&1, :noise_by_ext})

  @all_cats Map.merge(@base_cats, @add_cats)
            |> Map.merge(@noise_by_ext)

  # API ---

  def get(extension), do: Map.get(@all_cats, extension, :not_found)
  def all_categories(), do: Map.values(@all_cats)

  def extensions_for(category) do
    @all_cats
    |> Enum.filter(fn {_ext, cat} -> cat == category end)
    |> Enum.map(fn {ext, _cat} -> ext end)
  end
end

defmodule BaseClassifier do
  import Bitwise

  # todo: for ai class - look for lora
  # todo: disambiguate .ts/.mdf/.rom by size -- don't track ts, mdf to new, rom to consoles
  # todo: change simhash to cross-torrent, batch by batch -- or per torrent, what is better?

  # NOTE: only based on extensions, doesn't yet classify ai/noise - left for tokenizer
  # lang_script_fmimes + pattern_and_token_fmimes -- for tokenizer
  # exploration_fmimes left out for now

  # We'll define a flat ordered list of all 64 bit names for the fmimes bitmap

  @type fmime_bitmap :: <<_::64>>
  @type ext_based_fmime_bitmap :: <<_::44>>

  @base_fmimes [
    :any_base,
    :audio,
    :image,
    :video,
    :anim_image,
    :text,
    :book,
    :archive,
    :mdf,
    :torrent,
    :links,
    :ai_by_ext
  ]

  @ext_content_fmimes [
    :playlist,
    :subtitles,
    :spec_audio,
    :spec_image,
    :spec_video,
    :disc_video,
    :spec_text,
    :spec_arch,
    :exec_win,
    :exec_linux,
    :exec_mac,
    :mount_disc,
    :consoles,
    :spec_exec,
    :exec_firmware,
    :exec_mobile,
    :source_code,
    :dev_web_project,
    :dev_config,
    :reserved_01
  ]
  @various_data_fmimes [
    :data_creative,
    :data_game_assets,
    :data_software_assets,
    :data_database,
    :data_json,
    :data_xml,
    :data_tabular,
    :data_3d_model,
    :data_scientific,
    :data_geospatial,
    :data_font,
    :reserved_02
  ]

  @ext_based_fmimes @base_fmimes ++ @ext_content_fmimes ++ @various_data_fmimes

  @bit_positions @ext_based_fmimes
                 |> Enum.with_index()
                 |> Map.new(fn {cat, idx} -> {cat, idx} end)

  @r_tuple {MapSet.new(), MapSet.new(), MapSet.new(), MapSet.new(), 0}

  # --- API

  def classify_ext_list(ext_list), do: do_classify(ext_list)

  def decode_fmime_bitmap(hex_string) do
    {int_value, ""} = Integer.parse(hex_string, 16)
    # Can now check bits
    int_value
  end

  def which_categories_present(hex_string) do
    {bitmask, ""} = Integer.parse(hex_string, 16)

    @ext_based_fmimes
    |> Enum.with_index()
    |> Enum.filter(fn {_cat, idx} -> (bitmask &&& 1 <<< idx) != 0 end)
    |> Enum.map(fn {cat, _idx} -> cat end)
  end

  # --- Logic

  defp do_classify(list) do
    {base_cats, spec_cats, data_cats, not_found, bitmap} =
      Enum.reduce(list, @r_tuple, fn ext, {base_acc, spec_acc, data_acc, nf_acc, bitmap_acc} ->
        case ExtCat.get(ext) do
          :not_found ->
            {base_acc, spec_acc, data_acc, MapSet.put(nf_acc, ext), bitmap_acc}

          :noise_by_ext ->
            # Discard noise
            {base_acc, spec_acc, data_acc, nf_acc, bitmap_acc}

          cat ->
            new_bitmap = set_bit_for_category(bitmap_acc, cat)

            cond do
              cat in @base_fmimes ->
                {MapSet.put(base_acc, cat), spec_acc, data_acc, nf_acc, new_bitmap}

              cat in @ext_content_fmimes ->
                {base_acc, MapSet.put(spec_acc, cat), data_acc, nf_acc, new_bitmap}

              cat in @various_data_fmimes ->
                {base_acc, spec_acc, MapSet.put(data_acc, cat), nf_acc, new_bitmap}

              true ->
                {base_acc, spec_acc, data_acc, nf_acc, new_bitmap}
            end
        end
      end)

    final_bitmap = maybe_any_base(bitmap, base_cats)
    finalize(base_cats, spec_cats, data_cats, not_found, final_bitmap)
  end

  defp maybe_any_base(bitmap, base_cats) do
    has_base_fmime? = Enum.any?(base_cats, fn cat -> cat in @base_fmimes end)

    case has_base_fmime? do
      false -> bitmap
      true -> set_bit_for_category(bitmap, :any_base)
    end
  end

  defp finalize(base_cats, spec_cats, data_cats, not_found, bitmap) do
    %{}
    |> maybe_add_list(:base_fmimes, base_cats)
    |> maybe_add_list(:spec_fmimes, spec_cats)
    |> maybe_add_list(:data_fmimes, data_cats)
    |> maybe_add_list(:not_found, not_found)
    |> Map.put(:ext_based_fmime_bitmap, format_bitmap(bitmap))
  end

  defp set_bit_for_category(bitmap, category) do
    case Map.get(@bit_positions, category) do
      nil -> bitmap
      bit_pos -> bitmap ||| 1 <<< bit_pos
    end
  end

  defp format_bitmap(bitmap) do
    bitmap
    |> Integer.to_string(16)
    # 44 bits = 11 hex chars
    |> String.pad_leading(11, "0")
    |> String.downcase()
  end

  defp maybe_add_list(map, _key, mapset) when map_size(mapset) == 0, do: map

  defp maybe_add_list(map, key, mapset) do
    list =
      mapset
      |> MapSet.to_list()
      |> Enum.sort()

    Map.put(map, key, list)
  end
end

defmodule TorrentAnalyzer do
  @moduledoc """
  Analyzes JSON files from a directory to identify file extensions that aren't
  classified by ExtCat, helping to enrich the classifier's extension database.
  """

  def run(dir_path) do
    IO.puts("🔍 Analyzing torrents in: #{dir_path}\n")

    stats = %{
      files_processed: 0,
      torrents_analyzed: 0,
      total_extensions: MapSet.new(),
      classified: MapSet.new(),
      not_found: MapSet.new(),
      noise: MapSet.new(),
      category_counts: %{},
      extension_frequency: %{},
      errors: []
    }

    json_files =
      dir_path
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))

    total_files = length(json_files)
    IO.puts("📂 Found #{total_files} JSON files\n")

    final_stats =
      json_files
      |> Enum.with_index(1)
      |> Enum.reduce(stats, fn {file, idx}, acc ->
        if rem(idx, 100) == 0 do
          IO.write("\rProcessing: #{idx}/#{total_files}")
        end

        process_file(Path.join(dir_path, file), acc)
      end)

    IO.puts("\n\n✅ Processing complete!\n")

    write_report(dir_path, final_stats)
  end

  defp process_file(filepath, stats) do
    case File.read(filepath) do
      {:ok, content} ->
        case SimpleJson.decode(content) do
          {:ok, data} ->
            process_torrent_data(data, stats)

          {:error, reason} ->
            %{
              stats
              | errors: [{filepath, "JSON decode error: #{inspect(reason)}"} | stats.errors]
            }
        end

      {:error, reason} ->
        %{stats | errors: [{filepath, "File read error: #{inspect(reason)}"} | stats.errors]}
    end
  rescue
    e ->
      %{stats | errors: [{filepath, "Exception: #{inspect(e)}"} | stats.errors]}
  end

  defp process_torrent_data(%{"extensions" => extensions} = data, stats)
       when is_list(extensions) do
    # Normalize extensions to lowercase
    normalized_exts =
      extensions
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    # Update extension frequency
    extension_frequency =
      Enum.reduce(normalized_exts, stats.extension_frequency, fn ext, freq ->
        Map.update(freq, ext, 1, &(&1 + 1))
      end)

    # Classify the extensions
    classification = BaseClassifier.classify_ext_list(normalized_exts)

    # Update category counts
    category_counts = update_category_counts(stats.category_counts, classification)

    # Track classified vs not found
    classified_exts =
      normalized_exts
      |> Enum.filter(fn ext -> ExtCat.get(ext) != :not_found end)
      |> MapSet.new()

    not_found_exts =
      classification
      |> Map.get(:not_found, [])
      |> MapSet.new()

    noise_exts =
      normalized_exts
      |> Enum.filter(fn ext -> ExtCat.get(ext) == :noise_by_ext end)
      |> MapSet.new()

    %{
      stats
      | files_processed: stats.files_processed + 1,
        torrents_analyzed: stats.torrents_analyzed + 1,
        total_extensions: MapSet.union(stats.total_extensions, MapSet.new(normalized_exts)),
        classified: MapSet.union(stats.classified, classified_exts),
        not_found: MapSet.union(stats.not_found, not_found_exts),
        noise: MapSet.union(stats.noise, noise_exts),
        category_counts: category_counts,
        extension_frequency: extension_frequency
    }
  end

  defp process_torrent_data(_data, stats) do
    # No extensions key or invalid format
    %{stats | files_processed: stats.files_processed + 1}
  end

  defp update_category_counts(counts, classification) do
    all_categories =
      [:base_fmimes, :spec_fmimes, :data_fmimes]
      |> Enum.flat_map(fn key -> Map.get(classification, key, []) end)

    Enum.reduce(all_categories, counts, fn cat, acc ->
      Map.update(acc, cat, 1, &(&1 + 1))
    end)
  end

  defp write_report(dir_path, stats) do
    timestamp = DateTime.utc_now() |> DateTime.to_string() |> String.replace(" ", "_")
    report_file = Path.join(dir_path, "extension_analysis_#{timestamp}.log")

    report = generate_report(stats)

    File.write!(report_file, report)
    IO.puts("📝 Report written to: #{report_file}")

    # Also print summary to console
    print_summary(stats)
  end

  defp generate_report(stats) do
    """
    ═══════════════════════════════════════════════════════════════
    TORRENT EXTENSION ANALYSIS REPORT
    ═══════════════════════════════════════════════════════════════
    Generated: #{DateTime.utc_now()}

    SUMMARY
    ───────────────────────────────────────────────────────────────
    Files Processed:      #{stats.files_processed}
    Torrents Analyzed:    #{stats.torrents_analyzed}
    Total Unique Exts:    #{MapSet.size(stats.total_extensions)}
    Classified:           #{MapSet.size(stats.classified)}
    Not Found:            #{MapSet.size(stats.not_found)}
    Noise/Ignored:        #{MapSet.size(stats.noise)}


    ═══════════════════════════════════════════════════════════════
    UNCLASSIFIED EXTENSIONS (NOT_FOUND)
    ═══════════════════════════════════════════════════════════════
    These extensions should be reviewed for addition to ExtCat:

    #{format_extensions_with_frequency(stats.not_found, stats.extension_frequency)}


    ═══════════════════════════════════════════════════════════════
    NOISE EXTENSIONS (Detected but Ignored)
    ═══════════════════════════════════════════════════════════════
    #{format_extensions_with_frequency(stats.noise, stats.extension_frequency)}


    ═══════════════════════════════════════════════════════════════
    CATEGORY DISTRIBUTION
    ═══════════════════════════════════════════════════════════════
    #{format_category_counts(stats.category_counts)}


    ═══════════════════════════════════════════════════════════════
    ALL EXTENSIONS BY FREQUENCY
    ═══════════════════════════════════════════════════════════════
    #{format_all_extensions_by_frequency(stats.extension_frequency)}


    ═══════════════════════════════════════════════════════════════
    CLASSIFIED EXTENSIONS
    ═══════════════════════════════════════════════════════════════
    #{format_extensions_with_frequency(stats.classified, stats.extension_frequency)}

    #{if stats.errors != [] do
      """

      ═══════════════════════════════════════════════════════════════
      ERRORS
      ═══════════════════════════════════════════════════════════════
      #{format_errors(stats.errors)}
      """
    else
      ""
    end}
    """
  end

  defp format_extensions_with_frequency(ext_set, frequency_map) do
    ext_set
    |> MapSet.to_list()
    |> Enum.map(fn ext -> {ext, Map.get(frequency_map, ext, 0)} end)
    |> Enum.sort_by(fn {_ext, count} -> -count end)
    |> Enum.map(fn {ext, count} ->
      "  #{String.pad_trailing(ext, 20)} (#{count} occurrences)"
    end)
    |> Enum.join("\n")
    |> case do
      "" -> "  (none)"
      result -> result
    end
  end

  defp format_category_counts(counts) do
    counts
    |> Enum.sort_by(fn {_cat, count} -> -count end)
    |> Enum.map(fn {cat, count} ->
      "  #{String.pad_trailing(to_string(cat), 30)} #{count}"
    end)
    |> Enum.join("\n")
    |> case do
      "" -> "  (none)"
      result -> result
    end
  end

  defp format_all_extensions_by_frequency(frequency_map) do
    frequency_map
    |> Enum.sort_by(fn {_ext, count} -> -count end)
    # Top 100
    |> Enum.take(100)
    |> Enum.map(fn {ext, count} ->
      classification = ExtCat.get(ext)

      status =
        case classification do
          :not_found -> "❌ NOT_FOUND"
          :noise_by_ext -> "🔇 NOISE"
          cat -> "✓ #{cat}"
        end

      "  #{String.pad_trailing(ext, 15)} #{String.pad_leading(to_string(count), 6)} - #{status}"
    end)
    |> Enum.join("\n")
  end

  defp format_errors(errors) do
    errors
    # Limit to first 20 errors
    |> Enum.take(20)
    |> Enum.map(fn {file, reason} -> "  #{file}: #{reason}" end)
    |> Enum.join("\n")
  end

  defp print_summary(stats) do
    IO.puts("""

    ═══════════════════════════════════════════════════════════════
    📊 QUICK SUMMARY
    ═══════════════════════════════════════════════════════════════
    """)

    IO.puts("Total Extensions:     #{MapSet.size(stats.total_extensions)}")
    IO.puts("✅ Classified:        #{MapSet.size(stats.classified)}")
    IO.puts("❌ Not Found:         #{MapSet.size(stats.not_found)}")
    IO.puts("🔇 Noise:             #{MapSet.size(stats.noise)}")

    if MapSet.size(stats.not_found) > 0 do
      IO.puts("\n🎯 TOP UNCLASSIFIED EXTENSIONS:")

      stats.not_found
      |> MapSet.to_list()
      |> Enum.map(fn ext -> {ext, Map.get(stats.extension_frequency, ext, 0)} end)
      |> Enum.sort_by(fn {_ext, count} -> -count end)
      |> Enum.take(20)
      |> Enum.each(fn {ext, count} ->
        IO.puts("   #{String.pad_trailing(ext, 15)} (#{count} times)")
      end)
    end

    IO.puts("\n═══════════════════════════════════════════════════════════════\n")
  end
end

TorrentAnalyzer.run()
