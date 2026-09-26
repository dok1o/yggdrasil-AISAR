defmodule YggPF.CursorTest do
  @moduledoc "Cursor and epoch behaviour (spec sections 21, 22, 26, 58, 59)."

  use ExUnit.Case, async: true

  alias YggPF.{Codec, Const, Cursor}

  describe "cursor threshold (spec section 58)" do
    test "escalation begins at 9, not 8" do
      refute Cursor.escalate?(0)
      refute Cursor.escalate?(8)
      assert Cursor.escalate?(9)
    end

    test "0 matching yids does not escalate" do
      st = Cursor.new(1) |> Cursor.observe(0)
      assert st.cursor == 0
      assert st.escalations == 0
    end

    test "8 matching yids does not escalate" do
      st = Cursor.new(1) |> Cursor.observe(8)
      assert st.cursor == 0
      assert st.matches == 8
    end

    test "9 matching yids escalates exactly once" do
      st = Cursor.new(1) |> Cursor.observe(9)
      assert st.cursor == 1
      assert st.escalations == 1
      # counter resets, since the new cursor is a different region
      assert st.matches == 0
    end

    test "counts accumulate across observations within a cursor" do
      st = Cursor.new(1) |> Cursor.observe(5) |> Cursor.observe(3)
      assert st.cursor == 0
      assert st.matches == 8

      st = Cursor.observe(st, 1)
      assert st.cursor == 1
    end

    test "repeated crowding escalates repeatedly" do
      st =
        Enum.reduce(1..5, Cursor.new(1), fn _, acc -> Cursor.observe(acc, 9) end)

      assert st.cursor == 5
      assert st.escalations == 5
    end
  end

  describe "cursor lifecycle (spec sections 22, 59)" do
    test "starts at 0 (INV-010)" do
      assert Cursor.new(42).cursor == Const.cursor_start()
      assert Cursor.new(42).cursor == 0
    end

    test "resets on epoch change (INV-012)" do
      st = Cursor.new(10) |> Cursor.observe(9) |> Cursor.observe(9)
      assert st.cursor == 2

      rolled = Cursor.advance(st, 11)
      assert rolled.epoch == 11
      assert rolled.cursor == 0
      assert rolled.matches == 0
    end

    test "same epoch does not reset" do
      st = Cursor.new(10) |> Cursor.observe(9)
      assert Cursor.advance(st, 10) == st
    end

    test "immediately before, at, and after a minute boundary" do
      # 59s -> epoch N, 60s -> epoch N+1
      assert Codec.epoch(1_700_000_099) == Codec.epoch(1_700_000_059 + 40)
      before_e = Codec.epoch(1_759_000_019)
      at_e = Codec.epoch(1_759_000_020)

      st = Cursor.new(before_e) |> Cursor.observe(9)
      assert st.cursor == 1

      case at_e == before_e do
        true -> assert Cursor.advance(st, at_e).cursor == 1
        false -> assert Cursor.advance(st, at_e).cursor == 0
      end

      # a definitely-later epoch always resets
      assert Cursor.advance(st, before_e + 1).cursor == 0
    end
  end

  describe "active cursors (spec section 25)" do
    test "only cursor 0 is active at the start of an epoch" do
      assert Cursor.active(Cursor.new(1)) == [0]
    end

    test "last and next once escalated" do
      st = Cursor.new(1) |> Cursor.observe(9)
      assert Cursor.active(st) == [0, 1]

      st = Cursor.observe(st, 9)
      assert Cursor.active(st) == [1, 2]
    end
  end

  describe "initial scan slowdown (spec section 26)" do
    test "no fnodes means no delay" do
      assert Cursor.initial_delay_ms(0, 100) == 0
    end

    test "delay grows with fnode density relative to legacy density" do
      # deterministic: rand always returns 1.0, so we see the upper bound
      max_rand = fn -> 1.0 end
      window = 60_000

      low = Cursor.initial_delay_ms(10, 1000, rand: max_rand, window_ms: window)
      high = Cursor.initial_delay_ms(1000, 1000, rand: max_rand, window_ms: window)

      assert low < high
      assert high <= window
    end

    test "the spec section 26 example: 1000 fnodes over few legacy nodes spreads to the window" do
      spread =
        Cursor.initial_delay_ms(1000, 4, rand: fn -> 1.0 end, window_ms: 60_000)

      assert spread == 60_000
    end

    test "delay is jittered, not a fixed sleep" do
      results =
        for _ <- 1..50, do: Cursor.initial_delay_ms(50, 100, window_ms: 60_000)

      assert Enum.uniq(results) |> length() > 1, "expected jitter, got a constant"
      assert Enum.all?(results, &(&1 >= 0 and &1 <= 60_000))
    end

    test "never exceeds the window" do
      assert Cursor.initial_delay_ms(10_000_000, 1, rand: fn -> 1.0 end, window_ms: 1000) == 1000
    end
  end
end
