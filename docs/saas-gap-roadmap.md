# Samen SaaS Gap Roadmap

**Mission:** Samen is a meta-harness that makes building AND running a SaaS a joy. It has the
close-the-first-contract 80%. This roadmap ranks everything a SaaS needs that Samen is missing
or under-serves, and sequences gated, framework-first workstreams to fill it.

**Method (Phase 0 Discovery, 2026-07-09):** four parallel deep-dive audits, full evidence in
`docs/gap-discovery/`:
- [builder-dx.md](gap-discovery/builder-dx.md) — the builder's journey
- [operator.md](gap-discovery/operator.md) — running the SaaS
- [end-user.md](gap-discovery/end-user.md) — the tenant's users
- [harden-existing.md](gap-discovery/harden-existing.md) — depth-vs-claim audit of what's built

**North star for every item:** does this make building or running a SaaS on Samen more of a joy,
and does it level up the framework (samen_web / kernel) so every vertical inherits it?

---

## Headline diagnosis (all four lenses converge)

1. **The security/governance kernel is as deep as the gates claim.** Crypto-shred, two-plane
   masking, token-blind aggregates, hash-chained audit, verifier gate + destruction oracle,
   the generator's correct-by-construction output — all world-class with honest evidence.
2. **The product surfaces on top are demo-deep.** Only ~6 of ~30 LiveViews handle events;
   "New contact" buttons are unwired; marketing "sent" email goes nowhere (no-op adapter that
   marks `delivered`); Stripe sync is a stub; flags/search/files are resources with no engine;
   no pagination anywhere. A real first tenant hits a wall in week one on nearly every product
   feature — each an honestly-labeled stub, not a breach, but a wall nonetheless.
3. **Builder DX is scaffolding lag, not architecture lag.** Everything the verticals do thinly
   at runtime (pawchart: full UI in ~12 router lines), the generator doesn't emit — builders
   hand-copy web/API/seeds/observability/deploy from demo/pawchart. Near-zero
   time-to-gate-green masks a large time-to-first-visible-feature.
4. **One claim-integrity item:** the "provably non-PII" CDC/aggregate classifier is a
   name+type heuristic + human allowlist — benign-named freeform strings (e.g. `drv_notes`)
   pass as `:metadata` and mirror to ClickHouse. The mechanism is out of step with the
   load-bearing claim. (harden H-2)
5. **The strategic edge:** because governance plumbing already exists, analytics, DSAR,
   status/SLA, and delivery can ship *privacy-correct by construction* — exactly where
   incumbent operator tools are weakest for regulated B2B.

Three memory-carried residues were confirmed already fixed (Workspace header, F4.2, partial
F4.3) — do not re-scope.

---

## Ranked gap register (deduped across lenses)

Tiers: **P0** = week-one wall or claim-integrity · **P1** = joy multiplier, near-term ·
**P2** = important, sequence later. Layer: kernel / web (samen_web) / gen (generators+docs) /
op-todo (human operator task).

