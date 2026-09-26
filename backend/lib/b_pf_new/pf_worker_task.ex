defmodule PFBinWorkerTask do
  @type target :: <<_::160>>
  @type frid :: target()
  @type fkey :: target()
  @type nodev4 :: <<_::48>>
  @type fn4 :: nodev4()
  @type tx_id :: <<_::32>>
  @type query_reply_opcode :: <<_::16>>
  @type kblock :: <<_::8192>>
  @type merkle_proof :: <<_::1024>>
  @query_opcodes %{
    ping: 0x0001,
    find_fnodes: 0x0002,
    get_kblock: 0x0003,
    semantic_q: 0x0004,
    semantic_any_q: 0x0104,
    mdf_q: 0x0005,
    mdf_any_q: 0x0105,
    treefile_q: 0x0006,
    put_q: 0x0007,
    get_token: 0x1002
  }
  @reply_opcodes %{
    pong: 0x4001,
    fnodes: 0x4002,
    kblock: 0x4003,
    semantic_r: 0x4004,
    semantic_any_r: 0x4104,
    mhashes: 0x4005,
    mhashes_any: 0x4105,
    thashes: 0x4006,
    put_r: 0x4007,
    error: 0x5001,
    token: 0x5002,
    saddrs: 0x5003
  }
  @qr_opcodes Map.merge(@query_opcodes, @reply_opcodes)
  @opcodes_list Map.values(@qr_opcodes)
  @qr_atoms for {atom, idx} <- @qr_opcodes, into: %{}, do: {idx, atom}
  def handle(tx_id, {frid, fnodev4}, qr_opcode, msg),
    do: do_handle(tx_id, frid, fnodev4, qr_opcode, msg)
  def get_opcode_range_for_plugins(), do: 0x7FFF..0xFFFF
  defp do_handle(tx_id, frid, fn4, op, msg) when op in @opcodes_list do
    name = Map.get(@qr_atoms, op)
    handle_opc(name, tx_id, fn4, frid, msg)
  end
  defp do_handle(_tx_id, fn4, _frid, name_idx, msg) do
    {:log_handle_error, fn4, name_idx, msg}
  end
  defp handle_opc(:ping, _t, _fn4, _frid, _msg), do: :answer_pong
  defp handle_opc(:find_fnodes, t, fn4, _frid, _msg), do: {t, fn4}
  defp handle_opc(:get_kblock, t, fn4, frid, part_num), do: {t, fn4, frid, part_num}
  defp handle_opc(:semantic_q, t, fn4, frid, sem_args), do: {t, fn4, frid, sem_args}
  defp handle_opc(:semantic_any_q, t, fn4, frid, sem_args), do: {t, fn4, frid, sem_args}
  defp handle_opc(:mdf_q, t, fn4, _frid, fmime_idx), do: {t, fn4, fmime_idx}
  defp handle_opc(:mdf_any_q, t, fn4, _frid, fmime_idx), do: {t, fn4, fmime_idx}
  defp handle_opc(:treefile_q, t, fn4, _frid, batch_num), do: {t, fn4, batch_num}
  defp handle_opc(:put_q, t, fn4, _frid, put_args), do: {t, fn4, put_args}
  defp handle_opc(:get_tokefn4, t, fn4, frid, _msg), do: {t, fn4, frid}
  defp handle_opc(:pong, _t, fn4, _frid, _msg) do
    GenS.PFLog.log_pong(fn4)
  end
  defp handle_opc(:fnodes, t, fn4, _frid, fnodes_r), do: {t, fn4, fnodes_r}
  defp handle_opc(:kblock, t, fn4, frid, wr_kblock), do: {t, fn4, frid, wr_kblock}
  defp handle_opc(:semantic_r, t, fn4, frid, file_id), do: {t, fn4, frid, file_id}
  defp handle_opc(:semantic_any_r, t, fn4, frid, file_id), do: {t, fn4, frid, file_id}
  defp handle_opc(:mhashes, t, fn4, frid, mhashes_r), do: {t, fn4, frid, mhashes_r}
  defp handle_opc(:mhashes_any, t, fn4, frid, mhashes_r), do: {t, fn4, frid, mhashes_r}
  defp handle_opc(:thashes, t, fn4, frid, thashes_r), do: {t, fn4, frid, thashes_r}
  defp handle_opc(:put_r, t, fn4, _frid, signal), do: {t, fn4, signal}
  defp handle_opc(:hmac_tokefn4, t, fn4, frid, token) do
    PFReplySubTask.lookup(:hmac_token, t, {fn4, frid, token})
  end
  defp handle_opc(:saddrs, t, fn4, _frid, saddrs_r) do
    PFReplySubTask.lookup(:saddrs, t, {fn4, saddrs_r})
  end
  defp handle_opc(:error, t, fn4, frid, _msg), do: {t, fn4, frid}
end