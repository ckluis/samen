---
project: Conductor
url: https://github.com/dangeranger/conductor
category: Software Factories With License Warnings
relevance: low
verdict: Unlicensed 0-star experimental Codex/Linear agent harness — nothing samen can legally or usefully adopt; at most a conceptual echo of samen's own _orch/ loop.
---

# 029 — Conductor

## What the project is

Conductor is a brand-new, experimental Elixir/OTP coding-agent harness (Elixir 1.19 / OTP 28, escript CLI). It polls Linear issues via GraphQL, creates a sanitized, isolated per-issue workspace, and launches OpenAI Codex app-server sessions over JSON-RPC stdio to work each issue autonomously. A GenServer `Conductor.Orchestrator` handles polling, claims, bounded dispatch, retries, reconciliation, config reloads, and snapshots; workspaces support local or SSH-remote execution, with the rule that hooks and Codex subprocesses only ever run from the issue workspace, never the source checkout. An optional Phoenix LiveView dashboard (`--port` flag) plus JSON API provides monitoring. The repo is agent-first in its documentation conventions (AGENTS.md entry map, SPEC.md behavior contract, ARCHITECTURE.md module boundaries) and enforces a `make all` gate (format, tests, 95% coverage, dialyzer, lint).

Repo health: 0 stars, 0 forks, 8 commits on main, "external integration validation pending." **No license file anywhere** — the code is all-rights-reserved by default.

## What samen could adopt

Effectively nothing as code, and little as concept:

- **Nothing as code.** No license means samen (MIT, public) cannot vendor, port, or even closely derive from this source. This alone caps the entry at low relevance, per the category warning.
- **Concept only — issue-tracker-driven task claiming with snapshot/reconcile (what):** an orchestrator that claims backlog items, retries bounded work, and snapshots state for recovery. **Why it fits:** samen's `_orch/` autonomous loop (backlog.yaml, per-task handoffs, verify verdicts) is file-based and session-driven; a claims/reconcile discipline is the same shape. **But** samen's loop is deliberately operator-gated and runs inside Claude Code sessions with phase gates (`./ci.sh`, INV-3), not a resident OTP daemon — and samen already evaluated and rejected an in-BEAM agent framework (Jido, `_orch/jido-eval-report.md`) for this exact role. Re-deriving the idea independently is trivial if ever wanted. Effort if ever pursued: M, value today: near zero.
- **Concept only — workspace-isolation rule (what):** "agent subprocesses never run from the source checkout." **Why it fits:** samen's dev process could note this as hygiene for future multi-agent runs (worktrees already provide it in Claude Code). Effort: S, but it is process hygiene samen already practices via BATON/worktree conventions, not a repo change.

## What to ignore and why

- **The entire codebase**: unlicensed, 0 stars, 8 commits, self-described as pending external validation — legally unusable and unproven.
- **Codex/Linear integrations**: samen's AI plane is Anthropic-adapter-based behind a masked-payload chokepoint (ADR-043/047); Codex JSON-RPC stdio sessions and Linear GraphQL polling solve a different problem (dev-tooling orchestration) than samen's product-runtime agent loop, and stdio transports are explicitly out of samen's prod posture (MCP is HTTP+SSE, no stdio in prod).
- **The LiveView dashboard**: samen already has a first-party operator plane and fleet cockpit (ADR-044) far deeper than an opt-in monitoring page.
- **Domain mismatch overall**: Conductor is a software-factory dev harness, not a SaaS substrate — it touches none of samen's actual concerns (PII vaulting, two-plane masking, crypto-shred, billing, identity, verification gates).
