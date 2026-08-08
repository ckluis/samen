import Config

# ADR-036 D1 / ADR-037 §5.2: AshMoney/ex_money wiring (CRM Opportunity / Billing
# Price Money attributes). No FX feature — the background exchange-rate poller
# stays off.
config :ash, :known_types, [AshMoney.Types.Money]
config :ex_money, auto_start_exchange_rate_service: false

# PawChart — the Phase-6 second-vertical thin slice (T6.2), the reuse-measurement
# probe. MOUNTS the samen_core Billing scope AS-IS (plain subscriptions, NO reshape),
# AUTHORS the vertical Clinical resources (Patient / Pet), and DEFINES a Tier-2
# VaccineLot custom object clinics author themselves.
config :pawchart,
  ecto_repos: [PawChart.Repo],
  ash_domains: [
    PawChart.Crm,
    PawChart.Billing,
    PawChart.Support,
    PawChart.Work,
    PawChart.Calendar,
    PawChart.Docs,
    PawChart.Tags,
    PawChart.Locations,
    PawChart.SalesOps,
    PawChart.Marketing,
    PawChart.Clinic,
    PawChart.Aggregate,
    PawChart.Primitives,
    PawChart.Analytics,
    # T157 — the ADR-010 OPERATOR namespace (a SECOND Identity+Billing+Support mount over the
    # SaaS's OWN book of business: the clinic ACCOUNTS + their admins + subscriptions + desk).
    PawChart.Operator
  ]

# The samen_core verifiers (catalog_parity/prefixes/pii_reads/pii_classify/…) discover
# domains from :samen_core :ash_domains. Register PawChart's domains so the gate scans
# the mounted CRM/Billing/Support scopes + the vertical Clinical resources + the
# token-blind aggregate plane.
config :samen_core, :ash_domains, [
  PawChart.Crm,
  PawChart.Billing,
  PawChart.Support,
  PawChart.Work,
  PawChart.Calendar,
  PawChart.Docs,
  PawChart.Tags,
  PawChart.Locations,
  PawChart.SalesOps,
  PawChart.Marketing,
  PawChart.Clinic,
  PawChart.Aggregate,
  PawChart.Primitives,
  PawChart.Analytics,
  # T157 — register the operator namespace so the verifier gate scans its mounted
  # Identity/Billing/Support resources (catalog_parity / prefixes / pii_* / vault parity).
  PawChart.Operator
]

# T157 (ADR-010) — the well-known OPERATOR org id (the SaaS company's own org). The operator
# workspace (`/operator/accounts` · `/billing` · `/revenue` · `/desk`) scopes to this org over
# its OWN book of business on the TENANT plane (the clinics-as-customers + their admins, CLEAR).
# `Samen.Web.Operator.org_id/1` resolves it: label → this app-env → single seeded row.
config :pawchart, operator_org_id: "0f000000-0000-4000-8000-0000000000c1"

# F2 / ADR-031 — the prod auth arm. OFF for the local dogfood (the query-param convenience
# identity stays); a real launch flips it true and provisions the operator roster below.
config :pawchart, auth_required?: false

# T146 / T157 — the operator-ROLE authority seam (`Samen.Web.Operator.Authz` on_mount +
# `Samen.Web.AuthGate` conn pipeline). Called with the authenticated principal id appended;
# returns an operator role (`Samen.OperatorPlane.Actor.roles/0`) or `nil` (NOT an operator →
# refused). `PawChart.Auth.operator_role/2` resolves a REAL configured `:operator_roster`
# (below) FIRST; a dev-only `:operator_admin` grant applies ONLY while `:auth_required?` is
# false AND the principal is absent from the roster. The seam is the REAL resolver, NOT the
# framework `Samen.Web.Operator.Authz.dev_operator_role/2` dev fallback (T157 done-criterion).
config :pawchart, :operator_authority, {PawChart.Auth, :operator_role, [:pawchart]}

# T157 — a REAL operator roster (not the dev fallback): the seeded platform operator principal
# holds `:operator_support`. Proves the roster path grants a listed principal and refuses an
# unlisted one EVEN when the dev fallback is disarmed (`auth_required?: true`). A production
# deploy provisions this (or swaps `operator_role/2` for real operator `Membership` rows).
config :pawchart, :operator_roster, %{
  "op-pawchart-platform" => :operator_support
}

# T157 — masked impersonation over PawChart clinic tenants: the repo backing impersonation
# sessions. An operator opens a bounded, reason-required session over ONE clinic org and sees
# its REAL patient/pet roster with PII masked (••••).
config :samen_core, :impersonation_repo, PawChart.Repo

