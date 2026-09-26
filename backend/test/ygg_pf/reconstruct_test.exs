defmodule YggPF.ReconstructTest do
  @moduledoc "Scan filtering and combinatorial reconstruction (spec sections 8, 9, 60)."

  use ExUnit.Case, async: true

  alias YggPF.{Codec, Const, Reconstruct}

  @cursor 0
  @epoch 29_000_000
  @port Const.ygg_pf_port()

  defp ygg_ip(seed) do
    key = :crypto.hash(:sha256, <<seed::32>>) |> then(&(&1 <> &1))
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = Ygg.Address.addr_for_key(key)
    {a, b, c, d, e, f, g, h}
  end

  defp uaddr(n), do: <<10, 0, 0, n, 0x1A, 0xE1>>

  # Paint an address into the two compact node entries a scanner would see.
  defp painted(ip, n) do
    [y0, y1] = Codec.encode({ip, @port}, @cursor, @epoch)
    [{y0, uaddr(n)}, {y1, uaddr(n)}]
  end

  defp noise(count) do
    for _ <- 1..count, do: {:crypto.strong_rand_bytes(20), uaddr(99)}
  end

  describe "filtering (spec section 8)" do
    test "painted ids are recovered as fragments" do
      ip = ygg_ip(1)
      frags = Reconstruct.fragments(painted(ip, 1), @cursor, @epoch)

      assert map_size(frags) == 2
      assert length(Map.get(frags, 0)) == 1
      assert length(Map.get(frags, 1)) == 1
    end

    test "unrelated DHT noise is filtered out" do
      assert Reconstruct.fragments(noise(500), @cursor, @epoch) == %{}
    end

    test "noise around a painted pair does not disturb it" do
      ip = ygg_ip(2)
      nodes = Enum.shuffle(painted(ip, 2) ++ noise(300))
      frags = Reconstruct.fragments(nodes, @cursor, @epoch)

      assert [%{yaddr: ^ip}] = Reconstruct.candidates(frags)
    end

    test "fragments under the wrong cursor or epoch are not collected" do
      ip = ygg_ip(3)
      assert Reconstruct.fragments(painted(ip, 3), @cursor + 1, @epoch) == %{}
      assert Reconstruct.fragments(painted(ip, 3), @cursor, @epoch + 1) == %{}
    end

    test "checksum corruption drops the fragment" do
      ip = ygg_ip(4)
      [{y0, u}, {y1, _}] = painted(ip, 4)

      # flip a bit inside the affix of the first yid
      <<head::binary-15, byte, tail::binary>> = y0
      corrupt = <<head::binary, Bitwise.bxor(byte, 1), tail::binary>>

      frags = Reconstruct.fragments([{corrupt, u}, {y1, u}], @cursor, @epoch)
      assert Map.get(frags, 0) == nil
      assert Reconstruct.candidates(frags) == []
    end
  end

  describe "reconstruction (spec section 9)" do
    test "a complete pair reconstructs the exact address" do
      ip = ygg_ip(5)
      frags = Reconstruct.fragments(painted(ip, 5), @cursor, @epoch)

      assert [%{yaddr: ^ip, uaddrs: uaddrs}] = Reconstruct.candidates(frags)
      assert uaddr(5) in uaddrs
    end

    test "a lone fragment yields nothing" do
      ip = ygg_ip(6)
      [first, _second] = painted(ip, 6)
      frags = Reconstruct.fragments([first], @cursor, @epoch)

      assert Reconstruct.candidates(frags) == []
    end

    test "several painted nodes are all recovered" do
      ips = Enum.map(1..6, &ygg_ip(&1 + 100))

      nodes =
        ips
        |> Enum.with_index()
        |> Enum.flat_map(fn {ip, i} -> painted(ip, i + 1) end)
        |> Enum.shuffle()

      frags = Reconstruct.fragments(nodes, @cursor, @epoch)
      found = frags |> Reconstruct.candidates() |> Enum.map(& &1.yaddr)

      assert Enum.sort(found) == Enum.sort(ips)
    end

    test "match_count feeds cursor escalation (spec section 21)" do
      nodes = Enum.flat_map(1..5, fn i -> painted(ygg_ip(i + 200), i) end)
      frags = Reconstruct.fragments(nodes, @cursor, @epoch)

      # 5 addresses x 2 parts
      assert Reconstruct.match_count(frags) == 10
      assert YggPF.Cursor.escalate?(Reconstruct.match_count(frags))
    end
  end

  describe "adversarial (spec section 60)" do
    test "conflicting fragments only yield Ygg-range addresses" do
      # Cross-pairing fragments from different nodes almost never lands in 200::/7.
      ips = Enum.map(1..8, &ygg_ip(&1 + 300))
      nodes = Enum.flat_map(Enum.with_index(ips), fn {ip, i} -> painted(ip, i + 1) end)
      frags = Reconstruct.fragments(nodes, @cursor, @epoch)

      found = frags |> Reconstruct.candidates() |> Enum.map(& &1.yaddr)

      # every real address is found
      for ip <- ips, do: assert(ip in found)
      # and every reported address is a valid Ygg address
      for ip <- found, do: assert(Codec.ygg_addr?(ip))
    end

    test "duplicate fragments do not duplicate candidates" do
      ip = ygg_ip(9)
      nodes = painted(ip, 9) ++ painted(ip, 9) ++ painted(ip, 9)
      frags = Reconstruct.fragments(nodes, @cursor, @epoch)

      assert [%{yaddr: ^ip}] = Reconstruct.candidates(frags)
    end

    test "excessive yids are capped rather than exploding" do
      # 60 fragments per part would be 3600 pairs; cap at 100.
      many =
        Enum.flat_map(1..60, fn i -> painted(ygg_ip(i + 400), rem(i, 250) + 1) end)

      frags = Reconstruct.fragments(many, @cursor, @epoch)
      assert Reconstruct.match_count(frags) == 120

      capped = Reconstruct.candidates(frags, max_pairs: 100)
      assert length(capped) <= 100
    end

    test "empty input is safe" do
      assert Reconstruct.fragments([], @cursor, @epoch) == %{}
      assert Reconstruct.candidates(%{}) == []
      assert Reconstruct.match_count(%{}) == 0
    end
  end

  describe "fixed prefix path (spec section 27)" do
    test "fixed-prefix painting is recovered independently of epoch" do
      ip = ygg_ip(10)
      painter = Codec.painter_address(ip, @port)

      nodes =
        painter
        |> Codec.split_parts()
        |> Enum.with_index()
        |> Enum.map(fn {part, i} ->
          {Codec.build_yid(Codec.derive_fixed_prefix(i), Codec.build_affix(part)), uaddr(10)}
        end)

      frags = Reconstruct.fixed_fragments(nodes)
      assert [%{yaddr: ^ip}] = Reconstruct.candidates(frags)

      # and it is not visible to the epoch-dependent filter
      assert Reconstruct.fragments(nodes, @cursor, @epoch) == %{}
    end
  end
end
