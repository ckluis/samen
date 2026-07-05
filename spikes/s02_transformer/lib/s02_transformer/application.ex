defmodule S02Transformer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The spike test harness (test/test_helper.exs) owns the Repo lifecycle so
    # it can storage_up + migrate before connections open. Outside :test the
    # repo is supervised normally.
    children =
      if Application.get_env(:s02_transformer, :start_repo?, true) do
        [S02Transformer.Repo]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: S02Transformer.Supervisor)
  end
end
