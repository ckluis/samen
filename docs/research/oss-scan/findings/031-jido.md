---
project: Jido
url: https://github.com/agentjido/jido
category: Agent Frameworks and Development Tools
relevance: low
verdict: Already deep-evaluated by samen (2026-08-13) and rejected (DON'T ADOPT); the one genuine gap it exposed was since closed first-party by ADR-047 — nothing new to adopt.
---

# 031 — Jido

## What the project is

Jido is a distributed autonomous-agent framework for Elixir (Apache-2.0, `jido` 2.3.3
released 2026-08-10, ~1.8k stars). Core abstractions: **Agents** (immutable state struct +
single `cmd/2`), **Actions**, **Signals** (CloudEvents envelopes over configurable
dispatchers), **Directives** (`Emit`, `Spawn`, `Schedule`, `Stop`, ...), **Plugins**, a
GenServer `AgentServer` with parent/child hierarchies, "Pods" for durable agent groups, and
Direct/FSM execution strategies. AI is a companion package, `jido_ai` (2.3.0): eight
reasoning strategies (ReAct default), tools-as-`Jido.Action`, model routing/retries,
checkpoint/resume streaming — hard-depending on `req_llm`, a multi-provider LLM HTTP client
with 13 deps of its own. The whole stack (`jido`, `jido_action`, `jido_signal`, `req_llm`)
is published by a single maintainer; the current architecture dates from the 2.0.0
restructure (2026-02), so it is young and moving fast.

## Why this evaluation is short

Samen has already run exactly this evaluation, in depth, five days before this scan:
`/Users/clank/Desktop/projects/samen/_orch/jido-eval-report.md` (dated 2026-08-13, verified
against hex.pm/GitHub at that time). Verdict: **DON'T ADOPT**, ratified in ADR-037's
ecosystem posture. A freshness check for this scan (GitHub releases, 2026-08-19) confirms
the latest release is still 2.3.3 (2026-08-10) — nothing has shipped since that eval that
could change its conclusions.

The eval's findings, condensed:

1. **`jido_ai` fails INV-4 by construction.** It hard-depends on `req_llm`, which puts
   vendor API clients into the tree regardless of code paths reached — the identical
   placement failure for which ADR-037 §5.6 rejected `ash_ai`. It also has no chokepoint
   concept, its map/keyword tool args are the wrong shape for samen's allowlist scrub
   (`safe_segment?/1` refuses all maps/tuples/structs by design), its persisted agent state
   cannot carry samen's grant-span re-scrub contract (ADR-043 §3.2a/EG2), and its telemetry
   is a second uncoordinated EG6 emitter.
2. **`jido` core is egress-free (no INV-7 threat) but near-totally duplicative** of samen's
   already-adopted governed stack: Reactor (graph execution + compensation), Oban/AshOban
   (durable scheduling with same-transaction enqueue), AshStateMachine (guarded lifecycles),
   Phoenix.PubSub + EventCapture (signalling), `Automation.Run`/`Health`/`Breaker`
   (org-scoped supervision + kill-switch). Jido brings none of samen's org-scoping, plane
   model, policy actors, or audit resources, plus 7+ new deps and a second scheduler.
3. **The audit-surface argument is decisive for samen specifically.** Samen's AI claims rest
   on a full-tree AST anti-bypass probe and a 285-patch sabotage harness, both of which can
   only certify samen's own `lib/`. Any dependency participating in an egress path is a
   surface those load-bearing gates structurally cannot certify.
4. **The one genuine gap the eval found — durable multi-step LLM tool use (EG2) — has since
   been closed first-party.** ADR-047 (agent loop, BUILT, accepted 2026-08-17) shipped it
   with zero new dependencies: EG2-governed tool defs/args/results, per-turn history grant
   re-scrub, AI-writes-as-drafts through the E3 approvals engine, budgets/cost caps,
   transcript retention under the erasure envelope, `mix samen.gen.agent` +
   `mix samen.verify.agent_coverage` with a raw-spawn AST lock. The strongest hypothetical
   reason to reconsider Jido no longer exists.

## What samen could adopt

Nothing as a dependency. Two idea-level items only:

- **Sensors as a named primitive** (what: Jido's declarative environment-watcher abstraction
  that feeds signals into agents; why: the eval flagged it as the single non-overlapping
  primitive, and if samen's agent loop later needs ambient triggers beyond `resource_event`
  capture + AshOban scans, "sensor" is a clean concept to name that seam; effort: S — a
  naming/API-shape borrow over existing EventCapture/AshOban machinery, no code from Jido).
- **Watch-list monitoring** (what: track Jido's release cadence as a proxy for where the
  Elixir agent-framework ecosystem converges — e.g. if a future major version drops the
  `req_llm` hard-dep from `jido_ai` or splits a dependency-free agent-loop core; why: samen's
  rejection is contingent on Jido's current dependency shape and samen's first-party loop
  staying sufficient; effort: S — a periodic glance, already institutionalized by the
  `_orch` eval habit).

## What to ignore and why

- **`jido_ai` entirely** — INV-4 violation via `req_llm`, no chokepoint concept, tool-arg
  shape incompatible with the allowlist scrub, ungoverned persistence and telemetry. Strictly
  worse than `ash_ai` on the rubric that already rejected `ash_ai`.
- **`jido` core as a runtime** — duplicates Reactor/Oban/AshStateMachine/PubSub with no
  org-scoping or governance, adds 7+ deps from a single-maintainer stack ~6 months into its
  current architecture, and expands the surface samen's AST probe and sabotage harness
  cannot certify. ADR-047 removed the only gap it could have filled.
- **Signals/CloudEvents bus** — an in-memory bus is a weaker guarantee than samen's
  deliberate transactional-then-durable path (in-txn EventCapture → Oban).
- **`Schedule` directive / `crontab` + `time_zone_info`** — a second scheduler with no
  equivalent of the same-transaction Oban enqueue samen's durability idiom depends on.

## Sources

- `/Users/clank/Desktop/projects/samen/_orch/jido-eval-report.md` (samen's full evaluation, 2026-08-13)
- `/Users/clank/Desktop/projects/samen-oss-scan/samen-digest.md` (§5 ADR-037 posture, §6 ADR-047 agent loop)
- github.com/agentjido/jido releases page (fetched 2026-08-19; latest 2.3.3, 2026-08-10)