| # | Gap (cluster) | Lens | Delta in one clause | Joy | Effort | Layer | Tier |
|---|---|---|---|---|---|---|---|
| G1 | **Real CRUD + list ergonomics** | end-user, harden | Most LiveViews read-only; no pagination/sort/filter/bulk anywhere incl. JSON:API (unbounded reads) | H | M | web+kernel | ✅ shipped (WS-A) |
| G2 | **Delivery engine + notifications inbox** | end-user, harden, operator | Marketing send is a no-op stub; `Notification` resource has no inbox/engine/prefs; SLA breach is a silent state flip; kernel `Send.:create_checked` hardcodes `msp_suppression` | H | M | kernel+web | ✅ shipped (WS-A) |
| G3 | **PII classifier: heuristic → mechanism** | harden | "Provably non-PII" is name/type heuristic + allowlist; freeform strings leak to the aggregate plane by naming | H (trust) | M | kernel | ✅ shipped (WS-A phase A1) |
| G4 | **Generator catch-up (web/API/seed scaffolds)** | builder | gen.app emits headless data layer only; no resource/scope generators; JSON:API + seeds + observability wiring all hand-copied | H | M | gen | P0 |
| G5 | **Onboarding + empty states + first-run** | end-user | Inconsistent empty states, no first-run, no in-app sample data | H | M | web | ✅ shipped (WS-A) |
| G6 | **Feature-flag evaluation engine** | operator, harden | Flags are config rows nothing evaluates; no bucketing/targeting/rollout; experiments absent | H | S/M | kernel+web | P1 |
| G7 | **Revenue analytics (MRR movements)** | operator | Snapshot MRR only; no movements/churn/cohorts/NRR | H | M | web | P1 |
| G8 | **Tenant lifecycle admin** | operator | No provision/suspend/offboard/export/delete actions from the operator plane | H | M | web+kernel | P1 |
| G9 | **Global search** | end-user, harden | PII-safe index registry exists; zero search action / ⌘K / UI | H | M | kernel+web | P1 |
| G10 | **Getting-started tutorial + cookbook + README** | builder | 3 reference guides, no zero-to-feature walkthrough, no gate-failure index | M-H | S | gen | P1 |
| G11 | **Status/health/SLA + alerting** | operator | Metrics defined but unwired; bare `/healthz`; no status page/alerts/health dashboard | H | M | web+gen | P1 |
| G12 | **Product analytics over CDC** | operator | No event capture/funnels/retention; vault-excluded CDC projection is an ideal unused feed — privacy-correct-by-construction moat | H | L | new (web) | P1 |
| G13 | **Billing depth: Stripe sync + usage rating** | operator, harden | Stripe-mirror schema inert; SyncAdapter stub; no rating/proration/tax | M-H | L | kernel+op-todo | P1 |
| G14 | **Files engine** | end-user, harden | Metadata resource only; no storage adapter/upload/preview | M/H | M | kernel+web | P1 |
| G15 | **Import/export (CSV mapper)** | end-user | None at any granularity; catalog-as-data makes a generic mapper feasible; export = highest-risk mask-by-omission vector | M/H | M | web | P1 |
| G16 | **Deploy story (Fly/Neon templates)** | builder | Zero deploy artifacts; all carried as operator TODOs | H | M | gen+op-todo | P1 |
| G17 | **Per-tenant health scores + drill-down** | operator | Health is a single subscription-status pill | M-H | S | web | P1 |
| G18 | **Self-serve settings (profile/2FA/sessions/API keys)** | end-user | Models exist, no screens, no `/settings` route | M | M | web | P2 |
| G19 | **DSAR self-serve + compliance reporting** | operator | Erasure/audit built; no DSAR export, retention admin, SOC2 evidence surface | M | M | web | P2 |
| G20 | **Responsive/mobile + perf polish** | end-user | Zero `@media`; no `assign_async`/`stream`/skeletons | M/H | M | web | P2 |
| G21 | **Support desk depth (CSAT/macros/KB/routing)** | operator, harden | Desk only reads; SLA reporting absent | M | M | web | P2 |
| G22 | **Agent-grounding packaging (MCP, json diagnostics, reusable eval)** | builder | Differentiator built but unpackaged for builders | M-H | M | gen | P2 |
| G23 | **Product feedback → roadmap** | operator | Absent entirely | M | M | new | P2 |
| G24 | **i18n / timezone / currency** | end-user | USD + UTC hardcoded, no gettext | M | M | web | P2 |
| G25 | **A11y (kit-level)** | end-user | 3 aria/role/alt occurrences total; kit fix = fleet leverage | L-M | M | web | P2 |
| G26 | **Test/red-path scaffolds for verticals** | builder | 4 mandated test files hand-copied per resource | M | M | gen | P2 |
| G27 | **Misc kernel residues** | harden | Webhook A6 over-strict guard; rollup cron ADR-007; abbrev-registry tax ADR-006; Oban multi-node concurrency | L-M | S-M | kernel+op-todo | P2 |
| G28 | **Operator RBAC granularity / backlog tooling** | operator | Closed role set fine for now; backlog = link out | L | M | web | P3 |

