---
project: Buster Claw
url: https://github.com/hightowerbuilds/buster-claw
category: Agent Platforms With License Warnings
relevance: low
verdict: Elixir/Phoenix personal desktop agent surface with a few nice governance instincts, but PolyForm-Shield blocks code reuse and samen already has stronger equivalents for every pattern worth having.
---

# Buster Claw

## What the project is

A macOS **desktop assistant shell for external coding agents** (Claude Code, Codex, OpenCode): it does not embed an LLM, it is the "hands, memory, and receipts" for agent subscriptions you already have. Stack is Phoenix/LiveView at the repo root with a **Tauri (Rust) desktop shell** in `desktop/tauri`, SQLite for a durable dispatch queue, and native macOS packaging (.app/.dmg, per-arch ERTS binaries). ~991 commits, actively developed, 0 stars (recent/solo launch).

Feature surface: 217 commands (documents, in-tab browser automation on the user's real logged-in session, Google Workspace, GitHub webhooks with signature verification, finance), a "BusterPhone" SMS/voice relay, per-caller trust tiers (trusted / agent_untrusted / agent-mcp) derived from token type, local-only 127.0.0.1 binding with API tokens in the macOS Keychain, and an auditable mutation feed with redaction.

**License: PolyForm-Shield-1.0.0** — source-available, not OSI-approved, non-compete clause. Code cannot be lifted into MIT-licensed samen under any circumstances; only ideas are transferable.

## What samen could adopt

Very little survives contact with what samen already has; these are pattern-level notes only.

- **Per-caller trust tiers derived from token type** — Buster Claw maps API-token class directly to a capability tier (trusted vs agent_untrusted vs mcp). *Why it fits:* samen's MCP server already issues per-operator tokens (ADR-043); an explicit token-class→capability-tier mapping is a tidy framing if/when samen adds non-operator MCP callers (G22 agent-grounding packaging). *Effort:* S — a naming/policy convention over the existing policy engine, not new machinery.
- **"Receipts" UX framing for the audit feed** — a human-readable "everything the agent changed" feed with mutation redaction, aimed at the end user rather than compliance. *Why it fits:* samen's hash-chained audit is tenant-readable but compliance-shaped; a per-agent-run "what did the agent just do" digest view over existing audit + agent-loop transcripts (ADR-047) would strengthen the operator cockpit and the AI-plane story. *Effort:* M — a LiveView projection over existing data, no new plumbing.
- **Durable dispatch queue as the only inbound path** — all trusted inbound work lands in a durable queue first, so crashes and agent swaps are invisible. *Why noted:* samen already does this better (same-transaction Oban enqueue, EventCapture, automation runs on AshStateMachine); adopt nothing, but it independently validates samen's queue-first invariant. *Effort:* n/a — already covered.

## What to ignore and why

- **All code**: PolyForm-Shield non-compete license is incompatible with samen's MIT posture; nothing may be vendored or ported.
- **Tauri/desktop shell, macOS Keychain, per-arch ERTS packaging**: samen is a server-side multi-tenant SaaS substrate; a single-user desktop shell solves a different problem.
- **In-tab browser automation, Google Workspace commands, BusterPhone SMS/voice**: personal-assistant features on the user's own logged-in sessions — the opposite of samen's tenant-isolated, chokepoint-governed model; importing "act as the logged-in human" semantics would undermine the two-plane/masking guarantees.
- **SQLite persistence**: samen is Postgres-only by design (vault, CDC classifier, pgvector, token-blind aggregates all assume Postgres).
- **Its audit/redaction implementation**: samen's hash-chained, WORM-anchored, crypto-shreddable audit chain is strictly stronger; only the presentation idea (receipts digest) is worth keeping, per above.
