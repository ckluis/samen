defmodule Demo.Application do
  @moduledoc "Demo contact-manager OTP application (T1.9 dogfood)."
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:demo, :start_repo?, true) do
        [Demo.Repo]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Demo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
