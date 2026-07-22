defmodule Samen.Identity.Register do
  @moduledoc """
  A1 — self-serve registration (ADR-035 §5 A1; spec §WS-A A1). The single
  code-interfaced transaction that creates, ATOMICALLY, in ONE repo
  transaction: `Org` (name from the form; `plan` default `"free"`),
  `Credential` (password hashed §4.4, `email_bidx` §4.1, `verified_at: nil`),
  `User` (PII vaulted at write via the existing `pii_attribute` path —
  `full_name`, `emails`; `credential_id` set), the owner `Membership`
  (`role: :owner`), and the `:email_verify` `AuthToken`. Any failure rolls the
  WHOLE set back — no orphan orgs, no credential-less users (the atomicity
  contract T02's `registration_test.exs` proves directly).

  ## Host-agnostic (ADR-004 blueprint contract)

  This module names no host resource module. Callers pass `mods` — the eight
  Identity resource modules a `use Samen.Scopes.Identity` mount materializes
  (only five are needed here: `:org`, `:credential`, `:user`, `:membership`,
  `:auth_token`) plus the host `:repo` — the same parameterization seam
  `Samen.Web.Mount` uses for LiveViews. A generated app's mount (Demo/Driftwood/
  a flagship gen-app) calls in with its own modules; this module never hardcodes
  one.

  ## Duplicate email — no account-existence oracle (ADR-035 §5 A1)

  A duplicate `email_bidx` short-circuits BEFORE the transaction (a plain
  pre-check read) and returns the SAME `{:ok, %{status: :ok}}` shape a real
  registration returns — never a distinguishable error, so a prober cannot use
  the signup form to enumerate registered emails.

  ## What this module does NOT do (T02 scope)

  Sending the verify email through the Delivery chokepoint (ADR-035 §5 A2) and
  the `GET /verify/:token` consume loop are A2's contract (owed by a later
  task). This module mints the `:email_verify` `AuthToken` row — the data half
  of A2 — inside the SAME atomic transaction (so the row exists the instant an
  account exists), and hands the caller the RAW token (never persisted) so a
  caller that already has A2 wired can dispatch it; it does not itself call
  Delivery.

  ## A10 fan-out — `auth.signup` (T09, ADR-035 §5 A10)

  The FINAL step inside the SAME atomic transaction audits `auth.signup`
  (`Samen.Scopes.Identity.Audit.auth_event/2` — the `email_verified`/
  `password_reset`/`invite_*` precedent) — a failed audit write rolls the
  WHOLE registration back exactly like a failed org/credential/user/
  membership/auth_token write does, so "an account exists but was never
  audited" can never happen (the SAME atomicity guarantee the moduledoc
  above already promises for every other row). The welcome notification
  (`Samen.Scopes.Identity.Notify`) dispatches AFTER the transaction commits
  (best-effort, never gates the signup — the ADR's own note that "the verify
  email IS the touch" means this notice is a courtesy in-app record, not the
  load-bearing communication).
  """

  alias Samen.Auth.BlindIndex
  alias Samen.Auth.Hasher
  alias Samen.Auth.PasswordPolicy
  alias Samen.Scopes.Identity.Audit
  alias Samen.Scopes.Identity.Notify

  @email_verify_ttl_seconds 7 * 24 * 60 * 60

  # Fixed dummy password for the duplicate-email timing-parity hash (§below).
  # Never compared against, never stored — its only purpose is to burn the
  # SAME ~100-300ms of PBKDF2 work a fresh registration pays, so response
  # latency cannot distinguish "email already registered" from "email free"
  # (ADR-035 §4.4 timing-parity discipline, addendum P2 — prime orchestrator,
  # post-T02 verification).
  @dummy_password "samen-dummy-timing-parity-password-never-compared"

  @type mods :: %{
          required(:org) => module(),
          required(:credential) => module(),
          required(:user) => module(),
          required(:membership) => module(),
          required(:auth_token) => module(),
          required(:repo) => module()
        }

  @type attrs :: %{
          required(:org_name) => String.t(),
          required(:email) => String.t(),
          required(:password) => String.t(),
          optional(:first_name) => String.t() | nil,
          optional(:last_name) => String.t() | nil
        }

  @doc """
  Run the A1 registration transaction.

  Returns:
    * `{:ok, %{status: :registered, org: org, user: user, membership: membership,
      credential: credential, auth_token: auth_token, raw_verify_token: token}}`
      on a fresh signup.
    * `{:ok, %{status: :duplicate}}` when the email is already registered — the
      SAME shape class (`{:ok, _}`) so a caller renders the identical generic
      "check your inbox" response either way (no account-existence oracle).
    * `{:error, :weak_password}` — the password failed `Samen.Auth.PasswordPolicy`.
      Checked BEFORE the blind index / transaction (no partial work for a
      request that can never succeed).
    * `{:error, reason}` — any other failure. The transaction rolls back the
      WHOLE set (org/credential/user/membership/auth_token) — zero orphan rows.

  `opts`:
    * `:inject_failure_after` — **TEST-ONLY** (one atom of `:org | :credential |
      :user | :membership`). Forces the transaction to fail immediately after
      that step's row is created, so a test can prove the ATOMICITY property —
      every earlier step's row is rolled back too — without racing a real DB
      constraint. `nil` (the default; every production caller, including
      `Samen.Web.Auth.RegistrationLive`, never sets it) runs the real path
      unmodified.
  """
  @spec register(attrs, mods, keyword()) :: {:ok, map()} | {:error, term()}
  def register(%{} = attrs, %{} = mods, opts \\ []) do
    with :ok <- PasswordPolicy.validate(Map.get(attrs, :password)),
         {:ok, bidx} <- BlindIndex.compute(Map.fetch!(attrs, :email)) do
      case duplicate?(mods, bidx) do
        true ->
          # ADR-035 §4.4 timing-parity discipline (addendum P2): a fresh
          # registration pays one PBKDF2-hash's worth of latency
          # (`do_register/4` -> `Hasher.hash/1`) before it can respond. Without
          # this line the duplicate branch above would return IMMEDIATELY,
          # so response latency alone would distinguish "already registered"
          # from "available" even though the wording is identical — closing
          # exactly that oracle is the point of burning the SAME hash here,
          # on a fixed dummy password, discarding the result.
          Hasher.hash(@dummy_password)
          {:ok, %{status: :duplicate}}

        false ->
          do_register(attrs, mods, bidx, Keyword.get(opts, :inject_failure_after))
      end
    end
  end

  defp duplicate?(mods, bidx) do
    require Ash.Query

    mods.credential
    |> Ash.Query.filter(email_bidx == ^bidx)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      [_ | _] -> true
    end
  end

  defp do_register(attrs, mods, bidx, inject_failure_after) do
    {hash, scheme} = Hasher.hash(Map.fetch!(attrs, :password))

    result =
      mods.repo.transaction(fn ->
        with {:ok, org} <- create_org(mods, attrs),
             :ok <- maybe_inject(inject_failure_after, :org),
             {:ok, credential} <- create_credential(mods, bidx, hash, scheme),
             :ok <- maybe_inject(inject_failure_after, :credential),
             {:ok, user} <- create_user(mods, org, credential, attrs),
             :ok <- maybe_inject(inject_failure_after, :user),
             {:ok, membership} <- create_owner_membership(mods, org, user),
             :ok <- maybe_inject(inject_failure_after, :membership),
             {:ok, auth_token, raw_token} <- mint_email_verify_token(mods, credential, bidx),
             # ADR-035 §5 A10 (T09) — `auth.signup`'s audit landing is the LAST
             # step INSIDE this same atomic transaction: a failed audit write
             # rolls the whole registration back via the SAME `{:error, reason}
             # -> mods.repo.rollback/1` branch every earlier step already uses
             # (no code path leaves an audited-less account behind).
             {:ok, _audit} <- audit_signup(mods, org, credential) do
          %{
            status: :registered,
            org: org,
            credential: credential,
            user: user,
            membership: membership,
            auth_token: auth_token,
            raw_verify_token: raw_token
          }
        else
          {:error, reason} -> mods.repo.rollback(reason)
        end
      end)

    case result do
      {:ok, registered} ->
        notify_signup(registered)
        {:ok, registered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ADR-035 §5 A10 (T09) — the audit HALF, atomic with the signup transaction
  # (see `do_register/4`'s `with` chain). Token-only: org id + credential id,
  # never subject PII (the `Samen.Scopes.Identity.Audit` contract).
  defp audit_signup(mods, org, credential) do
    Audit.auth_event(mods.repo,
      event: "auth.signup",
      subject_id: credential.id,
      actor_id: credential.id,
      # `correlation_id` (a bounded id field, NOT the free-text `detail`
      # string) carries the new org id — keeps `detail` a fixed, exact-
      # matchable "identity.auth.signup" string (the SAME discipline every
      # other A10 audit call in this module family already keeps).
      correlation_id: org.id
    )
  end

  # ADR-035 §5 A10 (T09) — the notify HALF. Best-effort, dispatched AFTER the
  # transaction above commits (never gates/unwinds the signup — the ADR marks
  # signup's notification column "--", since the verify email is the real
  # touch; this in-app record is a courtesy, not a requirement the write
  # depends on). org_id/recipient_id are already resolved from the just-
  # committed rows, so this needs no extra lookup (unlike
  # `Notify.notify_credential/4`'s credential -> User read).
  defp notify_signup(%{org: org, user: user}) do
    Notify.security_notice(
      org.id,
      user.id,
      "signup",
      "Welcome to Samen. Check your inbox to verify your email address."
    )
  end

  # See `register/3`'s `:inject_failure_after` doc — TEST-ONLY.
  defp maybe_inject(step, step), do: {:error, :injected_test_failure}
  defp maybe_inject(_other, _step), do: :ok

  defp create_org(mods, attrs) do
    mods.org
    |> Ash.Changeset.for_create(:create, %{name: Map.fetch!(attrs, :org_name)}, authorize?: false)
    |> Ash.create()
  end

  # `email_bidx`/`password_hash`/`hash_scheme`/`verified_at` are ALL private
  # (`public?: false` — credential-class columns, ADR-035 §3.1/§8, the ApiKey
  # `token_digest` precedent). Ash 3's default `create: :*` accepts only
  # PUBLIC writable attributes, so these are set via `force_change_attribute/3`
  # (the SAME idiom `Samen.Web.Settings.ApiKeys` uses for `token_digest`) —
  # never a public action input, only an internal, governed write.
  defp create_credential(mods, bidx, hash, scheme) do
    mods.credential
    |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:email_bidx, bidx)
    |> Ash.Changeset.force_change_attribute(:password_hash, hash)
    |> Ash.Changeset.force_change_attribute(:hash_scheme, scheme)
    |> Ash.Changeset.force_change_attribute(:verified_at, nil)
    |> Ash.create()
  end

  defp create_user(mods, org, credential, attrs) do
    mods.user
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org.id,
        handle: user_handle(attrs),
        full_name: %Samen.Type.FullName{
          first: Map.get(attrs, :first_name),
          last: Map.get(attrs, :last_name)
        },
        emails: [%{label: "primary", address: Map.fetch!(attrs, :email)}]
      },
      authorize?: false
    )
    # credential_id is private (ADR-035 §3.1 additive FK) — force_change, same
    # reason as the Credential fields above.
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

  # ADR-035 §4.2 mint discipline: 32 random bytes, URL-safe base64 (the RAW
  # token — appears only in the caller's return value, never persisted); at
  # rest ONLY the SHA-256 digest. Context :email_verify, 7-day expiry,
  # sent_to_bidx binds the token to the address it was minted for.
  defp mint_email_verify_token(mods, credential, bidx) do
    raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    digest = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
    expires_at = DateTime.utc_now() |> DateTime.add(@email_verify_ttl_seconds, :second)

    # Every AuthToken column is private (ADR-035 §4.2 — the ApiKey `token_digest`
    # precedent) — force_change, same as create_credential/2 above.
    result =
      mods.auth_token
      |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:credential_id, credential.id)
      |> Ash.Changeset.force_change_attribute(:token_digest, digest)
      |> Ash.Changeset.force_change_attribute(:context, :email_verify)
      |> Ash.Changeset.force_change_attribute(:sent_to_bidx, bidx)
      |> Ash.Changeset.force_change_attribute(:expires_at, expires_at)
      |> Ash.Changeset.force_change_attribute(:consumed_at, nil)
      |> Ash.create()

    case result do
      {:ok, auth_token} -> {:ok, auth_token, raw_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp user_handle(attrs) do
    [Map.get(attrs, :first_name), Map.get(attrs, :last_name)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      handle -> handle
    end
  end
end
