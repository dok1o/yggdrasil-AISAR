defmodule KRPCUtilsSync do
  @compile {:inline,
            [
              get_params_for_nodev4: 1,
              send_packet: 3,
              pack_nodes: 1,
              use_ann_port?: 2,
              build_announced_peer: 2
            ]}
  @ann_port "port"
  @impl_port "implied_port"
  @common_btt_ports [6881, 51413, 49001, 6889, 6882]
  def send_packet(nil, nodev4, packet) do
    shard_id = MathSync.select_udp_shard(nodev4)
    <<a, b, c, d, port::16>> = nodev4
    GenS.UDPSocketShard.send_packet(shard_id, {a, b, c, d}, port, packet)
  end
  def send_packet(shard_id, nodev4, packet) do
    <<a, b, c, d, port::16>> = nodev4
    GenS.UDPSocketShard.send_packet(shard_id, {a, b, c, d}, port, packet)
  end
  def get_params_for_nodev4(nodev4) do
    ihw_id = WorkerIDSync.select_work_id_for_nodev4(nodev4)
    tid = IdGenSync.make_tid()
    {ihw_id, tid}
  end
  def pack_nodes(nodes) do
    for {rid, nodev4} <- nodes, into: <<>>, do: <<rid::binary-20, nodev4::binary-6>>
  end
  def build_announced_peer(<<ip_bin::binary-4, remote_port::16>> = _nodev4, args) do
    ann_port = Map.get(args, @ann_port)
    impl_port = Map.get(args, @impl_port)
    real_port =
      case use_ann_port?(ann_port, impl_port) do
        false -> remote_port
        true -> ann_port
      end
    <<ip_bin::binary-4, real_port::16>>
  end
  def generate_candidates_to_ask(count) do
    1..count
    |> Enum.map(fn _i -> {rand_ip(), rand_dht_port()} end)
    |> Enum.filter(fn {ip, _port} -> UAddrChkSync.valid_ip?(ip) end)
    |> Enum.uniq()
    |> Enum.map(fn {{a, b, c, d}, port} -> <<a, b, c, d, port::16>> end)
  end
  defp use_ann_port?(an_p, im_p), do: is_integer(an_p) and an_p > 0 and im_p == 0
  defp rand_octet(), do: Enum.random(1..255)
  defp rand_high_port(), do: Enum.random(20_000..65_500)
  defp rand_dht_port(), do: Enum.random(@common_btt_ports ++ [rand_high_port()])
  defp rand_ip(), do: {rand_octet(), rand_octet(), rand_octet(), rand_octet()}
end