defmodule Sender do
  def many_find_node_bs(to_query), do: send_bs_fn_queries(to_query)
  def many_find_node(to_query, :nid), do: send_fn_queries(to_query, :nid)
  def many_find_node(to_query, {:fid, fid}), do: send_fn_queries(to_query, {:fid, fid})
  def paint(), do: :noop
  def scan(), do: :noop
  def many_samples(nodes), do: send_sample_queries(nodes)
  def many_get_peers(to_query), do: send_get_peers_queries(to_query)
  def many_get_peers_samples(to_query), do: send_get_peers_targeted(to_query)
  defp send_bs_fn_queries(to_query) do
    boot_id = PFMaskSync.generate_fid(IdGenSync.rand_id())
    to_query
    |> Enum.uniq()
    |> Enum.each(fn nodev4 ->
      target = IdGenSync.rand_id()
      KRPCOutSync.find_node(target, nodev4, :hash_table_bootstrap, boot_id)
    end)
  end
  defp send_get_peers_targeted(pairs) do
    Enum.reduce(pairs, 0, fn {ih, nodev4}, acc ->
      KRPCOutSync.get_peers(ih, nodev4, {:peers_sample, ih})
      acc + 1
    end)
  end
  defp send_get_peers_queries(to_query) do
    Enum.reduce(to_query, 0, fn {target, context}, acc ->
      nodes = ETSLookup.closest_nodes(target)
      Enum.each(nodes, fn {_rid, nodev4} -> KRPCOutSync.get_peers(target, nodev4, context) end)
      acc + length(nodes)
    end)
  end
  defp send_fn_queries(to_query, :nid) do
    Enum.reduce(to_query, 0, fn {target, context}, acc ->
      case ETSLookup.closest_nodes(target) do
        [] ->
          case ETSLookup.random_nodes(1) do
            [{_rid, nodev4}] ->
              KRPCOutSync.find_node(target, nodev4, context, :nid)
              acc + 1
            [] ->
              acc
          end
        found_nodes ->
          Enum.each(found_nodes, fn {_rid, nodev4} ->
            KRPCOutSync.find_node(target, nodev4, context, :nid)
          end)
          acc + length(found_nodes)
      end
    end)
  end
  defp send_fn_queries(to_query, {:fid, fid}) do
    Enum.reduce(to_query, 0, fn {target, context}, acc ->
      case ETSLookup.closest_nodes(target) do
        [] ->
          case ETSLookup.random_nodes(1) do
            [{_rid, nodev4}] ->
              KRPCOutSync.find_node(target, nodev4, context, fid)
              acc + 1
            [] ->
              acc
          end
        found_nodes ->
          Enum.each(found_nodes, fn {_rid, nodev4} ->
            KRPCOutSync.find_node(target, nodev4, context, fid)
          end)
          acc + length(found_nodes)
      end
    end)
  end
  defp send_sample_queries(nodes) do
    nodes
    |> Enum.reduce([], fn {rid, nodev4}, acc ->
      tid = IdGenSync.make_tid()
      KRPCOutSync.sample_infohashes(nodev4, tid, :samples)
      [{{rid, nodev4}, tid} | acc]
    end)
  end
end