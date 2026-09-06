---
project: ControlKeel
url: https://github.com/aryaminus/controlkeel
category: Software Factories
relevance: medium
verdict: Not a SaaS-foundry peer, but an Elixir governance control plane whose findings→eval→benchmark promotion loop, decision-lineage replay, and agent budget/circuit-breaker mechanics are directly liftable ideas for samen's AI plane and verification story.
---

# 018 — ControlKeel

## What the project is

ControlKeel (Apache-2.0, ~11 stars, ~1,283 commits, single-author but actively developed with CI/release automation) is a **control plane for governing AI coding agents**. It sits between agent hosts (Claude, Codex, Copilot, OpenCode) and production, validating agent output against organizational policy before changes land. Stack: **Elixir + Phoenix/LiveView, plain Ecto on embedded SQLite** (not Ash, not Postgres), Req for HTTP, **Burrito single-binary distribution** via GitHub Releases and npm, **MCP as the primary integration mechanism** plus A2A and internal APIs.

Core loop: capture intent/policy → deterministic scanner validation ("FastPath", PreToolUse-hook hard blocks on shell commands, sensitive writes, secrets; median 52 ms; benchmark: 12/12 caught, 9/12 blocked on risky scenarios) → human gates only for high-impact actions → persist findings, reviews, **proof bundles**, and costs → mine recurring failures into eval candidates → human-approved benchmarks → deterministic promotion. Operating principle: "spend tokens on discovery, not rediscovery." Notable design points: **decision lineage** (append-only audit rows stamped with the policy/artifact identity that governed them, so historical decisions can be replayed against the ruleset in force at the time), **precedent retrieval** (prior resolutions surfaced in-path so agents don't re-derive edge cases), **code-mode governance** (agents write small programs against typed SDK surfaces; source + declared capabilities validated pre-execution; Docker-sandbox-only, deny-by-default filesystem/network/secrets; proof artifacts capture source, grants, logs, outcomes), and **cost governance** (session budget, rolling 24 h budget, proxy-token estimates committed against provider usage, cached-token accounting, circuit breakers on API-call rate/error rate/budget-burn rate, capture of `anthropic-ratelimit-*` / `retry-after` headers).

It is a *development-process governor* — the same species as samen's `_orch/` autonomous loop + verifier discipline — not a multi-tenant SaaS substrate. No Ash, no PII vaulting, no multi-tenancy, no two-plane model.

## What samen could adopt

1. **Findings→eval-candidate→benchmark promotion path mined from real traces.** ControlKeel clusters real validation failures/tool errors/cost spikes into eval candidates "from real trace packets, not paraphrases," drafts benchmarks with bounded real evidence, human-gates materialization (`obs benchmarks approve`), and auto-archives/reopens candidates on results. Why it fits: samen already has the red-team AI eval tier (≥90% bar, ADR-043) and a flake ledger with RED-on-revert regression tests — but candidates are hand-authored. Mining eval scenarios from real agent-loop transcripts (ADR-047 retains them) with a human-gated promotion step would grow the eval corpus from production behavior while keeping the "a test that cannot fail is a bug" discipline. Effort: **M**.

2. **Policy-version stamping on audit rows (decision lineage replay).** Every ControlKeel review/finding disposition records the identity of the policy/ruleset that governed it, so decisions replay against the historical ruleset. Why it fits: samen's hash-chained audit (ADR-002) records events but, per the digest, not the governing policy version; stamping a policy/catalog revision id on approval and reveal-grant audit events would make compliance answers ("was this reveal legitimate under the rules then in force?") mechanical, and it composes with the catalog-as-data posture. Effort: **S–M** (one field + catalog/policy revision id plumbing at the approvals and reveal chokepoints).

3. **Budget-burn-rate circuit breakers + rate-limit telemetry in the agent loop.** ADR-047 has budgets/cost caps; ControlKeel adds a rolling 24 h window with warn/block thresholds, preflight estimate-and-block, breakers on consecutive failures and burn *rate* (not just totals), cached-token accounting, and allowlisted capture of `anthropic-ratelimit-*`/`retry-after` headers with honest scope ("records telemetry, does not pretend to throttle" — same fail-honest spirit as INV-4 adapters). Why it fits: drops straight into `samen_anthropic` + the ADR-047 loop as a hardening pass. Effort: **S**.

4. **Precedent retrieval in the agent loop.** Surfacing prior findings/resolutions in-path before an agent re-derives an edge case is the "typed memory" counterpart of samen's catalog grounding. Samen already has pgvector + non-PII tsvector search; indexing closed `_orch/` verdicts and gate-report findings and injecting matches into agent context (through the masking chokepoint) is the G22 "agent-grounding packaging" gap wearing different clothes. Effort: **M**.

5. **Hook-time deterministic verifier subset (FastPath analogue).** ControlKeel runs its deterministic scanner *pre-mutation* inside the agent session (52 ms median) rather than only at CI. Samen's `ci-fast.sh` exists, but a ~100 ms subset of the cheapest verifiers (`no_plaintext_pii` grep-tier, `pii_classify`, prefix checks) wired as an agent PreToolUse/pre-commit hook would catch sabotage-class mistakes thousands of tokens earlier than the phase-gate `./ci.sh`. Effort: **S**.

6. **Proof bundles for governed executions (pattern, later).** Capturing source + granted capabilities + logs + outcome as one evidence artifact per approved automation/AI action is a tighter packaging of what samen's approvals engine (E3) + audit already record separately. Worth borrowing the *bundle* shape if samen ever ships code-mode-style script execution. Effort: **L** as a feature, **S** as a doc convention.

## What to ignore and why

- **SQLite/embedded persistence and Burrito single-binary distribution** — samen is Postgres-only by ADR and in-monorepo by ADR-033; ControlKeel's local-first packaging solves a distribution problem samen has deliberately declined.
- **The host-attach adapter catalog (Copilot/Codex/OpenCode/etc.) and npm packaging** — samen governs its own first-party agent loop, not third-party coding agents.
- **Cloud sync / org-membership / workspace keys** — samen's identity spine and two-plane model already cover this at greater depth.
- **Code-mode sandbox execution as a near-term feature** — samen's stance is "AI writes do not exist; side effects go through E3 approvals," which is stricter and simpler; adopt only if a script-execution surface is ever scoped.
- **Taking ControlKeel as a dependency or upstream** — plain Ecto (no Ash), single-author, 11 stars, different storage model; the value is in the patterns above, not the code.

*Method note: evaluated directly via WebFetch of README, control-plane-architecture.md, observability-feedback-loop.md, code-mode-governance.md, and cost-governance.md; the environment exposed no Agent tool, so the mandated subagents were replaced by sequential direct fetches at equivalent depth.*
