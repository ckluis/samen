---
project: Kammer
url: https://github.com/tskovlund/kammer
category: Communication and Social
relevance: medium
verdict: Not an architecture source, but a well-run AI-authored Phoenix reference with 4-6 directly liftable patterns (passkeys, step-up reauth, config tiers, email privacy mode, i18n/tz proof) — patterns only, since AGPL-3.0 code cannot flow into MIT samen.
---

# 068 — Kammer

## What the project is

Kammer is a self-hosted community platform ("Facebook Groups for associations, bands, clubs") built in **Elixir/Phoenix 1.8 + Ecto/PostgreSQL** with a **Svelte PWA** frontend (ADR-0024 replaced an earlier LiveView v1), Oban jobs, Swoosh/gen_smtp email, and Docker Compose deployment with a first-run wizard. AGPL-3.0, pre-v1, ~631 commits, tiny audience (2 stars) but genuinely active. It is *not* Ash — plain Phoenix contexts.

Striking meta-parallel to samen: it is **authored primarily by Claude working autonomously on the issue queue**, with 29 numbered ADRs, RFCs, Credo strict + Dialyzer + warnings-as-errors + coverage floors, Playwright e2e, and an "honest limitations" section (operators can read the DB; no E2E encryption in v1). Same development religion as samen, applied to a consumer product instead of a foundry.

Feature set: passwordless auth (magic links + passkeys), groups with four visibility presets and "sealed groups" (presets-not-ACLs, ADR-0009), chronological-only feeds, markdown posts/polls/reactions, timezone-aware events with RSVPs and signup slots, versioned file sharing, full-text search, guest identities with email digests, date polls / assignments / decisions register, bilingual EN+Danish.

## What samen could adopt

1. **Passkeys / WebAuthn via `wax_` (ADR-0018)** — usernameless discoverable-credential login: challenge omits `allow_credentials`, `credential_id` is the instance-wide unique key, COSE keys stored opaquely via Erlang binary serialization, clone detection via `sign_count`, JS hook feeds the *existing* login handler so no parallel session code. *Why it fits:* samen's identity spine (ADR-035) has TOTP + OIDC but no passkeys; this is the obvious next auth rung and kammer proves `wax_` composes with a hand-rolled LiveView flow exactly like samen's (no ash_authentication needed — consistent with samen's ADR-037 rejection). *Effort:* M.

2. **Step-up re-auth as a token property (ADR-0029)** — `stepped_up_at` timestamp lives on the `users_tokens` row (10-min window, 1–60 configurable): "the elevation is a property of the credential that asked, dies with it, and cannot be replayed onto another device." Two elevation paths (passkey re-assertion or single-use email round-trip bound to `target_token_id`), gating passkey enrollment/removal, device revocation, email change, account deletion, GDPR export. *Why it fits:* samen has TOTP step-up for OIDC but no generalized sudo-mode; PII reveal-grant approval, session revocation, DSAR export, and crypto-shred initiation are exactly the actions this gate was designed for, and the credential-scoped (non-mintable, non-replayable) design matches samen's fail-closed style. *Effort:* M.

3. **Three-tier configuration layer (ADR-0027) + hybrid first-run wizard (ADR-0010)** — tier 1: DB-backed instance settings with admin UI, env overlays at boot ("env always wins"); tier 2: boot-validated operator-tunable env (rate limits, token lifetimes, retention windows — each with safe default + bounds check); tier 3: named module-attribute constants for crypto params and **anti-abuse rate limits deliberately kept non-configurable** ("security footguns shouldn't hide behind runtime knobs"). Wizard: activates on first boot, setup token printed to server logs, fills only what env didn't, locks permanently. *Why it fits:* samen's operator plane + `gen.app` onboarding has no articulated settings-precedence doctrine; the security/policy rate-limit split directly applies to samen's Hammer ingress limits, and the wizard pattern strengthens `mix samen.gen.app` first-boot UX. *Effort:* M (doctrine + settings resource), wizard S on top of existing onboarding.

4. **Email privacy mode (ADR-0011)** — instance-level switch that strips content from notification emails ("N new posts in {group}" + link) so substantive content never transits third-party ESPs; auth/RSVP mails already minimal; off by default; honestly documented as partial (metadata still leaks). *Why it fits:* this is mask-by-default extended to the email egress channel — samen's `Samen.Delivery.Chokepoint` is the single place to implement a `content_minimal` mode, and it strengthens the hero claim (today a notification template could embed revealed non-PII content into Postmark/SES-transited mail). *Effort:* S.

5. **i18n + timezone existence proof for G24** — kammer ships bilingual (gettext ~>1.0) with `tz`-backed timezone-aware events on the same Phoenix generation samen uses. *Why it fits:* samen's G24 gap (USD+UTC hardcoded, no gettext) is exactly this; kammer demonstrates the dependency set and that it coexists with Oban/Swoosh/hammer without friction. *Effort:* L for samen (cross-cutting through UI kit, types, ICS, digests) — but the library choices are now validated.

6. **`sobelow` + `mix_audit` in the CI gate** — kammer runs Sobelow (Phoenix security static analysis) and MixAudit (dep CVE scan) in precommit. *Why it fits:* samen's verifier suite is world-class on its own invariants but the digest lists neither of these off-the-shelf scanners; both are near-free additions to `ci.sh` and close a supply-chain/OWASP lane samen's bespoke verifiers don't cover. *Effort:* S.

7. **Backup doctrine phrases worth stealing (docs/backups.md)** — "a backup nobody has restored is a wish"; explicit warning that "purged content lives on in old snapshots until they rotate out"; optional `age` encryption; prune-to-14 default. *Why it fits:* samen's LocalPgDump verification already restores; the snapshot-vs-erasure paragraph is worth mirroring in `docs/compliance-story.md` — and it doubles as marketing, since samen's crypto-shred makes the problem structurally moot (shredded keys render old snapshots unreadable) where kammer can only rotate. *Effort:* S (docs only).

Optional/watch: `web_push_ex` for a push channel on samen's notification inbox (M); magic-link auth as a passwordless option in the identity spine (M, low priority — samen is BYO-auth-friendly already).

## What to ignore and why

- **All code, verbatim** — AGPL-3.0 is incompatible with samen's MIT posture; adopt the patterns and ADR reasoning, never the source.
- **Svelte PWA frontend (ADR-0024)** — kammer migrated *off* LiveView to a JSON-API-driven PWA; samen is LiveView-committed with a two-plane mount architecture. Wrong direction for samen.
- **Domain features** — feeds, polls, reactions, sealed groups, decisions register, date polls: community-product surface area, not foundry substrate. At most a future `Samen.Scopes.Community` blueprint idea, not now.
- **Presets-not-ACLs (ADR-0009)** — right call for a consumer product, wrong for samen, whose Ash policy + OrgScope + reveal-grant model is the differentiator.
- **No-ActivityPub, mdex/vix, open_api_spex** — federation is out of scope; markdown/image NIFs conflict with samen's no-NIF-leaning core (simple_sat chosen partly for purity); samen standardized on JSON:API rather than OpenAPI-first.
- **Plain-Ecto data layer** — nothing to learn for samen's Ash resource substrate.
