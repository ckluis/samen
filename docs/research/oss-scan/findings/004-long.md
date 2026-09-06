---
project: Long
url: https://github.com/mjason/long
category: AI and Agents
relevance: medium
verdict: Well-built personal-scale Elixir/Ash agent runtime with the opposite trust posture to samen; mine 2-3 agent-UX patterns (SKILL.md skills, introspectable data-surface tool, agent self-scheduling), ignore the architecture.
---

# 004 — Long

## What the project is

Long (mjason, MIT, ~26 stars, ~204 commits, beta) is a **LAN-first, single-binary LLM agent runtime for a household or small team**, and — unexpectedly for the category — it is a genuine Elixir stack: Phoenix 1.8 + LiveView, **Ash 3 on AshSQLite**, Oban + AshOban for scheduling, Jido/Jido.AI for tools, ReqLLM for 20+ LLM providers, Deno for sandboxed TS/JS execution, and an Obscura headless-browser CLI. It ships a `/chat` LiveView with streaming + tool-call display, `/manage` config pages, WeChat and Telegram multi-account bots with cross-channel member binding, and a 4-tier memory system (WorkingCheckpoint → decaying Global/Session facts → filesystem Skills → LLM-summarized SessionArchive). Deployment is deliberately "personal CLI tool, not server infrastructure": `curl | bash` into `~/.long/`, launchd/systemd user service, SQLite file, web-first config, Docker image available.

Its signature architectural bet: **one introspectable `graphql` tool over the entire Ash data layer is the agent's primary capability** — the agent discovers what it can do via schema introspection, so adding an Ash resource grants CRUD with no new tool registration.

Trust posture is the inverse of samen's: "no hard auth/RBAC yet: members are trusted," `bash` tool runs with full host access, `check_origin` off, no SSL, no PII controls, no cost budgets, light test coverage, unpinned binary downloads (their own roadmap flags the supply chain).

## What samen could adopt

1. **Anthropic-compatible SKILL.md skills with a filesystem watcher + ETS index.**
   *What:* skills as `SKILL.md` (YAML frontmatter + markdown + scripts), filesystem as source of truth, watcher-driven ETS index, per-member vs promoted-to-global scoping.
   *Why it fits:* directly on-point for G22 (packaging agent grounding for builders) and the ADR-047 agent loop. Samen's Prompt resource + catalog grounding could gain a portable, Anthropic-ecosystem-compatible skill format that operators author as files and `mix samen.gen.agent` consumes; personal-vs-global scoping maps cleanly onto tenant-vs-operator plane. Content would still transit the EG2 masking chokepoint.
   *Effort:* **M**.

2. **Schema-introspection as the tool surface (one data tool, not N bespoke tools).**
   *What:* replace static tool catalogs with a single introspectable query tool the agent probes at runtime; "adding a resource" = "agent gains capability" with zero registration.
   *Why it fits:* samen already has the machine-readable catalog as its grounding artifact — the adoptable idea is exposing a *single read-only query tool over the catalog/data layer* (policy-scoped, masked, token-blind where required) instead of hand-registering per-resource tools, shrinking agent_coverage surface area. Writes stay out: Long's write-capable GraphQL with no permission layer is exactly what samen's "AI writes do not exist / E3 approvals" rule forbids — adopt the read half only, run it through OrgScope + PiiResolution.
   *Effort:* **M** (read tool over existing catalog + verifier tier extension).

3. **Agent self-scheduling as a first-class verb.**
   *What:* the LLM creates its own Oban-backed scheduled tasks mid-conversation (`createScheduledTask`), giving "remind me / do this nightly" UX.
   *Why it fits:* samen has Oban + ash_oban + the ADR-039 automation engine; the missing piece is an agent-proposable "scheduled automation" action kind that lands as a **draft routed through the E3 approvals engine** — a cheap, differentiating agent capability that stays inside samen's governance model.
   *Effort:* **S/M** (new Automation.Action kind + approval face + agent tool def).

4. **Memory-tier taxonomy as design input (not code).**
   *What:* the L1–L4 split — per-session working checkpoint, decaying fact/preference/goal store, skills, archived summaries.
   *Why it fits:* samen's agent loop has transcripts + retention/erasure but no long-term memory; if a memory scope is ever added, this taxonomy is a sane starting shape — with samen-specific twists Long lacks entirely (facts holding PII must be vault-routed and crypto-shreddable; decay interacts with retention policy).
   *Effort:* **L**, future roadmap item only.

## What to ignore and why

- **The entire trust/deploy posture** — SQLite/AshSQLite, trusted members, no RBAC, `check_origin` off, unsandboxed `bash` tool, 0.0.0.0 bind: all antithetical to samen's fail-closed, Postgres-only, mask-by-default invariants. Long's roadmap is busy adding what samen already has.
- **ReqLLM and Jido** — ReqLLM would put vendor/HTTP deps where INV-4 forbids them (samen's provider behaviour + adapter packages already cover this); Jido was already evaluated and rejected (`_orch/jido-eval-report.md`).
- **WeChat/Telegram channel bots** — out of samen's SaaS-foundry scope; if chat-channel ingress ever matters it would be a fail-honest adapter package, and Long's implementation (account-trust based) isn't a governance reference.
- **Single-binary `curl | bash` distribution** — samen is a monorepo substrate (ADR-033, no Hex/no binaries); the personal-CLI DX is charming but solves a different product's problem.
- **Deno sandbox for agent code execution** — decent pattern if samen ever adds a code_run tool, but Long pairs it with an unsandboxed bash escape hatch and unpinned binary downloads; not a security reference today.
