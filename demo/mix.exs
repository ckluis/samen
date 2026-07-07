defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
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
      mod: {Demo.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:samen_core, path: "../samen_core"},
      # Phoenix + LiveView for the HEEx %Masked{} rendering proof (T1.9 acceptance)
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      # Stream-data for property tests (T1.9 acceptance)
      {:stream_data, "~> 1.3"},
      # simple_sat: Ash policy authorizer's SAT solver (pure Elixir; no NIF). Needed
      # by the mounted Identity scope's org-scope + RBAC policies (T3.1).
      {:simple_sat, "~> 0.1"},
      # AshJsonApi: the public /api/v1 surface (T3.11; plan OD-6 — AshJsonApi ONLY).
      # Field exposure is opt-in via the `json_api` DSL (allowlist serialization);
      # the same Ash policy stack (org-scope + RBAC + reveal-grant) gates the API.
      {:ash_json_api, "~> 1.7"}
    ]
  end

  defp aliases do
    []
  end
end
