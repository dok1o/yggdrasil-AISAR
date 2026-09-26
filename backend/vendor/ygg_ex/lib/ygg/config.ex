defmodule Ygg.Config do
  @moduledoc """
  Node configuration file (`ygg.json`, plain JSON via Jason, no HJSON comments).
  Ports the subset of `NodeConfig` from `reference/yggdrasil-go/src/config/config.go:44-58` that the no-TUN sub-node
  needs, with the same field names: `PrivateKey` (hex, Go `KeyBytes`), `Peers`, `Listen`,
  `AllowedPublicKeys`, `NodeInfo`, `NodeInfoPrivacy`. Own fields: `PrivateKeyFile` (used when
  `PrivateKey` is absent, see `Ygg.Identity.load_or_create/1`), `PeerListFile` (one URI per
  line, blank lines and `#` comments ignored), `PublicPeers` (scraper, `Ygg.PublicPeers`),
  `StatusIntervalSec`, `SendSigReq`. A missing file yields the defaults, like Go's
  `GenerateConfig` merge in `ReadFrom` (config.go:93-121).
  Router fields: `Router` (only `"native"`, the default: the Elixir ironwood port,
  `Ygg.Router.Native`; the Go sidecar router `"ironwood"` was removed and lives only in the
  archive, `"stub"` is internal to tests: programmatic `Ygg.Node.start_link/1` defaults to
  `:stub`), `Routing` (ironwood-layer settings: `DumpIntervalSec`, `RoutingLogFile` JSONL,
  `DumpBloomFull`, `GroupPassword` of the `encrypted` sessions; an old `Sidecar` section is
  read in its place with a warning, its `Path`/`Mode` are ignored), `KeysFile` (text
  file every own key is appended to, `Ygg.Identity.record/3`), `AddressFile` (`<ipv6> <port>
  <public_key_hex>` of this node, `Ygg.AddressFile`), `LogFile` (rotating log file, `Ygg.LogFile`).
  `PrivateKeyFile` holds the 64-hex seed and is created when missing.
  """
  require Logger
  alias Ygg.{Identity, PeerURI}
  @derive {Inspect, except: [:private_key]}
  defstruct private_key: nil,
            private_key_file: "ygg_key.hex",
            peers: [],
            listen: [],
            allowed_public_keys: [],
            node_info: %{},
            node_info_privacy: false,
            peer_list_file: "priv/peers/peer_list_09_21_europe.txt",
            public_peers: %{
              enabled: false,
              count: 10,
              cache_file: "public_peers.cache",
              cache_ttl_hours: 24,
              regions: nil
            },
            status_interval_sec: 10,
            send_sig_req: true,
            router: :native,
            routing: %{
              dump_interval_sec: 5,
              routing_log_file: "log/routing.jsonl",
              password: "",
              bloom_full: false
            },
            keys_file: "keys_collected.txt",
            address_file: "ygg_address.txt",
            log_file: "log/ygg.log"
  @type t :: %__MODULE__{}
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, json} ->
        with {:ok, map} <- Jason.decode(json), {:ok, cfg} <- from_map(map) do
          {:ok, env_overrides(cfg)}
        end
      {:error, :enoent} ->
        Logger.info("Config #{path} not found, using defaults")
        {:ok, env_overrides(%__MODULE__{})}
      {:error, reason} ->
        {:error, {:read_config, path, reason}}
    end
  end
  @doc "`YGG_PEER_LIST=<file>` overrides `PeerListFile` (handy for live runs)."
  @spec env_overrides(t()) :: t()
  def env_overrides(%__MODULE__{} = cfg) do
    case System.get_env("YGG_PEER_LIST") do
      nil -> cfg
      file -> %{cfg | peer_list_file: file}
    end
  end
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    pp = Map.get(map, "PublicPeers", %{})
    rt = routing_section(map)
    cfg = %__MODULE__{
      private_key: Map.get(map, "PrivateKey"),
      private_key_file: Map.get(map, "PrivateKeyFile", "ygg_key.hex"),
      peers: Map.get(map, "Peers", []),
      listen: Map.get(map, "Listen", []),
      allowed_public_keys: Map.get(map, "AllowedPublicKeys", []),
      node_info: Map.get(map, "NodeInfo") || %{},
      node_info_privacy: Map.get(map, "NodeInfoPrivacy", false),
      peer_list_file: Map.get(map, "PeerListFile", "priv/peers/peer_list_09_21_europe.txt"),
      public_peers: %{
        enabled: Map.get(pp, "Enabled", false),
        count: Map.get(pp, "Count", 10),
        cache_file: Map.get(pp, "CacheFile", "public_peers.cache"),
        cache_ttl_hours: Map.get(pp, "CacheTTLHours", 24),
        regions: Map.get(pp, "Regions")
      },
      status_interval_sec: Map.get(map, "StatusIntervalSec", 10),
      send_sig_req: Map.get(map, "SendSigReq", true),
      router: router(Map.get(map, "Router", "native")),
      routing: %{
        dump_interval_sec: Map.get(rt, "DumpIntervalSec", 5),
        routing_log_file: Map.get(rt, "RoutingLogFile", "log/routing.jsonl"),
        password: Map.get(rt, "GroupPassword", ""),
        bloom_full: Map.get(rt, "DumpBloomFull", false)
      },
      keys_file: Map.get(map, "KeysFile", "keys_collected.txt"),
      address_file: Map.get(map, "AddressFile", "ygg_address.txt"),
      log_file: Map.get(map, "LogFile", "log/ygg.log")
    }
    with :ok <- validate(cfg), do: {:ok, cfg}
  end
  defp router("native"), do: :native
  defp router(other), do: {:invalid, other}
  defp routing_section(%{"Routing" => %{} = rt}), do: rt
  defp routing_section(%{"Sidecar" => %{} = sc}) do
    Logger.warning(
      "Config: \"Sidecar\" is obsolete (sidecar router removed), read as \"Routing\""
    )
    sc
  end
  defp routing_section(_map), do: %{}
  defp validate(%{peers: p, listen: l, allowed_public_keys: a} = cfg)
       when is_list(p) and is_list(l) and is_list(a) do
    bad_key =
      Enum.find(
        a,
        &(not match?({:ok, <<_::binary-size(32)>>}, Base.decode16(&1, case: :mixed)))
      )
    cond do
      bad_key != nil -> {:error, {:invalid_allowed_public_key, bad_key}}
      true -> validate_router(cfg)
    end
  end
  defp validate(_cfg), do: {:error, :invalid_config}
  defp validate_router(%{router: {:invalid, r}}), do: {:error, {:invalid_router, r}}
  defp validate_router(%{routing: %{dump_interval_sec: s}}) when not is_number(s) or s < 0,
    do: {:error, {:invalid_dump_interval, s}}
  defp validate_router(_cfg), do: :ok
  @doc "Identity from `PrivateKey`, else from the key file (created when missing)."
  @spec identity(t()) :: {:ok, Identity.t(), :config | :loaded | :created} | {:error, term()}
  def identity(%__MODULE__{private_key: hex}) when is_binary(hex) and hex != "" do
    with {:ok, id} <- Identity.from_hex(hex), do: {:ok, id, :config}
  end
  def identity(%__MODULE__{private_key_file: path}), do: Identity.load_or_create(path)
  @doc "Peers from the config plus the peer list file, first occurrence wins per info URI."
  @spec peer_uris(t()) :: [String.t()]
  def peer_uris(%__MODULE__{peers: peers, peer_list_file: file}) do
    (peers ++ read_peer_file(file))
    |> Enum.reduce({[], MapSet.new()}, fn uri, {acc, seen} ->
      case PeerURI.parse(uri) do
        {:ok, %{info_uri: info}} ->
          if MapSet.member?(seen, info),
            do: {acc, seen},
            else: {[uri | acc], MapSet.put(seen, info)}
        {:error, reason} ->
          Logger.warning("Ignoring peer #{inspect(uri)}: #{inspect(reason)}")
          {acc, seen}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
  @spec read_peer_file(Path.t() | nil) :: [String.t()]
  def read_peer_file(nil), do: []
  def read_peer_file(""), do: []
  def read_peer_file(path) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> String.split(["\n", "\r\n"], trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      {:error, reason} ->
        Logger.warning("Peer list #{path} not readable: #{inspect(reason)}")
        []
    end
  end
  @doc """
  Resolves the relative file paths of the config (`PrivateKeyFile`, `PeerListFile`,
  `KeysFile`, `AddressFile`, `LogFile`, `Routing.RoutingLogFile`, `PublicPeers.CacheFile`)
  against `base_dir` instead of the current directory; absolute paths and empty values
  (file disabled) are kept. A relative `PeerListFile` missing under `base_dir` falls back
  to the list of the same name bundled with ygg_ex (`bundled_peer_list/1`). Used by
  `Ygg.Embedded`; the standalone node keeps CWD-relative paths.
  """
  @spec resolve_paths(t(), Path.t()) :: t()
  def resolve_paths(%__MODULE__{} = cfg, base_dir) do
    base = Path.expand(base_dir)
    at = &resolve(&1, base)
    %{
      cfg
      | private_key_file: at.(cfg.private_key_file),
        peer_list_file: resolve_peer_list(cfg.peer_list_file, base),
        keys_file: at.(cfg.keys_file),
        address_file: at.(cfg.address_file),
        log_file: at.(cfg.log_file),
        routing: Map.update(cfg.routing, :routing_log_file, nil, at),
        public_peers: Map.update(cfg.public_peers, :cache_file, nil, at)
    }
  end
  @doc "Path of a peer list bundled with ygg_ex (`priv/peers/<basename>`)."
  @spec bundled_peer_list(Path.t()) :: Path.t()
  def bundled_peer_list(name),
    do: Application.app_dir(:ygg_ex, Path.join("priv/peers", Path.basename(name)))
  defp resolve(path, base) when is_binary(path) and path != "", do: Path.expand(path, base)
  defp resolve(path, _base), do: path
  defp resolve_peer_list(path, base) when is_binary(path) and path != "" do
    full = Path.expand(path, base)
    cond do
      Path.type(path) == :absolute or File.exists?(full) -> full
      File.regular?(bundled_peer_list(path)) -> bundled_peer_list(path)
      true -> full
    end
  end
  defp resolve_peer_list(path, _base), do: path
  @doc "Options for `Ygg.Node.start_link/1`."
  @spec node_opts(t(), Identity.t()) :: keyword()
  def node_opts(%__MODULE__{} = cfg, %Identity{} = id) do
    [
      identity: id,
      peers: peer_uris(cfg),
      listen: cfg.listen,
      allowed_keys: Enum.map(cfg.allowed_public_keys, &Base.decode16!(&1, case: :mixed)),
      send_sig_req: cfg.send_sig_req,
      status_interval_ms: cfg.status_interval_sec * 1_000,
      node_info: cfg.node_info,
      node_info_privacy: cfg.node_info_privacy,
      public_peers: cfg.public_peers,
      router: cfg.router,
      routing: routing_opts(cfg.routing),
      address_file: cfg.address_file
    ]
  end
  @doc """
  `Routing` options as `Ygg.Router.Native` and `Ygg.Sessions` read them from `ctx.routing`
  (`dump_interval_ms`, `routing_log_file`, `bloom_full`, `password`).
  """
  @spec routing_opts(map()) :: map()
  def routing_opts(%{} = rt) do
    %{
      dump_interval_ms: round(Map.get(rt, :dump_interval_sec, 5) * 1_000),
      routing_log_file: Map.get(rt, :routing_log_file, "log/routing.jsonl"),
      password: Map.get(rt, :password, ""),
      bloom_full: Map.get(rt, :bloom_full, false)
    }
  end
end