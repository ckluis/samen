---
project: ElGraph
url: https://github.com/showjihyun/ElGraph
category: Agent Frameworks and Development Tools
relevance: medium
verdict: Do not adopt as a dependency (v0.3, 2 stars, single author, no PII-governance concept), but mine its checkpoint-per-step/resume, interrupt-as-checkpoint HITL, time-travel forking, and ElTrace timeline patterns for samen's ADR-047 agent loop and operator plane.
---

# 039 — ElGraph

## What the project is

ElGraph is a **BEAM-native, graph-first agent framework** (Elixir/OTP, MIT) explicitly positioned as a Python-free LangGraph alternative: "LangGraph-style durable execution, human-in-the-loop, and checkpointing with zero Python dependency." Agents are declared as state channels + nodes + edges; a node takes `(state, ctx)` and returns a partial state-update map; graphs compile with an entry point and support conditional edges, parallel fan-out, subgraphs, and per-node retry (`retry: [max: 3, backoff: :exponential]`).

Umbrella layout keeps the core dependency-light (`:telemetry`, `:req`, `:jason`, `:nimble_options`, `:opentelemetry_api` only): `el_graph` (runtime), `el_trace` (Phoenix LiveView observability UI), `el_graph_web` (A2A JSON-RPC + AG-UI SSE), `el_graph_ecto` (Postgres checkpointer), `el_graph_redis`, `el_graph_req_llm` (~21 providers via ReqLLM), `el_graph_otel` (OTel bridge → Langfuse etc.).

Headline mechanics:
- **Checkpoint after every step**, swappable backends (ETS / DETS-Mnesia / Postgres / Valkey), `keep: {:last, n}` retention; resume never re-runs completed nodes; a half-failed parallel step preserves succeeded work.
- **Task memoization** (`Ctx.memo/3`) skips re-running LLM/tool calls on resume or retry.
- **HITL interrupt**: `Ctx.interrupt(ctx, payload)` inside a node checkpoints durably; `ElGraph.invoke` returns `{:interrupted, %{payload: ...}}`; `ElGraph.resume(graph, thread_id: id, resume: "approved")` injects the human answer without re-execution. The OS process may crash during the wait without losing state.
- **Time-travel forking**: `ElTrace.fork("t1", step, as: "t1-rejected")` branches a new thread from any past checkpoint, preserving the original — safe "what-if" exploration.
- **ElTrace**: LiveView dashboard rendering agent threads as timelines with inline approve/reject and "branch here" controls.
- **MCP both directions**: server (HTTP `/mcp` + stdio; tools/resources/prompts) and client (streamable HTTP, bidirectional sampling/elicitation/roots). Also A2A JSON-RPC and AG-UI SSE.
- **Distribution**: `:pg` signal bus with at-least-once idempotent delivery (signal id + dedup, absorbs netsplit redelivery), multi-node `:peer` verification, per-agent fault-isolated processes.
- **Testing**: `ElGraph.Test.ScriptedLLM` canned-response provider, zero credentials, all tests `async: true`.
- Memory system (episodic/semantic/procedural, `fact_at` point-in-time queries) with native/Mem0/Zep backends; cost guard `budget: [tokens: ...]` on the ReAct preset.

Maturity: ~157 commits, 2 stars/0 forks, ~v0.3 on Hex, M1–M5 milestones done, actively maintained but effectively a single-author young project.

## What samen could adopt

Samen already BUILT its first-party agent loop (ADR-047, zero new deps, EG2 governed egress, E3 approvals for side effects) and deliberately rejected Jido and ash_ai. So the value here is **pattern-mining, not adoption**. Concretely:

1. **Checkpoint-per-step durable resume with task memoization.** *What:* persist a snapshot + pending writes after each agent step; on resume/retry, memoized LLM/tool calls (`Ctx.memo/3`-style keyed cache) are skipped, and succeeded branches of a partially-failed parallel step are preserved. *Why it fits:* ADR-047's durable multi-step loop already retains transcripts; step-granular checkpoints turn crash/deploy interruptions and Oban retries into free resumes instead of re-billed LLM calls — directly serves the budgets/cost-caps goal. Postgres-backed, so no new infra; retention (`keep: {:last, n}`) composes with the ADR-046 erasure envelope (checkpoints must carry tokens only, like the audit chain). *Effort:* M.

