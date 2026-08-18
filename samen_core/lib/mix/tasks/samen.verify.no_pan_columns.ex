defmodule Mix.Tasks.Samen.Verify.NoPanColumns do
  @shortdoc "Verify no resource/table anywhere carries a PAN/CVC-shaped column (ADR-038 B5)."

  @moduledoc """
  `mix samen.verify.no_pan_columns` — the whole-app, repo-wide CI backstop to the
  compile-time `Samen.Verifiers.NoPanColumns` verifier (base-wired into EVERY Samen
  resource via `Samen.Extension`; ADR-038 §3.5 B5 no-PAN invariant; T23; spec §B5
  "card on file via hosted provider surfaces only … no PAN touches samen").

  The compile-time verifier already fails the build of any host that declares a
  PAN/CVC-shaped attribute via the Ash DSL. This task adds the two whole-app sweeps
  the compile-time verifier can't do on its own, mirroring the established
  `samen.verify.no_pii_columns` shape:

    1. **DSL sweep** — for EVERY resource (not just aggregate-plane ones) in every
       configured domain, re-run the exact PAN-shape rule
       (`Samen.Verifiers.NoPanColumns.violations/2`). Catches a resource whose
       compile-time verifier somehow didn't run (e.g. compiled before this task
       shipped) without needing a fresh compile.

    2. **information_schema sweep** — for every table backing an Ash-Postgres
       resource in every configured domain, query `information_schema.columns` and
       FAIL if any column name is PAN/CVC-shaped. This is the "no PAN column
       ANYWHERE" claim asserted against the LIVE database, not just the DSL — a
       raw-SQL `ALTER TABLE … ADD COLUMN card_number …` that bypassed the resource
       layer entirely is caught here, exactly as `no_pii_columns` catches a stray
       `pii_*` column.

  ## Usage

      mix samen.verify.no_pan_columns
      mix samen.verify.no_pan_columns --domain MyApp.Billing
      mix samen.verify.no_pan_columns --repo MyApp.Repo

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`).
  """
  use Mix.Task

  @task_name "samen.verify.no_pan_columns"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} =
      OptionParser.parse(args, strict: [domain: :keep, repo: :string])

    violations = dsl_violations(opts) ++ physical_column_violations(opts)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Re-run the PAN-shape rule on EVERY resource in the configured domains (not
  scoped to the aggregate plane — B5 is a plane-independent invariant). Separated
  from `run/1` so tests can call it without halting.
  """
  def dsl_violations(opts \\ []) do
    resources(opts)
    |> Enum.flat_map(fn resource ->
      resource
      |> Samen.Verifiers.NoPanColumns.violations(resource)
      |> Enum.map(fn {_path, message} -> message end)
    end)
  end

  @doc """
  For every resource's physical table, assert (via `information_schema`) that no
  column name is PAN/CVC-shaped. Separated from `run/1` for tests.
  """
  def physical_column_violations(opts \\ []) do
    case resolve_repos(opts) do
      [] ->
        []

      repos ->
        tables = resource_tables(opts)

        Enum.flat_map(repos, fn repo ->
          ensure_repo_started!(repo)

          Enum.flat_map(tables, fn {resource, table} ->
            %{rows: rows} =
              repo.query!(
                "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
                [table]
              )

            for [col] <- rows, Samen.Verifiers.NoPanColumns.pan_shaped?(col) do
              "resource #{inspect(resource)} (table #{table}) has PHYSICAL column #{col} " <>
                "that is PAN/CVC-shaped. No table anywhere may carry a raw card number or " <>
                "security-code column (ADR-038 §3.5 B5 no-PAN invariant)."
            end
          end)
        end)
    end
  end

  @doc "Every resource across the configured domains (all planes — no aggregate-only filter)."
  def resources(opts \\ []) do
    domains(opts) |> Enum.flat_map(&Ash.Domain.Info.resources/1) |> Enum.uniq()
  end

  # -------------------------------------------------------------------------

  defp resource_tables(opts) do
    resources(opts)
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
