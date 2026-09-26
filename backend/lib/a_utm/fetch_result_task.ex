defmodule ResultTask do
  require Logger
  @type base_language_group() :: :en | :other
  @type freq_entry() :: {base_language_group(), pos_integer()}
  @compile {:inline, []}
  @type ihv :: <<_::160>>
  @type nid :: ihv()
  @type nodev4 :: <<_::48>>
  @bloom_filter_cutoff_thr 128
  def process({ih, info_bin}, start_ms, save_tjf?) do
    do_process({ih, info_bin}, start_ms, save_tjf?)
  end
  defp do_process({ih, info_bin}, start_ms, save_tjf?) do
    case SimpleBencodeSync.decode(info_bin) do
      {:ok, info_dict} -> process_info_dict(ih, info_dict, start_ms, save_tjf?)
      {:error, reason} -> log_return_err(reason)
    end
  end
  defp process_info_dict(ih, info_dict, start_ms, save_tjf?) do
    {:ok, tcompact} = TCompactSync.build(info_dict)
    name = tcompact.torr_name
    utmf_maybe_tjf(ih, name, tcompact, start_ms, save_tjf?)
  end
  defp utmf_maybe_tjf(ih, name, tcompact, _start_ms, false) do
    {ts_flags, tc_flags, top_freqs, _cutoff_freqs} = process_data(name, tcompact)
    utmf_flags = Map.merge(ts_flags, tc_flags)
    _utmf_prepare = {ih, top_freqs, utmf_flags}
    :ok
  end
  defp utmf_maybe_tjf(ih, name, tcompact, start_ms, true) do
    {ts_flags, tc_flags, top_freqs, cutoff_freqs} = process_data(name, tcompact)
    tjf_prep = %{
      tokens: Enum.map(top_freqs, &format_token/1),
      tokens_cutoff: Enum.map(cutoff_freqs, &format_token/1)
    }
    categs = %{basic: tcompact.basic_categories, other: tcompact.other_categories}
    ih_hex = PrinterSync.full_hex(ih)
    final_tjf = build_tjf_json_fields(ih_hex, name, ts_flags, tc_flags, tjf_prep, categs)
    utmf_flags = Map.merge(ts_flags, tc_flags)
    _utmf_prepare = {ih, top_freqs, utmf_flags}
    GenS.TJFWriter.write(ih, final_tjf, start_ms)
  end
  defp build_tjf_json_fields(ih_hex, name, ts_flags, tc_flags, tjf_prep, categs) do
    tjf_flags =
      [
        {"en", tc_flags.has_en?},
        {"other", tc_flags.has_other?},
        {"long_words", ts_flags.has_long?},
        {"more_tokens", tc_flags.more_tokens?}
      ]
      |> Enum.filter(fn {_key, value} -> value end)
      |> Enum.map(fn {key, _value} -> key end)
    %{
      "infohash" => ih_hex,
      "name" => name,
      "tokens" => tjf_prep.tokens,
      "tokens_cutoff" => tjf_prep.tokens_cutoff,
      "flags" => tjf_flags,
      "basic_categories" => categs.basic,
      "other_categories" => categs.other
    }
    |> clean_map()
  end
  defp process_data(name, tcompact) do
    all_strings = list_all_strings(name, tcompact)
    {:ok, ts_result} = TScriptSync.process(all_strings)
    ts_flags = %{has_long?: ts_result.has_long?, ry_num?: ts_result.ry_num?}
    lang_freqs = apply_noise_filter(ts_result.frequencies)
    {unique_en_words, unique_other_words} = count_langs(lang_freqs)
    total_unique_words = unique_en_words + unique_other_words
    has_en? = unique_en_words > 0
    dominant_en? =
      case has_en? do
        false -> false
        true -> unique_en_words * 5 >= total_unique_words * 4
      end
    sorted_freqs =
      lang_freqs
      |> drop_langs()
      |> sort_freqs()
    total_tokens_count = length(sorted_freqs)
    tcompact_flags = %{
      has_en?: has_en?,
      has_other?: unique_other_words > 0,
      dominant_en?: dominant_en?,
      more_tokens?: total_tokens_count > @bloom_filter_cutoff_thr
    }
    {top_freqs, cutoff_freqs} = Enum.split(sorted_freqs, @bloom_filter_cutoff_thr)
    {ts_flags, tcompact_flags, top_freqs, cutoff_freqs}
  end
  defp list_all_strings(name, map) do
    [name | map.filenames_raw ++ map.leafdirs_raw ++ map.tree_dirs_raw]
  end
  defp format_token({token, 1}), do: token
  defp format_token({token, c}) when is_integer(c), do: %{"token" => token, "count" => c}
  defp count_langs(freqs) do
    Enum.reduce(freqs, {0, 0}, fn {_word, {lang, _count}}, {en, other} ->
      case lang do
        :en -> {en + 1, other}
        :other -> {en, other + 1}
      end
    end)
  end
  defp drop_langs(lang_freqs) do
    Enum.map(lang_freqs, fn {word, {_lang, count}} -> {word, count} end)
  end
  defp sort_freqs(freqs) do
    Enum.sort(freqs, fn {w1, c1}, {w2, c2} ->
      case c1 == c2 do
        false -> c1 > c2
        true -> w1 < w2
      end
    end)
  end
  defp apply_noise_filter(map) do
    Enum.reduce(map, %{}, fn {token, {lang, count}}, acc ->
      case UTMNoiseFilterSync.noise_filter(token) do
        nil ->
          acc
        mapped_token ->
          Map.update(acc, mapped_token, {lang, count}, &merge_e(&1, {lang, count}))
      end
    end)
  end
  defp merge_e({lang1, c1}, {lang2, c2}) do
    case c1 >= c2 do
      true -> {lang1, c1 + c2}
      false -> {lang2, c1 + c2}
    end
  end
  defp clean_map(map) when is_map(map), do: Map.reject(map, &empty_value?/1)
  defp empty_value?({_k, []}), do: true
  defp empty_value?({_k, nil}), do: true
  defp empty_value?({_k, v}) when is_map(v) and map_size(v) == 0, do: true
  defp empty_value?({_k, _v}), do: false
  defp log_return_err(reason) do
    Logger.warning("[ResultTask] Bencode decode failed: #{inspect(reason)}")
    {:error, :bencode_failed}
  end
end