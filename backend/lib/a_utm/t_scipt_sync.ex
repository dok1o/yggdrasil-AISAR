defmodule TScriptSync do
  @type base_language_group() :: :en | :other
  @type freq_entry() :: {base_language_group(), pos_integer()}
  @type result :: %{
          frequencies: %{String.t() => freq_entry()},
          has_long?: bool(),
          ry_num?: bool()
        }
  @common_hash_length 20
  @resolutions_years_length_range 3..4
  @ry_range @resolutions_years_length_range
  @delimiters ~r/[^\p{L}\p{N}]+/u
  def process(strings_list), do: do_process(strings_list)
  defguardp digit?(char) when char in ?0..?9
  defguardp alphanum?(char) when char in ?a..?z or char in ?0..?9
  def do_process(strings_list) do
    init_acc = %{frequencies: %{}, has_long?: false, ry_num?: false}
    result = Enum.reduce(strings_list, init_acc, &process_string/2)
    {:ok, result}
  end
  defp process_string(text, acc) do
    text
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> String.split(@delimiters, trim: true)
    |> Enum.reduce(acc, &process_word/2)
  end
  defp process_word(word, acc) do
    case scan(word, 0, false) do
      :long -> %{acc | has_long?: true}
      :other_number -> acc
      :maybe_res_year_number -> bump_word(%{acc | ry_num?: true}, word, :other)
      :en -> bump_word(acc, word, :en)
      :non_en -> bump_word(acc, word, :other)
    end
  end
  defp scan(word, length, letter_found?)
  defp scan(_w, len, _lf?) when len >= @common_hash_length, do: :long
  defp scan(<<c::utf8, r::binary>>, l, false) when digit?(c), do: scan(r, l + 1, false)
  defp scan(<<c::utf8, r::binary>>, l, false) when c in ?a..?z, do: scan(r, l + 1, true)
  defp scan(<<_c::utf8, _::binary>>, _l, false), do: :non_en
  defp scan(<<c::utf8, r::binary>>, l, true) when alphanum?(c), do: scan(r, l + 1, true)
  defp scan(<<_::utf8, _::binary>>, _l, true), do: :non_en
  defp scan(<<>>, l, false) when l in @ry_range, do: :maybe_res_year_number
  defp scan(<<>>, _l, false), do: :other_number
  defp scan(<<>>, _l, true), do: :en
  defp bump_word(%{frequencies: freqs} = acc, word, lang) do
    new_freqs = Map.update(freqs, word, {lang, 1}, fn {^lang, n} -> {lang, n + 1} end)
    %{acc | frequencies: new_freqs}
  end
end