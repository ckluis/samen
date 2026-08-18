# ADR-029 — Self-serve settings: profile self-edit through the vault chokepoint, API-key mint UI, host-owned auth boundary respected

- **Status:** Accepted (design; WS-E phase E5 implements).
- **Date:** 2026-07-16
- **Task:** WS-E / G18 — Identity resources (User `usr` with vaulted `full_name`/`emails`, ApiKey `key`, Membership `mbs`, Invitation `inv`) exist; there is NO `/settings` route, NO profile-edit LiveView, NO API-key management UI, NO session list. Build the self-serve settings surface, framework-first, keeping the vault write chokepoint and the host-owned auth boundary.
- **Deciders:** opus (WS-E design), grounded in `docs/gap-discovery/end-user.md` G8, the live `identity/blueprint.ex`, the `WriteGuard`/`Vault.Change` chokepoint, and the fact that auth (login/2FA/sessions) is deferred to the HOST (`router.ex` derives org from session; there is no login LiveView).

---

## 1 · Context

The Identity data models are complete but have zero UI. Two constraints shape the design:

1. **A profile self-edit writes the user's OWN vaulted PII** (`full_name`, `emails`). This is the "profile self-edit of own vaulted PII" entry on the six-surface masking watch-list. It must route through the SAME `WriteGuard` + `Vault.Change` chokepoint the sample-data path and the CRUD forms use — a self-edit must not become a plaintext-write bypass, and an operator impersonating a tenant must not be able to silently write plaintext into the user's masked field.

2. **Auth is HOST-OWNED and stays that way.** `samen_web/router.ex` derives org/actor from the session; there is NO framework login LiveView, no password store, no 2FA. Sessions and 2FA are properly the host's auth layer. WS-E must NOT invent a framework auth system — it builds the settings surfaces that sit ON TOP of whatever auth the host provides, and is honest about the boundary.

## 2 · Decision

**Four load-bearing decisions:**

1. **`/settings` is a framework route group (`samen_settings_routes`) with three sub-surfaces: Profile, API keys, and a read-only Sessions/Security view.** Every vertical mounts it with one macro call — zero authored settings LiveViews. The surfaces are: **Profile** (edit own `full_name`/`emails` + `handle`), **API keys** (list own keys, mint, revoke), **Security** (read-only: active impersonation sessions from the existing `Samen.Impersonation.Sessions`, recent auth-audit events).

2. **Profile self-edit routes through the vault write chokepoint, on the TENANT plane only.** The edit form is a governed `User` update action run through `Ash.update` → `WriteGuard` (which already refuses operator-plane plaintext PII writes) → `Vault.Change` (encrypts → `vt_*`). A user editing their own profile is on the tenant plane, so the write is permitted and vault-routed; an operator impersonating that user hits `WriteGuard`'s operator-plane refusal — they CANNOT write plaintext into the masked field. The form renders the current masked/plaintext value per plane through the kit (a `%Masked{}` value renders read-only with no `name`, so it can't even be submitted — the shipped kit behaviour). Red-pathed per plane.

3. **API-key management shows the token ONCE at mint, never persists or re-displays it.** The mint action creates an `ApiKey` row storing only `token_digest` (SHA-256, one-way — the existing schema); the raw key is returned in the LiveView response ONCE and never again. Minted-key authority is bounded by the minter's role ceiling (the existing `minter_role` / scope-intersection rule). Revoke sets `revoked_at`. The list shows digest-prefix + plane + scopes + created/revoked — never the key. Fail-closed: a key value is never read back from the DB (it isn't there).

4. **The Sessions/Security surface is READ-ONLY and honest about the host-auth boundary.** It surfaces what the framework genuinely owns: impersonation sessions (who acted as this org — from `impersonation/sessions.ex`) and auth-relevant audit events. It does NOT claim password/2FA/session-revocation the host owns; those render as an explicit "managed by your identity provider" affordance (honest, not a fake toggle). No framework login/2FA is built.

## 3 · Rationale

- **Framework route group + one macro** matches the notifications/flags/operator mount precedents — settings is inherited, not re-authored per vertical.
- **Self-edit through the existing chokepoint** means the new self-edit path introduces ZERO new PII-write trust surface: it's the same `WriteGuard`/`Vault.Change` the CRUD forms already proved, so the operator-plaintext-write refusal holds for free, and "profile self-edit" is closed on the masking watch-list with a per-plane red-path.
- **Show-once API keys** matches the shipped `token_digest`-only schema and standard credential hygiene — the UI can't leak a key it never stores.
- **Read-only, honest Security surface** respects the deliberate host-auth boundary (the framework was designed with auth deferred to the host) rather than inventing a parallel auth system WS-E can't properly secure.

## 4 · Consequences

**Positive** — real self-serve profile/API-key/security surfaces every vertical inherits at ≈0 LOC; the profile self-edit closes a masking watch-list surface with a per-plane test; API-key hygiene is correct-by-construction (digest-only); the host-auth boundary is respected and honest.

**Negative / accepted** — no 2FA/password/session-revocation UI (host-owned; honestly labeled). No SSO/SCIM. Sessions view is read-only (the framework doesn't own the auth session store). Tenant-admin self-serve billing (G13-adjacent) is out of scope (Operator Cockpit v2).

**Neutral** — new `samen_settings_routes` macro + three framework LiveViews (Profile, ApiKeys, Security), reusing the existing `User`/`ApiKey` actions and `Impersonation.Sessions`; no new resources, no new abbrevs.

## 5 · Red paths

- **RP-ST-1 (AC-G18-2) profile self-edit vault routing + plane gate:** a tenant editing own profile writes `full_name`/`emails` as `vt_*` (plaintext nowhere in the raw row); an operator impersonating that user is refused a plaintext write by `WriteGuard`. Sabotaging the chokepoint (letting the operator write plaintext) FAILS — this is the profile entry on the masking watch-list.
- **RP-ST-2 (AC-G18-3) API-key show-once + digest-only:** mint returns the raw key exactly once; the DB stores only `token_digest`; the list never re-displays the key. Persisting/re-reading the raw key FAILS the hygiene test.
- **RP-ST-3 (AC-G18-4) minted-key authority ceiling:** a member cannot mint a key with authority exceeding their role (the `minter_role`/scope-intersection rule). Sabotaging the intersection to grant escalated scopes FAILS.
- **RP-ST-4 (AC-G18-5) Security surface is read-only + honest:** the Security view exposes no framework password/2FA write; it renders impersonation sessions from the real source. Faking a host-auth toggle (claiming to revoke a session the framework doesn't own) FAILS the honesty structural test.
