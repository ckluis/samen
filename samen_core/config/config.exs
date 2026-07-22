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
    SamenCore.Support.PiiClassifyDomain,
    SamenCore.Support.CustomFields,
    SamenCore.Support.RichTypes,
    Samen.CustomObjects.Domain,
    # T3.10 bounded-context DSL toy KERNEL domain (aliased/reshaped by Ctx.Toy).
    Core.Ctx
  ]

# T3.9 Tier-2 custom objects: the repo backing the `tnt_record` Ash resource +
# the `tnt_object`/`tnt_field` catalog. Host apps configure their own; falls back
# to :vault_repo in the runtime API. Compile-time here because the Record
# resource's `postgres do repo(...) end` reads it via compile_env.
config :samen_core, :tnt_record_repo, SamenCore.TestRepo

config :ash, disable_async?: true

# ADR-036 D1/ADR-037 §5.2: AshMoney/ex_money wiring. `known_types` lets Ash's
# operator-overload expr evaluation (sum/compare in calculations) recognize the
# wrapped type transitively; `auto_start_exchange_rate_service: false` is a
# deliberate no-op — samen_core/hosts never do live currency conversion, only
# same-currency arithmetic (ADR-036 D1 "Money is not PII", no FX feature), so the
# background exchange-rate poller (which would otherwise try a network call at
# boot) stays off.
config :ash, :known_types, [AshMoney.Types.Money]
config :ex_money, auto_start_exchange_rate_service: false

# AshPostgres migration primary key shape (matches the S0.2/S0.3 spike convention:
# binary_id named :id — the abbrev transformer then prefixes it per-resource).
config :samen_core, SamenCore.TestRepo,
  migration_primary_key: [name: :id, type: :binary_id]

# The Ecto repo the T1.6 reveal-grant model uses. Host apps configure their own.
config :samen_core, :reveal_grant_repo, SamenCore.TestRepo

# The Ecto repo the T4.1 masked-impersonation session runtime uses. Falls back to
# :reveal_grant_repo if unset. Host apps configure their own.
config :samen_core, :impersonation_repo, SamenCore.TestRepo

# The Ecto repo the T4.3 hash-chained audit (`aud_chain`) uses. Falls back to
# :reveal_grant_repo if unset. Host apps configure their own.
config :samen_core, :audit_chain_repo, SamenCore.TestRepo

# T4.3 WORM anchor adapter. Defaults to the faithful local append-only-file adapter
# (Samen.Anchor.LocalWorm). Production sets Samen.Anchor.S3ObjectLock + :anchor_s3_enabled
# (ADR-002 §3.2 — the config-flagged, never-faked S3 Object Lock compliance-mode skeleton).
config :samen_core, :anchor_adapter, Samen.Anchor.LocalWorm

# T4.4 break-glass. The repo backing the operator-suspension flag + reveal ledger +
# anchor-tracking (falls back to :impersonation_repo then :reveal_grant_repo).
config :samen_core, :operator_suspension_repo, SamenCore.TestRepo

# T4.4 breadth budget: N DISTINCT subjects revealed per rolling window before an
# operator is auto-suspended (all reveal paths then deny, incl. break-glass).
config :samen_core, :break_glass_breadth_budget, 25
config :samen_core, :break_glass_breadth_window_seconds, 3600

# T4.4 (R8): the locally-durable break-glass audit file path. In PRODUCTION this
# MUST point at a PERSISTENT VOLUME mounted per operator node (see the T4.4 runbook,
# docs/runbooks/break-glass.md) — the default tmp path is a dev/test convenience.
# The [:samen, :break_glass, :unanchored] telemetry fires while entries here are
# unanchored (the honest-residue monitor).
config :samen_core, :break_glass_local_audit_path,
  Path.join(System.tmp_dir!(), "samen_break_glass.local")

# T2.3 rollup registry. A rollup is a small derived summary over the raw
# append-only `aud_event` tier — dashboards read the rollup, never scan raw
# events. The framework (Samen.Rollup.rebuild_all/1, RollupRefreshWorker cron),
# the erasure orchestration (rebuild-or-exclude-on-erasure), and the
# no_plaintext_pii oracle tier (Tiers.Rollup) all read this single registry.
#
# The registry is PLAIN DATA (maps), not `%Samen.Rollup.Spec{}` structs: config
# is evaluated before the app's modules are compiled/loaded, so a struct literal
# here cannot resolve `Samen.Rollup.Spec.__struct__/1`. `Samen.Rollup.specs/0`
# builds `%Spec{}` structs from this data at runtime (`Spec.from_config/1`),
# which also validates the shape fail-closed.
#
# `rol_daily_event_count`: per-day / per-org(correlation) / per-subject event
# counts over `aud_event`. Token/bounded-ID/count columns only — no plaintext PII.
config :samen_core, :rollups, [
  %{
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

# T2.6 OTel tracing: db_statement MUST be :disabled on a Samen substrate.
# OpentelemetryEcto records SQL text + bind params by default — disabling it
# ensures no pii_ token / plaintext value serializes into db.statement in any
# span. The LogTelemetry tier of no_plaintext_pii asserts this both at config
# level (Phase 1) and at live-setup time (Phase 2, T2.6).
#
# Host apps MUST call:
#   OpentelemetryEcto.setup([:my_app, :repo], db_statement: :disabled)
# in their application start — and configure the same key so the CI tier can
# verify it:
#   config :my_app, :opentelemetry_ecto, db_statement: :disabled
config :samen_core, :opentelemetry_ecto, db_statement: :disabled

# OTel SDK: in test we use the simple (synchronous) processor + the pid
# exporter so tests can assert on spans inline. In prod, the host configures
# its own exporter (OTLP → Honeycomb/Tempo/etc.).
config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none

import_config "#{config_env()}.exs"
