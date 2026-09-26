defmodule MagnetSorter.MixProject do
  use Mix.Project

  def project do
    [
      app: :magnet_sorter,
      version: "0.69.0",
      elixir: "~> 1.19.5",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Tests must never start the application (it starts DHT networking).
  defp aliases, do: [test: "test --no-start"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {MagnetSorter.Application, []},
      extra_applications: [:logger, :jason, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  # defp deps do
  #   # Elixir 1.19
  #   [
  #     {:jason, "1.4.5"},
  #     # Ecto adapter for SQLite
  #     {:ecto_sqlite3, "0.24.0"},
  #     # Ecto’s SQL features & migrations
  #     {:ecto_sql, "3.14.0"}
  #     # Native SQLite3 driver used by adapter
  #     # {:exqlite, "0.36.0"}
  #     # {:poolboy, "~> 1.5.2"}
  #     # {:dep_from_hexpm, "~> 0.3.0"},
  #     # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
  #   ]
  # end

  defp deps do
    # Elixir 1.19.5, manually selected, no second-order
    [
      {:jason, "1.4.5"},

      # SQLite
      {:db_connection, "2.9.0"},
      {:ecto_sqlite3, "0.24.0"},
      {:ecto_sql, "3.14.0"},
      {:ecto, "3.14.0"},
      {:exqlite, "0.41.0"},

      # SQL tool deps
      {:decimal, "3.1.1"},
      {:telemetry, "1.3.0"},

      # exqlite build dependencies
      {:cc_precompiler, "0.1.11", runtime: false},
      {:elixir_make, "0.10.0", runtime: false},

      # Yggdrasil node (stage 3), vendored from ygg_port: see vendor/ygg_ex/VENDORED.md
      {:ygg_ex, path: "vendor/ygg_ex"}
    ]
  end
end
