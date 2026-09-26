defmodule YggPF.WebPeers do
  @moduledoc """
  Yggdrasil peer discovery by web scrape (spec sections 36-39).

  A faithful Elixir port of `web scrape/ygg_peers_fetch.sh`,
  `web scrape/parse_ygg_peers.py` and `web scrape/update_ygg_config.py`. No Python
  shell-out (spec section 39): fetching uses OTP's `:httpc`, JSON uses `Jason`, both already
  available to this project.

  Pipeline (spec section 39): fetch -> parse -> validate -> deduplicate -> classify source
  -> store/expose.

  ## Priority

  Web-scraped and manually supplied peers are **low priority** (spec section 36, INV-019).
  Validated scan-discovered Ygg relays outrank them (spec section 37, INV-020). `merged/2`
  applies that ordering.

  Spec section 37 also warns that routing priority and configuration persistence are separate
  concerns: outranking a web-scraped peer in the active list must not delete the
  user's configured peers. Nothing here writes to user config - `merged/2` returns a
  ranked list and leaves persistence to the caller.

  ## Behaviour carried over from the shell/Python originals

    * source `https://api.github.com/repos/yggdrasil-network/public-peers/contents/{region}`
    * region defaults to `europe`, limit defaults to 20
    * URI schemes `tcp tls quic ws wss socks sockstls`
    * trailing `.,);:'"` stripped from each match
    * order-preserving dedup by URI
    * peers grouped by the Ygg IPv6 identity found within 500 characters after the
      URI, falling back to the host, so one node contributes one URI
    * groups shuffled, then the first URI of each is taken up to the limit
  """

  require Logger

  @api "https://api.github.com/repos/yggdrasil-network/public-peers/contents"
  @default_region "europe"
  @default_limit 20
  @schemes ~w(tcp tls quic ws wss socks sockstls)
  @window 500
  @user_agent ~c"yggdrasil-AISAR/ygg_pf"

  # Mirrors parse_ygg_peers.py:17-19
  @uri_re ~r/(?:tcp|tls|quic|ws|wss|socks|sockstls):\/\/[^\s`<>()\[\]]+/
  # Mirrors parse_ygg_peers.py:36-40
  @ygg_addr_re ~r/\b2[0-9a-f]{2}:[0-9a-f:]{10,}\b/i

  @type source :: :web_scrape | :manual | :scan
  @type peer :: %{uri: String.t(), identity: String.t() | nil, source: source(), priority: integer()}

  @doc "Priority ordering. Lower sorts first. Spec sections 36, 37."
  def priority(:scan), do: 0
  def priority(:manual), do: 10
  def priority(:web_scrape), do: 20

  # ------------------------------------------------------------------ #
  # Fetch                                                               #
  # ------------------------------------------------------------------ #

  @doc """
  Fetch, parse and select peers for a region.

  Options: `:region`, `:limit`, `:shuffle?`, `:http` (injectable fetcher for tests).
  """
  @spec fetch(keyword()) :: {:ok, [peer()]} | {:error, term()}
  def fetch(opts \\ []) do
    region = Keyword.get(opts, :region, @default_region)
    limit = Keyword.get(opts, :limit, @default_limit)
    http = Keyword.get(opts, :http, &http_get/1)

    with {:ok, listing} <- http.("#{@api}/#{region}"),
         {:ok, urls} <- download_urls(listing),
         {:ok, text} <- fetch_all(urls, http) do
      {:ok, select(text, limit, opts)}
    end
  end

  defp download_urls(body) do
    case Jason.decode(body) do
      {:ok, entries} when is_list(entries) ->
        {:ok, entries |> Enum.map(&Map.get(&1, "download_url")) |> Enum.reject(&is_nil/1)}

      {:ok, %{"message" => msg}} ->
        {:error, {:github_api, msg}}

      _other ->
        {:error, :unexpected_listing}
    end
  end

  defp fetch_all([], _http), do: {:error, :no_peer_files}

  defp fetch_all(urls, http) do
    # The shell original concatenates every file into one blob before parsing, so
    # the 500-character identity window can span a file boundary. Preserved here.
    text =
      urls
      |> Enum.map(fn url ->
        case http.(url) do
          {:ok, body} ->
            body

          {:error, reason} ->
            Logger.warning("[YggPF.WebPeers] skipping #{url}: #{inspect(reason)}")
            ""
        end
      end)
      |> Enum.join("\n")

    case String.trim(text) do
      "" -> {:error, :no_peers_fetched}
      _non_empty -> {:ok, text}
    end
  end

  # ------------------------------------------------------------------ #
  # Parse / validate / dedup / select                                   #
  # ------------------------------------------------------------------ #

  @doc "Extract peer URIs, preserving order and removing duplicates."
  @spec parse_uris(String.t()) :: [String.t()]
  def parse_uris(text) when is_binary(text) do
    @uri_re
    |> Regex.scan(text)
    |> Enum.map(fn [uri | _] -> strip_punct(uri) end)
    |> Enum.filter(&valid_uri?/1)
    |> Enum.uniq()
  end

  # parse_ygg_peers.py:24 - uri.rstrip(".,);:'\"")
  defp strip_punct(uri), do: String.replace(uri, ~r/[.,);:'"]+$/, "")

  @doc """
  Validate a peer URI: known scheme, non-empty host, and a parseable port when present.
  """
  @spec valid_uri?(String.t()) :: boolean()
  def valid_uri?(uri) when is_binary(uri) do
    case String.split(uri, "://", parts: 2) do
      [scheme, rest] when rest != "" ->
        scheme in @schemes and host_part(rest) != ""

      _malformed ->
        false
    end
  end

  def valid_uri?(_other), do: false

  defp host_part(rest) do
    rest
    |> String.split(["/", "?"], parts: 2)
    |> List.first()
    |> to_string()
  end

  @doc """
  Group URIs by Yggdrasil identity, mirroring `parse_ygg_peers.py:31-44`.

  For each URI we look at the 500 characters of source text starting at its first
  occurrence and take the first Ygg-looking IPv6 address found there. If none is
  found the host acts as the identity, so distinct hosts are never merged.
  """
  @spec group_by_identity(String.t(), [String.t()]) :: [{String.t(), [String.t()]}]
  def group_by_identity(text, uris) do
    uris
    |> Enum.reduce({[], %{}}, fn uri, {order, groups} ->
      key = identity_for(text, uri)

      case Map.has_key?(groups, key) do
        true -> {order, Map.update!(groups, key, &(&1 ++ [uri]))}
        false -> {order ++ [key], Map.put(groups, key, [uri])}
      end
    end)
    |> then(fn {order, groups} -> Enum.map(order, &{&1, Map.fetch!(groups, &1)}) end)
  end

  defp identity_for(text, uri) do
    case :binary.match(text, uri) do
      {pos, _len} ->
        section = binary_part(text, pos, min(@window, byte_size(text) - pos))

        case Regex.run(@ygg_addr_re, section) do
          [addr | _] -> String.downcase(addr)
          nil -> fallback_identity(uri)
        end

      :nomatch ->
        fallback_identity(uri)
    end
  end

  defp fallback_identity(uri) do
    case String.split(uri, "//", parts: 2) do
      [_scheme, rest] -> rest
      _other -> uri
    end
  end

  @doc "Full parse + group + select, from raw concatenated source text."
  @spec select(String.t(), pos_integer(), keyword()) :: [peer()]
  def select(text, limit \\ @default_limit, opts \\ []) do
    uris = parse_uris(text)
    groups = group_by_identity(text, uris)

    groups =
      case Keyword.get(opts, :shuffle?, true) do
        true -> Enum.shuffle(groups)
        false -> groups
      end

    Logger.info("[YggPF.WebPeers] #{length(uris)} URIs, #{length(groups)} unique nodes")

    groups
    |> Enum.take(limit)
    |> Enum.map(fn {identity, [uri | _rest]} ->
      %{uri: uri, identity: identity, source: :web_scrape, priority: priority(:web_scrape)}
    end)
  end

  @doc "Wrap a user-supplied manual peer list. Low priority, like web scrape (spec section 36)."
  @spec manual([String.t()]) :: [peer()]
  def manual(uris) do
    uris
    |> Enum.filter(&valid_uri?/1)
    |> Enum.uniq()
    |> Enum.map(&%{uri: &1, identity: nil, source: :manual, priority: priority(:manual)})
  end

  @doc "Wrap a validated scan-discovered relay. Outranks web-scraped peers (spec section 37)."
  @spec scan_relay(String.t(), String.t() | nil) :: peer()
  def scan_relay(uri, identity \\ nil),
    do: %{uri: uri, identity: identity, source: :scan, priority: priority(:scan)}

  @doc """
  Merge peer sets into the active Ygg peer list, highest priority first.

  Scan-discovered relays replace web-scraped peers for the same identity
  (spec section 37, INV-020). Deduplication is by identity where known, otherwise by URI.
  Returns a ranked list; it does not write configuration.
  """
  @spec merged([peer()], pos_integer() | :infinity) :: [peer()]
  def merged(peers, limit \\ :infinity) do
    peers
    |> Enum.sort_by(& &1.priority)
    |> Enum.uniq_by(&(&1.identity || &1.uri))
    |> then(fn list ->
      case limit do
        :infinity -> list
        n -> Enum.take(list, n)
      end
    end)
  end

  # ------------------------------------------------------------------ #
  # HTTP                                                                #
  # ------------------------------------------------------------------ #

  defp http_get(url) do
    ensure_started()

    headers = [
      {~c"user-agent", @user_agent},
      {~c"accept", ~c"application/vnd.github+json"}
    ]

    request = {String.to_charlist(url), headers}
    opts = [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()], timeout: 15_000]

    case :httpc.request(:get, request, opts, body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, body}} -> {:ok, body}
      {:ok, {{_v, status, _r}, _h, _body}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_started do
    Enum.each([:inets, :ssl], fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[YggPF.WebPeers] #{app}: #{inspect(reason)}")
      end
    end)
  end
end
