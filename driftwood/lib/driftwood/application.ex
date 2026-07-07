defmodule Driftwood.Application do
  @moduledoc "Driftwood freight-brokerage OTP application (Phase-5 reference vertical, T5.2)."
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:driftwood, :start_repo?, true) do
        [Driftwood.Repo]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Driftwood.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
