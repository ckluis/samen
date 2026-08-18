defmodule Demo.CmsScopeCatalogParityRedPathTest do
  @moduledoc """
  Catalog-parity red path for the CMS scope (T3.5).

  Proves:
    1. All nine CMS tables (6 content + 3 E7 version) are catalogued (green path: verifier passes).
    2. Deleting a catalog row makes the verifier fail (anti-tautology probe).
    3. The pattern mirrors `Demo.IdentityCatalogParityRedPathTest` exactly.
  """
  use Demo.DataCase, async: false

  alias Demo.Repo
  import Ecto.Query

  @cms_tables ~w(
    cpg_page
    cpt_post
    cbl_block
    cmd_media
    cnv_navigation
    csm_seo_meta
    cpg_page_versions
    cpt_post_versions
    cbl_block_versions
  )

  # =========================================================================
  # Green path: all CMS tables are catalogued.
  # =========================================================================

  test "all nine CMS tables (6 content + 3 version) have catalog rows (green path)" do
    catalogued =
      Repo.all(
        from t in "tam_table",
          where: t.tam_table_name in @cms_tables,
          select: t.tam_table_name
      )

    missing = @cms_tables -- catalogued

    assert missing == [],
           "Expected all CMS tables to be catalogued, missing: #{inspect(missing)}"
  end

  test "all CMS tables have fld_field rows (columns catalogued)" do
    Enum.each(@cms_tables, fn table ->
      count =
        Repo.one(
          from f in "fld_field",
            where: f.fld_table_name == ^table,
            select: count(f.fld_column_name)
        )

      assert count > 0,
             "Table #{table} should have at least one fld_field row, got 0"
    end)
  end

  # =========================================================================
  # Anti-tautology probe: deleting a catalog row makes catalog_parity fail.
  #
  # Per scope-authoring guide §9: temporarily break the check, confirm the
  # red-path test flips to failing, then revert.
  # =========================================================================

  test "deleting a catalog row causes catalog_parity to detect the ghost table (anti-tautology)" do
    # Confirm cpg_page is currently catalogued (use raw SQL — schemaless queries need explicit select).
    {:ok, %{rows: rows_before}} =
      Repo.query("SELECT tam_table_name FROM tam_table WHERE tam_table_name = $1", ["cpg_page"])

    assert rows_before != [], "cpg_page must be in tam_table before the probe"

    # Count fld_field rows before deletion.
    {:ok, %{rows: [[field_count_before]]}} =
      Repo.query(
        "SELECT COUNT(*) FROM fld_field WHERE fld_table_name = $1",
        ["cpg_page"]
      )

    assert field_count_before > 0, "cpg_page must have field rows before probe"

    # --- SABOTAGE: delete the cpg_page catalog row ---
    # We wrap in a transaction so we can roll back after confirming the failure.
    Repo.transaction(fn ->
      {:ok, _} =
        Repo.query("DELETE FROM tam_table WHERE tam_table_name = $1", ["cpg_page"])

      # Verify deletion happened.
      {:ok, %{rows: rows_after_delete}} =
        Repo.query("SELECT tam_table_name FROM tam_table WHERE tam_table_name = $1", ["cpg_page"])

      assert rows_after_delete == [], "cpg_page should be removed from tam_table"

      # Now run catalog_parity (the Mix task reads from the DB directly).
      # We simulate the parity check inline using the Mix task check/1:
      alias Mix.Tasks.Samen.Verify.CatalogParity
      violations = CatalogParity.check(Demo.Repo)

      # The parity check should detect the missing catalog row.
      refute violations == [],
             "Expected catalog_parity to detect missing cpg_page catalog row"

      assert Enum.any?(violations, fn v ->
               String.contains?(to_string(v), "cpg_page")
             end),
             "Expected a violation mentioning cpg_page, got: #{inspect(violations)}"

      # --- REVERT: roll back the deletion ---
      Repo.rollback(:probe_done)
    end)

    # After rollback, the catalog row is restored.
    {:ok, %{rows: rows_restored}} =
      Repo.query("SELECT tam_table_name FROM tam_table WHERE tam_table_name = $1", ["cpg_page"])

    assert rows_restored != [], "cpg_page catalog row must be restored after probe rollback"
  end

  test "catalog_parity would detect orphaned fld_field rows (anti-tautology probe)" do
    # A ghost column (a fld_field row for a column that doesn't exist in the resource)
    # should be detected. Insert a fake column and verify it would be flagged.
    Repo.transaction(fn ->
      # Insert a fake field row (use raw SQL — schemaless Ecto insert_all needs all columns).
      {:ok, _} =
        Repo.query(
          "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) " <>
            "VALUES ($1, $2, $3, $4)",
          ["cpg_page", "cpg_fake_ghost_column", "fake_ghost_column", "String"]
        )

      # Simulate the ghost-column check using the Mix task.
      alias Mix.Tasks.Samen.Verify.CatalogParity
      violations = CatalogParity.check(Demo.Repo)

      # The parity check should detect the orphaned column.
      refute violations == [],
             "Expected catalog_parity to detect orphaned fld_field row for cpg_fake_ghost_column"

      assert Enum.any?(violations, fn v ->
               s = to_string(v)
               String.contains?(s, "cpg_fake_ghost_column") or
                 String.contains?(s, "cpg_page")
             end),
             "Expected a violation about cpg_fake_ghost_column or cpg_page, got: #{inspect(violations)}"

      Repo.rollback(:probe_done)
    end)
  end
end
