defmodule TryETS do
  require Logger
  @type table_name :: atom()
  @type table_type :: :set | :ordered_set | :bag | :duplicate_bag
  @type visibility :: :public | :protected | :private
  @type concurrency :: boolean() | :auto
  @u16 65_535
  def create_named(name, type, visibility, read_concurrency, write_concurrency) do
    opts = build_opts(type, visibility, read_concurrency, write_concurrency)
    try do
      :ets.new(name, [:named_table | opts])
    rescue
      ArgumentError ->
        Logger.debug("[TryETS] Table #{name} already exists")
        case :ets.whereis(name) do
          :undefined -> name
          tid -> tid
        end
    end
  end
  def create_many_named(names, type, visibility, read_concurrency, write_concurrency) do
    Enum.each(names, fn name ->
      create_named(name, type, visibility, read_concurrency, write_concurrency)
    end)
  end
  def update_counter(table, key), do: do_update_existing(table, key, :infinite, 1)
  def update_counter(table, key, mode, max \\ :infinite, incr \\ 1) do
    case mode do
      :key -> do_update_existing(table, key, max, incr)
      :tuple -> do_update_wildcard(table, key, max, incr)
    end
  end
  def new_and_count(table, key, max \\ :infinite, incr \\ 1) do
    spec = build_spec(2, incr, max)
    try do
      :ets.update_counter(table, key, spec, {key, 0})
    rescue
      ArgumentError -> :noop
    catch
      :exit, _reason -> :noop
    end
  end
  def size(table) do
    case safe_ets(&:ets.info(&1, :size), table, nil, 0) do
      :undefined -> 0
      val -> val
    end
  end
  def buckets(table) do
    case safe_ets(&:ets.info(&1, :buckets), table, nil, 0) do
      :undefined -> 0
      val -> val
    end
  end
  def slot(table, slot_idx) do
    case safe_ets(&:ets.slot(&1, &2), table, slot_idx, []) do
      :"$end_of_table" -> :endpoint
      val -> val
    end
  end
  def upd_elem(table, key, element_spec) do
    safe_ets_2(&:ets.update_element(&1, &2, &3), table, key, element_spec, false)
  end
  def lookup(table, key), do: safe_ets(&:ets.lookup(&1, &2), table, key, [])
  def insert(table, object), do: safe_ets(&:ets.insert(&1, &2), table, object, true)
  def delete(table, key), do: safe_ets(&:ets.delete(&1, &2), table, key, true)
  def delete_all(table), do: safe_ets(&:ets.delete_all_objects/1, table, nil, true)
  def member?(table, key), do: safe_ets(&:ets.member(&1, &2), table, key, false)
  def take(table, key), do: safe_ets(&:ets.take(&1, &2), table, key, [])
  def next(table, key), do: safe_ets(&:ets.next(&1, &2), table, key, :"$end_of_table")
  def tab2list(table), do: safe_ets(&:ets.tab2list/1, table, nil, [])
  def first(table), do: safe_ets(&:ets.first/1, table, nil, :"$end_of_table")
  def match_delete(table, pattern), do: safe_ets(&:ets.match_delete(&1, &2), table, pattern, true)
  def select(table, match_spec), do: safe_ets(&:ets.select(&1, &2), table, match_spec, [])
  def select(table, match_spec, limit) do
    try do
      case :ets.select(table, match_spec, limit) do
        {results, _cont} -> results
        :"$end_of_table" -> []
      end
    rescue
      FunctionClauseError -> []
    catch
      :error, :badarg -> []
    end
  end
  def random_select(table, count) do
    table
    |> tab2list()
    |> Enum.shuffle()
    |> Enum.take(count)
  end
  def set_cooldown_ms(table, key, ttl_ms) do
    insert(table, {key, TimeSync.mono_ms() + ttl_ms})
  end
  def cooled_down_ms?(table, key) do
    case lookup(table, key) do
      [{^key, expires_at}] -> TimeSync.mono_ms() >= expires_at
      [] -> true
    end
  end
  def clean_expired(table) do
    now = TimeSync.mono_ms()
    expired =
      :ets.foldl(
        fn {key, expires_at}, acc ->
          case now >= expires_at do
            false -> acc
            true -> [key | acc]
          end
        end,
        [],
        table
      )
    Enum.each(expired, &delete(table, &1))
    :ok
  end
  defp safe_ets(fun, table, nil, default) do
    try do
      fun.(table)
    rescue
      FunctionClauseError -> default
    catch
      :error, :badarg -> default
    end
  end
  defp safe_ets(fun, table, arg, default) do
    try do
      fun.(table, arg)
    rescue
      FunctionClauseError -> default
    catch
      :error, :badarg -> default
    end
  end
  defp safe_ets_2(fun, table, arg1, arg2, default) do
    try do
      fun.(table, arg1, arg2)
    rescue
      FunctionClauseError -> default
    catch
      :error, :badarg -> default
    end
  end
  defp build_spec(pos, incr, :infinite), do: {pos, incr}
  defp build_spec(pos, incr, :u16), do: {pos, incr, @u16, @u16}
  defp build_spec(pos, incr, lim) when is_integer(lim), do: {pos, incr, lim, lim}
  defp do_update_existing(table, key, max, incr) do
    spec = build_spec(2, incr, max)
    try do
      :ets.update_counter(table, key, spec)
    rescue
      ArgumentError -> :noop
    catch
      :exit, _reason -> :noop
    end
  end
  defp do_update_wildcard(table, key, max, incr) do
    case :ets.lookup(table, key) do
      [] ->
        :noop
      rows ->
        case :ets.info(table, :type) do
          type when type in [:set] ->
            do_set_update(table, key, rows, max, incr)
          type when type in [:ordered_set, :bag, :duplicate_bag] ->
            do_non_set_update(table, key, rows, max, incr)
        end
    end
  end
  defp do_set_update(table, key, [sample | _], max, incr) do
    size = tuple_size(sample)
    vars = for i <- 1..(size - 1), do: :"$#{i}"
    counter_var = List.last(vars)
    match_pattern = List.to_tuple([key | vars])
    update_logic = build_update_logic(max, incr, counter_var)
    non_counter_vars = Enum.drop(vars, -1)
    result = List.to_tuple([key | non_counter_vars] ++ [update_logic])
    ms = [{match_pattern, [], [result]}]
    select_replace(table, ms)
  end
  defp build_update_logic(:infinite, incr, var), do: {:+, var, incr}
  defp build_update_logic(:u16, incr, var), do: {:min, @u16, {:+, var, incr}}
  defp build_update_logic(lim, incr, var), do: {:min, lim, {:+, var, incr}}
  defp select_replace(table, ms) do
    try do
      case :ets.select_replace(table, ms) do
        0 -> :error
        count -> count
      end
    rescue
      ArgumentError -> :error
    catch
      :exit, _reason -> :error
    end
  end
  defp do_non_set_update(table, _key, rows, max, incr) do
    updated_rows =
      Enum.map(rows, fn tuple ->
        size = tuple_size(tuple)
        counter_pos = size - 1
        old_val = elem(tuple, counter_pos)
        new_val = compute_new_value(old_val, incr, max)
        put_elem(tuple, counter_pos, new_val)
      end)
    try do
      Enum.each(rows, fn row -> :ets.delete_object(table, row) end)
      :ets.insert(table, updated_rows)
      length(updated_rows)
    rescue
      ArgumentError -> :noop
    catch
      :exit, _reason -> :noop
    end
  end
  defp compute_new_value(old, incr, :infinite), do: old + incr
  defp compute_new_value(old, incr, :u16), do: min(@u16, old + incr)
  defp compute_new_value(old, incr, lim) when is_integer(lim), do: min(lim, old + incr)
  defp build_opts(type, visibility, read_concurrency, write_concurrency) do
    [type, visibility]
    |> maybe_add_concurrency(:read_concurrency, read_concurrency)
    |> maybe_add_concurrency(:write_concurrency, write_concurrency)
  end
  defp maybe_add_concurrency(opts, key, :auto), do: [{key, :auto} | opts]
  defp maybe_add_concurrency(opts, key, true), do: [{key, true} | opts]
  defp maybe_add_concurrency(opts, _key, _), do: opts
end