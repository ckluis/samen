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
      package: package(),
      # ExDoc — moduledoc coverage is ~100%; `mix docs` emits HTML API docs into `doc/`
      # (gitignored, dev-only, never committed). `--warnings-as-errors` compile / CI are
      # unaffected: ex_doc is `only: :dev, runtime: false`.
      name: "samen_core",
      source_url: "https://github.com/ckluis/samen",
      docs: docs()
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
      {:opentelemetry_ecto, "~> 1.2"},
      # simple_sat: pure-Elixir SAT solver Ash's policy authorizer requires to solve
      # policy scenarios (T3.1 Identity scope policies: org-scope + RBAC). Ash lists
      # it as an OPTIONAL dep (picosat_elixir or simple_sat); we choose simple_sat to
      # avoid a NIF/C toolchain requirement in this environment. No AWS/Neon here —
      # a pure-Elixir solver keeps the policy layer self-contained and CI-portable.
      {:simple_sat, "~> 0.1"},
      # ash_money (ADR-037 §5.2 ADOPT; ADR-036 D1): Samen.Type.Money wraps
      # AshMoney.Types.Money — samen owns the catalog/type-menu NAME, the package
      # owns currency arithmetic/rounding/SQL-aggregation + the Postgres composite
      # `money_with_currency` extension (AshMoney.AshPostgresExtension). ex_money is
      # the underlying %Money{} value/currency library; ex_money_sql provides the
      # Ecto/Postgrex type + SQL operators the extension installs.
      {:ash_money, "~> 0.2.6"},
      {:ex_money, "~> 6.0"},
      {:ex_money_sql, "~> 2.0"},
      # ash_archival (ADR-037 §5.3 ADOPT; ADR-040 §5 E6; dep-add owned by T36 per
      # ADR-037 §7.4): the E6 soft-delete substrate is implemented ON this extension —
      # `archived_at` (utc_datetime_usec, NULL = live), the preparation-variant default
      # read filter (`is_nil(archived_at)`, NOT base_filter — restore is a hard E6
      # requirement), the soft-destroy rewrite, `archive_related` cascade, and
      # `exclude_destroy_actions` keeping the terminal hard-delete/crypto-shred path.
      # `use Samen.Resource, archivable: true` is the thin Samen sugar over it (mirrors
      # the ash_money §5.2 adoption pattern). Preparation variant per ADR-037 §5.3.
      {:ash_archival, "~> 2.0"},
      # ash_oban (ADR-037 §5.9 ADOPT, v0.8.10 — consumed by T32/T39/T41/T42; dep-add
      # owned by T39 per the same-ADR ash_money/ash_archival adoption pattern): the
      # WS-E automation engine's periodic scans (E1 schedule-due, E4 reminder-due,
      # E5 escalation-step-due) are AshOban triggers with EXPLICIT `scheduler_cron`
      # (no accidental every-minute defaults), queues registered via `AshOban.config/2`,
      # and the ID-only ActorPersister rule (job args carry bounded ids/enums only —
      # never actor structs, attribute values, or vt_* tokens; ADR-039 §2/§4.3). An
      # ash-project extension over Oban (already in the tree), not a vendor SDK.
      {:ash_oban, "~> 0.8.10"},
      # ash_state_machine (ADR-037 §5.8 ADOPT, targeted, v0.2.13 — consumed by T34/T39/T42;
      # dep-add owned by T34 per the same-ADR ash_archival/ash_oban adoption pattern, i.e. the
      # dep lands WITH its first governed adopter): ADR-040 §4 E3's `Approval` is the designated
      # new state-bearing resource — `pending → approved | rejected | expired | cancelled`, illegal
      # transitions refused by the machine (`NoMatchingTransition`); the double-decide guard is the
      # exactly-once mechanism (§4.3). The injected `:state` atom column is abbrev-prefixed +
      # catalogued like any column (ADR-037 §5.8 C2). Existing status-bearing resources are NOT
      # retrofitted this run (§5.8 C4). An ash-project extension over Ash (already in the tree).
      {:ash_state_machine, "~> 0.2.13"},
      # ash_paper_trail (ADR-037 §5.4 ADOPT, v0.6.0 — T33/T38 named; dep-add owned by
      # T119 per the same-ADR ash_money/ash_archival/ash_oban/ash_state_machine pattern,
      # i.e. the dep lands WITH its first governed adopter, not ahead of it): ADR-040 §6
      # E7 audit-on-write is a per-resource opt-in ON this extension — `use Samen.Resource,
      # versioned: true` (mode :changes_only default, :snapshot for CMS content per §6.5)
      # attaches AshPaperTrail.Resource with `store_action_inputs? false` FOREVER (INV-1,
      # §6.3) and `:full_diff` refused substrate-wide. The generated `<Resource>.Version`
      # gets full samen governance (allocator-owned abbrev, org_id mirror, OrgScope,
      # catalog, no_plaintext_pii roster) via the version-resource mixin (§6.2). An
      # ash-project extension over Ash (already in the tree), not a vendor SDK.
      {:ash_paper_trail, "~> 0.6.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
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
      licenses: ["MIT"]
    ]
  end
end
