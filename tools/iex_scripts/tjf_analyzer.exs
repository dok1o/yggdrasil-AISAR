#!/usr/bin/env elixir

# TFJAnalyzer - Torrent File JSON Analyzer
# Load in iex: c("tfj_analyzer.exs")
# Run: TFJAnalyzer.run("/path/to/json/folder")

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
  @raw_audio ~w(mp3 flac m4a m4b mka ape wav ogg opus wma aac ac3)
  @raw_image ~w(jpg jpeg png webp avif)
  @raw_anim_image ~w(apng gif ugoira)
  @raw_video ~w(mkv mp4 avi webm flv 3gp wmv mpg mpeg mp2 mov)
  @raw_text ~w(txt md htm html mhtml mht nfo info log diz rtf csv)
  @raw_book ~w(pdf fb2 cbz cbr epub cb7 cba cbt mobi doc docx odt djvu djv)
  @raw_archive ~w(zip zst xz gz rar 7z tar gzip tgz tzst txz)
  @raw_mdf ~w(mdf blake3)
  @raw_torrent ~w(torrent magnet)
  @raw_links ~w(url webloc website lnk link)
  @raw_ai_by_ext ~w(gguf safetensors pt pth ckpt onnx h5 hdf5 pb tflite)

  @raw_playlist ~w(m3u pls cue m3u8 xspf asx fpl)
  @raw_subtitles ~w(srt ass ssa vtt smi sub sup pgs idx)
  @raw_spec_audio ~w(fm accurip oga aif aiff wave wv tta tak dsf dff it s3m mptm mid midi kar aa aax cdg lrc mod xm ra spx alac)
  @raw_spec_image ~w(bmp heic heif jxl qoi tif tiff cr2 cr3 nef arw dng orf rw2 raf pef srw eps cdr wmf emf psb xcf kra afphoto ktx ktx2 exr hdr svg ai dds tga psd raw jp2 j2k lrf)
  @raw_spec_video ~w(m2v m4v ogm ogv rm rmvb divx asf qt rv av1 ffp swf bik bik2 bk2 mts braw hevc lytx)
  @raw_disc_video ~w(vob m2ts ts dts ifo clpi mpls bdmv bdjo)
  @raw_spec_text ~w(man manifest version ver azw azw3 chm hlp syslog page pages asc ppt pptx odp key qxp pub xls xlsx ods zim msg desc description reg opf org ics vcf par par2 nzb toc)
  @raw_spec_arch ~w(z bz2 lzma lz4 lha lzh lzo tlz br r00)
  @raw_mount_disc ~w(iso mds img vmdk vdi nrg ccd cdi wim esd swm ima)
  @raw_consoles ~w(nes smc sfc gen smd gb gbc gba n64 nds nsp xci pbp cso cci chd psv gdi a26 pce neo cia wad wbfs rom nsz)
  @raw_exec_win ~w(exe msi)
  @raw_exec_linux ~w(deb rpm appimage elf)
  @raw_exec_mac ~w(dmg app pkg mpkg)
  @raw_spec_exec ~w(ocx flatpak flatpakref snap so dll scr com sys jar war ear class cmd ps1 vbs wsf msix msp wasm cab gem run)
  @raw_exec_firmware ~w(inf fw uef)
  @raw_exec_mobile ~w(apk aab xapk obb ipa)
  @raw_source_code ~w(c h r f sh py ex exs erl cpp hpp hs bat js wl rs go java cs swift kt scala svelte vue rb php lua lisp pl bash zsh fish pas f90 f95 for cls vbp targets)
  @raw_dev_web_project ~w(css asp aspx browser)
  @raw_dev_config ~w(yaml yml toml ini conf config cfg cf env make cmake lib ftp properties prefs dockerfile)
  @raw_data_creative ~w(als flp rpp band cproj logic)
  @raw_data_binary ~w(bin pak pack package dat dat0 dat1 dat2 data blob)
  @raw_data_game_assets ~w(map umap unity unity3d u3d godot asset assets uasset utoc ucas res ress resource resources vdf vpk acf bsp bundle repack cgm rne ahk)
  @raw_data_software_assets ~w(ico icon icns cur)
  @raw_data_database ~w(sqlite db sqlite3 sql mdb pdb accdb)
  @raw_data_json ~w(json jsonl ndjson wheel)
  @raw_data_xml ~w(xml xsd xslt)
  @raw_data_tabular ~w(tsv parquet arrow feather orc tbl)
  @raw_data_3d_model ~w(obj stl fbx gltf glb blend 3ds dae usd usdz dwg dxf step stp iges igs f3d fcstd prc wrl wrz)
  @raw_data_scientific ~w(netcdf nc fits nii root mat mml tex bib sty ipynb nb dcm)
  @raw_data_geospatial ~w(shp dbf geotiff kml kmz gpx osm geojson tiger world)
  @raw_data_font ~w(ttf otf woff woff2 eot ttc)

  @raw_noise_by_ext ~w(tmp temp dmp dump bak back backup bup crash mem old crdownload part cache gpg pgp enc aes age sig crypto chk checksum sfv crc32 md5 sha sha1 sha256 sha512 hash lock cert crt cer keystore crl csr cat pem lic)

  @meta_noise ~w(security policy license)

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
      @raw_data_binary,
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
      @raw_noise_by_ext,
      @meta_noise
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
  @data_binary Map.new(@raw_data_binary, &{&1, :data_binary})
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
            |> Map.merge(@data_binary)
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

  @noise_by_ext Map.new(@raw_noise_by_ext, &{&1, :noise})
  @meta_noise Map.new(@meta_noise, &{&1, :noise})

  @all_cats Map.merge(@base_cats, @add_cats)
            |> Map.merge(@noise_by_ext)
            |> Map.merge(@meta_noise)

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
  @type ext_based_fmime_bitmap :: <<_::48>>

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
    :ai_by_ext,
    :reserved_01,
    :reserved_02,
    :reserved_03,
    :reserved_04
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
    :reserved_05
  ]
  @various_data_fmimes [
    :data_creative,
    :data_binary,
    :data_game_assets,
    :data_software_assets,
    :data_database,
    :data_json,
    :data_xml,
    :data_tabular,
    :data_3d_model,
    :data_scientific,
    :data_geospatial,
    :data_font
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

          :noise ->
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
    case MapSet.size(base_cats) > 0 do
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
    # 48 bits = 12 hex chars
    |> String.pad_leading(12, "0")
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

#!/usr/bin/env elixir

# TFJAnalyzer - Torrent File JSON Analyzer
# Load in iex: c("tfj_analyzer.exs")
# Run: TFJAnalyzer.run("/path/to/json/folder")

defmodule TFJAnalyzer do
  @moduledoc """
  Analyzes torrent JSON files focusing on token frequency and language-script distribution.
  """

  defstruct [
    :folder_path,
    files_processed: 0,
    errors: [],
    total_tokens: %{},
    tokens_by_script: %{},
    categories: %{},
    extensions: %{},
    system_flags: %{},
    scripts: %{},
    file_counts: [],
    total_sizes: [],
    piece_lengths: [],
    leaf_dir_counts: [],
    token_lengths: [],
    sample_torrents: []
  ]

  def run(folder_path) when is_binary(folder_path) do
    IO.puts("╔══════════════════════════════════════════════════════╗")
    IO.puts("║         TORRENT FILE JSON TOKEN ANALYZER            ║")
    IO.puts("╚══════════════════════════════════════════════════════╝")
    IO.puts("")
    IO.puts("Folder: #{folder_path}")

    stats = %__MODULE__{folder_path: folder_path}

    case File.ls(folder_path) do
      {:ok, files} ->
        json_files = Enum.filter(files, &String.ends_with?(&1, ".json"))
        IO.puts("Found #{length(json_files)} JSON files to process...")
        IO.puts("")

        {stats, _} =
          Enum.reduce(json_files, {stats, 1}, fn file, {acc, idx} ->
            if rem(idx, 100) == 0, do: IO.write("\rProcessing: #{idx}/#{length(json_files)}")
            {process_file(folder_path, file, acc), idx + 1}
          end)

        IO.write("\rProcessing complete.#{String.duplicate(" ", 40)}\n")

        report = generate_report(stats)
        report_path = Path.join(folder_path, "tfj_analysis_report.log")

        case File.write(report_path, report) do
          :ok ->
            IO.puts("\n✓ Report generated: #{report_path}")

          {:error, reason} ->
            IO.puts("\n✗ Error writing report: #{reason}")
        end

        stats

      {:error, reason} ->
        IO.puts("✗ Error accessing folder: #{reason}")
        stats
    end
  end

  defp process_file(folder_path, filename, stats) do
    filepath = Path.join(folder_path, filename)

    case File.read(filepath) do
      {:ok, content} ->
        case SimpleJson.decode(content) do
          {:ok, data} when is_map(data) ->
            analyze_record(data, filename, stats)

          {:ok, _other} ->
            add_error(stats, filename, "Not a JSON object")

          {:error, reason} ->
            add_error(stats, filename, "Parse error: #{reason}")
        end

      {:error, reason} ->
        add_error(stats, filename, "File read error: #{reason}")
    end
  end

  defp add_error(stats, filename, reason) do
    %{
      stats
      | errors: [{filename, reason} | stats.errors],
        files_processed: stats.files_processed + 1
    }
  end

  defp analyze_record(data, filename, stats) do
    stats = %{stats | files_processed: stats.files_processed + 1}

    # Extract dominant script
    script = get_value(data, "dominant_script") || "unknown"
    stats = update_map_counter(stats, :scripts, script)

    # Process tokens
    tokens = get_value(data, "tokens") || []
    stats = process_tokens(tokens, script, stats)

    # Process basic_categories
    stats = process_list_field(data, "basic_categories", stats, :categories)

    # Process extensions
    stats = process_list_field(data, "extensions", stats, :extensions)

    # Process system flags
    stats = process_list_field(data, "system", stats, :system_flags)

    # Collect numeric fields
    stats = collect_numeric(data, "file_count", stats, :file_counts)
    stats = collect_numeric(data, "total_size", stats, :total_sizes)
    stats = collect_numeric(data, "piece_length", stats, :piece_lengths)
    stats = collect_numeric(data, "leaf_dir_count", stats, :leaf_dir_counts)

    # Store sample torrent name
    torrent_name = get_value(data, "torrent_name")
    infohash = get_value(data, "infohash")
    stats = maybe_add_sample(stats, torrent_name, infohash, script)

    stats
  end

  defp get_value(data, key) when is_map(data) and is_binary(key) do
    Map.get(data, key)
  end

  defp get_value(_, _), do: nil

  defp update_map_counter(stats, field, key) do
    Map.update!(stats, field, fn map ->
      Map.update(map, key, 1, fn existing -> existing + 1 end)
    end)
  end

  defp process_tokens(tokens, script, stats) when is_list(tokens) do
    Enum.reduce(tokens, stats, fn token, acc ->
      case token do
        %{"token" => t, "count" => c} when is_binary(t) and is_integer(c) ->
          add_token(acc, t, c, script)

        t when is_binary(t) ->
          add_token(acc, t, 1, script)

        _ ->
          acc
      end
    end)
  end

  defp process_tokens(_, _, stats), do: stats

  defp add_token(stats, token, count, script) do
    token_len = String.length(token)

    # Extract, update with Map.update, put back
    new_total_tokens =
      Map.update(stats.total_tokens, token, count, fn existing ->
        existing + count
      end)

    new_tokens_by_script =
      Map.update(stats.tokens_by_script, script, %{token => count}, fn tokens_map ->
        Map.update(tokens_map, token, count, fn existing -> existing + count end)
      end)

    new_token_lengths = [token_len | stats.token_lengths]

    %{
      stats
      | total_tokens: new_total_tokens,
        tokens_by_script: new_tokens_by_script,
        token_lengths: new_token_lengths
    }
  end

  defp process_list_field(data, key, stats, field_key) do
    items = get_value(data, key)

    if is_list(items) do
      updated_map =
        Enum.reduce(items, Map.get(stats, field_key), fn item, acc ->
          if is_binary(item) do
            Map.update(acc, item, 1, fn existing -> existing + 1 end)
          else
            acc
          end
        end)

      Map.put(stats, field_key, updated_map)
    else
      stats
    end
  end

  defp collect_numeric(data, key, stats, field_key) do
    value = get_value(data, key)

    if is_integer(value) do
      Map.update(stats, field_key, [value], fn list -> [value | list] end)
    else
      stats
    end
  end

  defp maybe_add_sample(stats, torrent_name, infohash, script) do
    cond do
      !is_binary(torrent_name) ->
        stats

      length(stats.sample_torrents) >= 20 ->
        stats

      true ->
        sample = %{
          name: String.slice(torrent_name, 0, 60),
          hash: infohash,
          script: script
        }

        %{stats | sample_torrents: [sample | stats.sample_torrents]}
    end
  end

  # ═══════════════════════════════════════════════════════════════
  # REPORT GENERATION
  # ═══════════════════════════════════════════════════════════════

  defp generate_report(stats) do
    script_analysis = analyze_scripts(stats)
    cross_script_tokens = find_cross_script_tokens(stats)
    token_length_stats = calculate_token_length_stats(stats.token_lengths)

    """
    ═══════════════════════════════════════════════════════════════
    TORRENT FILE JSON TOKEN ANALYSIS REPORT
    ═══════════════════════════════════════════════════════════════
    Generated: #{DateTime.utc_now() |> DateTime.to_string()}
    Source: #{stats.folder_path}

    ═══════════════════════════════════════════════════════════════
    SUMMARY
    ═══════════════════════════════════════════════════════════════
    Files Processed:          #{stats.files_processed}
    Unique Tokens:            #{map_size(stats.total_tokens)}
    Total Token Occurrences:  #{sum_values(stats.total_tokens)}
    Scripts Detected:         #{map_size(stats.scripts)}
    Categories Found:         #{map_size(stats.categories)}
    Unique Extensions:        #{map_size(stats.extensions)}
    System Flags Found:       #{map_size(stats.system_flags)}
    Errors:                   #{length(stats.errors)}


    ═══════════════════════════════════════════════════════════════
    SCRIPT DISTRIBUTION
    ═══════════════════════════════════════════════════════════════
    #{format_script_distribution(stats.scripts, stats.files_processed)}


    ═══════════════════════════════════════════════════════════════
    TOKEN ANALYSIS BY SCRIPT
    ═══════════════════════════════════════════════════════════════
    #{format_script_token_analysis(script_analysis)}


    ═══════════════════════════════════════════════════════════════
    TOP 100 TOKENS (OVERALL)
    ═══════════════════════════════════════════════════════════════
    #{format_top_tokens(stats.total_tokens, 32 * 1_024)}


    ═══════════════════════════════════════════════════════════════
    CROSS-SCRIPT TOKENS (appear in 3+ scripts)
    ═══════════════════════════════════════════════════════════════
    #{format_cross_script_tokens(cross_script_tokens, stats.total_tokens)}


    ═══════════════════════════════════════════════════════════════
    TOKEN LENGTH STATISTICS
    ═══════════════════════════════════════════════════════════════
    #{format_token_length_stats(token_length_stats)}


    ═══════════════════════════════════════════════════════════════
    CATEGORY DISTRIBUTION
    ═══════════════════════════════════════════════════════════════
    #{format_distribution(stats.categories, "Category", "Files")}


    ═══════════════════════════════════════════════════════════════
    EXTENSION DISTRIBUTION (TOP 50)
    ═══════════════════════════════════════════════════════════════
    #{format_distribution(stats.extensions, "Extension", "Files", 50)}


    ═══════════════════════════════════════════════════════════════
    SYSTEM FLAGS DISTRIBUTION
    ═══════════════════════════════════════════════════════════════
    #{format_distribution(stats.system_flags, "Flag", "Files")}


    ═══════════════════════════════════════════════════════════════
    NUMERIC FIELD STATISTICS
    ═══════════════════════════════════════════════════════════════
    #{format_numeric_field("File Count", stats.file_counts, :integer)}
    #{format_numeric_field("Total Size", stats.total_sizes, :bytes)}
    #{format_numeric_field("Piece Length", stats.piece_lengths, :bytes)}
    #{format_numeric_field("Leaf Dir Count", stats.leaf_dir_counts, :integer)}


    ═══════════════════════════════════════════════════════════════
    SAMPLE TORRENTS
    ═══════════════════════════════════════════════════════════════
    #{format_sample_torrents(stats.sample_torrents)}

    #{format_errors_section(stats.errors)}
    """
  end

  defp analyze_scripts(stats) do
    stats.tokens_by_script
    |> Enum.map(fn {script, tokens} ->
      sorted = sort_map_by_value(tokens)
      total = sum_values(tokens)
      unique = map_size(tokens)
      file_count = Map.get(stats.scripts, script, 0)

      %{
        script: script,
        file_count: file_count,
        unique_tokens: unique,
        total_occurrences: total,
        top_tokens: Enum.take(sorted, 10),
        other_tokens: Enum.drop(sorted, 10) |> Enum.take(15)
      }
    end)
    |> Enum.sort_by(fn x -> x.file_count end, :desc)
  end

  defp find_cross_script_tokens(stats) do
    stats.tokens_by_script
    |> Enum.flat_map(fn {_script, tokens} -> Map.keys(tokens) end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_token, script_count} -> script_count >= 3 end)
    |> Enum.sort_by(fn {_token, count} -> count end, :desc)
  end

  defp calculate_token_length_stats([]), do: nil

  defp calculate_token_length_stats(lengths) do
    sorted = Enum.sort(lengths)
    count = length(sorted)
    sum = Enum.sum(sorted)

    %{
      count: count,
      min: List.first(sorted),
      max: List.last(sorted),
      avg: Float.round(sum / count, 2),
      median: median(sorted),
      distribution: Enum.frequencies(sorted) |> Enum.sort_by(fn {len, _} -> len end)
    }
  end

  # ═══════════════════════════════════════════════════════════════
  # FORMATTING HELPERS
  # ═══════════════════════════════════════════════════════════════

  defp format_script_distribution(scripts, total_files) do
    scripts
    |> sort_map_by_value()
    |> Enum.map(fn {script, count} ->
      pct = Float.round(count / max(total_files, 1) * 100, 1)
      bar_len = trunc(pct / 5)
      bar = String.duplicate("█", bar_len) <> String.duplicate("░", 20 - bar_len)
      "  #{pad(script, 10)} #{pad("#{count}", 6)} #{bar} #{pct}%"
    end)
    |> Enum.join("\n")
  end

  defp format_script_token_analysis(script_stats) do
    script_stats
    |> Enum.map(fn %{
                     script: script,
                     file_count: fc,
                     unique_tokens: uq,
                     total_occurrences: tot,
                     top_tokens: top,
                     other_tokens: other
                   } ->
      dominant_str =
        top
        |> Enum.take(5)
        |> Enum.map(fn {t, c} -> "#{t}(#{c})" end)
        |> Enum.join(", ")

      secondary_str =
        if Enum.drop(top, 5) != [] or other != [] do
          sec = Enum.drop(top, 5) ++ other

          sec_str =
            sec
            |> Enum.take(10)
            |> Enum.map(fn {t, c} -> "#{t}(#{c})" end)
            |> Enum.join(", ")

          "\n      Secondary: #{sec_str}"
        else
          ""
        end

      """
      ┌─ [#{script}] ─ #{fc} files, #{uq} unique tokens, #{tot} occurrences
      │  Dominant: #{dominant_str}#{secondary_str}
      └────────────────────────────────────────────────────────
      """
    end)
    |> Enum.join("\n")
  end

  defp format_top_tokens(tokens, limit) do
    tokens
    |> sort_map_by_value()
    |> Enum.take(limit)
    |> Enum.chunk_every(2)
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, row} ->
      chunk
      |> Enum.with_index()
      |> Enum.map(fn {{token, count}, col} ->
        idx = (row - 1) * 2 + col + 1
        "#{pad("#{idx}.", 4)} #{pad(truncate(token, 25), 27)} #{pad("#{count}", 6)}"
      end)
      |> Enum.join("  │  ")
    end)
    |> Enum.join("\n")
  end

  defp format_cross_script_tokens(cross_tokens, total_tokens) do
    if cross_tokens == [] do
      "  (No tokens appear in 3 or more scripts)"
    else
      cross_tokens
      |> Enum.take(50)
      |> Enum.map(fn {token, script_count} ->
        total = Map.get(total_tokens, token, 0)
        "  #{pad(token, 30)} #{pad("#{script_count} scripts", 12)} #{pad("total: #{total}", 10)}"
      end)
      |> Enum.join("\n")
    end
  end

  defp format_token_length_stats(nil) do
    "  (No token data)"
  end

  defp format_token_length_stats(stats) do
    dist_str =
      stats.distribution
      |> Enum.take(20)
      |> Enum.map(fn {len, count} ->
        bar_len = min(trunc(count / max(stats.count, 1) * 100), 30)
        bar = String.duplicate("█", bar_len)
        "#{pad("#{len}", 3)} │ #{pad("#{count}", 6)} #{bar}"
      end)
      |> Enum.join("\n")

    """
      Min: #{stats.min} | Max: #{stats.max} | Avg: #{stats.avg} | Median: #{stats.median}

      Length Distribution:
      Len │ Count  Histogram
      ────┼──────────────────────────────────────
    #{dist_str}
    """
  end

  defp format_distribution(items, label, value_label, limit \\ :infinity) do
    if map_size(items) == 0 do
      "  (No data)"
    else
      sorted = sort_map_by_value(items)
      limited = if limit == :infinity, do: sorted, else: Enum.take(sorted, limit)
      total = sum_values(items)

      header = "  #{pad(label, 25)} #{pad(value_label, 8)} #{pad("Pct", 7)}"

      separator =
        "  #{String.duplicate("─", 25)} #{String.duplicate("─", 8)} #{String.duplicate("─", 7)}"

      rows =
        limited
        |> Enum.map(fn {item, count} ->
          pct = Float.round(count / max(total, 1) * 100, 1)
          "  #{pad(item, 25)} #{pad("#{count}", 8)} #{pad("#{pct}%", 7)}"
        end)
        |> Enum.join("\n")

      if limit != :infinity and length(sorted) > limit do
        "#{header}\n#{separator}\n#{rows}\n  ... and #{length(sorted) - limit} more"
      else
        "#{header}\n#{separator}\n#{rows}"
      end
    end
  end

  defp format_numeric_field(label, [], _type) do
    "  #{label}: (No data)"
  end

  defp format_numeric_field(label, values, type) do
    sorted = Enum.sort(values)
    count = length(sorted)
    sum = Enum.sum(sorted)
    min_val = List.first(sorted)
    max_val = List.last(sorted)
    avg = Float.round(sum / count, 2)
    med = median(sorted)

    {min_str, max_str, sum_str, avg_str, med_str} =
      case type do
        :bytes ->
          {format_bytes(min_val), format_bytes(max_val), format_bytes(sum), format_bytes(avg),
           format_bytes(med)}

        :integer ->
          {"#{min_val}", "#{max_val}", "#{sum}", "#{avg}", "#{med}"}
      end

    """
      #{label}:
        Count: #{count}
        Range: #{min_str} ── #{max_str}
        Sum:   #{sum_str}
        Avg:   #{avg_str}
        Med:   #{med_str}
    """
  end

  defp format_bytes(n) when is_float(n) and n >= 1_000_000_000_000,
    do: "#{Float.round(n / 1_000_000_000_000, 2)} TB"

  defp format_bytes(n) when is_integer(n) and n >= 1_000_000_000_000,
    do: "#{Float.round(n / 1_000_000_000_000, 2)} TB"

  defp format_bytes(n) when is_float(n) and n >= 1_000_000_000,
    do: "#{Float.round(n / 1_000_000_000, 2)} GB"

  defp format_bytes(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{Float.round(n / 1_000_000_000, 2)} GB"

  defp format_bytes(n) when is_float(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 2)} MB"

  defp format_bytes(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 2)} MB"

  defp format_bytes(n) when is_float(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 2)} KB"
  defp format_bytes(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 2)} KB"
  defp format_bytes(n) when is_float(n), do: "#{Float.round(n, 0)} B"
  defp format_bytes(n) when is_integer(n), do: "#{n} B"

  defp format_sample_torrents([]) do
    "  (No samples collected)"
  end

  defp format_sample_torrents(samples) do
    samples
    |> Enum.reverse()
    |> Enum.take(15)
    |> Enum.map(fn %{name: name, hash: hash, script: script} ->
      base = "  [#{pad(script, 8)}] #{name}"
      if hash, do: base <> "\n             #{hash}", else: base
    end)
    |> Enum.join("\n\n")
  end

  defp format_errors_section([]), do: ""

  defp format_errors_section(errors) do
    error_lines =
      errors
      |> Enum.reverse()
      |> Enum.take(100)
      |> Enum.map(fn {file, reason} -> "  [#{file}] #{reason}" end)
      |> Enum.join("\n")

    extra =
      if length(errors) > 100, do: "\n  ... and #{length(errors) - 100} more errors", else: ""

    """
    ═══════════════════════════════════════════════════════════════
    ERRORS (#{length(errors)})
    ═══════════════════════════════════════════════════════════════
    #{error_lines}#{extra}
    """
  end

  # ═══════════════════════════════════════════════════════════════
  # UTILITY FUNCTIONS
  # ═══════════════════════════════════════════════════════════════

  defp sort_map_by_value(map) do
    map
    |> Enum.map(fn {k, v} -> {k, v} end)
    |> Enum.sort_by(fn {_k, v} -> v end, :desc)
  end

  defp sum_values(map), do: map |> Map.values() |> Enum.sum()

  defp median([]), do: 0

  defp median(sorted) do
    mid = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  defp pad(str, len) when is_binary(str) do
    str_len = String.length(str)

    if str_len >= len do
      String.slice(str, 0, len)
    else
      str <> String.duplicate(" ", len - str_len)
    end
  end

  defp pad(num, len) when is_number(num), do: pad("#{num}", len)

  defp truncate(str, max_len) when byte_size(str) <= max_len, do: str

  defp truncate(str, max_len) do
    String.slice(str, 0, max_len - 3) <> "..."
  end
end

# Allow running directly: elixir tfj_analyzer.exs <path>
if System.argv() != [] do
  TFJAnalyzer.run(hd(System.argv()))
end
