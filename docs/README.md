# Docs index

The front door to `docs/`. Start with **Guides** if you're building; **Concepts** if you want
the mental model before the ADRs; **ADRs** for the load-bearing decisions; everything else is
process record — useful for archaeology, not required reading.

## Start here

- [Getting started](guides/getting-started.md) — zero to first feature: generate an app,
  tour it, add a scope + resource, bend the API contract and watch the gate flip.
- [Two-plane + masking concepts](concepts/two-plane-masking.md) — the tenant/operator plane
  model and the PII masking mechanism, explained before you read the ADRs that specify them.
- [ADR index](adr/README.md) — every accepted architecture decision, one line each.
- [Cookbook](guides/cookbook.md) — task recipes (add a scope, bend billing, ramp a flag, mount
  the operator cockpit, add a vaulted field, expose an API field, scaffold CRUD, run a
  crypto-shred, write a sabotage patch, mount surfaces in a fresh vertical).

## Guides (`docs/guides/`)

| Doc | What it is |
|---|---|
| [getting-started.md](guides/getting-started.md) | The generated-app-first tutorial: `mix samen.gen.app` → tour → add a scope/resource → bend + watch the gate flip. |
| [cookbook.md](guides/cookbook.md) | Task-shaped recipes, each citing the exact generator command / framework macro and the shipped file it's verified against. |
| [generators.md](guides/generators.md) | How `mix samen.gen.app` / `gen.scope` / `gen.resource` work, the `--modules` mountable-surface menu, the abbrev registry coupling, and the generator's own red paths. |
| [scope-authoring.md](guides/scope-authoring.md) | The fan-out template for authoring a new universal scope (or a vertical scope) — the pattern Identity established and every other scope copies. |
| [llm-grounding.md](guides/llm-grounding.md) | How an LLM agent (or a human driving one) authors a resource on Samen, grounded in the machine-readable catalog. |
| [gate-failures.md](guides/gate-failures.md) | Error message → which verifier fired → what it means → the fix, for every `samen.verify.*` task plus the drift check. |
| [byo-esp.md](guides/byo-esp.md) | Wiring real outbound email delivery through the fail-honest `Samen.Delivery.Adapter` boundary — Samen ships no first-party ESP integration. |

## Concepts (`docs/concepts/`)

| Doc | What it is |
|---|---|
| [two-plane-masking.md](concepts/two-plane-masking.md) | Extracts and consolidates the two-plane (tenant/operator) model and the PII masking mechanism from ADR-009/ADR-010 into one reader-facing explainer, meant to be read before those ADRs. |

## ADRs (`docs/adr/`)

33 accepted architecture decisions, indexed in [adr/README.md](adr/README.md) — grouped by
concern (vault/crypto-shred, scope packaging, the operator plane, then per-workstream:
WS-A/B/D/E, launch). Read the ADR itself before touching anything it governs.

## Runbooks (`docs/runbooks/`)

Operational procedures for a deployed Samen app.

