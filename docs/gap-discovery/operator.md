# Samen Gap Discovery — Operator Lens

> The experience of the SaaS company's staff **running** a product built on Samen —
> day-to-day (support, incidents, flags) and month-to-month (revenue, analytics, planning).
> Benchmark: Stripe dashboard · Amplitude/PostHog · ChartMogul · LaunchDarkly · Intercom ·
> Statuspage · Linear · Metabase.

## Executive assessment

Samen has built a genuinely differentiated **operator spine**: a real two-plane control
plane (operator-org-as-tenant on the tenant plane with PII clear + masked impersonation on
the operator plane), a token-blind cross-tenant aggregate with k-anon suppression, a
hash-chained tamper-evident audit + crypto-shred + WORM anchor, and a Stripe-mirror billing
data model. The **identity line** (own-book clear / downstream masked) is the crown jewel and
is proven both directions live and in tests.

But the operator lens exposes a consistent pattern: **the data models and privacy substrate
are world-class; the operational surfaces on top of them are thin or absent.** Samen today is
a governed *system of record* for an operator, not yet an operational *cockpit*. The operator
can see a portfolio MRR number and a list of accounts; they cannot yet answer "is this tenant
churning?", "did my last release regress error rates?", "which flag is live for whom?", "is
the platform up?", or "run this tenant's DSAR export." Critically, several of these gaps are
**uniquely cheap for Samen to fill** because the vault/CDC/audit/aggregate primitives already
exist — the missing piece is the read/compute/UI layer, not the hard governance plumbing. That
is the strategic edge: Samen can ship analytics, DSAR, revenue-ops, and status/SLA surfaces
that are *privacy-correct by construction*, which is exactly where Amplitude/ChartMogul/Intercom
are weakest for regulated B2B SaaS.

Two structural notes that shape every recommendation:

1. **"Designed vs built" is the dominant residue.** Observability (OTel/Prom/wide-events),
   the ClickHouse analytics tier, and real KMS/anchor wiring are all *seamed with operator
   TODOs*, not plumbed. This is honest and intentional, but it means the operator's analytics
   and monitoring story is essentially unbuilt above the projection/telemetry mechanisms.
2. **Framework-first still holds.** Every gap below should land in `samen_web` (or a new
   sibling lib) so all verticals inherit it; the vertical only proves it. Several gaps
   (analytics reads, revenue movements, health scores) are pure *read layers* over data that
   already exists — the cheapest, highest-joy class of work.

---

## Method / scoring

Per gap: **world-class · Samen today (cited) · delta · joy (H/M/L) · effort (S/M/L) ·
harden-vs-new**. Ranked by `(joy × frequency-of-need) / effort`, with a thumb on the scale for
gaps that Samen's architecture makes uniquely cheap or valuable (flagged **⚡EDGE**).

---

## The gaps

### G1. Revenue analytics — MRR movements, ARR, churn, cohorts ⚡EDGE
- **World-class (ChartMogul/Stripe):** MRR waterfall (new / expansion / contraction / churned /
  reactivation), ARR, net revenue retention, churn rate, LTV, ARPA, cohort retention grids,
  trials→paid conversion, forecast.
- **Samen today:** `Samen.Web.Operator.Reads.platform_billing/2` computes a single **snapshot
  MRR** (sum of active monthly-price subscriptions) + a dunning/past-due list
  (`samen_web/lib/samen/web/operator/reads.ex:85-108`). The billing data model is rich
  (Subscription with `trial_end`/`cancel_at`/`cancelled_at`, Invoice, Plan, Price —
  `samen_core/lib/samen/scopes/billing/blueprint.ex`). `demo/lib/demo/operator_dashboard.ex`
  gives `mrr/0` by tier with k-anon. **No movement decomposition, no time series, no churn, no
  cohorts, no NRR, no forecast, no RevenueRollup resource** (the one in the CDC doc is an
  example, not code).
- **Delta:** The entire ChartMogul surface. Snapshot MRR is ~10% of revenue analytics.
- **⚡ Why uniquely cheap:** every input exists in governed, non-PII billing columns; MRR
  movements are a deterministic diff over subscription/plan/price history. This is a **read +
  rollup layer**, not new plumbing. The k-anon aggregate actor + CDC projection make a
  privacy-safe cross-tenant revenue tier trivial to add.
