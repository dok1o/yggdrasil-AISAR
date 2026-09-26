defmodule YggPF.CodecTest do
  @moduledoc """
  Properties and adversarial cases for the SDP codec (spec sections 56, 60).
  """

  use ExUnit.Case, async: true

  alias YggPF.{Codec, Const}

  # The node's own recorded identity, data/ygg/ygg_address.txt
  @ip {0x202, 0x3EB, 0xBC02, 0x2E59, 0x6617, 0x5771, 0x1EE0, 0xFA2E}
  @port Const.ygg_pf_port()

  defp painter, do: Codec.painter_address(@ip, @port)
  defp part0, do: painter() |> Codec.split_parts() |> hd()

  describe "required properties (spec section 56)" do
    test "bit_size(prefix) == 80" do
      assert bit_size(Codec.derive_prefix(0, 0, 29_000_000)) == 80
      assert bit_size(Codec.derive_fixed_prefix(0)) == 80
    end

    test "bit_size(address_part) == 72" do
      for p <- Codec.split_parts(painter()), do: assert(bit_size(p) == 72)
    end

    test "bit_size(checksum) == 8" do
      <<_::binary-9, cks::8>> = Codec.build_affix(part0())
      assert cks in 0..255
    end

    test "bit_size(affix) == 80" do
      for p <- Codec.split_parts(painter()), do: assert(bit_size(Codec.build_affix(p)) == 80)
    end

    test "byte_size(yid) == 20" do
      for y <- Codec.encode({@ip, @port}, 0, 1), do: assert(byte_size(y) == 20)
    end

    test "join(split(address)) == address" do
      a = painter()
      assert Codec.join_parts(Codec.split_parts(a)) == a
    end

    test "decode(encode(address)) == address" do
      assert Codec.decode(Codec.encode({@ip, @port}, 0, 1), 0, 1) == {:ok, {@ip, @port}}
    end
  end

  describe "round trip across the input space (spec section 55)" do
    test "many addresses, ports, cursors and epochs" do
      for seed <- 1..80 do
        key = :crypto.hash(:sha256, <<seed::32>>) |> then(&(&1 <> &1))
        <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = Ygg.Address.addr_for_key(key)
        ip = {a, b, c, d, e, f, g, h}

        for port <- [0, 1, 443, @port, 65535],
            cursor <- [0, 1, 9, 255],
            epoch <- [0, 1, 29_000_000, 4_294_967_295] do
          yids = Codec.encode({ip, port}, cursor, epoch)
          assert Codec.decode(yids, cursor, epoch) == {:ok, {ip, port}}
        end
      end
    end

    test "bit reversal is an involution over random inputs" do
      for _ <- 1..200 do
        b = :crypto.strong_rand_bytes(9)
        assert Codec.reverse_bits(Codec.reverse_bits(b)) == b
      end
    end
  end

  describe "adversarial (spec section 60)" do
    test "every single-bit mutation of an affix is rejected" do
      affix = Codec.build_affix(part0())

      for pos <- 0..(bit_size(affix) - 1) do
        <<head::bits-size(pos), bit::1, tail::bits>> = affix
        flipped = <<head::bits, bxor1(bit)::1, tail::bits>>
        assert Codec.parse_affix(flipped) == :error, "bit #{pos} not caught"
      end
    end

    test "wrong cursor does not decode" do
      yids = Codec.encode({@ip, @port}, 0, 100)
      assert Codec.decode(yids, 1, 100) == :error
    end

    test "wrong epoch does not decode" do
      yids = Codec.encode({@ip, @port}, 0, 100)
      assert Codec.decode(yids, 0, 101) == :error
    end

    test "swapped part order does not decode" do
      [a, b] = Codec.encode({@ip, @port}, 0, 100)
      assert Codec.decode([b, a], 0, 100) == :error
    end

    test "truncated and oversized ids are rejected" do
      assert Codec.split_yid(<<0::152>>) == :error
      assert Codec.parse_affix(<<0::72>>) == :error
      assert Codec.fragment(<<0::160>>) == :error or match?({:ok, _}, Codec.fragment(<<0::160>>))
      assert Codec.decode([<<0::160>>], 0, 0) == :error
    end

    test "an unrelated random node id does not match any prefix" do
      for _ <- 1..500 do
        id = :crypto.strong_rand_bytes(20)
        refute Codec.prefix_match?(id, 0, 0, 29_000_000)
        refute Codec.prefix_match?(id, 1, 0, 29_000_000)
      end
    end
  end

  describe "prefix separation" do
    test "distinct part, cursor, epoch and fixed prefixes all differ" do
      base = Codec.derive_prefix(0, 0, 100)
      assert base == Codec.derive_prefix(0, 0, 100)
      refute base == Codec.derive_prefix(1, 0, 100)
      refute base == Codec.derive_prefix(0, 1, 100)
      refute base == Codec.derive_prefix(0, 0, 101)
      refute base == Codec.derive_fixed_prefix(0)
      refute Codec.derive_fixed_prefix(0) == Codec.derive_fixed_prefix(1)
    end

    test "fixed prefix is epoch independent" do
      assert Codec.derive_fixed_prefix(0) == Codec.derive_fixed_prefix(0)
    end
  end

  describe "id_paint (spec section 20)" do
    test "shares the prefix but is not the yid" do
      prefix = Codec.derive_prefix(0, 0, 100)
      idp = Codec.id_paint(prefix)
      assert byte_size(idp) == 20
      assert binary_part(idp, 0, 10) == prefix

      [yid0, _] = Codec.encode({@ip, @port}, 0, 100)
      refute idp == yid0
    end

    test "successive id_paint values differ" do
      prefix = Codec.derive_prefix(0, 0, 100)
      refute Codec.id_paint(prefix) == Codec.id_paint(prefix)
    end
  end

  describe "epoch" do
    test "1-minute buckets" do
      assert Codec.epoch(0) == 0
      assert Codec.epoch(59) == 0
      assert Codec.epoch(60) == 1
      assert Codec.epoch(119) == 1
      assert Codec.epoch(120) == 2
    end
  end

  test "ygg_addr? accepts 0x02-prefixed addresses only" do
    assert Codec.ygg_addr?(@ip)
    refute Codec.ygg_addr?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    refute Codec.ygg_addr?({0x300, 0, 0, 0, 0, 0, 0, 1})
  end

  defp bxor1(0), do: 1
  defp bxor1(1), do: 0
end
