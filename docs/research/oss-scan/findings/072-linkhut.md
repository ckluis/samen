---
project: linkhut
url: https://git.sr.ht/~mlb/linkhut
category: Communication and Social
relevance: low
verdict: Well-built single-purpose Phoenix bookmarking app, not SaaS infra — cherry-pick 3-4 small identity/files/API patterns, ignore the domain.
---

# 072 — linkhut

## What the project is

linkhut is an AGPL-3.0 open-source social bookmarking service (the del.icio.us lineage), written in **Elixir/Phoenix** — Phoenix ~1.8, LiveView ~1.0, Ecto/Postgres, Oban ~2.23, Elixir ~1.19. Flagship instance at ln.ht; actively maintained (v0.1.7, current deps, sourcehut-hosted with mailing-list patch workflow). Features: tag/save/share bookmarks, unread + private links, RSS/Atom feeds (atomex/xml_builder), import/export, a del.icio.us/Pinboard-compatible REST API (`/_/v1/posts/add|all|suggest`, `/tags/rename` ...) behind an OAuth2 provider (`ex_oauth2_provider`) plus self-serve personal access tokens, IFTTT trigger/action endpoints, page snapshot/archival (recrawl, multi-format download), Prometheus metrics via prom_ex, hammer rate limiting, argon2 auth, and a `single_file` release step for simple deploys. No Ash, no multi-tenancy, no org model — it is a single-community consumer app, architecturally a plain well-groomed Phoenix context app.

## What samen could adopt

- **`gen_magic` (libmagic) MIME sniffing at the upload chokepoint** — What: server-side content-type detection via libmagic port instead of trusting client MIME. Why it fits: samen's `Samen.Files.ChokepointGuard` quarantines by default and has a fail-honest virus `Scanner` skeleton (WS-E follow-on); content sniffing is the cheap first real check before a scanner lands, and it slots into the existing single upload path. Effort: **S**.
- **Sudo mode for destructive account actions** — What: linkhut gates profile deletion behind a `require_sudo_mode` pipeline (recent re-auth required), separate from ordinary session auth. Why it fits: samen's identity spine has TOTP step-up for OIDC but no general recent-re-auth gate for dangerous tenant self-serve actions (org delete, key rotation, DSAR export); a `sudo_mode` plug composes cleanly with the existing session model and E3 approvals (approvals cover operator/AI writes; sudo covers the *end-user's own* irreversible acts). Effort: **S**.
- **Async import with status-poll UX** — What: bookmark import runs as a background task; the UI posts the upload then polls `/import/:task` for status. Why it fits: samen's CSV chokepoint does RFC-4180 round-trip but large tenant imports belong on Oban with a progress surface; this is the minimal honest UX (no fake progress) and pairs with samen's existing job substrate. Effort: **S/M**.
- **Token-authenticated private feeds** — What: per-user token in the feed URL (`VerifyTokenAuth` in a `:feed` pipeline) so private/unread RSS works in feed readers with no session. Why it fits: samen has notifications + saved_views but no feed egress; a masked, non-PII Atom feed of saved-view results is a small tenant-visible win — must route through the masking chokepoint and be classified as governed egress (EG2-style) since feed URLs are bearer credentials. Effort: **M**.
- **Self-serve personal-access-token UI pattern** — What: linkhut's settings surface for minting/revoking personal API tokens alongside full OAuth2 app registration. Why it fits: samen's `/api/v1` is deny-by-default and MCP uses per-operator tokens, but tenant-facing self-serve API token lifecycle (mint, name, revoke, last-used) is an open product-depth gap; linkhut shows the minimal complete shape. Skip `ex_oauth2_provider` itself (unmaintained-ish, non-Ash) — build on samen's own auth resources. Effort: **M**.

## What to ignore and why

- **The domain (bookmarking, tags, public feeds, snapshots/archival)** — consumer social product, orthogonal to a multi-tenant SaaS substrate; samen's cms/tags scopes already cover the generic parts.
- **`ex_oauth2_provider` as a dependency** — vendor auth rewrite territory samen already rejected (ADR-029/031 BYO-auth, ash_authentication rejection); adopt the token-UI pattern, not the library.
- **IFTTT trigger/action API** — samen's automation engine + webhooks (ADR-039) are a superset; a bespoke IFTTT shim is distribution work for a consumer product.
- **prom_ex / plug_cowboy / dart_sass toolchain choices** — samen has its own observability posture (telemetry + OTel with db_statement disabled) and UI kit; swapping brings no invariant value.
- **del.icio.us API compatibility** — an adoption strategy for the bookmarking niche, meaningless for samen's generated per-product JSON:APIs.
- **Single-community trust model** — no orgs, no planes, plaintext PII at rest; nothing to learn for the vault/masking kernel.
