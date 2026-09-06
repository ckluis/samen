---
project: RawPair
url: https://github.com/rawpair/rawpair
category: Developer Tools
relevance: low
verdict: Same Elixir/Phoenix stack but a pre-alpha, single-shared-secret, ephemeral-container pair-programming tool with no tenancy, auth spine, or PII surface — almost nothing structural transfers to a SaaS foundry.
---

# RawPair — evaluation vs samen

## What the project is

RawPair is a **self-hosted, real-time collaborative dev environment**: it spins up one isolated Docker container per pairing session with a shared Monaco code editor (synced via Yjs CRDT) and a shared terminal (ttyd + tmux over a Phoenix Channel), fronted by Nginx, with an optional Vector/Loki/Grafana observability stack and a Go-based install CLI. Elixir/Phoenix (plain Phoenix + Ecto, no Ash) is 130KB of the codebase, Go (CLI) 32KB, TypeScript/JS (yjs-server + frontend assets) ~33KB combined.

Status: **pre-alpha**, MPL-2.0, 70 stars / 7 forks / 31 open issues, last push 2025-10-12 (~10 months stale as of this scan), 251 commits. `mix.exs` deps: phoenix ~>1.7.21, phoenix_live_view ~>1.0, ecto_sql, postgrex, bandit, swoosh, finch — a standard, unremarkable Phoenix stack.

Architecture, confirmed by reading the source:
- `RawPair.Docker.WorkspaceManager` shells out (via a `DockerClient` wrapper) to launch a per-workspace container plus an optional DB sidecar (Postgres/MySQL/MariaDB), with static random port assignment (`Enum.random(6000..6999)`) and per-workspace CPU/mem/swap limits.
- `RawPair.Terminal.TerminalBridge` + `RawPairWeb.TerminalChannel` bridge a Phoenix Channel to ttyd/tmux for shared shell access.
- Router (`router.ex`) has **no authentication pipeline at all** — a bare `/enter` POST and `/logout` DELETE (a shared-passphrase gate, not an identity system), and the README explicitly warns operators not to expose it publicly without adding their own auth. No org/user/RBAC model exists.
- LiveView surfaces: `DashboardLive`, `RoomLive`, `WorkspaceLive` (CRUD over ephemeral container lifecycle).

This is a single-operator internal tool for spinning up throwaway pairing sandboxes — not a multi-tenant product, and it doesn't attempt to be one.

## What samen could adopt

- **Docker CLI wrapper module as a `System.cmd`-shelling adapter pattern** — What: a small, isolated `Docker.Client` module (launch/stop/list_files) that all container lifecycle calls funnel through, with resource-limit defaults as module attributes. Why it fits: if samen ever ships a "spin up a live per-tenant sandbox" feature (e.g., for `mix samen.gen.app` demo hosting, or an eval/spike runner), this is a clean small reference for a single chokepoint-shaped wrapper around `System.cmd("docker", ...)` — consistent with samen's own chokepoint idiom, just for infra rather than PII. Effort: S (pattern only, not code — samen's fail-honest-adapter convention already covers the "docker not available" case better).
- **ttyd/tmux-over-Phoenix-Channel terminal bridging** — What: a WebSocket channel proxying a tmux-attached ttyd process. Why it fits: narrow, speculative use only if samen's operator plane ever wants an embedded "shell into this sandboxed environment" affordance for support/debugging; not on any current roadmap item. Effort: S to spike, but no concrete samen need today.

Neither rises above "nice to have if a matching need appears" — nothing here fills an open gap in the digest (G8–G28 roadmap items are all product/compliance depth, not dev-sandbox tooling).

## What to ignore and why

- **The entire multi-tenancy/auth absence**: RawPair has no identity spine, no org model, no RBAC — the opposite of what samen needs to adopt from anywhere. Nothing to lift; samen's ADR-035 identity spine is already far ahead of this.
- **Yjs/Monaco collaborative editing**: solves live multi-cursor code editing, a problem samen doesn't have (samen's chat surface is catalog-driven object unfurl, not code editing); pulling in Yjs/CRDT machinery would be a large unjustified dependency for zero current samen use case.
- **Ephemeral per-session container orchestration as a product feature**: RawPair's whole reason to exist (spin up isolated dev sandboxes) is orthogonal to samen's reason to exist (PII-governed multi-tenant SaaS substrate); adopting this domain would be scope creep, not hardening.
- **Observability stack (Vector/Loki/Grafana/Portainer)**: generic self-hosting boilerplate, no samen-specific insight; samen already has its own observability subsystem (`samen_core/lib/samen/observability`) tied to its masking/audit invariants, which generic Loki wiring doesn't address.
- **Go CLI installer / Ansible / Cloudflare dirs**: install/ops tooling for RawPair's own self-hosting story, not transferable architecture.
- **Pre-alpha status and 10-month-stale last push**: low confidence this project itself will mature into a reference worth re-checking later.
