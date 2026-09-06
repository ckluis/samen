---
project: Cantrip
url: https://github.com/deepfates/cantrip
category: Agent Frameworks and Development Tools
relevance: medium
verdict: Same-language (Elixir) agent runtime worth pattern-mining — port-isolated code sandbox, forkable loom replay, and eval-harness style — but its LLM plumbing and storage choices conflict with samen's INV-4/Postgres-only invariants; do not adopt wholesale.
---

# 037 — Cantrip

## What the project is

Cantrip (deepfates, MIT, v1.3.3, ~122 stars, ~298 commits, actively developed) is an **Elixir/BEAM multi-agent runtime**. An agent ("cantrip") declaratively binds an LLM (ReqLLM-based provider routing), an identity/system prompt, a "circle" (medium: structured tool-call conversation, sandboxed Elixir code, or bash), and durable "loom" storage. Execution patterns: `cast` (one-shot), `summon` (persistent OTP process), `cast_batch` (concurrent child delegation with result grafting in request order, each child getting its own loom). Vocabulary maps cleanly onto agent-governance concepts:

- **Gates** — allowlisted boundary-crossing tool functions (`read_file`, `list_dir`, `search`, `mix`, `done`, opt-in `compile_and_load`); construction-time dependency closure; failed gate calls return to the agent as data ("errors are observations").
- **Wards** — declarative runtime constraints composed as a list: `[%{max_turns: 8}, %{sandbox: :port}, %{code_eval_timeout_ms: 5_000}]`; also recursion depth. Timeout closes the port and kills the child OS process.
- **Loom** — a durable, **forkable tree of turns** with three backends (memory, JSONL, Mnesia w/ cluster replication); `Loom.fork/4` replays a prefix and branches from a prior turn.
- **Sandbox modes** — `:port` (default for code medium): LLM-written Elixir evaluated by **Dune** inside a child BEAM spawned via `elixir -e ... PortChild.main()`, optionally wrapped in an OS-level container runner; denies `File.*`/`System.*`/`Process.*`/spawn/node; parent↔child speak length-prefixed Erlang external terms (`{:eval, ...}`, `{:gate_call, ...}`); gate closures are rewritten to injected proxies so child code has no host-BEAM authority; non-Cantrip atoms serialize as strings to protect the parent atom table. Also `:dune` (in-process), `:unrestricted`, `:port_unrestricted`.
- **Eval harness** — scenario suites (`evals/familiar/v1.3.3.exs`) covering gate-use, composition, judge-graded synthesis quality, **forbidden-pattern checks**, and cross-summoning memory, across multiple seeds with rubric scoring and transcript diffs.
- Extras: `cast_stream` event-driven streaming; ACP (Agent Client Protocol) editor mounting (Zed/JetBrains); hot-load validation via compile wards (exact module names, source hashes, signer keys — see `docs/signer-key-runbook.md`); docs on architecture, observability, port isolation, deployment.

## What samen could adopt

Samen already has a first-party agent loop (ADR-047: EG2 governed egress, drafts-only AI writes via E3 approvals, budgets, transcript retention, `mix samen.verify.agent_coverage`), so this is pattern-mining, not adoption. Cantrip is essentially a second data point alongside the rejected Jido — but a more interesting one because its governance vocabulary (gates/wards/allowlists/audit loom) rhymes with samen's chokepoint philosophy.

1. **Port-isolated Dune sandbox for LLM-authored code** — child-BEAM evaluation with Dune language restriction, injected proxy gates, length-prefixed term protocol, kill-on-timeout, optional OS-container runner (`docs/port-isolated-runtime.md`).
   - *Why it fits*: if samen's automation engine or agent loop ever gains a "compute/expression" step (e.g., LLM-drafted formulas over catalog data), this is the proven Elixir-native way to run untrusted code without host-BEAM authority — structurally-cannot rather than policy, exactly samen's style. Dune itself is a small, vendor-free hex dep that could live in an adapter package, honoring INV-4.
   - *Effort*: L (new medium, new verifier tier, sabotage patches).
2. **Forkable loom replay for agent regression tests** — record every turn as a forkable tree; branch from a prior turn to replay/regress.
   - *Why it fits*: samen retains agent transcripts (ADR-046) but doesn't use them as replayable fixtures; fork-and-replay would let the red-team eval tier and `verify.agent_coverage` pin down regressions from a real captured turn instead of synthetic cassettes only. Backend would be Postgres rows, not JSONL/Mnesia.
   - *Effort*: M.
3. **Eval-harness structure: forbidden-pattern scenarios + transcript diffs + multi-seed rubric scoring** — Cantrip ships a curated 5-scenario starter suite per release version.
   - *Why it fits*: samen's AI red-team tier has a ≥90% masking bar; adding forbidden-pattern assertions (things the agent must never emit/call) and transcript-diff review artifacts would strengthen gate reports with per-release versioned eval suites — matches the claim-evidence discipline.
   - *Effort*: S–M.
4. **Wards as a declarative composed constraint list** — max_turns / recursion depth / timeout / sandbox policy expressed as data on the agent definition.
   - *Why it fits*: samen's ADR-047 budgets/caps exist; expressing them as catalog-visible declarative data (like `pii_*` classes) would make them verifiable by a parity tier and groundable for the LLM. Small ergonomic win.
   - *Effort*: S.
5. **`cast_stream` as the streaming reference** — event-driven result consumption over the same loop, streamed to a pid.
   - *Why it fits*: samen deferred AI streaming in ADR-047; when that deferral lifts, Cantrip is a working same-stack example of streaming a governed agent loop (events, not raw provider chunks — compatible with per-turn re-scrub since events can be minted post-chokepoint).
   - *Effort*: M.
6. **Signed hot-load wards (source hash + signer key) — read for ideas only** — Cantrip validates hot-loaded modules against exact module names, source hashes, and signer keys.
   - *Why it fits*: samen will never hot-load AI code, but the hash+signer validation pattern is relevant to fleet directives (ADR-044) if directives ever carry executable/config payloads.
   - *Effort*: S (reading), payoff speculative.

## What to ignore and why

- **ReqLLM provider routing** — samen's AI kernel is deliberately hand-built with a `%MaskedPayload{}`-only provider behaviour; a generic router has no chokepoint concept (same reason ash_ai was rejected in ADR-037) and would drag vendor deps toward core (INV-4).
- **Mnesia loom backend / distributed replication** — violates samen's Postgres-only purity; samen's multi-node story is Oban-on-Postgres.
- **`compile_and_load` hot-loading and `:unrestricted` sandbox defaults** — directly contradicts samen's "AI writes do not exist" stance and the raw-spawn AST lock; the Familiar's trusted-local default is the opposite of samen's fail-closed prod posture.
- **ACP editor mounting** — samen's external surface is its MCP server (HTTP+SSE, per-operator tokens); an editor-agent protocol serves a dev-tool product, not a SaaS foundry.
- **Bash medium** — arbitrary shell as an agent medium is out of scope for a governed tenant-facing plane.
- **Wholesale adoption as the agent framework** — ADR-047 is BUILT, gated, and integrated with approvals/erasure/audit; swapping runtimes would forfeit the EG2 egress governance that is samen's actual moat. Cantrip's own docs punt OS-level isolation guarantees to the deployment ("Cantrip does not verify the security properties of an arbitrary runner"), which is weaker than samen's verified-by-CI bar.
