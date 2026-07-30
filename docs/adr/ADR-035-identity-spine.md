# ADR-035 — Identity spine architecture: the WS-A A1–A10 contracts

- **Status:** Accepted (design ADR; fixes every WS-A contract before any auth code is written).
- **Date:** 2026-07-21
- **Task:** T01 (phase 1). Binding on T02–T10 (implementation), consulted by T16 (phase gate).
- **Deciders:** fable (T01 orchestrator), grounded in ADR-037 §5.1/§5.8/§5.14 (binding input),
  `spec/full-saas-readiness.md` §WS-A + INV-1..6, `_orch/plan/spec-questions.md` (c1, c2, c3),
  ADR-029/ADR-031 (auth seam precedents), and the live seams:
  `samen_web/lib/samen/web/{auth.ex,mount.ex,plane.ex,session_controller.ex,settings/}`,
  `samen_core/lib/samen/scopes/identity/blueprint.ex`.

---

## 1 · Context

WS-A is the single biggest commercial blocker: today F2 auth is a reference wiring
(PBKDF2-over-config in one vertical, ADR-031), and the framework deliberately owns only the
authenticated-principal *seam* (`Samen.Web.Auth`, the `"samen_current_user"` session key,
`CurrentOrg`'s fail-closed `:authn` gate). The spec requires a phx.gen.auth-grade identity spine
at framework level in `samen_web`/`samen_core`, inherited by every generated app (A9), with PII
vaulted at write (A1/A5/A7) and every auth event audited and notified (A10).

This ADR fixes every contract — resource model, token scheme, session model, plug/LiveView
integration, event taxonomy, generator wiring, OIDC/2FA module boundaries — so T02–T10 implement
against decisions, not improvisation. Nothing in this ADR weakens ADR-031: BYO-auth hosts remain
supported; the spine is the framework's own first-party auth module built ON the ADR-031 seam.

## 2 · ADR-037 AshAuthentication verdict consumed — REJECT → hand-build

**Binding branch (M6 directive):** ADR-037 §5.1 evaluated `ash_authentication 4.14.1` +
`ash_authentication_phoenix 2.17.2` and returned **REJECT**. This ADR consumes that verdict:
the identity spine is **hand-built** in `samen_core`/`samen_web` on the existing seams.

The reject rationale, restated from ADR-037 §5.1 (cited, not re-litigated):

1. **C1 / INV-1 FAIL — plaintext-email identity model.** ash_authentication's sign-in
   preparation requires `email` as a queryable plaintext citext column with an equality
   identity. Samen's `Identity.User` carries `pii_attribute(:emails, …, vault: :pii_email)` —
   the column holds a `vt_*` token, per-subject encrypted, crypto-shreddable, masked on the
   operator plane (traceability A1 asserts exactly this). Adopting as designed reintroduces the
   exact column class the vault exists to eliminate; a shredded subject's login email would
   survive crypto-shred. Making it vault-compatible means forking the sign-in preparation,
   every credential flow's identity lookup, and all senders — maintaining a fork, not using a
   package.
2. **A7 sits in a release candidate.** TOTP/recovery codes/brute-force protection are 5.0-only;
   5.0 was at rc.12 with breaking changes in flight at evaluation. Adopting 4.x schedules a
   breaking migration mid-run.
3. **C2/C4 — integration labor on top of the fork.** Token resource, citext extension, and
   generated-into-`lib/` code all need catalog rows, abbrev allocations, prefix-safe columns;
   adoption cost ≥ hand-build cost, with an external breaking release on the critical path.

**Hand-build disposition for A1–A10** (per ADR-037 §5.1's binding notes, made concrete in §5–§6
below): the spine rides the seams that already exist and are tested — the `Samen.Web.Auth`
session seam (ADR-031), the `Identity.{Org,User,Membership,Role,ApiKey,Invitation}` blueprint,
the vault write path (`Samen.Vault.Change`/`Samen.Pii.WriteGuard`), the Delivery chokepoint for
token emails, and the notification + audit spine for A10. A **blind-index email lookup**
(HMAC, non-reversible, org-independent-keyed — §4.1) replaces the plaintext-email query
ash_authentication would have needed, so sign-in/reset/invite lookups never require plaintext
email at rest. Library notes adopted from §5.1: **assent** for A6 OIDC, **nimble_totp** for A7
(§7). Password hashing is this ADR's call (§4.4). Related ADR-037 verdicts consumed:
**ash_rate_limiter ADOPT (narrow, §5.14)** — auth-surface throttling is designed on it (§4.5);
**ash_state_machine (§5.8)** — the optional T05 election is **declined** for this run (§5, A5).

## 3 · Architecture overview

### 3.1 Resource model (samen_core, Identity scope blueprint)

The blueprint (`Samen.Scopes.Identity.Blueprint`) gains four org-less resources and one column.
All are materialized per-host by the ADR-004 convention, abbrevs allocated through
`mix samen.abbrev.reserve` only (ADR-023), catalogued per `catalog_parity`.

| Resource | Org scope | Purpose | Key columns (logical names) |
|---|---|---|---|
| `Identity.Credential` (new) | org-LESS | THE authentication principal (one human, N orgs) | `email_bidx` (unique, §4.1), `password_hash` (`public?: false`), `hash_scheme`, `verified_at`, `totp_secret` 🔒, `recovery_codes` 🔒, `totp_enabled_at` |
| `Identity.Session` (new) | org-less (belongs_to credential) | Revocable login session (A4) | `token_digest` (unique), `created_at`, `last_seen_at`, `expires_at`, `revoked_at`, `device_label` |
| `Identity.AuthToken` (new) | org-less (belongs_to credential) | Single-use emailed tokens (A2/A3) | `token_digest` (unique), `context` (bounded enum), `sent_to_bidx`, `expires_at`, `consumed_at` |
| `Identity.UserIdentity` (new) | org-less (belongs_to credential) | SSO link (A6) | `provider` (bounded), `provider_uid` (opaque IdP subject), `linked_at` |
| `Identity.User` (existing) | org-scoped | Per-org profile 🔒 (unchanged PII model) | + `credential_id` (nullable FK — additive, no migration break) |
| `Identity.Invitation` (existing) | org-scoped | Pending invite 🔒 | `accept_token` REPLACED by `token_digest`; `status` lifecycle hardened (A5) |

Why an org-less Credential: `Identity.User` is org-scoped, so one human with two orgs is two
User rows. Sign-in must resolve BEFORE an org actor exists; the credential is that pre-actor
principal. `authorized_orgs` derives from the credential's linked Users' Memberships — closing
the ADR-031 carry (the seam sources from real Membership rows, and the actor role is read from
the Membership, not hardcoded `:member`).

Credential/Session/AuthToken/UserIdentity have **no `json_api` block, no `show_fields`, no
tenant read policy**: they are reachable only through the auth module's governed actions
(default-deny policies; the ApiKey `token_digest` precedent — credential material is never
rendered, never API-exposed). Session listing (A4) reads through one self-scoped action
(`:list_mine`, filtered to the caller's own credential).

### 3.2 Module boundaries

- `samen_core` — resources (above), `Samen.Identity.Register` (the A1 transaction),
  `Samen.Auth.Hasher` behaviour + PBKDF2-SHA256 default (§4.4), `Samen.Auth.BlindIndex` (§4.1),
  token mint/consume actions, audit helpers (extend `Samen.Scopes.Identity.Audit`). Pure
  `ash` + OTP `:crypto`; **no new samen_core deps**.
- `samen_web` — the entire HTTP/LiveView surface: `Samen.Web.Auth` (seam, extended §5 A4),
  `Samen.Web.Auth.Plug` + `on_mount` hooks, Registration/Login/Verify/Reset/Invite-accept/
  Onboarding LiveViews + controllers, `Samen.Web.Auth.Oidc` (assent), `Samen.Web.Auth.Totp`
  (nimble_totp), rate limiting (§4.5), `samen_auth_routes` router macro. New deps land here.
- Verticals/demo — adopt via `samen_auth_routes()` at ≈0 LOC (framework-first rule).

## 4 · Cross-cutting contracts

### 4.1 Blind-index email lookup (the vault-compatible identity query)

`email_bidx = Base.encode16(HMAC-SHA256(k_bidx, normalize(email)))` where `normalize/1` is
trim + NFC + lowercase, and `k_bidx` is a dedicated, **org-independent** purpose key resolved
through the `Samen.Kms` behaviour (never a per-subject vault key — login happens before a
subject context exists; never the app secret_key_base). Properties:

- **Provisioning (the `Samen.Kms` behaviour is subject-keyed only — no purpose-key API
  exists):** `k_bidx` is provisioned as the reserved **synthetic subject `"sys:bidx"`**
  through the existing `generate_subject_key`/`unwrap` callbacks — no new behaviour
  callback, no adapter (InMemory/FileBacked/AwsKmsDynamo) or conformance-suite changes.
  `"sys:bidx"` is permanently EXCLUDED from erasure sweeps and the destruction oracle
  (shredding it would break every login lookup, not one subject's data): `shred/1` on
  `"sys:bidx"` is REFUSED, with the red test + positive control (a normal subject still
  shreds) owed in T02.
- Non-reversible (keyed HMAC); equality-only lookup — exactly what sign-in, password reset,
  invite-matching, and uniqueness need. No plaintext email column exists anywhere (INV-1).
- Unique index on `Credential.email_bidx` = global "one account per email".
- `AuthToken.sent_to_bidx` binds a token to the address it was emailed to (an email change
  invalidates in-flight tokens — the phx.gen.auth binding, vault-compatible).
- Erasure/crypto-shred: the DSAR/erasure arm nulls `email_bidx` (and `sent_to_bidx`) when the
  subject is erased — the HMAC is non-reversible, but a lookup handle to an erased subject is
  still a handle; null it.
- Red test (T02): `email_bidx` never equals the plaintext or lowercased email; rotating
  `k_bidx` is a documented operator runbook (re-derive via a vault-revealed sweep), not in
  scope this run.

### 4.2 Token scheme — hashed at rest, single-use, expiring (A2/A3/A5)

One discipline for every emailed secret, extending the ApiKey `token_digest` precedent:

- **Mint:** 32 random bytes (`:crypto.strong_rand_bytes/1`), URL-safe base64. The RAW token
  appears only inside the emailed link; it is never persisted, never logged.
- **At rest:** `token_digest = SHA-256(raw)` only. (SHA-256, not the password hasher: the input
  is 256-bit random, so brute-force cost arguments don't apply; equality lookup needs a
  deterministic digest.)
- **Single-use:** consumption is one atomic action — `UPDATE … SET consumed_at = now() WHERE
  token_digest = $1 AND consumed_at IS NULL AND expires_at > now()` (returning the row); zero
  rows = invalid/expired/replayed, one generic failure message. Sabotage twin flips the
  `consumed_at IS NULL` guard and the named replay red test must fail.
- **Expiry per context** (bounded enum on `AuthToken.context`):

| context | expiry | consumed by |
|---|---|---|
| `:email_verify` | 7 days | A2 confirm loop |
| `:password_reset` | 1 hour | A3 reset |
| `:email_change` | 1 hour | settings email change (rides A2 machinery) |
| `:totp_pending` | 5 minutes | A7 second-factor interstitial (§5 A7) |
| invite (`Invitation.token_digest`) | 14 days | A5 accept (lives on the Invitation row — one less join; single-use via the `pending → accepted` transition) |

- Expired/consumed rows are pruned by a standing Oban sweep (also the A5 `pending → expired`
  transition driver).

### 4.3 Session model + revocation (A4)

- DB-backed `Identity.Session` rows; the cookie carries the RAW session token inside the signed
  + encrypted Phoenix session under a new framework key `"samen_session_token"`; the row stores
  only the SHA-256 digest. Revocation is row-level and immediate: delete/`revoked_at` the row
  and every subsequent resolve fails — there is no stateless-JWT non-revocability by design.
- **Remember-me:** a separate signed, `http_only`, `secure`, `SameSite=Lax` cookie carrying the
  same raw token, max-age 60 days; the Session row is the single source of truth for both
  cookies (one list entry, one revocation). Sessions slide: `expires_at` = last_seen + 60 days,
  `last_seen_at` touched best-effort/throttled (the ApiKey `mark_used` precedent — never gates
  auth).
- **Concurrent-session policy (spec-questions c3, operator default):** unlimited concurrent
  sessions; ALL listed in Settings/Security with `device_label` + timestamps, individually
  revocable + revoke-all-others; optional org-level max as a Tier-0 setting (enforced at
  session create: oldest evicted). Password reset (A3) and any 2FA change (A7) revoke all other
  sessions.
- **Session metadata is non-PII by construction:** `device_label` is a bounded browser-family +
  OS-family string derived from the user agent; the raw user-agent and the client IP are NOT
  stored on the row (mask-unknown-by-default posture; IP appears only in the rate-limiter's
  ephemeral counters, §4.5). Accepted trade: the session list shows "Safari on macOS ·
  last seen 2h ago", not an IP geolist.
- **Plane disjointness:** `Identity.Session` rows authenticate TENANT-plane principals only;
  operator-plane entry and impersonation (`Samen.Web.Plane`'s operator kind /
  `Samen.Impersonation`, which carry their own session id) remain host-wired and never
  resolve through `resolve_principal/1` — an operator impersonation session is never an
  `Identity.Session` row.
- `SecurityLive` drops its honest "managed by your identity provider" placeholders for
  password/2FA/sessions ONLY when the host mounts the framework spine (the RP-ST-4 honesty
  red-path inverts: with the spine mounted, the controls are real; without it, the
  placeholders stay).

### 4.4 Password hashing (ADR-037 §5.1 left this choice here)

**PBKDF2-SHA256 via OTP `:crypto`, 600,000 iterations (OWASP 2023+ level), per-credential
16-byte salt, behind a `Samen.Auth.Hasher` behaviour** — not bcrypt/argon2.

- Rationale: `bcrypt_elixir`/`argon2_elixir` are NIF deps; the spine's core placement means the
  dep would land in `samen_core`, and this ADR's criterion is that **`samen_core/mix.exs` stays
  untouched**. PBKDF2-SHA256 at this cost is NIST-approved, OWASP-sanctioned, pure-OTP, and
  rides the exact primitive the driftwood ADR-031 reference already proved.
- `hash_scheme` (e.g. `"pbkdf2-sha256$600000"`) is stored per credential → transparent
  future migration (verify-then-rehash-on-login when the configured scheme is stronger).
- Hosts may wire argon2 via the behaviour (`config :samen_core, :auth_hasher, MyArgon2`) —
  the host app owns that dep, same shape as every adapter seam.
- Constant-time comparison (`:crypto.hash_equals/2`); a dummy verify runs on unknown-bidx
  sign-in attempts (timing parity red test in T03).

### 4.5 Rate limiting (ADR-037 §5.14 ADOPT, narrow)

`ash_rate_limiter == 1.0.0` (pinned per the retired-2.0.0 mishap) + Hammer, **as `samen_web`
deps**, enforced at the web auth chokepoints (every internet-facing auth entry lives in
`samen_web`; core actions are not directly internet-reachable, so the limiter wraps the
surfaces without touching `samen_core/mix.exs`). **Enforcement shape:** manual
`AshRateLimiter`/Hammer check calls (keyed per the rules below) in a `samen_web` plug +
LiveView hook mounted in front of the auth controllers/LiveViews — the package's
resource-level `rate_limit` DSL and `Change`/`Preparation` hooks are deliberately NOT used,
because they compile into Ash resource/action definitions, which live in `samen_core`, and
would drag the dep into the kernel (INV-4). This is a stated divergence from ADR-037 §5.14's
anticipated "action-level DSL on governed actions" shape; the §5.14 contracts themselves
(non-PII keys, deterministic backend, red tests) are unchanged. Contracts:

- **Keys are non-PII by construction** (§5.14 rule): `email_bidx`, credential id, or remote IP
  — NEVER plaintext email. Red test on key composition; sabotage twin.
- Limited surfaces + defaults (config-tunable): sign-in 10/min per bidx + 100/hr per IP;
  registration 5/hr per IP; token request (verify resend, reset request, invite resend)
  3/15min per bidx; token consume 10/min per IP; TOTP verify 5/min per credential.
- Deterministic Hammer test backend in CI (hermetic); 429 paths carry both the red test and the
  positive control. Webhook ingress limits are T19's scope, not this ADR's.

## 5 · Per-requirement decisions (A1–A10)

### A1 — Self-serve registration (spec §WS-A A1)

`Samen.Identity.Register` (samen_core, code-interfaced generic action) runs ONE repo
transaction creating: `Org` (name from form; `plan` default `"free"`), `Credential`
(password hashed §4.4, `email_bidx` §4.1, `verified_at: nil`), `User` (PII **vaulted at
write** via the existing `pii_attribute` path — `full_name`, `emails`; `credential_id` set),
owner `Membership` (`role: :owner`), and the `:email_verify` AuthToken — atomically; any
failure rolls the whole set back (no orphan orgs, no credential-less users). The verify email
leaves through the Delivery chokepoint (recipient revealed at send only, per the existing
discipline). Duplicate email → the same generic "check your inbox" response as success
(no account-existence oracle). Surface: `RegistrationLive` at `/signup` (public, pre-actor).

### A2 — Email verification (spec §WS-A A2)

Tokenized confirm loop on the §4.2 scheme (`:email_verify`, 7 days, single-use, bidx-bound).
`GET /verify/:token` consumes → sets `Credential.verified_at` → `auth.email_verified` event.
**Capability-limited while unverified** (bounded set, enforced fail-closed): an unverified
principal may complete onboarding, edit own profile, resend verification, and log out;
it may NOT send invitations (policy check on the invite action), mint API keys, or pass
live_sessions marked `:require_verified` (on_mount hook). The actor map gains `verified?:`;
the policy check is a named `Samen.Policy.Verified` (red test: unverified invite attempt
denied + positive control).

### A3 — Password reset (spec §WS-A A3)

`POST /reset` (bidx lookup; uniform response whether or not the account exists) mints a
`:password_reset` token (1h, §4.2) → email via Delivery chokepoint → `GET/PUT /reset/:token`
consumes + rehashes. **All sessions revoked on successful reset** (including the current one —
the user re-authenticates; c3 ruling). Resets audited both at request and completion
(`auth.password_reset_requested` / `auth.password_reset`, §6). In-flight reset tokens are
invalidated by an email change (bidx binding).

### A4 — Session management (spec §WS-A A4)

The §4.3 model. Plug/LiveView integration (the Mount/plane.ex seam):

- `Samen.Web.Auth` (the ADR-031 seam module) gains `resolve_principal/1`: given the conn/LV
  session map, resolve `"samen_session_token"` → digest → live Session row → `{credential_id,
  session_id}`; fall back to the existing `"samen_current_user"` read for BYO-auth hosts —
  **ADR-031 hosts keep working unchanged**. `put_session_token/2` supersedes
  `put_current_user/2` on the framework-auth path (which still writes `samen_current_user`
  with the resolved per-org user id so the settings surface's "me" contract holds).
- `Samen.Web.Auth.Plug` (browser pipeline) + `on_mount {Samen.Web.Auth, :ensure_authenticated}`
  (live_sessions) both call `resolve_principal/1`; a dead render and a websocket reconnect
  resolve identically (the Mount `to_session/from_session` pattern).
- `CurrentOrg`'s `:authn` gate keeps its ADR-031 contract; the framework spine supplies the
  `:authorized_orgs` seam from Membership rows via the credential (and the actor's role is
  read from the resolved Membership — both ADR-031 carries closed).
- Settings/Security session list per §4.3; revocation posts through a controller (cookie
  writes happen on real HTTP responses — the SessionController precedent).

### A5 — Team invitations (spec §WS-A A5)

Existing `Identity.Invitation` hardened: `accept_token` → `token_digest` (§4.2, 14 days);
invitee `email` stays **vaulted (`:pii_email`)** exactly as today; role selection bounded by
`Samen.Scope.Role` with the inviter's-rank ceiling (ManageRole precedent — no invite above
your own rank). Lifecycle `pending → accepted | revoked | expired` enforced by an explicit
transition-guard change (illegal transition = refused, red-tested). **ash_state_machine
(ADR-037 §5.8 optional T05 election): DECLINED this run** — the extension would be
`samen_core`'s first new dep inside WS-A and its core landing is T33's call (WS-E); a 3-state
guard does not justify pre-empting that ADR. Recorded revisit: when T33 lands the extension in
core, Invitation is the designated retrofit. Accept flow: token consume → existing credential
(bidx match) gains a new org `User` + `Membership` at the invited role; no credential → the
registration form completes the join (email pre-bound via the invitation vault, verified
implicitly by token possession → `verified_at` set). Invitee email renders through
`PiiResolution` per plane (tenant clear / operator `••••` — the existing MaskingCase 3-proof
discipline; the invitations surface owes its green/red/sabotage-twin tests in T05).

### A6 — SSO / OIDC (spec §WS-A A6; spec-questions c1, c2)

**OIDC via assent** (protocol library, `samen_web` dep — c2 ruling), **Google as the built
reference**; SAML ships as a documented extension seam only (c1 ruling — spec text permits).
Module boundary: `Samen.Web.Auth.Oidc` (assent strategy config per provider; routes
`/auth/oidc/:provider` + callback, mounted only when `samen_auth_routes(oidc: [...])` is
configured — an unconfigured provider is fail-honest `{:error, :not_configured}`, never a
dead button). Linkage model: `UserIdentity` (provider + opaque `provider_uid`) belongs to
Credential; the IdP-asserted email is used transiently for bidx lookup at link time and
flows through the vault write path if it creates a profile — **no plaintext IdP email is
persisted**. Link-first by default; JIT signup (`signup: true` per provider) creates the
Credential with `verified_at` set (IdP-verified email). Passwordless (SSO-only) credentials
have `password_hash: nil` — password sign-in simply fails for them; linking/unlinking emits
`auth.sso_linked` / `auth.sso_unlinked` and unlink requires another sign-in method to exist
(no lockout by unlink; red test).

### A7 — 2FA / TOTP (spec §WS-A A7; spec-questions c2)

**nimble_totp** (`samen_web` dep — c2 ruling), module `Samen.Web.Auth.Totp`. Enrollment:
secret generated server-side, provisioning URI/QR rendered once, enrollment confirmed by a
valid code before `totp_enabled_at` is set (no half-enrolled lockouts). **Vault classes
(INV-1): `totp_secret` and `recovery_codes` are vault-routed under the existing `:pii_secret`
class** (the webhook `signing_secret` precedent — secret material, per-subject encrypted,
crypto-shredded with the subject, masked everywhere by default). The verify path resolves the
secret through the vault chokepoint as the authenticating subject (the tenant-as-owner rule —
self-plane resolution; never a plane bypass, never a raw column read). Recovery codes: 10 ×
single-use, vaulted per spec ("recovery material vaulted"), shown once at enrollment,
per-code consumed markers, regeneration invalidates the prior set. Sign-in with TOTP enabled
becomes two-step: password verify mints a `:totp_pending` token (5 min, §4.2) carried in the
signed session; the Session row is created only after the second factor (or recovery code)
verifies — no half-authenticated session rows exist. 2FA enable/disable/recovery-use revokes
other sessions (c3) and emits `auth.totp_*` events.

### A8 — Onboarding scaffold (spec §WS-A A8)

`Samen.Web.Onboarding.WizardLive` at `/onboarding`, entered after first verified sign-in
(re-entrant; skippable per step; completion recorded as a Tier-0 org setting so it never
re-traps). Three framework steps, each a seam every generated app inherits: **org naming**
(writes `Org.name`), **plan selection hook** (renders the host's plan choices via a
`{mod, fun}` labels seam writing the Tier-0 `Org.plan` — the WS-B billing hookup point,
honest static copy when unwired), **teammate invite** (the A5 surface embedded). Completing
the wizard lands on the plane's landing view, where the existing `Samen.Web.FirstRun`
checklist takes over (the wizard is run-once org setup; FirstRun remains the "no data yet"
card — complementary, not duplicated).

### A9 — Generator wiring (spec §WS-A A9)

`mix samen.gen.app` emits the full spine wired and green with **zero hand-edits**: Identity
scope mount including the four new resources (abbrevs allocated through the sanctioned
allocator ONLY — ADR-023; registry hands-off), `samen_auth_routes()` in the router,
auth config block (hasher scheme + iterations, bidx key sourced from the app's `Samen.Kms`
wiring, session/remember-me durations, rate-limit table), the onboarding wizard mount, seeds
gaining a verified owner credential for the dev org, and the generated app's auth tests
(sign-up → verify → invite → accept smoke). The flagship gen-app probe (`ci.sh`) is the
acceptance instrument: A9 is DONE only when the emitted app passes the probe including the
new auth smoke, unedited. Catalog registration for every new resource/field rides the
generator path (`catalog_parity` check 3 — no ghost resources).

### A10 — Auth events: notification + audit taxonomy (spec §WS-A A10)

Every event below lands in the hash-chained audit tier via `Samen.Scopes.Identity.Audit`
helpers (extended with `auth_event/2` — the `api_key_event` precedent) AND, where a recipient
exists, dispatches through `Samen.Notifications.Engine` (suppression-aware, vault-routed body,
id-only PubSub envelope — the engine's existing contract). **Payloads are token-blind by
construction:** credential id, user id, org id, session id, event kind, bounded metadata —
never an email address, never a raw token, never a secret. Full taxonomy (bounded set):

| Event | Audit | Notification | Notes |
|---|---|---|---|
| `auth.signup` | ✓ | — (the verify email IS the touch) | org + user + credential ids |
| `auth.email_verified` | ✓ | ✓ welcome (post-verify) | |
| `auth.login` / `auth.login_failed` | ✓ | — | failed: bidx-keyed counter only, no PII |
| `auth.logout` / `auth.session_revoked` / `auth.sessions_revoked_all` | ✓ | ✓ on revoke-by-another-session | security-notice class |
| `auth.password_reset_requested` / `auth.password_reset` | ✓ | ✓ security notice to the account email | via Delivery chokepoint |
| `auth.email_change_requested` / `auth.email_changed` | ✓ | ✓ notice to BOTH old + new address | both resolved at send via vault |
| `auth.invite_sent` / `auth.invite_accepted` / `auth.invite_revoked` / `auth.invite_expired` | ✓ | ✓ inviter (accepted); org admins (accepted) | invitee addressed only through Delivery |
| `auth.sso_linked` / `auth.sso_unlinked` | ✓ | ✓ security notice | provider + uid only |
| `auth.totp_enrolled` / `auth.totp_disabled` / `auth.recovery_code_used` / `auth.recovery_codes_regenerated` | ✓ | ✓ security notice | |

**Old-address sequencing (`auth.email_changed`):** after the change commits, the old address
would no longer be resolvable — so the vault write that replaces the email RETAINS the
superseded `pii_email` value until the old-address notice dispatches. The notice's delivery
envelope references the retained value by token (job args stay token-only), the Delivery
chokepoint reveals it at send, and the retained value is pruned after dispatch (or by the
standing sweep on terminal delivery failure). Red test: the old-address notice resolves and
sends AFTER the new address is live (T03).

CDC (ADR-015 default-deny): `credential` / `session` / `auth_token` / `user_identity` tables
**stay denied** (credential material never streams); auth *events* reach consumers through the
audit tier + notification stream, not row CDC. `user` / `invitation` / `membership` keep their
existing classifications.

## 6 · Plane placement (INV-2 — every new surface)

| Surface | Plane | PII posture |
|---|---|---|
| `/signup`, `/login`, `/verify/:token`, `/reset*`, `/invite/:token`, `/auth/oidc/*`, `/2fa` | **pre-actor public** (no org actor exists yet; plane-less by construction) | Render no org data; form input flows to vault at write; responses are uniform (no account oracle) |
| `/onboarding` wizard | tenant | Own-org writes only |
| Settings/Security: sessions list + revocation, 2FA enrollment, password change | tenant | Non-PII session metadata (§4.3); TOTP/recovery via self-plane vault resolution |
| Invitations list/manage (settings surface) | tenant (clear) / operator impersonation (masked) | Invitee email via `PiiResolution` — MaskingCase 3-proofs owed (T05) |
| Auth audit events | existing aud tier, both planes per its rules | Token-blind payloads (§5 A10) |
| Operator plane | **no new surfaces** | Token-blind; operator sees auth events in the existing audit views only |

## 7 · Library choices + INV-4 (samen_core untouched)

| Concern | Choice | Placement |
|---|---|---|
| OIDC (A6) | **assent** (protocol implementation, not a vendor SDK — c2 ruling; what ash_authentication itself uses) | `samen_web/mix.exs` |
| TOTP (A7) | **nimble_totp** (c2 ruling) | `samen_web/mix.exs` |
| Rate limiting | **ash_rate_limiter == 1.0.0** + hammer (ADR-037 §5.14) | `samen_web/mix.exs` |
| Password hashing | OTP `:crypto` PBKDF2-SHA256 behind `Samen.Auth.Hasher` (§4.4) | no dep |
| Blind index / token digests / RNG | OTP `:crypto` | no dep |

**`samen_core/mix.exs` is untouched by WS-A** (INV-4 + spec-questions c2): every new
dependency above lands in `samen_web` only; core's additions are pure ash + OTP. Core builds
and gate-passes with all adapters absent (the Delivery chokepoint already fail-honests when no
ESP is configured — a token email in that state is `{:error, :not_configured}`, never a fake
send).

## 8 · Verifier + sabotage duties (INV-3)

- New tables → allocator-issued abbrevs, `tam_table`/`fld_field` catalog rows, prefix-safe
  columns (`prefixes` verifier); `password_hash`/`token_digest`/`email_bidx` are
  credential-class columns (ApiKey `token_digest` precedent): `public?: false`, never
  allowlisted, and they join the `no_plaintext_pii` projection roster (bidx red test §4.1).
- MaskingCase 3-proofs: invitation email surfaces (T05); TOTP/recovery vault routing (T07).
- Red tests + sabotage twins (each with its positive control, per house anti-tautology):
  token replay (§4.2 consume guard), session-revocation immediacy, unverified-capability gate
  (A2), rank-ceiling on invites (A5), unlink-lockout guard (A6), rate-limit 429 + non-PII keys
  (§4.5), timing-parity dummy verify (§4.4).
- `./ci-fast.sh` per task; full `./ci.sh` incl. gen-app flagship probe at the phase boundary
  (A9 is measured BY the probe).

## 9 · Consequences

**Positive** — every WS-A contract is fixed before code: one token discipline, one revocable
session model, a vault-compatible identity lookup, and a spine that generated apps inherit
whole. The two ADR-031 carries (Membership-sourced authorization, real actor role) close as
side effects. No plaintext identity column enters the schema; crypto-shred claims survive
sign-in (the exact failure ADR-037 §5.1 rejected).

**Negative / accepted** — PBKDF2-SHA256 (not memory-hard argon2) is the default hasher; the
`hash_scheme` column + behaviour make the upgrade cheap, and hosts can wire argon2 today.
Session rows add a hot-path DB read per request (mitigated by per-request memoization; measured
in T04). No raw IP on session rows means coarser session forensics. Invitation keeps a guarded
string status this run (state-machine retrofit deferred to post-T33). SAML remains a
documented seam, not an implementation (c1).

**Neutral** — BYO-auth (ADR-031) remains fully supported; the spine is opt-in per host via
`samen_auth_routes`. ash_authentication is re-evaluated at 5.0-final per ADR-037 §7
(recorded trigger), from a position where the spine already owns its data model.

---

## 10 · Addendum (T100) — A6+A7 interaction: 2FA is an ACCOUNT property, and EVERY session-minting surface honors it

- **Status:** Accepted addendum (2026-07-22). **Task:** T100 (phase 1), closing the
  cross-task gap T07's verifier surfaced (`_orch/verify/T07-verdict.json`, first `FINDING`).
- **Decision:** **step-up = YES** — the recommended default in the T100 handoff, adopted
  without deviation (no operator-approval carve-out is invoked).

### 10.1 The gap

The A7 two-step (§5 A7) was scoped to the **password** verify: `SessionController.create/2`
mints a `:totp_pending` token and detours to `/2fa` only on the password path. The A6 OIDC
callback (`OidcController.callback/2`, T06) minted a full `Identity.Session` **directly** via
`Samen.Auth.SessionCreate.create/3` with **no `totp_enabled_at` check**. A credential with
BOTH a linked OIDC identity AND TOTP enabled could therefore authenticate through the
federated flow and skip its second factor entirely — an attacker who compromises the linked
IdP account bypasses 2FA. The mistake was treating 2FA as a property of the *password flow*.

### 10.2 The rule (generic — binds every current and future surface)

**2FA is an ACCOUNT property, not a password-flow property.** Therefore:

> **No surface mints an `Identity.Session` for a credential whose `totp_enabled_at` is set
> without first routing that credential through the shared `/2fa` second-factor step-up.**

Concretely, there is exactly ONE second-factor mechanism (no parallel path): the
`:totp_pending` `AuthToken` context (§4.2), the `/2fa` interstitial (`TotpChallengeLive`),
`SessionController.verify_totp/2`, and the single `finish_login` `Session` mint. Any surface
that resolves a credential and would sign it in — the password login (A7), the **OIDC
callback (A6, this addendum)**, and any FUTURE surface (magic-link login, invite-acceptance
auto-login, post-reset auto-login) — is the SAME class and MUST:

1. check `Samen.Web.Auth.TotpStepUp.enrolled?/3` (`totp_enabled_at` set?), and
2. when true, arm the step-up via `Samen.Web.Auth.TotpStepUp.challenge/4` and redirect to
   `/2fa` — **never** call `SessionCreate.create/3` directly for an enrolled credential.

A future surface SHOULD route its final mint through `verify_totp/2`'s `finish_login` rather
than re-deriving the cookie/fixation discipline.

### 10.3 Mechanism (reuse, not duplication)

`Samen.Web.Auth.TotpStepUp` (new) owns the ONE way the interstitial is armed — mint the
`:totp_pending` token, renew the session id (fixation defense at the first privileged step),
stash the remember-me/`return_to` bookkeeping keys, hand back the conn — and the ONE
definition of those interstitial session keys, which `SessionController.verify_totp/2` reads
back. Both `SessionController.create/2` (password) and `OidcController.callback/2` (OIDC) call
it, so the two entrypoints cannot drift into parallel 2FA paths. The OIDC path's non-TOTP
branch is unchanged (direct mint), preserving the T06 behavior for credentials without 2FA.

### 10.4 Fail-closed posture (the security invariant, INV-3)

If `totp_enabled_at` is set and the second factor is not presented, **NO session exists** —
not a partial or elevatable one. The `:totp_pending` token lives under
`samen_totp_pending_token`, a key `Auth.resolve_principal/2` never reads; it resolves against
`AuthToken`, not `Session`, so even coerced into the session-token slot it authenticates
nobody (the same disjoint-key property T07's verifier confirmed for the password path). The
T100 red test proves the federated attacker — linked IdP identity but no TOTP code — obtains
zero usable session and lands on `/2fa`; the positive control proves the factor completes to
exactly one session via `finish_login`; the non-TOTP control proves unchanged OIDC login.

## 11 · Addendum (T110) — the pre-actor arc is browser-real with NO JavaScript: every credential form has a POST fallback, no credential ever in a URL

- **Status:** Accepted addendum (2026-07-23). **Task:** T110 (phase 3), an ESCALATED
  security fix filed directly from the WS-UX Persona-1 dogfood walk
  (`_orch/ux/persona-1-org-owner.md` F1/F2/F8).

### 11.1 The gap

Samen ships **zero client `<script>`** by design (the CSS-only / no-esbuild posture,
`Samen.Web.Layouts`), so in a REAL browser the LiveView socket never connects and every
`phx-submit`-only form degrades to its native HTML submit. §5 A4 (login) + §10 already solve
this — `LoginLive`'s form carries a real `action` + `method="post"` and the router pairs a
`post(...)` controller route with the GET LiveView — but that precedent was applied ONLY to
A4/A7-verify. A1 (`/signup`), A3 (`/reset`, `/reset/:token`), A5 (`/invite/:token`), the A8
onboarding wizard, and A7 ENROLLMENT were left `phx`-only. Worst case (F1): `/signup`'s
native submit defaulted to **GET**, putting the plaintext **password in the URL query
string** (`?registration[password]=…`) — browser history, access logs, `Referer`. Server-side
LiveView tests passed throughout (they simulate the socket), so the gate was green while a
real human hit a wall at the first screen.

### 11.2 The rule (generic — binds every current and future auth surface)

**No credential may ever appear in a URL / query string.** Every form carrying a password,
TOTP code, recovery code, or a reset/invite/verify token IN ITS BODY MUST submit via a real
`method="post"` to a paired controller action — in BOTH the JS-connected and no-JS-fallback
paths. A verify/reset/invite token that is legitimately PART of the url PATH
(`GET /reset/:token`, `/invite/:token`) is how the token arrives and is unchanged; the
objection is a credential appearing as a side effect of a SUBMIT.

Concretely, each pre-actor GET `live(...)` now pairs with a `post(...)` controller route in
`samen_auth_routes/1` (mirroring the login/2fa pairing): `POST /signup`, `POST /reset`,
`POST /reset/:token`, `POST /invite/:token` → `Samen.Web.Auth.AccountController`. The A8
onboarding wizard pairs its writes (`name_org`/`select_plan`/`invite`/`finish`) with
`Samen.Web.Onboarding.WizardController` under `samen_onboarding_routes/2` (Skip is a plain
GET `<.link patch>` — navigation, no write). A7 enrollment pairs
`POST /settings/security/2fa{,/recovery_codes,/disable}` → `Samen.Web.Auth.TotpEnrollController`
under `samen_settings_routes/3`'s existing `spine_totp` gate.

### 11.3 Mechanism (reuse, not duplication)

The controller — never the LiveView — is the AUTHORITATIVE mutation + rate-limit site (a
no-JS POST bypasses the LiveView entirely, so the ADR-038 §6.3 limits `:registration_ip` /
`:token_request_account` are enforced in `AccountController`, not only in the LiveView's
inline guard). The LiveView's `phx-submit` does a cheap inline password-length check for the
JS UX, then arms `phx-trigger-action` to fire the SAME real POST — the exact `LoginLive`
pattern (§10). Status flows back as NON-secret query flags (`?registered=1`,
`?error=weak_password`, `?reset=1`, `?joined=1`, onboarding `&step=`), never a credential.
The no-account-existence-oracle discipline (A1/A3) is preserved: register + request-reset
return the SAME redirect whether or not the account exists. One-time recovery codes (A7),
which cannot ride a redirect URL, are handed back via the Phoenix FLASH (a signed, single-use,
same-user channel — never a URL).

Because every auth surface lives in `samen_web` and verticals/generated apps adopt it via the
router macros at ≈0 authored LOC (the framework-first rule), fixing the macros + LiveViews
fixes every already-generated and future app with zero template/vertical hand-edits (the
`templates_golden` goldens pin only the macro-CALL lines).

### 11.4 The regression invariant (INV-3)

`account_controller_test.exs` proves, with a POSITIVE CONTROL (the pre-fix `phx-submit`-only
shape is FLAGGED, so the check is not a tautology): (a) each pre-actor arc form renders
`method="post"` + a real `action`; (b) `samen_auth_routes` emits the paired `post(...)`
routes; (c) each controller performs the real mutation and redirects with only non-secret
flags — the submitted password/token is NEVER in the redirect Location. `totp_test.exs` adds
the same POST-form + route-pairing proof for A7 enrollment.
