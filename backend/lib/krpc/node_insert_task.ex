defmodule NodeInsertSubTask do
  import MagnetSorter.Const
  @compile {:inline, [free_slots?: 2]}
  @typedoc "20b SHA-1 base value: remote node_id, infohash, other"
  @type target :: <<_::160>>
  @type rid :: target()
  @typedoc "IPv4 node: 4 bytes for IPv4 address, 2 bytes for port as <<a,b,c,d,port::16>>"
  @type nodev4 :: <<_::48>>
  @type node_entry :: {rid(), nodev4()}
  @ext_ets_nodes :dht_nodes
  @ext_ets_nodes_rev :node_reverse
  @ext_ets_dht_blacklist :dht_blacklist
  @discard_num div(dht_size(), 32)
  def insert(nodes, mode_atom), do: try_insert(nodes, mode_atom)
  defp free_slots?(size, target), do: size <= target + @discard_num
  defp blacklisted?(nodev4), do: TryETS.member?(@ext_ets_dht_blacklist, nodev4)
  defp try_insert(nodes, mode_atom) do
    target = dht_size()
    size = TryETS.size(@ext_ets_nodes)
    if free_slots?(size, target) do
      case mode_atom do
        :one -> filter_insert(nodes, 1)
        :batch -> filter_insert(nodes, max(target - size, 1))
      end
    end
  end
  defp filter_insert(nodes, slots) do
    nodes
    |> Enum.reject(fn {_rid, nodev4} -> blacklisted?(nodev4) end)
    |> Enum.filter(fn {rid, _nodev4} -> WireSync.ihv?(rid) end)
    |> Enum.take(slots)
    |> Enum.each(fn {rid, nodev4} -> sync_put(rid, nodev4) end)
  end
  defp sync_put(rid, n4) do
    case TryETS.take(@ext_ets_nodes, rid) do
      [{^rid, old_n4}] when old_n4 != n4 -> TryETS.delete(@ext_ets_nodes_rev, old_n4)
      _ -> :noop
    end
    case TryETS.take(@ext_ets_nodes_rev, n4) do
      [{^n4, o_rid}] when o_rid != rid -> TryETS.delete(@ext_ets_nodes_rev, o_rid)
      _ -> :noop
    end
    TryETS.insert(@ext_ets_nodes, {rid, n4})
    TryETS.insert(@ext_ets_nodes_rev, {n4, rid})
  end
end