---
project: Camelot
url: https://github.com/T0ha/camelot
category: Software Factories
relevance: medium
verdict: Same-stack (Elixir/Phoenix/Ash/Oban) Kanban control plane for Claude Code/Codex agents — not a foundry component, but its headless-Claude planning contract and session-adoption patterns map directly onto samen's _orch loop and ADR-047; GPL-2.0 means patterns only, never code.
---

# 017 — Camelot

## What the project is

Camelot (T0ha/camelot, GPL-2.0, ~10 stars, 247 commits, actively developed) is a self-hosted AI-agent orchestration platform: a Kanban board that delegates coding tasks to Claude Code and Codex CLI agents while keeping a human in the loop. Tasks move through a 6-stage state machine (todo → planning → executing → pr → done/cancelled); agents propose plans that a human approves before any code executes; sessions record full transcripts; GitHub integration syncs issues, tracks PRs, and monitors CI.

Notably, it is built on **exactly samen's stack**: Elixir 1.15+/Phoenix 1.8, Ash 3.0 + AshPostgres + ash_oban, Oban, LiveView 1.1, `simple_sat`, `req`, Tailwind. Architecture: Ash domains for Accounts (magic-link ash_authentication), Projects (memberships, env vars, MCP config), Board (Task/TaskMessage, PR-status checks), Agents (Agent/AgentTemplate/Session, priority dispatch via an Ash change), Prompts (per-project templates with variable interpolation), GitHub (App JWT, installation-token cache, webhook signature plug), and a `Runtime` layer: `AgentProcess` GenServers under a supervisor/registry, a `RunnerPool` with global and per-user caps, and pluggable runner backends — LocalPort (dev), Docker Engine, and Docker Swarm (socket-proxy topology, per-user Swarm secrets via `SecretSync`, node-label pinning, per-user profile volumes). A `Reconciler` recovers orphaned sessions after redeploys.

It is a *development-process* tool (a control plane for AI coding agents working on repos), not a SaaS substrate — so it is adjacent to samen's meta-process (`_orch/` autonomous loop, BATON runs) and to ADR-047's durable agent loop, rather than to samen's product kernel.

## What samen could adopt

1. **Planning output contract for headless Claude Code runs** (`docs/planning-output-contract.md`).
   - *What*: Planning-stage runs pass `--json-schema`, injecting a `StructuredOutput` tool that coexists with normal read-only tools; the agent must deliver `{decision: "plan"|"question", plan, questions[]}` via that tool, with an `--append-system-prompt` forbidding free-text questions. `OutputParser` reads the validated object from the final `result` event's `structured_output`, with a 7-level precedence fallback (structured → legacy ExitPlanMode denial → permission denials → free-text question scan over the full transcript → error/whole-transcript-as-plan). Invariant: a question always persists a message; a plan is never just the last assistant turn. They document the exact failure mode this fixes: ToolSearch/deferred-tool Claude Code builds don't register ExitPlanMode in headless mode, and `result` only carries the *last* turn, so plans/questions silently vanish.
   - *Why it fits samen*: samen's `_orch/` loop drives headless Claude sessions with per-task handoffs and verify verdicts; the "plan or question, structurally, via a schema-validated tool — never scraped from prose" pattern would harden task handoffs and any future `mix samen.gen.agent`-driven planning step against exactly this transcript-loss class of bug. It is also a ready-made answer for ADR-047 follow-ons if agent-loop steps ever need a plan/approve gate feeding the E3 approvals engine.
   - *Effort*: **S** (a prompt/flag convention + one parser precedence list; no new deps).

2. **Session adoption after restart** (`docs/session-adoption.md`).
   - *What*: Runner output is tee'd to a durable file and an exit-code marker is written *after* the tee (marker presence ⇒ output complete). On boot, a pure `recovery_action/4` in the Reconciler decides adopt-vs-fail per orphaned `:running` session; adoption rebuilds minimal state, re-attaches without consuming a new pool slot, polls for the marker, and finalises through the identical exit path as a live run, flagging `was_adopted`.
   - *Why it fits samen*: directly addresses the known samen-workflow pain "session-limit hits strand ≤1 agent; resume re-runs only the stragglers" (fan-out memory) — a durable-marker + adopt-don't-restart discipline would let `_orch` resume digest logic *reattach* to completed-but-unharvested work instead of re-running it. Also a good model for ADR-047 transcript durability across BEAM restarts (deferred graceful-drain is even called out as a separate concern, matching samen's honesty discipline).
   - *Effort*: **M** (marker/tee convention is small; a reconciler with a pure decision function + tests is a real but bounded piece).

