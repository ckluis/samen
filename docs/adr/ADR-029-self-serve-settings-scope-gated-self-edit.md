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

## 6 · Amendment 2026-11-27 — an API key's scopes are enforced, and a key with no scopes is refused

The decision text above is left as written. Decision 3 says a minted key's authority is bounded by the minter's role ceiling and RP-ST-3 proves the bound at mint. A key's declared `scopes` were stored and trimmed at mint but never consulted when the key made a request: its authority at use was its effective role alone. That is now changed.

- **Scopes are enforced on every request a key makes over JSON:API.** `Samen.Transformers.ApiKeyScopePolicy` puts `policy Samen.Policy.ApiKeyScopeRefused do forbid_if always() end` first in the policy list of every resource that carries `AshJsonApi.Resource` (a build error if the resource has no `Ash.Policy.Authorizer`). The condition is true only for a key request whose scopes do not permit the action, so the policy forbids that request and applies to no other; it never authorizes. A key therefore acts with the lower of its scopes and its role: it can do what both the scopes and the resource's own role and org policies allow, an action none of those policies covers stays forbidden, and a `bypass` the resource declares cannot skip a policy that precedes it. An actor with no `:api_key` (a signed-in person, a system actor) is not affected.
- **The grammar.** A scope key is `"all"`, `"<family>"` or `"<family>.<type>"`, atoms or strings; its value is a list of `"read"` and `"write"`. The family is the underscored last segment of the resource's domain (`Demo.Crm` is `crm`), or what the domain's `samen_api_family/0` returns; the type is the resource's JSON:API type. A read action needs `read`; a create, update, destroy or generic action needs `write`. A write route that first reads a row (an update or destroy by id) needs `read` as well. `Samen.Scope.ApiKey.permits?/4` is the pure predicate.
- **A key that already holds scopes acts within them.** Its scopes were stored and never consulted, so it acted on its minter's role alone; it now acts within them. The settings page's earlier default ticked `read` only, so a key minted with that default reads and no longer writes until it is re-minted. A write route that reads the row before it writes (an update or destroy by id) needs both `read` and `write`.
- **An empty scope map authorizes nothing.** A key whose `scopes` is `%{}` (or malformed) is refused on every API request with the API's ordinary forbidden response.
- **The scopes a key is created with are checked.** The `ApiKey` resource's `:create` refuses an empty scope map and a scope key or value outside the grammar. The resource cannot know a host's router, so `Samen.Web.Settings.ApiKeys.mint/3` also refuses a family or `family.type` the app does not expose over JSON:API. A domain family containing a dot fails compilation, because `family.type` is split on the dot.
- **Minting a key with no scopes is refused.** `Samen.Web.Settings.ApiKeys.mint/3` returns `{:error, :no_scopes}` when the requested scopes, after the minter-role trim of RP-ST-3, leave none, and the API-keys page says so. Existing keys that were minted with `%{}` keep working because `mix samen.gen.api_key_scopes` writes a migration giving each the authority its minter role already granted: owner, admin and member keys get `{"all": ["read", "write"]}`, viewer keys `{"all": ["read"]}`. The host runs the generator, then `mix ecto.migrate`.
- **Out of scope.** A host's MCP endpoint authenticates the same keys but builds an actor with no `api_key` map, so scopes are not enforced there.
- **A design limit.** Scopes gate the resources exposed over the JSON:API. A load from an exposed resource into one that is not exposed (a relationship, an aggregate or a calculation) is decided by the key's role, not by its scopes.

Red paths: `RP-ST-5` a key scoped to another family is refused and one scoped to the right family reads; `RP-ST-6` a key with no scopes authorizes nothing; `RP-ST-7` the scope policy precedes a `bypass`; `RP-ST-8` minting with no scopes is refused; `RP-ST-9` the backfill gives a viewer-minted key read only. Each has a sabotage.

## 7 · Amendment 2026-11-28 — `/help` tells a key what it can do

The decision text above and §6 are left as written. §6 enforces a key's scopes; this adds the description of what they allow, so a caller (a person, or an AI agent holding the key) can learn its own authority without trial and error.

- **`GET /api/help` and `GET /api/help/<type>`** (`Samen.Api.Help.Endpoint`, mounted next to `/api/v1`) describe the resources, actions, fields and relations THIS caller can use, and who the caller is (plane, role, scopes). It is derived, never listed by hand: for each JSON:API route, `Samen.Api.Help` asks Ash `Ash.can?({resource, action}, actor, maybe_is: true, run_queries?: false)`, the same policies, the same first-position key-scope policy and the same role that the request itself meets (ADR-035's identity spine, ADR-043 §8/§8a's role ladder). An update or destroy route is listed only when its read is allowed as well, because the request reads the row first. A question Ash cannot answer (it raises) is reported and answers "not allowed": the description under-reports.
- **It shows only what the caller can do.** A resource with no allowed action is not listed; a type the caller cannot use and a type that does not exist answer the same `404`, byte for byte; a relation is listed only when both ends are. It never names another role, says what would unlock an omitted action or shows a policy description. No row is read, so no field value, vault token or custom-object definition can reach it: a PII field appears by name, type and `pii: true`, with `delivery` `"clear"` for a tenant key over its own org and `"omitted_without_grant"` otherwise (ADR-001 §6.2, ADR-028: the value is resolved only by `Samen.Api.PiiResolution` on the request itself). Every response is `Cache-Control: private, no-store` with `Vary: Authorization, Accept`. A request with no valid key gets `401` and `WWW-Authenticate: Bearer`, nothing else.
- **API errors point at help** (`Samen.Api.Help.ErrorHints`, the first plug of the API endpoint): each error of a `4xx`/`5xx` JSON:API response gets `meta._hint` (a fixed sentence selected by the error `code`, never the `detail`), `meta.help` and `links.about`. The link names a type only when the caller may use it. A key with no scopes is told so. Success bodies are not touched. The plug is used rather than AshJsonApi's per-domain `error_handler` because that handler receives neither the conn nor the actor, so it cannot tell a visible type from a hidden one (ADR-037's choice of AshJsonApi stands).
- **A new dependency**: `plug` in samen_core (ADR-033: the monorepo's hosts already lock it).
- **Not covered.** A host's MCP endpoint builds an actor with no `api_key` map and has no `/help`. A browser-session view of the description for a signed-in person is not part of this change. Custom objects (tenant data) are not described.

Red paths: `RP-ST-10` help omits an action or a resource the key cannot use, and a viewer-minted key never lists a write; `RP-ST-11` help for a hidden type is the same as for an unknown one; `RP-ST-12` an API error carries a hint and a link, a hidden type is never linked, a success body is byte-identical with the plug; `RP-ST-13` help is private and no-store; `RP-ST-14` help carries no PII value or vault token on either plane. Each has a sabotage.
