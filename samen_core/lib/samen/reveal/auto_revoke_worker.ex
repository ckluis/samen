defmodule Samen.Reveal.AutoRevokeWorker do
  @moduledoc """
  The reveal-grant auto-revoke job (T1.6 clause (d); doc D6 "Oban auto-revoke job
  scheduled in the same transaction that writes the grant").

  `Samen.Reveal.Grants.approve/2` enqueues this worker with `scheduled_at:
  expires_at` IN THE SAME TRANSACTION that inserts the grant row (via
  `Oban.insert/2` on the multi's repo). Because the enqueue and the grant insert
  share one transaction, a grant insert that rolls back leaves NO `oban_jobs`
  row — proven by the crash test in `reveal_grant_same_tx_test.exs`.

  At `expires_at` the job runs and flips the grant's `revoked_at` to now (if not
  already revoked), and writes an `expired`/`revoked` audit row. This is
  belt-and-suspenders with the deny-on-read policy (clause (c)): even if this job
  never ran, `Samen.Reveal.Grants.active?/2` already denies past `expires_at`.
  The job exists so the row is eventually reconciled to `revoked`, not to make
  expiry safe (expiry is safe on read regardless).
  """
  use Oban.Worker, queue: :reveal, max_attempts: 5

  alias Samen.Reveal.RevealGrant
  alias Samen.Reveal.Grants

  import Ecto.Query, only: [from: 2]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"grant_id" => grant_id}}) do
    repo = Grants.repo()
    now = DateTime.utc_now()

    case repo.get(RevealGrant, grant_id) do
      nil ->
        # Grant gone (e.g. subject fully erased) — nothing to revoke. Idempotent.
        :ok

      %RevealGrant{revoked_at: revoked_at} = grant when is_nil(revoked_at) ->
        # Flip to revoked only if still active. Use an UPDATE that only touches
        # revoked_at (NOT expires_at — clause (e) no renew-in-place) and only
        # where revoked_at is still NULL, so concurrent manual revokes are safe.
        {count, _} =
          repo.update_all(
            from(g in RevealGrant,
              where: g.id == ^grant_id and is_nil(g.revoked_at)
            ),
            set: [revoked_at: now, updated_at: now]
          )

        if count == 1 do
          Grants.write_audit(repo, %{
            event: "expired",
            subject_id: grant.subject_id,
            actor_id: "system:auto_revoke",
            request_id: grant.request_id,
            grant_id: grant.id,
            detail: "auto-revoked at expires_at=#{DateTime.to_iso8601(grant.expires_at)}"
          })
        end

        :ok

      %RevealGrant{} ->
        # Already revoked (manual revoke won the race) — idempotent no-op.
        :ok
    end
  end
end
