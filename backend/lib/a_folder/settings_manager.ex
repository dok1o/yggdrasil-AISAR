defmodule GenS.SettingsManager do
  use GenServer
  require Logger
  @type crawl_regime :: :thin | :power
  @data_dir "../data"
  @logs_dir "../data/logs"
  @settings_path "../data/settings.json"
  @defaults %{
    legacy_crawl: false,
    enable_pf: false,
    jsonl_append_tjf: true,
    hide_debug: false,
    enable_ygg: true,
    # ygg_pf web scrape (spec sections 38, 40). Off by default: web-scraped peers are
    # low priority (spec section 36) and SDP scanning is the primary discovery path.
    ygg_web_scrape_peers: false,
    ygg_web_scrape_region: "europe",
    ygg_web_scrape_limit: 20
  }
  def start_link(opts \\ []) do
    file_path = Keyword.get(opts, :file_path, @settings_path)
    GenServer.start_link(__MODULE__, {file_path, @defaults}, name: __MODULE__)
  end
  def defaults(), do: @defaults
  @doc "Retrieve a setting value (supports fallback via module prefix if not registered)"
  def get_setting(key), do: GenServer.call(__MODULE__, {:get, key})
  @doc "Update a setting, save to disk, and apply to KeyStorageSync immediately"
  def update_setting(key, value), do: GenServer.cast(__MODULE__, {:update, key, value})
  @doc "Force reload settings from disk and re-apply to KeyStorageSync"
  def reload(), do: GenServer.cast(__MODULE__, :reload)
  def init({file_path, defaults}) do
    File.mkdir_p!(@data_dir)
    File.mkdir_p!(@logs_dir)
    MagnetSorter.Schema.create_db!()
    KeyStorageSync.set_samples_log(false)
    KeyStorageSync.set_os_rules_atom(OSChkSync.os_rules())
    settings = load_settings(file_path, defaults)
    apply_to_key_storage(settings)
    init_log(settings)
    st = %{file_path: file_path, defaults: defaults, settings: settings}
    {:ok, st}
  end
  def load_settings(file_path, defaults) do
    case JsonHelper.read(file_path) do
      {:ok, settings_map} when is_map(settings_map) ->
        normalize(Map.merge(defaults, settings_map))
      _malformed ->
        if File.exists?(file_path) do
          Logger.warning("[Settings] #{file_path} is not a settings map: defaults, file kept")
          defaults
        else
          init_and_return_defaults(file_path, defaults)
        end
    end
  end
  def handle_call({:get, key}, _from, %{settings: settings}) do
    {:reply, Map.get(settings, key), settings}
  end
  def handle_cast(:reload, st) do
    new_settings = load_and_merge(st.file_path, st.defaults)
    apply_to_key_storage(new_settings)
    Logger.info("[Settings] Successfully reloaded and applied from disk")
    {:noreply, %{st | settings: new_settings}}
  end
  def handle_cast({:update, key, value}, %{settings: settings} = st) do
    new_settings = Map.put(settings, key, value)
    JsonHelper.write(st.file_path, new_settings)
    apply_to_key_storage(new_settings)
    Logger.info("[Settings] Updated #{key}=#{value} and persisted to disk")
    {:noreply, %{st | settings: new_settings}}
  end
  defp init_and_return_defaults(file_path, defaults) do
    JsonHelper.write(file_path, defaults)
    defaults
  end
  defp load_and_merge(settings_map, defaults) do
    defaults
    |> Enum.to_list()
    |> Keyword.new(fn {k, v} -> {k, Map.get(settings_map, k, v)} end)
    |> Map.new()
  end
  defp apply_to_key_storage(%{legacy_crawl: crawl?, enable_pf: pf?} = settings) do
    KeyStorageSync.set_crawl(crawl?)
    KeyStorageSync.set_use_pf(pf?)
    KeyStorageSync.set_use_ygg(normalize(settings).enable_ygg)
    if crawl?, do: GenS.InfohashWorkerPool.enable_crawling()
  end
  defp normalize(settings),
    do: Map.update(settings, :enable_ygg, @defaults.enable_ygg, &ygg_flag/1)
  defp ygg_flag(flag) when is_boolean(flag), do: flag
  defp ygg_flag("true"), do: true
  defp ygg_flag("false"), do: false
  defp ygg_flag(other) do
    Logger.warning(
      "[Settings] enable_ygg=#{inspect(other)} is not a boolean, using #{@defaults.enable_ygg}"
    )
    @defaults.enable_ygg
  end
  defp init_log(%{legacy_crawl: crawl?, enable_pf: pf?} = settings) do
    Logger.info(
      "=== [Backend] Crawling: #{on_off(crawl?)}, PF protocol: #{on_off(pf?)}, " <>
        "Yggdrasil: #{on_off(Map.get(settings, :enable_ygg, @defaults.enable_ygg))} ==="
    )
  end
  defp on_off(flag), do: if(flag, do: "enabled", else: "disabled")
end