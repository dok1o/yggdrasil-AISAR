defmodule CBuffer do
  def idx_tab(main_table), do: :"#{main_table}_idx"
  def insert(main_table, idx, record, limit) do
    idx_table = idx_tab(main_table)
    first_key = elem(record, 0)
    case TryETS.lookup(main_table, idx) do
      [old_record] when tuple_size(old_record) >= 2 ->
        old_first_key = elem(old_record, 1)
        TryETS.match_delete(idx_table, {old_first_key, idx})
      [] ->
        :noop
    end
    main_record = Tuple.insert_at(record, 0, idx)
    TryETS.insert(main_table, main_record)
    TryETS.insert(idx_table, {first_key, idx})
    rem(idx + 1, limit)
  end
  def lookup_by_key(main_table, key) do
    idx_table = idx_tab(main_table)
    idx_table
    |> TryETS.lookup(key)
    |> Enum.flat_map(fn {^key, idx} ->
      TryETS.lookup(main_table, idx)
    end)
  end
  def take_by_key(main_table, key) do
    idx_table = idx_tab(main_table)
    indices = TryETS.lookup(idx_table, key)
    records =
      Enum.flat_map(indices, fn {^key, idx} ->
        TryETS.take(main_table, idx)
      end)
    TryETS.match_delete(idx_table, {key, :_})
    records
  end
end