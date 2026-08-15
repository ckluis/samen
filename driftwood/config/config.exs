import Config

# ADR-036 D1 / ADR-037 §5.2: AshMoney/ex_money wiring (CRM Opportunity / Billing
# Price Money attributes, tenant + operator billing mounts). No FX feature — the
# background exchange-rate poller stays off.
config :ash, :known_types, [AshMoney.Types.Money]
config :ex_money, auto_start_exchange_rate_service: false

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
    Driftwood.Work,
    Driftwood.Calendar,
    Driftwood.Docs,
    Driftwood.Tags,
    Driftwood.Locations,
    Driftwood.SalesOps,
    Driftwood.Marketing,
    Driftwood.Freight,
    Driftwood.Aggregate,
    Driftwood.Operator,
    Driftwood.Chat,
    Driftwood.Primitives,
    Driftwood.Analytics,
    Driftwood.Automation,
    # T155 (ADR-043 §6.3): adopt the reusable AI-plane domain (Samen.AI.Prompt +
    # Samen.AI.SupportReplyDraft) so AI support-reply drafts PERSIST in a real host
    # (repo overrides + migrations below; the ai_support_reply approval kind registered
    # in the Approvals.Registry block).
    Samen.AI.Domain
  ]

# The samen_core verifiers (catalog_parity/prefixes/pii_reads/pii_classify/…)
# discover domains from :samen_core :ash_domains. Register Driftwood's domains so
# the gate scans the mounted CRM scope + the vertical Freight resources + the
# token-blind aggregate plane (T5.3 clause (b)).
config :samen_core, :ash_domains, [
  Driftwood.Crm,
  Driftwood.Billing,
  Driftwood.Support,
  Driftwood.Work,
  Driftwood.Calendar,
  Driftwood.Docs,
  Driftwood.Tags,
  Driftwood.Locations,
  Driftwood.SalesOps,
  Driftwood.Marketing,
  Driftwood.Freight,
  Driftwood.Aggregate,
  Driftwood.Operator,
  Driftwood.Chat,
  Driftwood.Primitives,
  Driftwood.Analytics,
  Driftwood.Automation,
  # T155 — verifiers must scan the mounted AI-plane resources too.
  Samen.AI.Domain
]

# WS-A A4/A5 — the kernel notification ENGINE (`Samen.Notifications.Engine`) wired to
# Driftwood's mounted Primitives resources (the ADR-014 SendWorker config convention:
# the kernel is mount-agnostic; the host names its concrete modules + repo). The
# realtime broadcast rides the samen_web PubSub broadcaster over `Driftwood.PubSub` —
# id-only envelopes (Invariant N1); each inbox subscriber re-reads per its OWN scope,
# so masking survives the realtime path by construction.
config :samen_core, Samen.Notifications.Engine,
  notification_module: Driftwood.Primitives.Notification,
  preference_module: Driftwood.Primitives.NotificationPreference,
  repo: Driftwood.Repo,
  broadcaster: Samen.Web.Notifications.PubSubBroadcaster

config :samen_web, Samen.Web.Notifications.PubSubBroadcaster, pubsub: Driftwood.PubSub

# WS-B B9 (AC-X1) — the product-analytics capture emitter (ADR-021):
#   * `Samen.Analytics.track/1` writes into Driftwood's `fae` ledger;
#   * every flag-variant assignment (ADR-020 §3.4 seam) flows to `track/1`.
config :samen_core, Samen.Analytics, product_event_resource: Driftwood.Analytics.ProductEvent
config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}

# ADR-010 — the well-known OPERATOR org id (the SaaS company's own org). The operator
# workspace (`/operator/accounts` · `/billing` · `/desk`) scopes to this org over its OWN book
# of business (tenant orgs as accounts) on the TENANT plane (PII of the SaaS's own customers
# CLEAR). `Samen.Web.Operator.org_id/1` resolves it: label → this app-env → single seeded row.
config :driftwood, operator_org_id: "0f000000-0000-4000-8000-0000000000aa"

config :ash, disable_async?: true

