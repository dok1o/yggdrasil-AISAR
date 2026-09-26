defmodule GenS.YggPFScheduler do
  @moduledoc """
  Paint and scan scheduling (spec sections 23, 24, 25, 26, 27).

  Budgets per second:

      per active cursor   4 paint + 4 scan
      active cursors      2 (last and next, spec section 25)     => 16 q/s
      fixed prefix        1 paint + 1 scan                       =>  2 q/s

  The tick runs at 250 ms and emits a quarter of each per-second budget, carrying
  the fractional remainder forward so the rate is exact over a second without
  depending on precise timer delivery.

  ## Painting lags scanning (spec section 24)

  Scanning establishes density, density establishes the cursor, and only then does
  painting know which region to paint. So paint is withheld until at least one scan
  cycle has completed in the current epoch. `@paint_lag_ticks` sets the minimum.

  ## Initial scan slowdown (spec section 26)

  At each minute boundary every fnode would otherwise derive the same new prefix
  simultaneously and converge on the same handful of closest legacy nodes. Scans
  are therefore delayed by `YggPF.Cursor.initial_delay_ms/3`, proportional to
  cached fnode density over cached legacy density and jittered. Spec section 26 explicitly
  forbids replacing this with a fixed sleep.

  ## Testability

  Spec section 61 asks for observable scheduling behaviour rather than brittle wall-clock
  assertions, so all dispatch goes through an injectable `:emit` function and every
  query is counted in `stats/0`.
  """

  use GenServer
  require Logger

  alias YggPF.{Codec, Const, Cursor, Diag, Paint, Self}

  @tick_ms 250
  @diag_tick_ms 10_000
  @clean_tick_ms 5_000
  @ticks_per_second div(1_000, @tick_ms)
  @paint_lag_ticks 2

  defstruct cursor: nil,
            tick: 0,
            scan_gate_ms: 0,
            epoch_started_ms: 0,
            scanned_this_epoch: 0,
            carry: %{paint: 0.0, scan: 0.0, fixed_paint: 0.0, fixed_scan: 0.0},
            stats: %{paint: 0, scan: 0, fixed_paint: 0, fixed_scan: 0, epochs: 0, skipped_scan: 0},
            emit: nil,
            density: nil

  # ------------------------------------------------------------------ #
  # API                                                                 #
  # ------------------------------------------------------------------ #

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: name(opts))

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)

  @doc "Current counters. Spec section 61 prefers asserting on these over wall-clock timing."
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc "Current cursor state."
  def cursor(server \\ __MODULE__), do: GenServer.call(server, :cursor)

  @doc "Fold observed matching-yid counts in, possibly escalating the cursor (spec section 21)."
  def observe(server \\ __MODULE__, count), do: GenServer.cast(server, {:observe, count})

  @doc "Run one tick synchronously. Test hook - avoids waiting on timers."
  def tick_now(server \\ __MODULE__), do: GenServer.call(server, :tick_now)

  # ------------------------------------------------------------------ #
  # Callbacks                                                           #
  # ------------------------------------------------------------------ #

  @impl true
  def init(opts) do
    epoch = Keyword.get(opts, :epoch, Codec.current_epoch())

    st = %__MODULE__{
      cursor: Cursor.new(epoch),
      emit: Keyword.get(opts, :emit, &default_emit/2),
      density: Keyword.get(opts, :density, &default_density/0),
      epoch_started_ms: now_ms()
    }

    st = arm_scan_gate(st)

    Paint.create_tables()

    case Keyword.get(opts, :autotick, true) do
      true ->
        :timer.send_interval(@tick_ms, :tick)
        :timer.send_interval(@diag_tick_ms, :diag)
        :timer.send_interval(@clean_tick_ms, :clean)

      false ->
        :ok
    end

    {:ok, st}
  end

  @impl true
  def handle_call(:stats, _from, st), do: {:reply, st.stats, st}
  def handle_call(:cursor, _from, st), do: {:reply, st.cursor, st}
  def handle_call(:tick_now, _from, st), do: {:reply, :ok, do_tick(st)}

  @impl true
  def handle_cast({:observe, count}, st) do
    before = st.cursor.cursor
    cur = Cursor.observe(st.cursor, count)

    if cur.cursor != before do
      Logger.info("[YggPF] cursor escalated #{before} -> #{cur.cursor} (>#{Const.cursor_threshold()} yids)")
    end

    {:noreply, %{st | cursor: cur}}
  end

  @impl true
  def handle_info(:tick, st), do: {:noreply, do_tick(st)}

  def handle_info(:diag, st) do
    Diag.log_state(st.cursor.cursor)
    {:noreply, st}
  end

  def handle_info(:clean, st) do
    Paint.clean()
    {:noreply, st}
  end

  def handle_info(_other, st), do: {:noreply, st}

  # ------------------------------------------------------------------ #
  # Tick                                                                #
  # ------------------------------------------------------------------ #

  defp do_tick(st) do
    st
    |> roll_epoch()
    |> Map.update!(:tick, &(&1 + 1))
    |> dispatch_scan()
    |> dispatch_paint()
    |> dispatch_fixed()
  end

  # Epoch boundary: cursor resets to 0 (INV-012) and the scan gate is re-armed so
  # the population does not burst simultaneously (spec section 26).
  defp roll_epoch(st) do
    epoch = Codec.current_epoch()

    case epoch == st.cursor.epoch do
      true ->
        st

      false ->
        Logger.debug("[YggPF] epoch #{st.cursor.epoch} -> #{epoch}, cursor reset to 0")
        Paint.reset_epoch()

        %{
          st
          | cursor: Cursor.advance(st.cursor, epoch),
            epoch_started_ms: now_ms(),
            scanned_this_epoch: 0,
            stats: Map.update!(st.stats, :epochs, &(&1 + 1))
        }
        |> arm_scan_gate()
    end
  end

  defp arm_scan_gate(st) do
    {fnodes, legacy} = st.density.()
    delay = Cursor.initial_delay_ms(fnodes, legacy)
    %{st | scan_gate_ms: now_ms() + delay}
  end

  defp dispatch_scan(st) do
    cond do
      now_ms() < st.scan_gate_ms ->
        %{st | stats: Map.update!(st.stats, :skipped_scan, &(&1 + 1))}

      true ->
        cursors = Cursor.active(st.cursor)
        {n, st} = take(st, :scan, Const.scan_per_second() * length(cursors))

        emit_each(st, :scan, cursors, n)
        %{st | scanned_this_epoch: st.scanned_this_epoch + n}
    end
  end

  # Paint is withheld until scanning has had a chance to establish the cursor (spec section 24).
  defp dispatch_paint(st) when st.scanned_this_epoch == 0, do: st

  defp dispatch_paint(st) do
    case st.tick < @paint_lag_ticks do
      true ->
        st

      false ->
        cursors = Cursor.active(st.cursor)
        {n, st} = take(st, :paint, Const.paint_per_second() * length(cursors))
        emit_each(st, :paint, cursors, n)
        st
    end
  end

  defp dispatch_fixed(st) do
    {np, st} = take(st, :fixed_paint, Const.fixed_paint_per_second())
    {ns, st} = take(st, :fixed_scan, Const.fixed_scan_per_second())

    for _ <- 1..np//1, do: st.emit.(:fixed_paint, :fixed)
    for _ <- 1..ns//1, do: st.emit.(:fixed_scan, :fixed)
    st
  end

  defp emit_each(_st, _kind, _cursors, 0), do: :ok

  defp emit_each(st, kind, cursors, n) do
    # Spread the budget round-robin across the active cursors.
    Enum.each(0..(n - 1), fn i ->
      st.emit.(kind, Enum.at(cursors, rem(i, length(cursors))))
    end)
  end

  # Accrue a per-second budget in 250 ms slices, carrying the fraction forward.
  defp take(st, key, per_second) do
    acc = Map.fetch!(st.carry, key) + per_second / @ticks_per_second
    n = trunc(acc)

    st = %{
      st
      | carry: Map.put(st.carry, key, acc - n),
        stats: Map.update!(st.stats, key, &(&1 + n))
    }

    {n, st}
  end

  # ------------------------------------------------------------------ #
  # Defaults                                                            #
  # ------------------------------------------------------------------ #

  # Paint and scan are both find_node (INV-013), but they differ in which field
  # carries what:
  #
  #   paint - sender id = yid_i           <- this is the payload; Mainline stores
  #                                          the SENDER id against our address
  #           target    = id_paint_i         (prefix + random affix: a probe point
  #                                          that spreads paints across the region)
  #
  #   scan  - sender id = our node id (:nid)
  #           target    = id_paint_i         (walk the region, spec section 7)
  #
  # Sending id_paint as the *sender id* - an earlier reading of spec section 20 - paints an
  # affix with a random checksum that every scanner correctly discards. See
  # YggPF.Paint for the full argument.
  defp default_emit(kind, cursor) do
    epoch = Codec.current_epoch()
    # The reply carries no rotation marker, so the cursor and epoch ride along in
    # the KRPC context and come back to us in KRPCReplySubTask.handle_ctx/4.
    ctx = reply_ctx(cursor, epoch)

    Enum.each(0..(Const.n_parts() - 1), fn part ->
      prefix = prefix_for(part, cursor, epoch)
      target = Codec.id_paint(prefix)

      case kind do
        k when k in [:paint, :fixed_paint] ->
          case own_yid(part, prefix) do
            nil -> :skip
            yid -> Paint.paint(yid, target, ctx)
          end

        k when k in [:scan, :fixed_scan] ->
          Paint.scan(target, ctx)
      end
    end)
  end

  defp reply_ctx(:fixed, _epoch), do: :ygg_pf_fixed
  defp reply_ctx(cursor, epoch), do: {:ygg_pf, cursor, epoch}

  defp prefix_for(part, :fixed, _epoch), do: Codec.derive_fixed_prefix(part)
  defp prefix_for(part, cursor, epoch), do: Codec.derive_prefix(part, cursor, epoch)

  # Our own painted yid for `part`: the affix half is fixed by our yaddr, only the
  # prefix half rotates with the epoch.
  defp own_yid(part, prefix) do
    case Self.painter_address() do
      nil ->
        nil

      painter ->
        affix =
          painter
          |> Codec.split_parts()
          |> Enum.at(part)
          |> Codec.build_affix()

        Codec.build_yid(prefix, affix)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
