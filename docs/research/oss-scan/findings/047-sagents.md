---
project: Sagents
url: https://github.com/sagents-ai/sagents
category: Agent Frameworks and Development Tools
relevance: high
verdict: Do not adopt the library (LangChain dep + no masking chokepoint = same structural rejection as ash_ai/Jido), but mine it hard — its LiveView streaming event taxonomy, dual-view transcript model, edit-capable HITL decisions, and until_tool pattern are directly applicable to samen's ADR-047 agent loop.
---

# 047 — Sagents

## What the project is

Sagents (Apache-2.0, Hex `~> 0.13.0`, ~266 stars, active) is an Elixir framework for **interactive AI agents** built on top of Elixir LangChain, targeting Phoenix LiveView apps. It is the closest open-source analogue to samen's ADR-047 agent loop that exists in the Elixir ecosystem.

Architecture:
- **OTP supervision**: `Sagents.Supervisor` → ProcessRegistry (Registry or Horde.Registry) → DynamicSupervisor → per-agent `AgentSupervisor` (`:rest_for_one`) holding an `AgentServer` GenServer + a `SubAgentsDynamicSupervisor`. Discovery via registry keys (`{:agent_server, agent_id}`), not tree traversal.
- **Explicit pipeline run loop**: composable steps (`call_llm`, `execute_tools`, `check_pre_tool_hitl`, `propagate_state`); each step returns `{:continue, chain}` or a terminal `:ok | :error | :interrupt | :pause`. Custom modes via `LangChain.Chains.LLMChain.Mode` behaviour.
- **Middleware behaviour** (`init/1`, `system_prompt/1`, `tools/1`, `before_model/2`, `after_model/2`, `handle_message/3`, `on_server_start/2`): TodoList, virtual FileSystem, HumanInTheLoop, SubAgent delegation, Summarization (auto-compact near token limits), ConversationTitle, DebugLog, ProcessContext (OTel/Sentry context across task boundaries).
- **HITL approvals**: per-tool `interrupt_on` map; agent pauses and broadcasts `{:status_changed, :interrupted, interrupt_data}`; resume with a decisions list — `:approve`, `:edit` (modify tool arguments before execution), `:reject` — with **per-tool-call granularity on parallel calls**. SubAgent interrupts escalate to the parent for consolidated approval.
- **`until_tool` structured completion**: loop until the agent calls a named tool, returning `{:ok, state, %ToolResult{}}`.
- **Dual-view persistence**: full LLM history + middleware state as a serialized **AgentState blob**, separate from UI-oriented **DisplayMessage** records — so history can be summarized/compacted without changing what users see. Optional `AgentPersistence` / `DisplayMessagePersistence` behaviours; `mix sagents.setup` generates schemas/migrations/context/coordinator; `mix sagents.gen.live_helpers` generates LiveView handlers.
- **LiveView streaming**: PubSub topic `"agent_server:#{agent_id}"` with a rich event taxonomy — status (`:idle/:running/:interrupted/:paused/:cancelled/:error`), `{:llm_deltas, ...}`, `{:llm_message, ...}`, `{:llm_token_usage, ...}`, `:tool_call_identified/:tool_execution_started/completed/failed`, `:todos_updated`, `:state_restored`.
- **Lifecycle/ops**: inactivity timeout (default 5 min), optional Phoenix.Presence viewer-tracking shutdown, optional Horde clustering with membership modes (`:auto`/`:participation`/`:partition`) and node-transfer events; crashed agents re-create from persisted state via `Session.ensure_running/3`.
- Ecosystem: `agents_demo` (runnable Phoenix example) and `sagents_live_debugger` (LiveView dashboard for agent inspection).

Security posture: HITL gates exist but masking/sandboxing/input validation are explicitly the integrator's problem. No erasure mechanism; state blobs persist raw conversation history.

## What samen could adopt

