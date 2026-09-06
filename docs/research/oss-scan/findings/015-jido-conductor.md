---
project: jido-conductor
url: https://github.com/jmanhype/jido-conductor
category: Agent Platforms With License Warnings
relevance: low
verdict: Early-prototype Tauri desktop UI for the Jido framework samen already evaluated and rejected; nothing here samen needs.
---

# 015 — jido-conductor

## What the project is

jido-conductor is an early-stage desktop application for managing and orchestrating agents built on the Jido Elixir agent framework (~1.2.0). Three-tier architecture: a Tauri 2.0 (Rust) desktop shell, a React 18 / TypeScript / Vite / Tailwind / shadcn/ui / Zustand frontend, and an Elixir/Phoenix service on port 8745 doing the actual agent orchestration (SQLite in dev, Postgres in prod). Features: a template gallery consuming `.jido.zip` archives described by a `conductor.json` manifest, Zod/schema-validated parameter forms for configuring runs, isolated workspace execution via shell scripts, SSE log streaming into the desktop UI, and per-run budget/cost tracking.

Maturity is prototype-grade: 4 stars, 26 commits, no packaged releases, a single configuration test file rather than a test suite, and only partial HTTP API wiring between the tiers. The manifest flags a license warning — the README claims MIT but the repo carries no LICENSE file (the fetched page reports MIT; the missing-file discrepancy stands until upstream adds one), so treat it as not-safely-licensed for code reuse.

## What samen could adopt

Little to nothing directly — samen has already litigated the core question this project sits on: Jido itself was formally evaluated and **rejected** (`/Users/clank/Desktop/projects/samen/_orch/jido-eval-report.md`), and ADR-047 shipped a first-party durable agent loop with zero new dependencies, EG2 governed egress, and E3 approvals gating all side effects. A desktop front-end for the rejected framework inherits that rejection.

Marginal idea-level (not code-level, given the license gap) takeaways:

- **Per-run budget/cost tracking surfaced in the operator UI** — what: show agent-run cost caps and burn as first-class UI, not just enforcement. Why it fits: ADR-047 already has budgets/cost caps in the kernel; a fleet-cockpit or operator-plane read surface for them is a natural G-register-style polish item. Effort: S (read-only LiveView over existing RunRecord/budget data).
- **Manifest-described, parameter-schema'd run templates** (`conductor.json` pattern) — what: declarative agent-run templates with validated parameters. Why it fits: rhymes with samen's catalog-as-data posture and could feed `mix samen.gen.agent` presets or the G22 agent-grounding packaging theme. Effort: M, and only worth revisiting when G22 is actually scheduled.
- **SSE log streaming of agent runs to an operator view** — what: live run-transcript streaming. Why it fits: samen deliberately deferred AI streaming (ADR-047); this is a reminder of the UX payoff, not an implementation to copy — any samen version must pass the EG2 masking chokepoint per chunk. Effort: L (interacts with the deferred-streaming decision).

## What to ignore and why

- **The entire codebase as a dependency or fork source**: license file missing despite MIT claim; prototype quality (1 test file — the antithesis of samen's sabotage-verified discipline); and it front-ends Jido, which samen rejected.
- **Tauri/React desktop shell**: samen is a two-plane Phoenix/LiveView web substrate; a desktop shell contradicts the operator-plane architecture and adds a JS/Rust toolchain for no capability gain.
- **SQLite-dev/Postgres-prod split and shell-script workspace isolation**: samen is Postgres-only with OTP-native isolation; these patterns solve problems samen does not have.
- **Its orchestration model generally**: samen's agent loop is governed egress + approvals-gated writes by construction; jido-conductor has no comparable trust boundary, so its flows cannot be lifted without re-deriving them inside samen's chokepoints — at which point nothing of the original remains.
