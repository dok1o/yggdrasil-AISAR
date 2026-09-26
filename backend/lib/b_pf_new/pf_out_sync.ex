defmodule PFOutSync do
  @moduledoc """
    Helpers for constructing and sending Protocol F (PF) packets.
    PF Header Layout (32 bytes):
      [Marker/Ver: 2B] [TxID: 4B] [Reserved: 4B] [SenderNodeID: 20B] [Opcode: 2B]
  """
  @pf_marker_and_ver <<0x66, 0x01>>
  @reserved <<0::size(32)>>
  @null_tx_id <<0::size(32)>>
  @doc """
  Constructs a standard PF protocol packet.
  ## Parameters
    - `tx_id`: 4-byte transaction ID from the incoming request
    - `sender_node_id`: 20-byte local Freenet node ID (SHA-1 hash)
    - `opcode`: 2-byte opcode (e.g., 0x4001 for PONG)
    - `payload`: Optional binary payload (defaults to empty)
  """
  def send_pong(fnodev4) do
    {nid, _legacy_tid} = KRPCUtilsSync.get_params_for_nodev4(fnodev4)
    packet = build_packet(@null_tx_id, nid, 0x4001, <<>>)
    KRPCUtilsSync.send_packet(nil, fnodev4, packet)
  end
  def build_packet(tx_id, sender_node_id, opcode, payload \\ <<>>) do
    <<@pf_marker_and_ver, tx_id::binary-4, @reserved, sender_node_id::binary-20, opcode::16,
      payload::binary>>
  end
end