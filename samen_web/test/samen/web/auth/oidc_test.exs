defmodule Samen.Web.Auth.OidcTest do
  @moduledoc """
  T06 — A6 optional OIDC module (ADR-035 §5 A6), against the samen_web test
  host's Operator Identity mount, with a STUBBED IdP (no live Google, no HTTP —
  deterministic token/claims fixtures via `OidcStubStrategy`). Proves:

    1. Fresh-signup-via-OIDC (JIT provision): an unknown IdP email + `signup:
       true` provisions Org + Credential (passwordless — `password_hash: nil` —
       and `verified_at` SET because the IdP verified the email) + User (email
       **vaulted at write**) + owner Membership + the UserIdentity link.
    2. Link-to-existing: an IdP email whose blind index matches an existing
       Credential LINKS to THAT credential (no new credential); returning SSO
       resolves the SAME credential with no duplicate link.
    3. Link-only refusal: an unknown IdP email with `signup: false` is
       `{:error, :no_account}` — no account created.
    4. State/nonce validation: a TAMPERED callback state is refused (red);
       the matching state proceeds (positive control).
    5. Module absent/unconfigured: no `oidc:` → NO oidc routes
       (`Samen.Web.Router.__oidc_routes__/1`); an unconfigured provider
       fail-honests `{:error, :not_configured}` (ADR-014 shape).
    6. Unlink-lockout guard (§8): unlinking a passwordless credential's ONLY
       sign-in method is refused (red); a credential with another method
       unlinks (positive control).
    7. INV-1: the IdP email is vaulted on the User (a `vt_*` token at rest,
       clear on the tenant plane, masked on the operator plane) and NEVER
       persisted on the UserIdentity row.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Auth.BlindIndex
  alias Samen.Identity.OidcLink
  alias Samen.Identity.Register
  alias Samen.Web.Auth.Oidc
  alias Samen.Web.Router
  alias Samen.WebTest.Operator.Credential
  alias Samen.WebTest.Operator.Membership
  alias Samen.WebTest.Operator.User
  alias Samen.WebTest.Operator.UserIdentity

  # A deterministic stub IdP strategy (assent's `authorize_url/1` + `callback/2`
  # shape). Reads the claims + state it should assert from `strategy_opts`
  # (threaded through `Samen.Web.Auth.Oidc`'s config), so a test controls exactly
  # what "Google" returns — no HTTP, no live IdP (the done-criterion 1 contract).
  defmodule OidcStubStrategy do
    def authorize_url(config) do
      state = config[:test_state] || "stub-state"
      {:ok, %{url: "https://accounts.google.test/o/oauth2/auth?state=#{state}", session_params: %{state: state, nonce: "stub-nonce"}}}
    end

    def callback(config, _params) do
      {:ok, %{user: config[:test_claims] || %{}}}
    end
  end

  setup do
    prev = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:samen_core, :delivery_env, prev),
        else: Application.delete_env(:samen_core, :delivery_env)
    end)

    :ok
  end

  # -- helpers -----------------------------------------------------------------

  defp link_mods,
    do: %{
      org: Samen.WebTest.Operator.Org,
      credential: Credential,
      user: User,
      membership: Membership,
      user_identity: UserIdentity,
      repo: Repo
    }

  defp register_mods,
    do: %{
      org: Samen.WebTest.Operator.Org,
      credential: Credential,
      user: User,
      membership: Membership,
      auth_token: Samen.WebTest.Operator.AuthToken,
      repo: Repo
    }

  defp unique_email, do: "oidc-#{System.unique_integer([:positive])}@example.test"

  defp claims(email, uid, opts \\ []) do
    %{
      provider: "google",
      provider_uid: uid,
      email: email,
      first_name: Keyword.get(opts, :first_name, "Ada"),
      last_name: Keyword.get(opts, :last_name, "Lovelace"),
      email_verified: Keyword.get(opts, :email_verified, true)
    }
  end

  # A stub-backed provider config (the compile-time literal a host would pass as
  # `oidc_config:`, or the app-env `providers` map).
  defp stub_config(claims, opts \\ []) do
    state = Keyword.get(opts, :state, "state-#{System.unique_integer([:positive])}")

    %{
      providers: %{
        google: [
          strategy: OidcStubStrategy,
          client_id: "test-client",
          client_secret: "test-secret",
          redirect_uri: "https://app.test/auth/oidc/google/callback",
          strategy_opts: [test_claims: stringify_claims(claims), test_state: state]
        ]
      }
    }
  end

  defp stringify_claims(%{} = c) do
    %{
      "sub" => c.provider_uid,
      "email" => c.email,
      "given_name" => c[:first_name],
      "family_name" => c[:last_name],
      "email_verified" => c[:email_verified]
    }
  end

  defp user_identities(credential_id) do
    UserIdentity
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.read!(authorize?: false)
  end

  # ===========================================================================
  # 1. Fresh signup via OIDC (JIT provision)
  # ===========================================================================

  describe "fresh signup via OIDC (JIT provision)" do
    test "provisions a passwordless, verified credential + org + user + owner membership + link" do
      email = unique_email()
      c = claims(email, "google-sub-#{System.unique_integer([:positive])}")

      {:ok, result} = OidcLink.link_or_provision(c, link_mods(), signup: true)
      assert result.status == :provisioned

      cred = Ash.get!(Credential, result.credential_id, authorize?: false)
      # Passwordless (SSO-only) — password sign-in fails for it by design.
      assert is_nil(cred.password_hash)
      assert is_nil(cred.hash_scheme)
      # IdP-verified email → verified_at SET at provision.
      refute is_nil(cred.verified_at)
      # email_bidx is the blind index, NEVER the plaintext (INV-1).
      {:ok, bidx} = BlindIndex.compute(email)
      assert cred.email_bidx == bidx
      refute cred.email_bidx == email

      # One owner membership in the provisioned org.
      [membership] =
        Membership
        |> Ash.Query.filter(user_id == ^owner_user_id(result.credential_id))
        |> Ash.read!(authorize?: false)

      assert membership.role == :owner

      # Exactly one UserIdentity link.
      [ui] = user_identities(result.credential_id)
      assert ui.provider == :google
      assert ui.provider_uid == c.provider_uid
      refute is_nil(ui.linked_at)
    end

    test "INV-1: the IdP email is vaulted on the User (vt_* at rest, clear tenant / masked operator), never on the link" do
      email = unique_email()
      c = claims(email, "google-sub-#{System.unique_integer([:positive])}")

      {:ok, result} = OidcLink.link_or_provision(c, link_mods(), signup: true)

      [raw] =
        User
        |> Ash.Query.ensure_selected([:id, :handle, :status, :org_id, :credential_id, :emails])
        |> Ash.Query.filter(credential_id == ^result.credential_id)
        |> Ash.read!(authorize?: false)

      # At rest (direct column read): the emails column holds a `vt_*` vault
      # token, NEVER the plaintext IdP email — the vault-at-write proof.
      %{rows: [[stored]]} =
        Repo.query!("SELECT wou_emails FROM wou_user WHERE wou_id = $1", [
          Ecto.UUID.dump!(raw.id)
        ])

      assert to_string(stored) =~ "vt_"
      refute to_string(stored) =~ email

      # A plain Ash read masks by default (never plaintext, never a raw token).
      assert match?(%Samen.Masked{}, raw.emails)

      # Tenant plane resolves CLEAR (positive control).
      tenant = resolve_on_plane(raw, User, :tenant, repo: Repo)
      refute match?(%Samen.Masked{}, tenant.emails)
      assert inspect(tenant.emails) =~ email
      refute inspect(tenant.emails) =~ "vt_"

      # Operator-without-grant plane masks (red).
      operator = resolve_on_plane(raw, User, :operator, repo: Repo)
      assert match?(%Samen.Masked{}, operator.emails)
      refute inspect(operator.emails) =~ email

      # The IdP email is NEVER persisted on the UserIdentity link row.
      [ui] = user_identities(result.credential_id)
      refute inspect(Map.from_struct(ui)) =~ email
    end
  end

  # ===========================================================================
  # 2. Link-to-existing + returning SSO
  # ===========================================================================

  describe "link to an existing credential" do
    test "an IdP email matching an existing credential LINKS to it (no new credential)" do
      email = unique_email()
      {:ok, %{status: :registered, credential: existing}} = register!(email)

      c = claims(email, "google-sub-#{System.unique_integer([:positive])}")
      {:ok, result} = OidcLink.link_or_provision(c, link_mods(), signup: true)

      # LINKED to the SAME credential the password registration created — the
      # bidx equality match (ADR-035 §5 A6), not a second account.
      assert result.status == :linked
      assert result.credential_id == existing.id

      [ui] = user_identities(existing.id)
      assert ui.provider_uid == c.provider_uid
    end

    test "returning SSO resolves the SAME credential with no duplicate link" do
      email = unique_email()
      uid = "google-sub-#{System.unique_integer([:positive])}"
      c = claims(email, uid)

      {:ok, first} = OidcLink.link_or_provision(c, link_mods(), signup: true)
      assert first.status == :provisioned

      {:ok, second} = OidcLink.link_or_provision(c, link_mods(), signup: true)
      assert second.status == :signed_in
      assert second.credential_id == first.credential_id

      # Still exactly one link — no duplicate UserIdentity on the return trip.
      assert length(user_identities(first.credential_id)) == 1
    end

    test "link-only: an unknown IdP email with signup:false is refused (no account created)" do
      email = unique_email()
      c = claims(email, "google-sub-#{System.unique_integer([:positive])}")

      assert {:error, :no_account} = OidcLink.link_or_provision(c, link_mods(), signup: false)

      {:ok, bidx} = BlindIndex.compute(email)

      assert [] ==
               Credential
               |> Ash.Query.filter(email_bidx == ^bidx)
               |> Ash.read!(authorize?: false)
    end
  end

  # ===========================================================================
  # 3. State/nonce validation (via the web module against the stub)
  # ===========================================================================

  describe "state validation (CSRF/replay guard)" do
    test "RED: a tampered callback state is refused; CONTROL: the matching state proceeds" do
      email = unique_email()
      c = claims(email, "google-sub-#{System.unique_integer([:positive])}")
      config = stub_config(c, state: "the-real-state")

      {:ok, _url, session_params} = Oidc.authorize_url(:google, config)
      assert session_params.state == "the-real-state"

      # RED — a forged/mismatched state never reaches the token exchange.
      assert {:error, :invalid_state} =
               Oidc.handle_callback(
                 :google,
                 %{"state" => "attacker-state", "code" => "abc"},
                 session_params,
                 config
               )

      # POSITIVE CONTROL — the matching state proceeds and yields claims.
      assert {:ok, resolved} =
               Oidc.handle_callback(
                 :google,
                 %{"state" => "the-real-state", "code" => "abc"},
                 session_params,
                 config
               )

      assert resolved.email == email
      assert resolved.provider == :google
      assert resolved.provider_uid == c.provider_uid
    end

    test "RED: a missing callback state is refused" do
      c = claims(unique_email(), "google-sub-x")
      config = stub_config(c, state: "s-1")
      {:ok, _url, session_params} = Oidc.authorize_url(:google, config)

      assert {:error, :invalid_state} =
               Oidc.handle_callback(:google, %{"code" => "abc"}, session_params, config)
    end
  end

  # ===========================================================================
  # 4. Module absent / unconfigured (fail-honest, ADR-014)
  # ===========================================================================

  describe "module absent / unconfigured (fail-honest)" do
    test "no oidc: providers => NO oidc routes are emitted" do
      assert Router.__oidc_routes__([]) == []
      assert Router.__oidc_routes__(nil) == []

      routes = Router.__oidc_routes__([:google])
      assert length(routes) == 2
      # request + callback endpoints, both on the OidcController.
      assert Enum.all?(routes, fn {_path, mod, _action} -> mod == Samen.Web.Auth.OidcController end)
      assert Enum.any?(routes, fn {path, _m, a} -> a == :callback and path =~ "/callback" end)
      assert Enum.any?(routes, fn {_path, _m, a} -> a == :request end)
    end

    test "an unconfigured provider fail-honests {:error, :not_configured}, never a fake redirect" do
      # Empty config — the provider is absent.
      assert {:error, :not_configured} = Oidc.authorize_url(:google, %{})
      refute Oidc.configured?(:google, %{})

      # A provider present but missing its credentials is ALSO not_configured
      # (no client_id/secret, no test strategy) — never a half-wired {:ok, _}.
      partial = %{providers: %{google: [redirect_uri: "https://app.test/cb"]}}
      assert {:error, :not_configured} = Oidc.authorize_url(:google, partial)
      refute Oidc.configured?(:google, partial)
    end

    test "handle_callback on an unconfigured provider is {:error, :not_configured}" do
      assert {:error, :not_configured} =
               Oidc.handle_callback(:google, %{"state" => "x"}, %{state: "x"}, %{})
    end

    test "a configured provider IS configured? true (the positive control)" do
      c = claims(unique_email(), "google-sub-y")
      assert Oidc.configured?(:google, stub_config(c))
    end
  end

  # ===========================================================================
  # 5. Unlink-lockout guard (ADR-035 §5 A6 / §8)
  # ===========================================================================

  describe "unlink lockout guard" do
    test "RED: unlinking a passwordless credential's ONLY sign-in method is refused" do
      email = unique_email()
      c = claims(email, "google-sub-#{System.unique_integer([:positive])}")
      {:ok, %{status: :provisioned, credential_id: cid}} =
        OidcLink.link_or_provision(c, link_mods(), signup: true)

      # The provisioned credential is passwordless with exactly one link —
      # removing it would lock the human out.
      assert {:error, :would_lockout} =
               OidcLink.unlink(link_mods(), cid, "google", c.provider_uid)

      # The link still exists (nothing was removed).
      assert length(user_identities(cid)) == 1
    end

    test "CONTROL: a credential with a password unlinks its SSO identity freely" do
      email = unique_email()
      # A password credential (has a password_hash) …
      {:ok, %{status: :registered, credential: cred}} = register!(email)
      # … that also links an SSO identity.
      c = claims(email, "google-sub-#{System.unique_integer([:positive])}")
      {:ok, %{status: :linked}} = OidcLink.link_or_provision(c, link_mods(), signup: true)
      assert length(user_identities(cred.id)) == 1

      # Unlink succeeds — the password remains as a sign-in method (no lockout).
      assert :ok = OidcLink.unlink(link_mods(), cred.id, "google", c.provider_uid)
      assert user_identities(cred.id) == []
    end
  end

  # ===========================================================================
  # 6. email_verified enforcement (the account-takeover fix — F1/F2)
  # ===========================================================================

  describe "email_verified enforcement (F1/F2 — the account-takeover fix)" do
    test "F2: claim extraction preserves an explicit email_verified:false (never coerced to nil)" do
      # RED: an IdP that asserts email_verified:false — the falsey signal the
      # security check depends on — must survive normalization as `false`, not
      # be destroyed to `nil` by `false || atom_lookup`.
      c = claims(unique_email(), "google-sub-#{System.unique_integer([:positive])}", email_verified: false)
      config = stub_config(c, state: "s-f2-false")
      {:ok, _url, sp} = Oidc.authorize_url(:google, config)

      {:ok, resolved} =
        Oidc.handle_callback(:google, %{"state" => "s-f2-false", "code" => "x"}, sp, config)

      assert resolved.email_verified == false
      refute is_nil(resolved.email_verified)

      # POSITIVE CONTROL: a true claim normalizes to true.
      c2 = claims(unique_email(), "google-sub-#{System.unique_integer([:positive])}", email_verified: true)
      config2 = stub_config(c2, state: "s-f2-true")
      {:ok, _u2, sp2} = Oidc.authorize_url(:google, config2)
      {:ok, resolved2} = Oidc.handle_callback(:google, %{"state" => "s-f2-true", "code" => "x"}, sp2, config2)
      assert resolved2.email_verified == true
    end

    test "F1 RED: an email_verified:false claim matching a VICTIM credential is REFUSED — no link, no session" do
      victim_email = unique_email()
      {:ok, %{status: :registered, credential: victim}} = register!(victim_email)

      attacker_uid = "attacker-sub-#{System.unique_integer([:positive])}"
      attacker = claims(victim_email, attacker_uid, email_verified: false)

      # The exact takeover probe: an unverified IdP email asserting the victim's
      # address. It must NOT bind the attacker's sub to the victim's credential.
      assert {:error, :email_unverified} =
               OidcLink.link_or_provision(attacker, link_mods(), signup: true)

      # NOTHING bound to the victim: no link on the victim, no link for the
      # attacker sub — a subsequent SSO cannot resolve a session for the victim.
      assert user_identities(victim.id) == []

      assert [] ==
               UserIdentity
               |> Ash.Query.filter(provider_uid == ^attacker_uid)
               |> Ash.read!(authorize?: false)
    end

    test "F1 CONTROL: an email_verified:true claim matching the same credential DOES link to it" do
      email = unique_email()
      {:ok, %{status: :registered, credential: cred}} = register!(email)
      verified = claims(email, "google-sub-#{System.unique_integer([:positive])}", email_verified: true)

      assert {:ok, %{status: :linked, credential_id: cid}} =
               OidcLink.link_or_provision(verified, link_mods(), signup: true)

      assert cid == cred.id
      assert length(user_identities(cred.id)) == 1
    end

    test "F1: an ABSENT email_verified claim is treated UNVERIFIED (fail-closed) — link refused" do
      email = unique_email()
      {:ok, %{status: :registered, credential: victim}} = register!(email)

      # No :email_verified key at all → must be treated as unverified.
      c = %{
        provider: "google",
        provider_uid: "sub-absent-#{System.unique_integer([:positive])}",
        email: email
      }

      assert {:error, :email_unverified} = OidcLink.link_or_provision(c, link_mods(), signup: true)
      assert user_identities(victim.id) == []
    end

    test "F1 RED: an email_verified:false FRESH signup provisions an UNVERIFIED credential (verified_at nil)" do
      c = claims(unique_email(), "google-sub-#{System.unique_integer([:positive])}", email_verified: false)

      {:ok, %{status: :provisioned, credential_id: cid}} =
        OidcLink.link_or_provision(c, link_mods(), signup: true)

      cred = Ash.get!(Credential, cid, authorize?: false)
      # The unverified IdP email must NOT auto-verify the account — it follows the
      # normal capability-limited unverified path (Policy.Verified, T03).
      assert is_nil(cred.verified_at)
      # Still a passwordless SSO credential.
      assert is_nil(cred.password_hash)
    end

    test "F1 CONTROL: an email_verified:true FRESH signup provisions a VERIFIED credential" do
      c = claims(unique_email(), "google-sub-#{System.unique_integer([:positive])}", email_verified: true)

      {:ok, %{status: :provisioned, credential_id: cid}} =
        OidcLink.link_or_provision(c, link_mods(), signup: true)

      cred = Ash.get!(Credential, cid, authorize?: false)
      refute is_nil(cred.verified_at)
    end
  end

  # -- registration helper (password credential, for the link/control cases) ---

  defp register!(email) do
    Register.register(
      %{
        org_name: "OIDC Co #{System.unique_integer([:positive])}",
        first_name: "Grace",
        last_name: "Hopper",
        email: email,
        password: "correct horse battery staple"
      },
      register_mods()
    )
  end

  defp owner_user_id(credential_id) do
    [user] =
      User
      |> Ash.Query.filter(credential_id == ^credential_id)
      |> Ash.read!(authorize?: false)

    user.id
  end
end
