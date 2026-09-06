---
project: Maestro
url: https://github.com/joosure/Maestro
category: Software Factories
relevance: low
verdict: Same Elixir/Ash/Phoenix/Oban stack but a dev-tooling agent orchestrator, not a SaaS substrate; AGPL blocks code reuse and samen's _orch loop plus ADR-047 already cover the overlapping ideas.
---

# 023 — Maestro

## What the project is

Maestro (evolved from OpenAI's "Symphony") is an early-stage (~44 stars) task-driven engineering platform that routes tickets from project systems (Linear, TAPD) to AI coding agents (Codex, Claude Code, OpenCode) and writes results back for human review. Pipeline: task intake -> isolated workspace + repo checkout -> agent execution with scoped tool access -> recorded outputs (diffs, logs, tool calls, summaries) -> project-system writeback. Motto: "Automate boldly. Gate carefully. Keep the trail visible."

Notably, it is built on samen's exact stack: Elixir/OTP, Phoenix (dashboard on :4000), Ash for entity modeling, Oban for job processing, behaviour-based adapters across six extension points (project systems, code platforms, agent adapters, workflow templates, workspaces/runtimes, records). CLI launch is template-driven (`./bin/symphony --template linear/github/codex`), configured via env vars. License: AGPL-3.0-only (with Apache-2.0 Symphony portions).

## What samen could adopt

- **Workflow-template bundling for adapter combos** (`linear/github/codex` style named presets that wire N adapters into one runnable config). What: a named-preset layer over samen's existing adapter packages (e.g. `stripe/postmark/anthropic` host profiles) so `mix samen.gen.app` could take a `--stack` preset. Why it fits: samen already has fail-honest vendor adapters as separate packages; a preset name is a cheap DX win for the generator story. Effort: S.
- **Per-run isolated-workspace model as a meta-process idea** for samen's `_orch` autonomous loop: Maestro gives each agent run its own directory + repo checkout + scoped tools + recorded transcript, enabling parallel runs without cross-contamination. Samen's loop is serialized by convention (memory: serialize fan-outs) and file-based; if samen ever parallelizes autonomous tasks, git-worktree-per-task with recorded diffs/logs is the pattern to copy conceptually. Effort: M (process/tooling, not product code).
- **Agent-comparison runs** (same task to multiple agents, compare outputs) as an eval idea for samen's ADR-047 agent loop or the aiCRO-style eval harness: run the same governed agent task against fake vs live provider (or two prompts) and diff RunRecords. Samen already has bounded RunRecords, so this is a thin reporting layer. Effort: S/M.

All of these are pattern-level only — AGPL-3.0 is incompatible with MIT samen, so no code, only ideas.

## What to ignore and why

- **The platform itself**: it orchestrates coding agents against repos (dev tooling); samen's AI plane governs product-embedded agents over tenant data with masked egress and E3 approvals — different problem, and samen's ADR-047 loop is already built and gated.
- **Its Ash/Phoenix usage as a reference**: early-stage codebase (44 stars, "controlled environments/prototyping" status) with no visible test/verification discipline; samen (2,600+ core tests, 285 sabotage patches, 49 ADRs) is far deeper on the same stack — nothing to learn there.
- **Project-system adapters (Linear/TAPD) and code-platform adapters (GitHub/CNB)**: outside samen's product scope; samen's backlog is file-based `_orch/backlog.yaml` by deliberate convention, and its human-gated review flow already exists via gate reports.
- **License-encumbered anything**: AGPL-3.0-only means even vendoring snippets is a no-go for the MIT-published samen repo.
