defmodule Mix.Tasks.SamenWeb.TestSetup do
  @shortdoc "Create + migrate the scratch samen_web_test DB for the render tests"
  @moduledoc """
  Sets up the throwaway `samen_web_test` database that backs `samen_web`'s standalone render
  tests (ADR-009 §6). Drops (if present), creates, and migrates the DB so the test-support
  scope resources + vault routing are live. Run automatically by the `mix test` alias.

  Idempotent: safe to run repeatedly. Only touches the `:test` repo config.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    # Force the test environment repo config.
    Mix.Task.run("loadpaths")
    Application.ensure_all_started(:ash_postgres)
    Application.ensure_all_started(:ecto_sql)

    # `Module.concat/1` (not a compile-time literal) so a HOST that pulls samen_web as a
    # dep — and therefore does NOT compile samen_web's `test/support` `Samen.WebTest.Repo`
    # — gets no "undefined module" warning when this task module is compiled. The module
    # still resolves at runtime in samen_web's own `:test` env, where the repo exists.
    repo = Module.concat([Samen.WebTest, Repo])

    # Drop + create the scratch DB (ignore "does not exist" on drop).
    _ = repo.__adapter__().storage_down(repo.config())
    :ok = ensure_created(repo)

    {:ok, _} = repo.start_link(pool_size: 2)

    # Quiet the per-column catalog_sync INSERT logging during the one-time migration.
    prev_level = Logger.level()
    Logger.configure(level: :warning)
    Ecto.Migrator.run(repo, migrations_path(), :up, all: true)
    Logger.configure(level: prev_level)

    :ok
  end

  defp ensure_created(repo) do
    case repo.__adapter__().storage_up(repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> Mix.raise("Could not create #{inspect(repo)}: #{inspect(reason)}")
    end
  end

  defp migrations_path do
    Path.join([File.cwd!(), "priv", "repo", "migrations"])
  end
end
