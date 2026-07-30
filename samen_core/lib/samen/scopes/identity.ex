defmodule Samen.Scopes.Identity do
  @moduledoc """
  The **Identity** universal scope (T3.1; doc :311 scope table:
  `org · user🔒 · membership · role · api_key · invitation🔒 · audit`).

  Identity is the first scope and the reference the other six copy. It ships as a
  **library-authored blueprint** (ADR-004): `use`-ing this module inside a host's
  Ash domain expands into real `use Samen.Resource` resources **owned by the host**
  — host `otp_app`, host `repo`, host namespace — so the resources are catalogued in
  the HOST's catalog, scanned by the host's unchanged verifiers, and store PII in the
  host's one Postgres.

  ## Mounting Identity (the host side)

      defmodule Demo.Identity do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Identity,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.Identity
      end

  This defines, in the host's namespace:

    * `Demo.Identity.Org`        — the tenant anchor (org-less; no PII)
    * `Demo.Identity.User`       — a user 🔒 (name/email vault-routed)
    * `Demo.Identity.Membership` — (user, org, role) association; RBAC-gated
    * `Demo.Identity.Role`       — Tier-0 config rows: the role catalog per org
    * `Demo.Identity.ApiKey`     — scoped credential, two planes (tenant/operator)
    * `Demo.Identity.Invitation` — a pending invite 🔒 (email vault-routed)
    * `Demo.Identity.Credential` — ADR-035 §3.1: THE authentication principal
      (org-less; one human, N orgs); no PII, `email_bidx` is a keyed-HMAC index
    * `Demo.Identity.AuthToken`  — ADR-035 §4.2: single-use, expiring, hashed
      emailed secrets (email_verify / password_reset / email_change / totp_pending)
    * `Demo.Identity.Session`    — ADR-035 §3.1/§4.3: a revocable, DB-backed
      login session (org-less; belongs_to Credential); introduced at T03 for
      A3's "revoke all sessions on reset", extended by T04 (A4) with the full
      listing/remember-me/revocation surface
    * `Demo.Identity.UserIdentity` — ADR-035 §3.1/§5 A6: the SSO link (org-less;
      belongs_to Credential); binds an external IdP subject (`provider` +
      opaque `provider_uid`) to a Credential (the optional OIDC module, T06)
    * `Demo.Identity.LoginFailure` — ADR-038 §6.4: the durable brute-force
      failure counter (org-less; one row per `email_bidx`/`credential` key);
      makes T103's bounded `login_failed` signal survive a node restart (T109)

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name (per ADR-004):

    * `Demo.Identity.Org`        → `ido` (the CRM `org` is a distinct resource;
      abbrevs are permanent + one-owner, so Identity's org takes its own `ido`)
    * `Demo.Identity.User`       → `usr`
    * `Demo.Identity.Membership` → `mbs` (the CRM `mbr` is a distinct resource)
    * `Demo.Identity.Role`       → `iro` (Identity role; avoids the rollup table
      prefix `rol_*`)
    * `Demo.Identity.ApiKey`     → `key`
    * `Demo.Identity.Invitation` → `inv`
    * `Demo.Identity.Credential` → `crd` (ADR-035 §3.1)
    * `Demo.Identity.AuthToken`  → `atk` (ADR-035 §4.2)
    * `Demo.Identity.Session`    → `ses` (ADR-035 §3.1/§4.3)
    * `Demo.Identity.UserIdentity` → `uid` (ADR-035 §3.1/§5 A6)
    * `Demo.Identity.LoginFailure` → `dil` (ADR-038 §6.4; T109)

  The macro does NOT invent abbrevs — the host passes them so the host owns the
  registry entry. Defaults are provided for the demo mount.

  ## Audit rides T2.2 — never duplicated

  The scope table lists `audit` under Identity. This is the existing append-only
  `aud_event` tier (T2.2), NOT a new table. Identity actions that must be audited
  (role change, api_key mint/revoke, invitation accept) call
  `Samen.AuditEvent.insert/2`. See `Samen.Scopes.Identity.Audit`.

  ## Policies — inherited, not re-authored

  Every tenant-plane resource carries the org-scope policy (`Samen.Policy.OrgScope`)
  and, where relevant, RBAC (`Samen.Policy.RoleAtLeast` / `Samen.Policy.ManageRole`).
  These are authored ONCE here and inherited by the mount — the point of the
  scope-authoring guide.
  """

  @default_abbrevs %{
    org: "ido",
    user: "usr",
    membership: "mbs",
    role: "iro",
    api_key: "key",
    invitation: "inv",
    credential: "crd",
    auth_token: "atk",
    session: "ses",
    user_identity: "uid",
    # ADR-038 §6.4 (T109) — the durable brute-force failure counter.
    login_failure: "dil"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string (the base macro validates the
    # abbrev caller-side and requires a compile-time literal). A caller may override
    # via `abbrevs: %{org: "abc", ...}`; otherwise the defaults are used.
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    # T3.11 — opt-in public API surface. When `json_api: true`, the blueprint injects
    # the `AshJsonApi.Resource` extension + a `json_api do … end` ALLOWLIST block on
    # the API-exposed resources (Org, User, Membership). Default OFF, so samen_core
    # itself needs no ash_json_api dependency: the HOST that mounts `/api/v1` opts in
    # (and must have ash_json_api compiled). This keeps "field exposure is opt-in"
    # true at the SCOPE level too — an Identity mount publishes nothing to the public
    # contract unless the host explicitly asks.
    json_api? = Keyword.get(opts, :json_api, false) |> Macro.expand(__CALLER__)

    org_mod = Module.concat(namespace, Org)
    user_mod = Module.concat(namespace, User)
    membership_mod = Module.concat(namespace, Membership)
    role_mod = Module.concat(namespace, Role)
    api_key_mod = Module.concat(namespace, ApiKey)
    invitation_mod = Module.concat(namespace, Invitation)
    credential_mod = Module.concat(namespace, Credential)
    auth_token_mod = Module.concat(namespace, AuthToken)
    session_mod = Module.concat(namespace, Session)
    user_identity_mod = Module.concat(namespace, UserIdentity)
    login_failure_mod = Module.concat(namespace, LoginFailure)

    quote do
      require Samen.Scopes.Identity.Blueprint

      # Register the eleven Identity resources in the host domain (ADR-035 §3.1
      # adds Credential + AuthToken to the original six; T03 adds Session; T06
      # adds UserIdentity, the A6 SSO link; T109 adds LoginFailure, the ADR-038
      # §6.4 durable brute-force counter).
      resources do
        resource(unquote(org_mod))
        resource(unquote(user_mod))
        resource(unquote(membership_mod))
        resource(unquote(role_mod))
        resource(unquote(api_key_mod))
        resource(unquote(invitation_mod))
        resource(unquote(credential_mod))
        resource(unquote(auth_token_mod))
        resource(unquote(session_mod))
        resource(unquote(user_identity_mod))
        resource(unquote(login_failure_mod))
      end

      # Materialize the resource modules in the host namespace. Each is a normal
      # Samen resource; the blueprint threads the host's otp_app/repo/domain and the
      # resource's literal, registry-checked abbrev.
      Samen.Scopes.Identity.Blueprint.define_org(
        unquote(org_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.org),
        unquote(json_api?)
      )

      Samen.Scopes.Identity.Blueprint.define_user(
        unquote(user_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.user),
        unquote(json_api?)
      )

      Samen.Scopes.Identity.Blueprint.define_membership(
        unquote(membership_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.membership),
        unquote(user_mod),
        unquote(org_mod),
        unquote(json_api?)
      )

      Samen.Scopes.Identity.Blueprint.define_role(
        unquote(role_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.role)
      )

      Samen.Scopes.Identity.Blueprint.define_api_key(
        unquote(api_key_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.api_key),
        unquote(membership_mod)
      )

      Samen.Scopes.Identity.Blueprint.define_invitation(
        unquote(invitation_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.invitation)
      )

      Samen.Scopes.Identity.Blueprint.define_credential(
        unquote(credential_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.credential)
      )

      Samen.Scopes.Identity.Blueprint.define_auth_token(
        unquote(auth_token_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.auth_token),
        unquote(credential_mod)
      )

      Samen.Scopes.Identity.Blueprint.define_session(
        unquote(session_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.session),
        unquote(credential_mod)
      )

      Samen.Scopes.Identity.Blueprint.define_user_identity(
        unquote(user_identity_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.user_identity),
        unquote(credential_mod)
      )

      Samen.Scopes.Identity.Blueprint.define_login_failure(
        unquote(login_failure_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.login_failure)
      )
    end
  end

  # Resolve the abbrev override (an AST map literal or nil) to a plain
  # %{atom => string} map, merged over the defaults. Fail closed if a caller passes
  # a non-map or a non-string abbrev.
  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Identity, abbrevs: must be a compile-time map literal " <>
            "(%{org: \"abc\", ...}). Got: #{Macro.to_string(other)}"
  end
end
