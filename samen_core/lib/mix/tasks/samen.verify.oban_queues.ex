defmodule Mix.Tasks.Samen.Verify.ObanQueues do
  @shortdoc "Fail build when a worker enqueues to a queue this app never configures."

  @moduledoc """
  `mix samen.verify.oban_queues` — worker-queue ⊆ configured-queue PARITY (B-OBAN).

  ## What it checks

  For this app's runtime population (samen_core plus every loaded application that
  depends on it — see `Samen.Jobs.QueueParity.samen_apps/0`), it DISCOVERS every
  queue enqueued to by a compiled `Oban.Worker` — hand-written workers and the
  worker/scheduler modules AshOban generates for each `trigger` alike, via the
  `c:Oban.Worker.__opts__/0` callback — and asserts each one is present in the
  RESOLVED runtime Oban configuration: `Samen.Jobs.install_defaults/1` applied to
  this host's `config :samen_core, Oban`, which is byte-for-byte what
  `application.ex` hands to the `{Oban, _}` child spec.

  ## Why this matters (B-OBAN)

  A job enqueued to an unconfigured queue does NOT fail. `Oban.insert/2` returns
  `{:ok, job}`, the row lands in `oban_jobs` with `state = 'available'`, and no
  producer ever claims it: no error, no retry, no discard, an empty DLQ, and an
  Oban dashboard that looks perfectly healthy. A webhook ingress still returns 200
  to the upstream provider; the operator's DLQ "replay" button still reports
  success. The work simply never happens, permanently and silently.

  That shipped: `:webhooks_in` (inbound webhook processing) was configured by NONE
  of the four host configs, and `:automation`/`:automation_timers` by one, because
  each host hand-maintained its own `queues:` list and nothing ever compared those
  lists to the workers. The fix is the `Samen.Jobs.install_defaults/1` seam; this
  task is the gate that keeps them in parity.

  ## Non-vacuity

  A discovery-based check passes trivially when discovery finds nothing. This task
  FAILS CLOSED on empty discovery instead of printing a green line — the same
  non-emptiness floor the other discovery verifiers require.

  ## Exit codes

  - `0` — every enqueued-to queue has a configured producer
  - `1` — at least one queue is enqueued-to but unconfigured, or discovery was empty

  ## Example

      $ mix samen.verify.oban_queues
      [oban-queue-parity] 21 workers across 9 queues (samen_core, samen_web, driftwood) — all configured. ✓

      $ mix samen.verify.oban_queues
      [oban-queue-parity] FAIL: queues enqueued to but NOT configured:
        - :webhooks_in <- Samen.Webhook.IngestWorker
      Jobs on an unconfigured queue sit `available` FOREVER — no error, no retry, no DLQ.
  """

  use Mix.Task

  alias Samen.Jobs.QueueParity

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    case QueueParity.check() do
      {:ok, report} ->
        worker_count = report.sources |> Map.values() |> List.flatten() |> length()
        apps = Enum.map_join(report.apps, ", ", &to_string/1)

        configured =
          case report.configured do
            :disabled -> "queues disabled on this node (queues: false)"
            names -> "#{length(names)} configured"
          end

        Mix.shell().info(
          "[oban-queue-parity] #{worker_count} workers across " <>
            "#{length(report.discovered)} queues (#{apps}) — #{configured}, all covered. ✓"
        )

      {:error, {:no_workers_discovered, apps}} ->
        Mix.shell().error("[oban-queue-parity] FAIL: discovered ZERO Oban workers.")

        Mix.shell().error(
          "  scanned applications: #{Enum.map_join(apps, ", ", &to_string/1)}"
        )

        Mix.shell().error(
          "A parity check that discovers nothing verifies nothing — this is a FAILURE, not a pass."
        )

        Mix.raise("oban-queue-parity: empty discovery — exit 1")

      {:error, {:unconfigured_queues, missing, _report}} ->
        Mix.shell().error("[oban-queue-parity] FAIL: queues enqueued to but NOT configured:")

        Enum.each(missing, fn {queue, mods} ->
          Mix.shell().error("  - #{inspect(queue)} <- #{Enum.map_join(mods, ", ", &inspect/1)}")
        end)

        Mix.shell().error(
          "Jobs on an unconfigured queue sit `available` FOREVER — no error, no retry, no DLQ."
        )

        Mix.shell().error(
          "Register the queue in Samen.Jobs.default_queue_config/0 (the single source of truth)."
        )

        Mix.raise("oban-queue-parity: unconfigured worker queues — exit 1")

      {:error, :no_oban_config} ->
        Mix.shell().error(
          "[oban-queue-parity] FAIL: no `config :samen_core, Oban` in this app — nothing to verify."
        )

        Mix.raise("oban-queue-parity: missing Oban config — exit 1")
    end
  end
end
