defmodule Ygg.StatusPrinter do
  @moduledoc """
  Periodic status table in the log. Replaces the admin socket / `yggdrasilctl getPeers`
  (`reference/yggdrasil-go/_other/src/admin/getpeers.go`, not ported): the same columns as `PeerEntry` that make
  sense without ironwood's tree (URI, direction, key, address, up, uptime, latency, bytes and
  rates, last error) plus the parent/seq seen in the peer's last Announce.
  """
  use GenServer
  require Logger
  alias Ygg.{Identity, Links}
  def start_link(ctx), do: GenServer.start_link(__MODULE__, ctx)
  @impl true
  def init(ctx) do
    Process.send_after(self(), :print, ctx.status_interval_ms)
    {:ok, ctx}
  end
  @impl true
  def handle_info(:print, ctx) do
    Process.send_after(self(), :print, ctx.status_interval_ms)
    Logger.info("\n" <> format(Links.list(ctx), ctx.identity))
    {:noreply, ctx}
  end
  @doc "Text table for a `Ygg.Links.list/1` result."
  @spec format([map()], Identity.t()) :: String.t()
  def format(links, %Identity{} = id) do
    up = Enum.count(links, & &1.up)
    head =
      "node #{Identity.pub_hex(id) |> binary_part(0, 8)} #{Ygg.Address.format(id.address)}: #{up}/#{length(links)} links up"
    cols = ~w(URI DIR KEY ADDRESS STATE UPTIME RTT RX TX PARENT/SEQ ERROR)
    rows =
      links
      |> Enum.sort_by(&{not &1.up, &1.uri})
      |> Enum.map(fn l ->
        [
          String.slice(l.uri, 0, 44),
          if(l.inbound, do: "in", else: "out"),
          if(l.key, do: binary_part(l.key, 0, 8), else: "-"),
          l.address || "-",
          Atom.to_string(l.state),
          if(l.up, do: duration(l.uptime_ms), else: "-"),
          if(l.rtt_ms, do: "#{l.rtt_ms}ms", else: "-"),
          "#{bytes(l.rx_bytes)} #{bytes(l.rx_rate)}/s",
          "#{bytes(l.tx_bytes)} #{bytes(l.tx_rate)}/s",
          if(l.parent, do: "#{binary_part(l.parent, 0, 8)}/#{l.seq}", else: "-"),
          if(l.last_error,
            do: "#{inspect(l.last_error)} #{duration(l.last_error_age_ms)} ago",
            else: ""
          )
        ]
      end)
    widths =
      Enum.map(0..(length(cols) - 1), fn i ->
        [cols | rows] |> Enum.map(&String.length(Enum.at(&1, i))) |> Enum.max()
      end)
    line = fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {c, w} -> String.pad_trailing(c, w) end)
      |> String.trim_trailing()
    end
    Enum.join([head, line.(cols) | Enum.map(rows, line)], "\n")
  end
  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m#{rem(div(ms, 1000), 60)}s"
  defp duration(ms), do: "#{div(ms, 3_600_000)}h#{rem(div(ms, 60_000), 60)}m"
  defp bytes(n) when n < 1_024, do: "#{n}B"
  defp bytes(n) when n < 1_048_576, do: "#{Float.round(n / 1_024, 1)}K"
  defp bytes(n), do: "#{Float.round(n / 1_048_576, 1)}M"
end