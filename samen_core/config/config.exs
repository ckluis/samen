import Config

# samen_core is a library. The Repo and domains below exist only so the kernel's
# own test/dev fixtures (test/support/*) can be introspected by `mix ash.codegen`
# and exercised against a real Postgres. Host applications configure their own
# repo + domains.
config :samen_core,
  ecto_repos: [SamenCore.TestRepo],
  ash_domains: [
    SamenCore.Support.Crm,
    SamenCore.Support.Clinical,
    SamenCore.Support.PropDomain,
    SamenCore.Support.PiiClassifyDomain
  ]

config :ash, disable_async?: true

# AshPostgres migration primary key shape (matches the S0.2/S0.3 spike convention:
# binary_id named :id — the abbrev transformer then prefixes it per-resource).
config :samen_core, SamenCore.TestRepo,
  migration_primary_key: [name: :id, type: :binary_id]

# The Ecto repo the T1.6 reveal-grant model uses. Host apps configure their own.
config :samen_core, :reveal_grant_repo, SamenCore.TestRepo

# T2.3 rollup registry. A rollup is a small derived summary over the raw
# append-only `aud_event` tier — dashboards read the rollup, never scan raw
# events. The framework (Samen.Rollup.rebuild_all/1, RollupRefreshWorker cron),
# the erasure orchestration (rebuild-or-exclude-on-erasure), and the
# no_plaintext_pii oracle tier (Tiers.Rollup) all read this single registry.
#
# `rol_daily_event_count`: per-day / per-org(correlation) / per-subject event
# counts over `aud_event`. Token/bounded-ID/count columns only — no plaintext PII.
config :samen_core, :rollups, [
  %Samen.Rollup.Spec{
    name: :daily_event_count,
    table: "rol_daily_event_count",
    subject_column: "rol_subject_id",
    suppressed_column: "rol_suppressed",
    bounded_columns:
      ~w(rol_id rol_day rol_org_id rol_subject_id rol_event_count rol_suppressed rol_refreshed_at),
    rebuild_sql:
      {"DELETE FROM rol_daily_event_count",
       """
       INSERT INTO rol_daily_event_count
         (rol_day, rol_org_id, rol_subject_id, rol_event_count, rol_suppressed, rol_refreshed_at)
       SELECT
         aud_occurred_at::date AS rol_day,
         aud_correlation_id    AS rol_org_id,
         aud_subject_id::uuid  AS rol_subject_id,
         COUNT(*)::int         AS rol_event_count,
         FALSE                 AS rol_suppressed,
         now()                 AS rol_refreshed_at
       FROM aud_event
       WHERE aud_subject_id IS NOT NULL
       GROUP BY aud_occurred_at::date, aud_correlation_id, aud_subject_id::uuid
       """}
  }
]

# Oban config (T2.1 queue taxonomy). Uses the canonical Samen queue taxonomy
# from `Samen.Jobs.default_queue_config/0`. The test config overrides with
# `testing: :manual` so job rows are written but not auto-executed (the
# same-tx crash test needs observable job rows; the starvation test starts
# its own Oban supervisor with custom queues).
#
# Host apps should wire:
#
#     config :my_app, Oban,
#       repo: MyApp.Repo,
#       queues: Samen.Jobs.default_queue_config(),
#       plugins: [
#         {Oban.Plugins.Cron, crontab: Samen.Jobs.default_crontab()},
#         {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
#       ]
config :samen_core, Oban,
  repo: SamenCore.TestRepo,
  queues: [
    default: 10,
    rollups: 2,
    webhooks_out: 5,
    erasure: 1,
    maintenance: 1,
    reveal: 5
  ],
  plugins: false

import_config "#{config_env()}.exs"
