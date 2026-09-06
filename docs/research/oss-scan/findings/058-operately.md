---
project: Operately
url: https://github.com/operately/operately
category: Business and Collaboration
relevance: medium
verdict: Mature, active Elixir SaaS (goals/projects/OKRs) with a directly adoptable MCP OAuth scope model and AI-agent packaging story, but its React+GraphQL/plain-Ecto architecture diverges from samen's Ash/LiveView substrate.
---

# 058 — Operately

Evaluation note: the environment provided no Agent/Task subagent tool, so the orchestrator ran the deep evaluation directly via WebFetch (README, docs/architecture.md, docs/api.md, docs/mcp-connections.md, app/mix.exs, docs tree).

## What the project is

Operately is an open-source (Apache-2.0 core, separate license for optional enterprise files) "operating system for company management": goals/OKRs linked to daily work, project management with milestones and enforced check-in cadences, team spaces, message boards, documents/files, and team/permission management. Targeted at 5–100-person teams; self-hostable via Docker Compose with a quick-start installer, also sold as flat-rate SaaS. Active and real: ~543 stars, 4,300+ commits, Semaphore CI, ongoing releases.

Stack and architecture:
- Backend: Elixir/Phoenix, plain Ecto (no Ash), Oban for jobs, Swoosh + gen_smtp for email, ex_aws/S3 for files, Sentry + telemetry_metrics/statsd for observability, ueberauth (+Google) for auth, site_encrypt for built-in Let's Encrypt.
- Frontend: React + TypeScript (separate `turboui` component package), talking to the backend via a typed API layer with TypeScript codegen (`make gen`); docs still describe Absinthe/GraphQL + Apollo, and parts have migrated toward their own typed-RPC tooling — either way, not LiveView.
- Repo layout: `/app` (Phoenix app), `/cli` (CLI for programmatic/AI access), `/turboui`, `/docs`, `/specs`.
- **Operations pattern**: every mutation is an operation module with a `run/…` pipeline — validate input → open transaction → perform action → create an `activities` audit record → trigger notifications → commit/rollback. Activities double as the user-facing feed and the audit trail.
- **AI/agent surface**: hosted remote MCP server with OAuth; granular `mcp:read` / `mcp:write` scopes (omitting scope yields read-only by default); each grant binds to exactly one company (tools cannot take a company argument); arbitrary clients supported via Client ID Metadata Documents (no pre-registration); connections reviewable/revocable from an account security dashboard with immediate token invalidation. Ships agent skills for Claude Code/Codex/OpenClaw plus a CLI and API for agents.

## What samen could adopt

1. **MCP OAuth with default-read scopes and single-tenant grant binding.**
   - What: Replace/augment samen's per-operator MCP tokens with OAuth grants carrying `mcp:read`/`mcp:write`-style scopes, read-only by default when scope is unrequested; bind each grant to exactly one org/tenant so tools structurally cannot take a tenant-selection argument; support Client ID Metadata Documents so arbitrary OAuth-capable hosts connect without pre-registration; give operators a connection dashboard with immediate revocation.
   - Why it fits: this is governance-by-construction in samen's own idiom — the one-grant-one-tenant rule is the same shape as samen's token-blind/org-scoped actor discipline, and default-deny write scope matches fail-closed policy posture. Samen's MCP server (ADR-043, per-operator tokens, HTTP+SSE) is the exact surface to harden, and packaging it well feeds the G22 agent-grounding differentiator.
   - Effort: M (OAuth server plumbing on top of the existing identity spine + MCP server; samen already has assent, sessions, and revocation machinery).

2. **Agent skills + CLI packaging for the product itself.**
   - What: Ship first-class "use this product from Claude Code/Codex" packaging — a small CLI over the JSON:API, published agent skills/instructions, and docs that treat AI agents as a primary client persona.
   - Why it fits: samen's G22 gap ("agent-grounding packaging for builders") is exactly this; samen already has the machine-readable catalog and MCP server, but Operately demonstrates the last mile — skills files, CLI, and agent-facing docs — that makes the grounding usable by external builders.
   - Effort: M (CLI generator + skills templates emitted by `mix samen.gen.app`; catalog already provides the grounding data).

3. **Check-in cadence / accountability workflow as a scope capability.**
   - What: An opinionated cadence engine on the `work` scope — scheduled check-ins, goal reviews with status (on-track/at-risk), reminder jobs, and an activity-feed rendering of updates. Operately's core product insight is that enforced cadence, not flexible structure, is the differentiator.
   - Why it fits: samen's `Samen.Scopes.work` has Project + Task but no cadence layer; this is a high-leverage, vertical-agnostic product-depth addition (freight ops reviews in driftwood, clinic huddles in pawchart) built from parts samen already owns (Oban scheduling, notifications, automation engine).
   - Effort: M.

4. **User-facing activity feed derived from the audit substrate.**
   - What: Operately's operations pipeline writes one `activities` record per mutation and derives both notifications and a human-readable, per-object/per-space activity feed from it. Samen's hash-chained audit is compliance-grade but not (per the digest) surfaced as a friendly per-record timeline in the tenant plane.
   - Why it fits: samen already pays the write cost (audit events, wide events, notifications); a masked-aware feed component in the UI kit (rendering `%Masked{}` inline) would convert existing audit data into product value with zero new invariant risk.
   - Effort: S–M (read-side projection + UI kit component; no new write paths).

5. **Zero-ops self-host ergonomics (reference only).**
   - What: One-command Docker Compose installer plus `site_encrypt` (in-BEAM Let's Encrypt) so a single container serves TLS with no reverse proxy.
   - Why it fits: samen's generated apps currently assume Fly deploys; a self-host lane would widen who can run a generated product. site_encrypt specifically is a neat BEAM-native trick worth knowing.
   - Effort: S to note as an ADR option; M to actually emit a compose/self-host artifact from the generator. Low priority versus the WS-L cloud drills.

## What to ignore and why

- **React + TypeScript + Apollo/codegen frontend, and the GraphQL/Absinthe API layer.** Samen deliberately chose LiveView + deny-by-default JSON:API; adopting a JS SPA or GraphQL would reverse settled decisions and reopen the PII-masking rendering problem (`%Masked{}` works because rendering stays server-side).
- **Plain Ecto contexts + hand-rolled operations pattern as an architecture.** Samen gets the same transactional action→audit→notification pipeline from Ash actions/changes plus its chokepoints, with policies and verifiers on top; the pattern is validation of samen's approach, not something to import.
- **ueberauth for auth.** Samen already standardized on assent (ADR-035); no reason to switch.
- **The tenancy/access model.** Operately's account→company→people model has no PII vaulting, no two-plane split, no token-blind aggregates — it is strictly weaker than samen's model; nothing to learn on the trust kernel.
- **Sentry/StatsD observability stack.** Samen's OpenTelemetry posture (with db_statement disabled for token hygiene) is deliberate; StatsD/Sentry would be a lateral move.
- **The product domain wholesale.** Goals/OKR software is one vertical, not substrate; samen should absorb the cadence *pattern* (item 3), not clone the product.
- **Stale-docs caveat.** Operately's architecture/api docs lag the code (still describing GraphQL after apparent migration toward their own typed-RPC tooling) — a reminder that samen's docs-verified-as-code discipline (doc_commands_test.exs) is worth keeping, and to verify any Operately detail against source before copying.
