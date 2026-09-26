defmodule KRPCWorkerTask do
  import TimeSync
  @compile {:inline, []}
  @type ihv :: <<_::160>>
  @type nid :: ihv()
  @type nodev4 :: <<_::48>>
  @ext_ets_dht_blacklist :dht_blacklist
  @blacklist_ttl_s 30
  @server_error 202
  @generic_error 201
  @protocol_error 203
  @method_unknown_error 204
  @temp_blacklist_errors [@generic_error, @protocol_error, @method_unknown_error]
  @b_errors @temp_blacklist_errors
  def process_dht(packet, ipv4_tuple, port, udp_shard_id),
    do: do_process_dht(packet, ipv4_tuple, port, udp_shard_id)
  defp do_process_dht(packet, {a, b, c, d} = ip, port, s_id) do
    nodev4 = <<a, b, c, d, port::16>>
    if UAddrChkSync.valid_ip?(ip) do
      case WireSync.recv(packet) do
        {:error, @server_error, _msg, _tid} -> :noop
        {:error, code, _msg, _tid} when code in @b_errors -> process_blacklist_err(nodev4)
        {:error, code, msg, _tid} -> process_other_codes(code, msg)
        {:error, :libtorrent_keepalive} -> :noop
        {:error, :non_sha1_args, _payload} -> :noop
        {:error, :malformed_map, _map} -> :noop
        {:query, n, {rid, args}, tid} -> query_subtask(n, {rid, args}, tid, nodev4, s_id)
        {:reply, {rid, data}, tid} -> reply_subtask(data, {rid, nodev4}, tid)
      end
    end
  end
  defp query_subtask(name, {rid, args}, tid, nodev4, shard_id) do
    KRPCQuerySubTask.handle_query({name, args, tid}, nodev4, shard_id)
    NodeInsertSubTask.insert([{rid, nodev4}], :one)
    GenS.Metrics.increment(:recvd)
  end
  defp reply_subtask(data, {rid, nodev4}, tid) do
    KRPCReplySubTask.handle_reply(data, {rid, nodev4}, tid)
    NodeInsertSubTask.insert([{rid, nodev4}], :one)
    GenS.Metrics.increment(:recvd)
  end
  defp process_blacklist_err(nodev4) do
    TryETS.insert(@ext_ets_dht_blacklist, {nodev4, expires_in(@blacklist_ttl_s)})
    GenS.Metrics.increment(:dht_node_blacklisted)
  end
  defp process_other_codes(_code, _msg), do: :noop
end