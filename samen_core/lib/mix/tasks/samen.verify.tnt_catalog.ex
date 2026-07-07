defmodule Mix.Tasks.Samen.Verify.TntCatalog do
  @shortdoc "Verify tenant custom-field + custom-object catalog parity (Tier-1 tnt_field + Tier-2 tnt_object/tnt_record)."

  @moduledoc """
  `mix samen.verify.tnt_catalog` — Tier-1 custom-field catalog parity (plan T3.8
  (c); vision doc §core "Every custom field is catalogued").

  The `tnt`-namespaced sibling of `mix samen.verify.catalog_parity` (which covers
  the *system* columns in `fld_field`). This verifier covers the *tenant* custom
  fields in `tnt_field`. The two catalog surfaces are deliberately distinct
  (vision doc §limits "System is provable; tenant is best-effort"):

    * `fld_field` — system columns, org-agnostic, compile-time provable.
    * `tnt_field` — tenant custom fields, org-scoped, validated-at-write.

  ## What it checks

  1. **`tnt_field` → `tam_table` (no orphan custom field on a ghost table):**
     every `tnt_field` row must reference a table that exists in `tam_table`. A
     custom field defined for a table the system doesn't know about is a catalog
     inconsistency — the tenant catalog can only extend real, catalogued tables.

  2. **bag keys → `tnt_field` (no invisible custom field — the T3.8 red path):**
     for each managed table that carries an `xxx_custom` jsonb bag, every key that
     appears in any row's bag MUST have a matching `tnt_field` row for that row's
     org. A bag key with no `tnt_field` definition is an **uncatalogued custom
     field** — customization that rotted past the catalog (the exact failure the
     validated-at-write change exists to prevent; this verifier is the durable CI
     backstop that catches any row that slipped in another way, e.g. a raw SQL
     write bypassing Ash).

  Check 2 is skipped for a table with no bag column (nothing to scan).

  3. **Tier-2 objects/records catalogued (T3.9):** every custom-object *field* (a
     `tnt_field` row on an object's synthetic table `tnt$obj$<key>`) and every
     `tnt_record` must reference a defined `tnt_object` for that org. An orphan
     object-field or an orphan record is Tier-2 customization that rotted past the
     tenant-tier object catalog. Skipped when the Tier-2 tables aren't bootstrapped.

  ## Diagnostics

      FAIL: samen.verify.tnt_catalog found 2 violation(s):
        • orphan tnt_field: org=<uuid> table=ghost_tbl field=foo (table not in tam_table)
        • uncatalogued custom field: per_person.loyalty_tier (org=<uuid>, no tnt_field row)

  ## Repo discovery

  Same as `catalog_parity`: reads `:ecto_repos` or `--repo MyApp.Repo`.

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`).
  """

  use Mix.Task

  @task_name "samen.verify.tnt_catalog"

  # The bag column suffix the base macro emits: `<abbrev>_custom`. We detect a bag
  # column by this suffix on a managed table.
  @bag_suffix "_custom"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} = OptionParser.parse(args, strict: [repo: :string])
    repos = resolve_repos(opts)

    violations =
      Enum.flat_map(repos, fn repo ->
        ensure_repo_started!(repo)
        check(repo)
      end)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Run the tnt-catalog parity check against `repo`; return a list of violation
  strings. Separated from `run/1` so the test suite can call it without halting.
  """
  def check(repo) do
    unless tnt_field_exists?(repo) do
      # No tnt_field table ⇒ Tier-1 not bootstrapped in this repo ⇒ nothing to
      # check. (Do NOT fail: a host that hasn't opted into Tier-1 is valid.)
      []
    else
      orphan_check(repo) ++ bag_key_check(repo) ++ tnt_object_check(repo)
    end
  end

  # -------------------------------------------------------------------------
  # Check 3 (T3.9): Tier-2 custom objects are catalogued.
  #
  #   (a) every custom-object FIELD (a tnt_field row whose table is the object's
  #       synthetic table name, `tnt$obj$<key>`) references a defined tnt_object;
  #   (b) every tnt_record references a defined tnt_object.
  #
  # Skipped when the Tier-2 tables aren't bootstrapped in this repo.
  # -------------------------------------------------------------------------

  defp tnt_object_check(repo) do
    if tnt_object_exists?(repo) do
      object_prefix = Samen.CustomObjects.object_table_prefix()
      prefix_len = String.length(object_prefix)

      defined_objects = defined_object_keys(repo)

      # (a) orphan object-field: a tnt_field on tnt$obj$<key> with no tnt_object.
      %{rows: field_rows} =
        repo.query!(
          "SELECT tnt_org_id::text, tnt_table_name, tnt_field_name FROM tnt_field " <>
            "WHERE tnt_table_name LIKE $1 || '%'",
          [object_prefix]
        )

      field_violations =
        for [org, table, field] <- field_rows,
            key = String.slice(table, prefix_len..-1//1),
            not MapSet.member?(defined_objects, {org, key}) do
          "orphan custom-object field: org=#{org} object=#{key} field=#{field} " <>
            "(no tnt_object row)"
        end

      # (b) orphan record: a tnt_record whose object_key has no tnt_object.
      record_violations =
        if tnt_record_exists?(repo) do
          %{rows: rec_rows} =
            repo.query!("SELECT DISTINCT tnr_org_id::text, tnr_object_key FROM tnt_record")

          for [org, key] <- rec_rows, not MapSet.member?(defined_objects, {org, key}) do
            "orphan tnt_record: org=#{org} object=#{key} (no tnt_object row)"
          end
        else
          []
        end

      field_violations ++ record_violations
    else
      []
    end
  end

  defp defined_object_keys(repo) do
    %{rows: rows} = repo.query!("SELECT tnt_org_id::text, tnt_object_key FROM tnt_object")
    MapSet.new(rows, fn [org, key] -> {org, key} end)
  end

  defp tnt_object_exists?(repo), do: table_exists?(repo, "tnt_object")
  defp tnt_record_exists?(repo), do: table_exists?(repo, "tnt_record")

  # -------------------------------------------------------------------------
  # Check 1: tnt_field → tam_table (no orphan custom field on a ghost table)
  # -------------------------------------------------------------------------

  defp orphan_check(repo) do
    managed = managed_table_names(repo)
    object_prefix = Samen.CustomObjects.object_table_prefix()

    %{rows: rows} =
      repo.query!(
        "SELECT tnt_org_id::text, tnt_table_name, tnt_field_name FROM tnt_field ORDER BY tnt_table_name, tnt_field_name"
      )

    # A field on a synthetic custom-object table (`tnt$obj$<key>`) is a Tier-2
    # object field, NOT a Tier-1 field on a physical table — it is checked by
    # `tnt_object_check/1` (against tnt_object), not against tam_table. Exempt it
    # here so the two catalog checks don't fight.
    for [org, table, field] <- rows,
        not String.starts_with?(table, object_prefix),
        not MapSet.member?(managed, table) do
      "orphan tnt_field: org=#{org} table=#{table} field=#{field} (table not in tam_table)"
    end
  end

  # -------------------------------------------------------------------------
  # Check 2: bag keys → tnt_field (no invisible custom field — the T3.8 red path)
  # -------------------------------------------------------------------------

  defp bag_key_check(repo) do
    managed = managed_table_names(repo)

    managed
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.flat_map(fn table ->
      case bag_column(repo, table) do
        nil -> []
        bag_col -> scan_bag(repo, table, bag_col)
      end
    end)
  end

  # Scan every row's bag: collect (org_id, key) pairs present in bags, then reject
  # any pair with no tnt_field row.
  defp scan_bag(repo, table, bag_col) do
    org_col = org_column(repo, table)

    if is_nil(org_col) do
      # A bag on an org-less table (e.g. an anchor) — can't org-scope the check;
      # skip (Tier-1 is org-scoped by definition; an org-less bag is out of scope).
      []
    else
      # jsonb_object_keys over each row, joined with the row's org.
      sql =
        "SELECT DISTINCT #{org_col}::text AS org, jsonb_object_keys(#{bag_col}) AS key " <>
          "FROM #{table} WHERE #{bag_col} IS NOT NULL"

      %{rows: rows} = repo.query!(sql)

      defined = defined_fields(repo, table)

      for [org, key] <- rows, not MapSet.member?(defined, {org, key}) do
        "uncatalogued custom field: #{table}.#{key} (org=#{org}, no tnt_field row)"
      end
    end
  end

  defp defined_fields(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT tnt_org_id::text, tnt_field_name FROM tnt_field WHERE tnt_table_name = $1",
        [table]
      )

    MapSet.new(rows, fn [org, field] -> {org, field} end)
  end

  # -------------------------------------------------------------------------
  # DB helpers
  # -------------------------------------------------------------------------

  defp tnt_field_exists?(repo), do: table_exists?(repo, "tnt_field")

  defp table_exists?(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name=$1",
        [table]
      )

    rows != []
  end

  defp managed_table_names(repo) do
    %{rows: rows} = repo.query!("SELECT tam_table_name FROM tam_table")
    MapSet.new(Enum.map(rows, fn [t] -> t end))
  end

  # The bag column on a table, if any: `<abbrev>_custom`.
  defp bag_column(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema='public' AND table_name=$1 AND column_name LIKE '%' || $2",
        [table, @bag_suffix]
      )

    case rows do
      [[col] | _] -> col
      _ -> nil
    end
  end

  # The org_id column on a table (`<abbrev>_org_id`), if any.
  defp org_column(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema='public' AND table_name=$1 AND column_name LIKE '%_org_id'",
        [table]
      )

    case rows do
      [[col] | _] -> col
      _ -> nil
    end
  end

  # -------------------------------------------------------------------------
  # Repo resolution (mirrors catalog_parity)
  # -------------------------------------------------------------------------

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