# WS-A A4/A5 — the kernel notification ENGINE (`Samen.Notifications.Engine`) wired to
# PawChart's mounted Primitives resources (the ADR-014 SendWorker config convention:
# the kernel is mount-agnostic; the host names its concrete modules + repo). The
# realtime broadcast rides the samen_web PubSub broadcaster over `PawChart.PubSub` —
# id-only envelopes (Invariant N1); each inbox subscriber re-reads per its OWN scope.
config :samen_core, Samen.Notifications.Engine,
  notification_module: PawChart.Primitives.Notification,
  preference_module: PawChart.Primitives.NotificationPreference,
  repo: PawChart.Repo,
  broadcaster: Samen.Web.Notifications.PubSubBroadcaster

config :samen_web, Samen.Web.Notifications.PubSubBroadcaster, pubsub: PawChart.PubSub

# WS-B B9 (AC-X1) — the product-analytics capture emitter (ADR-021):
#   * `Samen.Analytics.track/1` writes into PawChart's `vae` ledger;
#   * every flag-variant assignment (ADR-020 §3.4 seam) flows to `track/1`.
config :samen_core, Samen.Analytics, product_event_resource: PawChart.Analytics.ProductEvent
config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}

# WS-B B9 (AC-X1) — the DOMAIN-SOURCED operator-cockpit rollups (ADR-018/021), the
# demo B2/B8 specs with PawChart's ledgers as sources. Host-invariant table names
# (`mrr_revenue_rollup` / `paf_product_event_rollup` — the rol precedent);
# `Samen.Rollup.specs/0`, the RollupRefreshWorker cron, the erasure orchestration,
# and the `no_plaintext_pii` Rollup oracle tier all read this single registry.
config :samen_core, :rollups, [
  # Revenue-movement rollup over PawChart's `pbv` subscription-movement ledger
  # (the single Billing mount — the demo single-mount pattern; the clinic vertical
  # has no separate operator-book billing namespace yet). Subject-free aggregate by
  # construction (period/kind grain); the erasure hook is the ledger-side
  # `subject_delete_sql` keyed on the movement's customer (AC-G7-7 stance).
  %{
    name: :revenue_rollup,
    source: :domain,
    table: "mrr_revenue_rollup",
    subject_delete_sql: "DELETE FROM pbv_subscription_event WHERE pbv_customer_id::text = $1",
    domain_table: "pbv_subscription_event",
    domain_subject_column: "pbv_customer_id",
    bounded_columns:
      ~w(mrr_id mrr_org_id mrr_period_month mrr_kind mrr_delta_cents mrr_count mrr_suppressed mrr_refreshed_at),
    rebuild_sql:
      {"DELETE FROM mrr_revenue_rollup",
       """
       INSERT INTO mrr_revenue_rollup
         (mrr_org_id, mrr_period_month, mrr_kind, mrr_delta_cents, mrr_count, mrr_suppressed, mrr_refreshed_at)
       SELECT
         pbv_org_id                              AS mrr_org_id,
         date_trunc('month', pbv_occurred_at)::date AS mrr_period_month,
         pbv_kind                                AS mrr_kind,
         COALESCE(SUM(pbv_mrr_delta_cents),0)::int AS mrr_delta_cents,
         COUNT(*)::int                           AS mrr_count,
         FALSE                                   AS mrr_suppressed,
         now()                                   AS mrr_refreshed_at
       FROM pbv_subscription_event
       GROUP BY pbv_org_id, date_trunc('month', pbv_occurred_at)::date, pbv_kind
       """}
  },
  # Funnel/retention seed rollup over PawChart's `vae` product-event ledger.
  # Erasure stance per design §4.4: `vae` has NO subject column — `vae_actor_ref`
  # is a per-subject HMAC pseudonym, so the load-bearing erasure is key
  # destruction; the `subject_delete_sql` + residue scan key the pseudonym column
  # against the RAW subject id and match zero rows BY CONSTRUCTION (they exist to
  # catch a sabotaged track/1 leaking a raw id).
  %{
    name: :product_event_rollup,
    source: :domain,
    table: "paf_product_event_rollup",
    subject_delete_sql: "DELETE FROM vae_product_event WHERE vae_actor_ref::text = $1",
    domain_table: "vae_product_event",
    domain_subject_column: "vae_actor_ref",
    bounded_columns:
      ~w(paf_id paf_org_id paf_kind paf_stage paf_cohort_week paf_week_offset paf_actor_count paf_suppressed paf_refreshed_at),
    rebuild_sql:
      {"DELETE FROM paf_product_event_rollup",
       """
       INSERT INTO paf_product_event_rollup
         (paf_org_id, paf_kind, paf_stage, paf_cohort_week, paf_week_offset,
          paf_actor_count, paf_suppressed, paf_refreshed_at)
       SELECT
         vae_org_id                                AS paf_org_id,
         'funnel'                                  AS paf_kind,
         CASE vae_event_name
           WHEN 'session.signed_in'   THEN 'signup'
           WHEN 'first_run.completed' THEN 'first_run'
           ELSE 'first_record'
         END                                       AS paf_stage,
         NULL::date                                AS paf_cohort_week,
         NULL::int                                 AS paf_week_offset,
         COUNT(DISTINCT vae_actor_ref)::int        AS paf_actor_count,
         FALSE                                     AS paf_suppressed,
         now()                                     AS paf_refreshed_at
       FROM vae_product_event
       WHERE vae_event_name IN ('session.signed_in', 'first_run.completed', 'record.created')
       GROUP BY vae_org_id, vae_event_name
       UNION ALL
       SELECT
         a.vae_org_id                              AS paf_org_id,
         'retention'                               AS paf_kind,
         NULL::text                                AS paf_stage,
         f.cohort_week                             AS paf_cohort_week,
         ((date_trunc('week', a.vae_occurred_at)::date - f.cohort_week) / 7)::int
                                                   AS paf_week_offset,
         COUNT(DISTINCT a.vae_actor_ref)::int      AS paf_actor_count,
         FALSE                                     AS paf_suppressed,
         now()                                     AS paf_refreshed_at
       FROM vae_product_event a
       JOIN (
         SELECT vae_org_id, vae_actor_ref,
                date_trunc('week', MIN(vae_occurred_at))::date AS cohort_week
         FROM vae_product_event
         WHERE vae_actor_ref IS NOT NULL
         GROUP BY vae_org_id, vae_actor_ref
       ) f
         ON f.vae_org_id = a.vae_org_id AND f.vae_actor_ref = a.vae_actor_ref
       WHERE a.vae_actor_ref IS NOT NULL
         AND ((date_trunc('week', a.vae_occurred_at)::date - f.cohort_week) / 7) BETWEEN 0 AND 4
       GROUP BY a.vae_org_id, f.cohort_week,
                ((date_trunc('week', a.vae_occurred_at)::date - f.cohort_week) / 7)
       """}
  }
]

