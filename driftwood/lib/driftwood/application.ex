defmodule Driftwood.Application do
  @moduledoc "Driftwood freight-brokerage OTP application (Phase-5 reference vertical, T5.2)."
  use Application

  @impl true
  def start(_type, _args) do
    # ADR-045 §2 (V-F1) — the fail-secure tenant-auth BOOT GUARD: refuse to boot a PROD host
    # whose tenant gate is disarmed (a no-op in dev/test). Sits beside the ADR-024 prod-secret
    # raise as the framework's second boot-honest refusal.
    Samen.Web.TenantGate.assert_prod_armed!(:driftwood)

    # Observability plane (WS-D D1.1): OTel-Ecto with the un-forgettable
    # db_statement: :disabled + metrics contention handlers, wired via the
    # framework helper instead of hand-copied setup calls. Follows the repo:
    # in :test start_repo? is false, so no Ecto telemetry exists to observe.
    repo_children =
      if Application.get_env(:driftwood, :start_repo?, true) do
        Samen.Observability.child_specs(:driftwood) ++
          [
            Driftwood.Repo,
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
