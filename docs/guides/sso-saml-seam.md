# SSO: the OIDC module and the SAML extension seam

**Status:** OIDC is built (Google reference IdP). SAML is a **documented extension
seam**, not an implementation — per ADR-035 §5 A6 and the operator M-question
ruling (spec-questions c1: "OIDC-only build; SAML documented"). This guide is the
seam: it fixes the boundary a future SAML task builds against, so adding SAML is a
new module beside OIDC, not a refactor of it.

## What ships today (A6, OIDC)

The optional OIDC module (ADR-035 §5 A6):

- `Samen.Web.Auth.Oidc` (samen_web) — the protocol layer over **assent** (a
  protocol implementation, not a vendor SDK; the same library `ash_authentication`
  uses). Google is the built reference IdP. State/nonce are validated before any
  token exchange; an unconfigured provider fail-honests `{:error, :not_configured}`.
- `Samen.Web.Auth.OidcController` (samen_web) — the `GET /auth/oidc/:provider`
  request + `GET /auth/oidc/:provider/callback` endpoints, mounted **only** when a
  host passes `oidc:` to `samen_auth_routes/1`. No `oidc:` → no routes.
- `Samen.Identity.OidcLink` (samen_core) — the host-agnostic, pure-`ash`
  link/provision transaction: returning-SSO resolve, link-to-existing (bidx match,
  ADR-035 §4.1), or JIT provision (`signup: true`). The IdP email is **vaulted at
  write** on the `User`; it is never persisted on the `UserIdentity` link row.
- `Identity.UserIdentity` (samen_core blueprint) — the org-less SSO link:
  `(provider, provider_uid)` → `Credential`, unique on `(provider, provider_uid)`.

### Enabling OIDC in a host

```elixir
# router
import Samen.Web.Router

scope "/" do
  pipe_through :browser
  samen_auth_routes namespace: MyApp.Identity, repo: MyApp.Repo, oidc: [:google]
end
```

```elixir
# config/runtime.exs — the IdP credentials (operator-provisioned secrets)
config :samen_web, Samen.Web.Auth.Oidc,
  providers: %{
    google: [
      client_id: System.fetch_env!("GOOGLE_OIDC_CLIENT_ID"),
      client_secret: System.fetch_env!("GOOGLE_OIDC_CLIENT_SECRET"),
      redirect_uri: "https://app.example.com/auth/oidc/google/callback",
      signup: true
    ]
  }
```

For a **live** Google sign-in the host also adds assent's optional runtime deps to
its own `mix.exs` — an HTTP client and JWT verifier: `{:req, "~> 0.4"}` and
`{:jose, "~> 1.11"}` (same host-owns-the-adapter-dep posture as wiring argon2 for
password hashing, ADR-035 §4.4). Without them the module still compiles and simply
fail-honests `{:error, :not_configured}` — never a fake redirect.

## The SAML seam (not built — the boundary a future task fills)

SAML is a fundamentally different protocol from OIDC (XML assertions +
signature validation + an IdP-metadata exchange, vs. OIDC's OAuth2 code flow +
JWT), but it resolves to the **same identity model**. The seam is drawn so a SAML
module reuses everything below the protocol line and replaces only the protocol
layer.

### What a SAML module MUST reuse (the identity spine — unchanged)

1. **`Identity.UserIdentity`** — the link resource is protocol-agnostic. SAML adds
   `:saml` to the `provider` `one_of` (a one-line blueprint change + mirror
   migrations, the T06 precedent) and stores the SAML `NameID` as `provider_uid`.
   No new link table.
2. **`Samen.Identity.OidcLink`** — despite the name, its `link_or_provision/3` /
   `unlink/4` take already-validated **claims** (`%{provider:, provider_uid:,
   email:, first_name:, last_name:}`), not anything OIDC-specific. A SAML module
   maps its parsed assertion to that claims map and calls the SAME function:
   returning-SSO / link-to-existing (bidx) / JIT provision are identical. (When SAML
   lands, rename this to `Samen.Identity.SsoLink` — a pure rename; the logic is
   already protocol-neutral.)
3. **The blind-index match** (ADR-035 §4.1) — a SAML-asserted email matches an
   existing credential by `email_bidx` equality, exactly as OIDC does. No plaintext
   email at rest; the IdP email vaults at write on JIT provision.
4. **`Samen.Auth.SessionCreate`** + `Samen.Web.Auth.put_session_token/2` — the
   session mint + cookie write are protocol-agnostic; a SAML callback controller
   ends the same way the OIDC one does.
5. **The A10 audit taxonomy** — `auth.sso_linked` / `auth.sso_unlinked` already
   cover SAML (provider + uid only, token-blind).

### What a SAML module MUST build (the protocol layer only)

1. **`Samen.Web.Auth.Saml`** — the protocol module beside `Samen.Web.Auth.Oidc`.
   Same shape: `configured?/2`, an authorize/redirect builder (SP-initiated
   `AuthnRequest`), and a `handle_callback/…` that validates the assertion
   **signature** + conditions + `Recipient`/`Audience` + `NotOnOrAfter` (SAML's
   replay/CSRF defenses, the analog of OIDC's state/nonce) and returns the claims
   map. Same fail-honest contract: unconfigured → `{:error, :not_configured}`.
   Library candidate: a SAML protocol lib in `samen_web/mix.exs` (INV-4 — never
   `samen_core`), the assent-placement precedent.
2. **`Samen.Web.Auth.SamlController`** — the SP endpoints:
   `GET /auth/saml/:provider` (SP-initiated redirect) and `POST
   /auth/saml/:provider/acs` (the Assertion Consumer Service — SAML POSTs the
   assertion, so this is a POST, unlike OIDC's GET callback). Reuse
   `OidcController`'s link/provision/session tail verbatim.
3. **A router opt** — `saml: [:okta, ...]` on `samen_auth_routes/1`, mounted only
   when present (the OIDC `oidc:` / `__oidc_routes__/2` module-absent precedent —
   add a sibling `__saml_routes__/2`).
4. **IdP metadata config** — a SAML provider config carries the IdP's SSO URL,
   the signing certificate, and the SP entity id, in place of OIDC's
   `client_id`/`client_secret`.

### The one-line trust-boundary note

SAML assertion **signature validation is the entire security boundary** (there is
no client secret and no back-channel token exchange — the browser POSTs the signed
assertion). A SAML module that skips or weakens signature/condition validation is
the SAML analog of skipping OIDC's state check; it owes the same red test +
positive-control pair (a tampered/unsigned assertion refused; a valid one
accepted) the OIDC module ships for state (`oidc_test.exs`).

## Why documented-only this run (ADR-035 §9)

SAML remains a documented seam, not an implementation (c1). The spine already owns
its protocol-agnostic identity model, so SAML is additive and low-risk when a
customer actually requires it — a new protocol module beside OIDC, reusing the link
resource, the link/provision transaction, the bidx match, the session mint, and the
audit taxonomy unchanged.
