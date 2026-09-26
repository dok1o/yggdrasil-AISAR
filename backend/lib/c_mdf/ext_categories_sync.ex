defmodule ExtCatSync do
  @raw_audio ~w(mp3 flac m4a m4b mka ape wav ogg opus wma aac ac3)
  @raw_image ~w(jpg jpeg png webp avif)
  @raw_anim_image ~w(apng gif ugoira)
  @raw_video ~w(mkv mp4 avi webm flv 3gp wmv mpg mpeg mp2 mov)
  @raw_text ~w(txt md htm html mhtml mht nfo info log diz rtf csv)
  @raw_book ~w(pdf fb2 cbz cbr epub cb7 cba cbt mobi doc docx odt djvu djv)
  @raw_archive ~w(zip zst xz gz rar 7z tar gzip tgz tzst txz)
  @raw_mdf ~w(mdf)
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
  @raw_noise_by_ext ~w(tmp temp dmp dump bak back backup bup crash mem old crdownload part cache gpg pgp enc aes age sig crypto chk checksum sfv crc32 md5 sha sha1 sha256 sha512 blake3 hash lock cert crt cer keystore crl csr cat pem lic)
  @meta_noise ~w(security policy law license)
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
    raise "[ExtCatSync] Duplicate ext defined: #{inspect(duplicates)}"
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
  def get(extension), do: Map.get(@all_cats, extension, :ext_not_found)
  def all_categories(), do: Map.values(@all_cats)
  def extensions_for(category) do
    @all_cats
    |> Enum.filter(fn {_ext, cat} -> cat == category end)
    |> Enum.map(fn {ext, _cat} -> ext end)
  end
end