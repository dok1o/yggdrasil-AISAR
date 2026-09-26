defmodule KRPCReplySubTask do
  @type rid :: <<_::160>>
  @type nodev4 :: <<_::48>>
  @type fnode :: nodev4()
  @type source :: nodev4()
  @type node_entry :: {rid(), nodev4()}
  @nodes "nodes"
  @values "values"
  @samples "samples"
  @ext_ets_inbox :dht_inbox
  @hash_table_work [:hash_table_bootstrap, :hash_table_rotation]
  def handle_reply(%{@nodes => <<>>} = _data, {_rid, _nodev4}, _tid), do: :noop
  def handle_reply(%{@values => []} = _data, {_rid, _nodev4}, _tid), do: :noop
  def handle_reply(data, {rid, nodev4}, tid) do
    case TryETS.lookup(@ext_ets_inbox, tid) do
      [{^tid, ctx}] ->
        TryETS.delete(@ext_ets_inbox, tid)
        handle_ctx(ctx, data, {rid, nodev4}, tid)
      [] ->
        :noop
    end
  end
  def handle_ctx(h_ctx, data, {_rid, nodev4}, _tid) when h_ctx in @hash_table_work do
    maybe_payload(nil, UnpackSync.nodes(data[@nodes]), nodev4, :nodes)
  end
  def handle_ctx(:pf_bootstrap, data, {_rid, nodev4}, _tid) do
    maybe_payload(nil, UnpackSync.nodes(data[@nodes]), nodev4, :pf_nodes)
  end
  def handle_ctx({:get_peers_asked, ih}, data, {_rid, nodev4}, _tid) do
    maybe_payload(ih, UnpackSync.nodes(data[@nodes]), nodev4, :nodes)
    try_find_woker(ih, UnpackSync.peers(data[@values]), nodev4, :values)
  end
  def handle_ctx({:peers_sample, ih}, data, {_rid, nodev4}, _tid) do
    maybe_payload(ih, UnpackSync.nodes(data[@nodes]), nodev4, :nodes)
    maybe_payload(ih, UnpackSync.peers(data[@values]), nodev4, :peers_sample)
  end
  def handle_ctx({:ihw, pid}, data, {_rid, _nodev4}, _tid) do
    maybe_payload_ihw(pid, UnpackSync.nodes(data[@nodes]), :ihw_n)
    maybe_payload_ihw(pid, UnpackSync.nodes(data[@values]), :ihw_p)
  end
  def handle_ctx(:samples, data, {rid, nodev4}, tid) do
    maybe_samples(UnpackSync.samples(data[@samples]), {rid, nodev4}, tid)
  end
  def handle_ctx(other_ctx, data, {_rid, _nodev4}, _tid) do
    require Logger
    alias Logger, as: LTemp
    LTemp.debug("[KRPC Reply] Unhandled ctx: #{other_ctx}, data: #{inspect(data)}")
  end
  defp maybe_payload(_ih, [], _source, _payload_type), do: :noop
  defp maybe_payload(ih, list, source, payload_type) do
    case payload_type do
      :nodes -> nodes_reply_logic(list)
      :peers_sample -> do_sample_peers(ih, list, source)
      :pf_nodes -> GenS.PFNodesProcessor.check_mask(list, :pf_nodes)
    end
  end
  defp maybe_payload_ihw(_pid, [], _payload_type), do: :noop
  defp maybe_payload_ihw(pid, list, :ihw_n), do: send(pid, {:nodes, list})
  defp maybe_payload_ihw(pid, list, :ihw_p), do: send(pid, {:new_peers, list, :values})
  defp do_sample_peers(ih, list, source) do
    GenS.SampleCoordinator.sample_peers(ih, list, source)
    try_find_woker(ih, list, source, :values)
  end
  defp maybe_samples([], {_rid, _nodev4}, _tid), do: :noop
  defp maybe_samples(samples, {rid, nodev4}, tid) do
    GenS.SampleCoordinator.sample_response(samples, {rid, nodev4}, tid)
  end
  defp nodes_reply_logic(nodes) do
    NodeInsertSubTask.insert(nodes, :batch)
    GenS.PFNodesProcessor.check_mask(nodes, :legacy_nodes)
  end
  defp try_find_woker(ih, list, peer, :values) do
    GenS.IHWorkerRouter.find(ih, list, peer, :values)
  end
end