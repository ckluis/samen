---
project: Svärm
url: https://github.com/svarm-dev/svarm
category: Software Factories With License Warnings
relevance: medium
verdict: Same-stack (Elixir/Phoenix, OTP 29) coding-agent governance tool; adopt its budget-hold, cost-receipt, and ROI-metric patterns into samen's ADR-047 agent loop — patterns only, never code (FSL-1.1-MIT).
---

# 030 — Svärm

## What the project is

Svärm is a self-hosted **control plane for external AI coding agents**, built in **Elixir 1.20+/OTP 29 with Phoenix LiveView** — the exact samen stack. Rather than letting agents push PRs directly, it acts as a gatekeeper: it pulls tickets from GitHub Issues or a local SQLite board, runs preflight checks (config, capacity, approvals), dispatches agents into isolated per-ticket workspace directories (optional git worktrees), and keeps humans on the merge button. Core loop is a GenServer poll (`Svarm.Orchestrator`) over adapter behaviours: `Svarm.Tracker` (GitHub Issues or SQLite), `Svarm.Runner` (CLI or RPC agent execution), `Svarm.Provider` (LLM access, OpenRouter shipped), and `Svarm.Usage.Ledger` (append-only cost tracking). Lib layout confirms dedicated `budget.ex`, `approval.ex`, `dispatch.ex`, `run_log/`, `usage/`, `workflow/` modules.

Signature features:
- **Per-ticket and per-day USD budget caps** with two modes: `hard` (skip spawn) or `hold` (park the run for human approval).
- **Cost receipts** posted to the originating issue as append-only ledger entries — tokens, model, estimated USD, explicitly labeled "estimated"; exportable via `mix svarm.export_usage`.
- **ROI dashboard**: merge rate and $/merged over configurable windows, 24h cost rollups, retry metrics.
- **Mid-run Q&A pausing**: agent-to-human dialogue with a 15-minute timeout; **review-resume** re-dispatch when a GitHub review requests changes; optional CI-triggered re-dispatch behind a circuit breaker.
- **Agent env allowlist**: spawned agents get an explicit env-var allowlist; secrets never inherit the host environment.
- Fail-closed production auth on board mutations (`APPROVALS_USER`/`APPROVALS_PASSWORD` required in prod).

Status: v0.1.5, 132 commits, 1 star / 0 forks — a very early solo project, but actively developed with CI. **License: FSL-1.1-MIT** (internal use/study/modification allowed; no competing product or hosted service; each version converts to MIT after two years). Not OSI-approved today.

## What samen could adopt

All items are **pattern adoption, not code adoption** — FSL code cannot be vendored into MIT samen (see ignore section).

1. **Budget `hold` mode routed through E3 approvals** — Svärm's `hard`-vs-`hold` distinction (block spawn vs park for approval) is a better shape than a bare cap. Samen's ADR-047 agent loop already has budgets/cost caps and already has the ADR-040 E3 approvals engine (requester ≠ approver at policy + DB-CHECK); wiring "budget exceeded ⇒ park run as an Approvals gate item" composes two existing subsystems. Why it fits: turns a silent refusal into a governed, audited human decision — exactly samen's fail-honest posture. **Effort: S.**

2. **Per-run cost receipts as first-class ledger entries** — append a receipt (tokens, model, estimated USD, provider lane, labeled "estimated") to each agent RunRecord/transcript, surfaced on the operator plane and exportable. Why it fits: samen's claim-evidence culture demands honest labeling of estimates; receipts slot naturally into the hash-chained audit (tokens-only, so crypto-shred-safe) and into ADR-046 transcript retention. **Effort: S.**

3. **ROI metrics for the agent loop** — merge-rate / $-per-accepted-outcome / retry counts over time windows on the operator dashboard (and eventually the ADR-044 fleet cockpit). Why it fits: samen's agent loop has cost caps but no shipped cost-effectiveness view; this is the operator-cockpit-v2 theme already on the roadmap. **Effort: M.**

4. **Mid-run pause-for-human with timeout** — a bounded agent-loop step kind: "ask the operator, wait ≤N minutes, fail honest to `{:error, :no_human_response}` on timeout." Why it fits: samen's agent loop deliberately keeps AI writes proposal-only; a governed Q&A pause extends the same philosophy to ambiguity mid-run instead of forcing abort-or-guess. Fits the automation engine's bounded-outcome RunRecord allowlist. **Effort: M.**

5. **Review-resume for the _orch dev loop (process, not product)** — Svärm's "re-dispatch on requested changes, circuit-breaker on repeated CI failure" is a convention worth encoding in samen's own autonomous-run orchestration (`_orch/` backlog handoffs): a bounded auto-retry-on-review-feedback rule with an explicit trip counter, instead of ad-hoc resume prompts. **Effort: S** (docs/convention change).

6. **Optional: run Svärm itself, internally** — FSL-1.1 explicitly permits internal use. As a dashboard over samen's *development* coding-agent runs (tickets, live logs, per-ticket cost, approval gates) it dogfoods the exact BATON-run workflow. Low priority; samen's `_orch` files already serve as persistent state. **Effort: S to try, M to keep.**

## What to ignore and why

- **Any code reuse.** FSL-1.1-MIT forbids using it in anything competing and clouds provenance for an MIT-published repo; samen's INV-4/vendor-free discipline and AI-authored provenance story make vendoring FSL code a non-starter. Two-year MIT conversion only covers versions ≥2 years old.
- **The approvals implementation** (HTTP Basic Auth, `APPROVALS_USER`/`PASSWORD` env pair). Samen's identity spine + E3 approvals engine is strictly stronger (second-party approval enforced in policy AND DB CHECK).
- **SQLite tracker / OpenRouter provider adapters.** Samen is Postgres-only with its own fail-honest provider adapter pattern (`samen_anthropic`); nothing to learn beyond what ADR-014/024/038 already codify.
- **cwd/worktree isolation and env allowlists for spawned agent processes.** Samen's agent loop is in-BEAM durable tool use (zero subprocess spawning; raw-spawn AST lock already exists) — the threat model doesn't apply to the product plane.
- **CI-triggered re-dispatch circuit breaker as a library.** Samen's automation engine already ships Health/Breaker; only the dev-process convention (item 5) is new.
- **The product category itself.** Svärm governs *coding agents making PRs*; samen's AI plane governs *product-embedded agents over tenant data*. Adjacent inspiration, not a competitor or a substrate candidate.
