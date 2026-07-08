defmodule PawChart.MixProject do
  use Mix.Project

  # PawChart — the Phase-6 SECOND-VERTICAL THIN SLICE (T6.2), the reuse-measurement
  # probe. A vet-clinic SaaS on the Samen substrate, built as the vision doc's EASY
  # ADDITIVE case (contrast with Driftwood's bounded-context reshape):
  #
  #   * MOUNTS the samen_core Billing scope AS-IS — plain subscriptions, NO reshape
  #     (the additive contrast to Driftwood's settlement-netting reshape).
  #   * AUTHORS two vertical resources: Patient (the human owner, composes CorePerson —
  #     PII vault-routed) + Pet (the animal record; pii_pet_microchip scalar vault +
  #     owner FK). The doc's "two PII subjects, one relationship" shape.
  #   * DEFINES a Tier-2 VaccineLot custom object clinics author themselves (tnt_object).
  #   * RUNS the FULL samen_core verifier gate in its own pawchart/ci.sh.
  #
  # The point of this app is MEASUREMENT: docs/reuse-measurement.md quantifies
  # inherited-vs-authored to validate (or honestly falsify) "build the 20%, inherit
  # the 80%."
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
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.3"},
      # simple_sat: the Ash policy authorizer's pure-Elixir SAT solver. Needed by the
      # mounted Billing scope's OrgScope policies + the Patient/Pet OrgScope policies.
      {:simple_sat, "~> 0.1"}
    ]
  end

  defp aliases do
    []
  end
end
