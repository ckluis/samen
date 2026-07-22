defmodule Samen.Identity.Totp do
  @moduledoc """
  ADR-035 §5 A7 — the KERNEL half of 2FA/TOTP + vaulted recovery codes.
  `samen_core` never references `nimble_totp` (INV-4: the dep lives in
  `samen_web` only, `samen_core/mix.exs` stays untouched) — this module owns
  the atomic DB mutation (locking, single-use, anti-replay watermark, vault
  reveal) and takes the actual "is this code valid" decision as an INJECTED
  pure function (`validator_fun`), supplied by `Samen.Web.Auth.Totp` (which
  holds the nimble_totp comparison). Recovery-code consumption needs no
  external library at all — pure `:crypto` SHA-256 digests — so it is fully
  self-contained here.

  ## Enrollment — no half-enrolled state

  `enroll/4` is ONE atomic update setting `totp_secret` + `recovery_codes` +
  `totp_enabled_at` together. Nothing is persisted before this call succeeds
  (the caller — `Samen.Web.Auth.Totp.confirm_enrollment/4` — only calls in
  AFTER a fresh, not-yet-persisted secret has already verified a code), so
  there is no window where a secret exists on the row but 2FA isn't really
  live yet.

  ## Atomicity — the `invite.ex` `SELECT ... FOR UPDATE` precedent

  `verify_totp_code/3` and `consume_recovery_code/3` both lock the Credential
  row (`Ash.Query.lock(:for_update)`) inside an explicit `Repo.transaction/1`,
  mirroring `Samen.Identity.Invite`'s single-use-under-concurrency discipline:
  a concurrent second caller's own `SELECT ... FOR UPDATE` on the SAME row
  BLOCKS until this transaction commits, then re-evaluates against the
  now-updated row — so a replayed TOTP code or a double-spent recovery code
  is refused even under a true race, not just sequential replay.

  ## The vault reveal — self-plane resolution only

  Both atomic paths reveal `totp_secret`/`recovery_codes` via
  `Samen.Vault.reveal/3` bound to `subject_id: credential_id` — the
  "tenant-as-owner" rule (ADR-035 §5 A7): the ONLY subject ever asserted is
  the credential being verified, never a plane bypass, never a raw column
  read. Credential grants no actor-facing `reveal` action (see the blueprint's
  `policy always() do forbid_if(always()) end`) — this module IS the single
  legitimate reader.
  """

  require Ash.Query

  alias Samen.Vault

  @type mods :: %{required(:credential) => module(), required(:repo) => module()}

  @recovery_select [:id, :totp_secret, :recovery_codes, :totp_enabled_at, :totp_last_verified_at]

  @doc "SHA-256 hex digest of a raw recovery code — never the plaintext at rest."
  @spec code_digest(String.t()) :: String.t()
  def code_digest(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  @doc """
  Complete enrollment: ONE atomic update writes `totp_secret` (already
  base64-encoded by the caller — see the blueprint moduledoc),
  `recovery_codes` (hashed digests + nil `used_at`, built here from the
  plaintext codes the caller is about to show the user once), and
  `totp_enabled_at` together. `{:error, :not_found}` for an unknown
  `credential_id`.
  """
  @spec enroll(mods, String.t(), String.t(), [String.t()]) :: {:ok, term()} | {:error, term()}
  def enroll(%{} = mods, credential_id, encoded_secret, recovery_codes_plain)
      when is_binary(credential_id) and is_binary(encoded_secret) and is_list(recovery_codes_plain) do
    now = DateTime.utc_now()
    recovery_json = encode_codes(recovery_codes_plain)

    case fetch(mods, credential_id) do
      [credential] ->
        credential
        |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:totp_secret, encoded_secret)
        |> Ash.Changeset.force_change_attribute(:recovery_codes, recovery_json)
        |> Ash.Changeset.force_change_attribute(:totp_enabled_at, now)
        |> Ash.Changeset.force_change_attribute(:totp_last_verified_at, nil)
        |> Ash.update()

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Disable 2FA: clears secret/recovery codes/`totp_enabled_at`/the replay
  watermark together. Idempotent (disabling an already-disabled credential is
  a harmless no-op success).
  """
  @spec disable(mods, String.t()) :: {:ok, term()} | {:error, term()}
  def disable(%{} = mods, credential_id) when is_binary(credential_id) do
    case fetch(mods, credential_id) do
      [credential] ->
        credential
        |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:totp_secret, nil)
        |> Ash.Changeset.force_change_attribute(:recovery_codes, nil)
        |> Ash.Changeset.force_change_attribute(:totp_enabled_at, nil)
        |> Ash.Changeset.force_change_attribute(:totp_last_verified_at, nil)
        |> Ash.update()

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Regenerate the recovery-code set — a full overwrite, so the OLD set (every
  code in it, used or not) is invalidated the instant this commits. Refuses
  `{:error, :not_enrolled}` when 2FA isn't confirmed yet (there is nothing to
  regenerate).
  """
  @spec regenerate_recovery_codes(mods, String.t(), [String.t()]) ::
          {:ok, term()} | {:error, :not_enrolled | :not_found | term()}
  def regenerate_recovery_codes(%{} = mods, credential_id, recovery_codes_plain)
      when is_binary(credential_id) and is_list(recovery_codes_plain) do
    case fetch(mods, credential_id) do
      [%{totp_enabled_at: nil}] ->
        {:error, :not_enrolled}

      [credential] ->
        credential
        |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:recovery_codes, encode_codes(recovery_codes_plain))
        |> Ash.update()

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Atomically verify a TOTP code. `validator_fun.(encoded_secret, since)` is
  called with the REVEALED (still base64-encoded — the caller decodes)
  plaintext secret and the current `totp_last_verified_at` watermark, and must
  return a boolean. On `true`, `totp_last_verified_at` is set to `now()` in
  the SAME transaction the row was locked under, so a concurrent second call
  racing the identical code sees the updated watermark before it decides —
  the replay guard holds under concurrency, not just sequential replay.

  `{:error, :not_enrolled}` — 2FA was never confirmed (`totp_enabled_at` nil):
  the F2 red test this task's done-criteria name ("verify attempted before
  enrollment complete"). `{:error, :invalid_code}` — the validator rejected
  it (wrong code, expired drift window, or a replay the `since` watermark
  caught).
  """
  @spec verify_totp_code(mods, String.t(), (String.t(), DateTime.t() | nil -> boolean())) ::
          {:ok, term()} | {:error, :not_enrolled | :invalid_code | :not_found | term()}
  def verify_totp_code(%{} = mods, credential_id, validator_fun)
      when is_binary(credential_id) and is_function(validator_fun, 2) do
    mods.repo.transaction(fn ->
      case locked(mods, credential_id) do
        [%{totp_enabled_at: nil}] ->
          mods.repo.rollback(:not_enrolled)

        [%{totp_secret: masked, totp_last_verified_at: since} = credential] ->
          case Vault.reveal(masked, mods.repo, subject_id: credential_id) do
            {:ok, encoded_secret} ->
              if validator_fun.(encoded_secret, since) do
                touch_verified(mods, credential)
              else
                mods.repo.rollback(:invalid_code)
              end

            {:error, _reason} ->
              mods.repo.rollback(:invalid_code)
          end

        [] ->
          mods.repo.rollback(:not_found)
      end
    end)
    |> unwrap_transaction()
  end

  @doc """
  Atomically consume ONE recovery code (single-use). Locks the row, reveals +
  decodes the JSON code set, finds an entry whose digest matches `raw_code`
  AND is not yet used, marks it used, and re-vaults the WHOLE set — all
  inside the row lock, so a concurrent second consume attempt for the SAME
  code blocks until this commits, then sees it already marked used and is
  refused (`{:error, :invalid_code}`, the SAME generic outcome as a wrong
  code — no oracle on why).
  """
  @spec consume_recovery_code(mods, String.t(), String.t()) ::
          {:ok, term()} | {:error, :not_enrolled | :invalid_code | :not_found | term()}
  def consume_recovery_code(%{} = mods, credential_id, raw_code)
      when is_binary(credential_id) and is_binary(raw_code) do
    digest = code_digest(raw_code)

    mods.repo.transaction(fn ->
      case locked(mods, credential_id) do
        [%{totp_enabled_at: nil}] ->
          mods.repo.rollback(:not_enrolled)

        [%{recovery_codes: masked} = credential] ->
          with {:ok, json} <- Vault.reveal(masked, mods.repo, subject_id: credential_id),
               {:ok, codes} <- decode_codes(json),
               {:found, updated_codes} <- mark_used(codes, digest) do
            credential
            |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
            |> Ash.Changeset.force_change_attribute(:recovery_codes, Jason.encode!(updated_codes))
            |> Ash.update()
            |> case do
              {:ok, updated} -> updated
              {:error, reason} -> mods.repo.rollback(reason)
            end
          else
            _ -> mods.repo.rollback(:invalid_code)
          end

        [] ->
          mods.repo.rollback(:not_found)
      end
    end)
    |> unwrap_transaction()
  end

  # -- private -----------------------------------------------------------------

  defp touch_verified(mods, credential) do
    now = DateTime.utc_now()

    credential
    |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:totp_last_verified_at, now)
    |> Ash.update()
    |> case do
      {:ok, updated} -> updated
      {:error, reason} -> mods.repo.rollback(reason)
    end
  end

  defp unwrap_transaction({:ok, credential}), do: {:ok, credential}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp fetch(mods, credential_id) do
    mods.credential
    |> Ash.Query.filter(id == ^credential_id)
    |> Ash.Query.ensure_selected(@recovery_select)
    |> Ash.read!(authorize?: false)
  end

  defp locked(mods, credential_id) do
    mods.credential
    |> Ash.Query.filter(id == ^credential_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.Query.ensure_selected(@recovery_select)
    |> Ash.read!(authorize?: false)
  end

  defp encode_codes(plain_codes) do
    plain_codes
    |> Enum.map(&%{"digest" => code_digest(&1), "used_at" => nil})
    |> Jason.encode!()
  end

  defp decode_codes(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:error, :corrupt}
    end
  end

  defp mark_used(codes, digest) do
    index =
      Enum.find_index(codes, fn
        %{"digest" => d, "used_at" => nil} -> d == digest
        _ -> false
      end)

    case index do
      nil ->
        :not_found

      i ->
        now = DateTime.to_iso8601(DateTime.utc_now())
        {:found, List.update_at(codes, i, &Map.put(&1, "used_at", now))}
    end
  end
end
