---
project: Shem
url: https://github.com/thephilip/shem
category: AI and Agents
relevance: medium
verdict: Pattern mine, not a dependency — deterministic agent-run replay, install-time tool graduation gates, and offline attestation bundles are ideas worth folding into samen's ADR-047 agent loop; the code itself (0-star, single-author, Mnesia/DETS, container sandboxes) is off-posture to adopt.
---

# 007 — Shem

## What the project is

Shem is a newly public (0 stars, ~847 commits, single author, Apache-2.0) BEAM-native AI agent platform built in Elixir, positioned around debuggability and verifiability. Its pillars:

- **Flight recorder**: every agent run is a hash-chained (SHA-256, tamper-evident) event log that can be rewound, forked, and replayed. Replay is deterministic — it replays recorded events rather than re-executing LLM calls; "fork & continue" re-rolls LLM calls live from a chosen turn and shows original vs fork diverging side by side.
- **Time-travel debugger**: a forensic WebUI (deliberately styled like an oscilloscope/logic analyzer — "precise, forensic, engineered"; WCAG AA, reduced-motion, keyboard-scrubbing) over `/api/sessions/:id/{events,fork,verify}` endpoints, plus a TUI dashboard.
- **Tool packs**: tools shipped as a git repo with per-tool manifests (`pack.json` + `tools/*.json` + source in python/javascript/go/elixir). A mandatory **graduation gate** re-runs every tool's own `test_source` in a throwaway container on the installer's machine at install time — upstream CI is never trusted. Sandbox is deny-all by default (`--network=none`, slim images, read-only mounts); elevation requires explicit per-tool operator grants, and grants do not survive reinstalls/upgrades. Declared actions carry risk tags and are **enforced fail-closed at call time**; undeclared actions are blocked.
- **Attestation**: `shem attest` exports offline-verifiable evidence bundles with stdlib-only verification scripts; `shem replay --check` turns recorded sessions into CI regression tests.
- **Interfaces**: TUI, WebUI, REST API, MCP server at `/mcp/sse`, Python SDK. Runtime: OTP process-per-agent isolation, Plug/Bandit, Mnesia/DETS persistence, local single-user at 127.0.0.1:4000 — explicitly no multi-tenant story.

Maturity caveat: self-described "young and moving fast," dogfooding-driven, no community, docs good (README/DESIGN/PRODUCT/PACKS) but implementation details thin outside the README.

## What samen could adopt

1. **Deterministic replay of agent-loop runs + `replay --check` CI tier**
   - What: record each ADR-047 agent-loop turn (tool defs, args, results, provider responses) as a replayable event stream, then a `mix samen.verify.agent_replay`-style tier that re-runs recorded sessions against the current code and fails on divergence.
   - Why it fits: samen already has the raw material — EG2-governed transcripts (ADR-046 retention), fixture-transport cassettes in `samen_anthropic`, and a culture of "every guarantee ships with a proof." Replay-as-regression is exactly the sabotage-harness mindset applied to agent behavior, and because the AI plane only ever handles `%MaskedPayload{}`, a replay log can stay token-blind and inside the erasure envelope (crypto-shreddable) by construction — something Shem itself doesn't have to solve.
   - Effort: M (event capture piggybacks on existing transcript records; the replay executor and divergence diffing are the new work).

2. **Fail-closed declared-action manifests for agent tools**
   - What: per-tool manifest declaring actions with risk tags (`read`/`write`/`execute`), enforced fail-closed at call time — undeclared action ⇒ refused — plus a parity verifier (`samen.verify.tool_manifest_parity`) checking manifest vs implementation.
   - Why it fits: samen already routes all mutating tool effects through the E3 approvals engine and uses bounded-outcome allowlists (Automation RunRecord); this extends the same "governance by construction" to the read/query tools `mix samen.gen.agent` emits, and gives `samen.verify.agent_coverage` a machine-checkable contract to check against. Philosophically identical to samen's chokepoint-everything posture.
   - Effort: S–M (manifest schema + one call-time guard + one verifier tier).

3. **Offline-verifiable attestation bundles (`shem attest` pattern)**
   - What: a `mix samen.attest` that exports a gate report / audit-chain segment / crypto-shred destruction-oracle result as a self-contained bundle with a stdlib-only (or plain-Elixir-script) verifier an auditor or tenant can run with no samen checkout.
   - Why it fits: samen's differentiator is tenant-readable hash-chained audit + claim-evidence docs (`docs/claim-evidence.md`, gate reports, WORM anchoring). Packaging those proofs so a second party can verify them offline is a cheap, on-brand extension of the compliance story (G19 DSAR export adjacency) and strengthens the "honest claims" positioning.
   - Effort: M.

4. **Fork-at-turn debugging affordance in the operator plane (lower priority)**
   - What: from a stored agent transcript, re-run from turn N with a re-rolled LLM call and diff the two trajectories.
   - Why it fits: useful for the permanent red-team eval tier and for debugging agent regressions; builds directly on item 1's replay substrate.
   - Effort: L — defer until replay exists; also note ADR-047 deliberately deferred streaming, so scope carefully.

5. **Forensic-instrument UI register for the debugger/audit surfaces (idea only)**
   - What: Shem's design doc is a good articulation of "show actual hashes and event rows, monospace numerics, integrity badges as persistent state, zero decorative chrome" for trust-critical screens.
   - Why it fits: samen's audit-chain viewer and future agent-transcript operator screens sell trust; borrowing the register (not the CSS) is free direction for the operator cockpit v2 theme.
   - Effort: S (design guidance, not code).

## What to ignore and why

- **The codebase as a dependency**: 0 stars, single author, pre-1.0, "moving fast." Samen's ADR-033/INV-4 posture (in-monorepo, zero vendor deps in core) rules out depending on it; everything above is pattern adoption.
- **Container sandboxing of tools**: Shem sandboxes polyglot third-party tools in containers; samen's agent tools are first-party Elixir inside the monorepo behind chokepoints and approvals — containers add ops surface without closing a real gap. The ADR-047 raw-spawn AST lock already covers the escape hatch Shem's containers guard.
- **Tool packs as a distribution mechanism**: samen doesn't distribute tools to third parties (ADR-033, no Hex); the install-time re-verification problem Shem solves doesn't exist for samen today. Revisit only if G22 (agent-grounding packaging for external builders) turns into shipping tools outward — then the "installer re-runs the gate locally, grants don't survive upgrades" rules are the right ones.
- **Hash-chained event log, MCP server, process-per-agent isolation**: samen already has each (ADR-002 audit chain with DB-trigger immutability + WORM anchoring; HTTP+SSE MCP server with per-operator tokens; OTP/Oban execution) — and samen's versions are multi-tenant and erasure-aware where Shem's are single-user.
- **Mnesia/DETS persistence and single-user localhost model**: directly contrary to samen's Postgres-only, two-plane, multi-tenant architecture.