- **Joy: H** (a founder checks MRR movements weekly/daily) · **Effort: M** · **harden**
  (extend `Operator.Reads` + a new `RevenueRollup`/movements module; optionally back it with
  the CDC tier). Needs subscription-change history — a small append-only ledger if not present.

### G2. Product analytics — event ingestion, funnels, retention, DAU/MAU ⚡EDGE
- **World-class (Amplitude/PostHog):** first-class event pipeline, funnels, retention curves,
  cohorts, DAU/MAU/stickiness, paths, feature adoption, per-tenant usage.
- **Samen today:** **Nothing at the product-analytics layer.** There is a `Billing.Usage`
  metered-usage resource and a wide-event telemetry schema
  (`samen_core/lib/samen/wide_event.ex`) but no product-event capture API, no funnel/retention/
  cohort compute, no DAU/MAU. The CDC projection (`samen_core/lib/samen/cdc/projection.ex`) is
  the *ideal warehouse feed* but no analytics queries are written and ClickHouse is unconnected.
- **Delta:** The whole product-analytics discipline — capture → warehouse → funnels/retention/
  cohorts → dashboards.
- **⚡ Why uniquely valuable:** Samen's token-blind CDC projection means product analytics can
  be built **PII-safe by construction** (events carry `vt_*` tokens, k-anon floors, erasure-
  for-free). That's a real moat vs Amplitude/PostHog, which are compliance headaches for
  regulated B2B. But it's the largest lift here.
- **Joy: H** · **Effort: L** (event API + ingestion + at least one funnel/retention compute +
  a dashboard; realistically needs the ClickHouse tier turned on for scale) · **new module**
  (an analytics/events scope + an operator analytics surface). Ship a Postgres-rollup MVP
  first; ClickHouse is the scale path.

### G3. Feature-flag evaluation engine + experiments ⚡EDGE
- **World-class (LaunchDarkly):** SDK-side evaluation, targeting rules (attributes/segments),
  deterministic % rollout, gradual ramp, kill-switch, A/B/n experiments with metric lift +
  significance, flag-usage insights.
- **Samen today:** `FeatureFlag` is a **config-row resource only**
  (`samen_core/lib/samen/scopes/primitives/blueprint.ex:470-539`) with `enabled`,
  `rollout_pct`, `stage`. **No evaluation function** (`flag?(name, actor) → bool`), no targeting
  rules, no deterministic bucketing, no variant assignment, no experiment analysis, and the demo
  gates nothing behind a flag. It stores flag metadata that nothing reads.
- **Delta:** The engine — the actual `evaluate/2` with hashed % bucketing + targeting +
  experiment variant assignment + a "does flag X move metric Y" analysis (which needs G2).
- **⚡ Why uniquely cheap:** deterministic bucketing (`hash(subject) % 100 < rollout_pct`) is a
  small pure function; the resource already carries the config. Targeting can key off the
  governed Identity/Billing columns (plan/tier). Experiment analysis composes with G1/G2.
- **Joy: H** (flags are touched constantly during rollout/incident) · **Effort: S** for the
  evaluation engine + gradual rollout; **M** if experiments/analysis included · **harden**
  (add `Samen.FeatureFlags.evaluate/2` + a targeting struct; operator flag-management UI).

### G4. Status page, health, SLA tracking & alerting ⚡EDGE
- **World-class (Statuspage/Pingdom + Datadog):** public status page, component uptime, incident
  timeline + subscriber comms, per-plan SLA (uptime %, response-time) tracking with breach
  alerts, error-rate/latency alerting on tenant-facing degradation.
- **Samen today:** `/healthz` returns a bare `ok`
  (`driftwood/lib/driftwood_web/...PageController`). Prometheus metric *definitions* +
  contention handlers exist (`samen_core/lib/samen/metrics.ex`,
  `metrics/contention_handlers.ex`) but the reporter/sink is unconnected (observability-guide.md
  §operator-TODO). **No status page, no uptime tracking, no SLA-per-plan tracking, no alerting,
  no incident comms, no operator system-health dashboard** (error rates / p95 / pool saturation).