# F2 (ADR-031) — the launch AUTH gate, ARMED BY DEFAULT IN PROD (ADR-045 §2 V-F1, Option A).
# dev/test keep the query-param convenience identity (a `?org=<uuid>` is trusted, so the dogfood
# needs no login); prod derives the tenant actor ONLY from an authenticated session. This is
# EXPLICIT here AND enforced by the framework env-aware default + the `Samen.Web.TenantGate` boot
# guard (a prod host that is disarmed refuses to boot). `:auth_credentials` is empty by design —
# this PUBLIC repo commits no working password; the operator provisions credentials (phx.gen.auth
# / IdP for real). See docs/launch-checklist.md.
config :driftwood, auth_required?: config_env() == :prod
config :driftwood, auth_credentials: %{}

# T146 — the OPERATOR-ROLE authority resolver `Samen.Web.AuthGate` reads at the conn level (the
# `:require_authenticated_operator` pipeline every `/operator/*` scope pipes through). Called with
# the authenticated principal id; returns an operator role (`Samen.OperatorPlane.Actor.roles/0`)
# or `nil` (NOT an operator → refused). `Driftwood.Auth.operator_role/2` resolves a configured
# `:operator_roster` in prod, with a dev-only `:operator_admin` grant while `:auth_required?` is
# false. The `[:driftwood]` args list is the J3 PRODUCT-SCOPE carrier (ADR-044 §6.2/§6.3a #4) —
# a role granted here confers scope ONLY on :driftwood. Empty by design in this PUBLIC repo — a
# real launch provisions the operator roster.
config :driftwood, :operator_authority, {Driftwood.Auth, :operator_role, [:driftwood]}
config :driftwood, :operator_roster, %{}

# J3 — the FLEET-WIDE role read (`Samen.Fleet.Authz` `:fleet_authority` seam, ADR-044 §6.2/§6.3a #1).
# Returns %{scope => role} for the cockpit's tile gating. `:fleet_operators` grants the reserved
# `:fleet` cockpit scope (default empty ⇒ fail-CLOSED: no cockpit access until provisioned).
config :driftwood, :fleet_authority, {Driftwood.Auth, :fleet_roles, []}
config :driftwood, :fleet_operators, %{}

