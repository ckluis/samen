---
project: Keila
url: https://github.com/pentacent/keila
category: Communication and Social
relevance: high
verdict: Proven Elixir/Phoenix newsletter platform whose delivery pipeline, per-sender rate limiting, bounce handling, segment query DSL, and MJML+Liquid templating are directly adoptable patterns for samen's marketing/delivery scopes — patterns only, since AGPL-3.0 forbids code reuse in MIT samen.
---

# 070 — Keila

## What the project is

Keila is an actively maintained (v0.30.2, 2.2k stars, ~1,360 commits) open-source newsletter and email-campaign platform — a self-hostable Mailchimp/Brevo alternative — written in **Elixir/Phoenix** (Phoenix ~1.7, LiveView ~1.1, Ecto/Postgres, Oban ~2.20, Elixir ~1.18). AGPL-3.0, with a commercial hosted offering (app.keila.io) and an official Docker image. It is a single-product app organized into classic Phoenix contexts: `accounts`, `auth`, `projects` (its tenancy unit), `contacts`, `mailings`, `templates`, `tracking`, `files`, `instance`, `admin`.

Load-bearing subsystems (verified in source):

- **Mailings pipeline** (`lib/keila/mailings/`): campaign render worker → delivery worker → rescue worker, a `deliver_scheduled_campaigns_worker`, a `scheduler`, a `message_pruner`, double-opt-in and welcome messages, and a transactional-message API (`POST /messages`, v0.30).
- **Pluggable ESP sender adapters** (`sender_adapters/`): SMTP, AWS SES, SendGrid, Mailgun, Postmark, Local, behind an `adapter.ex` behaviour with shared-behaviour modules (`shared_ses.ex`, `shared_local.ex`). Swoosh + gen_smtp + ex_aws_ses underneath.
- **Per-sender rate limiter** (`rate_limiter.ex`): token buckets in ETS at three scales (per-second/minute/hour), most-restrictive-wins, per-sender config, plus `persist/1`/`restore/1` to survive restarts; delivery jobs consume tokens and reschedule (Oban snooze) on `:error`.
- **Bounce/complaint handling** (since v0.6): automatic AWS SES bounce/complaint processing via Configuration Sets; hard-bounced/invalid contacts are marked `unreachable` (suppression semantics); only hard bounces surface in campaign stats.
- **Contact query DSL** (`contacts/query.ex`): Mongo-style JSON filter language (`$gt/$gte/$lt/$lte/$in/$like/$empty/$or/$and/$not`) over a whitelisted field set plus `data.`-prefixed JSONB paths and a special `messages` relation (filter contacts by `opened_at`, `bounced_at`, `campaign_id`), compiled to parameterized Ecto `dynamic/1` — injection-safe by whitelist + binding. Powers segments.
- **Contacts**: JSONB custom data (`ecto_string_map.ex`), CSV import with upserts and per-row `import_error` reporting (nimble_csv), form builder with custom field types, double opt-in (v0.13+), manual status transitions (active/unsubscribed/unreachable).
- **Templating**: MJML (Rust NIF `mjml ~5.0`) + Liquid (`solid`) + plain-text, with `<keila-content>` content slots and `<keila-code>` control-flow blocks; Liquid renders before MJML.
- **Tracking** (`tracking/tracking.ex`): HMAC-SHA256-signed open/click URLs (`create_hmac/3`, `valid_hmac?/4`), link registry per campaign, bot user-agent filtering, per-link click stats.
- **Ops/i18n**: REST API with OpenAPI spec (open_api_spex), admin user management + login-as, gettext with 7+ locales, ex_cldr, tz, telemetry.

## What samen could adopt

