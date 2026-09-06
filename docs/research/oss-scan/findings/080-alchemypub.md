---
project: AlchemyPub
url: https://codeberg.org/j4nk/alchemy_pub
category: Content Management and Publishing
relevance: low
verdict: A single-author, pre-1.0 Elixir/Phoenix LiveView markdown publishing toy (no Ash, no multi-tenancy, no tests) — architecturally irrelevant to samen's trust kernel, but its privacy-respecting anonymous analytics and in-memory ETS live-render pattern are small, concrete, Apache-2.0-clear ideas worth a glance for a future CMS/docs vertical.
---

# 080 — AlchemyPub

## What the project is

AlchemyPub (`j4nk/alchemy_pub`, Codeberg, Apache-2.0) is a personal-scale static-site-that-isn't-static: it renders Markdown files (with YAML frontmatter) into live-updating Phoenix LiveView pages, holding rendered content in ETS rather than writing HTML to disk, so edits propagate to all open viewers in real time. Built on Elixir ~>1.19 / Phoenix ~>1.8 / LiveView ~>1.1 — **no Ash anywhere in the dependency tree**. Notable pieces: `earmark` + a custom transformer for wikilink-style `[[references]]` and auto header anchors; "LiveDeck," a markdown-driven slideshow/presentation mode; "onesheet" print-ready single-page layouts; URL-forwarding via frontmatter; anonymous visitor analytics (country-level, via `geolix`/MaxMind GeoIP + `ecto_sqlite3`, no raw IP retention) rendered through `phoenix_live_dashboard`/`contex` charts; dark/light theming; graceful no-JS SSR fallback. It is 46 commits deep, 1 star, 1 watcher, no test suite, no docs — a solo dogfood project, not a framework or product.

## What samen could adopt

1. **Privacy-first "no raw PII stored" visitor analytics pattern** (geolix GeoIP lookup → country only, discard the IP).
   - *What*: resolve visitor IP to country/region at ingest time via a local MaxMind DB (`geolix`), persist only the derived non-PII geo label plus an ephemeral session/presence key — never the IP itself.
   - *Why it fits samen*: directly resonates with samen's `non_pii`/token-blind-aggregate posture (ADR-015's default-deny CDC classifier, the token-blind aggregate plane). A tenant-facing "where are my visitors/users from" widget built the same way — derive-then-discard at the chokepoint, never land the PII column at all — is a clean, on-brand pattern for any future analytics/marketing scope surface, and reinforces (rather than contradicts) INV-1.
   - *Effort*: **S** (one adapter behind the existing `pii`/`non_pii` chokepoint discipline; `geolix` is a small, dependency-light Hex package).

2. **ETS-backed live-render-not-static-file publishing model.**
   - *What*: Markdown/content lives in memory (ETS) and re-renders to all connected LiveView sessions on change, instead of a build step producing static HTML.
   - *Why it fits samen*: samen has no first-party "docs/blog/CMS vertical" product surface yet beyond the `cms` universal scope blueprint (currently just a scope, not a rendering pipeline). If/when a content-vertical is built on top of `Samen.Scopes.Cms`, this is a lightweight reference for "editor saves → all viewers see it now" without inventing a static-site build/deploy step — fits the two-plane model (tenant-authored content, operator moderation) if content is later treated as tenant-owned data rather than a file-tree.
   - *Effort*: **M** (a genuinely new rendering subsystem, not a drop-in; only worth it once a content vertical is actually scoped).

## What to ignore and why

- **The project as a whole / its stack**: no Ash, no multi-tenancy, no auth, no billing, no PII vault, SQLite instead of Postgres, zero tests. It answers none of samen's hard problems (masking, crypto-shred, chokepoints, two-plane, verification discipline) and isn't trying to.
- **LiveDeck (slideshow) and onesheet (print layout) features**: single-purpose presentation UX for a personal site; no product surface in samen calls for a slideshow/deck engine.
- **Wikilink resolution / header-anchor transformer**: a nice Earmark customization, but purely a markdown-rendering nicety with no bearing on samen's kernel or generators; not worth tracking as a pattern.
- **Overall as inspiration for architecture**: given zero Ash, zero tenancy, and a 1-star/46-commit maturity level, this is not a "deep adopt" candidate — the two items above are the entire extractable value, and both are optional, low-priority, future-vertical ideas rather than anything actionable against the current WS-A..L roadmap.
