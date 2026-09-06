---
project: Nivose
url: https://codeberg.org/Nivose/nivose
category: Content Management and Publishing
relevance: medium
verdict: Not an architectural peer (plain Phoenix/Ecto, no Ash, no multi-tenant trust kernel), but it's a real, actively-maintained sibling Elixir/Phoenix app whose dependency choices are a concrete shopping list for samen's open i18n, media, sitemap/feed, and security-scan gaps.
---

# 081 — Nivose

## What the project is

Nivose (Codeberg `Nivose/nivose`, AGPL-3.0, 628 commits across 57 branches, last commit Dec 30 2025 — actively maintained) is a self-hostable CMS for the "Small Web": it pairs static-site-generation efficiency with a modern web admin UI. Feature set per its README: WYSIWYG page/template builder, a multimedia manager with automatic image optimization, an optional server-side privacy-respecting analytics module, blogging with RSS feed generation, and a multi-account dashboard with role management.

Stack (from `mix.exs`, Elixir `~> 1.18`): **Phoenix 1.8 + LiveView 1.1** on **Bandit** (not Cowboy); Ecto/Postgrex against Postgres (plain Ecto — **no Ash** anywhere in the dependency tree); `oban` 2.20 for jobs; `vix` (libvips NIF binding) + `adept_svg` + `file_info` + `xxh3` for the image pipeline; the full `ex_cldr` family (locale display, dates/times, units, territories) + `gettext` for i18n; `flop`/`flop_phoenix` for filtering/pagination; `sitemapper` + `atomex` for XML sitemap and Atom feed generation; `swoosh`/`mua`/`mail` for email; `remote_ip` for proxy-aware client IPs; `sobelow`, `credo`, `dialyxir` in the dev/test static-analysis chain; `igniter` as a codegen dependency. Deployment is Docker Compose (`.env.sample` → `docker compose up -d`) or a `mix release`-style path (`./rel/overlays/bin/migrate` + `.../server`) with a `build_container_image.sh` helper for portable image export/import. Requires NodeJS, Rust (for the xxh3 NIF), and libvips as external build/runtime dependencies.

This is a single-tenant, self-hosted publishing tool, not a SaaS-with-a-trust-kernel: no vault/masking, no org-scoping/policy engine, no audit chain, no crypto-shred, no operator/tenant plane split. Its "multi-account dashboard with role management" is ordinary RBAC, not comparable to samen's OrgScope+PiiResolution composition.

## What samen could adopt

1. **`ex_cldr` + `gettext` for i18n/l10n.** What: the CLDR locale/date-time/units/territories family plus Gettext for translated strings. Why it fits: samen's gap register explicitly carries **G24 (i18n/timezone/currency: USD+UTC hardcoded, no gettext)** as open; Nivose is a live, working reference for wiring this stack into a Phoenix/LiveView app (locale display, date/time formatting, unit conversion) without inventing the integration from scratch. Effort: **M** (adding to `samen_web`, then threading locale through the UI kit and rich `Money`/`Duration` types).

2. **`vix` (libvips NIF) image pipeline for automatic image optimization.** What: Nivose's multimedia manager runs uploads through `vix`+`adept_svg`+`file_info`+`xxh3` for format normalization/optimization and content-hash-based dedup/caching. Why it fits: samen's `Files` chokepoint (LiveView upload, quarantine-by-default) currently has no image-optimization step; this is a concrete, proven library set to slot in behind the same chokepoint if/when samen builds a CMS-flavored vertical or a marketing-asset surface. Effort: **S–M** (library adoption + a new transform step behind the existing upload chokepoint; note libvips is a native dependency, a small posture change for a project that otherwise avoids NIFs where possible — see caveats below).

3. **`sitemapper` + `atomex` for sitemap/feed generation.** What: XML sitemap and Atom/RSS feed generators. Why it fits: samen already ships a `cms` universal scope blueprint and a `marketing` surface; any tenant-facing blog/content vertical built on those scopes needs sitemap + feed output, and these are small, self-contained libraries rather than hand-rolled XML. Effort: **S**.

4. **`sobelow` in the CI static-analysis chain.** What: Phoenix-specific security static analyzer (XSS, SQL injection, insecure config, etc.), run alongside `credo`/`dialyxir`. Why it fits: samen's `ci.sh` gate already runs ~20 custom verifier tiers plus dialyzer-equivalents; sobelow is a cheap, well-known additional net for the web layer (`samen_web`) that catches a different class of issues (Phoenix config/XSS/CSRF footguns) than samen's bespoke verifiers, which are focused on PII/masking invariants rather than general web security hygiene. Effort: **S**.

5. **`flop`/`flop_phoenix` as a cross-check on the pagination contract.** What: a well-adopted Ecto filtering/sorting/pagination library. Why it fits: samen already has a bespoke `reads` keyset-pagination contract and `PageLimitClamp`; Flop is not a drop-in replacement (samen's is purpose-built for the masked/token-blind read paths) but is worth a quick read-through as an external reference to sanity-check samen's contract against a widely-used community implementation. Effort: **S** (review only, not adoption).

6. **`remote_ip` for proxy-aware client IP resolution.** What: a small plug that resolves the real client IP behind reverse proxies/load balancers (honors `Forwarded`/`X-Forwarded-For` per config, avoiding spoofable-header pitfalls). Why it fits: samen's Hammer-backed rate limiting (auth + webhook ingress) and its optional analytics module (if samen ever builds a Nivose-style server-side privacy-respecting analytics surface) both need correct client-IP resolution behind Fly.io's proxy layer. Effort: **S**.

## What to ignore and why

- **Direct code reuse.** Nivose is **AGPL-3.0**, a strong copyleft license; samen is MIT and publishes its source. Do not port or adapt Nivose source directly — treat everything above as "library/pattern to independently adopt via Hex," not "code to copy." This is the one hard constraint from this review.
- **The WYSIWYG page/template builder.** Large, self-contained editor UI; nothing in samen's current roadmap (gap register, ADRs) calls for an end-user visual page builder, and building one is a big surface samen doesn't need to prove its trust-kernel thesis. Skip unless samen builds a marketing/CMS vertical that specifically wants it.
- **The "privacy-respecting server-side analytics module" as an architecture reference.** Interesting concept overlap with samen's own `analytics` kernel module, but Nivose's is single-tenant (no cross-tenant token-blind aggregation, no org-scoping) — it answers a much simpler problem than samen's two-plane, mask-by-default analytics needs. Not worth a deep read; the idea ("optional, server-side, privacy-respecting") is more useful as a one-line inspiration than as a design to study.
- **Static-site-generation core concept.** Samen's product model is dynamic multi-tenant SaaS apps, not static sites; SSG is orthogonal to samen's mission and shouldn't influence its architecture.
- **Igniter as a general codegen strategy.** Nivose uses `igniter` as a dependency; samen already has its own generator suite (`mix samen.gen.*`) purpose-built around the vault/scope/verifier system. Swapping to Igniter would be a lateral, non-load-bearing move — not worth the churn.
- **Bandit vs Cowboy.** Nivose runs on Bandit; samen doesn't currently name its HTTP server as a pain point anywhere in the digest or gap register. Not an actionable finding either way — no evidence samen's current server choice is a problem worth revisiting off this one data point.
