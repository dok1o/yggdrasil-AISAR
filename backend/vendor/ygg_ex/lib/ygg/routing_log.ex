defmodule Ygg.RoutingLog do
  @moduledoc """
  Routing data sink for `Ygg.Router.Native`: every dump and event goes to `Logger` as a
  one-line summary and, when a file is configured (`RoutingLogFile`, default
  `log/routing.jsonl`), as one JSON object per line with the full data
  (`{"ts": iso8601, "node": id, "event": "dump" | "link" | "path_notify" | "lookup", "data": ...}`).
  The dump layout is the `dumpJSON` of the former Go sidecar (STAGE2_CONTRACTS.md §5): `self`,
  `root`, `parent`, `depth`, `peers` (port, cost, priority, latency_ms), `tree` (key,
  parent, seq), `paths`, `blooms` (bit counts), `sessions` (encrypted mode).
  """
  require Logger
  @spec append(Path.t() | nil, term(), String.t(), map() | list()) :: :ok | {:error, term()}
  def append(nil, _node, _event, _data), do: :ok
  def append("", _node, _event, _data), do: :ok
  def append(path, node, event, data) do
    line = Jason.encode!(%{ts: now(), node: inspect(node), event: event, data: data})
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("Routing log #{path}: #{inspect(reason)}")
        err
    end
  end
  @doc "One-line summary of a routing dump for the log."
  @spec summary(map()) :: String.t()
  def summary(%{"self" => self} = d) do
    peers = Map.get(d, "peers", [])
    peer_str =
      peers
      |> Enum.sort_by(& &1["port"])
      |> Enum.map_join(" ", fn p ->
        "#{short(p["key"])}:p#{p["port"]}/c#{p["cost"]}/#{fmt_ms(p["latency_ms"])}"
      end)
    "routing #{short(self["key"])}: root=#{short(d["root"])} depth=#{d["depth"]} " <>
      "parent=#{short(d["parent"])} peers=#{length(peers)} [#{peer_str}] " <>
      "tree=#{length(Map.get(d, "tree", []))} paths=#{length(Map.get(d, "paths", []))} " <>
      "blooms=#{length(Map.get(d, "blooms", []))} sessions=#{length(Map.get(d, "sessions", []))} " <>
      "entries=#{self["routing_entries"]}"
  end
  def summary(other), do: "routing dump: #{inspect(other, limit: 20)}"
  @doc "Per-key view of a dump for `Ygg.Links.peer_info/3`: latency, port, cost, parent, seq."
  @spec peer_infos(map()) :: %{String.t() => map()}
  def peer_infos(dump) do
    tree = Map.new(Map.get(dump, "tree", []), &{&1["key"], &1})
    Map.new(Map.get(dump, "peers", []), fn p ->
      t = Map.get(tree, p["key"], %{})
      bloom = Enum.find(Map.get(dump, "blooms", []), &(&1["key"] == p["key"]))
      {p["key"],
       %{
         rtt_ms: round_ms(p["latency_ms"]),
         port: p["port"],
         cost: p["cost"],
         parent: t["parent"],
         seq: t["seq"],
         bloom_size: bloom && bloom["recv_bits"],
         counts: %{}
       }}
    end)
  end
  defp round_ms(ms) when is_number(ms) and ms > 0, do: Float.round(ms / 1, 2)
  defp round_ms(_), do: nil
  defp fmt_ms(ms) when is_number(ms) and ms > 0, do: "#{Float.round(ms / 1, 1)}ms"
  defp fmt_ms(_), do: "-"
  defp short(hex) when is_binary(hex) and byte_size(hex) >= 8, do: binary_part(hex, 0, 8)
  defp short(_), do: "-"
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end