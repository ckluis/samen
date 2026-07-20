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

  ## Queue / attempts

  Queue `:maintenance` (shared with the seal + reconcile crons). `max_attempts: 1`
  — a read-only verification sweep is not retried; the next cron tick re-runs it.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

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
