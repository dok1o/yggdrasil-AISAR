defmodule Ygg.PublicPeers do
  @moduledoc """
  Public peer discovery (PROMPT_ELIXIR_PORT.md, stage 1 item 1). Downloads the markdown
  files of `github.com/yggdrasil-network/public-peers` per region through the GitHub
  contents API (`:httpc`, JSON via Jason), extracts `tcp://` and `tls://` URIs, picks a
  configurable number of them round-robin across regions and adds them with
  `Ygg.Links.add/2`. The result is cached in a JSON file (`PublicPeers.CacheFile`,
  `CacheTTLHours`) so the site is not hit on every start; without network the cache is used
  regardless of age. Nothing here exists in the Go sources (Yggdrasil has no bootstrap
  discovery); the process runs after the node is up and never blocks it.
  """
  use GenServer
  require Logger
  alias Ygg.{Links, Node, PeerURI}
  @api "https://api.github.com/repos/yggdrasil-network/public-peers/contents/"
  @default_regions ~w(europe north-america south-america asia africa other)
  @uri_re ~r/\b(?:tcp|tls):\/\/[^\s`"'<>)]+/
  @http_timeout 15_000
  def start_link(ctx), do: GenServer.start_link(__MODULE__, ctx, name: Node.via(ctx, __MODULE__))
  @doc "Re-fetch (ignoring the cache) and add new peers."
  def refresh(ctx), do: GenServer.cast(Node.via(ctx, __MODULE__), :refresh)
  @impl true
  def init(%Node{} = ctx), do: {:ok, ctx, {:continue, :load}}
  @impl true
  def handle_continue(:load, ctx) do
    add_peers(ctx, load(ctx.public_peers))
    {:noreply, ctx}
  end
  @impl true
  def handle_cast(:refresh, ctx) do
    case fetch(regions(ctx.public_peers)) do
      {:ok, by_region} ->
        write_cache(ctx.public_peers[:cache_file], by_region)
        add_peers(ctx, select(by_region, ctx.public_peers[:count] || 10))
      {:error, reason} ->
        Logger.warning("Public peers refresh failed: #{inspect(reason)}")
    end
    {:noreply, ctx}
  end
  @doc "Peer URIs to use: fresh cache, else network (then cached), else stale cache, else []."
  @spec load(map()) :: [String.t()]
  def load(opts) do
    count = opts[:count] || 10
    cache_file = opts[:cache_file]
    ttl_ms = (opts[:cache_ttl_hours] || 24) * 3_600_000
    case read_cache(cache_file) do
      {:ok, by_region, age_ms} when age_ms < ttl_ms ->
        select(by_region, count)
      cached ->
        case fetch(regions(opts)) do
          {:ok, by_region} ->
            write_cache(cache_file, by_region)
            select(by_region, count)
          {:error, reason} ->
            Logger.warning("Public peers fetch failed: #{inspect(reason)}")
            case cached do
              {:ok, by_region, _age} ->
                Logger.info("Using stale public peers cache #{cache_file}")
                select(by_region, count)
              _ ->
                []
            end
        end
    end
  end
  @doc "URIs from one markdown file (only tcp/tls, valid per `Ygg.PeerURI`)."
  @spec parse_markdown(String.t()) :: [String.t()]
  def parse_markdown(text) do
    @uri_re
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, "."))
    |> Enum.filter(&match?({:ok, _}, PeerURI.parse(&1)))
    |> Enum.uniq()
  end
  @doc "Round-robin `count` URIs across regions, keeping each region's file order."
  @spec select(%{String.t() => [String.t()]}, non_neg_integer()) :: [String.t()]
  def select(by_region, count) do
    lists = by_region |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 == []))
    round_robin(lists, count, [])
  end
  defp round_robin(_lists, 0, acc), do: Enum.reverse(acc)
  defp round_robin([], _count, acc), do: Enum.reverse(acc)
  defp round_robin(lists, count, acc) do
    {taken, rest} =
      Enum.reduce(lists, {[], []}, fn
        [h | t], {taken, rest} -> {[h | taken], if(t == [], do: rest, else: [t | rest])}
      end)
    taken = Enum.reverse(taken) |> Enum.take(count)
    round_robin(Enum.reverse(rest), count - length(taken), Enum.reverse(taken) ++ acc)
  end
  @doc "Downloads every region's markdown files: `%{region => [uri]}`."
  @spec fetch([String.t()]) :: {:ok, %{String.t() => [String.t()]}} | {:error, term()}
  def fetch(regions) do
    results =
      for region <- regions do
        with {:ok, body} <- http_get(@api <> region),
             {:ok, entries} when is_list(entries) <- Jason.decode(body) do
          uris =
            entries
            |> Enum.filter(&(is_map(&1) and String.ends_with?(&1["name"] || "", ".md")))
            |> Enum.flat_map(fn e ->
              case http_get(e["download_url"]) do
                {:ok, md} -> parse_markdown(md)
                {:error, _} -> []
              end
            end)
          {region, uris}
        else
          {:error, reason} -> {:error, {region, reason}}
          other -> {:error, {region, other}}
        end
      end
    case Enum.split_with(results, &match?({:error, _}, &1)) do
      {errors, []} ->
        {:error, Enum.map(errors, &elem(&1, 1))}
      {errors, ok} ->
        for {:error, e} <- errors,
            do: Logger.warning("Public peers: region failed: #{inspect(e)}")
        {:ok, Map.new(ok)}
    end
  end
  @spec read_cache(Path.t() | nil) :: {:ok, map(), non_neg_integer()} | :none
  def read_cache(nil), do: :none
  def read_cache(file) do
    with {:ok, json} <- File.read(file),
         {:ok, %{"fetched_at" => at, "peers" => peers}} when is_map(peers) <- Jason.decode(json) do
      {:ok, peers, max(System.os_time(:millisecond) - at * 1_000, 0)}
    else
      _ -> :none
    end
  end
  @spec write_cache(Path.t() | nil, map()) :: :ok
  def write_cache(nil, _by_region), do: :ok
  def write_cache(file, by_region) do
    data = %{"fetched_at" => System.os_time(:second), "peers" => by_region}
    case File.write(file, Jason.encode!(data, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Cannot write #{file}: #{inspect(reason)}")
    end
  end
  defp add_peers(ctx, uris) do
    Logger.info("Public peers: adding #{length(uris)}")
    for uri <- uris do
      case Links.add(ctx, uri) do
        :ok -> :ok
        {:error, :already_configured} -> :ok
        {:error, reason} -> Logger.warning("Public peer #{uri} rejected: #{inspect(reason)}")
      end
    end
    :ok
  end
  defp regions(opts), do: opts[:regions] || @default_regions
  defp http_get(nil), do: {:error, :no_url}
  defp http_get(url) do
    headers = [{~c"user-agent", ~c"ygg_ex/0.1"}, {~c"accept", ~c"application/vnd.github+json"}]
    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
    http_opts = [timeout: @http_timeout, connect_timeout: 5_000, ssl: ssl]
    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:http, status, url}}
      {:error, reason} -> {:error, reason}
    end
  end
end