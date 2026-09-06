---
project: Avalon
url: https://github.com/elixir-avalon/avalon
category: Agent Frameworks and Development Tools
relevance: low
verdict: Early-stage (15 stars, ~34 commits, near-dormant) agent-abstraction framework; samen already built and gated its own agent loop (ADR-047) after rejecting the far more mature Jido for the same slot — nothing here clears that bar.
---

# 035 — Avalon

## What the project is

Avalon (elixir-avalon/avalon, Apache-2.0, by Christopher Grainger / cigrainger) is a "standardization framework for agentic workflows in Elixir." It deliberately ships interfaces over implementations: a `Conversation` structure for LLM interactions, a pluggable provider behaviour (OpenAI, Anthropic, Azure), a standardized tool interface (with a toy Calculator tool), and a graph-based workflow engine (nodes, edges, routers, visualizer). Design principles: standardization over implementation, composability, pluggability, Elixir-native, separation of concerns.

Maturity: 15 stars, 0 forks, ~34 commits. Main development burst Feb–Apr 2025; only two commits since (streaming added to the provider contract and a nimble_json_schema bump, June 2026). Roadmap items (process-based agents, persistence, multi-agent coordination, observability) remain unbuilt. Conceptual README, few examples, no production users in evidence.

## What samen could adopt

Essentially nothing wholesale — samen occupies the same slot with a first-party, verification-gated implementation (hand-built AI kernel per ADR-043, durable agent loop per ADR-047, provider behaviour in `samen_anthropic` that only accepts chokepoint-minted `%MaskedPayload{}`). Two ideas are worth a glance, not a dependency:

1. **Streaming shape in the provider contract** — what: Avalon's June-2026 PR #16 adds streaming to its provider behaviour, one of the few public Elixir examples of a streaming LLM provider contract. Why it fits: samen deferred AI streaming in ADR-047; when it revisits, this is a small reference for how to shape the callback without breaking a behaviour. Effort: S (read one PR when streaming is picked up).
2. **Graph/router workflow vocabulary** — what: explicit node/edge/router graph with a visualizer for agent workflows. Why it fits: samen's Automation engine (ADR-039) compiles actions to Reactor; a visualizer over compiled automation graphs is an operator-plane nicety Avalon demonstrates cheaply. Effort: M if ever wanted, and it would be first-party over Reactor, not Avalon code.

## What to ignore and why

- **The framework itself**: adopting it would put a third-party abstraction between samen and its AI egress chokepoint — exactly why ash_ai and Jido were rejected (vendor deps in core, no chokepoint/masking concept, INV-4 violation). Avalon's providers accept raw strings/conversations; samen's structurally refuse them.
- **Provider abstraction and tool interface**: samen already has `Samen.AI.Provider` and E3-approvals-gated tools with coverage verifiers (`mix samen.verify.agent_coverage`); Avalon's equivalents are thinner and ungoverned (no budgets, no transcript retention/erasure, no PII posture at all).
- **Bus factor / dormancy risk**: single-author, near-zero adoption, 14-month gap in substantive commits — fails any dependency-adoption bar samen applied in ADR-037.
