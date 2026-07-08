defmodule PawChart.Application do
  @moduledoc "PawChart vet-clinic OTP application (Phase-6 second-vertical thin slice, T6.2)."
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:pawchart, :start_repo?, true) do
        [PawChart.Repo, {Oban, Application.fetch_env!(:samen_core, Oban)}]
      else
        []
      end

    opts = [strategy: :one_for_one, name: PawChart.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
