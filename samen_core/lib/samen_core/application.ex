defmodule SamenCore.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The test harness (test/test_helper.exs) owns the Repo lifecycle so it can
    # storage_up + migrate before connections open. A host application supervises
    # its own repo; samen_core ships no runtime repo of its own.
    children =
      if Application.get_env(:samen_core, :start_repo?, false) do
        [SamenCore.TestRepo]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: SamenCore.Supervisor)
  end
end
