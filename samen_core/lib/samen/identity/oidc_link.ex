defmodule Samen.Identity.OidcLink do
  @moduledoc """
  A6 — the OIDC account-linking / JIT-provisioning transaction (ADR-035 §5 A6;
  spec §WS-A A6). The host-agnostic, pure-`ash` core half of the optional OIDC
  module: given the claims an IdP asserted (a `provider` + opaque `provider_uid`
  + the verified email), resolve them to a `Credential` — reusing an existing
  one, LINKING to one the email already owns, or PROVISIONING a fresh account —
  and hand the caller a `credential_id` to mint a session for.

  ## No new samen_core dep (INV-4)

  The assent protocol library + the HTTP/state/nonce dance live in
  `Samen.Web.Auth.Oidc` (samen_web); THIS module never imports assent. It takes
  already-validated claims as plain data and does only Ash writes — so
  `samen_core/mix.exs` stays untouched (ADR-035 §7).

  ## Linkage model (ADR-035 §5 A6)

    * **Returning SSO** — a `UserIdentity` row already binds `(provider,
      provider_uid)` to a Credential → resolve to it, no write. (`:signed_in`)
    * **Link-to-existing** — no such `UserIdentity`, but the IdP-asserted email's
      blind index (§4.1) matches an existing `Credential`, **AND the IdP marked
      that email verified** → create the `UserIdentity` link against THAT
      credential. The email is used ONLY for the bidx equality lookup; no
      plaintext IdP email is persisted. (`:linked`)
    * **JIT provision** — neither exists AND the provider opted into signup
      (`signup: true`) → ONE atomic transaction creates `Org` + `Credential`
      (`password_hash: nil` — passwordless/SSO-only; `verified_at` set ONLY when
      the IdP marked the email verified, else `nil`) + `User` (email **vaulted at
      write** via the `pii_attribute` path) + owner `Membership` + the
      `UserIdentity` link. Without `signup: true` → `{:error, :no_account}`
      (link-only). (`:provisioned`)

  ## Fail-closed email verification (ADR-035 §5 A6 — the takeover control)

  Binding an IdP `sub` to an EXISTING credential on email equality, or marking a
  provisioned credential verified, is trusted ONLY when the IdP's
  `email_verified` claim is truthy. An `email_verified: false`/absent claim
  asserting an address the caller does not control is the canonical
  unverified-email account-takeover: link-to-existing is REFUSED
  (`{:error, :email_unverified}` — nothing binds to the victim, no session), and
  a JIT provision lands an UNVERIFIED credential (`verified_at: nil`, the normal
  capability-limited path — `Samen.Policy.Verified`, T03). Returning-SSO is keyed
  on the stable `(provider, provider_uid)` sub (never the email), so it needs no
  re-check.

  ## Unlink lockout guard (ADR-035 §5 A6, §8 red test)

  `unlink/4` refuses to remove the LAST sign-in method: a passwordless credential
  (`password_hash: nil`) with exactly one `UserIdentity` cannot unlink it (that
  would lock the human out). A credential that still has a password, or another
  linked identity, unlinks freely.
  """

  require Ash.Query

  alias Samen.Auth.BlindIndex

  @type provider :: atom() | String.t()

  @type claims :: %{
          required(:provider) => provider(),
          required(:provider_uid) => String.t(),
          required(:email) => String.t(),
          optional(:first_name) => String.t() | nil,
          optional(:last_name) => String.t() | nil,
          optional(:email_verified) => boolean() | String.t() | nil
        }

  @type mods :: %{
          required(:org) => module(),
          required(:credential) => module(),
          required(:user) => module(),
          required(:membership) => module(),
          required(:user_identity) => module(),
          required(:repo) => module()
        }

  @doc """
  Resolve the IdP claims to a `Credential`. Returns:

    * `{:ok, %{status: :signed_in | :linked | :provisioned, credential_id: id}}`.
    * `{:error, :no_account}` — no `UserIdentity`, no email match, and the
      provider did not opt into signup (`signup: false`, the default).
    * `{:error, reason}` — a write/transaction failure (the provision
      transaction rolls back the whole set — no orphan org/credential).

  `opts`: `:signup` (boolean, default `false`) — whether an unknown IdP email
  JIT-provisions a fresh account or is refused (link-only).
  """
  @spec link_or_provision(claims(), mods(), keyword()) :: {:ok, map()} | {:error, term()}
  def link_or_provision(%{} = claims, %{} = mods, opts \\ []) do
    provider = normalize_provider(Map.fetch!(claims, :provider))
    provider_uid = Map.fetch!(claims, :provider_uid)
    verified? = email_verified?(claims)

    with {:ok, bidx} <- BlindIndex.compute(Map.fetch!(claims, :email)) do
      case find_user_identity(mods, provider, provider_uid) do
        [ui | _] ->
          # Returning SSO — keyed on the STABLE `(provider, provider_uid)` sub,
          # NOT the email. The link already exists (and, post-fix, is only ever
          # created off a VERIFIED email below), so an attacker cannot re-bind an
          # existing link. Email verification is not re-checked here.
          {:ok, %{status: :signed_in, credential_id: ui.credential_id}}

        [] ->
          case find_credential_by_bidx(mods, bidx) do
            [credential | _] ->
              # SECURITY (ADR-035 §5 A6): link-to-existing binds an IdP `sub` to a
              # PRE-EXISTING credential on email equality ALONE — so it is safe
              # ONLY when the IdP actually VERIFIED that email. An unverified /
              # absent `email_verified` claim is the canonical "Sign in with
              # Google" account-takeover vector (an attacker asserts a victim's
              # email it does not control). REFUSE the email-based link — bind
              # NOTHING to the victim credential, mint no session.
              if verified? do
                link_existing(mods, credential.id, provider, provider_uid)
              else
                {:error, :email_unverified}
              end

            [] ->
              if Keyword.get(opts, :signup, false) do
                provision(mods, claims, bidx, provider, provider_uid, verified?)
              else
                {:error, :no_account}
              end
          end
      end
    end
  end

  @doc """
  Unlink an IdP identity from a credential (A6 unlink). Refuses (`{:error,
  :would_lockout}`) when it is the credential's LAST sign-in method — a
  passwordless credential with no other linked identity. Otherwise deletes the
  `UserIdentity` row and returns `:ok`. An unknown link is `{:error, :not_found}`.
  """
  @spec unlink(mods(), String.t(), provider(), String.t()) ::
          :ok | {:error, :would_lockout | :not_found | term()}
  def unlink(%{} = mods, credential_id, provider, provider_uid)
      when is_binary(credential_id) do
    provider = normalize_provider(provider)

    case find_user_identity(mods, provider, provider_uid) do
      [%{credential_id: ^credential_id} = ui | _] ->
        if last_sign_in_method?(mods, credential_id, ui.id) do
          {:error, :would_lockout}
        else
          Ash.destroy(ui, authorize?: false)
        end

      _ ->
        {:error, :not_found}
    end
  end

  # -- lookups -----------------------------------------------------------------

  defp find_user_identity(mods, provider, provider_uid) do
    mods.user_identity
    |> Ash.Query.filter(provider == ^provider and provider_uid == ^provider_uid)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
  end

  defp find_credential_by_bidx(mods, bidx) do
    mods.credential
    |> Ash.Query.filter(email_bidx == ^bidx)
    |> Ash.Query.ensure_selected([:id, :password_hash])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
  end

  # Is `exclude_id` the ONLY thing keeping this credential reachable? True when
  # the credential is passwordless AND has no OTHER linked identity.
  defp last_sign_in_method?(mods, credential_id, exclude_id) do
    passwordless? =
      mods.credential
      |> Ash.Query.filter(id == ^credential_id)
      |> Ash.Query.ensure_selected([:password_hash])
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> case do
        [%{password_hash: nil} | _] -> true
        _ -> false
      end

    other_identity? =
      mods.user_identity
      |> Ash.Query.filter(credential_id == ^credential_id and id != ^exclude_id)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> case do
        [] -> false
        _ -> true
      end

    passwordless? and not other_identity?
  end

  # -- writes ------------------------------------------------------------------

  defp link_existing(mods, credential_id, provider, provider_uid) do
    case create_user_identity(mods, credential_id, provider, provider_uid) do
      {:ok, _ui} -> {:ok, %{status: :linked, credential_id: credential_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provision(mods, claims, bidx, provider, provider_uid, verified?) do
    result =
      mods.repo.transaction(fn ->
        with {:ok, org} <- create_org(mods, claims),
             {:ok, credential} <- create_sso_credential(mods, bidx, verified?),
             {:ok, user} <- create_user(mods, org, credential, claims),
             {:ok, _membership} <- create_owner_membership(mods, org, user),
             {:ok, _ui} <- create_user_identity(mods, credential.id, provider, provider_uid) do
          %{status: :provisioned, credential_id: credential.id}
        else
          {:error, reason} -> mods.repo.rollback(reason)
        end
      end)

    case result do
      {:ok, provisioned} -> {:ok, provisioned}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_org(mods, claims) do
    mods.org
    |> Ash.Changeset.for_create(:create, %{name: org_name(claims)}, authorize?: false)
    |> Ash.create()
  end

  # SSO-only credential: `password_hash: nil` (passwordless — password sign-in
  # simply fails for it, ADR-035 §5 A6/§4.4). `verified_at` is set ONLY when the
  # IdP actually VERIFIED the email (`verified?`); an unverified IdP email must
  # NOT auto-verify the account (SECURITY — else an attacker's `email_verified:
  # false` signup would land a pre-verified credential). An unverified SSO signup
  # follows the normal unverified path (capability-limited per `Samen.Policy.Verified`,
  # T03) until it confirms through the standard A2 email-verify loop.
  # `email_bidx`/`verified_at` are private credential-class columns →
  # `force_change_attribute` (the Register precedent).
  defp create_sso_credential(mods, bidx, verified?) do
    verified_at = if verified?, do: DateTime.utc_now(), else: nil

    mods.credential
    |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:email_bidx, bidx)
    |> Ash.Changeset.force_change_attribute(:password_hash, nil)
    |> Ash.Changeset.force_change_attribute(:hash_scheme, nil)
    |> Ash.Changeset.force_change_attribute(:verified_at, verified_at)
    |> Ash.create()
  end

  defp create_user(mods, org, credential, claims) do
    mods.user
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org.id,
        handle: user_handle(claims),
        full_name: %Samen.Type.FullName{
          first: Map.get(claims, :first_name),
          last: Map.get(claims, :last_name)
        },
        emails: [%{label: "primary", address: Map.fetch!(claims, :email)}]
      },
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:credential_id, credential.id)
    |> Ash.create()
  end

  defp create_owner_membership(mods, org, user) do
    mods.membership
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org.id, user_id: user.id, role: :owner},
      authorize?: false
    )
    |> Ash.create()
  end

  # Every UserIdentity column is private (credential-class, ADR-035 §3.1 — the
  # ApiKey `token_digest` precedent): set via `force_change_attribute`, never a
  # public create input.
  defp create_user_identity(mods, credential_id, provider, provider_uid) do
    mods.user_identity
    |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:credential_id, credential_id)
    |> Ash.Changeset.force_change_attribute(:provider, provider)
    |> Ash.Changeset.force_change_attribute(:provider_uid, provider_uid)
    |> Ash.Changeset.force_change_attribute(:linked_at, DateTime.utc_now())
    |> Ash.create()
  end

  # -- helpers -----------------------------------------------------------------

  # The `UserIdentity.provider` column is a bounded `:atom` (the Membership
  # `role` precedent) — store + filter with the atom, never a string.
  defp normalize_provider(p) when is_atom(p), do: p
  defp normalize_provider(p) when is_binary(p), do: String.to_existing_atom(p)

  # SECURITY (ADR-035 §5 A6): fail-CLOSED email-verification. ONLY a truthy
  # `email_verified` claim — the OIDC boolean `true`, or the string `"true"` some
  # providers emit — counts as verified. `false`, `"false"`, `nil`, and an absent
  # claim ALL mean UNVERIFIED. This is the single control that stops the
  # unverified-email account-takeover: an attacker's `email_verified: false`
  # asserting a victim's address can never link to, or auto-verify, an account.
  defp email_verified?(%{} = claims) do
    case Map.get(claims, :email_verified) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  # A JIT-provisioned SSO account gets a sane default org name (the human renames
  # it in onboarding, A8). Derived from the name claim, else a generic label —
  # never the email (no PII in the org name).
  defp org_name(claims) do
    case user_handle(claims) do
      nil -> "My workspace"
      handle -> "#{handle}'s workspace"
    end
  end

  defp user_handle(claims) do
    [Map.get(claims, :first_name), Map.get(claims, :last_name)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      handle -> handle
    end
  end
end
