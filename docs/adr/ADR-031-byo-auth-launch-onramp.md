# ADR-031 — BYO-auth launch on-ramp: the prod tenant actor is derived from an authenticated session, not a query param

- **Status:** Accepted (design + reference wiring; F2 / WS-F2). **Amended 2026-08-12 by ADR-045 §2
  — the `:auth_required?` default is now ARMED in `:prod` (fail-secure), superseding the literal
  "Off by default" in §2 below; dev/test are unchanged (the query-param dogfood and every prior test
  stay green). The amendment preserves this ADR's dev-ergonomics rationale exactly — only the `:prod`
  answer changed. Read §2's "Off by default" together with this note and ADR-045 §2/§2.5.**
- **Date:** 2026-07-20
- **Task:** WS-F2 unit 1 + 4 — prove day-1 login exists. Wire a real session-auth flow into the
  `Samen.Web.CurrentOrg` actor derivation in ONE vertical (driftwood), replacing the query-param
  identity for its prod path, and document how a new tenant/org gets created + first login.
- **Deciders:** opus (F2 sub-orchestrator), grounded in ADR-029 (auth is host-owned), the live
  `Samen.Web.CurrentOrg`/`SessionController` seams, and the existing `"samen_current_user"`
  session key the settings surface already reads.

---

## 1 · Context

Before F2, every tenant/shared LiveView resolved "what org am I acting on?" through
`Samen.Web.CurrentOrg.resolve/3`, whose FIRST resolution step trusts `params["org"]` — a raw
`?org=<uuid>`. In the local dogfood that is a feature (no login needed to demo). For a **real
launch it is an authentication hole**: anyone could act as any org's `:member` by typing that
org's id into the URL. The masking/policy kernel still scopes reads to `actor.org_id`, so this
is not a cross-org *masking* breach — but it IS an unauthenticated *identity* claim, and the
roadmap's operator TODOs carried "real auth" as the top launch blocker.

Two facts shape the fix:

1. **Auth is host-owned (ADR-029).** `samen_web` ships no password store, no login LiveView, no
   IdP, and should not grow one — a framework can't securely own every host's identity provider.
   What the framework CAN own is the *seam*: the one session key that names the authenticated
   user, and the one actor-derivation step that gates the tenant org against it.
2. **The `"samen_current_user"` session key already exists.** The self-serve settings surface
   (`Samen.Web.Settings.Reads`) already reads it as "me". F2 makes a real login the thing that
   *sets* it, and teaches `CurrentOrg` to *gate the tenant org against it* on the prod path.

## 2 · Decision — phx.gen.auth vs a minimal session verifier

**phx.gen.auth was NOT adopted; a minimal session-auth reference was wired instead.**
`phx.gen.auth` generates a whole password schema + registration/reset LiveViews assuming its own
Ecto `users` table. Samen already has vaulted `Identity.User`/`Membership`/`ApiKey` resources
whose PII rides the vault chokepoint; bolting phx.gen.auth's parallel schema alongside them would
fork identity, bypass the vault, and fight the Ash/vertical structure. The framework's job is the
*seam*, not the IdP. So:

**Three load-bearing decisions:**

1. **The framework owns the authenticated-principal seam, not the IdP.** New `Samen.Web.Auth`
   owns the `"samen_current_user"` session key: `authenticated_user_id/1` (session-ONLY — never a
   query param, because a param cannot prove identity), `put_current_user/2`, `log_out/1`. Any
   host login — phx.gen.auth, an OIDC/SAML callback, or the driftwood reference verifier — records
   the signed-in user through this ONE helper.

2. **`CurrentOrg.resolve/3` gains a fail-closed prod path, opt-in per mount.** A mount may carry
   an `:authn` label (`:required`, or `{:app_env, app, key}` for a runtime flag). When armed,
   `resolve/3` requires (a) an authenticated principal in the session AND (b) that the resolved
   org is in the principal's authorized set — the host-wired `:authorized_orgs` seam
   (`{mod, fun, args}` → `[org_id]`, the user id appended). A `?org=`/session org OUTSIDE that set
   never resolves: the viewer lands on their OWN first authorized org, never the target. No
   principal, no seam, or an empty set → `nil` (**no actor**). **Off by default** — dev/test keep
   the query-param convenience unchanged, so demo/pawchart and every existing test are untouched.

3. **Driftwood is the reference wiring (host-owned).** `Driftwood.Auth` verifies email+password
   against a salted PBKDF2-SHA256 credential record (`:crypto`, no new dep) and exposes
   `authorized_org_ids/1` (the membership seam). `DriftwoodWeb.Auth` is a module plug on the
   `:browser` pipeline (NO-OP in dev/test; in prod redirects unauthenticated requests to `/login`,
   auth+health routes exempt) plus `log_in_user/3`/`log_out_user/1`. `DriftwoodWeb.AuthController`
   serves `GET/POST /login` + `GET /logout`. The router points `:authn` at
   `{:app_env, :driftwood, :auth_required?}` and `:authorized_orgs` at `Driftwood.Auth`.