config :ash, disable_async?: true

config :pawchart, PawChart.Repo,
  migration_primary_key: [name: :id, type: :binary_id]

# Reveal-grant + non_pii + verify + vault + tnt_record repos: wire the PawChart repo.
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, PawChart.Repo
config :samen_core, :non_pii_repo, PawChart.Repo
config :samen_core, :verify_repo, PawChart.Repo
config :samen_core, :vault_repo, PawChart.Repo

# T3.9 Tier-2 custom objects (VaccineLot): the repo backing the tnt_object / tnt_field
# catalog and the tnt_record CRUD. PawChart is the vision doc's canonical Tier-2 case
# ("a VaccineLot object clinics define themselves"), so it wires the tnt_record repo.
config :samen_core, :tnt_record_repo, PawChart.Repo

# T4.5 aggregate-privacy floors for PawChart's token-blind cross-tenant plane. The
# samen_core defaults are k=5 / l=2; the dogfood datasets are small, so — exactly as
# demo/driftwood do — PawChart uses a small-but-non-trivial floor (k=2 / l=2): a
# count-of-one clinic still suppresses (the load-bearing k-anon guarantee that one
# clinic's exact patient volume / MRR is never released). Production hosts keep k=5.
config :samen_core, :k_anonymity_min_cohort, 2
config :samen_core, :l_diversity_min_distinct, 2

# The query-budget ledger repo (SCAFFOLD — accounting only, WARN-not-enforce).
config :samen_core, :query_budget_ledger_repo, PawChart.Repo

config :phoenix, :json_library, Jason

# PawChartWeb.Endpoint — serves the tenant + operator LiveView planes (CRM/Billing/
# Support modules mounted from samen_web + the clinical-vertical pages). Port 4032.
config :pawchart, PawChartWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4032")],
  secret_key_base: "pawchart_local_dogfood_secret_key_base_at_least_64_bytes_long_00000000",
  live_view: [signing_salt: "pawchart_lv_salt_dogfood"],
  render_errors: [formats: [html: PawChartWeb.ErrorHTML], layout: false],
  pubsub_server: PawChart.PubSub,
  server: false

# Oban: the canonical queue taxonomy (reused verbatim from the substrate convention).
config :samen_core, Oban,
  repo: PawChart.Repo,
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
