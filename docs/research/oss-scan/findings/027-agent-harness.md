---
project: Agent Harness
url: https://github.com/nyelbangash/agent-harness
category: Software Factories With License Warnings
relevance: low
verdict: Unlicensed zero-star personal coding-agent daemon; nothing adoptable as code, only two small idea-level echoes samen has mostly already built.
---

# 027 — Agent Harness

## What the project is

A "personal, always-on agentic development system": an Elixir/Phoenix/LiveView daemon that watches the author's own GitHub issues, triages them into auto/plan/skip lanes, generates implementation plans, and opens PRs autonomously (never touching default branches). It runs as a macOS launchd LaunchAgent on `127.0.0.1:4040` with a "Mission Control" LiveView dashboard (vintage gauges, issue board, live run console, ideation tree, budget panel). Stack: Phoenix + LiveView, Oban for scheduling, **SQLite** (single-writer), Claude via subscription OAuth (boot refuses if `ANTHROPIC_API_KEY` is set), Tailscale for remote access, ntfy.sh notifications.

Maturity signals: 0 stars, 161 commits, single author, ~184 tests, decent docs (MANUAL.md etc.), GitHub Actions present. **No license file** — the code is all-rights-reserved by default, so nothing can be legally copied regardless of merit.

Domain mismatch is fundamental: this is a single-user coding-agent factory for personal repos; samen is a multi-tenant Elixir/Ash/Postgres SaaS substrate whose agent story (ADR-047) is governed in-product tool use, not repo automation. Samen also already evaluated-and-rejected an external agent framework (Jido) and built its own loop.

## What samen could adopt (ideas only — no code, unlicensed)

1. **Hot-reloadable operating-mode policy with utilization gates** (`ops/policy.yaml`: plan_only / full_auto / paused; API-utilization thresholds auto-tighten the mode; weekly overflow cap hard-pauses everything).
   - Why it fits: samen's agent loop has budgets/cost caps and the automation engine has Health/Breaker, but an operator-visible *global posture dial* ("all AI to plan-only fleet-wide when spend crosses X") is a clean articulation of graduated degradation that could live in the operator plane / fleet directives.
   - Effort: S–M (a mode enum + policy check at the AI chokepoint + operator UI toggle; samen already has the breaker and budget primitives).

2. **`mix harness.doctor`-style environment preflight** (one task validating credentials/config before the daemon runs).
   - Why it fits: samen's fail-honest posture already names missing secrets at use time; a `mix samen.doctor` that sweeps adapter configuration up front (Stripe/ESP/KMS/AI live lanes, DB, Oban) would improve the operator on-ramp for the labeled operator-TODO infra.
   - Effort: S (walk adapters' `configured?` checks and print a table).

Both are convergent-evolution ideas to reimplement from scratch, not extractions.

## What to ignore and why

- **Everything as code**: no license ⇒ legally unadoptable; also 0 stars, one author, no community vetting.
- **SQLite single-writer model**: directly contradicts samen's Postgres-only, multi-tenant, crypto-shred architecture.
- **GitHub issue → PR pipeline, launchd daemon, Tailscale serve**: personal-dev-workflow concerns, not SaaS-substrate concerns; samen's `_orch/` autonomous loop already covers samen's own build automation differently.
- **Subscription-OAuth-only AI auth**: an anti-API-key stance for a personal tool; samen's provider adapters are the correct shape for a product.
- **Dashboard aesthetics (vintage gauges, ideation tree)**: charming but irrelevant to samen's operator cockpit requirements.