# J3 / Amendment 1 — the `:fleet_resolution` name-resolution + drill-in scope seam (ADR-044 §16.2).
# T83 ships the framework seam SHAPE (`Samen.Fleet.Resolution`, fail-closed to :none); the host
# resolver + the assignment resource it reads are T84 (operator ruling R-A). LEFT UNWIRED here so
# the seam fails CLOSED (every name masked, every scoped drill-in denied) until T84 provisions it.
# config :driftwood, :fleet_resolution, {Driftwood.Auth, :resolution_scope, [:driftwood]}

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
  },
  # WS-B B9 (AC-X1) / ADR-018: the DOMAIN-SOURCED revenue-movement rollup
  # (`mrr_revenue_rollup` — host-invariant table name, the demo B2 spec verbatim),
  # recomputed from Driftwood's OPERATOR-book movement ledger
  # (`dpv_subscription_event` — tenants' subscriptions to the SaaS, the operator
  # cockpit's revenue semantic; the tenant-plane `fbv` ledger is the brokerage's own
  # book and stays out of the cockpit rollup). Subject-free aggregate by
  # construction (period/kind grain); the erasure hook is the ledger-side
  # `subject_delete_sql` keyed on the movement's customer (AC-G7-7 stance).
  %{
    name: :revenue_rollup,
    source: :domain,
    table: "mrr_revenue_rollup",
    subject_delete_sql: "DELETE FROM dpv_subscription_event WHERE dpv_customer_id::text = $1",
    domain_table: "dpv_subscription_event",
    domain_subject_column: "dpv_customer_id",
    bounded_columns:
      ~w(mrr_id mrr_org_id mrr_period_month mrr_kind mrr_delta_cents mrr_count mrr_suppressed mrr_refreshed_at),
    rebuild_sql:
      {"DELETE FROM mrr_revenue_rollup",
       """
       INSERT INTO mrr_revenue_rollup
         (mrr_org_id, mrr_period_month, mrr_kind, mrr_delta_cents, mrr_count, mrr_suppressed, mrr_refreshed_at)
       SELECT
         dpv_org_id                              AS mrr_org_id,
         date_trunc('month', dpv_occurred_at)::date AS mrr_period_month,
         dpv_kind                                AS mrr_kind,
         COALESCE(SUM(dpv_mrr_delta_cents),0)::int AS mrr_delta_cents,
         COUNT(*)::int                           AS mrr_count,
         FALSE                                   AS mrr_suppressed,
         now()                                   AS mrr_refreshed_at
       FROM dpv_subscription_event
       GROUP BY dpv_org_id, date_trunc('month', dpv_occurred_at)::date, dpv_kind
       """}
  },
  # WS-B B9 (AC-X1) / ADR-021: the DOMAIN-SOURCED funnel/retention rollup
  # (`paf_product_event_rollup` — host-invariant table name, the demo B8 spec with
  # Driftwood's `fae` ledger as source). Erasure stance per design §4.4: `fae` has
  # NO subject column — `fae_actor_ref` is a per-subject HMAC pseudonym, so the
  # load-bearing erasure is key destruction; the `subject_delete_sql` + residue
  # scan key the pseudonym column against the RAW subject id and match zero rows
  # BY CONSTRUCTION (they exist to catch a sabotaged track/1 leaking a raw id).
  %{
    name: :product_event_rollup,
    source: :domain,
    table: "paf_product_event_rollup",
    subject_delete_sql: "DELETE FROM fae_product_event WHERE fae_actor_ref::text = $1",
    domain_table: "fae_product_event",
    domain_subject_column: "fae_actor_ref",
    bounded_columns:
      ~w(paf_id paf_org_id paf_kind paf_stage paf_cohort_week paf_week_offset paf_actor_count paf_suppressed paf_refreshed_at),
    rebuild_sql:
      {"DELETE FROM paf_product_event_rollup",
       """
       INSERT INTO paf_product_event_rollup
         (paf_org_id, paf_kind, paf_stage, paf_cohort_week, paf_week_offset,
          paf_actor_count, paf_suppressed, paf_refreshed_at)
       SELECT
         fae_org_id                                AS paf_org_id,
         'funnel'                                  AS paf_kind,
         CASE fae_event_name
           WHEN 'session.signed_in'   THEN 'signup'
           WHEN 'first_run.completed' THEN 'first_run'
           ELSE 'first_record'
         END                                       AS paf_stage,
         NULL::date                                AS paf_cohort_week,
         NULL::int                                 AS paf_week_offset,
         COUNT(DISTINCT fae_actor_ref)::int        AS paf_actor_count,
         FALSE                                     AS paf_suppressed,
         now()                                     AS paf_refreshed_at
       FROM fae_product_event
       WHERE fae_event_name IN ('session.signed_in', 'first_run.completed', 'record.created')
       GROUP BY fae_org_id, fae_event_name
       UNION ALL
       SELECT
         a.fae_org_id                              AS paf_org_id,
         'retention'                               AS paf_kind,
         NULL::text                                AS paf_stage,
         f.cohort_week                             AS paf_cohort_week,
         ((date_trunc('week', a.fae_occurred_at)::date - f.cohort_week) / 7)::int
                                                   AS paf_week_offset,
         COUNT(DISTINCT a.fae_actor_ref)::int      AS paf_actor_count,
         FALSE                                     AS paf_suppressed,
         now()                                     AS paf_refreshed_at
       FROM fae_product_event a
       JOIN (
         SELECT fae_org_id, fae_actor_ref,
                date_trunc('week', MIN(fae_occurred_at))::date AS cohort_week
         FROM fae_product_event
         WHERE fae_actor_ref IS NOT NULL
         GROUP BY fae_org_id, fae_actor_ref
       ) f
         ON f.fae_org_id = a.fae_org_id AND f.fae_actor_ref = a.fae_actor_ref
       WHERE a.fae_actor_ref IS NOT NULL
         AND ((date_trunc('week', a.fae_occurred_at)::date - f.cohort_week) / 7) BETWEEN 0 AND 4
       GROUP BY a.fae_org_id, f.cohort_week,
                ((date_trunc('week', a.fae_occurred_at)::date - f.cohort_week) / 7)
       """}
  }
]