## 3 · Rationale

- **Seam, not IdP** keeps the framework honest (ADR-029) and lets each host bring the auth it
  already runs. The security boundary is the actor-derivation step in `CurrentOrg`, so even a
  request that slips past the conn-level plug (e.g. a websocket reconnect) gets no tenant actor
  without an authenticated principal — defense-in-depth, one chokepoint.
- **Opt-in, runtime-flippable** means the dogfood stays param-driven and every prior test is
  unaffected, while the SAME code proves both paths in one suite (`Application.put_env`).
- **PBKDF2 reference, not phx.gen.auth** proves the seam end-to-end with zero new deps and no
  parallel identity schema. The verdict "day-1 login exists" is demonstrated without pretending
  the reference verifier is a production IdP — the launch checklist names the swap.
- **No committed backdoor.** `:auth_credentials` is empty by default; this PUBLIC repo commits no
  working password/hash. Tests inject a runtime credential; operators provision their own.

## 4 · Tenant onboarding (F2 unit 4 — folded here)

How a new tenant/org gets created and reaches first login, on the reference:

1. **Provision the org.** An operator creates the tenant `Identity.Org` (the operator "Accounts"
   surface / seeds already do this — each account row IS a tenant org; `Driftwood.Directory`
   projects them for the switcher).
2. **Provision the first user + membership.** Create the `Identity.User` and a `Membership`
   `(user, org, role)`. The user's PII rides the vault chokepoint (unchanged).
3. **Provision a credential.** For the reference, add a PBKDF2 credential record keyed by email
   (`user_id` + `org_ids` + `salt` + `pbkdf2`) via `config :driftwood, :auth_credentials`. For a
   real deploy this step is "the user sets a password through phx.gen.auth registration" or "the
   IdP asserts the user via SSO" — the membership rows are the authorization source of truth.
4. **First login.** `GET /login` → `POST /login` verifies → `DriftwoodWeb.Auth.log_in_user/3`
   writes the framework principal + sticky current org → the user lands in their org, actor
   derived from the session. `resolve/3` thereafter constrains every page to the user's orgs.

For production, the `:authorized_orgs` seam should point at real `Identity.Membership` rows
instead of the credential store (see carry below).

## 5 · Red paths (proven — `driftwood/test/auth_prodpath_test.exs`, 13 tests)

- **RP-AU-1 (prod-path RED) unauthenticated → no actor:** with `authn` armed, a request with a
  `?org=` param but NO authenticated principal resolves to `nil` (no actor). Sabotaging the gate
  (forcing `authn_required?` false) makes the query-param identity resolve again → FAILS.
- **RP-AU-2 (prod-path RED) authenticated ≠ authorized:** an authenticated user requesting a
  `?org=` they are not a member of lands on their OWN org, never the target. Sabotage → FAILS.
- **RP-AU-3 no provisioned org → no actor:** an authenticated principal with an empty authorized
  set gets `nil`.
- **GREEN + convenience:** a member resolves + scopes to their org; with auth disabled the
  `?org=` dogfood convenience still works.
- **Login mechanism:** PBKDF2 verify green/red (wrong password, unknown email), `log_in_user/3`
  writes the principal + sticky org, the plug redirects unauthenticated prod requests to `/login`
  (auth routes exempt), and is a no-op in dev/test.

The sabotage twin is committed at `scripts/sabotages/17-f2-authn-actor-gate-bypass.patch`
(APP driftwood; flips both prod-path RED tests) and rides the standing `scripts/sabotage.sh`.

## 6 · Consequences

**Positive** — day-1 login exists on a real vertical; the launch-blocking query-param identity is
closed on driftwood's prod path with a fail-closed actor gate every vertical can adopt at ≈2
router labels; the framework grew a reusable auth-principal seam without owning an IdP; no new
dependency; no committed secret.

**Negative / accepted** — the reference verifier is PBKDF2-over-config, not a production IdP (the
checklist names the swap to phx.gen.auth / SSO); the `:authorized_orgs` seam sources from the
credential store in the reference rather than `Membership` rows (carry); the operator-plane
(SaaS-staff) auth is out of F2's tenant scope and stays a carry; the actor role is still
`:member` (not read from the membership) on the authenticated path (carry).

**Neutral** — `Samen.Web.Auth` (new) + a `CurrentOrg` gate + two `Mount` label keys
(`authn`, `authorized_orgs`); driftwood adds `Driftwood.Auth`, `DriftwoodWeb.Auth` (plug),
`DriftwoodWeb.AuthController`, `/login`+`/logout` routes, and two config flags.
