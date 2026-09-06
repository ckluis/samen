---
project: Glorbo
url: https://github.com/foobarto/glorbo
category: AI and Agents
relevance: medium
verdict: "Adjacent domain, tiny community (3 stars, pre-1.0), but a serious solo-built Elixir/OTP codebase with 3-4 concrete governance patterns worth mining for samen's ADR-047 agent loop — take patterns, not code."
---

# 003 — Glorbo

## What the project is

Glorbo is a self-hosted **agent orchestration platform** (MIT OR Apache-2.0, v0.28.8, ~1,180 commits, 3 stars) that models companies as real organizations — org charts, goals, budgets, governance, chat — and runs AI agents as "employees" inside **kernel-level bubblewrap (bwrap) sandboxes**. Pure Elixir/OTP + Phoenix LiveView (no Ash). Its design identity is *filesystem-first*: everything (agents, tasks, permissions, audit) is Markdown + YAML frontmatter or append-only JSONL under `~/.glorbo/`, with SQLite as a rebuildable derived index (`glorbo reindex`). Ships as a single Burrito-packaged binary with user-level systemd install.

Key mechanics:
- **Per-company OTP supervision tree** as crash-isolation boundary: `Company.Router` (single write chokepoint validating every agent-initiated operation), DynamicSupervisor of per-agent `Agent.Server`s, `Company.AuditLog` GenServer appending to `audit/YYYY-MM.jsonl`, cron `Scheduler`/`TaskScheduler`, `BudgetTracker`, `Approvals.Gate`.
- **Agents are ephemeral**: they wake on inbox items / heartbeat cron / channel mentions, run once as a sandboxed CLI invocation (native provider CLI or the built-in `glorbo harness` tool loop), write their answer to `$GLORBO_REPLY_PATH`, and vanish. No resident agent processes, no embedded memory layer.
- **Two-layer permission model**: declarative `resource:action:scope` ACLs are *materialized as bwrap mount namespaces* — an agent lacking `projects:write:foo` literally cannot reach that path — with the Elixir Router double-checking at the application layer. Network policy per agent: `none` / `proxy` (pasta-wrapped, Glorbo proxy port only) / `open`.
- **Governance**: per-agent `monthly_usd` budgets with pre-dispatch enforcement; Director-gated task approvals (`requires_approval: director`); an agent proposals system (hire/budget/project proposals decided by permission-holding agents or the Director); everything audited.
- **Surfaces**: LiveView dashboard (org chart, kanban, approval inbox, audit, health), MCP server (`/mcp`, 23 tools, JSON-RPC over HTTP, actor attribution `mcp:<client>`, all mutations through the same `Glorbo.Actions` seams), CLI (`doctor`/`validate`/`fmt`/`reindex`), and a term_ui-based TUI shell.

## What samen could adopt

