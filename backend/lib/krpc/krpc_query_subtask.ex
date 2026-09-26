defmodule KRPCQuerySubTask do
  require Logger
  @typedoc "20b SHA-1 base value: remote node_id, infohash, other"
  @type ihv :: <<_::160>>
  @type nid :: ihv()
  @type rid :: ihv()
  @type ih :: ihv()
  @type tid :: <<_::16>>
  @type trunc8_hmac_token :: <<_::64>>
  @typedoc "IPv4 node: 4 bytes for IPv4 address, 2 bytes for port as <<a,b,c,d,port::16>>"
  @type nodev4 :: <<_::48>>
  @type peer :: nodev4()
  @ihv "target"
  @ih "info_hash"
  @pq "ping"
  @fnq "find_node"
  @gpq "get_peers"
  @apq "announce_peer"
  @hmac_token "token"
  @vote "vote"
  @hpq "holepunch"
  @smq "sample_infohashes"
  @hmac_token "token"
  @vote "vote"
  @hpq "holepunch"
  @ih "info_hash"
  @gpq "get_peers"
  @apq "announce_peer"
  def handle_query(
        {@apq, %{@ih => ih, @hmac_token => token} = args, tid},
        <<ip_bin::binary-4, _port::16>> = nodev4,
        shard_id
      ) do
    peer = KRPCUtilsSync.build_announced_peer(nodev4, args)
    nid = WorkerIDSync.select_work_id_for_target(ih)
    case TokenSync.verify?(token, ip_bin, nid) do
      false ->
        GenS.Metrics.increment(:announce_failed)
      true ->
        GenS.InfohashCollector.announce(ih, peer)
        reply_packet = WireSync.announce_peer_reply(nid, tid)
        KRPCUtilsSync.send_packet(shard_id, peer, reply_packet)
        GenS.Metrics.increment(:announce)
    end
  end
  def handle_query({@apq, _args, _tid}, _nodev4, _shard_id), do: :noop
  def handle_query({@gpq, %{@ih => ih}, tid}, nodev4, shard_id) do
    <<ip_bin::binary-4, _port::16>> = nodev4
    nid = WorkerIDSync.select_work_id_for_target(ih)
    token = TokenSync.make(ip_bin, nid)
    GenS.KRPCPayloadFactory.get_peers(ih, nodev4, token, nid, tid, shard_id)
  end
  def handle_query({@gpq, _args, _tid}, _nodev4, _shard_id), do: :noop
  def handle_query({@fnq, %{@ihv => ihv}, tid}, nodev4, shard_id) do
    nid = WorkerIDSync.select_work_id_for_nodev4(nodev4)
    GenS.KRPCPayloadFactory.find_node(ihv, nodev4, nid, tid, shard_id)
  end
  def handle_query({@smq, %{@ihv => ihv}, tid}, nodev4, shard_id) do
    nid = WorkerIDSync.select_work_id_for_nodev4(nodev4)
    GenS.KRPCPayloadFactory.sample_infohashes(ihv, nodev4, nid, tid, shard_id)
  end
  def handle_query({@smq, _args, tid}, nodev4, shard_id) do
    nid = WorkerIDSync.select_work_id_for_nodev4(nodev4)
    ihv = IdGenSync.rand_id()
    GenS.KRPCPayloadFactory.sample_infohashes(ihv, nodev4, nid, tid, shard_id)
  end
  @pf_magic "f"
  @f_syn 0
  def handle_query({@pq, %{@pf_magic => @f_syn} = _data, tid}, fnodev4, shard_id) do
    PFOutSync.send_pong(fnodev4)
    # The legacy pong cannot carry a 32-byte Ygg fid; emit a v2 pong as well.
    if Process.whereis(GenS.YggPFScanner) do
      if fid = YggPF.Self.fid() do
        KRPCUtilsSync.send_packet(shard_id, fnodev4, YggPF.Wire.pong(fid))
      end
    end
    Logger.debug("[PF] === QUERY DETECTED === from #{PrinterSync.peer(fnodev4)}")
    nid = WorkerIDSync.select_work_id_for_nodev4(fnodev4)
    reply_packet = WireSync.ping_reply(nid, tid)
    KRPCUtilsSync.send_packet(shard_id, fnodev4, reply_packet)
    GenS.Metrics.increment(:fping)
  end
  def handle_query({@pq, _args, tid}, nodev4, shard_id) do
    nid = WorkerIDSync.select_work_id_for_nodev4(nodev4)
    reply_packet = WireSync.ping_reply(nid, tid)
    KRPCUtilsSync.send_packet(shard_id, nodev4, reply_packet)
    GenS.Metrics.increment(:ping)
  end
  def handle_query({q, _args, _tid}, _n4, _s_id) when q in [@vote, @hpq], do: :noop
  def handle_query({name, args, _tid}, _nodev4, _shard_id) do
    Logger.debug("[KRPC Query] Uhhandled: name: #{name}, args: #{inspect(args)}")
  end
end