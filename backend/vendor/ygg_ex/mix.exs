defmodule YggEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :ygg_ex,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :inets, :public_key],
      mod: {Ygg.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end
end
