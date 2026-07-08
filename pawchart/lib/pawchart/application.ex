defmodule PawChart.Application do
  @moduledoc "PawChart vet-clinic OTP application (Phase-6 second-vertical thin slice, T6.2/T6.3)."
  use Application

  @impl true
  def start(_type, _args) do
    repo_children =
      if Application.get_env(:pawchart, :start_repo?, true) do
        [PawChart.Repo, {Oban, Application.fetch_env!(:samen_core, Oban)}]
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
