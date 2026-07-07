defmodule Samen.Impersonation.ExpireWorker do
  @moduledoc """
  The impersonation session auto-expire job (T4.1; mirrors `Samen.Reveal.AutoRevokeWorker`,
  T1.6 clause (d)).

  `Samen.Impersonation.Sessions.open/1` enqueues this worker with `scheduled_at:
  expires_at` IN THE SAME TRANSACTION that inserts the session row (via `Oban.insert/2`
  on the multi's repo). Because the enqueue and the session insert share one
  transaction, a session insert that rolls back leaves NO `oban_jobs` row.

  At `expires_at` the job runs and flips the session's `closed_at` to now (if not
  already closed), writing an `expired` `aud_event` row (T4.1 clause (d): expiry writes
  an audit row). This is belt-and-suspenders with the deny-on-read policy: even if this
  job never ran, `Samen.Impersonation.Sessions.active?/2` already denies past
  `expires_at`. The job exists so the row is eventually reconciled to closed, not to
  make expiry safe (expiry is safe on read regardless).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 5

  alias Samen.Impersonation.{Session, Sessions}

  import Ecto.Query, only: [from: 2]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id}}) do
    repo = Sessions.repo()
    now = DateTime.utc_now()

    case repo.get(Session, session_id) do
      nil ->
        # Session gone (e.g. org erased) — nothing to close. Idempotent.
        :ok

      %Session{closed_at: closed_at} = session when is_nil(closed_at) ->
        # Flip to closed only if still open. UPDATE that only touches closed_at /
        # close_cause (NOT expires_at — no renew-in-place) and only where closed_at is
        # still NULL, so a concurrent manual close is safe.
        {count, _} =
          repo.update_all(
            from(s in Session,
              where: s.id == ^session_id and is_nil(s.closed_at)
            ),
            set: [closed_at: now, close_cause: "expired", updated_at: now]
          )

        if count == 1 do
          Sessions.emit_event(repo, "expired", %{
            org_id: session.org_id,
            operator_id: "system:auto_expire",
            session_id: session.id,
            reason: session.reason,
            detail: "auto-closed at expires_at=#{DateTime.to_iso8601(session.expires_at)}"
          })
        end

        :ok

      %Session{} ->
        # Already closed (manual close won the race) — idempotent no-op.
        :ok
    end
  end
end
