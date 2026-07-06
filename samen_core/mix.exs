defmodule SamenCore.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :samen_core,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Protocol consolidation OFF in :test only. Property fixtures (e.g.
      # abbrev_property_test.exs) recompile modules at runtime via
      # Code.compile_string/1; each recompile re-derives Inspect for the fixture
      # module, which — once protocols are consolidated — emits a "has no effect"
      # warning that `mix test --warnings-as-errors` treats as an error. Disabling
      # consolidation in test (the standard Elixir remedy for runtime-recompiled
      # modules) removes the false failure without affecting dev/prod, where
      # protocols stay consolidated. Pre-existing condition surfaced by T1.6's
      # --warnings-as-errors gate.
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      # test/pii_reads_corpus/ holds the C3 `pii_reads` verifier corpus (T1.8b):
      # `.ex` files with INTENTIONAL PII leaks that the walker reads as TEXT and
      # must never be compiled or loaded as tests. Elixir 1.20 warns about any
      # file under test/ that neither matches `:test_load_filters` (*_test.exs)
      # nor is ignored — and `mix test --warnings-as-errors` treats that warning
      # as a failure. Ignore the corpus dir so the corpus is text-only fixtures.
      test_ignore_filters: [
        &String.starts_with?(&1, "test/pii_reads_corpus/"),
        # T2.4: scratch migration fixtures for the down/0 CI check and the live
        # carve-out test. Real migration `.exs` files loaded by Ecto.Migrator against
        # a throwaway DB — not ExUnit files — so not treated as tests.
        &String.starts_with?(&1, "test/fixtures/")
      ],
      deps: deps(),
      aliases: aliases(),
      description: "Samen foundry kernel: self-qualifying storage, machine catalog, PII vault.",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SamenCore.Application, []}
    ]
  end

  # test/support holds the kernel's fixture resources, domain, and repo. dev also
  # needs them so `mix ash.codegen` can introspect resources to generate the
  # migrations used by the DDL / no-INHERITS assertions.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Versions pinned in spikes/s00_smoke/VERSIONS.md (Elixir 1.20.2 / OTP 29).
  defp deps do
    [
      {:ash, "== 3.29.3"},
      {:ash_postgres, "== 2.10.0"},
      {:spark, "== 2.7.2"},
      {:ecto_sql, "== 3.14.0"},
      {:postgrex, "== 0.22.2"},
      {:jason, "~> 1.4"},
      {:stream_data, "== 1.3.0"},
      # Oban: durable jobs on the same Postgres. T1.6 enqueues the reveal-grant
      # auto-revoke job IN THE SAME TRANSACTION that writes the grant (same-tx
      # enqueue), so a grant insert that rolls back leaves no orphan job. Pinned
      # (T2.1 will layer AshOban conventions on top of this base Oban).
      {:oban, "== 2.23.0"},
      # telemetry_metrics: the standard definition structs for bounded-cardinality
      # metrics (T2.8). Provides Telemetry.Metrics.counter/2, distribution/2, etc.
      # Host apps wire these definitions to a reporter (e.g. TelemetryMetricsPrometheus).
      {:telemetry_metrics, "~> 1.1"},
      # phoenix_html provides Phoenix.HTML.Safe — %Masked{} implements it so a
      # HEEx `<%= @person.email %>` renders "••••" and never raises/leaks
      # (Gate-0 fix task #1, T1.5 acceptance clause (a)). Runtime dep: host apps
      # that render masked values in HEEx need the protocol present.
      {:phoenix_html, "~> 4.1"},
      # OTel tracing (T2.6): opentelemetry_api is the compile-time API surface;
      # opentelemetry is the SDK (span processor, exporter, BEAM propagation).
      # opentelemetry_ecto attaches to Ecto telemetry events — REQUIRED config:
      #   OpentelemetryEcto.setup([:my_app, :repo], db_statement: :disabled)
      # The :disabled flag suppresses SQL text + bind params from every span so
      # no pii_ token ever serializes into db.statement (doc §runs 4a).
      # opentelemetry_process_propagator carries span context across Process.spawn
      # and Task boundaries (not strictly required for Oban since we propagate via
      # job meta, but present for completeness on the BEAM process boundary).
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_ecto, "~> 1.2"}
    ]
  end

  defp aliases do
    # test/test_helper.exs owns the full Repo lifecycle (storage_down + storage_up
    # + migrate) so the schema always matches the generated migrations. We do NOT
    # add ecto.create/migrate here — doing so double-migrates and races the helper.
    []
  end

  defp package do
    [
      name: "samen_core",
      files: ~w(lib priv mix.exs README.md),
      licenses: ["Proprietary"]
    ]
  end
end
