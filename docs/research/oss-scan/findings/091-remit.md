---
project: Remit (ex-remit)
url: https://github.com/barsoom/ex-remit
category: Developer Tools
relevance: low
verdict: A small single-tenant Phoenix LiveView internal tool with no Ash, multi-tenancy, or PII/billing story — architecturally distant from samen's foundry concerns, but its dev-tooling deps (mix_audit, dialyxir, tz, opentelemetry+sentry setup) are cheap, concrete borrows.
---

## What the project is

Remit is barsoom's self-hosted, internal "commit-by-commit code review" web app — the fourth iteration of an in-house tool (earlier versions were Rails + AngularJS/MessageBus/Elm), rebuilt in 2020 in Phoenix LiveView to dogfood LiveView + Tailwind. It ingests GitHub webhooks (commits, commit comments), shows a real-time commit/review queue via LiveView, and links out to GitHub's own UI for the actual diff/comment interaction (GitHub disallows iframing, so it recommends running Remit and GitHub side-by-side via Fluid.app). Access control is a single shared `auth_key` URL parameter per team, not a real auth/identity system. It's deployed to Heroku with a release-phase migration step, `SECRET_KEY_BASE`/`AUTH_KEY`/`WEBHOOK_KEY`/`GITHUB_API_TOKEN` env vars, and configurable data retention (`REMOVE_DATA_OLDER_THAN_DAYS`). Stack is plain Phoenix + Ecto + Postgres — no Ash anywhere, no multi-tenant data model, no billing, no PII vaulting. ~50 GitHub stars, still actively pushed (commits as recent as today), MIT-licensed.

## What samen could adopt

- **`mix_audit` dependency-vulnerability scanning in CI** — why it fits: samen's `ci.sh` already runs a heavy gate (spikes/kernel/generative probes/sabotage); a supply-chain CVE scan is a cheap, orthogonal addition that catches a class of risk none of samen's 20 verifier tiers currently cover. effort: S.
- **`dialyxir` (Dialyzer) in the dev/CI toolchain** — why it fits: samen's kernel leans hard on declared Ash types and chokepoint contracts (`Samen.Type.VaultField`, `%MaskedPayload{}`); static success-typing analysis is a natural complement to the existing sabotage/verifier discipline and would catch contract-shape bugs the runtime verifiers don't. effort: M (first Dialyzer PLT build + fixing initial warnings across `samen_core`/`samen_web` is nontrivial at this codebase size).
- **`tz` for real timezone handling** — why it fits: samen's own gap register (G24) flags USD+UTC hardcoded, no i18n/timezone support, as an open P2 gap; `tz` is a lightweight, no-NIF-free-alternative-considered library worth a look when that workstream is picked up. effort: S (evaluation) / M (wiring through catalog + rich `Type` for timestamps).
- **`git_hooks` for pre-push local gating** — why it fits: samen already runs a heavy foreground `ci.sh`; a pre-push hook that runs a fast subset (credo/format/dialyzer) locally before a slow CI gate is a small DX improvement, not a new capability. effort: S.
- **Sentry + OpenTelemetry wiring pattern** — samen already has `opentelemetry(_api/_ecto)` pinned with `db_statement` disabled (to keep `pii_` tokens out of spans); Remit's mix.exs shows a full working `opentelemetry_cowboy` + `opentelemetry_phoenix` + `sentry` combo, useful as a reference wiring example if samen adds Sentry-style error tracking to the generated app template. effort: S.

## What to ignore and why

- **The core product (commit-by-commit review UI/webhook ingestion)** — no domain overlap with a SaaS foundry; it's a narrow internal tool for one specific engineering workflow, not a pattern samen's verticals (freight, vet clinic, etc.) would ever need.
- **Auth model** — a single shared `auth_key` URL param is explicitly weaker than anything samen would ship; samen already has a full identity spine (OIDC, TOTP, sessions, org-scoped RBAC) that supersedes this by every measure. Nothing to borrow here, and adopting it would be a regression.
- **Data model / Ecto usage** — plain Ecto schemas with no policy/authorization layer, no multi-tenant org-scoping, no vaulting; not a useful architectural reference given samen's kernel already solves this at a much deeper level (Ash policies, OrgScope, vault chokepoints).
- **Heroku deploy specifics** — samen's ops target (Fly, per ADR references) differs from Heroku buildpacks/dynos; the deploy mechanics don't transfer.
- **LiveView real-time patterns for the commit feed itself** — samen_web already has its own two-plane, catalog-driven, masking-aware LiveView chat/notification surfaces that are considerably more sophisticated (cross-plane realtime with PII masking baked in); Remit's simple PubSub-driven commit list doesn't add anything samen doesn't already have.

Note: research for this evaluation was done directly (repo metadata via `gh api`, README via WebFetch, `mix.exs` deps via `gh api`) rather than via spawned subagents — no Agent/Task tool was available in this environment, and the project's low architectural relevance (confirmed on first pass: no Ash, no multi-tenancy, no PII/billing surface) meant a single-pass shallow evaluation was sufficient per the calibration guidance.
