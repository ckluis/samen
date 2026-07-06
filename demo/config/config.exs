import Config

# Demo is a contact-manager dogfood app (T1.9).
# It uses samen_core as a path dep and exercises EVERY T1 feature.
config :demo,
  ecto_repos: [Demo.Repo],
  ash_domains: [Demo.Crm, Demo.Identity]

# samen_core verifiers (C1/C2/C3/C4/C5) discover domains from
# :samen_core :ash_domains. Register the demo's domains here so the
# verifier tasks find the demo resources — including the mounted Identity
# scope (T3.1: Identity resources are catalogued in the HOST's catalog and
# scanned by the host's UNCHANGED verifiers, per ADR-004).
config :samen_core, :ash_domains, [Demo.Crm, Demo.Identity]

config :ash, disable_async?: true

config :demo, Demo.Repo,
  migration_primary_key: [name: :id, type: :binary_id]

# catalog_parity allow-list (Gate-1 F3): the cnt_contact table has two raw-DDL
# columns added by migration — cnt_notes (the non_pii! reviewed plaintext column)
# and cnt_subject_id — that are NOT Ash resource attributes, so catalog_sync never
# emitted fld_field rows for them. They are intentional shadow columns, allow-listed
# so C1 catalog_parity does not flag them. This lives in the SHARED config (not
# config/test.exs) so `bash demo/ci.sh` is green in any MIX_ENV, not only :test.
# Keyed under :demo — the verifier reads Application.get_env(Mix.Project.config()[:app], …).
config :demo, :catalog_parity_allow_list, [
  {"cnt_contact", "cnt_notes"},
  {"cnt_contact", "cnt_subject_id"},
  # T2.4 expand-phase demo: cnt_tier is an operational shadow column added by the
  # ExpandAddContactTier expand migration (nullable, backward-compatible). Not an
  # Ash attribute, so allow-listed like cnt_notes.
  {"cnt_contact", "cnt_tier"}
]

# Reveal-grant model: wire Samen.Reveal.Grants (T1.6).
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, Demo.Repo
config :samen_core, :non_pii_repo, Demo.Repo
config :samen_core, :verify_repo, Demo.Repo

# Oban: T2.1 canonical queue taxonomy (consolidates T1.6 same-tx reveal enqueue).
# Uses the full Samen.Jobs queue taxonomy per the T2.1 convention layer.
# In production wire cron + pruner plugins; in test override with testing: :manual.
config :samen_core, Oban,
  repo: Demo.Repo,
  queues: [
    default: 10,
    rollups: 2,
    webhooks_out: 5,
    erasure: 1,
    maintenance: 1,
    reveal: 5
  ],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/10 * * * *", Samen.Jobs.RollupRefreshWorker}
     ]},
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

# T2.3 rollup registry (plain maps — config is evaluated before modules load, so
# Samen.Rollup.specs/0 builds %Spec{} at runtime). `rol_daily_event_count`:
# per-day / per-org / per-subject event counts over aud_event. The framework
# (RollupRefreshWorker cron), rebuild-or-exclude-on-erasure, and the
# no_plaintext_pii Rollup oracle tier all read this single registry.
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

# T2.6 OTel: db_statement must be :disabled (asserted by the LogTelemetry tier).
# The demo app calls OpentelemetryEcto.setup([:demo, :repo], db_statement: :disabled)
# in Demo.Application.start/2 when OTel is configured.
config :demo, :opentelemetry_ecto, db_statement: :disabled

# OTel SDK: no exporter in dev/test (operators wire a real OTLP exporter in prod).
# The :none value suppresses the "opentelemetry_exporter not found" warning.
config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none

import_config "#{config_env()}.exs"
