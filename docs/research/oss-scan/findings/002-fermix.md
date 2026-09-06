---
project: Fermix
url: https://github.com/tezra-io/fermix
category: AI and Agents
relevance: low
verdict: Well-crafted single-user personal-agent daemon; wrong problem domain for samen — only a few small agent-loop robustness ideas worth borrowing.
---

# What the project is

Fermix is a self-hosted, single-user personal AI agent daemon written in Elixir (>= 1.17, OTP >= 28). It runs as one BEAM VM under OTP supervision (`:rest_for_one` core supervisor, persistent `MainAgent` process, `Gateway.Queue` FIFO per conversation), fronted by Phoenix for a setup UI and webhook ingress. It connects to Telegram/WhatsApp/Slack/Discord/Signal/CLI channels, supports seven LLM providers with fallback chains, and ships ~30 built-in tools (shell, file, git, web search, browser automation, subagents, skills, memory, scheduled jobs) through a `Capabilities.Capability` behaviour + `Capabilities.Registry` GenServer that also unifies MCP tools and HTTP-template plugins. Memory is two-layer (ETS/GenServer hot path over canonical SQLite), with post-turn fact extraction and automatic context compaction at 85% of the context window. Distribution is a Burrito-packaged self-contained binary with launchd/systemd service units, config in `config.toml` + OS keychain, JSONL traces, and `/health/live` + `/health/ready` endpoints. Alpha maturity: pre-1.0, ~9 stars, ~700 commits, but with real engineering discipline (`mix quality` = format + warnings-as-errors + strict Credo + Dialyzer + tests; deterministic mock-provider benchmarks via `mix fermix.bench`).

# What samen could adopt

- **Repeated tool-call loop detection in the agent loop.** Fermix's `AgentLoop` detects when the model issues the same tool call repeatedly and breaks the cycle, in addition to a hard iteration cap. Samen's ADR-047 loop has budgets/cost caps but (per digest) no repeated-call pattern detector; it is a cheap robustness layer that saves budget before the cap trips and produces a more honest failure reason. Effort: S.
- **Per-subsystem structured readiness.** Fermix's `/health/ready` reports config/provider/channel status as structured readiness, not a bare 200. Samen shipped `/readyz` (G11), and its fail-honest adapters already know their own `:not_configured` state — surfacing adapter/provider configured-ness in readiness output would make the honest-degradation story operable from probes and feed the fleet cockpit's honest-degradation reporting. Effort: S.
- **Deterministic agent-loop benchmark tier.** `mix fermix.bench` runs dispatcher/agent-loop/adapter/soak scenarios against a mock provider for reproducible numbers. Samen already has the deterministic fake AI provider in CI; a small `samen.bench.agent` soak tier on top of it would catch loop/regression perf drift the correctness gate cannot see, and fits samen's claim-with-evidence culture. Effort: M.
- **Conversation compaction with memory survival.** Fermix summarizes older messages at a token threshold while preserving long-term memory and scheduled jobs. Samen's agent loop retains transcripts under the erasure envelope (ADR-046) but long multi-step runs will eventually hit context limits; a compaction step is the natural extension — with the samen-specific twist that any summary must be minted through the EG2 masking chokepoint and re-scrubbed like other history. Effort: M.
- **Post-turn extraction ordering as a pattern.** Fermix runs memory extraction only after the user-visible reply succeeds, so enrichment can never fail a response. Samen mostly has this via same-transaction Oban enqueues; worth keeping as an explicit convention for future AI-surface enrichment steps. Effort: S (convention, not code).

# What to ignore and why

- **The entire product shape** (single-user local daemon, chat-platform channels, Telegram/WhatsApp adapters, macOS voice companion): samen is a multi-tenant SaaS substrate; none of this transfers.
- **Burrito self-contained binaries + launchd/systemd packaging**: samen deploys Phoenix apps to cloud infra (Fly/Neon per roadmap), not end-user binaries.
- **SQLite memory store**: samen is Postgres-first with pgvector already required; nothing to learn here.
- **Ungoverned tool execution model** (shell/file/git tools with user `/confirm` grants): strictly weaker than samen's E3 approvals engine with requester-not-approver enforced at policy and DB-CHECK layers; adopting any of it would be a regression. Fermix has no PII masking, no egress governance, no audit chain.
- **cosign plugin signing**: samen distributes nothing (in-monorepo by ADR-033, no Hex packages, skills/plugins concept rejected in favor of scope blueprints); signature verification solves a distribution problem samen deliberately does not have.
- **Provider fallback chains across seven vendors**: samen's AI plane is deliberately single-chokepoint with a governed Anthropic adapter; multi-provider fallback would multiply the masked-egress verification surface for little value.
