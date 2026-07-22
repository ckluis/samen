defmodule Samen.Identity.Confirm do
  @moduledoc """
  A2 — Email verification (ADR-035 §5 A2). The tokenized confirm loop on the
  §4.2 scheme: `resend/2` mints a fresh `:email_verify` `AuthToken` for an
  unverified credential and dispatches it through `Samen.Delivery.AuthMailer`
  (honoring its current `:blocked` fail-honest state — `Samen.Identity.Register`
  mints the SIGNUP-time token inline inside A1's own transaction but does not
  dispatch it; this covers the independent resend path). `consume/2` is `GET
  /verify/:token`'s atomic single-use, expiring consume: sets
  `Credential.verified_at`, audits `auth.email_verified` AND (T09, ADR-035 §5
  A10) dispatches the `auth.email_verified` welcome notification through
  `Samen.Scopes.Identity.Notify` — the notify HALF of A10, additive and
  best-effort (see `Notify`'s moduledoc: a notify failure never unwinds the
  verify).

  ## `mods[:user]` — OPTIONAL (A10 notify seam)

  `mods.user` is not required by `consume/2`'s core contract (every caller
  that omits it keeps working exactly as before T09 — the notify half is a
  pure ADD, never a behavior change on the verify itself). When present, it
  resolves the credential's notification recipient
  (`Notify.notify_credential/6`); when absent, the notify half is silently
  skipped (no crash, no half-verified state either way — `verified_at` is
  set unconditionally regardless of whether a `User` mod was supplied).
  """

  alias Samen.Auth.BlindIndex
  alias Samen.Auth.TokenConsume
  alias Samen.Auth.TokenMint
  alias Samen.Delivery.AuthMailer
  alias Samen.Scopes.Identity.Audit
  alias Samen.Scopes.Identity.Notify

  require Ash.Query

  @email_verify_ttl_seconds 7 * 24 * 60 * 60

  @type mods :: %{
          required(:credential) => module(),
          required(:auth_token) => module(),
          required(:repo) => module(),
          optional(:user) => module()
        }

  @doc """
  Mint + dispatch a fresh `:email_verify` token for `email`. Uniform response
  regardless of whether the account exists or is already verified (no
  account-existence oracle, mirroring A1's duplicate-email discipline):
  `{:ok, :sent}` in both of those cases too. Returns `{:error, reason}` ONLY
  when a token WAS minted for a real unverified account but the Delivery
  chokepoint itself is honestly blocked/failed — surfaced so a caller can
  show an operator-facing signal rather than a silently false `:sent`.
  """
  @spec resend(String.t(), mods) :: {:ok, :sent} | {:error, term()}
  def resend(email, %{} = mods) when is_binary(email) do
    with {:ok, bidx} <- BlindIndex.compute(email) do
      case find_unverified_credential(mods, bidx) do
        [credential] -> mint_and_dispatch(mods, credential, bidx)
        [] -> {:ok, :sent}
      end
    end
  end

  @doc """
  Consume a raw `:email_verify` token (`GET /verify/:token`): atomic
  single-use/expiring consume (`Samen.Auth.TokenConsume`), then sets
  `Credential.verified_at` and audits `auth.email_verified`. `{:error,
  :invalid_token}` for an absent, expired, wrong-context, or already-consumed
  token — one generic outcome, no distinguishing signal (mirrors the token
  scheme's anti-replay-oracle posture).
  """
  @spec consume(String.t(), mods) :: {:ok, term()} | {:error, :invalid_token}
  def consume(raw_token, %{} = mods) when is_binary(raw_token) do
    digest = TokenMint.digest(raw_token)

    case TokenConsume.consume_once(mods.auth_token, digest, :email_verify) do
      {:ok, auth_token} -> mark_verified(mods, auth_token)
      :error -> {:error, :invalid_token}
    end
  end

  # -- private -----------------------------------------------------------------

  defp find_unverified_credential(mods, bidx) do
    mods.credential
    |> Ash.Query.filter(email_bidx == ^bidx and is_nil(verified_at))
    |> Ash.Query.ensure_selected([:id, :verified_at])
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
  end

  defp mint_and_dispatch(mods, credential, bidx) do
    with {:ok, _auth_token, _raw_token} <-
           TokenMint.mint(mods.auth_token, credential.id, :email_verify, bidx, @email_verify_ttl_seconds) do
      # The raw token lives only in the email body (never logged, never
      # returned from this function — `resend/2`'s public contract is the
      # uniform `{:ok, :sent}`).
      case AuthMailer.dispatch(:email_verify, credential_id: credential.id) do
        {:ok, _receipt} -> {:ok, :sent}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp mark_verified(mods, auth_token) do
    with [credential] <-
           mods.credential
           |> Ash.Query.filter(id == ^auth_token.credential_id)
           |> Ash.Query.ensure_selected([:id, :verified_at])
           |> Ash.read!(authorize?: false) do
      now = DateTime.utc_now()

      credential
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:verified_at, now)
      |> Ash.update()
      |> case do
        {:ok, updated} ->
          Audit.auth_event(mods.repo,
            event: "email_verified",
            subject_id: credential.id,
            actor_id: credential.id
          )

          notify_verified(mods, credential.id)

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
  defp notify_verified(%{user: user_mod}, credential_id) when not is_nil(user_mod) do
    Notify.notify_credential(
      user_mod,
      credential_id,
      "email_verified",
      "Your email address has been verified."
    )
  end

  defp notify_verified(_mods, _credential_id), do: :ok
end