# Reveal-grant + non_pii + verify repos (T1.6/T1.7): wire the Driftwood repo.
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, Driftwood.Repo
config :samen_core, :non_pii_repo, Driftwood.Repo
config :samen_core, :verify_repo, Driftwood.Repo
config :samen_core, :vault_repo, Driftwood.Repo

# T35 §4.7: reveal grants are a CLIENT of the T34 E3 approve/reject engine. Driftwood's
# own Approval resource (Samen.Approvals.Blueprint.define_approval/5,
# driftwood/lib/driftwood/approvals.ex) + the "pii_reveal" kind registered to
# Samen.Reveal.ApprovalHandler — Grants.approve/2 now routes its happy path through
# Samen.Approvals on this host.
config :samen_core, Samen.Approvals,
  approval_resource: Driftwood.Approvals.Approval,
  repo: Driftwood.Repo

config :samen_core, Samen.Approvals.Registry,
  kinds: %{
    "pii_reveal" => {:operator, Samen.Reveal.ApprovalHandler},
    # T155 (ADR-043 §6.3 D5): the AI support operator's human-gated send. Operator plane;
    # requester (the AI service principal) is never the decider (distinct-party by construction).
    "ai_support_reply" => {:operator, Samen.AI.SupportOperator.ReplyHandler}
  }

# T155 (ADR-043 §5.2 / §6.3): point the reusable AI-plane resources (mounted via
# Samen.AI.Domain above) at Driftwood.Repo so Prompt templates + support-reply drafts
# PERSIST in this host. Compile-time (the resources read it via compile_env, the
# tnt_record_repo / samen_ai_*_repo precedent in samen_core/config/config.exs).
config :samen_core, :samen_ai_prompt_repo, Driftwood.Repo
config :samen_core, :samen_ai_support_reply_draft_repo, Driftwood.Repo

# A1 (ADR-047 §4.1/§6): the agent-loop cursor resources ride the same Samen.AI.Domain
# mount — point them at Driftwood.Repo so run/turn rows persist in this host (the
# `samen_ai_prompt_repo` precedent above).
config :samen_core, :samen_ai_agent_run_repo, Driftwood.Repo
config :samen_core, :samen_ai_agent_turn_repo, Driftwood.Repo

# A5 (ADR-047 §6): the durable per-{org, definition} agent kill switch.
config :samen_core, :samen_ai_agent_kill_repo, Driftwood.Repo

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

# Oban: T2.1 canonical queue taxonomy. NO hand-listed `queues:` — B-OBAN: this
# host used to maintain its own list (the only one that registered :automation /
# :automation_timers, and like every other host it dropped :webhooks_in). config.exs
# runs before dependency modules load, so it cannot call the canonical
# `Samen.Jobs.default_queue_config/0` here; `Driftwood.Application` starts Oban via
# `Samen.Jobs.install_defaults/1`, which installs the whole taxonomy (plus the
# canonical cron) at boot. `mix samen.verify.oban_queues` gates the parity.
config :samen_core, Oban,
  repo: Driftwood.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

# ADR-039 §3.2 (T118) — the E1 engine's host-wired seam (the
# `Samen.Notifications.Engine` convention: config-resolved, opts override). The
# tenant automation builder (`Samen.Web.Automation.Reads`) never actually relies
# on this — it always passes explicit `workflow_module:`/`repo:` opts derived
# from the mount (opts win over config) — this line exists for host-level
# completeness (a future EventCapture-driven resource_event trigger needs it).
config :samen_core, Samen.Automation,
  workflow_module: Driftwood.Automation.Workflow,
  repo: Driftwood.Repo

import_config "#{config_env()}.exs"
