defmodule Samen.Auth.SessionRevoke do
  @moduledoc """
  ADR-035 §4.3 — the revoke half of the session discipline, three shapes:

    * `revoke_all/2` — EVERY live session for a credential. Password reset
      (A3) and any 2FA change (A7) both trigger this ("Password reset (A3)
      and any 2FA change (A7) revoke all other sessions" — spec-questions
      c3); A3's reset revokes even the session that requested it (the c3
      ruling: the user re-authenticates — no "except current" carve-out at
      reset time).
    * `revoke_one/3` (A4/T04) — a single, individually-chosen session
      (Settings/Security's per-row "revoke" control). Scoped by
      `credential_id` ownership as a defense-in-depth check: a caller cannot
      revoke a session belonging to a DIFFERENT credential by guessing/
      supplying an id, even if the web layer's own authz already scoped the
      request to "my sessions."
    * `revoke_others/3` (A4/T04) — every live session EXCEPT one (the
      "revoke all other sessions" Settings/Security control, and the c3
      concurrent-session policy's ordinary revoke-all-others shape, distinct
      from A3's revoke-ALL-including-current).

  Revocation is row-level and immediate: the next `Samen.Auth.SessionResolve.resolve/2`
  against a revoked row fails — no stateless-JWT non-revocability window.
  """

  require Ash.Query

  @doc """
  Revoke every live (`revoked_at IS NULL`) `Identity.Session` row belonging
  to `credential_id`. Idempotent — a credential with zero live sessions is a
  no-op, not an error.
  """
  @spec revoke_all(module(), String.t()) :: :ok
  def revoke_all(session_mod, credential_id) when is_binary(credential_id) do
    now = DateTime.utc_now()

    session_mod
    |> Ash.Query.filter(credential_id == ^credential_id and is_nil(revoked_at))
    |> Ash.bulk_update!(:revoke, %{revoked_at: now}, authorize?: false, return_errors?: true)

    :ok
  end

  @doc """
  Revoke exactly ONE session (`session_id`), scoped to `credential_id` — a
  session belonging to a different credential is refused (`{:error,
  :not_found}`), never silently a no-op success. `{:ok, :revoked}` on
  success (idempotent: revoking an already-revoked session of yours is still
  a success, not an error).
  """
  @spec revoke_one(module(), String.t(), String.t()) :: {:ok, :revoked} | {:error, :not_found}
  def revoke_one(session_mod, session_id, credential_id)
      when is_binary(session_id) and is_binary(credential_id) do
    now = DateTime.utc_now()

    session_mod
    |> Ash.Query.filter(id == ^session_id and credential_id == ^credential_id and is_nil(revoked_at))
    |> Ash.bulk_update(:revoke, %{revoked_at: now},
      authorize?: false,
      return_records?: false,
      return_errors?: true
    )
    |> case do
      {:ok, %Ash.BulkResult{status: :success, error_count: 0}} ->
        {:ok, :revoked}

      _ ->
        # Zero rows matched (wrong credential, unknown id, or already revoked-and-
        # gone) vs. an already-revoked row OF YOURS both need distinguishing before
        # reporting :not_found — an idempotent re-revoke of your own row is a
        # success, not an error.
        already_mine? =
          session_mod
          |> Ash.Query.filter(id == ^session_id and credential_id == ^credential_id)
          |> Ash.Query.select([:id])
          |> Ash.read!(authorize?: false)
          |> Enum.any?()

        if already_mine?, do: {:ok, :revoked}, else: {:error, :not_found}
    end
  end

  @doc """
  Revoke every live session belonging to `credential_id` EXCEPT
  `except_session_id` (the "revoke all other sessions" control). Idempotent;
  `:ok` regardless of how many rows matched.
  """
  @spec revoke_others(module(), String.t(), String.t()) :: :ok
  def revoke_others(session_mod, credential_id, except_session_id)
      when is_binary(credential_id) and is_binary(except_session_id) do
    now = DateTime.utc_now()

    session_mod
    |> Ash.Query.filter(
      credential_id == ^credential_id and is_nil(revoked_at) and id != ^except_session_id
    )
    |> Ash.bulk_update!(:revoke, %{revoked_at: now}, authorize?: false, return_errors?: true)

    :ok
  end
end