3. **RunnerPool with layered caps + priority dispatch as an Ash change**.
   - *What*: `RUNNER_GLOBAL_MAX` / `RUNNER_PER_USER_MAX` with per-user override; task dispatch implemented as `Agents.Changes.DispatchTasks` (an Ash change), keeping orchestration decisions inside the resource layer; precedence chains for config (project pin > user pin > instance default).
   - *Why it fits samen*: samen's ADR-047 already has budgets/cost caps; the *layered cap with per-actor override + explicit precedence* shape is a clean pattern for fleet-level agent concurrency governance (fleet cockpit directives), expressed in Ash idioms samen already uses (changes, policy-visible config resources).
   - *Effort*: **S** (pattern transplant into existing Samen.AI/fleet resources).

4. **`usage_rules` + skills wiring in mix.exs**.
   - *What*: the `usage_rules` hex package compiles dependency usage-rules into `CLAUDE.md` and generates `.claude/skills` entries (e.g. an "ash-framework" skill aggregating `:ash, ~r/^ash_/` rules), so the AI author always has current library conventions.
   - *Why it fits samen*: samen is 100% AI-authored and already encodes knowledge as infra (verify.sh, repo CLAUDE.md); auto-deriving Ash/Phoenix usage rules from the exact pinned dep versions would reduce drift between CLAUDE.md guidance and ash ==3.31.2 reality. Dev-only dep, zero runtime footprint, no INV-4 conflict.
   - *Effort*: **S** (add dev dep + config block, regenerate).

5. **Reference-read only: containerized runner isolation** (`docs/cluster-runners.md`, `Runtime.Runner.{DockerEngine,Swarm}`).
   - *What*: every agent CLI runs in an isolated container scheduled by Docker Swarm, reached through `tecnativa/docker-socket-proxy` with a minimal API surface (SERVICES/TASKS/NETWORKS/NODES/SECRETS only); per-user credentials become Swarm secrets (`SecretSync`); three documented daemon-access topologies.
   - *Why it fits samen*: if samen ever executes agent tool-use with filesystem/shell reach (beyond today's ADR-047 governed egress), this is the closest same-stack prior art for the isolation story, including the honest failure modes. For now it is a design reference, not a build item.
   - *Effort*: **L** (whole subsystem; defer until a concrete need exists).

## What to ignore and why

- **All code verbatim**: GPL-2.0 vs samen's MIT — patterns and docs are fair game; copied code is not. Every adoption above must be a re-implementation.
- **ash_cloak/cloak for secrets** (`Camelot.Vault`): samen's ADR-003 explicitly rejected AshCloak/Cloak in favor of the thin OTP `:crypto` vault with KMS-driven per-subject keys and crypto-shred; Camelot's simpler symmetric-key vault has no shred/masking semantics and would be a regression.
- **ash_authentication / magic links**: samen deliberately built its generator-emitted identity spine (ADR-035) and rejected ash_authentication rewrites; nothing here changes that calculus.
- **GitHub App integration machinery** (JWT, installation token cache, webhook plug): samen's product has no GitHub surface; its dev loop uses `gh`. Not worth carrying.
- **PostHog telemetry**: conflicts with samen's no-PII-egress posture and first-party observability; samen already strips db_statement from OTel spans.
- **The Kanban UI itself**: samen's Scopes.work (Project/Task with subtree cascade) plus the operator plane already cover task surfaces; Camelot's board is table-stakes LiveView, nothing samen's UI kit lacks.
- **As a tool to run samen's own burn-downs**: tempting (it literally orchestrates Claude Code against repos), but samen's `_orch` conventions (phase gates running full ci.sh foreground, decompose-cross-cutting rules, verify verdicts) are more disciplined than Camelot's generic stage machine; adopting the two specific mechanisms above beats adopting the platform.
