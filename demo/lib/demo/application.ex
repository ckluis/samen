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
        Samen.Observability.child_specs(:demo) ++ [Demo.Repo]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Demo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
