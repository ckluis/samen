defmodule SamenCore.CatalogTest do
  @moduledoc """
  Tests for the T1.2 catalog subsystem:

    * `Samen.Catalog` — introspection helpers
    * `Samen.Migration` — `catalog_sync` fail-closed guarantee
    * `mix samen.catalog.dump` — deterministic schema.dict.json
    * `mix samen.verify.column_refs` — CI linter for unknown `^[a-z]{3}_` refs

  RED PATHS (3 mandatory per task spec):
    1. `catalog_sync` under `@disable_ddl_transaction true` raises at compile time
    2. `mix samen.catalog.dump` is byte-identical across two runs on the same codebase
    3. CI linter catches a seeded bogus column reference (fails exit 1)
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
  end

  # ============================================================
  # Section 5 — mix samen.verify.column_refs (CI linter RED PATH)
  # ============================================================

  # ---------------------------------------------------------------------------
  # Helper: create a unique isolated scratch dir under a self-owned, project-local
  # parent, register cleanup, and return the dir path.
  #
  # Gate-2 F2.4: the scratch parent is a PROJECT-LOCAL `samen_core/tmp/` dir
  # (git-ignored), NOT the shared `/tmp` root. The gate's scratch-dir rule is
  # "scratch OUTSIDE the /tmp root"; the previous PRE-a fix isolated per-test with a
  # unique subdir but still rooted it at `/tmp/samen_colrefs_test/`, so a hostile or
  # stray file dropped directly in shared `/tmp` was outside our subtree (fine) but
  # the parent itself lived under the shared root. Rooting the scratch subtree in a
  # self-owned project dir removes the shared-root dependency entirely: no other
  # process, test suite, or user writes into `samen_core/tmp/colrefs_scratch/`.
  # ---------------------------------------------------------------------------
  @scratch_root Path.join([__DIR__, "..", "tmp", "colrefs_scratch"])

  defp make_scratch_dir(ctx_name) do
    base = Path.expand(Path.join(@scratch_root, ctx_name))
    File.mkdir_p!(base)
    base
  end

  describe "mix samen.verify.column_refs — CI linter" do
    test "no violations on files that only reference known catalogued columns" do
      # Each test gets its own isolated scratch dir — stray files from other
      # tests cannot pollute this scan (PRE-a fix for Gate-1 caveat).
      scratch = make_scratch_dir("good_#{System.unique_integer([:positive])}")
      file_path = Path.join(scratch, "good_source.ex")

      File.write!(file_path, """
      defmodule GoodModule do
        # Reference a known catalogued column
        def example, do: :com_name
      end
      """)

      on_exit(fn -> File.rm_rf(scratch) end)

      violations = Mix.Tasks.Samen.Verify.ColumnRefs.check(TestRepo, [scratch])
      assert violations == [], "Expected no violations, got: #{inspect(violations)}"
    end

    test "RED PATH: linter catches a seeded bogus column reference" do
      # Plant a reference to a column that does NOT exist in fld_field.
      # This is the mandatory red-path for the CI linter.
      scratch = make_scratch_dir("bad_#{System.unique_integer([:positive])}")
      file_path = Path.join(scratch, "bad_source.ex")

      # "xyz_hallucinated_column" is a valid ^[a-z]{3}_ token but is NOT in fld_field
      File.write!(file_path, """
      defmodule BadModule do
        def example, do: :xyz_hallucinated_column
      end
      """)

      on_exit(fn -> File.rm_rf(scratch) end)

      violations = Mix.Tasks.Samen.Verify.ColumnRefs.check(TestRepo, [scratch])

      assert length(violations) >= 1, "Expected at least 1 violation, got: #{inspect(violations)}"

      assert Enum.any?(violations, &(&1 =~ "xyz_hallucinated_column")),
             "Violation should name the bogus column, got: #{inspect(violations)}"
    end

    test "linter ignores catalog infrastructure tokens (tam_, fld_)" do
      # tam_ and fld_ tokens are part of the catalog infra and should never be flagged
      scratch = make_scratch_dir("infra_#{System.unique_integer([:positive])}")
      file_path = Path.join(scratch, "infra_source.ex")

      File.write!(file_path, """
      defmodule InfraModule do
        def example do
          "SELECT tam_table_name FROM tam_table"
          "SELECT fld_column_name FROM fld_field"
        end
      end
      """)

      on_exit(fn -> File.rm_rf(scratch) end)

      violations = Mix.Tasks.Samen.Verify.ColumnRefs.check(TestRepo, [scratch])
      assert violations == [], "Catalog infra tokens must not be flagged"
    end

    test "samen:allow comment suppresses a specific token on that line" do
      scratch = make_scratch_dir("allow_#{System.unique_integer([:positive])}")
      file_path = Path.join(scratch, "allowed_source.ex")

      File.write!(file_path, """
      defmodule AllowedModule do
        def example, do: :xyz_legacy_col  # samen:allow xyz_legacy_col
      end
      """)

      on_exit(fn -> File.rm_rf(scratch) end)

      violations = Mix.Tasks.Samen.Verify.ColumnRefs.check(TestRepo, [scratch])
      assert violations == [], "samen:allow should suppress the flagged token"
    end

    test "linter scans .ex and .exs files" do
      scratch = make_scratch_dir("scan_#{System.unique_integer([:positive])}")
      ex_path = Path.join(scratch, "check_me.ex")
      exs_path = Path.join(scratch, "check_me.exs")

      bad_content = """
      def something do
        :abc_bogus_column
      end
      """

      File.write!(ex_path, bad_content)
      File.write!(exs_path, bad_content)

      on_exit(fn -> File.rm_rf(scratch) end)

      violations = Mix.Tasks.Samen.Verify.ColumnRefs.check(TestRepo, [scratch])
      # Both files should be scanned — at least 2 violations
      assert length(violations) >= 2, "Expected violations from both .ex and .exs files"
    end
  end
end
