---
project: Akkoma
url: https://akkoma.dev/AkkomaGang/akkoma
category: Communication and Social
relevance: low
verdict: Mature Elixir/Phoenix ops reference in an unrelated federated-social domain; steal the EXIF-strip upload-filter idea and DB-backed whitelisted runtime config, nothing foundry-shaping.
---

# 061 — Akkoma

Note: akkoma.dev serves deliberate anti-AI-scraper garbage to automated fetchers, so the repo itself could not be read directly. Findings are assembled from docs.akkoma.dev, Wikipedia, and fediverse comparison guides (verified consistent with each other).

## What the project is

Akkoma is a federated microblogging server (ActivityPub), forked from Pleroma in 2022 for a faster development pace and more user customization. Backend is Elixir/Phoenix on PostgreSQL; AGPL-3.0. It is plain Phoenix/Ecto — no Ash, no multi-tenancy in the SaaS sense (one instance = one community), no billing, no operator/tenant plane split. Actively maintained as of 2026 and generally regarded as the practical Pleroma-lineage choice (stronger anti-abuse defaults than upstream).

Notable machinery:
- **MRF (Message Rewrite Facility)**: an ordered, composable pipeline of policy modules applied to every piece of federation traffic (SimplePolicy, KeywordPolicy, ObjectAgePolicy, SubchainPolicy for conditional branching, plus mandatory always-on policies). Custom MRF modules can be loaded from a runtime directory at boot.
- **ConfigDB**: optional database-backed runtime configuration gated by a `database_config_whitelist` of allowed sections, layered over file config.
- **Upload filter chain**: sequential filters on every upload — mandatory `Dedupe` (content-hash rename), `AnonymizeFilename`, `Mogrify` (strip EXIF, auto-orient), `Exiftool.StripMetadata` (surgical metadata removal preserving color profiles); Local and S3 uploaders; upload domain isolation strongly recommended.
- **Oban** with named queues + per-queue retry config + crontab workers; Oban Web dashboard exposed to admins.
- **Tuple-based rate limiting** `{scale_ms, limit}` per endpoint class, with separate unauthenticated/authenticated tiers and a RemoteIp plug for reverse-proxy correctness.
- MediaProxy with pluggable cache invalidation (Script/Http), LDAP auth, OAuth provider + Überauth consumer modes, Swoosh mail, Gun/Finch HTTP with proxy support.

## What samen could adopt

1. **EXIF/metadata stripping as a mandatory upload-chokepoint filter** (Akkoma's `Mogrify` strip + `Exiftool.StripMetadata` pattern).
   - Why it fits: image metadata (GPS coordinates, device serials, author names) is PII that bypasses samen's vault entirely — it rides inside file bytes through `Samen.Files.ChokepointGuard`. Samen's quarantine-by-default upload path is the natural single place to normalize/strip it, and "PII masked by default" arguably already promises this. Also adopt the content-hash dedupe rename + randomized filename (original filenames leak PII too).
   - Effort: S–M (S for a fail-honest `Exiftool`-shelling filter behind a behaviour with the fake/local lane samen already uses; M if pure-Elixir parsing is required to keep vendor tools out of core — put it in an adapter package per INV-4).

2. **Whitelisted DB-backed runtime config (ConfigDB pattern)** for the operator plane.
   - Why it fits: samen has feature flags but not operator-editable runtime settings; Akkoma's design point — an explicit whitelist of sections that may live in the DB, everything else file-only — is exactly samen's fail-closed style, and prevents the classic "operator UI can reconfigure security invariants" failure. Useful for G8 tenant-lifecycle and fleet-directive work.
   - Effort: M.

3. **Per-endpoint-class rate-limit tiers with authed/unauthed splits**.
   - Why it fits: samen currently rate-limits auth + webhook ingress only; Akkoma's declarative `{scale, limit}` catalog across timelines/search/mutations is a compact model for extending ash_rate_limiter/Hammer coverage to the JSON:API surface (deny-by-default `/api/v1`) without per-route bespoke code. Includes the RemoteIp-behind-proxy lesson samen will hit on Fly.
   - Effort: S.

4. **Ordered policy-pipeline composition (MRF shape) as prior art** for samen's ingress/automation filters.
   - Why it fits: samen already has chokepoints (single decrypt/send/upload/AI-egress paths); MRF shows a proven way to make a chokepoint *extensible* — ordered policy modules, mandatory always-on policies that cannot be removed, a transparency setting that publishes the active policy list (nice echo of samen's tenant-readable audit posture), and a Subchain policy for conditional branching. Worth a look when webhook/mailbox ingress filtering grows.
   - Effort: S (design reference only, no code reuse — AGPL).

## What to ignore and why

- **All ActivityPub/federation machinery** (signatures, object fetching, federated timelines, MediaProxy): different domain; samen products are tenant SaaS, not federated social nodes.
- **Direct code reuse of any kind**: AGPL-3.0 vs samen's MIT — patterns only, never vendoring.
- **Runtime-loaded custom Elixir modules from a directory at boot**: directly contradicts samen's verification posture (sabotage harness, AST anti-bypass probes assume a closed, verifiable code surface).
- **Frontend/theming ecosystem** (Pleroma-FE, Mangane, per-user themes): samen has its own token-CSS UI kit and function-component discipline.
- **LDAP / Überauth OAuth-consumer strategies**: samen's identity spine already covers OIDC via assent with TOTP step-up; ADR-029/031 keeps BYO-auth as the extension seam.
- **Ecto-only data layer**: nothing to learn for Ash-resource-centric samen; no policy engine comparable to samen's OrgScope/PiiResolution.
