defmodule PFClassifierSync do
  import Bitwise
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
    :ref,
    :plugin,
    :reserved_01,
    :reserved_02
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
  def classify_ext_list(ext_list), do: do_classify(ext_list)
  def decode_fmime_bitmap(hex_string) do
    {int_value, ""} = Integer.parse(hex_string, 16)
    int_value
  end
  def which_categories_present(hex_string) do
    {bitmask, ""} = Integer.parse(hex_string, 16)
    @ext_based_fmimes
    |> Enum.with_index()
    |> Enum.filter(fn {_cat, idx} -> (bitmask &&& 1 <<< idx) != 0 end)
    |> Enum.map(fn {cat, _idx} -> cat end)
  end
  defp do_classify(list) do
    {base_cats, spec_cats, data_cats, not_found, bitmap} =
      Enum.reduce(list, @r_tuple, fn ext, {base_acc, spec_acc, data_acc, nf_acc, bitmap_acc} ->
        case ExtCatSync.get(ext) do
          :ext_not_found ->
            {base_acc, spec_acc, data_acc, MapSet.put(nf_acc, ext), bitmap_acc}
          :noise ->
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