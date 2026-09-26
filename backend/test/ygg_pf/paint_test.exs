defmodule YggPF.PaintTest do
  @moduledoc """
  Regression test for the paint-identity bug.

  Field symptom: 22194 scan replies, 0 fragments, 0 candidates, indefinitely.

  Cause: the payload-bearing `yid` was sent as the find_node *target* while
  `id_paint` (prefix + **random** affix) was sent as the *sender id*. Mainline DHT
  stores the **sender id** against the sender's address, so what actually got
  painted was an affix with a random checksum. Every scanner - including ours -
  correctly discarded it, so nothing could ever be discovered.

  The invariant that must hold: **whatever we advertise as our sender id must
  survive `parse_affix/1`.**
  """

  use ExUnit.Case, async: true

  alias YggPF.{Codec, Const}

  @ip {0x202, 0x3EB, 0xBC02, 0x2E59, 0x6617, 0x5771, 0x1EE0, 0xFA2E}
  @port Const.ygg_pf_port()
  @cursor 0
  @epoch 29_400_000

  defp prefix(part), do: Codec.derive_prefix(part, @cursor, @epoch)

  # The 80-bit prefix is effectively unique, so a painted yid beats every ordinary
  # DHT node for any target under the same prefix. That is what makes painter and
  # scanner meet without agreeing on anything except the prefix.
  defp xor_distance(a, b), do: :crypto.exor(a, b) |> :binary.decode_unsigned()

  describe "what may be painted" do
    test "a yid carries a valid affix - it is a legal sender id" do
      for yid <- Codec.encode({@ip, @port}, @cursor, @epoch) do
        {_prefix, affix} = Codec.split_yid(yid)
        assert {:ok, _part} = Codec.parse_affix(affix)
      end
    end

    test "id_paint does NOT carry a valid affix - it must never be the sender id" do
      # Overwhelmingly likely to fail the checksum; assert over many draws so the
      # 1-in-256 accidental pass cannot make this test flap into a false green.
      failures =
        Enum.count(1..2_000, fn _ ->
          {_p, affix} = Codec.split_yid(Codec.id_paint(prefix(0)))
          Codec.parse_affix(affix) == :error
        end)

      assert failures > 1_900,
             "id_paint affixes should almost always fail the checksum, got #{failures}/2000"
    end

    test "painting id_paint yields nothing decodable - the observed failure mode" do
      painted = Enum.map(0..(Const.n_parts() - 1), &Codec.id_paint(prefix(&1)))

      # Prefixes match, so a scanner does look at them...
      for {id, i} <- Enum.with_index(painted) do
        assert Codec.prefix_match?(id, i, @cursor, @epoch)
      end

      # ...but the payload cannot be recovered.
      assert Codec.decode(painted, @cursor, @epoch) == :error
    end

    test "painting yids yields the exact address back" do
      yids = Codec.encode({@ip, @port}, @cursor, @epoch)
      assert Codec.decode(yids, @cursor, @epoch) == {:ok, {@ip, @port}}
    end
  end

  describe "rendezvous: a painted yid is the closest entry to any probe point" do
    test "the painted yid ranks first against a large routing table" do
      yids = Codec.encode({@ip, @port}, @cursor, @epoch)
      ordinary = for _ <- 1..2_000, do: :crypto.strong_rand_bytes(20)

      for {yid, part} <- Enum.with_index(yids) do
        table = [yid | ordinary]
        target = Codec.id_paint(prefix(part))

        closest = Enum.min_by(table, &xor_distance(&1, target))
        assert closest == yid, "painted yid#{part} was not the closest entry to the probe point"
      end
    end

    test "an unpainted region returns nothing usable" do
      ordinary = for _ <- 1..2_000, do: :crypto.strong_rand_bytes(20)
      target = Codec.id_paint(prefix(0))

      closest = Enum.min_by(ordinary, &xor_distance(&1, target))
      refute Codec.prefix_match?(closest, 0, @cursor, @epoch)
    end
  end

  describe "target vs identity are different values" do
    test "id_paint is a fresh probe point each time, the yid is stable" do
      yids1 = Codec.encode({@ip, @port}, @cursor, @epoch)
      yids2 = Codec.encode({@ip, @port}, @cursor, @epoch)

      assert yids1 == yids2, "the painted identity must be stable within an epoch"
      refute Codec.id_paint(prefix(0)) == Codec.id_paint(prefix(0))
    end

    test "both share the region prefix, which is what makes them meet" do
      [yid0 | _] = Codec.encode({@ip, @port}, @cursor, @epoch)
      target = Codec.id_paint(prefix(0))

      assert binary_part(yid0, 0, 10) == binary_part(target, 0, 10)
    end
  end
end
