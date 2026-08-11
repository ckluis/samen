defmodule PawChart.MixProject do
  use Mix.Project

  # PawChart — the Phase-6 SECOND-VERTICAL THIN SLICE (T6.2 → T6.3), the reuse-
  # measurement probe. A vet-clinic SaaS on the Samen substrate:
  #
  #   * MOUNTS the samen_core Billing scope AS-IS — plain subscriptions, NO reshape.
  #   * MOUNTS the samen_core CRM scope AS-IS — clinic contacts, referring vets, vendors.
  #   * MOUNTS the samen_core Support scope AS-IS — clinics file tickets with the platform.
  #   * MOUNTS the samen_web CRM/Billing/Support LiveView modules via samen_module_routes
  #     (ADR-009) — the inherited-80% product UI at framework level.
  #   * AUTHORS two vertical resources: Patient + Pet (the doc's "two PII subjects").
  #   * DEFINES a Tier-2 VaccineLot custom object (tnt_object).
  #   * RUNS the FULL samen_core verifier gate in its own pawchart/ci.sh.
  #
  # REUSE MEASUREMENT: the mount line-count (see docs/mount-reuse-report.md) quantifies
  # inherited-vs-authored: ~3 lines to inherit all three product modules in the router.
  def project do
    [
      app: :pawchart,
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
      mod: {PawChart.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:samen_core, path: "../samen_core"},
      # ADR-009 — the framework UI library. PawChart mounts the inherited CRM/Billing/
      # Support LiveViews from samen_web (3 lines in the router), so the entire
      # inherited-80% product UI is framework-level, not per-vertical.
      {:samen_web, path: "../samen_web"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_live_view, "~> 1.2.9"},
      {:phoenix_html, "~> 4.1"},
      # Bandit: the HTTP adapter behind PawChartWeb.Endpoint.
      {:bandit, "~> 1.12.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:stream_data, "== 1.3.0"},
      # simple_sat: the Ash policy authorizer's pure-Elixir SAT solver.
      {:simple_sat, "~> 0.1"}
    ]
  end

  defp aliases do
    []
  end
end
