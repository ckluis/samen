defmodule Samen.Jobs.RollupRefreshWorker do
  @moduledoc """
  Heartbeat rollup-refresh worker (T2.1 cron scaffold; T2.3 replaces with real
  AshOban triggers per rollup resource).

  Scheduled every 10 minutes via `Samen.Jobs.default_crontab/0`. In T2.1 this
  is a scaffold — it logs a heartbeat and returns `:ok`. T2.3 will replace the
  body with real `Ecto.Multi`-backed rollup materialisation.

  Queue: `:rollups` (concurrency 2 — rollup refreshes can run concurrently but
  are bounded so they don't compete with OLTP writes).

  DLQ policy: `max_attempts: 5` — rollup refreshes are idempotent (the next cron
  tick will retry); discarding after 5 attempts is safe.
  """
  use Oban.Worker, queue: :rollups, max_attempts: 5

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    Logger.debug("[Samen.Jobs.RollupRefreshWorker] heartbeat job_id=#{job_id}")
    # T2.3: replace with real rollup materialisation.
    :ok
  end
end
