defmodule S04CatalogTx.MixProject do
  use Mix.Project

  def project do
    [
      app: :s04_catalog_tx,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {S04CatalogTx.Application, []}
    ]
  end

  # test/support holds the spike's Ash resources / domain / repo fixtures
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},
      {:spark, "~> 2.0"}
    ]
  end
end
