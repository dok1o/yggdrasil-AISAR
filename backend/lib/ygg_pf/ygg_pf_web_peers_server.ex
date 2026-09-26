defmodule GenS.YggPFWebPeers do
  @moduledoc """
  Brings the node up on web-scraped Yggdrasil peers, and keeps the scrape fresh.

  On start it takes a random set of `YggPF.Const.web_bootstrap_peers/0` peers
  (16) from the scraped population and hands each to the running Yggdrasil node
  via `Ygg.add_peer/1`. The cache is refreshed every two hours and a fresh random
  set is connected.

  ## Deliberate choices

  **Nothing is written to `ygg.json`.** Spec section 37 warns that routing priority and
  configuration persistence are separate concerns: peers are added to the *live*
  node only, so the user's configured peer list is never rewritten or deleted.

  **Startup never blocks the supervisor.** The scrape is network I/O of unknown
  duration, so `init/1` returns immediately and the work happens in
  `handle_continue/2`. A failure is logged and retried, not fatal - spec section 45 forbids
  blocking forever on bootstrap.

  **These peers stay low priority.** They are `:web_scrape` source (spec section 36), and
  scan-discovered relays outrank and replace them (spec section 37). This module only
  supplies the initial transport so the Ygg node can reach the network at all;
  it does not claim they are good peers.
  """

  use GenServer
  require Logger

  alias YggPF.{Const, WebPeers}

  @retry_ms 60_000

  defstruct connected: [], last_refresh_ms: 0, failures: 0, opts: []

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Force a re-scrape and connect a fresh random set. Used by the GUI button."
  def refresh_now(opts \\ []), do: GenServer.cast(__MODULE__, {:refresh, opts})

  @doc "Peers this process has connected."
  def connected, do: GenServer.call(__MODULE__, :connected)

  # ------------------------------------------------------------------ #

  @impl true
  def init(opts) do
    WebPeers.create_table()
    {:ok, %__MODULE__{opts: opts}, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, st), do: {:noreply, do_refresh(st, st.opts)}

  @impl true
  def handle_call(:connected, _from, st), do: {:reply, st.connected, st}

  @impl true
  def handle_cast({:refresh, opts}, st) do
    {:noreply, do_refresh(st, Keyword.put(opts, :force, true))}
  end

  @impl true
  def handle_info(:refresh, st), do: {:noreply, do_refresh(st, st.opts)}
  def handle_info(_other, st), do: {:noreply, st}

  # ------------------------------------------------------------------ #

  defp do_refresh(st, opts) do
    case WebPeers.bootstrap_set(opts) do
      {:ok, []} ->
        Logger.warning("[YggPF.WebPeers] scrape returned no peers; retrying in #{@retry_ms}ms")
        schedule(@retry_ms)
        %{st | failures: st.failures + 1}

      {:ok, peers} ->
        connected = connect_all(peers)

        Logger.info(
          "[YggPF.WebPeers] bootstrap: #{length(connected)}/#{length(peers)} peer(s) accepted " <>
            "by the Yggdrasil node; next refresh in #{div(Const.web_cache_ttl_ms(), 60_000)} min"
        )

        schedule(Const.web_cache_ttl_ms())
        %{st | connected: connected, last_refresh_ms: System.os_time(:millisecond), failures: 0}

      {:error, reason} ->
        Logger.error(
          "[YggPF.WebPeers] peer scrape failed: #{inspect(reason)}. " <>
            "Retrying in #{div(@retry_ms, 1000)}s. The Yggdrasil node may have no peers " <>
            "until this succeeds, which also means ygg_pf cannot validate candidates."
        )

        schedule(@retry_ms)
        %{st | failures: st.failures + 1}
    end
  end

  defp connect_all(peers) do
    Enum.reduce(peers, [], fn peer, acc ->
      case add_peer(peer.uri) do
        :ok ->
          Logger.info("[YggPF.WebPeers]   + #{peer.uri}")
          [peer | acc]

        {:error, reason} ->
          Logger.warning("[YggPF.WebPeers]   ! #{peer.uri} rejected: #{inspect(reason)}")
          acc
      end
    end)
    |> Enum.reverse()
  end

  # The embedded node may still be starting; never let that crash this process.
  defp add_peer(uri) do
    case Ygg.add_peer(uri) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp schedule(ms), do: Process.send_after(self(), :refresh, ms)
end
