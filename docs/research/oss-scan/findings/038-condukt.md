---
project: Condukt
url: https://github.com/tuist/condukt
category: Agent Frameworks and Development Tools
relevance: medium
verdict: "Do not adopt as a dependency (conflicts with ADR-047 zero-new-deps and the Jido/ash_ai rejection precedent), but mine it as a design reference for sandboxed tool execution, per-session network egress policy, secrets redaction, and surface-scoped tool authority."
---

# 038 — Condukt (tuist/condukt)

Note on method: the Agent subagent tool was unavailable in this session; the evaluation was run directly via sequential WebFetch passes over the GitHub repo, condukt.dev, and the framework docs (overview, architecture, Elixir library pages).

## What the project is

Condukt, by Tuist GmbH, is an **Elixir framework for building AI agent runtimes**, plus a portable coding agent that ships as a Rust terminal binary, an Elixir library, and a WebAssembly browser package. MIT for the library and Rust components; MPL-2.0 for the Phoenix web server. Young but active: ~37 stars, ~177 commits, published on Hex with HexDocs, docs at condukt.dev.

Core ideas:

- **OTP-native agents**: agents are supervised processes integrating with host supervision trees; OTP handles backpressure, cancellation, and real-time event streaming.
- **Agent definition via `use Condukt` macro**: model, system prompt, tools, and named operations with **compile-time typed inputs/outputs validated by JSON Schema**.
- **Sandboxed tool execution**: tools run "somewhere other than your filesystem" — in memory, in a microVM, or in a dedicated Kubernetes pod per session. Performance-critical parts (bashkit, microsandbox, egress) are **Rust NIFs**.
- **Network policy enforcement**: allow/deny egress rules per session.
- **Secrets discipline**: secrets are resolved outside the conversation and automatically redacted from transcripts.
- **Surface-scoped authority**: the portable session owns message history and turn sequencing; it "does not own provider credentials, network policy, filesystem access, or shell access" — a browser surface cannot inherit terminal authority just because both share the loop.
- **Provider abstraction** via ReqLLM (multi-provider), plus sub-agents (delegated child sessions), MCP server support, session compaction, pluggable persistence/telemetry, and project-instruction discovery from AGENTS.md/CLAUDE.md.
- Composes with a declarative workflow engine rather than replacing one ("the loop is Condukt's, the reach is the host's").

## What samen could adopt (patterns, not the dependency)

Samen already has a BUILT first-party agent loop (ADR-047) with governed EG2 egress, per-turn history grant re-scrub, approvals-gated side effects, budgets, and transcript retention. Condukt is a strong independent confirmation of that architecture (host-owned tools, loop-owned history, credentials outside the session) and offers a few concrete deltas:

1. **Surface-scoped tool registries ("surface authority" model)**
   - What: make each agent surface (MCP server, operator plane, tenant plane, CI eval lane) an explicit first-class scope that owns its own tool registry, so a tool registered for one surface structurally cannot be invoked from another. Condukt frames this as "the host executes only tools registered for that surface".
   - Why it fits: samen already separates planes and actors; naming the *surface* in the agent-loop contract closes the "operator tool leaked into tenant MCP" class by construction, matching the chokepoint philosophy, and gives `mix samen.verify.agent_coverage` a parity axis to check.
   - Effort: S (contract + verifier extension over existing ADR-047 machinery).

2. **Secrets-redaction lane distinct from PII masking**
   - What: automatic redaction of *operator/app secrets* (API keys, tokens, connection strings) from agent transcripts and tool results, resolved outside the conversation — Condukt treats this as a separate concern from data privacy.
   - Why it fits: samen's masking is PII-classed (`pii_*`, `%MaskedPayload{}`); secrets are a different taxonomy that could ride the same chokepoint. A `samen.verify.no_secret_egress`-style tier (pattern + entropy scan over tool defs/args/results and retained transcripts) would extend the EG2 story cheaply.
   - Effort: S–M.

3. **Per-session network egress allow/deny policy for agent tool execution**
   - What: declarative allowlist of hosts a given agent session's tools may reach, enforced at the runtime boundary.
   - Why it fits: samen's fail-honest adapters constrain *which* vendors exist, but nothing constrains what a future code-executing or HTTP-fetching tool could reach. Since INV-4 keeps HTTP in adapter packages, an egress policy checked at the adapter/chokepoint layer (not a NIF) is the samen-native translation. Defense-in-depth for the AI plane.
   - Effort: M.

4. **Sandbox-per-session for code-executing tools (design reference only)**
   - What: Condukt's ladder of in-memory → microVM (microsandbox) → dedicated K8s pod per session.
   - Why it fits: today samen's agents produce drafts/proposals and mutate only via the E3 approvals engine, so there is no arbitrary-execution surface. If G22 (agent-grounding packaging for builders) ever grows a "run generated code" tool, this ladder is the reference architecture; the samen version would be a fail-honest `Sandbox` behaviour with a local sim, mirroring the KMS pattern.
   - Effort: L (and only when a code-execution tool is actually on the roadmap).

5. **Compile-time JSON-Schema-typed tool operations**
   - What: tool inputs/outputs declared with schemas validated at compile time.
   - Why it fits: samen's catalog is already the machine-readable dictionary grounding LLMs; deriving each agent tool's input/output schema *from the catalog* and asserting parity in CI (a `catalog_parity` sibling for tool defs) would tighten the EG2 contract and improve model tool-call reliability.
   - Effort: M.

6. **Session compaction under budget caps**
   - What: pluggable transcript compaction so long-running sessions stay within context/cost budgets.
   - Why it fits: ADR-047 already has budgets/cost caps and retention with erasure envelopes; a compaction step that re-runs the masking chokepoint over the summary (so compaction cannot resurrect scrubbed grants) is a natural S follow-on.
   - Effort: S–M.

## What to ignore and why

- **Condukt as a dependency**: directly conflicts with samen's posture — ADR-047 shipped the agent loop with *zero new dependencies*, ash_ai and Jido were both evaluated and rejected for pulling vendor deps/foreign loop ownership into core, and Condukt's ReqLLM multi-provider layer would bypass the `%MaskedPayload{}`-only provider contract (providers must refuse raw strings by FunctionClauseError). Also violates INV-4 (vendor/HTTP-free core).
- **Rust NIFs (bashkit, microsandbox, egress)**: samen deliberately avoids NIFs (simple_sat was chosen specifically for being pure-Elixir, no NIF); a NIF crashing the BEAM is the wrong trade for a trust kernel.
- **ReqLLM provider abstraction**: samen's `Samen.AI.Provider` behaviour exists precisely to keep egress token-blind; a generic provider layer is the thing the chokepoint design forbids.
- **CLI / WASM / terminal-coding-agent surfaces**: unrelated to a SaaS foundry's product/operator planes.
- **AGENTS.md/CLAUDE.md instruction discovery**: samen grounds agents in the catalog, not repo prose; adopting file-based instruction discovery would weaken the "grounding is data" stance.
- **Maturity risk**: ~37 stars, single-vendor (Tuist) project pivoting from build tooling into agents; API stability is unproven — another reason to copy ideas, not code.

Sources: github.com/tuist/condukt, condukt.dev, condukt.dev/docs/framework/architecture, condukt.dev/docs/framework/elixir.
