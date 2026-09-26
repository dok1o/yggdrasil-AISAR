import Config

config :logger, :console,
  format: "$time [$level] $message\n",
  metadata: []

config :logger, level: :info

# The supervision tree only brings up the network stack when this is true.
# Tests start the pieces they need by hand.
config :ygg_ex, autostart: config_env() != :test
config :ygg_ex, config_file: "ygg.json"

if config_env() == :test do
  config :logger, level: :warning
end
