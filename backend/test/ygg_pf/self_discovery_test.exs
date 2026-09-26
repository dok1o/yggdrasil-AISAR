defmodule YggPF.SelfDiscoveryTest do
  @moduledoc """
  Attribution of a self-sighting: when the scanner reconstructs its **own** yaddr,
  the log must name the origin and say whether it was the same node or another.

  The distinction carries real meaning:

    * returned by **another** node - our paint propagated through the DHT and a
      third party is storing it, so we are genuinely discoverable;
    * returned by **ourselves** - a local echo out of our own routing table,
      which proves nothing;
    * **unattributed** - kept separate from "self" on purpose, so an unknown
      origin can never be mistaken for a confirmed echo (or vice versa).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YggPF.{Codec, Const, Reconstruct, Self}

  @port Const.ygg_pf_port()
  @cursor 0
  @epoch 29_000_000

  @own_uaddr <<203, 0, 113, 9, 0x1A, 0xE1>>
  @other_uaddr <<198, 51, 100, 4, 0x1A, 0xE1>>
  @third_uaddr <<192, 0, 2, 77, 0x1A, 0xE1>>

  defp ygg_ip(seed) do
    key = :crypto.hash(:sha256, <<seed::32>>)
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = Ygg.Address.addr_for_key(key)
    {a, b, c, d, e, f, g, h}
  end

  # Build the two compact entries a scanner would see for a painted address.
  defp painted(ip, entry_uaddr) do
    [y0, y1] = Codec.encode({ip, @port}, @cursor, @epoch)
    [{y0, entry_uaddr}, {y1, entry_uaddr}]
  end

  setup do
    KeyStorageSync.set_own_uaddr(@own_uaddr)
    Self.reset_cache()
    on_exit(fn -> Self.reset_cache() end)
    :ok
  end

  describe "responder provenance is preserved" do
    test "fragments carry the responder that supplied them" do
      ip = ygg_ip(1)
      frags = Reconstruct.fragments(painted(ip, @other_uaddr), @cursor, @epoch, @third_uaddr)

      for {_part_index, list} <- frags, frag <- list do
        assert frag.responder == @third_uaddr
        assert frag.uaddr == @other_uaddr
      end
    end

    test "responder defaults to nil when the origin is not supplied" do
      ip = ygg_ip(2)
      frags = Reconstruct.fragments(painted(ip, @other_uaddr), @cursor, @epoch)

      for {_i, list} <- frags, frag <- list, do: assert(frag.responder == nil)
    end

    test "candidates surface both the claimed uaddrs and the responders" do
      ip = ygg_ip(3)

      frags =
        Reconstruct.fragments(painted(ip, @other_uaddr), @cursor, @epoch, @third_uaddr)

      assert [%{yaddr: {^ip, @port}, uaddrs: uaddrs, responders: responders}] =
               Reconstruct.candidates(frags)

      assert uaddrs == [@other_uaddr]
      assert responders == [@third_uaddr]
    end

    test "fragments from different responders merge into one candidate" do
      ip = ygg_ip(4)
      [e0, e1] = painted(ip, @other_uaddr)

      frags =
        Reconstruct.merge_fragments(
          Reconstruct.fragments([e0], @cursor, @epoch, @third_uaddr),
          Reconstruct.fragments([e1], @cursor, @epoch, @other_uaddr)
        )

      assert [%{yaddr: {^ip, @port}, responders: responders}] = Reconstruct.candidates(frags)
      assert Enum.sort(responders) == Enum.sort([@third_uaddr, @other_uaddr])
    end
  end

  describe "Self.origin/1" do
    test "a remote responder is :other" do
      assert Self.origin([@other_uaddr]) == :other
    end

    test "our own uaddr is :self" do
      assert Self.origin([@own_uaddr]) == :self
    end

    test "all-self responders are :self" do
      assert Self.origin([@own_uaddr, @own_uaddr]) == :self
    end

    test "any remote responder makes the whole finding :other" do
      assert Self.origin([@own_uaddr, @other_uaddr]) == :other
    end

    test "no recorded responder is :unknown, never :self" do
      assert Self.origin([]) == :unknown
      assert Self.origin([nil, nil]) == :unknown
    end

    test "nils are ignored when a real responder is present" do
      assert Self.origin([nil, @other_uaddr]) == :other
      assert Self.origin([nil, @own_uaddr]) == :self
    end

    test "origin is :unknown while our own uaddr is undetermined" do
      KeyStorageSync.set_own_uaddr(<<0, 0, 0, 0, 0, 0>>)

      assert Self.uaddr() == nil
      # must not claim :self, and must not claim :other either
      assert Self.origin([@other_uaddr]) == :unknown
    end
  end

  describe "self-sighting log names the origin" do
    setup do
      ip = ygg_ip(7)
      {:ok, ip: ip}
    end

    test "third-party sighting is reported as OTHER and as propagation", %{ip: ip} do
      log =
        capture_log(fn ->
          YggPF.Log.log_self_discovery(%{
            yaddr: {ip, @port},
            uaddrs: [@own_uaddr],
            responders: [@other_uaddr]
          })
        end)

      assert log =~ "SELF-DISCOVERY"
      assert log =~ "OTHER node"
      assert log =~ "propagated"
      refute log =~ "local echo"
    end

    test "self-echo is reported as SAME and explicitly not propagation", %{ip: ip} do
      log =
        capture_log(fn ->
          YggPF.Log.log_self_discovery(%{
            yaddr: {ip, @port},
            uaddrs: [@own_uaddr],
            responders: [@own_uaddr]
          })
        end)

      assert log =~ "SELF-DISCOVERY"
      assert log =~ "SAME node"
      assert log =~ "not evidence of propagation"
      refute log =~ "OTHER node"
    end

    test "unattributed sighting is neither SAME nor OTHER", %{ip: ip} do
      log =
        capture_log(fn ->
          YggPF.Log.log_self_discovery(%{
            yaddr: {ip, @port},
            uaddrs: [@own_uaddr],
            responders: []
          })
        end)

      assert log =~ "UNATTRIBUTED"
      refute log =~ "OTHER node"
      refute log =~ "SAME node"
    end

    test "the log states the yaddr that was found", %{ip: ip} do
      log =
        capture_log(fn ->
          YggPF.Log.log_self_discovery(%{
            yaddr: {ip, @port},
            uaddrs: [@own_uaddr],
            responders: [@other_uaddr]
          })
        end)

      assert log =~ to_string(:inet.ntoa(ip))
    end

    test "returns the origin so the caller can count it", %{ip: ip} do
      capture_log(fn ->
        assert YggPF.Log.log_self_discovery(%{
                 yaddr: {ip, @port},
                 uaddrs: [@own_uaddr],
                 responders: [@other_uaddr]
               }) == :other

        assert YggPF.Log.log_self_discovery(%{
                 yaddr: {ip, @port},
                 uaddrs: [@own_uaddr],
                 responders: [@own_uaddr]
               }) == :self
      end)
    end

    test "a foreign uaddr painted against our yaddr is flagged", %{ip: ip} do
      log =
        capture_log(fn ->
          YggPF.Log.log_self_discovery(%{
            yaddr: {ip, @port},
            uaddrs: [@third_uaddr],
            responders: [@other_uaddr]
          })
        end)

      assert log =~ "none of which is ours"
      assert log =~ "NAT remapping or another node painting our address"
    end

    test "no impersonation warning when our own uaddr is present", %{ip: ip} do
      log =
        capture_log(fn ->
          YggPF.Log.log_self_discovery(%{
            yaddr: {ip, @port},
            uaddrs: [@own_uaddr, @third_uaddr],
            responders: [@other_uaddr]
          })
        end)

      refute log =~ "none of which is ours"
    end

    test "no impersonation warning while our own uaddr is unknown", %{ip: ip} do
      KeyStorageSync.set_own_uaddr(<<0, 0, 0, 0, 0, 0>>)

      log =
        capture_log(fn ->
          YggPF.Log.log_self_discovery(%{
            yaddr: {ip, @port},
            uaddrs: [@third_uaddr],
            responders: [@other_uaddr]
          })
        end)

      refute log =~ "none of which is ours"
    end
  end

  describe "own_yaddr? / own_uaddr?" do
    test "own_uaddr? is false for a remote address" do
      assert Self.own_uaddr?(@own_uaddr)
      refute Self.own_uaddr?(@other_uaddr)
    end

    test "own_uaddr? is false, not a crash, on nil and junk" do
      refute Self.own_uaddr?(nil)
      refute Self.own_uaddr?(<<1, 2, 3>>)
    end

    test "an unknown self never matches a remote node" do
      KeyStorageSync.set_own_uaddr(<<0, 0, 0, 0, 0, 0>>)
      refute Self.own_uaddr?(@other_uaddr)
      refute Self.own_uaddr?(<<0, 0, 0, 0, 0, 0>>)
    end

    test "own_yaddr? tolerates a missing Ygg node" do
      # With no embedded node running, self is unknown and nothing is ours.
      refute Self.own_yaddr?(nil)
      refute Self.own_yaddr?({ygg_ip(11), @port})
    end
  end
end
