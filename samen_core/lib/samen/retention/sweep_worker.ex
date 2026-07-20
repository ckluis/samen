defmodule Samen.Retention.SweepWorker do
  @moduledoc """
  The scheduled retention sweep (F3.2). Reads the host's registered retention specs
  from app config and runs `Samen.Retention.sweep/2` — auto-shredding / pruning data
  past its configured TTL. Mount via `Samen.Jobs.default_crontab/0` (daily).

  ## Configuration

      config :samen_core, :retention_specs, [
        %{resource: MyApp.Marketing.Subscriber, ttl_seconds: 730*86400,
          action: :shred, subject_field: :id},
        %{resource: MyApp.Support.Ticket, ttl_seconds: 365*86400,
          action: :delete, timestamp_field: :closed_at}
      ]

  With NO config the sweep is a safe no-op (`[]`) — retention is opt-in per host, and
  an unconfigured host never silently deletes data. Fail-closed: a spec with a
  non-positive TTL is refused by `Samen.Retention`, not treated as "sweep everything".

  ## Queue / attempts

  Queue `:maintenance`; `max_attempts: 3`. The sweep is idempotent (a re-run finds no
  new expired rows for already-swept data).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    specs = Application.get_env(:samen_core, :retention_specs, [])

    report = Samen.Retention.sweep(specs)

    Logger.info(
      "[Samen.Retention.SweepWorker] job_id=#{job_id} swept=#{report.swept} " <>
        "specs=#{length(specs)}"
    )

    :ok
  end
end
