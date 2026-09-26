defmodule YggPF.WebPeers do
  @moduledoc """
  Yggdrasil peer discovery by web scrape (spec sections 36-39).

  An Elixir port of `web scrape/ygg_peers_fetch.sh`, `parse_ygg_peers.py` and
  `update_ygg_config.py`, with no Python shell-out (spec section 39). Fetching uses OTP's
  `:httpc`, JSON uses `Jason`.

  Pipeline (spec section 39): fetch -> parse -> validate -> deduplicate -> classify source
  -> store/expose.

  ## Differences from the shell original, by request

    * **All regions, walked recursively.** The original hard-coded `REGION=europe`
      and listed one directory. This walks the whole `public-peers` tree: the repo
      root is listed, every directory is recursed into, and every `.md` file below
      the root contributes peers. Root-level files (README and friends) are skipped
      so their example URIs are not mistaken for live peers.
    * **TCP and TLS only.** `quic`, `ws`, `wss`, `socks` and `sockstls` are rejected.
    * **Two-hour cache**, in ETS and mirrored to disk so a restart does not re-scrape.
    * **Random bootstrap set.** `bootstrap_set/1` draws N peers at random from the
      full cached population, so two starts within one cache window still pick
      different peers.

  ## A trap worth knowing about

  `sockstls://host` contains the substring `tls://`. A naive `(?:tcp|tls)://` pattern
  matches it at offset 5 and silently readmits exactly the scheme we are excluding.
  `@uri_re` therefore carries a `(?<![a-z])` guard, and `valid_uri?/1` re-checks the
  scheme after parsing.

  ## Priority

  Web-scraped and manually supplied peers are **low priority** (spec section 36, INV-019);
  validated scan-discovered relays outrank them (spec section 37, INV-020). `merged/2`
  applies that ordering. Nothing here writes user configuration - peers are handed
  to the running node, and `merged/2` returns a ranked list for the caller to use.
  """

  require Logger
  alias YggPF.Const

  @repo "yggdrasil-network/public-peers"
  @api "https://api.github.com/repos/#{@repo}/contents"
  @default_limit 16
  @max_depth 4
  @window 500
  @user_agent ~c"yggdrasil-AISAR/ygg_pf"

  @schemes ~w(tcp tls)
  # (?<![a-z]) stops sockstls:// from matching as tls://
  @uri_re ~r/(?<![a-z])(?:tcp|tls):\/\/[^\s`<>()\[\]]+/
  # Mirrors parse_ygg_peers.py:36-40
  @ygg_addr_re ~r/\b2[0-9a-f]{2}:[0-9a-f:]{10,}\b/i

  @ets :ygg_pf_web_cache
  @cache_key :peers
  @cache_file "../data/caches/ygg_web_peers.json"

  @type source :: :web_scrape | :manual | :scan
  @type peer :: %{
          uri: String.t(),
          identity: String.t() | nil,
          source: source(),
          priority: integer()
        }

  @doc "Priority ordering. Lower sorts first. Spec sections 36, 37."
  def priority(:scan), do: 0
  def priority(:manual), do: 10
  def priority(:web_scrape), do: 20

  def schemes, do: @schemes
  def create_table, do: TryETS.create_many_named([@ets], :set, :public, true, true)

  # ------------------------------------------------------------------ #
  # Cache                                                               #
  # ------------------------------------------------------------------ #

  @doc """
  Every known web-scraped peer, from cache when fresh, otherwise re-scraped.

  Options: `:force` to ignore the cache, `:http` to inject a fetcher, plus anything
  `scrape/1` accepts.
  """
  @spec all_peers(keyword()) :: {:ok, [peer()]} | {:error, term()}
  def all_peers(opts \\ []) do
    case Keyword.get(opts, :force, false) do
      false ->
        case cached() do
          {:ok, peers, age_ms} ->
            Logger.info(
              "[YggPF.WebPeers] using cached peers: #{length(peers)} entries, " <>
                "age #{div(age_ms, 1000)}s of #{div(Const.web_cache_ttl_ms(), 1000)}s"
            )

            {:ok, peers}

          :expired ->
            Logger.info("[YggPF.WebPeers] peer cache expired, re-scraping")
            refresh(opts)

          :miss ->
            refresh(opts)
        end

      true ->
        refresh(opts)
    end
  end

  @doc "Scrape now and replace the cache."
  @spec refresh(keyword()) :: {:ok, [peer()]} | {:error, term()}
  def refresh(opts \\ []) do
    case scrape(opts) do
      {:ok, []} -> {:error, :no_peers_found}
      {:ok, peers} -> {:ok, put_cache(peers)}
      {:error, _} = err -> fall_back_to_stale(err)
    end
  end

  # A stale cache beats no peers at all: the node still needs to reach the network.
  defp fall_back_to_stale(err) do
    case raw_cache() do
      %{"peers" => [_ | _] = raw} ->
        peers = Enum.map(raw, &decode_peer/1)

        Logger.warning(
          "[YggPF.WebPeers] scrape failed (#{inspect(err)}); falling back to " <>
            "#{length(peers)} stale cached peer(s)"
        )

        {:ok, peers}

      _none ->
        err
    end
  end

  defp cached do
    case raw_cache() do
      %{"fetched_at" => at, "peers" => [_ | _] = raw} when is_integer(at) ->
        age = System.os_time(:millisecond) - at

        case age < Const.web_cache_ttl_ms() do
          true -> {:ok, Enum.map(raw, &decode_peer/1), age}
          false -> :expired
        end

      _other ->
        :miss
    end
  end

  defp raw_cache do
    case TryETS.lookup(@ets, @cache_key) do
      [{@cache_key, %{} = doc}] -> doc
      _absent -> read_cache_file()
    end
  end

  defp put_cache(peers) do
    doc = %{"fetched_at" => System.os_time(:millisecond), "peers" => Enum.map(peers, &encode_peer/1)}
    TryETS.insert(@ets, {@cache_key, doc})
    write_cache_file(doc)
    peers
  end

  defp encode_peer(p), do: %{"uri" => p.uri, "identity" => p.identity}

  defp decode_peer(%{"uri" => uri} = m),
    do: %{
      uri: uri,
      identity: Map.get(m, "identity"),
      source: :web_scrape,
      priority: priority(:web_scrape)
    }

  defp read_cache_file do
    with {:ok, body} <- File.read(@cache_file),
         {:ok, %{} = doc} <- Jason.decode(body) do
      TryETS.insert(@ets, {@cache_key, doc})
      doc
    else
      _unavailable -> %{}
    end
  end

  defp write_cache_file(doc) do
    with :ok <- File.mkdir_p(Path.dirname(@cache_file)),
         {:ok, json} <- Jason.encode(doc),
         :ok <- File.write(@cache_file, json) do
      :ok
    else
      err -> Logger.warning("[YggPF.WebPeers] could not persist peer cache: #{inspect(err)}")
    end
  end

  @doc "Discard the cache, in memory and on disk."
  def clear_cache do
    TryETS.delete(@ets, @cache_key)
    File.rm(@cache_file)
    :ok
  end

  # ------------------------------------------------------------------ #
  # Bootstrap selection                                                 #
  # ------------------------------------------------------------------ #

  @doc """
  Draw `n` peers at random from the full known population.

  Drawing from the whole cached set rather than from a pre-truncated list means a
  restart inside the cache window still yields a different spread of peers.
  """
  @spec bootstrap_set(keyword()) :: {:ok, [peer()]} | {:error, term()}
  def bootstrap_set(opts \\ []) do
    n = Keyword.get(opts, :count, Const.web_bootstrap_peers())

    case all_peers(opts) do
      {:ok, peers} ->
        chosen = peers |> Enum.shuffle() |> Enum.take(n)

        Logger.info(
          "[YggPF.WebPeers] selected #{length(chosen)} of #{length(peers)} peer(s) at random " <>
            "for bootstrap"
        )

        {:ok, chosen}

      err ->
        err
    end
  end

  # ------------------------------------------------------------------ #
  # Scrape                                                              #
  # ------------------------------------------------------------------ #

  @doc """
  Walk the repository and return one peer per distinct node.

  Options: `:region` (`"all"`, the default, or a single directory name),
  `:http`, `:shuffle?`, `:limit`.
  """
  @spec scrape(keyword()) :: {:ok, [peer()]} | {:error, term()}
  def scrape(opts \\ []) do
    http = Keyword.get(opts, :http, &http_get/1)
    root = root_path(Keyword.get(opts, :region, "all"))

    Logger.info("[YggPF.WebPeers] walking #{@repo}#{if root == "", do: "", else: "/" <> root}")

    case walk(root, http, 0, []) do
      {:error, _} = err ->
        err

      [] ->
        {:error, :no_peer_files}

      urls ->
        Logger.info("[YggPF.WebPeers] #{length(urls)} peer file(s) found")

        case fetch_all(urls, http) do
          {:ok, text} -> {:ok, select(text, Keyword.get(opts, :limit, :all), opts)}
          err -> err
        end
    end
  end

  defp root_path(region) when region in [nil, "", "all", :all], do: ""
  defp root_path(region), do: to_string(region)

  # Recursive directory walk. Files are collected only below the root so that
  # top-level README examples are not mistaken for live peers.
  defp walk(_path, _http, depth, acc) when depth > @max_depth, do: acc

  defp walk(path, http, depth, acc) do
    url = if path == "", do: @api, else: "#{@api}/#{path}"

    case http.(url) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, entries} when is_list(entries) ->
            Enum.reduce(entries, acc, &collect_entry(&1, &2, http, depth))

          {:ok, %{"message" => msg}} ->
            {:error, {:github_api, msg}}

          _unexpected ->
            Logger.warning("[YggPF.WebPeers] unexpected listing at #{url}")
            acc
        end

      {:error, reason} ->
        Logger.warning("[YggPF.WebPeers] cannot list #{url}: #{inspect(reason)}")
        acc
    end
  end

  defp collect_entry(_entry, {:error, _} = err, _http, _depth), do: err

  defp collect_entry(%{"type" => "dir", "path" => p}, acc, http, depth),
    do: walk(p, http, depth + 1, acc)

  defp collect_entry(%{"type" => "file", "download_url" => url, "name" => name}, acc, _http, depth)
       when is_binary(url) do
    case depth > 0 and String.ends_with?(name, ".md") do
      true -> [url | acc]
      false -> acc
    end
  end

  defp collect_entry(_other, acc, _http, _depth), do: acc

  defp fetch_all(urls, http) do
    # The shell original concatenated every file before parsing, so the 500-character
    # identity window can span a file boundary. Preserved.
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

  @doc "Extract TCP/TLS peer URIs, preserving order and removing duplicates."
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

  @doc "Validate a peer URI: scheme must be tcp or tls, and the host must be non-empty."
  @spec valid_uri?(String.t()) :: boolean()
  def valid_uri?(uri) when is_binary(uri) do
    case String.split(uri, "://", parts: 2) do
      [scheme, rest] when rest != "" -> scheme in @schemes and host_part(rest) != ""
      _malformed -> false
    end
  end

  def valid_uri?(_other), do: false

  defp host_part(rest) do
    rest |> String.split(["/", "?"], parts: 2) |> List.first() |> to_string()
  end

  @doc """
  Group URIs by Yggdrasil identity, mirroring `parse_ygg_peers.py:31-44`.

  For each URI we inspect the 500 characters of source text starting at its first
  occurrence and take the first Ygg-looking IPv6 address found there. Failing that
  the host acts as the identity, so distinct hosts are never merged.
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

  @doc """
  Parse, group and select. `limit` may be `:all` to keep every distinct node.
  """
  @spec select(String.t(), pos_integer() | :all, keyword()) :: [peer()]
  def select(text, limit \\ @default_limit, opts \\ []) do
    uris = parse_uris(text)
    groups = group_by_identity(text, uris)

    groups =
      case Keyword.get(opts, :shuffle?, true) do
        true -> Enum.shuffle(groups)
        false -> groups
      end

    Logger.info("[YggPF.WebPeers] #{length(uris)} TCP/TLS URIs, #{length(groups)} unique nodes")

    groups
    |> take(limit)
    |> Enum.map(fn {identity, [uri | _rest]} ->
      %{uri: uri, identity: identity, source: :web_scrape, priority: priority(:web_scrape)}
    end)
  end

  defp take(list, :all), do: list
  defp take(list, n) when is_integer(n), do: Enum.take(list, n)

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
  Merge peer sets into the active list, highest priority first.

  Scan-discovered relays replace web-scraped peers for the same identity
  (spec section 37, INV-020). Deduplication is by identity where known, else by URI.
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

    headers = [{~c"user-agent", @user_agent}, {~c"accept", ~c"application/vnd.github+json"}]
    request = {String.to_charlist(url), headers}
    opts = [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()], timeout: 15_000]

    case :httpc.request(:get, request, opts, body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, body}} ->
        {:ok, body}

      {:ok, {{_v, 403, _r}, _h, _b}} ->
        {:error, {:http_status, 403, :likely_github_rate_limit}}

      {:ok, {{_v, status, _r}, _h, _b}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
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
