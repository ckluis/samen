import Config

# ADR-036 D1 / ADR-037 §5.2: AshMoney/ex_money wiring (CRM Opportunity / Billing
# Price Money attributes). No FX feature — the background exchange-rate poller
# stays off.
config :ash, :known_types, [AshMoney.Types.Money]
config :ex_money, auto_start_exchange_rate_service: false

# Demo is a contact-manager dogfood app (T1.9).
# It uses samen_core as a path dep and exercises EVERY T1 feature.
config :demo,
  ecto_repos: [Demo.Repo],
  ash_domains: [Demo.Crm, Demo.Identity, Demo.CrmScope, Demo.BillingScope, Demo.MarketingScope, Demo.CmsScope, Demo.SupportScope, Demo.PrimitivesScope, Demo.Analytics, Demo.Aggregate]

# samen_core verifiers (C1/C2/C3/C4/C5) discover domains from
# :samen_core :ash_domains. Register the demo's domains here so the
# verifier tasks find the demo resources — including the mounted Identity
# scope (T3.1), the CRM scope (T3.2), the Billing scope (T3.3), the
# Marketing scope (T3.4), the CMS scope (T3.5), the Support scope
# (T3.6), and the Primitives scope (T3.7 — resources catalogued in HOST's
# catalog, scanned by host's UNCHANGED verifiers, per ADR-004).
config :samen_core, :ash_domains, [Demo.Crm, Demo.Identity, Demo.CrmScope, Demo.BillingScope, Demo.MarketingScope, Demo.CmsScope, Demo.SupportScope, Demo.PrimitivesScope, Demo.Analytics, Demo.Aggregate]

# WS-B / Phase B7 (ADR-021): wire the product-analytics capture seam.
#   * `Samen.Analytics.track/1` writes into the DEMO's `pae` ledger;
#   * every feature-flag variant assignment (design §3.4) flows to `track/1` via the
#     configured emitter — zero call-site changes (B5/B6 seam → B7 sink).
config :samen_core, Samen.Analytics, product_event_resource: Demo.Analytics.ProductEvent
config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}

# T3.6 SLA breach detection: configure the ticket resource for the Oban cron.
config :samen_core, :support_sla_breach_ticket_resource, Demo.SupportScope.Ticket
config :samen_core, :support_sla_ticket_abbrev, "stk"

# WS-A A4/A5 / ADR-035 §5 A10 — the kernel notification ENGINE wired to the demo's
# mounted Primitives resources (the ADR-014 SendWorker config convention: the kernel
# is mount-agnostic; the host names its concrete modules + repo). WITHOUT this,
# every source event (auth-lifecycle A10 fan-out included) best-effort NO-OPs with
# `{:error, :no_notification_module}` — so the demo, a proof host, must wire it to
# match driftwood. No `:broadcaster` is set: the demo has no samen_web PubSub server,
# so dispatch defaults to `Samen.Notifications.LogBroadcaster` (samen_core) — the
# Notification RECORD still lands (the dispatch that matters), the realtime broadcast
# is a web concern the API-only demo does not run.
config :samen_core, Samen.Notifications.Engine,
  notification_module: Demo.PrimitivesScope.Notification,
  preference_module: Demo.PrimitivesScope.NotificationPreference,
  repo: Demo.Repo

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

# T4.1 masked impersonation: the repo backing impersonation sessions + the operator
# plane resource map (accounts ARE tenant orgs — Identity Org joined to Billing
# Subscription/Plan and Support Ticket rollups). Single-org paths only (cross-tenant
# aggregates are T4.2).
config :samen_core, :impersonation_repo, Demo.Repo

config :samen_core, :operator_plane,
  org: Demo.Identity.Org,
  subscription: Demo.BillingScope.Subscription,
  plan: Demo.BillingScope.Plan,
  ticket: Demo.SupportScope.Ticket

# T3.8 Tier-1 custom fields: the repo backing the `tnt_field` catalog and the
# validated-at-write change fallback. The change resolves the resource's own
# AshPostgres repo first; this is the fallback for repo-less call sites.
config :samen_core, :vault_repo, Demo.Repo

# T4.5 aggregate-privacy floors + query-budget scaffold.
#
# k-anonymity minimum cohort + l-diversity minimum distinct. The samen_core defaults
# are k=5 / l=2 (a sensible real-world floor). The demo's dogfood datasets are small
# (2 tenants per tier, a handful of tickets), so a k=5 floor would suppress every
# demo cohort and obscure what the tests demonstrate. The demo therefore uses a
# small-but-non-trivial floor (k=2 / l=2): a count-of-one cohort still suppresses
# (the load-bearing k-anon guarantee — one tenant's exact MRR / one ticket's status
# is never released), and a homogeneous status cohort (all one priority) still
# suppresses under l-diversity. Production hosts keep the k=5 default.
config :samen_core, :k_anonymity_min_cohort, 2
config :samen_core, :l_diversity_min_distinct, 2

