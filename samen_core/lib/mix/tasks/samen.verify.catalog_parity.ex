defmodule Mix.Tasks.Samen.Verify.CatalogParity do
  @shortdoc "Verify catalog parity: columns ⇄ fld_field rows, resources ↔ tam_table rows."

  @moduledoc """
  `mix samen.verify.catalog_parity` — verifier C1 (plan §C, Gate-0 fix tasks #5).

  ## What it checks

  Three directions of the column ⇄ catalog invariant:

  1. **Storage → catalog** (no uncatalogued column): for every physical column in
     `information_schema.columns` on Samen-managed tables, there must be a matching
     `fld_field` row.

  2. **Catalog → storage** (no orphan catalog row): for every `fld_field` row,
     the named physical column must exist in `information_schema.columns`.

  3. **Resource → tam_table** (no ghost table / uncatalogued resource — Gate-0 fix
     #5): every `Ash.Resource.Info`-visible resource with an AshPostgres data layer
     must appear in `tam_table`. A whole resource table that was never catalogued
     passes the first two checks silently (the ghost table is simply not in
     `tam_table`, so the column set is empty on both sides). This third check
     catches it explicitly.

  ## Diagnostics

  Each violation names the owning resource module (F4 — diagnostic quality fix):

      FAIL: samen.verify.catalog_parity found 3 violation(s):
        • uncatalogued column: com_contact.com_phone [SamenCore.Support.Crm.Contact]
        • orphan fld_field row: com_contact.com_old_field
        • ghost table: xyz_thing (resource SamenCore.Xyz.Thing not in tam_table)

  ## Allow-list (intentional shadow columns — Gate-0 fix F2)

  Some columns are intentionally present in the DB but absent from `fld_field`
  (e.g. Ecto schema migration internal columns, external tools). Declare them in
  your app config:

      config :samen_core, :catalog_parity_allow_list, [
        {"tam_table", "tam_id"},
        {"fld_field", "fld_id"}
      ]

  Allow-listed pairs are silently excluded from the "uncatalogued column" check.
  They are NOT excluded from the "orphan catalog row" check — a shadow column
  should never have a `fld_field` row.

  ## Repo discovery

  By default, reads `:ecto_repos` from the host app's config to discover all
  repos to check. Pass `--repo MyApp.Repo` to override:

      mix samen.verify.catalog_parity --repo MyApp.Repo

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `:erlang.halt/1`).
  """

  use Mix.Task

  @task_name "samen.verify.catalog_parity"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} =
      OptionParser.parse(args, strict: [repo: :string])

    repos = resolve_repos(opts)

    violations =
      Enum.flat_map(repos, fn repo ->
        ensure_repo_started!(repo)
        check(repo)
      end)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Run the parity check against `repo` and return a (possibly empty) list of
  human-readable violation strings.

  Separated from `run/1` so the test suite can call it directly and inspect
  violations without triggering `:erlang.halt/1`.
  """
  def check(repo) do
    allow_list = load_allow_list()
    managed_tables = managed_table_names(repo)
    physical = physical_columns(repo, managed_tables)
    catalogued = catalogued_columns(repo, managed_tables)

    # Direction 1: storage → catalog (no uncatalogued column)
    uncatalogued =
      MapSet.difference(physical, catalogued)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.reject(fn {t, c} -> MapSet.member?(allow_list, {t, c}) end)
      |> Enum.map(fn {t, c} ->
        owner = resource_for_table(t)
        suffix = if owner, do: " [#{owner}]", else: ""
        "uncatalogued column: #{t}.#{c}#{suffix}"
      end)

    # Direction 2: catalog → storage (no orphan catalog row)
    orphaned =
      MapSet.difference(catalogued, physical)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(fn {t, c} -> "orphan fld_field row: #{t}.#{c}" end)

    # Direction 3: resource → tam_table (Gate-0 fix #5 — ghost table detection)
    ghost_table_violations = ghost_table_check(repo, managed_tables)

    uncatalogued ++ orphaned ++ ghost_table_violations
  end

  # ---------------------------------------------------------------------------
  # Repo resolution
  # ---------------------------------------------------------------------------

  defp resolve_repos(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        otp_app = Mix.Project.config()[:app]
        repos = Application.get_env(otp_app, :ecto_repos, [])

        if repos == [] do
          Mix.shell().error(
            "samen.verify.catalog_parity: no :ecto_repos configured for #{otp_app}. " <>
              "Pass --repo MyApp.Repo to override."
          )
        end

        repos

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

  # ---------------------------------------------------------------------------
  # Allow-list (intentional shadow columns)
  # ---------------------------------------------------------------------------

  defp load_allow_list do
    otp_app = Mix.Project.config()[:app]

    Application.get_env(otp_app, :catalog_parity_allow_list, [])
    |> Enum.map(fn {t, c} -> {t, c} end)
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # DB queries
  # ---------------------------------------------------------------------------

  defp managed_table_names(repo) do
    %{rows: rows} = repo.query!("SELECT tam_table_name FROM tam_table")
    MapSet.new(Enum.map(rows, fn [t] -> t end))
  end

  defp physical_columns(repo, managed_tables) do
    if MapSet.size(managed_tables) == 0 do
      MapSet.new()
    else
      table_list = MapSet.to_list(managed_tables)

      %{rows: rows} =
        repo.query!(
          "SELECT table_name, column_name " <>
            "FROM information_schema.columns " <>
            "WHERE table_schema = 'public' " <>
            "AND table_name = ANY($1::text[]) " <>
            "ORDER BY table_name, column_name",
          [table_list]
        )

      MapSet.new(Enum.map(rows, fn [t, c] -> {t, c} end))
    end
  end

  defp catalogued_columns(repo, managed_tables) do
    if MapSet.size(managed_tables) == 0 do
      MapSet.new()
    else
      table_list = MapSet.to_list(managed_tables)

      %{rows: rows} =
        repo.query!(
          "SELECT fld_table_name, fld_column_name " <>
            "FROM fld_field " <>
            "WHERE fld_table_name = ANY($1::text[]) " <>
            "ORDER BY fld_table_name, fld_column_name",
          [table_list]
        )

      MapSet.new(Enum.map(rows, fn [t, c] -> {t, c} end))
    end
  end

  # ---------------------------------------------------------------------------
  # Ghost table check (Gate-0 fix #5): every Ash.Resource.Info resource that
  # has an AshPostgres table must appear in tam_table.
  # ---------------------------------------------------------------------------

  defp ghost_table_check(repo, managed_tables) do
    otp_app = Mix.Project.config()[:app]
    domains = Application.get_env(otp_app, :ash_domains, [])

    resource_tables =
      domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.filter(&postgres_resource?/1)
      |> Enum.map(fn r -> {AshPostgres.DataLayer.Info.table(r), inspect(r)} end)
      |> Enum.filter(fn {t, _} -> is_binary(t) and byte_size(t) > 0 end)
      |> Enum.uniq_by(fn {t, _} -> t end)

    for {table_name, resource_module} <- resource_tables,
        not MapSet.member?(managed_tables, table_name) do
      # Verify the table physically exists — if the migration was never run there's
      # a missing-migration problem, not a catalog problem; report both.
      physical_exists? = table_exists_in_db?(repo, table_name)

      if physical_exists? do
        "ghost table: #{table_name} (resource #{resource_module} not in tam_table)"
      else
        "ghost table: #{table_name} (resource #{resource_module} — table not in DB or tam_table)"
      end
    end
  end

  defp postgres_resource?(resource) do
    try do
      table = AshPostgres.DataLayer.Info.table(resource)
      is_binary(table) and byte_size(table) > 0
    rescue
      _ -> false
    end
  end

  defp table_exists_in_db?(repo, table_name) do
    %{rows: rows} =
      repo.query!(
        "SELECT 1 FROM information_schema.tables " <>
          "WHERE table_schema = 'public' AND table_name = $1",
        [table_name]
      )

    rows != []
  end

  # ---------------------------------------------------------------------------
  # Resource lookup (for diagnostic "owning resource" annotation — F4)
  # ---------------------------------------------------------------------------

  defp resource_for_table(table_name) do
    otp_app = Mix.Project.config()[:app]
    domains = Application.get_env(otp_app, :ash_domains, [])

    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&postgres_resource?/1)
    |> Enum.find_value(fn r ->
      if AshPostgres.DataLayer.Info.table(r) == table_name, do: inspect(r)
    end)
  end
end