- **Delta:** From "metrics defined" to "operator sees platform health + gets alerted + can post
  a status/incident." Support has an SLA *config* + breach worker for tickets
  (`support/sla_breach_worker.ex`) but no *service-level* (uptime) SLA.
- **⚡ Why partly cheap:** the metric contention handlers + wide-event schema already emit the
  signals; a status page over the tenant list + an operator health LiveView is a read/wire job.
  Incident comms compose with the existing notification primitive + audit chain.
- **Joy: H** (incidents are the operator's worst days) · **Effort: M** (health dashboard + basic
  status page + threshold alerting; uptime SLA tracking adds M) · **harden** for the health
  dashboard (wire existing telemetry) + **new** for status page / incident model.

### G5. Tenant lifecycle admin — provision / suspend / offboard / export ⚡EDGE
- **World-class:** self-serve tenant provisioning, suspend/resume (billing-driven or manual),
  offboarding with data export + retention window, hard delete, plan/entitlement admin, seat
  management — all audited.
- **Samen today:** The operator plane **reads** accounts/billing/desk but has **no tenant
  lifecycle mutations.** `Samen.OperatorPlane.Suspension` exists but suspends **operators**
  (breadth-budget), not **tenants** (`samen_core/lib/samen/operator_plane/suspension.ex`).
  There is masked impersonation (read/act-in-tenant) but no provision/suspend-tenant/offboard/
  export/delete operator actions. Accounts page has a non-wired "New account" button
  (`accounts_live.ex:63`).
- **Delta:** The entire tenant-lifecycle admin surface. This is table-stakes for running a
  multi-tenant SaaS and is currently missing.
- **⚡ Why uniquely cheap:** provisioning = seed the universal scopes for a new Org (the
  generator/seeds already do this); suspend = a status flag gate on the tenant scope + billing
  linkage; offboard-export composes with G8 (DSAR export) + crypto-shred (already built) for
  delete; every action naturally writes the existing audit chain.
- **Joy: H** (frequency: constant — onboarding, dunning-suspend, cancellations) · **Effort: M**
  · **harden** (new operator actions + Org lifecycle status + wire the audit chain).

### G6. Per-tenant health scores & account drill-down
- **World-class (Vitally/ChurnZero + Stripe):** composite health score (usage + billing +
  support + engagement), risk signals, account timeline, drill from portfolio → tenant.
