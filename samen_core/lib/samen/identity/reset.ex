defmodule Samen.Identity.Reset do
  @moduledoc """
  A3 — Password reset (ADR-035 §5 A3). `request/2`: bidx lookup, mints a
  `:password_reset` token (1h, §4.2), dispatches through
  `Samen.Delivery.AuthMailer` (honoring its current `:blocked` fail-honest
  state); uniform `{:ok, :sent}` whether or not the account exists (no
  account-existence oracle — response WORDING is identical either way, §4.4's
  A3 requirement). The not-found branch does NO hashing: unlike sign-in,
  reset-request's real (found) path never calls `Samen.Auth.Hasher` either
  (it mints a token and dispatches — no password comparison), so a dummy hash
  on the not-found branch would not mirror the found branch's cost, it would
  INVERT it (an unknown email would pay ~100-300ms MORE than a real one).
  Parity here means neither branch hashes — the same shape as
  `Samen.Identity.Confirm.resend/2`; enumeration on this surface is
  controlled by response-wording parity plus the §4.5 rate limit, not timing.
  `consume/3`: `GET/PUT
  /reset/:token` — validates the new password BEFORE touching the token (a
  doomed request never burns the single-use token), atomically
  single-use/expiring consumes it, rehashes the credential, and revokes EVERY
  session belonging to the credential (`Samen.Auth.SessionRevoke` — c3: reset
  revokes ALL sessions, including the one that requested it; the user
  re-authenticates). Audits BOTH the request and the completion
  (`auth.password_reset_requested` / `auth.password_reset`) AND (T09,
  ADR-035 §5 A10) dispatches the `auth.password_reset` security-notice
  notification through `Samen.Scopes.Identity.Notify` on completion — the
  notify HALF of A10, additive and best-effort (a notify failure never
  unwinds the rehash/revoke-all it rides alongside).

  ## `mods[:user]` — OPTIONAL (A10 notify seam)

  Same discipline as `Samen.Identity.Confirm`'s `mods[:user]`: not required
  by `consume/3`'s core contract, a pure ADD when present, a quiet no-op skip
  when absent — no caller that omits it changes behavior.
  """

  alias Samen.Auth.BlindIndex
  alias Samen.Auth.Hasher
  alias Samen.Auth.PasswordPolicy
  alias Samen.Auth.SessionRevoke
  alias Samen.Auth.TokenConsume
  alias Samen.Auth.TokenMint
  alias Samen.Delivery.AuthMailer
  alias Samen.Scopes.Identity.Audit
  alias Samen.Scopes.Identity.Notify

  require Ash.Query

  @password_reset_ttl_seconds 60 * 60

  @type mods :: %{
          required(:credential) => module(),
          required(:auth_token) => module(),
          required(:session) => module(),
          required(:repo) => module(),
          optional(:user) => module()
        }

  @doc """
  Request a password reset for `email`. Uniform `{:ok, :sent}` whether or not
  the account exists — response WORDING never distinguishes "no such
  account" from "reset email sent." The not-found branch does no hashing:
  the found (real-account) path never hashes either (it mints a token and
  dispatches — no password comparison), so parity here means BOTH branches
  stay cheap, the same shape as `Samen.Identity.Confirm.resend/2`.
  Enumeration is controlled by response-wording parity plus the §4.5
  token-request rate limit, not by artificial timing cost. Audits
  `auth.password_reset_requested` for a real account. `{:error, reason}`
  only when the account is real and Delivery is honestly blocked/failed.
  """
  @spec request(String.t(), mods) :: {:ok, :sent} | {:error, term()}
  def request(email, %{} = mods) when is_binary(email) do
    with {:ok, bidx} <- BlindIndex.compute(email) do
      case find_credential(mods, bidx) do
        [credential] ->
          mint_and_dispatch(mods, credential, bidx)

        [] ->
          {:ok, :sent}
      end
    end
  end

  @doc """
  Consume a raw `:password_reset` token with `new_password`.

  `{:error, :weak_password}` — rejected by `Samen.Auth.PasswordPolicy` BEFORE
  the token is touched (the single-use token survives a merely-weak retry).
  `{:error, :invalid_token}` — absent, expired, wrong-context, or
  already-consumed; one generic outcome, no distinguishing signal.
  """
  @spec consume(String.t(), String.t(), mods) ::
          {:ok, term()} | {:error, :weak_password | :invalid_token | term()}
  def consume(raw_token, new_password, %{} = mods) when is_binary(raw_token) do
    with :ok <- PasswordPolicy.validate(new_password) do
      digest = TokenMint.digest(raw_token)

      case TokenConsume.consume_once(mods.auth_token, digest, :password_reset) do
        {:ok, auth_token} -> rehash_and_revoke(mods, auth_token, new_password)
        :error -> {:error, :invalid_token}
      end
    end
  end

  # -- private -----------------------------------------------------------------

  defp find_credential(mods, bidx) do
    mods.credential
    |> Ash.Query.filter(email_bidx == ^bidx)
    |> Ash.Query.ensure_selected([:id])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
  end

  defp mint_and_dispatch(mods, credential, bidx) do
    with {:ok, _auth_token, raw_token} <-
           TokenMint.mint(mods.auth_token, credential.id, :password_reset, bidx, @password_reset_ttl_seconds) do
      Audit.auth_event(mods.repo,
        event: "password_reset_requested",
        subject_id: credential.id,
        actor_id: credential.id
      )

      # The raw token is threaded into `AuthMailer.dispatch/2`, which renders it
      # into the email body's `/reset/:token` link (F1/T111) — never logged nor
      # returned (the public contract is the uniform `{:ok, :sent}`; the token
      # lives only on this stack and in the transient delivery content).
      case AuthMailer.dispatch(:password_reset, credential_id: credential.id, raw_token: raw_token) do
        {:ok, _receipt} -> {:ok, :sent}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp rehash_and_revoke(mods, auth_token, new_password) do
    with [credential] <-
           mods.credential
           |> Ash.Query.filter(id == ^auth_token.credential_id)
           |> Ash.Query.ensure_selected([:id])
           |> Ash.read!(authorize?: false) do
      {hash, scheme} = Hasher.hash(new_password)

      credential
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:password_hash, hash)
      |> Ash.Changeset.force_change_attribute(:hash_scheme, scheme)
      |> Ash.update()
      |> case do
        {:ok, updated} ->
          # c3 — revoke EVERY session, including the one that requested the
          # reset (the user re-authenticates).
          :ok = SessionRevoke.revoke_all(mods.session, credential.id)

          Audit.auth_event(mods.repo,
            event: "password_reset",
            subject_id: credential.id,
            actor_id: credential.id
          )

          notify_reset(mods, credential.id)

          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    else
      [] -> {:error, :invalid_token}
    end
  end

  # ADR-035 §5 A10 (T09) — the notify HALF, additive alongside the audit
  # write above. `mods[:user]` is OPTIONAL (see moduledoc): absent means "no
  # notify seam wired for this caller," a quiet no-op, never an error.
  defp notify_reset(%{user: user_mod}, credential_id) when not is_nil(user_mod) do
    Notify.notify_credential(
      user_mod,
      credential_id,
      "password_reset",
      "Your password was changed and every other session was signed out. If this wasn't you, contact support immediately."
    )
  end

  defp notify_reset(_mods, _credential_id), do: :ok
end
