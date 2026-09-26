import Config

if config_env() != :test do
  config :ygg_ex, config_file: System.get_env("YGG_CONFIG", "ygg.json")
end
