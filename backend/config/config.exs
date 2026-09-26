import Config

config :magnet_sorter, MagnetSorter.Repo,
  database: "../data/magnet_sorter.db",
  pool_size: 8,
  journal_mode: :wal,
  cache_size: -64000,
  busy_timeout: 5000,
  log: false

# The node is started by Spv.YggSup (files in ../data/ygg), never by the :ygg_ex application.
config :ygg_ex, autostart: false

config :logger, :console,
  format: "[$level] $message\n",
  metadata: [],
  truncate: :infinity
