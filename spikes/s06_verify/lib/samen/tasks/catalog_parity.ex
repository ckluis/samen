defmodule Mix.Tasks.Samen.Verify.CatalogParity do
  @shortdoc "Verify catalog parity: every storage column has a fld_field row, and vice-versa."

  @moduledoc """
  `mix samen.verify.catalog_parity` — verifier C1 (plan §C).

  ## What it checks

  Both directions of the column ⇄ `fld_field` invariant:

  1. **Storage → catalog** (no uncatalogued column): for every physical column in
     `information_schema.columns` across tables known to `tam_table`, there must be
     a matching `fld_field` row.

  2. **Catalog → storage** (no orphan catalog row): for every `fld_field` row,
     the named physical column must exist in `information_schema.columns`.

  ## Diagnostics

  Violations are printed by name before the task exits with code 1:

      FAIL: samen.verify.catalog_parity found 2 violation(s):
        • uncatalogued column: com_contact.com_phone
        • orphan fld_field row: com_contact.com_old_field

  ## Configuration

  The task reads the repo from `Application.get_env(:s06_verify, :verify_repo)`.
  In production (`samen_core`) this will read from the app's configured ecto repos.
  For the spike we default to `S06Verify.Repo`.

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed).
  """

  use Mix.Task

  @task_name "samen.verify.catalog_parity"

  @impl Mix.Task
  def run(_args) do
    # Ensure the application is started (compiles config, sets env).
    Mix.Task.run("app.start")

    # In test environments the Application supervisor may have start_repo?: false,
    # meaning the Repo was not supervised. Start it directly if not already running.
    repo = Application.get_env(:s06_verify, :verify_repo, S06Verify.Repo)
    ensure_repo_started!(repo)

    violations = check(repo)
    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  defp ensure_repo_started!(repo) do
    case repo.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "Could not start repo #{inspect(repo)}: #{inspect(reason)}"
    end
  end

  @doc """
  Run the parity check against `repo` and return a (possibly empty) list of
  human-readable violation strings.

  Separated from `run/1` so the test suite can call it directly and inspect
  violations without triggering `:erlang.halt/1`.
  """
  def check(repo) do
    # Step 1: which tables are under Samen management?
    managed_tables = managed_table_names(repo)

    # Step 2: physical columns from information_schema for those tables.
    physical = physical_columns(repo, managed_tables)

    # Step 3: catalog rows from fld_field for those tables.
    catalogued = catalogued_columns(repo, managed_tables)

    # Step 4: compute violations in both directions.
    uncatalogued =
      MapSet.difference(physical, catalogued)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(fn {t, c} -> "uncatalogued column: #{t}.#{c}" end)

    orphaned =
      MapSet.difference(catalogued, physical)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(fn {t, c} -> "orphan fld_field row: #{t}.#{c}" end)

    uncatalogued ++ orphaned
  end

  # --- private helpers ---

  # Tables recorded in tam_table (Samen-managed tables only).
  defp managed_table_names(repo) do
    %{rows: rows} = repo.query!("SELECT tam_table_name FROM tam_table")
    MapSet.new(Enum.map(rows, fn [t] -> t end))
  end

  # Physical columns from information_schema for the given table names.
  # We skip internal Postgres system columns (ctid, xmin, etc.) by requiring
  # the column to be in the `public` schema and belong to a managed table.
  defp physical_columns(repo, managed_tables) do
    if MapSet.size(managed_tables) == 0 do
      MapSet.new()
    else
      # Build a parameterized ANY($1::text[]) query
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

  # Catalog rows from fld_field for the given table names.
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
end
