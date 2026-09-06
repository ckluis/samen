---
project: Harpoon
url: https://github.com/aschiavon91/harpoon
category: Developer Tools
relevance: low
verdict: A small single-purpose Elixir/Phoenix LiveView webhook inspector (webhook.site clone); same core stack as samen but no tenancy/Ash/architecture to lift — value is a handful of small library/tooling picks and a debug-tool idea, not patterns.
---

# Harpoon — evaluation vs samen

## What the project is

Harpoon is a lightweight, single-developer webhook-inspection tool (comparable to webhook.site): it hands each visitor a unique subdomain-scoped session (`http://<session_id>.localhost:4000/`), captures every HTTP request sent to that subdomain, and streams it live to a browser dashboard. Built with Elixir (~> 1.18), Phoenix (~> 1.7) + Phoenix LiveView (~> 1.0) for the reactive UI, Bandit as the web server, Ecto + `ecto_sqlite3` for storage (SQLite, not Postgres), and TailwindCSS for styling. Ships as a Docker image (`docker run -p 4000:4000 aschiavon/harpoon`) or runs locally via `mix setup`. MIT-licensed, small surface area, no multi-tenancy model, no auth/RBAC, no billing, no Ash — it is a dev-tool utility, not a framework or SaaS substrate. README is thin (setup instructions only; no architecture doc, no explanation of the subdomain-routing mechanism, no data-retention/expiry policy documented).

Dependency list of note: `bandit`, `friendlyid`, `nanoid` (short ID generation), `cors_plug`, `burrito` (packages the Elixir release as a single self-contained native executable), `magic_number` (content/mime-type sniffing from bytes), plus dev/test-only `styler`, `dialyxir`, `credo`, `sobelow` (Phoenix-aware static security analyzer).

## What samen could adopt

1. **`sobelow` as a CI verifier** — What: add the `sobelow` static security analyzer (Phoenix-specific: XSS, CSRF, SQL injection, insecure config, traversal) to `samen_web`'s CI lane. Why: it's a maintained, narrow, zero-risk addition that catches a different class of bug than samen's own `mix samen.verify.*` tiers (which check PII/masking invariants, not generic Phoenix security hygiene) — complementary, not overlapping. Effort: S.

2. **`burrito` for single-binary distribution** — What: a library that packages a Mix release into a self-contained native executable (no Erlang/Elixir install required on the target machine) for macOS/Linux/Windows. Why: samen's fleet cockpit and generated apps (`mix samen.gen.app`) currently assume a BEAM-aware host; `burrito` is a candidate if samen ever wants an "download and run" distribution path for a generated demo app or an operator-side CLI tool, without violating ADR-033 (in-monorepo distribution, no Hex packages) since it's a build step, not a published package. Effort: S to spike.

3. **Subdomain-per-session isolation pattern, as an idea for an operator debug tool** — What: Harpoon's core trick is Plug-level subdomain routing that mints an ephemeral, isolated inbox per session with zero auth. Why: samen already has fail-honest vendor adapters (Stripe, Postmark, SES, Resend, Anthropic) and a webhook ingress path (`Samen.Web.Webhook`, rate-limited via Hammer); an internal "operator webhook inspector" mounted only in dev/staging (masked-by-default, of course — samen can't ship an unauthenticated capture-everything endpoint given its PII posture) could help operators debug real vendor webhook payloads during ESP/Stripe integration work. This is a nice-to-have devtool idea, not a kernel or web-framework pattern. Effort: M if built as a real feature; likely not worth building — see below.

## What to ignore and why

- **The project as a whole (architecture, storage, UI)** — no multi-tenancy, no PII/masking model, no policy/RBAC, SQLite instead of Postgres, no Ash usage at all. There is no framework-level or kernel-level pattern here that maps onto samen_core or samen_web; it solves a narrower, unrelated problem (ephemeral request capture for humans debugging their own webhooks) with none of samen's governance concerns in scope.
- **`friendlyid`/`nanoid` short-ID generation** — samen already has its own abbrev/prefix registry (`mix samen.abbrev.reserve`) and token-based vault IDs; adding another ID-generation library would be redundant.
- **Unauthenticated, no-retention-policy request capture** — directly conflicts with samen's fail-closed, mask-by-default, audited-everything invariants (INV-1). If item 3 above is ever built, it must go through the vault/masking chokepoint and audit chain like everything else, not be lifted as-is.
- **SQLite persistence** — samen standardizes on Postgres (`ash_postgres`) everywhere; not a fit.
