defmodule PFReplySubTask do
  @type target :: <<_::160>>
  @type frid :: target()
  @type fkey :: target()
  @type nodev4 :: <<_::48>>
  @type fn4 :: nodev4()
  @type tx_id :: <<_::32>>
  @type query_reply_opcode :: <<_::16>>
  @type kblock :: <<_::8192>>
  @type merkle_proof :: <<_::1024>>
  def lookup(name, tx_id, reply_tuple) do
    {tx_id}
    :todo_ets_lookup
    :todo_process_on_match
    case name do
      :saddrs -> process(:saddrs, reply_tuple)
      :hmac_token -> process(:hmac_token, reply_tuple)
    end
  end
  def process(:saddrs, {fn4, <<_transport::16, fkey::160, saddrs_bin::binary>>}) do
    :here_processing_saddrs_for_asked_fkey
    :todo_ets_lookup_by_tx_id
    fcache_add(fkey, fn4, saddrs_bin)
  end
  def process(:hmac_token, {<<ip_bin::binary-4, _port::16>>, frid, token}) do
    :here_check_token
    _valid? = TokenSync.verify?(token, ip_bin, frid)
  end
  def process(_name, _malformed), do: :noop
  defp fcache_add(_fkey, _source, saddrs_bin) do
    _saddrs = UnpackSync.saddrs(saddrs_bin)
    :todo_ets_fcache_insert
    :todo_ets_add_fnodev4_as_saddrs_source
  end
end