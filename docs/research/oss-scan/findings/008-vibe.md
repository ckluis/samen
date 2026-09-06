---
project: Vibe
url: https://github.com/elixir-vibe/vibe
category: AI and Agents
relevance: medium
verdict: BEAM-native coding agent with excellent OTP session/subagent supervision and multi-surface attach UX worth borrowing; its eval-first control plane is the structural opposite of samen's governed-egress AI plane and must not be adopted.
---

# 008 — Vibe

## What the project is

Vibe (MIT, ~99 stars, 629 commits, actively developed, part of the `elixir-vibe` org) is an experimental **BEAM-native local coding agent** for Elixir/OTP projects. Instead of wrapping a chat loop around shell commands, it runs as a real OTP application: sessions, command jobs, plugin workers, subagents, telemetry collectors, and UI state are all supervised processes that can be monitored, cancelled, resumed, and inspected. It ships two surfaces over the *same session processes* — a TUI (`vibe`) and a Phoenix LiveView web console (`vibe --web`) — with tmux-like attach/detach against a singleton background server.

Distinctive design choices:
- **Eval-first control plane**: few model-facing tools; the model instead gets an Elixir eval context with rich aliases (`Cmd` = supervised shell with persisted output, `Web`, `MD`, `Goal`), and intermediate values persist across the session (Livebook-style). Motto: "Few model-facing tools outside; many BEAM powers inside."
- **Provider neutrality via ReqLLM** ("provider:model" strings), fuzzy model matching, reasoning-effort shorthand (`/effort medium`), OAuth login for Codex.
- **Storage**: everything (sessions, eval snapshots, memory, telemetry, imported history) in local SQLite under `~/.vibe`, with full-text search; `Vibe.Context.recall/2` does location-aware retrieval.
- **Plugins**: Rules (markdown files from `~/.vibe/rules/` injected into system prompts, with per-model filtering), Safety (confirmation before risky ops), Notify, Question, WebSearch.
- **Skills**: trusted Elixir files discovered from `priv/skills`, `./.vibe/skills`, `~/.vibe/skills`; users can list, inspect, and *create skills from session history*.
- **Subagents**: child sessions with independent lifecycle/state for parallel research and background chains; SSH/Erlang-distribution attach to remote nodes; hot code reload during dev.

It is a **developer tool**, not a SaaS platform: no multi-tenancy, no PII posture, no billing/identity, explicit "not production-ready, can take actions on your machine" warning.

## What samen could adopt

1. **Multi-surface attach over one session process (TUI/LiveView as adapters).**
   *What*: Vibe's principle "UI state is semantic; terminal and web rendering are adapters" — one supervised session process, any number of attached clients, survive disconnects.
   *Why it fits*: samen's ADR-047 agent loop is durable but the operator plane could expose *live attach* to a running agent session (watch turns stream, from cockpit or fleet view) the way Vibe's web console attaches to a TUI session. Strengthens the operator-cockpit-v2 roadmap theme without new deps — pure LiveView + the existing agent-run state machine.
   *Effort*: **M**.

2. **First-class inspect/cancel/resume verbs on agent runs.**
   *What*: every Vibe job/subagent is a supervised process with monitor/cancel/resume/inspect as core operations, not afterthoughts.
   *Why it fits*: samen's agent loop has budgets/caps and transcript retention; an operator-facing "kill this run now / resume from turn N / inspect intermediate state" verb set (audited, approvals-gated where mutating) is the natural next increment and matches samen's honest-degradation posture. Mostly wiring existing OTP + AshStateMachine machinery to operator UI.
   *Effort*: **M**.

3. **"Create skill from session history" for agent-grounding packaging (G22).**
   *What*: Vibe distills a successful session into a reusable, versioned skill file discovered from well-known paths.
   *Why it fits*: samen's open G22 gap is packaging the agent-grounding differentiator for builders. A samen equivalent — distill an approved agent transcript into a catalog-grounded Prompt resource / reusable playbook (going through the normal review/approvals path, never auto-trusted) — is a concrete, differentiating shape for that work.
   *Effort*: **M**.

4. **Rules-directory pattern with per-model filtering.**
   *What*: markdown rule files merged into system prompts, filterable by model.
   *Why it fits*: cheap operator ergonomics on top of samen's existing Prompt resource — per-org/per-surface standing instructions stored as data (already catalog-visible, already inside the masking chokepoint since prompt assembly is chokepointed). Small delta over what exists.
   *Effort*: **S**.

5. **UX niceties: fuzzy model selection, `/effort` shorthand, `@file` attachment syntax.**
   *What*: small affordances in Vibe's TUI/console.
   *Why it fits*: direct lift for samen's operator AI surfaces and MCP-adjacent tooling; no architectural impact.
   *Effort*: **S**.

## What to ignore and why

- **The eval-first control plane (the core idea).** Handing the model an open Elixir eval context is structurally incompatible with samen's guarantees: arbitrary eval bypasses the AI egress chokepoint (EG2), the MaskedPayload discipline, and "AI writes do not exist — everything mutating goes through E3 approvals." Vibe optimizes for power on a trusted dev box; samen optimizes for governance by construction. Adopting eval would un-prove samen's hero claim.
- **ReqLLM as provider layer.** Vendor/HTTP deps are banned from `samen_core` (INV-4), and samen deliberately hand-built `samen_anthropic` so providers can only accept chokepoint-minted `%MaskedPayload{}` (refusal by FunctionClauseError). A generic provider lib that takes raw strings would reopen exactly the hole samen closed. At most a reference when writing additional adapter packages.
- **SQLite + FTS memory layer.** Samen is Postgres-only with tsvector + pgvector already integrated with the catalog and PII classifier; a second local store would fragment the erasure envelope (crypto-shred completeness) and the destruction oracle's tier sweep.
- **Confirmation-prompt Safety plugin as an approvals model.** Samen's approvals engine (requester ≠ approver at policy AND DB-CHECK layers, same-transaction Oban auto-revoke) is strictly stronger than an interactive y/n prompt; nothing to import.
- **Hot code reload / remote-node attach for agents.** Dev-box conveniences that conflict with samen's release/verifier discipline and would be unaccountable mutation channels in a two-plane production system.
