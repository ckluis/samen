---
project: AlexClaw
url: https://github.com/thatsme/AlexClaw
category: AI and Agents
relevance: medium
verdict: Same stack (Elixir/OTP/Phoenix/pgvector), different domain (single-user personal agent); no wholesale adoption, but 5-6 concrete AI-plane patterns worth lifting into samen's ADR-043/047 surface.
---

# AlexClaw — evaluation vs samen

## What the project is

AlexClaw is a self-hosted, single-user, BEAM-native personal autonomous AI agent (Apache-2.0, 115 stars, Elixir, last push 2026-04, actively maintained, not a toy). It monitors sources (RSS, web, GitHub, APIs), accumulates knowledge in a Postgres+pgvector store, executes scheduled workflows, and talks to its owner over Telegram/Discord. Stack: Phoenix LiveView + Bandit, Ecto/Postgres + pgvector (HNSW, 768-dim), Req, Quantum (cron), nimble_totp, Nostrum (Discord), anubis_mcp (MCP Streamable HTTP server), Docker Compose deploy.

Notable internals:
- **Workflow engine**: linear pipelines with skill-declared `routes/0` branching (`{:ok, result, :branch}`), `input_from` fan-in wiring, per-step resilience config (`on_circuit_open: halt|skip|fallback`, `on_missing_skill`, `fallback_skill`), Registry GenServer+ETS for live run tracking/cancellation, JSON export/import with no DB IDs.
- **Multi-model LLM router**: tier-based (light/medium/heavy/local) provider selection from a DB table ordered by priority, five provider types (openai_compatible, ollama, gemini, anthropic, custom), per-provider daily limits, ETS+DB usage counters keyed `{provider_id, date}` to maximize free tiers, step-level > workflow-level > global tier override hierarchy.
- **Memory/RAG**: async embedding (insert with nil embedding, background embed task), semantic chunking (parent keeps full text, children embedded, search dedups by parent), hybrid vector+keyword search with light-tier LLM query rewrite (ETS-cached), embedding-model staleness tracking + `reembed_all` batch, keyword-only fallback when no embed provider.
- **Security**: Macaroon-style HMAC capability tokens attenuated on skill-to-skill calls, chain depth cap 3, Postgres-backed PolicyEngine with ETS cache, auth-denial audit log, AES-256-GCM app-level encryption of API keys (HKDF from SECRET_KEY_BASE), 7-layer ContentSanitizer for external content (hidden-HTML detection, zero-width Unicode stripping, 101 injection patterns loaded from runtime JSON, imperative-tone heuristic), AST scan of dynamic skills rejecting undeclared HTTP/socket calls, TOTP-gated sensitive workflows.
- **MCP server**: `anubis_mcp` Streamable HTTP at `/mcp`, bearer auth with `Plug.Crypto.secure_compare`, all skills/workflows exposed as tools, six `alexclaw://` resource URI templates, PubSub-driven dynamic tool-list refresh, PolicyEngine check per tool call.
- **Ops**: per-skill circuit breakers under a DynamicSupervisor with dead-letter routing, /health + /metrics JSON endpoints, 500-entry log ring buffer with live viewer, multi-node BEAM clustering with cross-node workflow triggers.

Explicitly single-user: no multi-tenancy, no org model, no PII governance. Core skills bypass all permission checks. Forge (dynamic skill generation) and web automation are pre-alpha.

## What samen could adopt

1. **Inbound content sanitization at the tool-result ingress (ContentSanitizer pattern)** — What: a layered scrubber (zero-width Unicode strip, hidden-HTML/CSS detection, known-injection-pattern list kept as runtime data, imperative-tone heuristic) applied to external content before it enters prompt assembly. Why: samen's chokepoint governs *egress* (no PII out via `%MaskedPayload{}`); the ADR-047 agent loop ingests tool results and web/external content, and injection-in is the complementary threat the ≥90% red-team eval bar measures. A data-driven pattern list slots naturally into samen's eval harness and sabotage discipline (patterns are fixtures, tests can flip). Effort: M.

