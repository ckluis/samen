---
project: Neoharness
url: https://github.com/Neofox/neoharness
category: Agent Platforms With License Warnings
relevance: medium
verdict: Unlicensed one-person Elixir agent runtime — no code may be reused, but its agent-loop hardening patterns (duplicate-call guard, 3-level context-overflow recovery, ETS cancel flags, fuse breaker) are concrete, clean-room-adoptable upgrades for samen's ADR-047 loop.
---

# 016 — Neoharness

## What the project is

Neoharness ("my own take on openclaw") is a personal-agent runtime on Elixir 1.19+/OTP 27+, Phoenix LiveView, Postgres, and Oban, driving OpenAI-compatible chat-completions endpoints. Single BEAM node, single user, ~178 commits, 0 stars, last push 2026-07-14. **License warning confirmed**: the README claims MIT, but the repo has no LICENSE file and the GitHub API reports `license: null` — legally all-rights-reserved, so no code or prose may be copied; patterns only, clean-room.

Feature set: one GenServer per conversation (`Agent.Loop.run/2` — LLM call → tool calls → results → repeat, bounded), ~30 built-in tools (memory, web, shell, image gen, browser, MCP), personas with hot-reloaded `SKILL.md` files, persona-scoped hybrid memory (tsvector + optional pgvector/OpenAI embeddings), Oban heartbeat/cron scheduled prompts, Telegram (ExGram) / Discord (Nostrum) / LiveView connectors, MCP **client** pool (Hermes clients under a DynamicSupervisor, `~/.neoharness/mcp.json` config, `ToolAdapter` wrapping MCP specs as internal `%Tool{}`), ACP delegation to external coding agents, and solid observability (telemetry, OTLP export, `llm_usages` token table, ErrorTracker, LiveDashboard).

Trust posture is the **opposite** of samen's: single-tenant, shell/browser access, direct AI writes to memory tables, no policy layer, no masking, vendor deps (OpenAI, Whisper) in the app itself.

## What samen could adopt (patterns, clean-room only)

1. **Duplicate tool-call guard in the agent loop.** Track consecutive identical `{name, arguments}` pairs: 2nd repeat forces extended thinking; 3rd+ blocks with a synthetic tool result; tools flagged `allow_repeat: true` (legit polling tools) bypass. *Why it fits*: ADR-047's durable loop has budgets/caps but this is a cheaper, earlier tripwire against degenerate model loops that burn budget before the cap fires; synthetic results keep the transcript honest (fail-honest-compatible). *Effort*: **S** — a tracker in the loop state + one verifier probe + a sabotage patch.

2. **Three-level context-overflow recovery.** (a) Pre-turn trim against a `context_cutoff_tokens` budget; (b) mid-turn: on a provider "prompt too long" 400, fold history inline via a summarizer and retry exactly once; (c) post-turn: extract durable facts, then compact/delete folded messages. *Why it fits*: samen's loop defers to budget caps today; graceful degradation instead of hard failure improves long agent runs. Caveat: any summarizer output is EG2 governed egress — the fold must run through the masking chokepoint and per-turn grant re-scrub, and compaction must respect the ADR-046 erasure envelope (folded summaries must stay crypto-shreddable, i.e. carry tokens not plaintext). *Effort*: **M**.

3. **Cancellation registry checked between loop iterations.** ETS-backed cancel flags keyed by agent-run id with TTL; the loop checks between iterations and before each tool call, short-circuiting remaining calls with synthetic results. *Why it fits*: gives the operator plane a real "stop this agent run" button with an auditable, non-lossy transcript tail — a natural operator-cockpit affordance samen doesn't list. *Effort*: **S**.

4. **Circuit breaker on AI provider egress.** Req `retry: :transient` + hard deadline, plus a `:fuse`-style breaker: N melts in a window blows the fuse and backs off the whole fleet for a cooldown. *Why it fits*: samen's ADR-039 automation engine already has Health/Breaker — extend the same idea to `samen_anthropic`/AI provider adapters (breaker state in the adapter package, never core, per INV-4; a blown fuse returns an honest `{:error, :provider_unavailable}`). *Effort*: **S**.

5. **Isolated conversation ids + trace retention for scheduled agent runs.** Heartbeat/cron runs use separate conversation ids (`<agent>:cron:<name>`) so scheduled reasoning never pollutes the user-facing context budget; retention keeps the newest 3 traces and collapses older ones to summaries. *Why it fits*: when samen wires scheduled AI automations (ADR-039 automation × ADR-047 loop), this prevents context-budget crosstalk and bounds transcript storage in a retention-policy-friendly way. *Effort*: **S/M**.

6. **Streaming handoff pattern (for when ADR-047 un-defers streaming).** Loop emits per-iteration `:messages_ready` persist+broadcast (not one end-of-run batch); LiveView buffers deltas in a `pending` assign and swaps to the persisted record on `:new_message` via `stream_insert`; connectors implement an optional `stream_delta/5` and degrade to whole-message delivery. *Why it fits*: a proven LiveView-native streaming shape with durable tool-call trails — a good reference design when streaming is re-scoped. *Effort*: **M** (and gated on streaming actually being scheduled).

7. **Structured-output extraction with schema validation + retry-with-errors.** Structured LLM calls validated against Ecto schemas; a malformed response retries once with the validation errors appended. *Why it fits*: samen's hand-built AI kernel does structured verbs; the validate-then-retry-once-with-errors shape is cheap robustness. Adopt the pattern, not InstructorLite (vendor-free core). *Effort*: **S**.

## What to ignore and why

- **Any literal code**: no LICENSE file — everything must be re-derived clean-room.
- **MCP client pool / Hermes**: samen ships an MCP *server*; consuming third-party MCP tools would make external tool defs/args/results governed egress with an untrusted far end — big EG2/approvals surface plus a new dependency, for a capability no samen roadmap item asks for. Revisit only if G22 (agent-grounding packaging) grows a client story.
- **Personas/SOUL files, hot-reloaded SKILL.md, SkillCrystallizer**: personal-assistant ergonomics; samen agents are product-scoped and generator-emitted (`mix samen.gen.agent`), and hot-reloading behavior files from disk is the opposite of samen's verified, sabotage-gated posture.
- **Shell/browser/image tools and direct AI memory writes**: violate samen's "AI writes do not exist" rule (everything mutating goes through E3 approvals) and its no-PII-egress construction.
- **Telegram/Discord connectors, Whisper ingest, OpenAI embeddings, MapTiler atlas**: vendor-coupled personal-agent features outside samen's product planes; samen's chat is in-product and its embeddings are provider-behaviour-based already.
- **Overall architecture as a base**: single-user, single-node, no tenancy, no policy layer, no masking — nothing to build on; samen is strictly ahead everywhere except the loop-hardening niceties above.
