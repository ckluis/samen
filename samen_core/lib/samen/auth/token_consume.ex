defmodule Samen.Auth.TokenConsume do
  @moduledoc """
  ADR-035 §4.2 — the ONE atomic single-use consume discipline shared by every
  emailed `AuthToken` context (A2 `:email_verify`, A3 `:password_reset`;
  `:email_change`/`:totp_pending` ride the SAME action when their owning
  requirements land). Consumption is exactly one atomic statement: `UPDATE ...
  SET consumed_at = now() WHERE token_digest = $1 AND context = $2 AND
  consumed_at IS NULL AND expires_at > $3 RETURNING` — realized as an
  `Ash.bulk_update!/4` over a query already narrowed to that WHERE shape,
  forced to `strategy: [:atomic]` (a single SQL statement; never a
  read-then-write race window), targeting the resource's `:consume` action
  (`accept []`, `change set_attribute(:consumed_at, arg(:consumed_at))` — see
  `Samen.Scopes.Identity.Blueprint.define_auth_token/6`).

  A replayed (already-consumed) or expired token, or a digest/context that
  matches no row, all resolve to the SAME `:error` — zero rows updated, one
  generic outcome, no oracle distinguishing WHY. Two callers racing the SAME
  digest: only the FIRST to commit sees its row match (`is_nil(consumed_at)`);
  the second's WHERE clause no longer matches once the first's UPDATE commits
  (the row lock serializes them) — the single-use property holds even under
  concurrency, not just sequential replay.
  """

  require Ash.Query

  @doc """
  Atomically consume the `AuthToken` whose `token_digest` is `digest` and
  whose `context` matches `context`. Returns `{:ok, auth_token}` (the
  post-consume row, `credential_id`/`sent_to_bidx` selected) on success,
  `:error` when zero rows matched.
  """
  @spec consume_once(module(), String.t(), atom()) :: {:ok, term()} | :error
  def consume_once(auth_token_mod, digest, context)
      when is_binary(digest) and is_atom(context) do
    now = DateTime.utc_now()

    result =
      auth_token_mod
      |> Ash.Query.filter(
        token_digest == ^digest and context == ^context and is_nil(consumed_at) and
          expires_at > ^now
      )
      |> Ash.Query.ensure_selected([:id, :credential_id, :context, :consumed_at, :sent_to_bidx])
      |> Ash.bulk_update!(:consume, %{consumed_at: now},
        authorize?: false,
        strategy: [:atomic],
        return_records?: true,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success, records: [row | _]} -> {:ok, row}
      _ -> :error
    end
  end
end
