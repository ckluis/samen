defmodule Driftwood.Application do
  @moduledoc "Driftwood freight-brokerage OTP application (Phase-5 reference vertical, T5.2)."
  use Application

  @impl true
  def start(_type, _args) do
    repo_children =
      if Application.get_env(:driftwood, :start_repo?, true) do
        [Driftwood.Repo, {Oban, Application.fetch_env!(:samen_core, Oban)}]
      else
        []
      end

    # The web plane (PubSub + Endpoint) starts whenever the repo runs (dev/prod). In
    # :test, start_repo? is false, so the web tree is off and the LiveViews are exercised
    # via render/1 + the dogfood test's direct load path (mirrors the demo's T4.1 slice).
    web_children =
      if Application.get_env(:driftwood, :start_repo?, true) do
        [{Phoenix.PubSub, name: Driftwood.PubSub}, DriftwoodWeb.Endpoint]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Driftwood.Supervisor]
    Supervisor.start_link(repo_children ++ web_children, opts)
  end
end
