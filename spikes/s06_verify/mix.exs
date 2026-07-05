defmodule S06Verify.MixProject do
  use Mix.Project

  def project do
    [
      app: :s06_verify,
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
      mod: {S06Verify.Application, []}
    ]
  end

  # test/support holds fixtures: Ash resources, domain, repo
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