Samen already **built** its own agent loop (ADR-047, zero new deps, EG2 governed egress, AI-writes-don't-exist, E3 approvals) and rejected ash_ai and Jido for vendor-dep and no-chokepoint reasons that apply equally here. The value is in Sagents' *design patterns*, which are proven in production LiveView apps:

1. **LiveView streaming event taxonomy + generated handlers** — *what*: the `agent_server:#{id}` PubSub vocabulary (status lifecycle, `llm_deltas`, token-usage, per-tool execution events) and the `gen.live_helpers`-style generator. *Why it fits*: ADR-047 deliberately deferred streaming; when samen un-defers it, this is a field-tested event contract to emit from the EG2 chokepoint (deltas would be post-scrub masked payload deltas), and samen already ships generators (`mix samen.gen.agent`) that could emit the LiveView handler side. *Effort*: **M**.

2. **Dual-view transcript model (AgentState blob vs DisplayMessages)** — *what*: separate the LLM-facing history (compactable, summarizable) from the user-facing rendered messages. *Why it fits*: samen's transcript retention rides the ADR-046 erasure envelope; splitting the views lets the agent-history blob be per-subject crypto-shreddable while display records carry only masked tokens, and enables context compaction without rewriting what tenants saw. *Effort*: **M**.

3. **`:edit` decision type + per-call granularity in approvals** — *what*: HITL resume decisions of `:approve` / `:edit` (operator amends tool arguments before execution) / `:reject`, individually per tool call within one parallel batch. *Why it fits*: samen's E3 approvals engine (Gate face, requester ≠ approver at policy + DB CHECK) covers approve/reject; "approve-with-amendment" is a natural Gate enrichment for AI/automation proposals and keeps the operator from rejecting an otherwise-good draft over one bad argument. Edited arguments must re-enter through the same validation/chokepoint path. *Effort*: **S–M**.

4. **`until_tool` structured completion** — *what*: run the loop until a designated "deliver" tool fires and return its `ToolResult` as the typed outcome. *Why it fits*: samen's agent outputs are drafts/proposals by construction; a declared terminal-tool contract gives `mix samen.gen.agent` scaffolds a crisp, pattern-matchable "the draft is ready" shape and gives `samen.verify.agent_coverage` something structural to assert. *Effort*: **S**.

5. **Summarization/compaction step with budget awareness** — *what*: middleware that auto-compresses history near token limits (and can be blocked from recursing into subagents). *Why it fits*: ADR-047 has budgets/cost caps but the digest shows no context-compaction mechanism; a compaction step inside the loop (operating on already-masked history, re-scrubbed per the per-turn history grant) directly extends budget runway on long multi-step runs. *Effort*: **M**.

6. **Agent live-debugger surface for the operator plane** — *what*: the `sagents_live_debugger` idea — a LiveView dashboard showing live agent runs, message flow, step/middleware state. *Why it fits*: samen's operator control plane already exists and is first-party (ash_admin rejected); an agent-run inspector (masked by default, reveal-gated like everything else) is a cheap ops win for debugging ADR-047 runs and a fleet-cockpit candidate. *Effort*: **M**.

7. *(Future, if subagents land)* **Interrupt escalation from child to parent** — subagent-protected operations bubble to the parent's approval queue for consolidated review. Samen's loop is single-agent today; record this as the reference pattern for a future subagent ADR rather than build now. *Effort*: **L** (gated on a subagent concept existing).

## What to ignore and why

- **The library itself / LangChain dependency**: pulling Sagents in means LangChain and its provider HTTP clients inside the app — an INV-4 violation (vendor-free core) and the exact reason ash_ai was rejected. Prompt assembly happens inside LangChain with raw strings, structurally incompatible with samen's `%MaskedPayload{}`-only chokepoint where providers refuse raw strings by FunctionClauseError.
- **Tool execution on approval**: in Sagents an approved tool executes directly. In samen, AI writes do not exist — side effects only via the E3 approvals engine with requester≠approver DB CHECK. Adopting Sagents' execution model would regress the governance invariant; only its *decision UX* (item 3) transfers.
- **Horde clustering + registry-based long-lived agent processes**: samen's loop is durable via its own kernel (multi-node Oban proven locally); Horde adds a CRDT-registry dependency and a process-affinity model samen doesn't need. Contradicts ADR-047's zero-new-deps posture.
- **Virtual FileSystem middleware**: samen already has a files chokepoint with quarantine-by-default; an in-memory agent filesystem would create a second, ungoverned file path.
- **Provider multiplexing via LangChain model classes**: samen has `Samen.AI.Provider` + fail-honest adapters (`samen_anthropic`, keyless CI fake); nothing to gain.
- **Persistence generators as-is**: they persist raw conversation history with no masking/erasure concept — incompatible with ADR-046; only the dual-view *shape* (item 2) transfers.
