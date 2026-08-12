defmodule PawChart.Application do
  @moduledoc "PawChart vet-clinic OTP application (Phase-6 second-vertical thin slice, T6.2/T6.3)."
  use Application

  @impl true
  def start(_type, _args) do
    # ADR-045 §2 (V-F1) — the fail-secure tenant-auth BOOT GUARD: refuse to boot a PROD host
    # whose tenant gate is disarmed (a no-op in dev/test). Sits beside the ADR-024 prod-secret
    # raise as the framework's second boot-honest refusal.
    Samen.Web.TenantGate.assert_prod_armed!(:pawchart)

    # Observability plane (WS-D D1.1): OTel-Ecto with the un-forgettable
    # db_statement: :disabled + metrics contention handlers, wired via the
    # framework helper instead of hand-copied setup calls. Follows the repo:
    # in :test start_repo? is false, so no Ecto telemetry exists to observe.
    repo_children =
      if Application.get_env(:pawchart, :start_repo?, true) do
        Samen.Observability.child_specs(:pawchart) ++
          [
            PawChart.Repo,
            # T128 + B-OBAN: install the canonical Samen queue taxonomy
            # (default_queue_config/0) AND cron (default_crontab/0) at boot — modules are
            # loaded here, unlike in config.exs. So every queue any shipped worker or
            # AshOban trigger enqueues to has a producer, and the audit-partition
            # roll-forward runs, with no host-maintained list. No-op under test
            # (plugins: false, testing: :manual).
            {Oban, Samen.Jobs.install_defaults(Application.fetch_env!(:samen_core, Oban))}
          ]
      else
        []
      end

    # The web plane (PubSub + Endpoint) starts whenever the repo runs (dev/prod). In
    # :test, start_repo? is false, so the web tree is off (mirrors Driftwood's pattern).
    web_children =
      if Application.get_env(:pawchart, :start_repo?, true) do
        [{Phoenix.PubSub, name: PawChart.PubSub}, PawChartWeb.Endpoint]
      else
        []
      end

    opts = [strategy: :one_for_one, name: PawChart.Supervisor]
    Supervisor.start_link(repo_children ++ web_children, opts)
  end
end
