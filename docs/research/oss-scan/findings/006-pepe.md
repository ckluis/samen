---
project: Pepe
url: https://github.com/pepe-agent/pepe
category: AI and Agents
relevance: medium
verdict: Tiny single-maintainer Elixir/OTP agent runtime — never a dependency, but a dense catalog of agent-runtime product patterns (model triage/failover, context compaction, tool-approval TTLs, directed agent ACLs, channel connectors) worth mining for samen's AI plane.
---

# 006 — Pepe (pepe-agent/pepe)

## What the project is

Pepe is a self-hosted AI agent runtime written in Elixir/OTP with a Phoenix LiveView dashboard. It is deliberately **database-free**: all agent definitions live as JSON in `~/.pepe/config.json`, and state is held in OTP processes (one lightweight process per conversation, supervision isolating crashes). It speaks the OpenAI Chat Completions protocol to any compatible provider (OpenAI, OpenRouter, Groq, DeepSeek, Ollama, vLLM, etc.), and exposes multiple surfaces over the same agents: web dashboard, OpenAI-compatible `POST /v1/chat/completions` HTTP API, WebSocket token streaming, CLI/TUI, an embeddable widget, and chat-channel connectors (Telegram, WhatsApp, Slack, Discord, Teams, Google Chat).

Feature highlights: declarative agent config (name, system_prompt, model, tools, `can_message`, `can_manage`, `auto_approve`, `max_iterations`); goal-directed execution with an independent reviewer model validating success criteria and retrying with feedback up to an attempt cap; agent-to-agent directed messaging and management; complexity-based model triage and failover chains; automatic context compaction; durable memory facts; scheduled tasks and "watch" notifications; a tool/skill marketplace (PepeHub); opt-in OS-level tool sandboxing (firejail / sandbox-exec / Docker); reversible PII redaction hooks (regex, LLM pseudonyms, or self-hosted Microsoft Presidio); per-project token scoping with SHA-256-hashed API tokens; per-tenant USD budget + message caps with a read-only usage/billing API.

Maturity: MIT, ~253 commits, 6 GitHub stars, 1 primary maintainer (emerged from internal proprietary tooling), docs in en/es/pt at pepe-agent.com. Active but tiny community; real bus-factor risk as a dependency.

## What samen could adopt

Samen already has a first-party governed agent loop (ADR-047: EG2 masked egress, E3 approvals for anything with side effects, budgets, transcript retention) and rejected external agent frameworks (Jido, ash_ai). So nothing here is a library to import — these are *product patterns* to re-implement inside samen's kernel discipline:

1. **Complexity-based model triage (`triage_model` → `simple_model`).** A fast classifier runs once at session start; "SIMPLE" verdicts downgrade the whole session to a cheaper model; triage failure silently falls back to the primary model (non-blocking, fail-open). *Why it fits:* directly serves ADR-047's budget/cost-cap goals — cost control by construction rather than only by caps — and the fail-open posture matches fail-honest (a broken triage never degrades correctness, only cost). Route the triage call through the existing masked-payload chokepoint. **Effort: S–M.**

2. **Model failover chains with honest events.** Transient errors (429/5xx/timeouts) retry on the next model in a configured chain and emit an explicit `failover` event; hard errors (bad key, malformed request) fail immediately. *Why it fits:* samen's `Samen.AI.Provider` behaviour has exactly one adapter today (`samen_anthropic`); a chain abstraction at the chokepoint (never in adapters) gives resilience while the emitted event preserves fail-honest observability — no silent substitution. **Effort: M.**

3. **Context-window compaction strategies.** At ~60% of context, replace the middle of history with a model-generated summary, preserving system prompt + recent turns; documented tradeoff between standard compaction and per-turn "micro-compaction" (steady cost but breaks provider prompt-cache reuse). *Why it fits:* ADR-047's durable multi-step loops will hit context limits; samen needs a compaction policy that composes with the per-turn history grant re-scrub (summarize only already-masked history). The cache-reuse tradeoff analysis is worth stealing verbatim. **Effort: M.**

