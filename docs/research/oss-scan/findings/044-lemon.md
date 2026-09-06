---
project: Lemon
url: https://github.com/z80dev/lemon
category: Agent Frameworks and Development Tools
relevance: medium
verdict: Do not adopt the platform (INV-4 / ADR-033 / Jido-rejection precedent all apply), but mine its agent-runtime and contract-testing patterns — its EventStream/backpressure design is the best available reference for samen's deferred streaming work.
---

# 044 — Lemon (z80dev/lemon)

## What the project is

Lemon is a BEAM-native LLM agent platform / personal AI assistant, MIT-licensed, actively developed (~129 stars, 1,500+ commits, 17-app umbrella, 9 packages published to Hex). Tagline: "OTP-supervised per-run processes, pluggable engines and channels, contract-tested extension points, and a deterministic multi-agent sim arena."

Architecture highlights (verified via README, /docs, and apps/lemon_agent, apps/lemon_platform_test):

- **Layered umbrella**: `lemon_ai` (provider-agnostic client, 27 providers, streaming/retries/rate-limit/cost tracking), `lemon_core` (event bus, encrypted secrets, ETS/JSONL/SQLite stores), `lemon_agent` (agentic loop), `lemon_memory` (SQLite FTS + optional semantic backends), `lemon_router`/`lemon_gateway` (run lifecycle, single-flight execution, scheduler/locks), `lemon_channels` (Telegram/Discord/WhatsApp/XMTP), `lemon_platform_test` (contract-test kits), plus an in-repo reference runtime (control plane, CLI, Web UI, TUI, browser automation, LSP).
- **Agent runtime** (`lemon_agent`): strict split between `LemonAgent.Loop` — a *pure, stateless* recursive orchestrator (stream LLM → parse tool calls → execute tools concurrently under a Task.Supervisor → check steering/abort → repeat until no tool calls) — and `LemonAgent.Agent`, a stateful GenServer owning history, subscribers, and queues. Subagents are full Agent instances under a DynamicSupervisor, Registry-keyed by `{session_id, role, index}`.
- **Streaming machinery**: `LemonAgent.EventStream` — bounded-queue GenServer producer/consumer with synchronous `push/2` (`:ok | {:error, :overflow}`) for backpressure and configurable drop strategies (`:error`, `:drop_oldest`, `:drop_newest`); typed event vocabulary (`message_start/update/end`, `tool_execution_start/end`, `turn_start/end`, `agent_end`).
- **Control primitives**: ETS-based cooperative `AbortSignal` (read-concurrent, checked by loop and tools); **steering** (inject a message after the current tool batch, remaining tools skipped) and **follow-up** queues (post-run, 50ms long-poll) for mid-run intervention.
- **Verification posture**: contract-test case templates for every extension behaviour; FakeLLM scripted simulation; "nothing makes a network call... unless you pass an explicit probe"; LemonSim deterministic event-sourced multi-agent arenas (Werewolf, Poker, etc.) for key-free benchmarking; AST-level layer-boundary checks; docs freshness governance (`docs/catalog.exs` with ownership + review cadence, validated by `mix lemon.quality`); tool pipeline documented as registry → policy → approval → execution with a layered Agent Safety Contract.

Domain mismatch to note: Lemon is a *personal assistant* platform (messaging channels, TUI, skills marketplace), not a multi-tenant SaaS substrate. It has no tenancy, no PII vault, no masking chokepoint, and its safety model is policy/approval-layered rather than token-blind-by-construction. The overlap with samen is entirely in the agent-runtime engineering and testing discipline.

## What samen could adopt

1. **Bounded EventStream + backpressure pattern for AI streaming** — What: a plain GenServer bounded queue with synchronous push, overflow signaling, drop strategies, and a typed agent-event vocabulary, feeding SSE. Why: ADR-047 deferred streaming; this is a zero-dependency, OTP-only design samen can reimplement inside the kernel without violating INV-4, and the drop-strategy/overflow contract is exactly the kind of bounded-outcome behavior samen already likes (cf. RunRecord allowlist). The EG2 re-scrub chokepoint slots naturally between Loop and EventStream. Effort: **M**.

