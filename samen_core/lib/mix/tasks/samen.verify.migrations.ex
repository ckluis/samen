defmodule Mix.Tasks.Samen.Verify.Migrations do
  @shortdoc "CI check: every expand migration's down/0 is exercised in a scratch DB."

  @moduledoc """
  `mix samen.verify.migrations` — the expand-`down/0` CI check (T2.4a).

  Exercises EVERY `:expand`-phase migration's `down/0` in a throwaway scratch
  database: migrates up, then for each expand migration steps down (running its
  `down/0`) and back up, failing closed if any down is missing, raises, or is not a
  clean round trip. `:contract`-phase migrations are covered by PITR, not `down/0`
  (doc §runs 2b), so they are not down-tested.

  ## Scratch DB, never production

  The check creates an ephemeral database named `<base>_samen_downcheck_<rand>`,
  runs `Samen.Migration.DownCheck` against it, and DROPS it — it never touches the
  dev or prod database. The scratch repo derives its config from `--repo` (or the
  configured verify repo) but overrides the database name.

  ## Usage

      mix samen.verify.migrations
      mix samen.verify.migrations --repo MyApp.Repo --migrations priv/repo/migrations
      mix samen.verify.migrations --min-expand 1

  Defaults: repo from `config :samen_core, :verify_repo` (or the first configured
  repo); migrations path from the repo's `priv/<repo>/migrations`.

  `--min-expand N` is an OPT-IN, PER-GATE floor: when passed, the discovered
  `:expand`-phase migration count under `migrations_path` must be at least `N` or the
  task fails closed. Absent the flag, no floor is enforced and a count of 0 is green
  — exactly today's behaviour. This exists so a gate can declare "this app owns at
  least one expand migration" without the task imposing that as a repo-wide policy.

  ## Exit code (fail-closed)

  Exits 0 when every expand down is green (and, if `--min-expand` was passed, the
  discovered count meets the declared floor), 1 otherwise, via `:erlang.halt/1`.
  """

  use Mix.Task

  @task_name "samen.verify.migrations"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [repo: :string, migrations: :string, min_expand: :integer]
      )

    Mix.Task.run("app.start")

    base_repo = resolve_repo(opts)
    migrations_path = resolve_migrations_path(opts, base_repo)

    unless File.dir?(migrations_path) do
      Mix.raise("migrations path does not exist: #{migrations_path}")
    end

    violations =
      check_in_scratch_db(base_repo, migrations_path) ++
        min_expand_violations(migrations_path, opts)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Run the check in a scratch DB and return the list of violation strings (empty =
  green). Separated from `run/1` so tests can call it without halting.
  """
  def check_in_scratch_db(base_repo, migrations_path) do
    scratch_config = scratch_config(base_repo)
    scratch_repo = define_scratch_repo(base_repo, scratch_config)

    _ = Ecto.Adapters.Postgres.storage_down(scratch_config)
    :ok = Ecto.Adapters.Postgres.storage_up(scratch_config)

    {:ok, pid} = scratch_repo.start_link(scratch_config)

    try do
      case Samen.Migration.DownCheck.run(scratch_repo, migrations_path, log: false) do
        {:ok, checked} ->
          IO.puts("#{@task_name}: exercised down/0 for #{length(checked)} expand migration(s).")
          []

        {:error, violations} ->
          violations
      end
    after
      Supervisor.stop(pid)
      _ = Ecto.Adapters.Postgres.storage_down(scratch_config)
    end
  end

  @doc """
  Return violation strings for the OPT-IN `--min-expand` floor, or `[]` if no floor
  was declared (`opts` carries no `:min_expand`) or the discovered `:expand`-phase
  migration count under `migrations_path` meets it. Pure and source-level — reuses
  `Samen.Migration.DownCheck.expand_migrations/1`'s discovery, no scratch DB needed.
  Separated from `check_in_scratch_db/2` so tests can exercise the floor alone,
  independent of the down/0 exercise it never weakens, reorders, or shadows.
  """
  def min_expand_violations(migrations_path, opts) do
    case Keyword.get(opts, :min_expand) do
      nil ->
        []

      floor ->
        count = migrations_path |> Samen.Migration.DownCheck.expand_migrations() |> length()

        if count < floor do
          [
            "--min-expand #{floor} declared but found only #{count} :expand migration(s) " <>
              "under #{migrations_path} (observed #{count}, floor #{floor})."
          ]
        else
          []
        end
    end
  end

  # ---------------------------------------------------------------------------

  defp resolve_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        Application.get_env(:samen_core, :verify_repo) ||
          Application.get_env(:samen_core, :non_pii_repo) ||
          Mix.raise("no repo: pass --repo or set config :samen_core, :verify_repo")

      repo_str ->
        Module.concat([repo_str])
    end
  end

  defp resolve_migrations_path(opts, repo) do
    case Keyword.get(opts, :migrations) do
      nil ->
        priv = :code.priv_dir(Application.get_application(repo) || :samen_core)
        repo_dir = repo |> Module.split() |> List.last() |> Macro.underscore()
        Path.join([to_string(priv), repo_dir, "migrations"])

      path ->
        path
    end
  end

  defp scratch_config(base_repo) do
    base = base_repo.config()
    original_db = Keyword.fetch!(base, :database)
    rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    base
    |> Keyword.put(:database, "#{original_db}_downcheck_#{rand}")
    # Drop the sandbox pool so migrations run against a real committed DB (down/0
    # DDL must actually execute, not run inside a rolled-back sandbox transaction).
    |> Keyword.delete(:pool)
    |> Keyword.put(:pool_size, 2)
  end

  # Define an ephemeral repo module bound to the scratch config. We reuse the base
  # repo's adapter behaviour by defining a fresh module (Ecto repos are modules).
  defp define_scratch_repo(base_repo, _scratch_config) do
    otp_app = Application.get_application(base_repo) || :samen_core
    mod_name = Module.concat([base_repo, "SamenDownCheckScratch"])

    if Code.ensure_loaded?(mod_name) do
      mod_name
    else
      contents =
        quote do
          use Ecto.Repo, otp_app: unquote(otp_app), adapter: Ecto.Adapters.Postgres
        end

      Module.create(mod_name, contents, Macro.Env.location(__ENV__))
      mod_name
    end
  end
end
