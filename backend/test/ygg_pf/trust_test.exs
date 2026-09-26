defmodule YggPF.TrustTest do
  @moduledoc """
  Candidate trust semantics (spec sections 31-35, 57) and the PF v2 wire format (spec section 51).

  Spec section 57 requires exactly three outcomes to be tested:

      SDP candidate + no pong                        = not trusted
      valid yaddr pong                               = fid may become trusted
      uaddr response + no yaddr validation           = must not gain full trusted state
  """

  use ExUnit.Case, async: false

  alias YggPF.{Const, Store, Wire}

  @fid :binary.copy(<<0xAB>>, 32)
  @other_fid :binary.copy(<<0xCD>>, 32)
  @uaddr <<192, 0, 2, 1, 0x1A, 0xE1>>

  setup do
    Store.create_tables()

    on_exit(fn ->
      for t <- [Store.table_fnodes(), Store.table_fnodes_rev(), Store.table_pending()] do
        TryETS.delete_all(t)
      end
    end)

    :ok
  end

  describe "spec section 57 candidate trust" do
    test "SDP candidate with no pong is not trusted" do
      assert Store.trust(@fid) == :unknown
      refute Store.trusted?(@fid)
      assert Store.get(@fid) == nil
      assert Store.reachable_yaddr_count() == 0
    end

    test "uaddr response alone must not gain trusted state (INV-018)" do
      assert Store.note_uaddr_response(@fid, @uaddr) == :uaddr_only

      assert Store.trust(@fid) == :uaddr_only
      refute Store.trusted?(@fid), "uaddr-only responder must not be trusted"

      # nothing may have reached either trusted table
      assert Store.get(@fid) == nil
      refute Store.trusted_pair?(@fid, @uaddr)
      assert Store.reachable_yaddr_count() == 0
      assert Store.pending_count() == 1
    end

    test "valid yaddr response promotes to trusted" do
      Store.note_uaddr_response(@fid, @uaddr)
      yaddr = {{0x200, 0, 0, 0, 0, 0, 0, 1}, Const.ygg_pf_port()}

      assert Store.note_yaddr_response(@fid, yaddr, [@uaddr]) == :validated

      assert Store.trust(@fid) == :validated
      assert Store.trusted?(@fid)
      assert Store.trusted_pair?(@fid, @uaddr)
      assert Store.reachable_yaddr_count() == 1
      # promotion clears the pending entry
      assert Store.pending_count() == 0
    end

    test "both spec section 33 structures are written on promotion" do
      yaddr = {{0x200, 0, 0, 0, 0, 0, 0, 2}, Const.ygg_pf_port()}
      Store.note_yaddr_response(@fid, yaddr, [@uaddr])

      assert [{@fid, _meta}] = TryETS.lookup(Store.table_fnodes(), @fid)
      assert [{{@fid, @uaddr}, _}] = TryETS.lookup(Store.table_fnodes_rev(), {@fid, @uaddr})
    end

    test "many uaddr responses never accumulate into trust" do
      for i <- 1..25 do
        Store.note_uaddr_response(@fid, <<10, 0, 0, i, 0x1A, 0xE1>>)
      end

      refute Store.trusted?(@fid)
      assert Store.reachable_yaddr_count() == 0
    end
  end

  describe "yaddr/fid binding (spec section 34 fork protection)" do
    test "a yaddr derived from the fid matches" do
      key = :crypto.hash(:sha256, "peer") |> then(&(&1 <> &1))
      <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = Ygg.Address.addr_for_key(key)

      assert Store.yaddr_matches?(key, {a, b, c, d, e, f, g, h})
      assert Store.yaddr_matches?(key, {{a, b, c, d, e, f, g, h}, 26_214})
    end

    test "a yaddr belonging to a different key does not match" do
      k1 = :crypto.hash(:sha256, "one") |> then(&(&1 <> &1))
      k2 = :crypto.hash(:sha256, "two") |> then(&(&1 <> &1))
      <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = Ygg.Address.addr_for_key(k2)

      refute Store.yaddr_matches?(k1, {a, b, c, d, e, f, g, h})
    end
  end

  describe "PF v2 wire format (spec section 51, D-6)" do
    test "pong round trips and carries a 32-byte fid" do
      packet = Wire.pong(@fid)

      assert byte_size(packet) == Const.pf_header_bytes()
      assert <<0x66, 0x02, _::binary>> = packet
      assert Wire.pong_fid(packet) == {:ok, @fid}
    end

    test "fid sits where the parser expects it" do
      packet = Wire.pong(@fid)
      assert {:ok, %{version: 2, fid: @fid, opcode: 0x4001}} = Wire.parse(packet)
    end

    test "a legacy v1 packet parses but can never yield a fid (INV-016)" do
      v1 = <<0x66, 0x01, 0::32, 0::32, :binary.copy(<<9>>, 20)::binary, 0x4001::16>>

      assert {:ok, %{version: 1, frid: _}} = Wire.parse(v1)
      assert Wire.pong_fid(v1) == :error, "v1 must not be able to grant trust"
    end

    test "wrong opcode is not a pong" do
      ping = Wire.build(<<0::32>>, @fid, Const.opcode_ping())
      assert Wire.pong_fid(ping) == :error
    end

    test "malformed packets are rejected" do
      for bad <- [<<>>, <<0x66>>, <<0x66, 0x02>>, <<0x64, 0x02, 0::320>>,
                  :crypto.strong_rand_bytes(43)] do
        assert Wire.pong_fid(bad) == :error
      end
    end

    test "truncated v2 packet is rejected" do
      full = Wire.pong(@fid)
      short = binary_part(full, 0, byte_size(full) - 1)
      assert Wire.parse(short) == :error
    end

    test "distinct fids produce distinct packets" do
      refute Wire.pong(@fid) == Wire.pong(@other_fid)
    end
  end

  describe "duplicate and conflicting identities (spec section 60)" do
    test "duplicate fid values collapse to one trusted entry" do
      yaddr = {{0x200, 0, 0, 0, 0, 0, 0, 3}, Const.ygg_pf_port()}
      Store.note_yaddr_response(@fid, yaddr, [@uaddr])
      Store.note_yaddr_response(@fid, yaddr, [@uaddr])

      assert Store.reachable_yaddr_count() == 1
    end

    test "a fid may accumulate several uaddrs" do
      yaddr = {{0x200, 0, 0, 0, 0, 0, 0, 4}, Const.ygg_pf_port()}
      u2 = <<198, 51, 100, 7, 0x1A, 0xE1>>

      Store.note_yaddr_response(@fid, yaddr, [@uaddr])
      Store.note_yaddr_response(@fid, yaddr, [u2])

      assert Enum.sort(Store.uaddrs(@fid)) == Enum.sort([@uaddr, u2])
      assert Store.trusted_pair?(@fid, @uaddr)
      assert Store.trusted_pair?(@fid, u2)
    end
  end
end
