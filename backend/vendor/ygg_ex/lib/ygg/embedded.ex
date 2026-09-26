defmodule Ygg.Embedded do
  @moduledoc """
  Runs an `Ygg.Node` under the supervisor of another OTP application. The host sets
  `config :ygg_ex, autostart: false` (then `Ygg.Application` starts only `Ygg.Registry`)
  and adds a child:
      children = [
        {Ygg.Embedded, config_file: "data/ygg/ygg.json", base_dir: "data/ygg",
                       log_file: "data/logs/ygg.log"}
      ]
  `start_link/1` does what the standalone bootstrap does (`Ygg.Application`): config ->
  log file -> identity (key file created when missing, mode 0600) -> key and address logged
  -> key recorded in `KeysFile` -> `Ygg.Node.start_link/1`, but any config or identity
  error is logged and returned as `{:error, reason}` instead of leaving the node out.
  Options:
  - `:base_dir`: the relative paths of the config (`PrivateKeyFile`, `KeysFile`,
    `AddressFile`, `LogFile`, `PeerListFile`, `Routing.RoutingLogFile`,
    `PublicPeers.CacheFile`) are resolved against it (`Ygg.Config.resolve_paths/2`); created
    with mode 0700 when missing, set to 0700 when it exists with other permissions (it holds
    the key, so give it a directory of its own). Default: the directory of `:config_file`.
  - `:config_file`: path of the `ygg.json` (relative to the current directory); written with
    `default_config/0` (pretty JSON, for the user to edit) when missing, then read. Default
    `<base_dir>/ygg.json`; `false` reads no file (defaults plus `:overrides`). Keys missing
    in the file take the values of `default_config/0`.
  - `:overrides`: map with `ygg.json` keys merged over the file (sections
    `Routing`/`PublicPeers` key by key), e.g. for tests.
  - `:log_file`: replaces `LogFile` of the config (relative to the current directory;
    `nil` or `""` writes no file).
  - `:log_filter`: `:ygg` (default: only lines logged by `Ygg.*` modules go to the file,
    see `Ygg.LogFile`) or `:all`.
  - `:log_handler_id`: logger handler id of the file (default `Ygg.LogFile.handler_id/0`).
    The handler stays attached when the node stops; `Ygg.LogFile.detach/1` removes it.
  - `:name`: node id and registered supervisor name (default `Ygg.Node`, the node the
    `Ygg` API functions address without an explicit node argument).
  A relative `PeerListFile` that does not exist under `base_dir` is taken from the lists
  bundled with ygg_ex (`Application.app_dir(:ygg_ex, "priv/peers/<basename>")`), so the
  default file needs no copy of the list. `YGG_PEER_LIST` is not consulted here.
  Supervision: `Ygg.Node` is `one_for_all` with `max_restarts: 0`, so any crash inside the
  node terminates it and the restart is up to the host. Put `Ygg.Embedded` under a
  dedicated supervisor with its own restart budget (e.g. `one_for_one`, `max_restarts: 5,
  max_seconds: 60`) placed as a `:temporary` or `:transient` child of the host tree, so a
  series of node crashes shuts Yggdrasil down without taking the host application with it.
  """
  import Bitwise, only: [&&&: 2]
  require Logger
  alias Ygg.{Address, Config, Identity, LogFile, Node}
  @peer_list "peer_list_09_22_europe.txt"
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :name, Node)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
  @doc "Loads (or writes) the config, prepares the identity and starts the node supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    with {:ok, cfg} <- load(opts),
         {:ok, node_opts} <- prepare(cfg, Keyword.put_new(opts, :log_filter, :ygg)) do
      Node.start_link(node_opts)
    else
      {:error, reason} = err ->
        Logger.error("Cannot start Yggdrasil node: #{inspect(reason)}")
        err
    end
  end
  @doc """
  The config for `start_link/1` options: creates `base_dir`, writes the default config file
  when missing, reads it, applies `:overrides`, resolves paths against `base_dir` and
  applies `:log_file`.
  """
  @spec load(keyword()) :: {:ok, Config.t()} | {:error, term()}
  def load(opts) do
    with {:ok, base, file} <- locations(opts),
         :ok <- ensure_dir(base),
         {:ok, map} <- read_map(file),
         {:ok, cfg} <- Config.from_map(merge(map, Keyword.get(opts, :overrides, %{}))) do
      cfg = Config.resolve_paths(cfg, base)
      case Keyword.fetch(opts, :log_file) do
        {:ok, path} when is_binary(path) and path != "" -> {:ok, %{cfg | log_file: path}}
        {:ok, _none} -> {:ok, %{cfg | log_file: nil}}
        :error -> {:ok, cfg}
      end
    end
  end
  @doc """
  From a loaded config to `Ygg.Node.start_link/1` options, shared with the standalone
  bootstrap in `Ygg.Application`: attaches the log file (a file that cannot be opened is
  only a warning), loads or creates the identity, logs key and address, records the key in
  `KeysFile`. Options: `:name` (default `Ygg.Node`), `:log_filter` (default `:all`),
  `:log_handler_id`.
  """
  @spec prepare(Config.t(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def prepare(%Config{} = cfg, opts \\ []) do
    attach_log(cfg.log_file, opts)
    with {:ok, id, how} <- Config.identity(cfg) do
      Logger.info("Key #{how}: #{Identity.pub_hex(id)}")
      Logger.info("Address #{Address.format(id.address)}, subnet #{Address.format(id.subnet)}")
      record_key(cfg.keys_file, id, how)
      {:ok, [{:name, Keyword.get(opts, :name, Node)} | Config.node_opts(cfg, id)]}
    end
  end
  @doc """
  Content written to a missing `:config_file`, in the `ygg.json.example` layout: no
  listeners, no direct peers, the bundled European peer list, status line every 60 s,
  routing dump every 60 s, all files relative to `base_dir`. No `PrivateKey`: the key lives
  in `PrivateKeyFile`.
  """
  @spec default_config() :: Jason.OrderedObject.t()
  def default_config do
    Jason.OrderedObject.new([
      {"PrivateKeyFile", "ygg_key.hex"},
      {"Peers", []},
      {"PeerListFile", @peer_list},
      {"Listen", []},
      {"AllowedPublicKeys", []},
      {"NodeInfo", %{}},
      {"NodeInfoPrivacy", false},
      {"PublicPeers",
       Jason.OrderedObject.new([
         {"Enabled", false},
         {"Count", 10},
         {"CacheFile", "public_peers.cache"},
         {"CacheTTLHours", 24}
       ])},
      {"StatusIntervalSec", 60},
      {"SendSigReq", true},
      {"Router", "native"},
      {"Routing",
       Jason.OrderedObject.new([
         {"DumpIntervalSec", 60},
         {"RoutingLogFile", "routing.jsonl"},
         {"GroupPassword", ""},
         {"DumpBloomFull", false}
       ])},
      {"KeysFile", "keys_collected.txt"},
      {"AddressFile", "ygg_address.txt"},
      {"LogFile", "ygg.log"}
    ])
  end
  defp locations(opts) do
    base = Keyword.get(opts, :base_dir)
    file = Keyword.get(opts, :config_file)
    cond do
      file == false and base != nil -> {:ok, Path.expand(base), false}
      file not in [nil, false] -> {:ok, Path.expand(base || Path.dirname(file)), file}
      base != nil -> {:ok, Path.expand(base), Path.join(base, "ygg.json")}
      true -> {:error, :no_base_dir}
    end
  end
  defp ensure_dir(dir) do
    case File.stat(dir) do
      {:ok, %{type: :directory, mode: mode}} when (mode &&& 0o777) == 0o700 ->
        :ok
      {:ok, %{type: :directory}} ->
        with {:error, reason} <- File.chmod(dir, 0o700) do
          Logger.warning("Cannot set mode 0700 on #{dir}: #{inspect(reason)}")
        end
        :ok
      _ ->
        with :ok <- File.mkdir_p(dir), :ok <- File.chmod(dir, 0o700) do
          :ok
        else
          {:error, reason} -> {:error, {:base_dir, dir, reason}}
        end
    end
  end
  defp read_map(false), do: {:ok, defaults()}
  defp read_map(file) do
    with :ok <- write_default(file),
         {:ok, json} <- read(file) do
      case Jason.decode(json) do
        {:ok, %{} = map} -> {:ok, merge(defaults(), map)}
        {:ok, other} -> {:error, {:invalid_config, file, other}}
        {:error, reason} -> {:error, {:invalid_config, file, Exception.message(reason)}}
      end
    end
  end
  defp read(file) do
    case File.read(file) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:read_config, file, reason}}
    end
  end
  defp write_default(file) do
    if File.exists?(file) do
      :ok
    else
      json = Jason.encode!(default_config(), pretty: true) <> "\n"
      with :ok <- File.mkdir_p(Path.dirname(Path.expand(file))),
           :ok <- File.write(file, json) do
        Logger.info("Config #{Path.expand(file)} created with defaults")
      else
        {:error, reason} -> {:error, {:write_config, file, reason}}
      end
    end
  end
  defp merge(base, over) do
    Map.merge(base, over, fn
      _k, %{} = a, %{} = b -> Map.merge(a, b)
      _k, _a, b -> b
    end)
  end
  defp defaults do
    Map.new(default_config().values, fn
      {k, %Jason.OrderedObject{values: v}} -> {k, Map.new(v)}
      kv -> kv
    end)
  end
  defp attach_log(path, opts) do
    log_opts = [
      id: Keyword.get(opts, :log_handler_id, LogFile.handler_id()),
      filter: Keyword.get(opts, :log_filter, :all)
    ]
    case LogFile.attach(path, log_opts) do
      :ok -> if path not in [nil, ""], do: Logger.info("Log file: #{Path.expand(path)}")
      {:error, reason} -> Logger.warning("Cannot open log file #{path}: #{inspect(reason)}")
    end
  end
  defp record_key(path, id, how) do
    case Identity.record(path, id, how) do
      :ok -> Logger.info("Key recorded in #{path}")
      :exists -> :ok
      {:error, reason} -> Logger.warning("Cannot record key in #{path}: #{inspect(reason)}")
    end
  end
end