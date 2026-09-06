---
project: Claper
url: https://github.com/ClaperCo/Claper
category: Business and Collaboration
relevance: low
verdict: A polished vertical Phoenix/LiveView product (live polls/presentations) with standard patterns; samen keeps only a few library pointers — gettext i18n as a G24 reference, libcluster for Fly multi-node, and its S3 upload/conversion worker as a Storage.S3 reference.
---

# 054 — Claper

## What the project is

Claper is an AGPL-3.0 audience-engagement platform: presenters upload slide decks and run live polls, quizzes, forms, Q&A/posts, and embeds against a room of anonymous attendees who join by code. Active project (~783 stars, 148 forks, ongoing dev branch), Phoenix ~1.7 + LiveView ~1.0, Ecto/Postgres, Tailwind, Docker-first deployment. Notably it ships an `lti_13` top-level module (LTI 1.3 for LMS embedding), OIDC login via `oidcc`, Oban workers, `hammer` rate limiting, `libcluster` clustering, `gettext` with 8 locales, S3 storage via `ex_aws_s3`, slide-deck conversion by shelling out (`porcelain`), live transcription (`websockex` streaming to an external STT), `flop`/`flop_phoenix` tables, and `hashids` for opaque join codes. Contexts under `lib/claper/`: accounts, audit, events, presentations, polls, quizzes, forms, posts, embeds, transcriptions, stats, settings, workers, rate_limit.

It is a single-tenant-per-event consumer-ish product, not a SaaS substrate: plain Ecto contexts (no Ash), no PII vaulting, no multi-plane model, no verification discipline beyond credo/tests. Architecturally it sits well below samen's kernel; its value to samen is as a working reference for a few specific integrations.

## What samen could adopt

1. **gettext-based multilingual LiveView (reference for gap G24)** — What: Claper is a maintained, real-world example of `gettext ~> 0.26` wired through LiveView UI, emails (swoosh), and validation messages across 8 locales. Why it fits: samen's gap register lists G24 (i18n/timezone/currency absent, USD+UTC hardcoded, no gettext) as open; Claper shows the concrete file layout, locale plumbing in LiveView mounts, and per-user locale persistence samen's `samen_web` UI kit would need. Effort: M (pattern study S; actually threading gettext through the kit and generators is M).

2. **libcluster for BEAM clustering on Fly (WS-L / multi-node Oban)** — What: `libcluster ~> 3.5` with DNS-based strategies is how Claper clusters nodes in Docker/Fly deployments. Why it fits: samen's multi-node Oban leadership is proven only via a local two-node `:peer` sim; the pending real Fly production deploys (operator TODO, WS-L) will need exactly this library, and Claper is a small readable config example. Effort: S (config-level; dep lives in host apps, not samen_core, so INV-4 holds).

3. **Async file-conversion worker pipeline (reference for real `Storage.S3`)** — What: Claper's upload flow stores originals to S3 (`ex_aws_s3`), then an Oban worker shells out (via `porcelain`) to convert PDF/PPT into per-slide images, with status surfaced back over PubSub to the LiveView. Why it fits: samen's WS-E follow-on needs a real `Samen.Files.Storage.S3` and virus `Scanner` behind the existing fail-honest skeletons; Claper demonstrates the S3 + Oban + progress-notification shape (samen would keep its quarantine chokepoint in front and put `ex_aws` deps in an adapter package). Effort: M.

4. **hashids for opaque public join codes** — What: `hashids ~> 2.1` mints short non-enumerable public identifiers for events. Why it fits: samen's tenant-facing surfaces (invite links, public share links, status-page style URLs) will eventually need non-sequential public tokens; hashids is a tiny pure-Elixir option, though samen may prefer random tokens it already generates. Effort: S — take-it-or-leave-it.

5. **Anonymous low-friction participant UX (pattern only)** — What: attendees join by code with no account, get an ephemeral identity, and interact in real time; presenter moderates live. Why it fits: samen's end-customer plane (masked-by-default tenant customers) could borrow the "no-signup ephemeral actor" flow for feedback/survey surfaces (adjacent to open gap G23 product feedback), modeled as a constrained anonymous actor under OrgScope. Effort: M, and only if a vertical demands it.

## What to ignore and why

- **The product domain itself** (polls, quizzes, slide sync, word clouds, LTI 1.3): education/events vertical, orthogonal to samen's B2B SaaS foundry; LTI would only matter if an education vertical appears.
- **Auth stack** (`oidcc`, `bcrypt_elixir`, joken/jose): samen's generator-emitted identity spine (assent OIDC + nimble_totp, vaulted credentials) is deeper and already gated; swapping libs buys nothing.
- **flop/flop_phoenix**: offset-based pagination/filter tables conflict with samen's keyset `reads` contract and saved_views; reject.
- **Plain-Ecto context architecture, plug_cowboy, phoenix_view/html_helpers legacy deps**: pre-Ash, partly legacy Phoenix idioms; samen's Ash resource + policy model supersedes them.
- **Rate limiting via hammer**: samen already uses hammer 7.0 at auth/webhook ingress — nothing new.
- **Live transcription via websockex**: interesting but vendor-streaming AI is deferred in samen (ADR-047 streaming deferred) and any such adapter must be chokepoint-governed; revisit only when streaming lands.
- **No verification/PII discipline to learn from**: Claper stores emails/user content in plaintext rows with a thin audit context — samen's vault/audit/verifier stack is strictly ahead.
