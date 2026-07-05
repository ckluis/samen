defmodule S03Fragments.MixProject do
  use Mix.Project

  def project do
    [
      app: :s03_fragments,
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
      mod: {S03Fragments.Application, []}
    ]
  end

  # test/support holds the spike's fragment, composed resources, domain, repo.
  # dev also needs them so `mix ash.codegen` can introspect the resources to
  # generate the migration used by the DDL/no-INHERITS assertions.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},
      {:spark, "~> 2.0"}
    ]
  end
end
