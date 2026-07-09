defmodule SamenWeb.MixProject do
  use Mix.Project

  # samen_web — the FRAMEWORK UI library (ADR-009). It promotes the inherited-80%
  # product UI (the component kit + the CRM/Billing/Support LiveViews + the two-plane
  # masking) out of the driftwood-local `driftwood_web` and into a shared path-dep lib
  # that EVERY vertical inherits by mounting, not by copying 11 LiveViews.
  #
  # It depends on phoenix_live_view/phoenix_html/phoenix (the web deps) + samen_core
  # (the pure kernel, path dep). samen_core gains NO web dep — the web dep lives HERE,
  # so the kernel's 842-test suite + verifier gate stay green by construction.
  #
  # In :test it ships its OWN test-support host (Samen.WebTest.{Repo,Crm,Billing,Support})
  # so the render tests exercise real materialized scope resources with NO dependency on
  # any vertical — the two-plane masking guarantee is proven by a framework-local test.
  def project do
    [
      app: :samen_web,
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
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The pure kernel — %Masked{}, Samen.Scope, Samen.Api.PiiResolution, the scope
      # blueprints. No web dep flows back into it.
      {:samen_core, path: "../samen_core"},
      # Web deps — the reason this lib exists separately from samen_core.
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      # AshPhoenix.Form — the A2 form-primitive contract (ADR-016 §2): `simple_form/1`
      # is `AshPhoenix.Form`-backed (create/edit + inline validation errors).
      {:ash_phoenix, "~> 2.3"},
      {:jason, "~> 1.4"},
      # Test-support host deps (materialize the scope blueprints against a scratch repo):
      {:ash, "== 3.29.3"},
      {:ash_postgres, "== 2.10.0"},
      {:simple_sat, "~> 0.1"}
    ]
  end

  defp aliases do
    [
      # `mix test` sets up the scratch samen_web_test DB (drop/create/migrate) then runs.
      test: ["samen_web.test_setup", "test"]
    ]
  end
end