Human-operator TODOs (not agent work, tracked for completeness): real Neon PITR drill, AWS
KMS+DynamoDB+S3-ObjectLock, ClickHouse ClickPipes activation, Stripe live keys, Fly account.

---

## Workstream candidates (gated, framework-first, one at a time)

### WS-A — "Product Reality" (G1 + G2 + G5, riders G3-adjacent masking tests) ← RECOMMENDED FIRST
> **✅ SHIPPED 2026-07-13** — all 5 phases (A1–A5) gated GO; workstream-wide adversarial gate GO: `docs/gate-ws-a.md`.
Turn the read-only demonstration into a product a tenant can actually use:
real CRUD on every mounted LiveView (kit-level form/table primitives so verticals inherit),
pagination/sort/filter/bulk as kit defaults + JSON:API `default_limit`, a real outbound email
delivery adapter (fix the kernel Send no-op + `msp_suppression` hardcode), in-app notifications
inbox + prefs fed by a delivery engine (SLA breach and system events flow into it), consistent
empty states + first-run.
**Why first:** every lens hits this wall; it is the difference between "gorgeous demo" and
"SaaS you can run"; nearly all of it lands in samen_web/kit so both verticals inherit; it
unblocks WS-B (operator surfaces need real data flow to be honest).
**New PII surfaces requiring per-plane masking tests:** CRUD write forms, notifications inbox.

### WS-B — "Operator Cockpit v1" (G7 + G17 + G6 + G12 seed)
Revenue movements (MRR waterfall/churn/cohorts), per-tenant health drill-down, feature-flag
evaluation engine with targeting/rollout, and the first product-analytics events over the
vault-excluded CDC projection. Pure read/compute layers over already-governed data — the
privacy-correct-by-construction moat.

### WS-C — "Truth & Trust" (G3 + G19 + G27 selections)
> Carry from A1 gate (INFO-1): a host custom TYPE self-classifying `samen_pii_class/0 => :non_pii`
> bypasses the two-reviewer `non_pii!` clearance discipline (single-party escape hatch,
> `classification.ex:90`). No kernel type or vertical uses it today; close or reviewer-gate it here.
Replace the non-PII heuristic with a real mechanism (default-deny freeform strings from the
aggregate plane; explicit provable allowlist with verifier backing), DSAR self-serve export,
retention admin. Small surface, protects the load-bearing claim.
**Note:** G3 is claim-integrity — if WS-A is chosen first, G3 ships as a rider inside WS-A's
gate (it is kernel-scoped and independent) or immediately after. It must not wait two
workstreams.

### WS-D — "Builder Joy" (G4 + G10 + G16 + G26)
Push the proven thin-mount patterns up into generators (web/API/seed/observability scaffolds,
resource/scope gen), zero-to-feature tutorial, gate-failure index, Fly/Neon deploy templates.
Highest leverage once the surfaces being scaffolded (WS-A) are real — generating today's
read-only patterns would scaffold the wrong thing.

### WS-E — "Table Stakes UX" (G9 + G14 + G15 + G18 + G20)
Search engine + ⌘K, files engine with storage adapter, CSV import/export mapper (mask-by-
omission red-paths mandatory), self-serve settings, responsive pass.

**Sequencing logic:** A → (C rider) → B → D → E, revisiting rank after each gate. D
deliberately follows A so generators emit the *real* patterns.

---

## Non-negotiable riders on every workstream
- Framework-first: capability lands in samen_web (or kernel where sanctioned); verticals only prove it.
- Masking by construction: every new PII surface ships per-plane masking tests (six flagged:
  notifications inbox, CRUD forms, file preview, export, profile self-edit, search results).
- Fail-closed proof: every guarantee ships a passing test + red-path must-fail test,
  anti-tautology probed; verifier gate + destruction oracle stay green.
- Adversarial gate per phase, findings fixed in-phase; commit each gated milestone; all suites
  + every ci.sh green before/after; ADRs for design decisions.
