defmodule MetadataCache do
  @ttl_seconds 120
  @md_cache_tab :utm_cache
  def get_cached_pieces(ih) do
    now = TimeSync.now()
    key = {ih}
    case TryETS.lookup(@md_cache_tab, key) do
      [{_key, pieces, expiry}] when expiry > now -> pieces
      _not_found -> %{}
    end
  end
  def cache_piece(ih, idx, data) do
    ttl = TimeSync.now() + @ttl_seconds
    key = {ih}
    pieces = get_cached_pieces(ih)
    val = Map.put(pieces, idx, data)
    TryETS.insert(@md_cache_tab, {key, val, ttl})
  end
  def clear(ih), do: :ets.match_delete(@md_cache_tab, {{ih}, :_, :_})
end