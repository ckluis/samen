defmodule Driftwood.Application do
  @moduledoc "Driftwood freight-brokerage OTP application (Phase-5 reference vertical, T5.2)."
  use Application

  @impl true
  def start(_type, _args) do
    # Observability plane (WS-D D1.1): OTel-Ecto with the un-forgettable
    # db_statement: :disabled + metrics contention handlers, wired via the
    # framework helper instead of hand-copied setup calls. Follows the repo:
    # in :test start_repo? is false, so no Ecto telemetry exists to observe.
    repo_children =
      if Application.get_env(:driftwood, :start_repo?, true) do
        Samen.Observability.child_specs(:driftwood) ++
          [Driftwood.Repo, {Oban, Application.fetch_env!(:samen_core, Oban)}]
      else
        []
      end

    # The web plane (PubSub + Endpoint) starts whenever the repo runs (dev/prod). In
    # :test, start_repo? is false, so the web tree is off and the LiveViews are exercised
    # via render/1 + the dogfood test's direct load path (mirrors the demo's T4.1 slice).
    # ADR-012 — the flagship chat needs the framework Presence server (who's-online/typing)
    # alongside the PubSub server. Presence uses the host's PubSub, so it starts after it.
    web_children =
      if Application.get_env(:driftwood, :start_repo?, true) do
        [
          {Phoenix.PubSub, name: Driftwood.PubSub},
          {Samen.Web.Chat.Presence, pubsub_server: Driftwood.PubSub},
          DriftwoodWeb.Endpoint
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Driftwood.Supervisor]
    Supervisor.start_link(repo_children ++ web_children, opts)
  end
end
