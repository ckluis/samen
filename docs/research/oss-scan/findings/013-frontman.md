---
project: Frontman
url: https://github.com/frontman-ai/frontman
category: Agent Platforms With License Warnings
relevance: low
verdict: "An Elixir/Phoenix AI agent orchestrator, but its non-OSI AI-use terms explicitly forbid AI-assisted pattern extraction — samen's AI-authored process cannot legally mine it, and the domain (browser-attached frontend editing) is orthogonal anyway."
---

# 013 — Frontman

## What the project is

Frontman is a browser-attached AI coding agent aimed at letting non-technical teammates (PMs, designers) make frontend changes: click a rendered UI element in the running app, describe the change in plain English, and the agent edits the source files with instant hot reload. Active (663 stars, 839 commits, pushed 2026-08-19, not archived) with a three-layer MCP architecture:

1. **Browser layer** — client-side MCP server capturing DOM tree, computed CSS, screenshots, console logs (TypeScript, Apache-2.0).
2. **Dev-server layer** — framework middleware (Next.js plugin, Astro integration, Vite plugin) exposing routes, server logs, compiled modules, source maps (Apache-2.0).
3. **Frontman server** — an **Elixir/Phoenix** umbrella app (`apps/frontman_server/`, plus `frontman_notifier`, `swarm_ai`) orchestrating the agent loop, MCP tool queries, edit generation, and hot-reload triggering. BYOK LLM providers (OpenAI, Anthropic, OpenRouter).

**License**: split. Client libraries/integrations are Apache-2.0; the server is AGPL-3.0 **plus** `AI-SUPPLEMENTARY-TERMS.md` (non-OSI, issued as AGPL §7 additional terms). Verified from the repo:
- §1 bans use of the source as training/fine-tuning/eval/RAG data.
- §2 bans "using artificial intelligence tools ... to analyze, reverse-engineer, or reproduce the architecture, algorithms, ... prompt engineering strategies, **agent orchestration patterns**, or design patterns of this software for the purpose of creating a substantially similar or competing product," where "competing product" includes anything providing "AI agent orchestration ... or similar functionality."
- §3 asserts AI-generated works derived from the code stay AGPL-encumbered.

## What samen could adopt

Effectively nothing directly; two ideas-only items survive:

- **Ecosystem proof point that Elixir/Phoenix carries a production agent orchestrator** (what: cite Frontman when defending the hand-built AI kernel decision; why it fits: validates ADR-043/047's "no framework needed" posture against "should have used Python" critiques; effort S — a line in claim/ADR context, no code).
- **The product concept of operator-facing, live-context UI editing** (what: a masked, approval-gated "click an element on the tenant plane, propose a change" surface is a conceivable far-future samen operator-cockpit feature; why it fits: samen already has drafts-only AI writes + E3 approvals, which is exactly the governance such a feature needs; effort L, and it must be designed independently from human-readable public behavior only — see below).

Nothing else clears the bar:
- The Apache-2.0 parts are TypeScript/Vite/Next.js frontend tooling — samen has no JS build layer to plug them into.
- Samen already owns its equivalents: MCP server (HTTP+SSE, per-operator tokens), durable agent loop (ADR-047, zero new deps), provider behaviour with fixture cassettes, masked-payload egress. Frontman offers no PII, multi-tenancy, masking, or verification story at all.

## What to ignore and why

- **The entire Elixir server (`apps/frontman_server/`)** — the AGPL alone conflicts with samen's MIT publication, and the AI-supplementary terms are a specific trap for samen: samen is 100% AI-authored and ships AI agent orchestration, so AI-mediated study of Frontman's server for samen plausibly falls inside §2's prohibition ("competing product" is defined broadly enough to argue it). Whether the clause would hold up is irrelevant; the legal-risk-to-value ratio is terrible. Do not point agents at this code. This evaluation deliberately stayed at README/docs/license level for that reason.
- **The domain itself** — frontend hot-reload editing for non-technical users solves a dev-tooling problem, not a SaaS-substrate problem. Samen's verticals are LiveView apps generated from blueprints; "click-to-edit the rendered DOM" does not compose with samen's generator-and-verifier model.
- **BYOK multi-provider support** — samen intentionally has one first-party adapter package per vendor with fail-honest stubs (INV-4); copying a BYOK switchboard would dilute the chokepoint discipline for no current need.

**Bottom line**: interesting as evidence that Elixir agent backends are viable in the wild; unadoptable in substance; the server code is a keep-out zone for samen's AI-driven workflow.