Legal note first: **AGPL-3.0 — no code may be copied into MIT samen.** Everything below is pattern/design adoption, re-implemented first-party (consistent with samen's ash_ai/ash_admin rejections).

1. **Multi-scale per-sender token-bucket rate limiting with persist/restore + Oban snooze.**
   *What:* ETS token buckets per sender at second/minute/hour scales, minimum-wins, state persisted to DB across restarts; delivery workers consume-or-snooze.
   *Why it fits:* samen's `Samen.Delivery.Chokepoint` is the single send path but the digest shows rate limiting only at auth/webhook ingress (hammer). ESP throughput caps (SES 14/s etc.) are a real production concern the delivery chokepoint doesn't govern yet; this is the proven Elixir shape for it, and per-sender config maps cleanly onto samen's per-adapter config. Effort: **M**.

2. **Bounce/complaint feedback loop → contact suppression.**
   *What:* SES Configuration-Set (SNS) + Postmark/ESP webhook ingestion that flips a recipient to `unreachable`, distinguishes hard/soft bounces, and gates future sends at the chokepoint.
   *Why it fits:* samen has `samen_postmark`/`samen_ses`/`samen_resend` send adapters and a webhook ingress with rate limiting, but no evidenced suppression-list semantics. Without it, any samen vertical that emails tenants' end-customers burns sender reputation. Fail-honest fits naturally (unconfigured feedback = `{:error, :not_configured}`, never silent). Effort: **M**.

3. **Campaign fan-out worker topology.**
   *What:* render-worker → per-recipient delivery-worker → rescue-worker (stuck-campaign recovery) → scheduled-campaigns poller → message pruner, all on Oban.
   *Why it fits:* samen's marketing scope exists as a blueprint but the digest shows no bulk-send machinery; this is the reference decomposition for "send to 50k contacts without losing state," and it composes with samen's existing ash_oban + same-transaction-enqueue discipline. Retention/pruning maps onto samen's retention subsystem. Effort: **L**.

4. **Segment query DSL compiled to whitelisted Ecto dynamics.**
   *What:* JSON filter objects (`{"data.plan": {"$in": [...]}, "messages": {"opened_at": {"$gt": ...}}}`) validated against a field whitelist, compiled to parameterized `dynamic/1`, with JSONB path support and engagement-relation filters.
   *Why it fits:* samen's saved_views/CRM/marketing scopes need user-authored segments; samen's catalog can *generate* the whitelist (catalog-driven fields instead of hardcoded), and PII classes mark which fields are segmentable at all (vaulted `email` can't be `$like`d — refuse by type, same move as the custom-field vault-bypass refusal). Keila proves the DSL scope that's sufficient in practice. Effort: **M**.

5. **MJML + Liquid template pipeline with content slots.**
   *What:* `mjml` NIF + `solid` Liquid rendering, template inheritance via `<keila-content>` slots, Liquid-before-MJML ordering, plain-text sibling rendering.
   *Why it fits:* samen's marketing/delivery scopes need real email templating; both libs are vendor deps that belong in an adapter/web package per INV-4, and Liquid variable interpolation must pull from chokepoint-minted masked/resolved values — the slot pattern keeps tenant-authored templates away from raw data. Keila's v0.30 breaking change (Liquid-before-MJML) is a free lesson: fix the ordering on day one. Effort: **M**.

6. **HMAC-signed open/click tracking with bot filtering.**
   *What:* per-link registry, HMAC-SHA256-signed redirect/pixel URLs verified before logging, hardcoded bot-UA filter, per-link stats.
   *Why it fits:* engagement events feed samen's analytics/marketing scopes and the segment DSL above; HMAC-signing prevents forged events and enumeration, and event rows can carry contact *tokens* (crypto-shreddable, consistent with the audit-chain design). Effort: **S**.

7. **Double opt-in + hosted form actions as a consent workflow.**
   *What:* signup form → pending contact → signed confirmation email → `double_opt_in_at` timestamp; unsubscribe/status transitions as first-class contact states.
   *Why it fits:* consent-at-capture strengthens samen's GDPR control posture (compliance-story doc) and is required product depth for the marketing scope; the timestamped consent field is exactly the kind of thing samen's DSAR export (open gap G19) should emit. Effort: **M**.

8. **Transactional-message API shape (`POST /messages`) + CSV import upsert/error-report ergonomics.**
   *What:* one API to render-a-template-and-send with per-call data; imports that upsert on email and return structured per-row errors.
   *Why it fits:* thin additions over samen's existing delivery chokepoint and CSV chokepoint — adopt the API contract, not machinery. Effort: **S**.

## What to ignore and why

- **All actual code** — AGPL-3.0 is incompatible with MIT samen. Patterns only; re-implement first-party.
- **Vanilla Phoenix-context/Ecto architecture** (phoenix_view, changesets, hand-rolled auth with argon2) — samen is Ash-native with a generator-emitted identity spine; nothing to import here.
- **Keila's tenancy model** — `projects` under one instance with a global admin is far shallower than samen's two-plane/three-identity model; adopting it would be a regression.
- **hashids public IDs** — samen already has the abbrev-registry/prefixed-token identity scheme.
- **ex_rated / hackney / HTTPoison-era plumbing** — samen standardized on hammer + req; Keila itself is mid-migration to req.
- **Swoosh as the adapter substrate** — samen's fail-honest, chokepoint-gated adapter behaviour is stricter than Swoosh's; wrapping Swoosh would dilute INV-4 and the MaskedPayload-style refusal ergonomics.
- **php_serializer / WordPress interop, Keila Cloud billing, Docker-image distribution** — irrelevant to a monorepo foundry that doesn't ship a hosted newsletter product.
- **Plaintext contact storage** — Keila stores emails/names in the clear; its contact schema cannot be copied as-is. Every adopted pattern above must route identity fields through the vault (which also means accepting that some Keila conveniences, like `$like` on email, are structurally unavailable in samen).

## Sources

- https://github.com/pentacent/keila (README, tree)
- https://github.com/pentacent/keila/blob/main/CHANGELOG.md
- mix.exs, lib/keila/{mailings,contacts,tracking}/ including rate_limiter.ex, contacts/query.ex, tracking.ex, sender_adapters/