# The query-budget ledger. Accounting is always on (per-cohort, WARN-not-enforce).
config :samen_core, :query_budget_ledger_repo, Demo.Repo
config :samen_core, :query_budget_warn_threshold, 50
config :samen_core, :query_budget_window_seconds, 3600

# T6.6 — the ENFORCING cross-query budget is OPT-IN and stays OFF here by default, so the
# demo's dashboard reads are never budget-denied in ordinary operation. The adversarial
# differencing suite turns it ON per-test (with a small per-cohort budget) to prove that,
# when enabled, a repeated/collusion read of an above-floor cohort is SUPPRESSED
# (`reason: :query_budget`) — the cross-query defence the ledger could only RECORD in
# T4.5. A production operator opts in with:
#   config :samen_core, :query_budget_enforce, true
#   config :samen_core, :query_budget_per_cohort, N   # reads/cohort/window before deny
#   config :samen_core, :query_budget_global, M        # reads across all cohorts/window (optional)
config :samen_core, :query_budget_enforce, false

# T6.6 — the OPT-IN differential-privacy noise layer (Laplace mechanism, `Samen.Aggregate.Dp`)
# is likewise OFF by default. Enabling it adds calibrated noise to released aggregate
# counts. HONEST CAVEAT (see the Dp moduledoc + the T6.6 report): a single ε-DP release is
# NOT a system-level DP guarantee — a formal ε-budget composed across queries is the
# still-open research edge (t-closeness too). We ship the mechanism, not the composition
# proof. Enable with:
#   config :samen_core, :dp_enabled, true
#   config :samen_core, :dp_epsilon, 1.0
config :samen_core, :dp_enabled, false

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
  },
  # WS-B / Phase B2 (ADR-018): the DOMAIN-SOURCED revenue-movement rollup
  # (`mrr_revenue_rollup`). Grain (org_id, period_month, mov_kind) → sum(delta), count,
  # recomputed from the `mov` subscription-movement ledger (a DOMAIN table, ADR-017),
  # NOT from aud_event. `source: :domain` selects the ADR-018 REBUILD arm: on a
  # subject shred the subject's `mov` rows are deleted (subject_delete_sql, keyed on
  # mov_customer_id — the subject) then this rollup is recomputed subject-free. It is
  # a subject-free aggregate BY CONSTRUCTION (period/kind grain, no per-subject
  # column), so subject_column/suppressed_column are omitted — the erasure hook lives
  # on the ledger side, not a rollup-table column (AC-G7-7 red-path proves it).
  %{
    name: :revenue_rollup,
    source: :domain,
    table: "mrr_revenue_rollup",
    subject_delete_sql: "DELETE FROM mov_subscription_event WHERE mov_customer_id::text = $1",
    # The post-shred oracle scans HERE for surviving subject rows, INDEPENDENTLY of
    # subject_delete_sql (B2-P1): SELECT count(*) FROM mov_subscription_event
    # WHERE mov_customer_id::text = $1. A sabotaged/no-op delete hook that leaves the
    # subject's ledger rows is then caught as an oracle CONTENT violation, not merely
    # missed by trusting the report's self-attested arm label.
    domain_table: "mov_subscription_event",
    domain_subject_column: "mov_customer_id",
    bounded_columns:
      ~w(mrr_id mrr_org_id mrr_period_month mrr_kind mrr_delta_cents mrr_count mrr_suppressed mrr_refreshed_at),
    rebuild_sql:
      {"DELETE FROM mrr_revenue_rollup",
       """
       INSERT INTO mrr_revenue_rollup
         (mrr_org_id, mrr_period_month, mrr_kind, mrr_delta_cents, mrr_count, mrr_suppressed, mrr_refreshed_at)
       SELECT
         mov_org_id                              AS mrr_org_id,
         date_trunc('month', mov_occurred_at)::date AS mrr_period_month,
         mov_kind                                AS mrr_kind,
         COALESCE(SUM(mov_mrr_delta_cents),0)::int AS mrr_delta_cents,
         COUNT(*)::int                           AS mrr_count,
         FALSE                                   AS mrr_suppressed,
         now()                                   AS mrr_refreshed_at
       FROM mov_subscription_event
       GROUP BY mov_org_id, date_trunc('month', mov_occurred_at)::date, mov_kind
       """}
  },
  # WS-B / Phase B8 (ADR-021): the DOMAIN-SOURCED funnel/retention rollup
  # (`paf_product_event_rollup`) over the `pae` product-event ledger — the G12 SEED
  # read's data source, on the `revenue_rollup` (B2/ADR-018) machinery exactly.
  # TWO arms in one table: funnel rows (org, stage) for signup→first-run→first-record
  # (a row exists iff the org reached the stage; actor_count = distinct pseudonyms,
  # 0 for org-level events) and retention rows (org, cohort_week, week_offset 0..4)
  # of distinct actors active N weeks after their first event. Bounded to the
  # design's ONE funnel + 4-week curve — no paths, no DAU/MAU, no ClickHouse.
  #
  # ERASURE STANCE (design §4.4 — `pae` has NO subject column): `pae_actor_ref` is a
  # per-subject HMAC pseudonym, so the LOAD-BEARING erasure is B7's key destruction
  # (post-shred the pseudonym is unreconstructable; AC-G12-5) — the rollup's counts
  # stay honest k-anonymous aggregate. The `subject_delete_sql` + oracle residue
  # scan below key `pae_actor_ref` against the RAW subject id and match ZERO rows
  # BY CONSTRUCTION (token-blind: the raw id never reaches `pae`). That zero IS the
  # invariant they enforce: were a sabotaged `track/1` ever to leak a raw subject id
  # into `pae_actor_ref`, the domain REBUILD arm deletes it on shred and the
  # DbContent oracle's INDEPENDENT residue scan (B2-P1) flags any survivor.
  %{
    name: :product_event_rollup,
    source: :domain,
    table: "paf_product_event_rollup",
    subject_delete_sql: "DELETE FROM pae_product_event WHERE pae_actor_ref::text = $1",
    domain_table: "pae_product_event",
    domain_subject_column: "pae_actor_ref",
    bounded_columns:
      ~w(paf_id paf_org_id paf_kind paf_stage paf_cohort_week paf_week_offset paf_actor_count paf_suppressed paf_refreshed_at),
    rebuild_sql:
      {"DELETE FROM paf_product_event_rollup",
       """
       INSERT INTO paf_product_event_rollup
         (paf_org_id, paf_kind, paf_stage, paf_cohort_week, paf_week_offset,
          paf_actor_count, paf_suppressed, paf_refreshed_at)
       SELECT
         pae_org_id                                AS paf_org_id,
         'funnel'                                  AS paf_kind,
         CASE pae_event_name
           WHEN 'session.signed_in'   THEN 'signup'
           WHEN 'first_run.completed' THEN 'first_run'
           ELSE 'first_record'
         END                                       AS paf_stage,
         NULL::date                                AS paf_cohort_week,
         NULL::int                                 AS paf_week_offset,
         COUNT(DISTINCT pae_actor_ref)::int        AS paf_actor_count,
         FALSE                                     AS paf_suppressed,
         now()                                     AS paf_refreshed_at
       FROM pae_product_event
       WHERE pae_event_name IN ('session.signed_in', 'first_run.completed', 'record.created')
       GROUP BY pae_org_id, pae_event_name
       UNION ALL
       SELECT
         a.pae_org_id                              AS paf_org_id,
         'retention'                               AS paf_kind,
         NULL::text                                AS paf_stage,
         f.cohort_week                             AS paf_cohort_week,
         ((date_trunc('week', a.pae_occurred_at)::date - f.cohort_week) / 7)::int
                                                   AS paf_week_offset,
         COUNT(DISTINCT a.pae_actor_ref)::int      AS paf_actor_count,
         FALSE                                     AS paf_suppressed,
         now()                                     AS paf_refreshed_at
       FROM pae_product_event a
       JOIN (
         SELECT pae_org_id, pae_actor_ref,
                date_trunc('week', MIN(pae_occurred_at))::date AS cohort_week
         FROM pae_product_event
         WHERE pae_actor_ref IS NOT NULL
         GROUP BY pae_org_id, pae_actor_ref
       ) f
         ON f.pae_org_id = a.pae_org_id AND f.pae_actor_ref = a.pae_actor_ref
       WHERE a.pae_actor_ref IS NOT NULL
         AND ((date_trunc('week', a.pae_occurred_at)::date - f.cohort_week) / 7) BETWEEN 0 AND 4
       GROUP BY a.pae_org_id, f.cohort_week,
                ((date_trunc('week', a.pae_occurred_at)::date - f.cohort_week) / 7)
       """}
  }
]

# T2.6 OTel: db_statement must be :disabled (asserted by the LogTelemetry tier).
# Demo.Application.start/2 wires Samen.Observability.child_specs(:demo) (WS-D D1.1),
# which owns the db_statement: :disabled default and raises if this key contradicts it.
config :demo, :opentelemetry_ecto, db_statement: :disabled

# OTel SDK: no exporter in dev/test (operators wire a real OTLP exporter in prod).
# The :none value suppresses the "opentelemetry_exporter not found" warning.
config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none

import_config "#{config_env()}.exs"