2. **Tier-based LLM router with persisted usage/cost counters** — What: DB-backed provider registry (type, tier, priority, daily limit, JSONB inference options), per-call tier declaration, cheapest-suitable-provider selection, ETS+DB `{provider, date}` usage counters. Why: samen's AI kernel has one real provider (samen_anthropic) plus the fake CI provider; ADR-047 already mandates budgets/cost caps, and a tier router is the natural home for them — light-tier for classification/rewrites, heavy for drafting. Fits the existing `Samen.AI.Provider` behaviour and fail-honest rule (unconfigured tier → `{:error, :not_configured}`). Effort: M (router + counters; additional provider adapters are separate S-each packages).

3. **Embedding-model staleness tracking + re-embed pipeline** — What: store the embedding model name per row, expose `stale_embedding_count`, batch `reembed_all` for nil/stale rows, async embed-after-insert so writes never block on the embedding call. Why: samen requires pgvector and will change models/dimensions eventually; this is a small, purely-operational pattern that prevents silent relevance rot and gives the operator plane a concrete health metric. Effort: S.

4. **Parent/child semantic chunking with search dedup** — What: split >N-char content on semantic boundaries, embed children only, keep full text on the un-embedded parent, dedupe search hits by parent. Why: samen's runtime catalog grounding and support/CRM AI surfaces retrieve documents; this is the standard fix for long-document retrieval and composes with samen's masking (chunking happens on already-masked/non-PII content). Effort: S.

5. **Per-step resilience policy on automation/agent steps** — What: declarative `on_circuit_open: halt|skip|fallback` + `fallback_skill` per workflow step, surviving breaker trips without killing the run. Why: samen's Automation engine (ADR-039) already has Health/Breaker and Reactor per-step compensation; what AlexClaw adds is the *operator-configurable* degradation choice per step rather than a fixed policy — a good fit for the automation editor and for agent tool steps whose vendor adapter is down (fail-honest, but recoverable). Effort: M.

6. **Capability-token attenuation for nested tool/agent calls** — What: HMAC (HKDF-derived) tokens scoped to declared permissions, attenuated to a subset when one tool invokes another, hard chain-depth cap. Why: ADR-047's EG2 governance re-scrubs history per turn but samen's tool-call *authority* model is actor/policy-based; attenuation gives monotonically-shrinking authority across multi-step chains and a cheap depth bound against runaway recursion. Adopt the concept (attenuation + depth cap) into `Samen.AI` tool dispatch, not the process-dictionary carriage. Effort: M.

7. **Evaluate `anubis_mcp` as the MCP transport for samen_web** — What: a maintained Elixir MCP library (Streamable HTTP) replacing hand-rolled protocol plumbing; also its resource-URI-template idiom (`samen://catalog/...`) for exposing the catalog/read-models. Why: samen hand-built its MCP server (protocol 2025-03-26); a vendor dep is allowed in samen_web (assent/hammer precedent) and would offload protocol churn — but samen's per-operator tokens and masking guarantees must wrap it, so this is a spike, not a default-adopt (echoes the ash_ai rejection logic). Effort: S to spike, M to migrate if it wins.

## What to ignore and why

- **Single-user auth/session model, Telegram/Discord gateways, Google OAuth token manager** — samen has a full identity spine (ADR-035) and a notifications subsystem; chat-platform control is a personal-agent feature, not a SaaS-foundry need. (A Telegram delivery adapter could someday be a fail-honest ESP-style package, but nothing here to lift.)
- **Quantum cron scheduling** — samen standardized on Oban/ash_oban with same-transaction enqueue and multi-node proofs; Quantum is strictly weaker (no persistence of job state, no uniqueness).
- **Runtime dynamic-skill compilation/hot-loading** — compiling user/LLM-supplied Elixir at runtime is the opposite of samen's verifier + sabotage discipline (and its AST "sandbox" is heuristic); samen's `mix samen.gen.agent` + coverage-floor verifier path is the right shape. Also "core skills bypass all checks" is exactly the kind of policy hole samen's fail-closed OrgScope design exists to prevent.
- **Process-dictionary token storage** — fragile across Task/GenServer hops; if adopting capability tokens (item 6), carry them explicitly in the call context.
- **Its memory/knowledge store as a product** — no tenancy, no PII classification, freeform ingestion; samen's CDC default-deny classifier and vault chokepoint make this unadoptable wholesale. Only the mechanical patterns (items 3-4) transfer.
- **LiveView admin UI** — samen's operator plane is first-party and further along (fleet cockpit, masked impersonation); nothing structural to gain.
