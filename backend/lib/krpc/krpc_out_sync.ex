defmodule KRPCOutSync do
  @ext_ets_inbox :dht_inbox
  def get_peers(ih, nodev4, context) do
    {nid, tid} = KRPCUtilsSync.get_params_for_nodev4(nodev4)
    TryETS.insert(@ext_ets_inbox, {tid, context})
    packet = WireSync.get_peers(nid, ih, tid)
    KRPCUtilsSync.send_packet(nil, nodev4, packet)
  end
  def find_node(target, nodev4, context, :nid) do
    {nid, tid} = KRPCUtilsSync.get_params_for_nodev4(nodev4)
    packet = WireSync.find_node(nid, target, tid)
    TryETS.insert(@ext_ets_inbox, {tid, context})
    KRPCUtilsSync.send_packet(nil, nodev4, packet)
  end
  def find_node(target, nodev4, context, bid) do
    tid = IdGenSync.make_tid()
    packet = WireSync.find_node(bid, target, tid)
    TryETS.insert(@ext_ets_inbox, {tid, context})
    KRPCUtilsSync.send_packet(nil, nodev4, packet)
  end
  def sample_infohashes(nodev4, tid, context) do
    {nid, _tid} = KRPCUtilsSync.get_params_for_nodev4(nodev4)
    target = IdGenSync.rand_id()
    packet = WireSync.sample_infohashes(nid, target, tid)
    TryETS.insert(@ext_ets_inbox, {tid, context})
    KRPCUtilsSync.send_packet(nil, nodev4, packet)
  end
  def ping(nodev4) do
    {nid, tid} = KRPCUtilsSync.get_params_for_nodev4(nodev4)
    TryETS.insert(@ext_ets_inbox, {tid, nil})
    packet = WireSync.ping(nid, tid)
    KRPCUtilsSync.send_packet(nil, nodev4, packet)
  end
  def ping_x(nodev4) do
    require Logger
    alias Logger, as: LTemp
    {nid, tid} = KRPCUtilsSync.get_params_for_nodev4(nodev4)
    packet = WireSync.ping_x(nid, tid)
    KRPCUtilsSync.send_packet(nil, nodev4, packet)
    LTemp.info("[PFOut] SENDING ping_x tid=#{Base.encode16(tid)} to #{PrinterSync.peer(nodev4)}")
  end
end