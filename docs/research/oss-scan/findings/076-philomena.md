---
project: Philomena
url: https://github.com/philomena-dev/philomena
category: Communication and Social
relevance: low
verdict: Mature high-traffic Phoenix imageboard whose stack choices (Redis/Exq, OpenSearch, Rustler NIFs, forked deps) run opposite to samen's Postgres-only/pure-Elixir invariants; worth mining only for its search-query grammar, media-intake validation, and CI security scanners.
---

# What the project is

Philomena is the open-source "next-generation imageboard" that powers Derpibooru — a large, actively maintained community platform for uploading, tagging, searching, discussing, and moderating images. It is a real production Elixir/Phoenix 1.8 application (~3,200 commits, active issues/PRs, AGPL-3.0) organized into five contexts under `lib/`: `philomena` (core domain: tags, images, comments, forums, moderation/reports), `philomena_web` (HTTP layer, Slime templates), `philomena_media` (media intake, analysis, processing, S3 storage via ExAws), `philomena_proxy` (camo-style external-image proxying), and `philomena_query` (a user-facing search query language parsed and compiled to OpenSearch queries). Notable stack: PostgreSQL + OpenSearch, Redis (Redix, phoenix_pubsub_redis) with Exq for background jobs, Rustler native NIFs for markdown rendering and media processing, hand-rolled auth (bcrypt_elixir + pot TOTP + canary authorization, no Pow/ash_authentication), Swoosh/Mua email, Docker Compose + devcontainer development, and git-push-over-SSH deployment. Several dependencies are pinned to custom GitHub forks.

It is single-community, not multi-tenant; has no SaaS concerns (no billing, orgs, plans, operator plane); treats user data as public-by-default (an imageboard), so it has no PII-vault/masking/erasure concepts; and uses Ecto directly, not Ash.

# What samen could adopt

1. **Sobelow + mix_audit in the verifier gate** — Philomena runs `sobelow` (Phoenix security static analysis) and `mix_audit` (dependency CVE audit) as standard checks. *Why it fits:* samen's whole identity is verification tiers; these are two off-the-shelf security tiers samen does not appear to run (digest lists ~20 `samen.verify.*` tasks, none dependency/CVE- or Phoenix-misuse-focused). Cheap, pure-Elixir, no infra. *Effort: S* — add to `ci.sh` with a curated ignore list.

2. **A bounded user-facing search query grammar (`philomena_query` pattern)** — Philomena isolates query parsing (boolean operators, field qualifiers, fuzzy matching) into its own context that compiles user input to backend queries. *Why it fits:* samen's ⌘K palette searches a non-PII tsvector; as products deepen (CRM, support desk G21, saved_views), operators will want `status:open assignee:me` style filters. The pattern — a separate, fuzz-testable parser context that compiles to a safe query AST, never string-interpolated — is directly portable to Postgres tsquery/Ash filters and composes with samen's catalog (catalog fields = legal qualifiers, PII fields refused by construction). *Effort: M* — grammar + compiler + verifier that only catalog non-PII fields are queryable.

3. **Media-intake validation discipline (`philomena_media`)** — content-sniffed MIME detection (never trust extension/headers), full analysis pass (dimensions, duration, animation) before acceptance, metadata handling, and derived-rendition generation behind one intake path. *Why it fits:* samen already has a single upload chokepoint with quarantine-by-default, but the real `Scanner` and `Storage.S3` impls are open WS-E follow-ons. Philomena's intake steps are a battle-tested checklist for what the quarantine-to-accepted promotion should verify. Adopt the checklist and ExAws-S3 usage patterns, not the Rust NIF pipeline. *Effort: M* for the validation steps inside the existing chokepoint; the NIF route should be skipped.

4. **SSRF-safe outbound image proxy (`philomena_proxy`) — as a design note only** — if samen's chat object-unfurl or marketing surfaces ever fetch external URLs/images, Philomena's camo-proxy approach (all external fetches through one egress with URL signing and target validation) matches samen's chokepoint-everything philosophy. *Effort: S* to record as the sanctioned pattern in an ADR seam; build only when a feature needs it.

# What to ignore and why

- **Redis + Exq job/pubsub stack** — samen standardized on Oban-on-Postgres (pinned, multi-node proven); adding Redis violates the minimal-infra posture for zero benefit.
- **OpenSearch** — samen deliberately chose Postgres tsvector (per-abbrev GIN indexes are the planned scale path); a second search cluster contradicts the Postgres-only purity and adds an unmaskable data sink that would need its own PII verifier tier.
- **Rustler NIFs for markdown/media** — samen chose `simple_sat` specifically to stay NIF-free; NIFs complicate the generative-proof and sabotage story (BEAM crash surface, toolchain in CI).
- **Custom GitHub forks of dependencies** (phoenix_slime, scrivener, pbkdf2) — opposite of samen's pin-hex-releases discipline; a maintenance-burden smell, not a pattern.
- **Hand-rolled auth and Canary authorization** — samen's identity spine (assent OIDC, nimble_totp, vaulted credentials) and Ash policies are strictly stronger; nothing to import.
- **Domain features** (tagging taxonomies, image galleries, forums, dupe detection) — imageboard-specific; no samen vertical needs them.
- **Moderation/report tooling as code** — conceptually adjacent to samen's G21 support-desk gap, but it is Ecto/imageboard-shaped; at most skim its report-lifecycle UX for the eventual desk build rather than porting anything.