1. **Budget "fail-honest on untracked cost" rule + tri-state pre-dispatch check** — Glorbo's `BudgetTracker.check_budget/1` returns `:ok` / `{:alert, used, cap}` (80%, dedup'd via an `alerts_fired` set rehydrated on restart) / `{:stop, used, cap}` (hard refusal until operator intervention or month rollover). Crucially, a provider whose usage parser is `"none"` is **refused at dispatch** unless the agent explicitly opts in (`allow_untracked_budget: true`), making risky configs greppable. *Why it fits:* samen's ADR-047 already has budgets/cost caps, and "refuse to run when cost cannot be attributed" is exactly samen's fail-honest adapter doctrine (ADR-014/024/026/038) applied to AI spend — plus a centralized per-model rate map (Glorbo's `config/llm_rates.exs`) mirrors samen's catalog-as-data instinct. *Effort:* **S** (tri-state check + explicit-opt-in flag + alert-dedup on the existing budget substrate; verifier tier `samen.verify.*` addition for the untracked-provider refusal).

2. **Per-dispatch egress attribution tokens** — Glorbo mints an ephemeral 32-byte token per agent dispatch, embeds it in `HTTPS_PROXY` userinfo, and its proxy stamps `{company, agent, dispatch_id}` into every audit event for that egress. *Why it fits:* samen's AI plane is chokepoint-governed but attribution today is at the payload-minting level; threading a per-run dispatch id from the ADR-047 agent loop through `samen_anthropic`/adapter calls into the hash-chained audit would give per-turn egress provenance ("which agent run caused this vendor call") — strengthening the EG2 governed-egress story and the claim-evidence discipline with near-zero new dependencies. *Effort:* **M** (context field through the AI chokepoint + adapter behaviour + audit event schema; no proxy needed since samen already owns the single egress path).

3. **Bounded reply contract with a failure-code taxonomy** — every Glorbo invocation must write `$GLORBO_REPLY_PATH`; missing/empty/oversized (1 MiB cap) map to `:reply_file_missing` / `:reply_file_empty` / `:reply_file_too_large`. *Why it fits:* samen's Automation `RunRecord` already uses a bounded-outcome allowlist; extending the same discipline to agent-loop turn outputs (explicit size caps + named failure atoms instead of generic errors) closes a small honesty gap and gives sabotage patches obvious targets. *Effort:* **S**.

4. **Heartbeat-with-empty-inbox maintenance ticks** — agents declare `heartbeat: "*/30 * * * *"`; when the cron fires with nothing queued, the agent still dispatches against a `HEARTBEAT.md` checklist (grooming loop). *Why it fits:* samen's automation engine (ADR-039) is event/trigger-driven; a first-class "scheduled agent grooming run" (via the existing ash_oban cron) would let host apps ship self-maintaining agents (queue triage, stale-record sweeps) as drafts-only proposals into the E3 approvals engine — a cheap product-depth win for the agent-grounding differentiator (G22). *Effort:* **M** (mostly generator + Prompt-resource wiring; the Oban and approvals substrate already exist).

5. **`mix samen.doctor` operator preflight** — Glorbo's `doctor [--json] [--fix] [--dry-run]` checks prerequisites (kernel, bwrap, uidmap, disk, permissions) before anything runs. *Why it fits:* samen's host apps have real environmental prerequisites (Postgres + pgvector, KMS config, Oban queues, abbrev registry state) currently checked implicitly by ~20 verifier tiers at CI time; a single operator-facing preflight with `--json` output would improve day-one host-app DX and the fleet cockpit's honest-degradation story. *Effort:* **S** (compose existing verifier probes into one task).

6. **(Conditional) Kernel-level sandboxing for future code-executing tools** — bwrap namespace isolation + `--cap-drop ALL` + pasta network scoping, with ACLs materialized as mounts. *Why it fits:* today samen's agents structurally cannot execute arbitrary code (AI outputs are drafts; mutations go through approvals), so this is not needed now — but if `mix samen.gen.agent` ever grows a bash/code-interpreter tool kind, Glorbo's "policy in Elixir, enforcement in kernel" split is the reference pattern to copy rather than invent. Park it as an ADR seam note. *Effort:* **L** (and Linux-only; defer).

## What to ignore and why

- **Filesystem-as-source-of-truth + SQLite derived index** — the heart of Glorbo's identity, and directly opposed to samen's Postgres/Ash/catalog substrate, vault chokepoints, and org-scoped policies. Markdown state has no answer to crypto-shred, org-scoping, or token-blind aggregates.
- **Company-as-employees org metaphor (CEO agents, `reports_to`, hiring proposals)** — charming for a personal agent platform; samen's two-plane operator/tenant model with the E3 approvals engine is a stricter superset for a SaaS context. The proposals taxonomy adds nothing over samen's approvals + draft pattern.
- **Burrito single-binary packaging, Homebrew tap, user systemd install** — Glorbo ships an end-user product; samen is a monorepo foundry with releases per host app (ADR-033). Wrong distribution model.
- **bwrap as a hard runtime dependency** — Linux-only (macOS falls back), and solves a threat (arbitrary code execution by agents) samen has designed out. Adopt the pattern only if that design changes (item 6).
- **TUI shell, term_ui Elm architecture, terminal-phosphor dashboard aesthetic** — surface polish for a different audience; samen's LiveView UI kit + operator plane already cover this.
- **Taking code directly** — 3 stars, 0 forks, pre-1.0 with explicitly unstable layouts/schemas, effectively a single-author project. Mine the design docs (GEP series is genuinely good); do not take a dependency.