4. **Tool-approval TTL vocabulary + surface-aware refusal.** Pepe grades approvals as once / this-turn / this-session / permanent (`auto_approve`), and on non-interactive surfaces (HTTP API, webhooks, cron) gated tools are *refused outright* — only pre-approved tools run. *Why it fits:* maps cleanly onto samen's existing grant vocabulary (time-boxed, no in-place renewal) and extends the E3 approvals engine with an explicit interactive-vs-headless distinction; "headless surface ⇒ deny-by-default for gated tools" is a crisp invariant samen could add to `verify.agent_coverage`. **Effort: S.**

5. **Directed agent-to-agent ACLs as data.** `can_message` is a one-way allowlist (A→B does not imply B→A), routes are project-scoped and never cross tenants; `can_manage` has a precise semantics (`null` = self only, `[]` = nobody, list = exactly those, `["*"]` = super-admin), and agents carry rename-stable internal IDs so bindings survive renames. *Why it fits:* when samen's agent loop grows delegation, this is the right shape — declarative directed routes stored as resources, enforced by OrgScope-composed policy, with a verifier tier proving no route crosses a tenant boundary. **Effort: S–M** (schema + policy + verifier).

6. **Chat-channel adapter packages (Telegram/Slack/WhatsApp/Teams) + embeddable widget.** Pepe proves one agent definition can serve dashboard, API, and external chat channels simultaneously. *Why it fits:* samen has cross-plane in-app chat but zero external channel reach — a real gap for the support-desk depth theme (G21). Fits samen's existing vendor-adapter pattern exactly: `samen_telegram`/`samen_slack` path-dep packages, fail-honest `{:error, :not_configured}`, all egress chokepoint-minted. **Effort: L.**

7. **Tenant-facing spend metering surface.** Per-company monthly USD budget + message limit, "metered live," exposed via a read-only usage API token for billing systems. *Why it fits:* samen has internal budgets (ADR-047) and a billing scope; the *productized* read-only metering API + per-tenant cap editor is a concrete G13 billing-depth feature that requires no live Stripe keys. **Effort: M.**

## What to ignore and why

- **Pepe as a dependency or embedded runtime.** 6 stars, one maintainer, JSON-file persistence, no Ash/Ecto — architecturally antithetical to samen (Postgres-backed resources, catalog parity, verifier tiers) and precisely the class of framework samen already rejected twice (Jido, ash_ai). Re-implement patterns, import nothing.
- **Reversible PII redaction (`token -> real` restore on the way out).** The exact opposite of samen's design: samen's AI plane is token-blind *by construction* and never restores plaintext into an AI-adjacent pipeline. Pepe's regex/LLM-pseudonym redaction is heuristic name/shape matching — the approach samen's ADR-015 default-deny classifier explicitly rejected. Samen's chokepoint + `verify.ai_prompt_masking` is strictly stronger. (One sub-idea *is* worth noting under item 4's spirit: Pepe scrubs **tool outputs** before they join the conversation — samen's EG2 already governs tool results, so no action needed.)
- **Database-free / config-file state model.** Fine for a single-binary personal runtime; incompatible with samen's audit chain, catalog, and multi-tenant guarantees.
- **OS-level tool sandboxing (firejail/Docker wrappers).** Only relevant if samen ever executes arbitrary user-supplied CLIs as tools; samen's tools are first-party Ash actions behind E3 approvals, so this whole surface (and PepeHub marketplace) is out of scope today.
- **Goal-directed reviewer loop as-is.** The retry-until-reviewer-passes pattern is interesting but samen's equivalent leverage point is its eval harness + approvals (AI outputs are drafts; humans/E3 gate effects). Adopting an LLM reviewer as an *authorizer* would weaken samen's "AI writes do not exist" invariant — at most use reviewers as a draft-quality signal.
- **Scheduled tasks / watches.** Samen's automation engine (ADR-039, Reactor + state machines + breakers) already exceeds this.
