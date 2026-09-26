defmodule YggPF.SchedulerTest do
  @moduledoc """
  Scheduling rates and failure logging (spec sections 23-27, 41-45, 61).

  Spec section 61 asks for observable scheduling and accounting behaviour rather than
  brittle wall-clock assertions, so the scheduler is driven by explicit
  `tick_now/1` calls with an injected emitter and the counters are asserted.
  """

  use ExUnit.Case, async: false

  alias YggPF.{Const, Cursor, Log}

  @ticks_per_second 4

  defp start_sched(opts \\ []) do
    test = self()

    emit = fn kind, cursor -> send(test, {:emitted, kind, cursor}) end

    defaults = [
      autotick: false,
      emit: emit,
      density: fn -> {0, 1} end,
      epoch: 1_000_000,
      name: :"sched_#{System.unique_integer([:positive])}"
    ]

    {:ok, pid} = GenS.YggPFScheduler.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp run_seconds(pid, n) do
    for _ <- 1..(n * @ticks_per_second), do: GenS.YggPFScheduler.tick_now(pid)
  end

  defp drain do
    receive do
      {:emitted, k, c} -> [{k, c} | drain()]
    after
      0 -> []
    end
  end

  describe "budgets (spec sections 23, 25, 27, 61)" do
    test "one second at cursor 0 emits the per-cursor budget plus the fixed budget" do
      pid = start_sched()
      run_seconds(pid, 1)
      s = GenS.YggPFScheduler.stats(pid)

      # only cursor 0 is active initially, so 4 scan + 4 paint
      assert s.scan == Const.scan_per_second()
      assert s.fixed_paint == Const.fixed_paint_per_second()
      assert s.fixed_scan == Const.fixed_scan_per_second()
    end

    test "rates hold over several seconds" do
      pid = start_sched()
      run_seconds(pid, 5)
      s = GenS.YggPFScheduler.stats(pid)

      assert s.scan == 5 * Const.scan_per_second()
      assert s.fixed_paint == 5 * Const.fixed_paint_per_second()
      assert s.fixed_scan == 5 * Const.fixed_scan_per_second()
    end

    test "two active cursors double the epoch budget to 16 q/s (spec section 25)" do
      pid = start_sched()
      # escalate so both last and next cursors are active
      GenS.YggPFScheduler.observe(pid, 9)
      # let the cast land
      _ = GenS.YggPFScheduler.cursor(pid)

      run_seconds(pid, 1)
      s = GenS.YggPFScheduler.stats(pid)

      assert s.scan == Const.scan_per_second() * Const.active_cursors()
      assert s.paint == Const.paint_per_second() * Const.active_cursors()
      assert s.scan + s.paint == Const.epoch_queries_per_second()
      assert Const.epoch_queries_per_second() == 16
    end

    test "fixed prefix adds 2 q/s on top (spec section 27)" do
      assert Const.fixed_queries_per_second() == 2
    end
  end

  describe "paint lags scan (spec section 24)" do
    test "no paint is emitted before scanning has run" do
      pid = start_sched()
      GenS.YggPFScheduler.tick_now(pid)
      s = GenS.YggPFScheduler.stats(pid)

      assert s.scan > 0 or s.skipped_scan > 0
      assert s.paint == 0, "paint must not race ahead of cursor establishment"
    end

    test "paint begins once scanning has established the cursor" do
      pid = start_sched()
      run_seconds(pid, 2)
      s = GenS.YggPFScheduler.stats(pid)

      assert s.paint > 0
    end
  end

  describe "initial scan slowdown (spec section 26)" do
    test "a dense fnode population defers its first scans" do
      # 1000 fnodes against 4 legacy nodes: the spec section 26 worked example
      pid = start_sched(density: fn -> {1000, 4} end)
      GenS.YggPFScheduler.tick_now(pid)
      s = GenS.YggPFScheduler.stats(pid)

      assert s.skipped_scan > 0, "expected the scan gate to defer the first scans"
      assert s.scan == 0
    end

    test "a sparse population scans immediately" do
      pid = start_sched(density: fn -> {0, 1000} end)
      GenS.YggPFScheduler.tick_now(pid)
      s = GenS.YggPFScheduler.stats(pid)

      assert s.scan > 0
      assert s.skipped_scan == 0
    end
  end

  describe "cursor plumbing" do
    test "observe escalates and both cursors then receive traffic" do
      pid = start_sched()
      run_seconds(pid, 1)
      _ = drain()

      GenS.YggPFScheduler.observe(pid, 9)
      assert GenS.YggPFScheduler.cursor(pid).cursor == 1

      run_seconds(pid, 1)
      emitted = drain()
      cursors = emitted |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 == :fixed)) |> Enum.uniq()

      assert 0 in cursors
      assert 1 in cursors
    end

    test "8 observed yids do not escalate, 9 do" do
      pid = start_sched()
      GenS.YggPFScheduler.observe(pid, 8)
      assert GenS.YggPFScheduler.cursor(pid).cursor == 0

      GenS.YggPFScheduler.observe(pid, 1)
      assert GenS.YggPFScheduler.cursor(pid).cursor == 1
    end
  end

  describe "failure logging taxonomy (spec sections 41-45)" do
    test "wall clock desync: epoch path fails while fixed path works (spec section 42)" do
      assert [{:wall_clock_desync, _}] =
               Log.classify(%{epoch_candidates: 0, fixed_candidates: 3})
    end

    test "no desync reported when both paths work" do
      assert Log.classify(%{epoch_candidates: 2, fixed_candidates: 3}) == []
    end

    test "no desync reported when both paths fail" do
      refute Enum.any?(
               Log.classify(%{epoch_candidates: 0, fixed_candidates: 0}),
               &match?({:wall_clock_desync, _}, &1)
             )
    end

    test "fewer than 4 reachable yaddrs is reported (spec section 43)" do
      assert [{:too_few_yaddrs, %{reachable_yaddrs: 3}}] =
               Log.classify(%{reachable_yaddrs: 3})

      assert Log.classify(%{reachable_yaddrs: 4}) == []
      assert Const.min_reachable_yaddrs() == 4
    end

    test "no new candidates with a prior-run cache is its own condition (spec section 44)" do
      assert [{:no_new_candidates, %{cached_fnodes: 12}}] =
               Log.classify(%{new_candidates: 0, cached_fnodes: 12})

      # not reported when there is no cache to fall back on
      refute Enum.any?(
               Log.classify(%{new_candidates: 0, cached_fnodes: 0}),
               &match?({:no_new_candidates, _}, &1)
             )
    end

    test "20s with no candidates and no DHT boot is a hard failure (spec section 45)" do
      assert [{:no_candidates_no_dht, _}] =
               Log.classify(%{elapsed_ms: 20_000, new_candidates: 0, dht_booted?: false})

      # not before the deadline
      assert Log.classify(%{elapsed_ms: 19_999, new_candidates: 0, dht_booted?: false}) == []
      # not once the DHT is up
      assert Log.classify(%{elapsed_ms: 30_000, new_candidates: 0, dht_booted?: true}) == []
    end

    test "conditions are distinct and can co-occur (spec section 41)" do
      conditions =
        Log.classify(%{
          epoch_candidates: 0,
          fixed_candidates: 5,
          reachable_yaddrs: 1,
          new_candidates: 0,
          cached_fnodes: 7
        })

      tags = Enum.map(conditions, &elem(&1, 0))

      assert :wall_clock_desync in tags
      assert :too_few_yaddrs in tags
      assert :no_new_candidates in tags
      assert length(Enum.uniq(tags)) == length(tags), "conditions must not be collapsed"
    end

    test "a healthy state reports nothing" do
      assert Log.classify(%{
               epoch_candidates: 9,
               fixed_candidates: 2,
               reachable_yaddrs: 25,
               new_candidates: 4,
               cached_fnodes: 25,
               dht_booted?: true,
               elapsed_ms: 60_000
             }) == []
    end
  end

  describe "active cursor helper" do
    test "matches the scheduler's view" do
      assert Cursor.active(Cursor.new(1)) == [0]
      assert Cursor.active(%{Cursor.new(1) | cursor: 3}) == [2, 3]
    end
  end
end
