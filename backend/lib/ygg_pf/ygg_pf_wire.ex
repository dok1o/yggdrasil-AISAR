defmodule YggPF.Wire do
  @moduledoc """
  `pingx` / `pong` for the Yggdrasil PF path (spec sections 31, 32, 51).

  ## pingx is not a binary packet

  Copied from `static_sync/wire_sync.ex:144-147`: `pingx` is an ordinary bencoded
  KRPC `ping` query carrying a magic key.

      {"y":"q", "q":"ping", "t":<tid>, "a":{"id":<20B nid>, "f":0}}

  This matters: a legacy Mainline node answers with a plain bencoded ping reply and
  nothing else, while a PF node *additionally* emits a binary PF packet. **The binary
  pong is the discriminator** - exactly the spec section 31 rule "no valid pong, discard
  candidate". A candidate that only produces the bencoded reply is a legacy node.

  ## pong is a binary PF packet

  PF v1 (`b_pf_new/pf_out_sync.ex`) used a 32-byte header carrying a 20-byte
  `SenderNodeID`:

      [0x66 0x01][TxID 4B][Reserved 4B][SenderNodeID 20B][Opcode 2B]

  A 32-byte Ygg public key does not fit, so `ygg_pf` defines **PF v2** (D-6), bumping
  the version byte and widening the identity field to a full `fid`:

      [0x66 0x02][TxID 4B][Reserved 4B][fid 32B][Opcode 2B]   = 44 bytes

  `a_folder/udp_shard.ex` already dispatches on `<<0x66, ver, ...>>`, so v1 and v2 can
  coexist while the legacy scheme is retired.
  """

  require Logger
  alias YggPF.Const

  @marker Const.pf_marker()
  @ver Const.pf_ver()
  @v1_ver Const.pf_v1_ver()
  @fid_bytes Const.fid_bytes()
  @header_bytes Const.pf_header_bytes()
  @opcode_pong Const.opcode_pong()
  @reserved <<0::32>>

  @type fid :: <<_::256>>
  @type tx_id :: <<_::32>>

  # ------------------------------------------------------------------ #
  # Build                                                               #
  # ------------------------------------------------------------------ #

  @doc """
  Build a PF v2 packet.

      iex> p = YggPF.Wire.build(<<0::32>>, :binary.copy(<<7>>, 32), 0x4001)
      iex> byte_size(p)
      44
  """
  @spec build(tx_id(), fid(), 0..0xFFFF, binary()) :: binary()
  def build(<<tx_id::binary-4>>, <<fid::binary-size(@fid_bytes)>>, opcode, payload \\ <<>>)
      when opcode in 0..0xFFFF and is_binary(payload) do
    <<@marker, @ver, tx_id::binary-4, @reserved::binary, fid::binary-size(@fid_bytes),
      opcode::16, payload::binary>>
  end

  @doc "Build a `pong` carrying our own `fid`."
  @spec pong(fid(), tx_id()) :: binary()
  def pong(fid, tx_id \\ <<0::32>>), do: build(tx_id, fid, @opcode_pong)

  # ------------------------------------------------------------------ #
  # Parse                                                               #
  # ------------------------------------------------------------------ #

  @doc """
  Parse an inbound PF packet.

  Returns `{:ok, %{version:, tx_id:, fid:, opcode:, payload:}}` for v2,
  `{:ok, %{version: 1, frid: ...}}` for a legacy v1 packet (recognised so it can be
  counted and ignored rather than silently dropped), or `:error`.

  A v1 packet can never yield a `fid`: its identity field is only 20 bytes. Callers
  must therefore not promote a v1 responder to trusted state.
  """
  @spec parse(binary()) :: {:ok, map()} | :error
  def parse(<<@marker, @ver, tx_id::binary-4, _reserved::binary-4,
              fid::binary-size(@fid_bytes), opcode::16, payload::binary>>) do
    {:ok, %{version: @ver, tx_id: tx_id, fid: fid, opcode: opcode, payload: payload}}
  end

  def parse(<<@marker, @v1_ver, tx_id::binary-4, _reserved::binary-4, frid::binary-20,
              opcode::16, payload::binary>>) do
    {:ok, %{version: @v1_ver, tx_id: tx_id, frid: frid, opcode: opcode, payload: payload}}
  end

  def parse(_malformed), do: :error

  @doc """
  Extract a `fid` from a packet that must be a well-formed v2 `pong`.

  This is the only path by which a candidate may acquire a routing identity
  (INV-014, INV-016). Everything else returns `:error`.
  """
  @spec pong_fid(binary()) :: {:ok, fid()} | :error
  def pong_fid(packet) do
    case parse(packet) do
      {:ok, %{version: @ver, opcode: @opcode_pong, fid: fid}} -> {:ok, fid}
      _not_a_v2_pong -> :error
    end
  end

  @doc "Minimum plausible PF packet size, for early rejection in the UDP path."
  def header_bytes, do: @header_bytes

  # ------------------------------------------------------------------ #
  # pingx                                                               #
  # ------------------------------------------------------------------ #

  @doc """
  Send a `pingx` to an underlay address.

  Delegates to the existing KRPC out path so transaction bookkeeping, socket
  sharding and logging stay in one place.
  """
  @spec pingx(binary()) :: any()
  def pingx(uaddr) when is_binary(uaddr), do: KRPCOutSync.ping_x(uaddr)
end
