defmodule UTMNoiseFilterSync do
  @scr_base ~w(screenshot screenlist scr screen scrlist capture)
  @scr_plural Enum.map(@scr_base, &(&1 <> "s"))
  @discard_words ["thumbnails", "thumbs", "desktop"]
  @scr_patterns @scr_base ++ @scr_plural
  @cover_patterns ~w(covers thumb thumbnail poster front)
  @scr_word "scr"
  @cover_word "cover"
  @bitcomet_padding_noise "padding"
  @year_like_start 1600
  @year_like_end 2999
  def noise_filter(token) do
    cond do
      token in @discard_words -> nil
      is_number_noise?(token) -> nil
      token in @scr_patterns -> @scr_word
      token in @cover_patterns -> @cover_word
      String.starts_with?(token, @bitcomet_padding_noise) -> nil
      true -> token
    end
  end
  defp is_number_noise?(token) do
    case Integer.parse(token) do
      :error -> false
      {n, _remainder} when n < @year_like_start or n > @year_like_end -> true
      {_parsed_value, _rest_string} -> false
    end
  end
end