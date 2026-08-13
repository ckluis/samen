defmodule Samen.AuditChain.VerifyWorker do
  @moduledoc """
  The scheduled audit-chain integrity sweep (F3.5; ADR-002). Complements the
  `Samen.Anchor.SealWorker` (which anchors heads into the WORM store): this worker
  periodically RE-VERIFIES every org's live hash chain end-to-end and emits
  telemetry so a detected tamper (edit/delete/reorder) alerts continuously, not
  only at the next external-anchor comparison.

  Mount via `Samen.Jobs.default_crontab/0`.

  ## Telemetry, not retry, is the alert channel

  A hash-chain tamper is NOT a transient infra fault — retrying the job cannot
  "fix" it. So the worker emits `[:samen, :audit_chain, :verify]` + one
  `[:samen, :audit_chain, :tamper]` per failed org (via `AuditChain.verify_all/1`),
  logs failures at `error`, and returns `:ok`. The durable alert is the telemetry
  signal + the error log; Oban retry is reserved for the seal worker's transient
  anchor-store outages.

  ## Queue / attempts — its OWN queue so a long verify cannot starve roll-forward (O3)

  Queue `:audit_verify` (NOT the shared `:maintenance` lane). The verify sweep is a
  keyset-bounded but still potentially long scan of every org's chain; on `:maintenance`
  (concurrency 1) it shared a strict-serialization lane with `Samen.AuditEvent.PartitionManager`
  — the audit-partition roll-forward whose absence makes `aud_event` writes FAIL at the next
  month boundary. A verify that ran long would queue the roll-forward behind it. Its own
  queue removes that collision: the verify can take as long as it needs without blocking the
  mechanism that keeps the audit table writable.

  `max_attempts: 1` — a read-only verification sweep is not retried; the next cron tick
  re-runs it. `unique: [period: 900, ...]` — a still-`available`/`executing` verify is NOT
  re-enqueued by the next 15-minute tick, so ticks cannot pile up into a backlog.
  """
  use Oban.Worker,
    queue: :audit_verify,
    max_attempts: 1,
    unique: [period: 900, states: [:scheduled, :available, :executing, :retryable, :suspended]]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    summary = Samen.AuditChain.verify_all()

    if summary.failed == [] do
      Logger.debug(
        "[Samen.AuditChain.VerifyWorker] job_id=#{job_id} orgs=#{summary.orgs} verified=#{summary.verified} tamper=0"
      )
    else
      Logger.error(
        "[Samen.AuditChain.VerifyWorker] job_id=#{job_id} TAMPER DETECTED in " <>
          "#{length(summary.failed)}/#{summary.orgs} org chains: #{inspect(summary.failed)}"
      )
    end

    :ok
  end
end
