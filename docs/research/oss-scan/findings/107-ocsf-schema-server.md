---
project: OCSF Schema Server
url: https://github.com/ocsf/ocsf-server
category: Infrastructure and Operations
relevance: low
verdict: A niche, stateless Elixir/Phoenix schema-browsing tool for the Open Cybersecurity Schema Framework — same language ecosystem as samen but no multi-tenant/SaaS/Ash/LiveView/PII patterns to adopt.
---

## What the project is

OCSF Schema Server is the reference web viewer for the [Open Cybersecurity Schema Framework](https://schema.ocsf.io) — a standardized taxonomy for security event logs (used by AWS Security Lake and others). It's a small Elixir/Phoenix application (720 commits, actively maintained, Apache-2.0) that:

- Loads a pre-compiled schema JSON file (produced by a separate Python `ocsf-schema-compiler` PyPI package) into memory at boot.
- Serves a browsable HTTP interface over that schema — categories, event classes, objects, attributes, dictionary — plus (per its description) tooling for validating/working with OCSF-formatted records.
- Supports "platform" and "private" schema extensions, composed in deterministic order with an explicit shadowing/conflict-resolution flag (`-a`) when an extension redefines a base-schema item.
- Ships as a single Docker container per schema version; hosting multiple OCSF versions simultaneously means running multiple containers behind an Nginx/reverse-proxy router (no built-in multi-version serving).
- Exposes a live `Schema.reload()` IEx shell command to hot-swap the in-memory schema without a restart.
- Uses Phoenix, not LiveView; no Ash, no Ecto, no Postgres, no persistent datastore of any kind — it's a stateless, read-only JSON-in-memory web server.

It is a domain-specific reference tool for the cybersecurity/observability community, not a SaaS product, not multi-tenant, and has no auth, billing, PII handling, or persistence layer at all.

## What samen could adopt

Nothing rises above minor/optional given the domain mismatch, but two small ideas are worth a passing note:

1. **Hot schema reload via a shell command** (`Schema.reload()`) — samen already has `mix samen.catalog.dump` as a static generator, but OCSF's live in-process reload-without-restart is a cheap operational nicety for an operator console (e.g., re-derive `Samen.Catalog` in a running `iex -S mix` session after a migration, without a redeploy). *Why it fits*: samen's catalog is already "schema as data" — this is just a convenience wrapper around re-computing it in-process. *Effort*: S.
2. **Deterministic extension ordering + explicit shadow flag** — OCSF's platform-extensions-then-private-extensions-then-explicit-`-a`-to-shadow model is a clean, auditable pattern for composing schema layers with conflicts made loud rather than silent. samen's `Samen.Scopes.*` blueprint composition (ADR-004) and abbrev registry (ADR-006/023/025) already solve this more rigorously (fail-closed flatten-conflict tripwire), so this is confirmation of an existing samen design choice rather than a new import. *Why it fits*: validates samen's existing approach; no action needed. *Effort*: N/A (already done, better, in samen).

Both are minor and neither justifies a dependency or architectural change.

## What to ignore and why

- **The entire application**, essentially: it has no multi-tenancy, no Ash, no LiveView, no Postgres, no auth, no billing, no PII/vault concerns, no verification/sabotage discipline — none of samen's core differentiators have an analog here to compare against.
- **The Python schema-compiler dependency** — introduces a second-language build step samen has no reason to take on; samen's catalog is Elixir-native and generated from Ash resources directly.
- **The multi-version-via-multiple-containers-behind-Nginx approach** — a workaround for a single-schema-per-process limitation that doesn't apply to samen's architecture (samen is a multi-tenant single-process app, not a versioned-artifact server).
- **Docker-volume-mounted static JSON as the "database"** — the opposite of samen's PII-vaulted, Postgres-backed, policy-scoped data model; not a pattern to borrow.

Overall: same language/framework family as samen (Elixir + Phoenix), but a different problem class entirely (static reference-data browser vs. multi-tenant SaaS foundry with a trust kernel). Low relevance; skip further evaluation.
