defmodule Mix.Tasks.Samen.Verify.NoPiiColumns do
  @shortdoc "Verify the token-blind aggregate plane has no pii_ columns (C7)."

  @moduledoc """
  `mix samen.verify.no_pii_columns` — the whole-app CI backstop to the compile-time
  `Samen.Verifiers.NoPiiColumns` verifier (C7; plan T4.2 clause (b); doc §control
  "an aggregate actor … whose resources have no pii_ columns at all").

  The per-resource verifier fails a single aggregate resource's compile if it
  declares a `pii_attribute`, a vault, a `pii_`-shaped column, or a relationship
  reaching a PII-bearing resource. This task is the fleet-wide sweep, mirroring the
  other verifiers, and adds the **physical-table** assertion the compile-time
  verifier can't do:

    1. **DSL sweep** — for every aggregate-plane resource (one declared with
       `use Samen.Aggregate.Resource`) in every configured domain, re-run the exact
       C7 rules (`Samen.Verifiers.NoPiiColumns.violations/2`). Catches a resource
       that somehow skipped the extension, and re-checks relationship destinations
       against fully-compiled modules.

    2. **information_schema sweep** — for each aggregate resource's physical table,
       query `information_schema.columns` and FAIL if any column name starts with
       `pii_` (the vault-column shape). This is the "pii_ columns physically don't
       exist" claim asserted against the LIVE database, not just the DSL — a
       raw-SQL `ALTER TABLE ... ADD COLUMN pii_...` on a rollup table is caught here.

  ## Usage

      mix samen.verify.no_pii_columns
      mix samen.verify.no_pii_columns --domain MyApp.Aggregate
      mix samen.verify.no_pii_columns --repo MyApp.Repo

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`).
  """
  use Mix.Task

  @task_name "samen.verify.no_pii_columns"
  @pii_column_prefix "pii_"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} =
      OptionParser.parse(args, strict: [domain: :keep, repo: :string])

    violations = dsl_violations(opts) ++ physical_column_violations(opts)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Re-run the C7 DSL rules on every aggregate-plane resource in the configured
  domains. Separated from `run/1` so tests can call it without halting.
  """
  def dsl_violations(opts \\ []) do
    aggregate_resources(opts)
    |> Enum.flat_map(fn resource ->
      resource
      |> Samen.Verifiers.NoPiiColumns.violations(resource)
      |> Enum.map(fn {_path, message} -> message end)
    end)
  end

  @doc """
  For each aggregate-plane resource, assert its physical table carries no `pii_`
  column (information_schema). Separated from `run/1` for tests.
  """
  def physical_column_violations(opts \\ []) do
    case resolve_repos(opts) do
      [] ->
        []

      repos ->
        tables = aggregate_tables(opts)

        Enum.flat_map(repos, fn repo ->
          ensure_repo_started!(repo)

          Enum.flat_map(tables, fn {resource, table} ->
            %{rows: rows} =
              repo.query!(
                """
                SELECT column_name
                FROM information_schema.columns
                WHERE table_name = $1
                  AND column_name LIKE $2
                """,
                [table, @pii_column_prefix <> "%"]
              )

            for [col] <- rows do
              "aggregate-plane resource #{inspect(resource)} (table #{table}) has physical " <>
                "column #{col} matching the vault shape `pii_*`. The token-blind aggregate " <>
                "plane's projection must contain no pii_ columns at all (C7, T4.2)."
            end
          end)
        end)
    end
  end

  @doc """
  The aggregate-plane resources across the configured domains (those declared with
  `use Samen.Aggregate.Resource`).
  """
  def aggregate_resources(opts \\ []) do
    domains(opts)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&Samen.Aggregate.Info.aggregate_plane?/1)
  end

  # -------------------------------------------------------------------------

  defp aggregate_tables(opts) do
    aggregate_resources(opts)
    |> Enum.map(fn resource -> {resource, AshPostgres.DataLayer.Info.table(resource)} end)
    |> Enum.reject(fn {_resource, table} -> is_nil(table) end)
  end

  defp domains(opts) do
    case Keyword.get_values(opts, :domain) do
      [] ->
        otp_app = Mix.Project.config()[:app]
        Application.get_env(otp_app, :ash_domains, [])

      names ->
        Enum.map(names, &Module.concat([&1]))
    end
  end

  defp resolve_repos(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        otp_app = Mix.Project.config()[:app]
        Application.get_env(otp_app, :ecto_repos, [])

      repo_str ->
        [Module.concat([repo_str])]
    end
  end

  defp ensure_repo_started!(repo) do
    case repo.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "Could not start repo #{inspect(repo)}: #{inspect(reason)}"
    end
  end
end
