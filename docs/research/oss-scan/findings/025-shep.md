---
project: Shep
url: https://github.com/craigruks/shep
category: Software Factories
relevance: medium
verdict: Tiny, readable Elixir/OTP coding-agent orchestrator — adopt its supervision, label-state-machine, and "green means a check reported" CI-verification patterns for samen's dev loop; do not take it as a dependency.
---

# 025 — Shep

## What the project is

Shep is a ~3,000-LOC MIT-licensed **Elixir/OTP orchestrator for coding agents** (Claude Code, Codex) by a single maintainer (craigruks; 0 stars/forks, 71 commits, 166 no-mock integration tests, `mix quality` = format + Credo + tests). It turns GitHub issues labeled `shep` into CI-verified pull requests: the orchestrator (a single GenServer error kernel) polls the tracker, claims an issue by flipping its label to `shep:in-progress`, cuts a fresh git worktree on branch `shep/<issue>` off a freshly-fetched remote base, runs an `on_worktree_ready` hook as a gate, then spawns the agent CLI as a **Port under a Task.Supervisor** with an idle watchdog, hard timeout, and max-turns cap. Crashes arrive as `:DOWN` messages (never crash the kernel); crashed agents get exponential backoff with 3 attempts.

Verification is two-phase: after the agent signals done, Shep runs `goal.verify` (e.g. `mix quality`) locally in the worktree and feeds failure logs back into the same agent session as capped "fix turns" — a PR only opens after local verification passes. It then watches CI with real rigor: "green" means a named check actually reported (`goal.ci_required_checks`), never "nothing is failing"; no check within `goal.ci_grace_ms` → `shep:failed`; mergeability is polled and conflicts go back as merge-base fix turns. Green CI flips to `shep:in-review` for human merge. Design pillars: **tracker-as-database** (GitHub labels ARE the state machine — no Postgres/Redis/state file; restart and re-learn the world), hot-reloaded YAML-front-matter config in `WORKFLOW.md` (1 s, no restart), worktrees preserved on failure / pruned on success, GitHub via `gh` CLI, and a `heel`/`take` pause mechanism that drops the operator interactively into the agent's live session. An experimental sandbox mode runs tasks on ephemeral Vercel VMs with forwarded credentials.

## What samen could adopt

Shep is dev-process tooling, not runtime product — its patterns map onto samen's **autonomous build loop** (`_orch/` backlog, BATON runs, phase gates), where samen's known pain points live (stranded agents on session limits, serialized fan-outs, gate tasks deadlocking when backgrounded).

1. **"Green means a check reported" CI semantics** — require named checks to have actually reported; treat no-report-within-grace as failure; poll mergeability and treat un-mergeable PRs (which GitHub builds no check suites for) as red. *Why it fits:* this is samen's fail-honest invariant (INV: never fake success) applied to the PR/CI layer of BATON runs, closing a real false-green hole. *Effort:* **S** — a rule in the run prompts plus a small `gh`-based check script alongside `verify.sh`/`resume-digest.sh`.

2. **Two-phase verify-then-PR loop with capped fix turns** — run the full local gate (`./ci.sh` or `ci-fast.sh`) in the worktree and loop failure logs back into the same agent session (`verify_fixes` cap) before any PR exists; separately cap CI fix turns after the PR opens; on exhaustion, mark failed and preserve the worktree for post-mortem. *Why it fits:* formalizes what samen's task handoffs do ad hoc; bounded retries + preserved-failure-state matches the flake-ledger/dry-twice discipline. *Effort:* **S** as convention encoded in `_orch/` prompts and CLAUDE.md; **M** if scripted.

3. **OTP error-kernel supervision for agent runners** — GenServer kernel + Task.Supervisor children + Port-per-agent + `:DOWN` collection + idle watchdog + hard timeout + exponential backoff (3 attempts). Two applications: (a) a first-party `samen_orch` dev-loop runner replacing fragile session babysitting — samen is the rare consumer that could read and rebuild Shep's 3k lines natively; (b) reference patterns for hardening the **ADR-047 runtime agent loop** (idle watchdog + stall-kill + backoff around durable multi-step tool use — samen has budgets/caps but Shep's stall detection and error-kernel isolation are complementary). *Effort:* **M** for (b) selective hardening; **L** for (a) a full runner — only worth it if BATON-run babysitting cost keeps recurring.

4. **Externally-reconstructable orchestration state** — Shep's tracker-as-database means a restart re-derives the world from label positions. Samen's `_orch/backlog.yaml` is already file-state, but the *reconstruction* discipline (any fresh session can re-learn run state from one queryable source, no session memory required) is exactly the resume-digest problem; consider promoting backlog state to GitHub issue labels for BATON runs so `gh` queries replace bespoke digest scripts. *Effort:* **M**.

5. **Worktree-per-task isolation, preserve-on-failure/prune-on-success + serialized base fetches** — fresh worktree off remote-tracking refs per task, fetches serialized to avoid git ref-lock races, failed worktrees kept for autopsy. *Why it fits:* enables safe parallel task execution in the monorepo and gives failed autonomous rounds durable evidence, matching samen's evidence-first gating. *Effort:* **S**.

6. **`heel`/`take` operator intervention** — pause a running agent, drop into its live session interactively, resume or hold on exit ("pair-programming where your pair is a process you can suspend"). A better-shaped human-gate primitive than kill-and-reprompt for samen's operator-gated runs. *Effort:* **M**, and only meaningful if item 3a is built.

## What to ignore and why

- **Shep as a dependency or hosted piece of samen** — it is operator dev-tooling with zero tenancy/PII/audit concerns; nothing belongs in `samen_core`/`samen_web`. Patterns in, code out.
- **Vercel sandbox mode** — experimental by its own admission (no Elixir in the base image, credential forwarding, untested pause/resume at scale); forwarding Claude+GitHub credentials to ephemeral third-party VMs is contrary to samen's key-custody posture.
- **Codex/multi-vendor agent routing (`shep:codex`, `shep:model:*`)** — samen's authoring loop is Claude-only by convention; per-issue model routing solves a problem samen doesn't have.
- **Hot-reloaded WORKFLOW.md config** — charming, but samen's runs are phase-gated and deliberate; 1-second live config mutation mid-run works against reproducible gate evidence.
- **Slack notification plumbing** — trivially replaceable; samen's operator surface is the terminal/PR.
- **Maturity as a signal** — 0 stars, single maintainer, 71 commits: treat as a well-written design document with tests, not an ecosystem bet. Its lineage (OpenAI Symphony/Sandcastle) is worth a skim for the same reason.