2. **Contract-test case kits for behaviours** — What: `lemon_platform_test`-style shared ExUnit case templates (`use SamenTest.ProviderCase, provider: ...`) asserting behavioral compliance, with each kit taking exactly one optional dep and raising a *named* compile-time error when missing. Why: samen has many behaviours (`Samen.AI.Provider`, `Samen.Kms`, delivery/ESP adapters, `Files.Storage`, backup) and a fail-honest contract (ADR-014/024/026/038) that is currently proven per-adapter; a single case template would make every current and future adapter prove `{:error, :not_configured}` honesty, MaskedPayload-only acceptance, and refusal semantics uniformly — and it packages well for G22 (agent-grounding for external builders). Effort: **M**.

3. **Stateless Loop / stateful Agent split with cooperative AbortSignal** — What: keep the agentic step function pure (input: context + tool results → output: next action) with a thin GenServer shell; ETS read-concurrent abort flag checked between steps and inside tool `execute` callbacks. Why: makes the ADR-047 loop property-testable without processes (Lemon property-tests context handling with StreamData, which samen already depends on), and gives budgets/cost-caps a clean mid-run cancellation mechanism instead of only pre-flight checks. Effort: **S** if applied as a refactor guide to the existing loop, **M** if abort plumbing reaches tools.

4. **Steering / follow-up queues as an operator surface** — What: inject an operator message after the current tool batch (skipping remaining tools) vs. queueing for after the run. Why: samen's agent loop is operator-governed by design; steering is a natural companion to the E3 approvals engine — approvals gate side effects, steering redirects a run that is drifting *before* it proposes anything. Maps cleanly onto the operator plane UI. Effort: **M**.

5. **Docs freshness registry** — What: every file in `docs/` must register in a `docs/catalog.exs` with an owner and review cadence; a verifier fails CI on unregistered or stale docs. Why: samen has 49 ADRs + gate reports + compliance docs and an INV-6 docs/claims-sync invariant, but its enforcement (`doc_commands_test.exs`, claim sweeps) checks *content*, not *staleness/ownership*; this is a cheap `mix samen.verify.docs_catalog` tier in the house style. Effort: **S**.

6. **Scenario-based agent eval arenas (inspiration only)** — What: LemonSim's deterministic, event-sourced multi-agent scenarios benchmarked offline with scripted/fake LLMs. Why: samen's red-team eval tier (≥90% context-assembly bar) is adversarial-static; a small deterministic scenario harness (e.g. "support triage world" seeded from driftwood) would exercise the full loop+approvals+budget path key-free in CI. Effort: **L** — only worth it when G22 packaging becomes active.

## What to ignore and why

- **Lemon as a dependency or vendored runtime** — violates INV-4 (its stack pulls HTTP/vendor deps, SQLite, channel SDKs into the runtime), ADR-033 (in-monorepo distribution), and the standing precedent of rejecting Jido and ash_ai for exactly this shape of coupling. Samen's agent loop is already BUILT and accepted (ADR-047) with zero new deps.
- **27-provider `lemon_ai` client** — provider breadth is anti-goal for samen: the whole point of `samen_anthropic` is a single chokepoint-minted `%MaskedPayload{}` ingress; a generic multi-provider client reintroduces raw-string prompt paths.
- **Channels (Telegram/Discord/WhatsApp/XMTP), TUI, skills marketplace** — personal-assistant surface area with no SaaS-foundry analog; samen's channels are its product planes.
- **SQLite/JSONL stores and Honcho memory** — samen is Postgres-only with pgvector by decision; nothing to take.
- **Hot code reload in prod** — directly at odds with samen's full-gate-at-every-boundary discipline (INV-3); a live-patched BEAM node is an unverified state.
- **Lemon's approval model as-is** — it is policy-layered ("recommended defaults"), weaker than samen's requester≠approver enforced at policy AND DB-CHECK; adopt nothing here, samen's is stronger.