| Doc | What it is |
|---|---|
| [break-glass.md](runbooks/break-glass.md) | The emergency reveal path for when the routine reveal would fail closed because the control-plane DB is unreachable. |
| [breach-notification.md](runbooks/breach-notification.md) | Contain → scope (via the hash-chained audit trail) → remediate a suspected unauthorized-access incident. |
| [secrets-rotation.md](runbooks/secrets-rotation.md) | Rotation procedures for the fail-closed secret set a deployed app reads at boot (`DATABASE_URL`, `SECRET_KEY_BASE`, KMS config, webhook HMAC secret). |
| [rollback.md](runbooks/rollback.md) | Reverting a bad release (code/config) via Fly — not a data-loss recovery path (that's `pitr-gameday.md`). |
| [pitr-gameday.md](runbooks/pitr-gameday.md) | The quarterly PITR / reverse-migration game-day drill script, plus the local-simulation evidence actually run in this environment. |
| [beam-introspection.md](runbooks/beam-introspection.md) | The wedged-process runbook: guarded remote console, `Process.info` + stacktrace, Oban/Ecto pool checkout handlers, the on-call decision tree. |
| [alerts.md](runbooks/alerts.md) | The alert catalog for a deployed app, with event-based fallbacks for the metrics-off default posture. |

## Gap discovery (`docs/gap-discovery/`)

The four lenses the roadmap (`saas-gap-roadmap.md`) was built from — each is "what's still
missing," not a build report.

| Doc | What it is |
|---|---|
| [builder-dx.md](gap-discovery/builder-dx.md) | The experience of a developer building a *new* SaaS product on Samen — gaps between `mix samen.gen.app` and a shipped feature. |
| [operator.md](gap-discovery/operator.md) | The experience of SaaS-company staff *running* a product on Samen — support, incidents, flags, revenue, analytics. |
| [end-user.md](gap-discovery/end-user.md) | The experience of a tenant's end-users actually using a product built on Samen, benchmarked against world-class B2B UX. |
| [harden-existing.md](gap-discovery/harden-existing.md) | Depth-vs-claim gaps, carried residues, and soft spots in the already-built foundry — not net-new modules. |

## Gate reports (`docs/gate-*.md`, `docs/gate-ws-*.md`)

Every phase/workstream's adversarial review, written up: acceptance criteria mapped to named
covering tests, suite counts, sabotages re-flipped. Chronological (phase gates first, then
per-feature and per-workstream gates):

`gate-0-report.md` … `gate-6-report.md` (the six phase gates) · `gate-ui-report.md` ·
`gate-samen-web.md` (ADR-009) · `gate-operator-plane.md` (ADR-010) · `gate-inherited-modules.md`
· `gate-crm-enrich.md` (ADR-011) · `gate-crossplane-chat.md` (ADR-012) ·
`gate-demo-coherence.md` (ADR-013) · `gate-ws-a.md` · `gate-ws-b.md` · `gate-ws-d.md` ·
`gate-ws-e.md` — the last four are the newest and cover the most ground.

## Workstream design + build-plan pairs (`docs/ws-a/`, `ws-b/`, `ws-d/`, `ws-e/`)

Each workstream folder has a `design.md` (the spec, ADR-grounded) and a `build-plan.md` (the
serialized, session-sized execution plan). WS-A = "Product Reality" (ADR-014/015/016), WS-B =
"Operator Cockpit v1" (ADR-017–021), WS-D = "Builder Joy" (ADR-022–024), WS-E = "Table Stakes
UX" (ADR-026–030).

## Build / verification reports (root of `docs/`)

Point-in-time reports from when a feature landed — read for "how was this actually built and
proven," not as ongoing reference:

- **samen_web extraction (ADR-009):** `samen-web-design.md`, `samen-web-build.md`, `rewire-driftwood.md`, `mount-reuse-report.md`.
- **Operator plane (ADR-010):** `operator-plane-build.md`, `mount-operator-driftwood.md`.
- **CRM enrichment (ADR-011):** `crm-detail-timeline.md`, `crm-marketing-outreach.md`, `crm-enrich-fixes.md`.
- **Cross-plane chat (ADR-012):** `012a-object-unfurl.md`, `012b-crossplane-chat.md`, `012c-mount-crossplane-chat-driftwood.md`.
- **Demo coherence (ADR-013):** `013-demo-coherence-build.md`, `seed-5-tenants.md`.
- **CDC / analytics:** `cdc-analytics-tier.md` (the optional ClickHouse mirror), `free-text-pii-residue.md` (the honest residue in freeform-text PII defense).

## Process / planning record

- [plan.md](plan.md) — the original v1 implementation plan (Phase 0–6), superseded in detail by everything shipped since but still the map of the phase structure.
- [saas-gap-roadmap.md](saas-gap-roadmap.md) — the ranked roadmap of what a SaaS needs that Samen under-serves; source for the WS-A/B/D/E workstreams.
- [claim-evidence.md](claim-evidence.md) — every load-bearing claim in the vision doc mapped to the test/verifier/probe that proves it (Gate 5's anti-invention audit).
- [risk-register-final.md](risk-register-final.md) — the Gate 6 refresh of the original risk register (R1–R15) against everything built.
- [extraction-retro.md](extraction-retro.md) — the Rule-of-Three retro on what Driftwood forced into the framework (feeds ADR-005/006/007).
- [launch-checklist.md](launch-checklist.md) — the bounded list of operator tasks between "the dogfood boots on localhost" and "a paying tenant logs in tomorrow."
- [observability-guide.md](observability-guide.md) — metrics/tracing/logging wiring and the documented operator TODO (real OTLP exporter).
- [next-session-brief.md](next-session-brief.md) — the paste-as-first-message brief for a fresh session continuing the build.

## Archive (`docs/archive/`)

`samen-foundry.html` / `samen-foundry.txt` — the original canonical combined vision doc
(2026-06-23) that `plan.md` and the early ADRs cite as source of truth. Superseded as a build
reference by the ADRs + shipped code, kept for provenance.

## Root-level references

- [../README.md](../README.md) — the repo's front door: the honest hero claim, the claim
  table, architecture, the verification story, getting started.
- [../index.html](../index.html) — the full design story as a standalone page.
