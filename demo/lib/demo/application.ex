defmodule Demo.Application do
  @moduledoc "Demo contact-manager OTP application (T1.9 dogfood)."
  use Application

  @impl true
  def start(_type, _args) do
    # Observability plane (WS-D D1.1): OTel-Ecto with the un-forgettable
    # db_statement: :disabled + metrics contention handlers, wired via the
    # framework helper instead of hand-copied setup calls. Follows the repo:
    # in :test start_repo? is false, so no Ecto telemetry exists to observe.
    children =
      if Application.get_env(:demo, :start_repo?, true) do
        Samen.Observability.child_specs(:demo) ++
          [
            Demo.Repo,
            # O6 / B-OBAN: the demo DECLARED a full Oban runtime (queues, cron, pruner)
            # and never started it. It is API-only, but "API-only" is not "job-free" —
            # demo mounts the Marketing scope (every send is an Oban job on
            # :webhooks_out via Samen.Jobs.enqueue_in_tx/3), wires the notification
            # ENGINE (EmailDispatchWorker), ships reveal_grants (the T1.6 same-tx
            # auto-revoke enqueue on :reveal), and owns a PARTITIONED aud_event table
            # whose roll-forward is `Samen.AuditEvent.PartitionManager` on the canonical
            # crontab. With no Oban child every one of those enqueues succeeded and then
            # never ran, and audit writes were on course to fail outright at the next
            # partition boundary. Started here through the same framework seam
            # driftwood/pawchart/generated apps use. No-op under test (start_repo? false).
            {Oban, Samen.Jobs.install_defaults(Application.fetch_env!(:samen_core, Oban))}
          ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Demo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
