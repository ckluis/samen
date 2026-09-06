---
project: Mindwendel
url: https://github.com/b310-digital/mindwendel
category: Business and Collaboration
relevance: low
verdict: A polished but single-purpose AGPL Phoenix LiveView brainstorming app; a few UX/config patterns worth noting, no code or architecture samen should adopt.
---

# 056 — Mindwendel

## What the project is

Mindwendel (b310-digital, AGPL-3.0, ~137 stars, active) is a self-hosted collaborative
brainstorming tool built on Elixir/Phoenix LiveView + PostgreSQL. Anonymous participants
(no registration; optional usernames) create, upvote, comment on, label, and drag-and-drop
ideas into lanes in real time via LiveView websockets. Extras: URL previews, HTML/CSV
export, gettext i18n (de/en/it), S3-compatible encrypted file attachments, optional
OpenAI-compatible AI idea generation with hourly/daily token caps, and default 30-day
auto-deletion of brainstormings for GDPR. Ships with Docker/Docker Compose and env-var
configuration; stateless behind a reverse proxy.

It is an end-user application, not a framework or substrate. There is no multi-tenancy,
no operator plane, no auth spine, no audit story — its privacy model is "ephemeral data +
auto-delete," the opposite end of the spectrum from samen's vault/masking/crypto-shred
governance.

## What samen could adopt

Nothing structural. The license (AGPL-3.0 vs samen's MIT) rules out lifting code entirely;
only ideas are portable, and most are things samen already has in stronger form (retention
subsystem vs a TTL job; AI budgets/cost caps vs token-limit env vars; files chokepoint +
vault vs an encryption-key env var; feature_flags vs MW_FEATURE_* toggles). Three small
pattern-level notes:

1. **Anonymous/ephemeral participation as a product pattern** — invite-by-URL sessions
   with zero registration and optional display names. Why it fits: a samen vertical doing
   lightweight external collaboration (e.g., a client-facing intake or voting board) could
   model "guest actors" without touching the identity spine — relevant to the ADR-029/031
   BYO-auth seam. Effort: M (new actor class must compose with OrgScope/PiiResolution;
   pattern only, no code reuse).

2. **TTL-by-default as a marketed compliance feature** — "deleted after N days" surfaced
   as a headline GDPR claim, configurable via one env var. Why it fits: samen's retention
   subsystem already does the mechanics; the takeaway is packaging — expose a per-scope
   `retention_days` knob in the generator and say it in the compliance-story doc. Effort: S.

3. **Per-window AI token throttles as plain config** (hourly + daily caps, reset hour,
   request timeout). Why it fits: ADR-047 budgets/cost caps exist; a simple
   window-based token throttle at the AI chokepoint is a cheap additional guardrail and
   maps cleanly to operator-plane config. Effort: S.

## What to ignore and why

- **All code** — AGPL-3.0 is incompatible with samen's MIT posture; ADR-033 keeps
  distribution in-monorepo anyway.
- **Its privacy model** — delete-everything-after-30-days is a substitute for governance,
  not an implementation of it; samen's vault/reveal/audit/crypto-shred already answers the
  same regulatory pressure at a much higher bar.
- **LiveView collaboration mechanics** — standard PubSub/LiveView fan-out; samen_web's
  chat surface already demonstrates cross-plane realtime with masking-aware unfurls, which
  is strictly harder than this app's use case.
- **S3 "encrypted attachments"** — a single symmetric key in an env var
  (`VAULT_ENCRYPTION_KEY_BASE64`); samen's per-subject KMS-held keys and files
  quarantine chokepoint are categorically stronger. Nothing to learn for the open
  `Storage.S3` follow-on beyond what samen already planned.
- **AI integration approach** — raw OpenAI-compatible calls from app code; no masking
  chokepoint concept, exactly the pattern samen's EG2/token-blind design forbids.
