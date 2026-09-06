---
project: Accent
url: https://github.com/mirego/accent
category: Business and Collaboration
relevance: medium
verdict: Mature, actively-maintained Elixir TMS — not kernel material, but the concrete reference (and candidate fleet tool) for samen's open G24 i18n gap.
---

# 053 — Accent (mirego/accent)

## What the project is

Accent is a developer-oriented, self-hosted **translation management system** (think open-source Phrase/Crowdin) built by Mirego. Elixir ~1.19 / Phoenix backend, EmberJS SPA frontend, PostgreSQL, GraphQL (Absinthe) API powering both the UI and external integrations, plus a CLI for CI workflows. v1.30.5, BSD-3-Clause, ~1.5k stars, 919 commits, active maintenance (recent PRs/issues). Features: full translation history with rollback and audit trail, async translator/developer collaboration with per-string discussions, translation linting, machine-translation provider adapters (with encrypted provider config via cloak_ecto), AI/prompt features (`lib/prompts/`), webhooks/integrations (`lib/hook/`), multi-provider OAuth login (ueberauth: GitHub/GitLab/Google/Slack/Discord/Microsoft/OIDC), Docker/Heroku/K8s deployment, and a format-agnostic parser/serializer layer (`lib/langue/` — Document/Entry/ValueType abstractions with pluggable `formatter/` implementations for gettext, JSON, XLIFF, etc.). Heavy observability: full OpenTelemetry suite (phoenix, absinthe, ecto, oban, dataloader, bandit, tesla) + telemetry_ui + Sentry.

## What samen could adopt

1. **Accent as the fleet's translation workflow when G24 lands** — What: when samen tackles G24 (i18n/gettext; today USD+UTC hardcoded, no gettext), use Accent as the self-hosted TMS managing gettext catalogs across all samen-generated products, synced via its CLI in CI. Why it fits: samen is a fleet of products from one operator — exactly the "many repos, one translation team" shape Accent's CLI + GraphQL API serves; self-hosted matches samen's no-hosted-vendor posture, BSD-3 license is clean. Effort: M (ops integration + CI sync per product; no core code).
2. **`opentelemetry_oban`** — What: add the Oban OTel bridge to samen's existing opentelemetry(_api/_ecto) stack. Why it fits: samen leans hard on Oban (auto-revoke, EventCapture, agent loop) but its digest lists only ecto/api OTel; Accent demonstrates the full instrumented set in production. Verify it doesn't serialize job args (samen disables db_statement for the same reason — `pii_` tokens in spans). Effort: S.
3. **`telemetry_ui` for operator-cockpit metrics panels** — What: Mirego's self-hosted, Ecto-backed telemetry dashboard library. Why it fits: samen's fleet cockpit (ADR-044) and G11 metrics-egress work want in-app metrics views without Grafana; telemetry_ui is a small dep that renders telemetry_metrics into LiveView-friendly charts inside the first-party operator plane (consistent with the ash_admin rejection: first-party surfaces, library-assisted). Effort: S–M (evaluate label cardinality against `samen.verify.metric_labels`).
4. **Langue's format-abstraction pattern as the G24 export/import design reference** — What: a neutral Document/Entry/ValueType core with per-format parser+serializer pairs behind one behaviour. Why it fits: when samen builds i18n string import/export it should mirror this shape — one chokepoint module, format plugins, round-trip tested — matching samen's existing chokepoint + RFC-4180 CSV round-trip discipline. Effort: reference-only now; L if/when G24 builds it.
5. **Machine-translation provider adapter layout** (`machine_translations/provider/` + `translated_text.ex` struct) — What: a small behaviour-based provider registry returning a typed result struct. Why it fits: same shape as samen's `Samen.AI.Provider`/ESP adapters; useful as a worked example when adding an MT verb to the AI plane for G24 (route through the masking chokepoint, providers stay in an adapter package per INV-4). Effort: S (pattern lift, not code).

## What to ignore and why

- **Absinthe/GraphQL stack** (absinthe, dataloader, scrivener): samen's API surface is deliberately deny-by-default JSON:API; adopting GraphQL contradicts its contract-verifier posture (`samen.verify.api_contract`).
- **ueberauth + oauth2**: samen already standardized on `assent` for OIDC (ADR-035/identity spine); two OAuth stacks is pure liability.
- **cloak_ecto for secret encryption**: samen explicitly rejected Cloak-style column encryption (ADR-003) in favor of the KMS-driven vault with crypto-shred; Accent's approach is strictly weaker.
- **bamboo + bamboo_smtp email stack**: samen has fail-honest first-party ESP adapter packages (postmark/ses/resend) with a single Delivery chokepoint.
- **EmberJS frontend, canada/canary authz, httpoison/tesla, New Relic agent, sentry**: wrong frontend stack (samen is LiveView), weaker authz than Ash policies + OrgScope, HTTP clients conflict with req-only-in-adapters (INV-4), and vendor APM conflicts with the keyless/local-first observability posture.
- **Accent's core domain (movement/, lint/, hook/) as code to vendor**: it is a product, not a library; nothing exports as a Hex dep, and samen's distribution stance (ADR-033) means integration happens at the workflow boundary (CLI/API), not source level.