2. **Interrupt-as-checkpoint HITL primitive wired to the E3 approvals engine.** *What:* a `interrupt/2`-style verb inside an agent step that durably checkpoints, surfaces an approval Gate, and on approval injects the decision and resumes without re-running prior steps. *Why it fits:* samen's rule is "AI writes do not exist — side effects go through E3 approvals"; today that means the proposal/draft pattern. ElGraph's mechanic makes the *pause itself* crash-safe and resumable from any process, which is exactly the missing plumbing between a mid-run agent step and a Gate that may take days to approve. Requester≠approver invariants stay in E3; this is only the suspend/resume transport. *Effort:* S–M (approvals engine and Oban already exist).

3. **ElTrace-style agent-run timeline in the operator plane.** *What:* a LiveView surface rendering each agent thread as a step timeline (state deltas, tool calls, interrupts) with inline approve/reject and "branch here." *Why it fits:* samen has the operator plane, wide events, and transcript retention but no dedicated agent-run debugging surface; this is also G22 (agent-grounding packaging) adjacent and a strong demo surface. Must render masked-by-default (`%Masked{}` composes naturally). *Effort:* M.

4. **Time-travel forking of agent threads.** *What:* branch a new thread from any past checkpoint, original preserved. *Why it fits:* operator red-teaming and prompt/eval iteration ("what would the run have done if the approval was rejected?") without mutating history — complements the permanent red-team eval tier and the AC-mapped gate culture. Cheap once item 1 exists (a fork is a new thread_id pointed at an old checkpoint). *Effort:* S (after item 1).

5. **MCP *client* with sampling/elicitation (study only).** *What:* samen has an MCP server (HTTP+SSE, per-operator tokens) but no client; ElGraph's bidirectional client is a reference for letting samen agents consume external MCP tools. *Why it fits:* extends ADR-047 tool use to third-party tools — but every tool result is EG2 governed egress, so results must pass the masking chokepoint like any provider payload. *Effort:* L (trust-boundary design dominates).

6. **Signal dedup for at-least-once delivery.** *What:* signal-id + dedup table absorbing redelivery/netsplits. *Why it fits:* samen's multi-node Oban proof is local-only (L4); an idempotency-key pattern on automation EventCapture/agent signals hardens the same-transaction enqueue story for real multi-node. *Effort:* S.

## What to ignore and why

- **ElGraph as a dependency.** v0.3, 2 stars, single author — supply-chain and abandonment risk far below samen's bar, and it fails the exact test that sank ash_ai/Jido (ADR-037, `_orch/jido-eval-report.md`): no chokepoint concept, no PII governance, LLM adapters accept raw strings. Samen's providers refuse anything but chokepoint-minted `%MaskedPayload{}` by construction; retrofitting that onto ElGraph would gut it.
- **ReqLLM 21-provider adapter layer.** Samen is deliberately narrow (samen_anthropic behind `Samen.AI.Provider`); breadth of providers multiplies the masked-egress audit surface for no current need.
- **Redis/Valkey/Mnesia/DETS checkpoint backends.** Samen is Postgres-only purity; the Postgres checkpointer pattern is the only one relevant.
- **Memory system with Mem0/Zep backends.** Vendor deps into the agent core violate INV-4; samen's pgvector + catalog grounding already covers semantic recall, and "temporal truth" facts would be a PII-classification minefield.
- **A2A JSON-RPC / AG-UI SSE protocols.** Niche, unstable ecosystems; samen deferred even first-party streaming (ADR-047) — no reason to adopt second-party agent-to-agent protocols now.
- **ScriptedLLM.** Samen already has the deterministic fake provider + fixture-transport cassettes; nothing new here.
