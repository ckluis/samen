defmodule Driftwood.MixProject do
  use Mix.Project

  # Driftwood — the Phase-5 reference vertical (freight brokerage) on the Samen
  # substrate. It mounts the samen_core scopes exactly as demo/ does (path dep),
  # composes vertical resources (Driver / Settlement / DispatchEvent), lays a
  # Driftwood.Context (Carrier/Shipper/Load aliases + the settlement reshape), and
  # runs the FULL verifier gate in its own driftwood/ci.sh.
  def project do
    [
      app: :driftwood,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Driftwood.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:samen_core, path: "../samen_core"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:stream_data, "~> 1.3"},
      {:simple_sat, "~> 0.1"},
      {:ash_json_api, "~> 1.7"}
    ]
  end

  defp aliases do
    []
  end
end
