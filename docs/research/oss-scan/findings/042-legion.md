---
project: Legion
url: https://github.com/software-mansion-labs/legion
category: Agent Frameworks and Development Tools
relevance: medium
verdict: Credible Elixir agent framework whose code-execution model conflicts with samen's governed-egress design, but its Lua sandbox, AST denylist, binding-scope semantics, and telemetry taxonomy are worth mining for samen's first-party agent loop.
---

# 042 — Legion (Software Mansion Labs)

## What the project is

Legion is an MIT-licensed Elixir framework (v0.4.0, ~103 stars, 41 commits — young but from Software Mansion, a serious shop) for AI agents that "live inside your application and get things done by writing code." Instead of classic tool-calling round trips, the LLM emits code snippets (Lua by default, optionally Elixir) that execute in a sandbox; tool functions are the only bridge out. Key pieces:

- **Tools**: plain Elixir modules with `use Legion.Tool`; the LLM reads the module source and calls public functions. Third-party modules exposed via `extra_source_modules` config, no wrappers.
- **Agents**: `use Legion.Agent` modules declaring `tools/0`, optional `config/0`, `system_prompt/0`, `output_schema/0` (typed structured output), `tool_config/1`. Agents are BEAM processes (`Legion.start_link/2`, `call/3`, `cast/2`), poolable with `:pg`.
- **Sandboxes**: (1) Lua — pure-Elixir Lua 5.3 VM (`lua` hex package); generated code cannot reach the BEAM at all. (2) Elixir — dangerous constructs (`defmodule`, `import`, `spawn`, `send`, `apply`) blocked at AST level plus a module allowlist.
- **Delegation**: `Legion.Tools.AgentTool` gives a parent agent scoped sub-agents (process-linked); `Legion.parallel/2` fan-out, `Legion.pipeline/1` chaining.
- **Human-in-the-loop**: `Legion.Tools.HumanTool` suspends execution mid-run and message-passes `{:human_request, ref, from_pid, question, meta}` to a handler process with a timeout.
- **Persistence**: Postgres store, resume by `agent_id` across restarts/deploys, optional intermediate-step checkpointing.
- **Credential isolation**: integrates dimamik/vault so auth context is reachable by tool functions at runtime but never visible to generated code.
- **Config**: `model` (ReqLLM format), `max_iterations`, `max_retries`, `sandbox`, `sandbox_timeout`, `binding_scope` (`:iteration` | `:turn` | `:conversation` variable persistence), `max_message_length`.
- **Observability**: telemetry events at agent-lifecycle / per-message / per-iteration / LLM-request / sandbox-eval levels, `Legion.Telemetry.attach_default_logger()`. Companion `legion_web` LiveView dashboard shows conversation traces and generated-code inspection.
- LLM access via ReqLLM (multi-provider).

## What samen could adopt

Samen already has a first-party agent loop (ADR-047, zero new deps, Jido and ash_ai rejected) governed by the EG2 egress class and the E3 approvals engine, so the framework itself is not a candidate. The mining targets are:

1. **AST denylist checklist for sandbox/anti-bypass hardening** — *what*: Legion's Elixir-sandbox blocklist (`defmodule`, `import`, `spawn`, `send`, `apply`) plus module allowlisting. *why it fits*: samen already ships AST anti-bypass probes and a raw-spawn AST lock (`mix samen.verify.agent_coverage`); diffing Legion's construct list against samen's lock is a cheap adversarial audit and may surface misses (e.g. `apply/3` indirection). *effort*: **S** (audit + add sabotage patches for any gap).

2. **Binding-scope semantics as a red-team eval case** — *what*: Legion's `:iteration`/`:turn`/`:conversation` variable persistence. *why it fits*: samen's per-turn history grant re-scrub (ADR-047) assumes turn history is the only carry-over channel; any conversation-scoped state (bindings, cached tool results) is a lane where a revealed value could outlive its grant. Encode "state persisted across turns must be re-scrubbed like history" as an explicit eval-tier case even though samen has no bindings today. *effort*: **S**.

3. **Telemetry event taxonomy for the agent loop** — *what*: leveled events (lifecycle / message / iteration / LLM request / sandbox eval) with an attachable default logger. *why it fits*: samen has wide_event + observability but the digest shows no per-iteration agent-loop event granularity; this taxonomy maps cleanly onto Samen's loop turns and budget accounting, and feeds the fleet cockpit. *effort*: **S–M**.

4. **Operator-plane agent-run trace surface** — *what*: legion_web's LiveView dashboard concept — per-conversation traces with inspectable per-step inputs/outputs. *why it fits*: samen's operator plane already owns first-party admin UX (ash_admin rejected); an agent-run trace view (masked by default, reveal-gated) makes ADR-047 transcripts operable and supports the G22 agent-grounding packaging theme. Build first-party, borrow the information architecture only. *effort*: **M**.

5. **Suspend/resume run state for approval-gated steps** — *what*: HumanTool's pattern of pausing an in-flight run on a `{:human_request, ...}` and resuming on answer/timeout. *why it fits*: samen routes side effects through E3 approvals as drafts/proposals; modeling "awaiting_approval" as an explicit AshStateMachine state on agent runs (like Automation.Run) would let a multi-step run continue automatically after grant instead of dying and restarting. *effort*: **M**.

6. **(Exploratory, flagged not recommended near-term) Lua-sandboxed compute step** — *what*: the `lua` hex package (pure-Elixir Lua 5.3, no NIF — matches samen's simple_sat posture) as a governed "compute over already-masked tool results" step, cutting LLM round trips for filter/branch/loop work. *why it fits*: it is the one code-execution variant compatible with samen's chokepoint, since generated code and its inputs/outputs are all EG2 governed egress and Lua structurally cannot reach the BEAM. *effort*: **L**, and only if loop-latency/cost budgets become a measured problem.

## What to ignore and why

- **The core execution model (LLM writes code as the primary action)** — directly at odds with samen's "AI writes do not exist" invariant and token-blind egress; generated code is a vast audit/masking surface samen deliberately avoids.
- **ReqLLM multi-provider integration** — violates INV-4 (no vendor/HTTP deps in core); samen's `Samen.AI.Provider` behaviour + `samen_anthropic` with `%MaskedPayload{}`-only acceptance is stronger.
- **dimamik/vault credential isolation** — process-context hiding is weaker than samen's KMS-backed vault chokepoint with crypto-shred; nothing to gain.
- **AgentTool delegation / parallel / pipeline** — samen's ADR-047 governs spawn via the raw-spawn AST lock and coverage floor; adopting free-form sub-agent fan-out would reopen exactly what that lock closes.
- **Postgres persistence store** — samen already has durable transcripts with erasure-envelope compliance (ADR-046); Legion's store has no masking/retention story.
- **Maturity as a dependency in general** — v0.4.0, 41 commits; API churn is likely, another reason to mine patterns rather than depend.
