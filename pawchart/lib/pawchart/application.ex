defmodule PawChart.Application do
  @moduledoc "PawChart vet-clinic OTP application (Phase-6 second-vertical thin slice, T6.2/T6.3)."
  use Application

  @impl true
  def start(_type, _args) do
    # Observability plane (WS-D D1.1): OTel-Ecto with the un-forgettable
    # db_statement: :disabled + metrics contention handlers, wired via the
    # framework helper instead of hand-copied setup calls. Follows the repo:
    # in :test start_repo? is false, so no Ecto telemetry exists to observe.
    repo_children =
      if Application.get_env(:pawchart, :start_repo?, true) do
        Samen.Observability.child_specs(:pawchart) ++
          [
            PawChart.Repo,
            # T128: install the canonical Samen cron (default_crontab/0) at boot so the
            # audit-partition roll-forward runs by default. No-op under test (plugins: false).
            {Oban, Samen.Jobs.install_default_cron(Application.fetch_env!(:samen_core, Oban))}
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
