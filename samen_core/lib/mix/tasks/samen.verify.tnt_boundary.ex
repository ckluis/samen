defmodule Mix.Tasks.Samen.Verify.TntBoundary do
  @shortdoc "Verify the Tier-2 one-way boundary (no system resource references into tnt_record)."

  @moduledoc """
  `mix samen.verify.tnt_boundary` — the Tier-2 **one-way boundary** CI sweep (plan
  T3.9; vision doc §core "System = provable; tenant = validated-at-write,
  contained, one-way boundary").

  The whole-app backstop to the per-resource compile-time verifier
  (`Samen.Verifiers.TntBoundary`). It sweeps every resource in every configured Ash
  domain and fails if any **system** resource declares a relationship
  (`belongs_to`/`has_one`/`has_many`/`many_to_many`) whose destination is
  `Samen.CustomObjects.Record` (`tnt_record`).

  The boundary is one-way: the tenant regime may reference OUT to system rows
  (opaque IDs in `tnt_record.refs`), but the system regime must never reference IN
  to the tenant regime. A system→tenant relationship would invert the source of
  truth (the exact thing the vision doc rejects about Twenty's runtime-DDL metadata
  model) and would put a real FK from a system table into `tnt_record` — breaking
  the structural no-FK guarantee.

  In addition to relationships, it asserts the **structural** half: no FK
  constraint in the database targets `tnt_record` or `tnt_object` (belt to the
  relationship check — a raw-SQL FK added outside Ash would be caught here).

  ## Usage

      mix samen.verify.tnt_boundary
      mix samen.verify.tnt_boundary --domain MyApp.Crm
      mix samen.verify.tnt_boundary --repo MyApp.Repo

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`).
  """
  use Mix.Task

  @task_name "samen.verify.tnt_boundary"
  @tenant_record Samen.CustomObjects.Record

  # Tenant-regime physical tables no system table may reference.
  @tenant_tables ~w(tnt_record tnt_object)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} =
      OptionParser.parse(args, strict: [domain: :keep, repo: :string])

    violations = relationship_violations(opts) ++ fk_violations(opts)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Scan configured domains for a system resource declaring a relationship into
  `tnt_record`. Separated from `run/1` so tests can call it without halting.
  """
  def relationship_violations(opts \\ []) do
    domains(opts)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == @tenant_record))
    |> Enum.flat_map(fn resource ->
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&(&1.destination == @tenant_record))
      |> Enum.map(fn rel ->
        "system resource #{inspect(resource)} declares relationship #{inspect(rel.name)} " <>
          "→ #{inspect(@tenant_record)} (tnt_record) — the one-way boundary forbids " <>
          "the system regime from referencing INTO the tenant regime (T3.9)."
      end)
    end)
  end

  @doc """
  Assert no FK constraint in the DB targets a tenant-regime table (the structural
  half of the boundary). Separated from `run/1` for tests.
  """
  def fk_violations(opts \\ []) do
    case resolve_repos(opts) do
      [] ->
        []

      repos ->
        Enum.flat_map(repos, fn repo ->
          ensure_repo_started!(repo)

          %{rows: rows} =
            repo.query!(
              """
              SELECT tc.constraint_name, ccu.table_name
              FROM information_schema.table_constraints tc
              JOIN information_schema.constraint_column_usage ccu
                ON tc.constraint_name = ccu.constraint_name
              WHERE tc.constraint_type = 'FOREIGN KEY'
                AND ccu.table_name = ANY($1)
              """,
              [@tenant_tables]
            )

          for [cname, table] <- rows do
            "FK constraint #{cname} targets tenant-regime table #{table} — no system " <>
              "table may reference INTO the tenant regime (one-way boundary, T3.9)."
          end
        end)
    end
  end

  # -------------------------------------------------------------------------

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
