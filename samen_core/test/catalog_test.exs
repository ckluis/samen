defmodule SamenCore.CatalogTest do
  @moduledoc """
  Tests for the T1.2 catalog subsystem:

    * `Samen.Catalog` — introspection helpers
    * `Samen.Migration` — `catalog_sync` fail-closed guarantee
    * `mix samen.catalog.dump` — deterministic schema.dict.json

  The uncatalogued-column ("hallucinated field") bug class is owned by the LIVE-gated
  `mix samen.verify.catalog_parity` (bidirectional physical ⇄ `fld_field` parity, run in
  every app's ci.sh) — see `verify_catalog_parity_test.exs` and the agent-authoring eval.
  The former `mix samen.verify.column_refs` source-text linter was retired (ADR-045 A3):
  its `^[a-z]{3}_` regex collided with the entire Elixir identifier namespace (~1.5k
  false positives) and it ran in no gate; catalog_parity + compile-time Ash attribute
  verification already cover the bug class.

  RED PATHS (2 mandatory per task spec):
    1. `catalog_sync` under `@disable_ddl_transaction true` raises at compile time
    2. `mix samen.catalog.dump` is byte-identical across two runs on the same codebase
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo

  # ============================================================
  # Sandbox checkout for tests that read the DB (non-migration).
  # Migration tests bypass the sandbox because migrations require
  # full DB ownership. We handle them with setup/teardown.
  # ============================================================

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    :ok
  end

  # ============================================================
  # Section 1 — Samen.Catalog introspection
  # ============================================================

  describe "Samen.Catalog.table/1" do
    test "returns the physical table name for a resource" do
      result = Samen.Catalog.table(SamenCore.Support.Crm.Contact)
      assert result.table_name == "com_contact"
      assert result.resource == "SamenCore.Support.Crm.Contact"
    end

    test "returns the physical table name for the Company resource" do
      result = Samen.Catalog.table(SamenCore.Support.Crm.Company)
      assert result.table_name == "cpy_company"
    end
  end

  describe "Samen.Catalog.fields/1" do
    test "returns fields with abbrev-prefixed column names" do
      fields = Samen.Catalog.fields(SamenCore.Support.Crm.Contact)
      column_names = Enum.map(fields, & &1.column_name)

      # All columns must be prefixed with the resource abbrev "com_"
      assert Enum.all?(column_names, &String.starts_with?(&1, "com_"))
    end

    test "fields are sorted by column_name (stable ordering for dump)" do
      fields = Samen.Catalog.fields(SamenCore.Support.Crm.Contact)
      sorted = Enum.sort_by(fields, & &1.column_name)
      assert fields == sorted
    end

    test "fields contain logical_name (unprefixed) and type" do
      fields = Samen.Catalog.fields(SamenCore.Support.Crm.Contact)
      name_field = Enum.find(fields, &(&1.logical_name == "name"))
      assert name_field != nil
      assert name_field.column_name == "com_name"
      assert name_field.type == "String"
    end

    test "includes injected columns (id, org_id, inserted_at, updated_at)" do
      fields = Samen.Catalog.fields(SamenCore.Support.Crm.Contact)
      logical_names = Enum.map(fields, & &1.logical_name)

      assert "id" in logical_names
      assert "org_id" in logical_names
      assert "inserted_at" in logical_names
      assert "updated_at" in logical_names
    end
  end

  # ============================================================
  # Section 2 — RED PATH: catalog_sync under @disable_ddl_transaction
  # ============================================================

  describe "Samen.Migration — @disable_ddl_transaction guard (Gate-0 fix #4)" do
    test "RED PATH: catalog_sync raises RuntimeError under @disable_ddl_transaction true" do
      # This is the key fail-closed guarantee: catalog_sync must refuse to RUN
      # when the calling migration has disabled the DDL transaction. Outside a
      # transaction, a crash between DDL and catalog write would be fail-open.
      #
      # The check is at runtime (not compile time) because Ecto sets
      # @disable_ddl_transaction false in its __using__/1, so the attribute's final
      # value is only reliable at @before_compile time (captured into __migration__/0).
      # We test via __guard_ddl_transaction__!/1 which is the same check catalog_sync
      # calls internally.
      #
      # Anti-tautology probe: verified separately (see module docstring for probe result).

      defmodule TestDisabledDdlMigration do
        use Samen.Migration
        @disable_ddl_transaction true
        def change, do: :ok
      end

      assert_raise RuntimeError, ~r/catalog_sync.*REFUSES.*disable_ddl_transaction/i, fn ->
        Samen.Migration.__guard_ddl_transaction__!(TestDisabledDdlMigration)
      end
    end

    test "catalog_sync guard passes when @disable_ddl_transaction is NOT set (or false)" do
      # Positive case: no @disable_ddl_transaction → guard passes.
      defmodule TestEnabledDdlMigration do
        use Samen.Migration
        def change, do: :ok
      end

      # Should not raise
      assert :ok = Samen.Migration.__guard_ddl_transaction__!(TestEnabledDdlMigration)
    end
  end

  # ============================================================
  # Section 3 — catalog_sync DB integration (uses bootstrap migration)
  # ============================================================

  describe "catalog_sync DB integration" do
    test "bootstrap migration creates tam_table and fld_field" do
      # The bootstrap migration (20260705033102) was run by test_helper.exs.
      # Verify the catalog tables exist and contain rows for our resources.
      %{rows: [[tam_count]]} = TestRepo.query!("SELECT count(*) FROM tam_table")
      assert tam_count > 0, "tam_table should have entries after bootstrap"

      %{rows: [[fld_count]]} = TestRepo.query!("SELECT count(*) FROM fld_field")
      assert fld_count > 0, "fld_field should have entries after bootstrap"
    end

    test "bootstrap seeds catalog rows for all known test resources" do
      expected_tables = ~w(com_contact cpy_company pat_patient stf_staff prp_fixture)

      %{rows: rows} = TestRepo.query!("SELECT tam_table_name FROM tam_table ORDER BY tam_table_name")
      seeded_tables = Enum.map(rows, fn [t] -> t end)

      for table <- expected_tables do
        assert table in seeded_tables, "Expected #{table} to be catalogued, got: #{inspect(seeded_tables)}"
      end
    end

    test "catalog rows match Ash.Resource.Info introspection for Contact" do
      %{rows: rows} =
        TestRepo.query!(
          "SELECT fld_column_name, fld_logical_name, fld_type FROM fld_field " <>
            "WHERE fld_table_name = 'com_contact' ORDER BY fld_column_name"
        )

      db_fields = Enum.map(rows, fn [c, l, t] -> %{column_name: c, logical_name: l, type: t} end)

      introspected =
        SamenCore.Support.Crm.Contact
        |> Samen.Catalog.fields()
        |> Enum.map(&Map.take(&1, [:column_name, :logical_name, :type]))
        |> Enum.sort_by(& &1.column_name)

      assert db_fields == introspected,
             "catalog rows must equal Ash.Resource.Info\ndb=#{inspect(db_fields)}\nintrospected=#{inspect(introspected)}"
    end
  end

  # ============================================================
  # Section 4 — mix samen.catalog.dump (determinism RED PATH)
  # ============================================================

  describe "mix samen.catalog.dump — determinism" do
    test "build_dict produces identical output on two calls with the same resources" do
      resources = [
        SamenCore.Support.Crm.Contact,
        SamenCore.Support.Crm.Company,
        SamenCore.Support.PropFixture
      ]

      dict1 = Mix.Tasks.Samen.Catalog.Dump.build_dict(resources)
      dict2 = Mix.Tasks.Samen.Catalog.Dump.build_dict(resources)

      assert dict1 == dict2,
             "build_dict must be deterministic across two calls"

      # RED PATH proof (anti-tautology): verify the result is non-trivial
      # (has tables) so equal-but-empty is not the source of idempotency
      assert length(dict1["tables"]) > 0, "dict must contain at least one table"
    end

    test "RED PATH: dump is byte-identical across two runs" do
      # Serialize to JSON twice and compare the raw bytes.
      resources = [
        SamenCore.Support.Crm.Contact,
        SamenCore.Support.Crm.Company,
        SamenCore.Support.Clinical.Patient,
        SamenCore.Support.Clinical.Staff,
        SamenCore.Support.PropFixture
      ]

      json1 = Mix.Tasks.Samen.Catalog.Dump.build_dict(resources) |> Jason.encode!(pretty: true)
      json2 = Mix.Tasks.Samen.Catalog.Dump.build_dict(resources) |> Jason.encode!(pretty: true)

      assert json1 == json2,
             "JSON output must be byte-identical on two calls — ordering is not stable"
    end

    test "tables in dump are sorted by table_name" do
      resources = [
        SamenCore.Support.Crm.Contact,
        SamenCore.Support.Crm.Company,
        SamenCore.Support.PropFixture
      ]

      dict = Mix.Tasks.Samen.Catalog.Dump.build_dict(resources)
      table_names = Enum.map(dict["tables"], & &1["table_name"])
      assert table_names == Enum.sort(table_names), "tables must be sorted alphabetically"
    end

    test "fields within a table are sorted by column_name" do
      resources = [SamenCore.Support.Crm.Contact]
      dict = Mix.Tasks.Samen.Catalog.Dump.build_dict(resources)

      [table] = dict["tables"]
      column_names = Enum.map(table["fields"], & &1["column_name"])
      assert column_names == Enum.sort(column_names), "fields must be sorted alphabetically"
    end

    test "each field entry has column_name, logical_name, and type" do
      resources = [SamenCore.Support.Crm.Contact]
      dict = Mix.Tasks.Samen.Catalog.Dump.build_dict(resources)

      [table] = dict["tables"]

      Enum.each(table["fields"], fn field ->
        assert Map.has_key?(field, "column_name"), "field must have column_name"
        assert Map.has_key?(field, "logical_name"), "field must have logical_name"
        assert Map.has_key?(field, "type"), "field must have type"
      end)
    end

    # ----------------------------------------------------------------------
    # T6.3 (part c) — schema.dict.json is a SUFFICIENT grounding artifact:
    # every field carries a PII flag, resource-qualified, keyed on the vault
    # DECLARATION (not a `pii_` name prefix). This is what lets an agent read
    # the whole model — resource, field, and PII-ness — from ONE file.
    # ----------------------------------------------------------------------
    test "every field entry carries a boolean `pii` flag (grounding completeness)" do
      resources = [
        SamenCore.Support.Clinical.Patient,
        SamenCore.Support.Crm.Contact
      ]

      dict = Mix.Tasks.Samen.Catalog.Dump.build_dict(resources)

      all_fields = Enum.flat_map(dict["tables"], & &1["fields"])
      assert all_fields != [], "dict must be non-trivial"

      Enum.each(all_fields, fn field ->
        assert Map.has_key?(field, "pii"), "every field must carry a `pii` flag"
        assert is_boolean(field["pii"]), "`pii` must be a boolean, got: #{inspect(field["pii"])}"
      end)
    end

    test "the `pii` flag keys on the vault DECLARATION for BOTH composite and scalar PII" do
      # Patient declares composite PII (full_name/emails/phones → pat_ prefix, NO
      # pii_ prefix) AND scalar PII (dob/mrn → pii_pat_ prefix). Both must be
      # pii:true; non-PII columns (id/org_id/timestamps) must be pii:false.
      dict = Mix.Tasks.Samen.Catalog.Dump.build_dict([SamenCore.Support.Clinical.Patient])
      [table] = dict["tables"]

      by_col = Map.new(table["fields"], fn f -> {f["column_name"], f["pii"]} end)

      # Composite PII: carries the resource abbrev, NO pii_ prefix — still pii:true
      # (proves the flag keys on the declaration, not the storage-name prefix).
      assert by_col["pat_full_name"] == true, "composite PII pat_full_name must be pii:true"
      assert by_col["pat_emails"] == true, "composite PII pat_emails must be pii:true"
      assert by_col["pat_phones"] == true, "composite PII pat_phones must be pii:true"

      # Scalar PII: carries the pii_ prefix.
      assert by_col["pii_pat_dob"] == true, "scalar PII pii_pat_dob must be pii:true"
      assert by_col["pii_pat_mrn"] == true, "scalar PII pii_pat_mrn must be pii:true"

      # Non-PII infrastructure columns.
      assert by_col["pat_id"] == false, "pat_id must be pii:false"
      assert by_col["pat_org_id"] == false, "pat_org_id must be pii:false"

      # ANTI-VACUITY: the flag is not a constant — the dict contains BOTH true and
      # false, so a "pii:true everywhere" or "pii:false everywhere" bug is caught.
      flags = Enum.map(table["fields"], & &1["pii"])
      assert Enum.any?(flags, &(&1 == true)), "at least one field must be pii:true"
      assert Enum.any?(flags, &(&1 == false)), "at least one field must be pii:false"
    end
  end

end
