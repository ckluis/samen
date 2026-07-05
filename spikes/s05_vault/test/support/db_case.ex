defmodule S05Vault.DBCase do
  @moduledoc """
  Test support: (re)create the spike DB and run migrations. No Ecto sandbox —
  the PITR/`pg_dump` red path requires real committed on-disk data.
  """

  @doc "Drop, create, and migrate the test database. Returns :ok."
  def reset_db! do
    repo = Samen.Repo
    config = repo.config()

    # Ensure repo is stopped before drop/create.
    _ = Ecto.Adapters.Postgres.storage_down(config)
    :ok = Ecto.Adapters.Postgres.storage_up(config) |> normalize_storage()

    {:ok, _} = ensure_repo_started(repo)

    Ecto.Migrator.run(repo, migrations_path(), :up, all: true, log: false)
    :ok
  end

  @doc "Truncate the vault + domain tables between tests without a full rebuild."
  def truncate! do
    Samen.Repo.query!("TRUNCATE person, pii_email RESTART IDENTITY CASCADE", [])
    :ok
  end

  defp ensure_repo_started(repo) do
    case repo.start_link() do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp normalize_storage(:ok), do: :ok
  defp normalize_storage({:error, :already_up}), do: :ok
  defp normalize_storage(other), do: other

  defp migrations_path do
    priv = :code.priv_dir(:s05_vault) |> to_string()
    Path.join([priv, "repo", "migrations"])
  end
end