- **Samen today:** Health is a **single derived pill from subscription status**
  (`reads.ex:386-391`: active→healthy, past_due→at_risk). The gate report itself flags the
  incoherence: Accounts health ignores past-due invoices that Billing shows
  (`gate-operator-plane.md` follow-up #1). No usage/support/engagement signals, no account
  drill-down page (Accounts links to impersonation, not to an account detail with history).
- **Delta:** A real multi-signal health model + an account detail/timeline surface.
- **Joy: M-H** (CSMs live here) · **Effort: S** (fold dunning + open-ticket count + usage into a
  score — inputs already computed in `Reads`) · **harden**. Low-hanging: fix the health/dunning
  coherence the gate already noted.

### G7. Usage-based / metered billing depth — rating, proration, tax, invoicing
- **World-class (Stripe Billing/Metronome):** usage aggregation → rating → invoice line items,
  proration on plan change, tiered/volume pricing, tax (Stripe Tax/Avalara), credit notes,
  trials/upgrades/downgrades flows, real payment-provider sync.
- **Samen today:** Data model is present but inert: `Billing.Usage` records quantities,
  `Invoice.line_items` is a jsonb bag, `SyncAdapter` is a **behaviour with a stub** — **no live
  Stripe calls, no rating engine (usage→invoice), no proration, no tax, no dunning state
  machine** beyond a past-due filter, no upgrade/downgrade/trial-conversion flows
  (`billing/blueprint.ex`, `billing/sync_adapter.ex`).
- **Delta:** From a Stripe-mirror schema to a working revenue engine. Rating + proration + tax +
  provider sync are each substantial.
- **Joy: M-H** (only if the product bills on usage; H for those, L for flat-rate) · **Effort: L**
  · **harden** the billing scope + a real `SyncAdapter` impl + a rating/proration engine.
  Sequence *after* G1 (movements) which is cheaper and higher-frequency.

### G8. DSAR self-serve & compliance reporting ⚡EDGE
- **World-class (OneTrust/Transcend):** self-serve data-subject access/export/erasure, audit-log
  export, retention-policy admin, SOC2 evidence packs, consent records.
- **Samen today:** **Erasure is built and excellent** (`samen_core/lib/samen/erasure.ex`:
  crypto-shred, key-first, idempotent, per-tier attestation report). Audit chain is verifiable
  (`audit_chain.ex`). But there is **no DSAR *access/export* path** (only erasure), **no
  operator-facing audit export UI**, **no retention-policy admin / TTL enforcement**, **no
  SOC2 evidence generation surface.** The primitives are kernel-only.
- **Delta:** The reporting/self-serve *surface* over strong primitives: a DSAR export (assemble
  a subject's governed data under grant), an audit-export/verify UI, a retention-policy resource +
  purge worker, a SOC2 evidence pack (chain-verify + erasure attestations + access logs).
- **⚡ Why uniquely valuable AND cheap:** Samen already *has* the hard parts (governed PII,
  reveal-under-grant, hash-chained audit, erasure attestations). Turning those into compliance
  *deliverables* is assembly + UI, and it's a strong differentiator for regulated buyers.
- **Joy: M** (frequency low but stakes very high — a DSAR deadline or SOC2 audit is a fire
  drill) · **Effort: M** · **harden** (DSAR export action + retention resource + audit/evidence
  export surface).

### G9. Support desk depth — CSAT flow, macros UI, KB, routing, FRT/CSAT metrics
- **World-class (Intercom/Zendesk):** macros/saved replies UI, knowledge base, assignment/
  routing rules, CSAT auto-send + reporting, first-response-time / resolution-time analytics,
  SLA-per-plan.
- **Samen today:** Solid data model: `Ticket` (SLA breach worker, priority, tags), `Macro`
  config rows, `Csat` resource, `Sla` config
  (`samen_core/lib/samen/scopes/support/blueprint.ex`). Operator desk **reads** tickets
  (`operator/desk_live.ex`). **Missing:** CSAT auto-send + CSAT/FRT *reporting*, macros *UI* /
  reply composition, **no knowledge base at all**, no assignment/routing rules, no SLA-per-plan
  tracking dashboard.
- **Delta:** The desk is a viewer, not a working helpdesk. Analytics (CSAT/FRT) and a KB are the
  biggest gaps.
- **Joy: M** · **Effort: M** · **harden** (extend the support scope + build reply/CSAT/reporting
  UI) + **new** for a KB resource.

### G10. Product feedback capture → triage → roadmap
- **World-class (Canny/ProductBoard/Linear):** in-app feedback capture, upvotes, triage,
  roadmap, changelog, close-the-loop notifications.
- **Samen today:** **Nothing.** No feedback resource, no roadmap, no changelog. (Support tickets
  are the closest proxy but are reactive, not product-feedback.)
- **Delta:** The whole feedback→roadmap loop.
- **Joy: M** · **Effort: M** · **new module** (a feedback scope + operator triage surface).
  Composes with the notification primitive for close-the-loop. Lower priority than the operational
  cockpit gaps.

### G11. Operator RBAC depth beyond the masking roles
- **World-class:** granular operator roles/permissions, scoped admin, teams, per-surface access,
  full audit of operator actions.
- **Samen today:** A **closed, thoughtful role set** exists —
  `operator_admin / operator_support / operator_readonly / operator_break_glass` with
  `may_read_operator_crm?` / `may_impersonate?` gates
  (`samen_core/lib/samen/operator_plane/actor.ex`, `operator_plane.ex`) + breadth-budget
  auto-suspend. This is *better than most* on the privacy/impersonation axis. **Missing:**
  finer-grained per-surface permissions (e.g. billing-admin vs support-only), custom roles, team
  management. This is a genuine strength with a modest depth gap.
- **Delta:** Custom/granular roles + per-surface authorization; the masking axis is already strong.
- **Joy: L-M** · **Effort: M** · **harden**. Lower priority — the existing model is sound for the
  core impersonation-safety concern.

### G12. Backlog / work-management for operators
- **World-class (Linear):** issues, sprints, cycles.
- **Samen today:** **Out of scope / absent.** The autonomous-loop `spec/` backlog is a build-time
  planning workspace, not a runtime operator surface.
- **Delta:** Full work-management.
- **Joy: L** (operators use dedicated tools; low value to build into the foundry) · **Effort: L**
  · **new**. **Recommend: do not build.** Note it explicitly as out-of-scope; integrate/link out
  instead. Listed for completeness.

---

## Ranking (joy × frequency ÷ effort, edge-weighted)

| # | Gap | Joy | Effort | Type | Note |
|---|-----|-----|--------|------|------|
| 1 | **G1 Revenue analytics (MRR movements/churn/cohorts)** | H | M | harden | ⚡ inputs exist; read+rollup layer |
| 2 | **G3 Feature-flag evaluation engine + experiments** | H | S/M | harden | ⚡ engine is a small pure fn over existing config |
| 3 | **G5 Tenant lifecycle admin (provision/suspend/offboard/export)** | H | M | harden | ⚡ table-stakes; composes with seeds+shred+audit |
| 4 | **G4 Status/health/SLA + alerting** | H | M | mixed | ⚡ telemetry emitted; needs sink+dashboard+status page |
| 5 | **G6 Per-tenant health scores + account drill-down** | M-H | S | harden | inputs already computed; fixes gate-noted incoherence |
| 6 | **G2 Product analytics (funnels/retention/DAU-MAU)** | H | L | new | ⚡ PII-safe-by-construction moat; biggest lift |
| 7 | **G8 DSAR self-serve + compliance reporting** | M | M | harden | ⚡ hard parts built; assembly+UI over erasure/audit |
| 8 | **G7 Usage billing depth (rating/proration/tax/sync)** | M-H | L | harden | only if product bills on usage; after G1 |
| 9 | **G9 Support depth (CSAT/FRT reporting, macros UI, KB, routing)** | M | M | mixed | desk is a viewer today |
| 10 | **G10 Product feedback → roadmap** | M | M | new | composes with notifications |
| 11 | **G11 Operator RBAC granularity** | L-M | M | harden | existing role model already strong |
| 12 | **G12 Operator backlog/work-mgmt** | L | L | new | recommend out-of-scope; link out |

---

## Recommended first operator workstream

**"Operator Cockpit v1" = G1 + G6 + G3**, in that order, as one gated workstream:

1. **Revenue movements + per-tenant health** (G1 + G6) — a `RevenueMovements`/`RevenueRollup`
   module and a multi-signal health score, both pure read/rollup layers over already-governed
   billing + support + usage columns, surfaced on a real operator dashboard with drill-down.
   Highest joy-per-effort; fixes the health/dunning incoherence the operator-plane gate already
   flagged; needs no new substrate.
2. **Feature-flag evaluation engine** (G3) — `Samen.FeatureFlags.evaluate/2` with deterministic
   bucketing + targeting over governed Identity/Billing attributes + a flag-management UI. Small,
   framework-level, immediately useful in every rollout.

This trio maximizes the strategic edge: it turns Samen's existing governed data into the
operational cockpit that's missing, entirely framework-first, without needing ClickHouse, real
KMS, or a payments-provider integration first. **G5 (tenant lifecycle)** is the strongest
follow-on (table-stakes), then **G4 (status/health/SLA)** to close the incident story, then
**G2 (product analytics)** as the moat play once the ClickHouse tier is warranted.

### Standout strategic note
The recurring pattern — **strong governed substrate, thin operational surface** — is an
opportunity, not just a debt. Because the vault, CDC projection, k-anon aggregate, hash-chained
audit, and crypto-shred already exist, Samen can ship *revenue analytics, product analytics,
DSAR/compliance reporting, and status/SLA* surfaces that are **privacy-correct by construction**.
That is precisely the ground where the incumbent operator tools (ChartMogul, Amplitude, Intercom,
OneTrust) are weakest for regulated multi-tenant B2B — so filling these operator gaps is also
Samen's clearest differentiation, not merely catch-up.
