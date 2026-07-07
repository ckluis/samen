defmodule Samen.Anchor.SealWorker do
  @moduledoc """
  The WORM-anchor seal cron (T4.3; ADR-002 §3.1).

  Periodically (Oban cron — mount via `Samen.Jobs.default_crontab/0`) seals EVERY org's
  audit-chain head into the external write-once store (`Samen.Anchor.adapter/0`). Each
  tick calls `Samen.AuditChain.seal_all/1`, which for each org with chain entries writes
  `{org_id, seq, hash, sealed_at}` to the anchor.

  ## Why a cron (and the honest window)

  Sealing on a cadence — not synchronously on every append — bounds the wholesale-rewrite
  detection window: entries written after the last seal and before the next are not yet
  anchored, so a rewrite that only fabricates *future* entries past the sealed head is
  caught at the *next* seal, not instantly (ADR-002 §3.3). A shorter cadence shrinks the
  window; the trade is anchor-store write volume. The break-glass deferred-anchor path
  (T4.4) reuses this same seal to anchor operator-node-local entries on reconnect.

  ## Fail closed

  If the anchor store is unreachable, `seal_all/1` returns `{:error, {org_id, reason}}`
  and this worker returns an `{:error, …}` so Oban retries — a seal that silently no-op'd
  would leave the chain un-anchored without warning (a false green for the tamper defense).

  ## Queue / attempts

  Queue `:maintenance` (shared with the impersonation expire + SLA workers), `max_attempts:
  5`. Seals are idempotent (the anchor store is append-only; re-sealing the same head is a
  duplicate line the newest-wins `read_head` collapses), so retry is safe.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 5

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    case Samen.AuditChain.seal_all() do
      {:ok, %{sealed: sealed, skipped: skipped}} ->
        Logger.debug(
          "[Samen.Anchor.SealWorker] job_id=#{job_id} sealed=#{sealed} skipped=#{skipped}"
        )

        :ok

      {:error, reason} ->
        # Fail closed: surface the anchor-store failure so Oban retries. Do NOT
        # swallow — an un-anchored chain silently defeats the rewrite defense.
        Logger.error("[Samen.Anchor.SealWorker] seal failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
