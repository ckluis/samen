---
project: Codex Pooler
url: https://github.com/icoretech/codex-pooler
category: Agent Platforms With License Warnings
relevance: medium
verdict: Mature Elixir/Phoenix AI-gateway with strong operator-plane patterns (per-key observatory, metadata-only logging, HMAC-digest tokens, PubSub settings cache) worth imitating — but Elastic-2.0 forbids code reuse and its core mission (pooling Codex accounts) is out of scope for samen.
---

# 011 — Codex Pooler

## What the project is

Codex Pooler is a self-hosted **Elixir/Phoenix** gateway that pools multiple upstream OpenAI Codex accounts behind stable "Pool API keys" so teams and agents can share capacity. Active and mature: ~152 stars, ~2,094 commits, semantic-versioned releases, docs site (docs.codex-pooler.com), Docker Compose + Helm chart deployment.

Key mechanics:
- **Eligibility-aware routing**: requests are routed to upstream accounts based on model support, quota evidence, account health, and pool policy; "prompt-cache locality" pins a session to the same upstream via transient keys; resumable Codex sessions over websockets.
- **Three runtime surfaces**: native `/backend-api/codex`, an intentionally-narrow OpenAI-compatible `/v1`, and `/mcp` (operator MCP tokens are read-only, metadata-only).
- **Operator dashboard** (LiveView): pool management, API key generation/rotation, request logs, audit logs, alerts, saved-reset/quota visibility; a per-key "Observatory" gives API-key holders a read-only view of their own usage.
- **Privacy-first observability**: stores routing metadata + latency only — no prompts, files, or raw tokens; upstream credentials encrypted at rest with versioning; TOTP for operator 2FA; metrics bearer token stored only as a keyed HMAC digest.
- **Ops**: Postgres + Oban; K8s deployment split into web / worker / scheduler / migration roles; DB-managed Instance Settings with a settings cache invalidated via PubSub; runtime ingress firewall; SMTP operator notifications.
- **License**: Elastic-2.0 — source-available, NOT OSI-approved. Samen (MIT) must not vendor or port code; patterns and architecture ideas only.

## What samen could adopt

1. **Per-key "Observatory" (tenant-facing usage view)** — a read-only, self-serve dashboard scoped to a single API key showing that key's own request counts, latency, and quota posture. *Why it fits*: directly extends samen's "tenant-readable audit" ethos to the API/AI plane; a natural G22 (agent-grounding packaging) and operator-cockpit-v2 feature — tenants see what their keys did without operator involvement. *Effort*: **M** (new read-scoped LiveView surface over existing wide-event/metrics data; policy work is samen's bread and butter).

2. **Metadata-only AI request logging discipline** — log routing metadata, model, token counts, latency; structurally never persist prompt bodies in request logs. *Why it fits*: samen already has masked AI egress (ADR-043) and transcript retention with erasure envelopes (ADR-046/047); adopting an explicit "AI request-log = metadata only" invariant (with a verifier tier, e.g. `samen.verify.ai_log_shape`) closes the gap between transcripts (governed, erasable) and operational logs (should be content-free by construction). *Effort*: **S** (mostly codifying + verifying an existing posture).

3. **HMAC-digest storage for bearer tokens** — store API keys / metrics tokens only as keyed HMAC digests, never encrypted-recoverable. *Why it fits*: samen's operator MCP tokens and any future tenant API keys should be non-recoverable secrets (show-once at mint), which is stronger and simpler than vault-encrypting them; complements the crypto-shred story since there is nothing to shred. *Effort*: **S**.

4. **DB-managed instance settings + PubSub cache invalidation** — operator-editable runtime settings persisted in Postgres, served from an ETS/cache layer invalidated via Phoenix.PubSub, so config changes are live without redeploys. *Why it fits*: samen's feature_flags cover boolean gating, but operator-plane knobs (rate limits, AI budgets, retention windows) currently lean on env/config; this pattern fits the two-plane model (operator plane writes, both planes read) and the fleet-directive story. *Effort*: **M**.

5. **Provider health + quota-evidence tracking on AI adapters** — track per-provider/per-credential health, observed quota state, and reset windows; feed them into routing/backoff decisions. *Why it fits*: samen's AI kernel has budgets/cost caps (ADR-047) but a single-adapter posture; as the fleet grows, recording "quota evidence" per provider credential and degrading honestly (fail-honest, never silent retry-storm) is a good ADR-sized extension of `Samen.AI.Provider`. *Effort*: **M**.

6. **K8s role split reference (web/worker/scheduler/migration)** — a working example of an Elixir release deployed as four distinct roles with an external Postgres. *Why it fits*: samen's production deploy (Fly, WS-L) is an operator TODO; this is a concrete, current reference for splitting Oban workers/cron from web nodes. *Effort*: **S** (reading reference material when WS-L lands, not code).

## What to ignore and why

- **The core mission (Codex/ChatGPT account pooling)** — multiplexing consumer AI accounts behind shared keys is out of samen's scope, ToS-gray, and contradicts samen's fail-honest, governance-first posture. Samen talks to providers via first-party adapters with real keys.
- **OpenAI-compatible `/v1` shim and the 15+ client integration matrix** — samen is not an inference gateway product; its AI surface is internal (chokepoint-minted MaskedPayloads), not a public OpenAI-compatible API.
- **Prompt-cache locality / session-pinning to upstream accounts** — only meaningful when pooling many upstream accounts; samen has no such pooling layer.
- **Any code reuse** — Elastic-2.0 is not MIT-compatible and not OSI-approved; samen must re-derive patterns first-party (which matches its existing ash_ai/ash_admin rejection posture anyway).
- **Runtime ingress firewall** — samen's Hammer-backed ingress rate limiting plus platform-level controls cover this; a bespoke app-layer firewall is scope creep for a foundry.
