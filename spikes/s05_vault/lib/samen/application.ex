defmodule S05Vault.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # In :test the DB may not exist yet at boot; the test harness
    # (S05Vault.DBCase) creates the DB then starts the repo explicitly, so we
    # do not auto-start it here. InMemory KMS is always safe to start.
    children =
      [Samen.Kms.InMemory] ++
        if Application.get_env(:s05_vault, :start_repo, true), do: [Samen.Repo], else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: S05Vault.Supervisor)
  end
end
