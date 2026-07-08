import Config

# Driftwood — the Phase-5 freight-brokerage reference vertical (T5.2).
# Mounts the samen_core CRM scope, composes the vertical Freight resources
# (Driver / Settlement / DispatchEvent) and lays Driftwood.Context over the
# kernel nouns (Carrier/Shipper/Load aliases + settlement netting reshape).
config :driftwood,
  ecto_repos: [Driftwood.Repo],
  ash_domains: [
    Driftwood.Crm,
    Driftwood.Billing,
    Driftwood.Support,
    Driftwood.Freight,
    Driftwood.Aggregate,
    Driftwood.Operator
  ]

# The samen_core verifiers (catalog_parity/prefixes/pii_reads/pii_classify/…)
# discover domains from :samen_core :ash_domains. Register Driftwood's domains so
# the gate scans the mounted CRM scope + the vertical Freight resources + the
# token-blind aggregate plane (T5.3 clause (b)).
config :samen_core, :ash_domains, [
  Driftwood.Crm,
  Driftwood.Billing,
  Driftwood.Support,
  Driftwood.Freight,
  Driftwood.Aggregate,
  Driftwood.Operator
]

# ADR-010 — the well-known OPERATOR org id (the SaaS company's own org). The operator
# workspace (`/operator/accounts` · `/billing` · `/desk`) scopes to this org over its OWN book
# of business (tenant orgs as accounts) on the TENANT plane (PII of the SaaS's own customers
# CLEAR). `Samen.Web.Operator.org_id/1` resolves it: label → this app-env → single seeded row.
config :driftwood, operator_org_id: "0f000000-0000-4000-8000-0000000000aa"

config :ash, disable_async?: true

config :driftwood, Driftwood.Repo,
  migration_primary_key: [name: :id, type: :binary_id]

# T5.4 rollup registry — the DRIVER-keyed load-count rollup the crypto-shred
# game-day governs across BOTH erasure arms (rebuild-or-exclude-on-erasure).
# `drl_driver_load_count`: per-day / per-org / per-driver dispatch-event counts
# over the raw append-only `aud_event` tier. Plain maps (config is evaluated before
# `Samen.Rollup.Spec` loads; `Samen.Rollup.specs/0` builds the struct at runtime).
# The refresh framework, the erasure orchestration, and the `no_plaintext_pii`
# Rollup oracle tier all read this single registry.
#
# The rebuild SQL counts DISPATCH-class events (aud_event_type = 'dispatch') per
# driver subject — a driver's load-dispatch stream. A pre-shred rollup that counted
# a driver's loads must NOT resurrect the driver after erasure (T5.4 red path); the
# rebuild arm recomputes it driver-free, the suppress arm flags the derived row.
config :samen_core, :rollups, [
  %{
    name: :driver_load_count,
    table: "drl_driver_load_count",
    subject_column: "drl_subject_id",
    suppressed_column: "drl_suppressed",
    bounded_columns:
      ~w(drl_id drl_day drl_org_id drl_subject_id drl_load_count drl_suppressed drl_refreshed_at),
    rebuild_sql:
      {"DELETE FROM drl_driver_load_count",
       """
       INSERT INTO drl_driver_load_count
         (drl_day, drl_org_id, drl_subject_id, drl_load_count, drl_suppressed, drl_refreshed_at)
       SELECT
         aud_occurred_at::date AS drl_day,
         aud_correlation_id    AS drl_org_id,
         aud_subject_id::uuid  AS drl_subject_id,
         COUNT(*)::int         AS drl_load_count,
         FALSE                 AS drl_suppressed,
         now()                 AS drl_refreshed_at
       FROM aud_event
       WHERE aud_subject_id IS NOT NULL
         AND aud_event_type = 'dispatch'
       GROUP BY aud_occurred_at::date, aud_correlation_id, aud_subject_id::uuid
       """}
  }
]

# Reveal-grant + non_pii + verify repos (T1.6/T1.7): wire the Driftwood repo.
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, Driftwood.Repo
config :samen_core, :non_pii_repo, Driftwood.Repo
config :samen_core, :verify_repo, Driftwood.Repo
config :samen_core, :vault_repo, Driftwood.Repo

# The FMCSA dispatch gate reads the CDL vault-token PRESENCE (not plaintext) via a
# bounded repo query on the pii_vault table (design §4 / OR-7). It needs the repo.
config :driftwood, :vault_repo, Driftwood.Repo

# T4.1 masked impersonation over Driftwood tenants (T5.3 clause (b)): the repo backing
# impersonation sessions. An operator opens a bounded, reason-required session over ONE
# brokerage tenant org and sees its REAL load board / driver roster with PII (••••).
config :samen_core, :impersonation_repo, Driftwood.Repo

# T4.5 aggregate-privacy floors for Driftwood's token-blind cross-tenant plane. The
# samen_core defaults are k=5 / l=2; the dogfood datasets are small, so — exactly as the
# demo does — Driftwood uses a small-but-non-trivial floor (k=2 / l=2): a count-of-one
# lane/tier still suppresses (the load-bearing k-anon guarantee that one brokerage's exact
# volume/MRR is never released). Production hosts keep the k=5 default.
config :samen_core, :k_anonymity_min_cohort, 2
config :samen_core, :l_diversity_min_distinct, 2

# The query-budget ledger repo (T4.5 SCAFFOLD — accounting only, WARN-not-enforce).
config :samen_core, :query_budget_ledger_repo, Driftwood.Repo

# T5.3: the DriftwoodWeb.Endpoint that serves the tenant + operator LiveView planes
# over localhost (the Fly/Neon target is an OPERATOR TODO — see docs/driftwood-dogfood.md
# "deploy seam"). The secret_key_base + live_view signing salt are LOCAL DEV/DOGFOOD
# constants (not production secrets — a real deploy injects them from the environment).
config :driftwood, DriftwoodWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4010")],
  secret_key_base: "driftwood_local_dogfood_secret_key_base_at_least_64_bytes_long_000000000000",
  live_view: [signing_salt: "driftwood_lv_salt_dogfood"],
  render_errors: [formats: [html: DriftwoodWeb.ErrorHTML], layout: false],
  pubsub_server: Driftwood.PubSub,
  server: false

config :phoenix, :json_library, Jason

# Oban: T2.1 canonical queue taxonomy. The load/dispatch workflow (DispatchWorker)
# runs on :default; erasure + reveal keep the shipped queues.
config :samen_core, Oban,
  repo: Driftwood.Repo,
  queues: [
    default: 10,
    rollups: 2,
    webhooks_out: 5,
    erasure: 1,
    maintenance: 1,
    reveal: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

import_config "#{config_env()}.exs"
