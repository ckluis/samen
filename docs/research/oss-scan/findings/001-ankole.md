---
project: Ankole
url: https://github.com/AgentBull/ankole
category: AI and Agents
relevance: medium
verdict: Don't adopt the platform (polyglot NIF/Bun/ZeroMQ stack conflicts with samen's pure-BEAM posture), but mine its Brain/Dreaming design docs as the reference blueprint when samen builds agent long-term memory.
---

# 001 — Ankole (AI Workforce OS)

## What the project is

Ankole (AgentBull/ankole, Apache-2.0, 42 stars, last push 2026-08-16, 224 commits, self-labeled "MVP/early production", explicit no-compat-contract on public APIs) is a self-hosted "AI workforce operating system": agents as autonomous workers with bounded authority, durable execution, and an operator console.

Stack: **Elixir/Phoenix/OTP control plane** (Principal/AuthZ, config, actor orchestration, AIGateway, Brain memory, SignalsGateway) + **Bun/TypeScript agent-execution workers** ("Agent Computer", Docker/bubblewrap-isolated) + a **Rust kernel crate loaded via Rustler NIF** + **ZeroMQ "RuntimeFabric"** for low-latency steering/checkpoint/backpressure traffic + Vite/React frontend. Requires **PostgreSQL 18 with ParadeDB `pg_search` (BM25) and `pgvector`**. Uses Oban (incl. Oban Lifeline for stuck-job rescue).

Notable subsystems (each has a real design doc under `docs/design-docs/`):
- **Durable execution**: "virtual actors" — agent sessions wake, checkpoint, stream, hibernate, recover; BackgroundAgentJob for hours/days-long work; "the final reply always comes from a stored outbox row"; local worker files are explicitly non-durable.
- **Brain** (long-term memory): entries/blocks/relations/sources/citations/episodes/cursors/audit rows in Postgres; per-store visibility keys (`shared` / `self` / `dm:P` / `channel:C`); every persisted block must cite a canonical source marker; before/after audit log with inverse-operation recovery; **Dreaming** = two-stage offline consolidation (Stage A: chat→episode summaries; Stage B: episodes→curated knowledge entries), triggered by silence/backlog thresholds, cursor never advances on failure.
- **Recall**: five parallel routes (knowledge keyword BM25, knowledge vector, chat keyword BM25, episode vector, Reciprocal Rank Fusion), exponential temporal decay (30-day half-life, floor for knowledge), per-candidate token caps inside a global token budget, optional reranker.
- **AuthZ**: Principals (human and agent identities), groups, grants, **CEL-expression decisions**; durable audit records; approval boundaries/escalation define agent authority.
- **SignalsGateway**: channel ingress (Lark/Feishu, Slack, webhooks) that deliberately does not conflate source facts with execution state; best-effort withdrawal when a provider deletes a message (reverses derived Brain knowledge only if it still matches the expected value).

## What samen could adopt

All are **patterns from the design docs**, not code or dependencies.

1. **Dreaming-style two-stage memory consolidation** (episodes → curated knowledge) as the design blueprint for samen's open G22 "agent-grounding packaging" and any agent long-term memory. Why it fits: samen already retains agent transcripts under the ADR-046 erasure envelope and has pgvector + a catalog for grounding; Ankole's silence/backlog triggers, protected recent tail, bounded per-run budgets, and cursor-only-advances-on-success semantics match samen's determinism discipline. Samen twist: all consolidation model calls go through the masking chokepoint (EG2), and shared-store writes should gate through the E3 approvals engine (Ankole explicitly has *no* approval flow for memory — samen should differ). Effort: **L**.

2. **Citation-required memory blocks + before/after audit with inverse recovery.** Every derived-knowledge block must carry a canonical source marker; every mutation logs before/after; recovery replays inverse ops newest→oldest and *stops on conflict rather than clobbering*. Why it fits: this is samen's claim-evidence ethos applied to AI memory, and it composes with the hash-chained audit. Effort: **M** (as part of item 1).

3. **Withdrawal propagation into derived artifacts** — when source evidence is deleted, find the audit rows it caused, reverse only still-matching changes, delete blocks citing that exact source marker; later human edits win. Why it fits: samen's crypto-shred erasure currently covers vaulted rows/rollups/Oban args; if samen ever derives AI knowledge from tenant data, this is the concrete recipe for extending the erasure envelope (ADR-046) into derived memory — a `samen.verify.erasure_completeness`-style tier could assert it. Effort: **M**.

4. **Recall ranking recipe**: hybrid keyword+vector via Reciprocal Rank Fusion, exponential temporal decay with a knowledge floor, per-candidate token caps (default 400) inside a global budget so one long thread can't starve others, dedup + neighbor/thread expansion. Why it fits: directly upgrades samen's AI-plane context assembly over its existing pgvector + non-PII tsvector search — using Postgres FTS instead of ParadeDB BM25 keeps zero new infra. Effort: **M**.

5. **`check_back_later` wake events as a first-class agent verb.** Ankole's Schedule doc treats checkbacks/cron fires as typed ActorEvents the agent loop consumes. Why it fits: samen's ADR-047 agent loop + Oban already have the machinery; a typed "check back at T" tool with governed egress gives durable multi-day agent work cheaply. Effort: **S**.

6. **Visibility-boundary conversation reset**: when a group's memory scope changes (shared ↔ confidential), end the conversation and start a successor that inherits neither transcript nor memory snapshot. Why it fits: a clean rule for samen's cross-plane chat + AI transcripts when org/role scoping changes; cheap to state as an invariant and test red-path. Effort: **S**.

7. Minor ops note: **Oban Lifeline** (30-min rescue of executing jobs) as a stale-lock guard for long agent jobs — samen pins oban 2.23 already. Effort: **S**.

## What to ignore and why

- **The polyglot runtime** (Rust kernel via Rustler NIF, Bun/TS agent workers, ZeroMQ RuntimeFabric): samen deliberately runs pure-BEAM with zero NIFs (simple_sat chosen for exactly this) and zero vendor deps in core (INV-4). The latency/isolation needs Ankole solves don't apply to samen's approvals-gated, no-AI-writes loop.
- **ParadeDB `pg_search` + PostgreSQL 18 requirement**: infra coupling samen doesn't need (Neon-compat risk); Postgres tsvector + pgvector already cover samen's recall floor.
- **CEL-based AuthZ**: samen's Ash policies + OrgScope + SAT-checked policy matrix are stronger and already verified; importing a second policy language would fork the trust kernel.
- **"Automation over human approval" memory philosophy**: Ankole explicitly ships no ACL/approval flow for Brain writes; samen's E3 requester≠approver discipline should override this wholesale.
- **Lark/Slack SignalsGateway integrations as-is**: if samen wants chat ingress later, it builds them as fail-honest adapter packages; nothing to lift directly.
- **Code reuse generally**: MVP maturity, breaking-change posture, 42 stars — the durable value is the unusually rigorous design docs, not the implementation.
