---
project: Codrift
url: https://github.com/filipecabaco/codrift
category: Software Factories With License Warnings
relevance: low
verdict: Elixir-based desktop cockpit for running coding agents in worktrees — dev-process tooling, not SaaS-foundry substrate; a couple of small ideas (agent shared-memory grounding, skills-as-distribution) are worth noting, nothing worth depending on.
---

# 028 — Codrift

## What the project is

Codrift (by Filipe Cabaço, of Supabase Realtime) is a native desktop app for running multiple AI coding agents — Claude Code, Codex, Opencode, Gemini, Copilot, Cursor, plain shells — simultaneously across project directories. Tech stack: Tauri (Rust shell) sidecar-spawning an Elixir server (Francis micro-framework + Bandit on port 43117), Svelte + xterm.js frontend, SQLite (FTS5) persistence, erlexec for PTY management.

Key features:
- **Initiatives**: named work units grouping directories, with `planning → ongoing → done → archived` states.
- **Git worktrees per directory** on `codrift/{id}/{slug}` branches, isolating agent changes until merge.
- **Shared memory**: per-initiative SQLite FTS5 knowledge base agents write decisions/snippets to and search before starting.
- **MCP server** (JSON-RPC 2.0 over HTTP POST + SSE) exposing initiative/agent/memory/integration tools; local token auth from `~/.codrift/auth-token`.
- **Integrations**: OAuth2 (PKCE + device flow) imports from GitHub Issues/Projects, Linear, GitLab; credentials stay local.
- **Skills distribution**: `npx skills add filipecabaco/codrift` installs prompting frameworks that teach each agent CLI to use the memory/MCP tools.

OTP shape: single root supervisor; Registry-based process lookup; DynamicSupervisors spawning per-agent GenServers wrapping erlexec PTYs; behaviour modules (`Agent`, `Integration`) as pluggable adapters; all actions routed through one `Codrift.Core` operation layer.

Status: early-stage (~83 commits, 6 stars), actively maintained solo project with real release engineering (Homebrew, notarization, Conventional-Commits semver CI). Manifest flags a license warning: README claims MIT but the repo lacks a LICENSE file — treat as unlicensed for code reuse until that lands.

## What samen could adopt

Nothing structural — Codrift solves the *development-time* multi-agent-cockpit problem, which samen already handles differently (Claude-Code-driven `_orch/` backlog DAG, serialized fan-outs, foreground gates). Two small idea-level takeaways:

1. **Per-initiative shared-memory grounding for agents** (idea only, no code). Codrift's pattern — agents search an FTS5 knowledge base of prior decisions before starting, and record findings after — maps onto samen's open G22 (agent-grounding packaging for builders). Samen already has a stronger substrate (machine-readable catalog, pgvector embeddings, MCP server); the adoptable bit is the *loop contract*: "search memory → check sibling activity → record decision" baked into the tool prompts. Why it fits: it would make samen's MCP server more useful for multi-session builder workflows without new deps. Effort: S (prompt/tool-description work on the existing MCP surface).

2. **Skills-as-distribution for agent onboarding** (idea only). `npx skills add <repo>` installing per-agent-CLI prompting configs is a neat packaging trick for G22: samen could ship a "samen skill" that teaches an external Claude Code/Codex session how to use the catalog + MCP tools. Effort: S–M (packaging + docs; no runtime change).

Not adoptable but worth a nod: Codrift's single `Codrift.Core` operation layer echoes samen's chokepoint-everything discipline — validation that the pattern travels, not something to import.

## What to ignore and why

- **The whole desktop/Tauri/PTY stack** (erlexec, xterm.js, sidecar pattern): dev tooling, orthogonal to a SaaS runtime. Samen's agent loop (ADR-047) is in-app durable tool use, not spawning external CLIs — and ADR-047 explicitly bans raw process spawns.
- **Francis + Bandit-on-a-port sidecar**: samen is Phoenix; no reason to look at a micro-framework.
- **SQLite/JSON-file persistence, fresh-connection-per-call memory access**: samen is Postgres-only by conviction; these are hobby-scale choices.
- **In-memory OAuth state, local file tokens**: far below samen's vaulted-credential and audit bar.
- **Code reuse of any kind**: license warning (MIT claimed in README, no LICENSE file) makes the repo legally unusable as a dependency or copy source; combined with 6 stars/solo bus-factor, treat as reference reading only.
- **Jido-style temptation**: samen already evaluated and rejected external agent frameworks; Codrift is even further from samen's governance model (no approvals engine, no egress governance, no masking concept).
