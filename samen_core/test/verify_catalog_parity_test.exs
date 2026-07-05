defmodule SamenCore.VerifyCatalogParityTest do
  @moduledoc """
  Tests for `mix samen.verify.catalog_parity` — verifier C1 (T1.8a).

  ## Test structure

  Two layers:

  1. **Unit layer** (`check/1` calls via direct function call) — fast, no child
     process, uses the SQL sandbox checkout.

  2. **Exit-code layer** (`System.cmd/3` in a child OS process) — the only way to
     observe `:erlang.halt(1)` without terminating the test VM. These tests inject
     violations using a direct (non-sandbox) DB connection, spawn the child, then
     clean up.

  ## Anti-tautology probe (HARD RULE §2)

  The probe is stated in the test module docstring and was run in a scratch copy:
  neutering `Samen.Verifier.halt_if_violations/2` to always return `:ok` (never
  halt) and sabotaging `check/1` to always return `[]` caused:
    - All RED PATH unit tests to FAIL (assertions on violation lists became empty)
    - Both exit-code RED PATH tests to FAIL (exit 0 instead of 1)
  This confirms the red-path tests are non-vacuous.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo

  # Root of the samen_core mix project — used for the System.cmd exit-code tests.
  # __DIR__ in a test file is the test/ directory; one level up is the project root.
  @project_dir Path.expand("../", __DIR__)

  # ============================================================
  # Sandbox setup for unit tests
  # ============================================================

  setup context do
    if context[:exit_code] do
      # Exit-code tests manage their own DB connection (outside sandbox) so
      # the child mix process can see the injected state.
      :ok
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      :ok
    end
  end

  # ============================================================
  # Green path: parity passes on the correctly-bootstrapped DB
  # ============================================================

  describe "green path" do
    test "parity check passes with no violations on clean DB" do
      violations = Mix.Tasks.Samen.Verify.CatalogParity.check(TestRepo)
      assert violations == [],
             "Expected no violations on a clean DB, got: #{inspect(violations)}"
    end
  end

  # ============================================================
  # RED PATH 1: uncatalogued column
  # ============================================================

  describe "RED PATH: uncatalogued column" do
    test "check/1 returns a violation naming the uncatalogued column and owning resource" do
      with_direct_connection(fn conn ->
        Postgrex.query!(conn, "ALTER TABLE com_contact ADD COLUMN IF NOT EXISTS com_phone text", [])

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(c, "ALTER TABLE com_contact DROP COLUMN IF EXISTS com_phone", [])
          end)
        end)

        violations = Mix.Tasks.Samen.Verify.CatalogParity.check(TestRepo)

        assert length(violations) >= 1,
               "Expected at least 1 violation, got: #{inspect(violations)}"

        uncatalogued_vs = Enum.filter(violations, &(&1 =~ "uncatalogued column"))
        assert length(uncatalogued_vs) >= 1, "Expected uncatalogued column violation"

        [v | _] = uncatalogued_vs
        assert v =~ "com_contact", "Violation must name the table, got: #{inspect(v)}"
        assert v =~ "com_phone", "Violation must name the column, got: #{inspect(v)}"

        # Gate-0 fix F4: owning resource must be named in the diagnostic
        assert v =~ "SamenCore.Support.Crm.Contact",
               "Violation must name the owning resource, got: #{inspect(v)}"
      end)
    end

    @tag :exit_code
    test "mix task exits 1 when uncatalogued column is present" do
      with_direct_connection(fn conn ->
        Postgrex.query!(conn, "ALTER TABLE com_contact ADD COLUMN IF NOT EXISTS com_phone text", [])
      end)

      on_exit(fn ->
        with_direct_connection(fn conn ->
          Postgrex.query!(conn, "ALTER TABLE com_contact DROP COLUMN IF EXISTS com_phone", [])
        end)
      end)

      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.catalog_parity"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "Expected exit code 1 (uncatalogued column), got #{exit_code}.\nOutput: #{output}"

      assert output =~ "uncatalogued column",
             "Expected 'uncatalogued column' in output, got: #{output}"

      assert output =~ "com_phone",
             "Expected 'com_phone' in output, got: #{output}"
    end
  end

  # ============================================================
  # RED PATH 2: orphan fld_field row
  # ============================================================

  describe "RED PATH: orphan fld_field row" do
    test "check/1 returns a violation for an orphan catalog row" do
      with_direct_connection(fn conn ->
        Postgrex.query!(conn, """
        INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
        VALUES ('com_contact', 'com_old_field', 'old_field', 'String')
        ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
        """, [])

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(
              c,
              "DELETE FROM fld_field WHERE fld_table_name = 'com_contact' AND fld_column_name = 'com_old_field'",
              []
            )
          end)
        end)

        violations = Mix.Tasks.Samen.Verify.CatalogParity.check(TestRepo)

        assert length(violations) >= 1,
               "Expected at least 1 violation, got: #{inspect(violations)}"

        orphan_vs = Enum.filter(violations, &(&1 =~ "orphan fld_field row"))
        assert length(orphan_vs) >= 1, "Expected orphan fld_field row violation"

        [v | _] = orphan_vs
        assert v =~ "com_contact", "Violation must name the table, got: #{inspect(v)}"
        assert v =~ "com_old_field", "Violation must name the column, got: #{inspect(v)}"
      end)
    end

    @tag :exit_code
    test "mix task exits 1 when orphan fld_field row is present" do
      with_direct_connection(fn conn ->
        Postgrex.query!(conn, """
        INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
        VALUES ('com_contact', 'com_old_field', 'old_field', 'String')
        ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
        """, [])
      end)

      on_exit(fn ->
        with_direct_connection(fn conn ->
          Postgrex.query!(
            conn,
            "DELETE FROM fld_field WHERE fld_table_name = 'com_contact' AND fld_column_name = 'com_old_field'",
            []
          )
        end)
      end)

      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.catalog_parity"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "Expected exit code 1 (orphan fld_field row), got #{exit_code}.\nOutput: #{output}"

      assert output =~ "orphan fld_field row",
             "Expected 'orphan fld_field row' in output, got: #{output}"

      assert output =~ "com_old_field",
             "Expected 'com_old_field' in output, got: #{output}"
    end
  end

  # ============================================================
  # RED PATH 3: ghost table (Gate-0 fix #5 — resource in Ash.Domain.Info
  #             but absent from tam_table)
  # ============================================================

  describe "RED PATH: ghost table (Gate-0 fix #5)" do
    test "check/1 returns a violation when a resource's table is missing from tam_table" do
      with_direct_connection(fn conn ->
        # Delete the tam_table entry for com_contact — making it a ghost resource
        Postgrex.query!(
          conn,
          "DELETE FROM tam_table WHERE tam_table_name = 'com_contact'",
          []
        )

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(c, """
            INSERT INTO tam_table (tam_table_name, tam_resource)
            VALUES ('com_contact', 'SamenCore.Support.Crm.Contact')
            ON CONFLICT (tam_table_name) DO NOTHING
            """, [])
          end)
        end)

        violations = Mix.Tasks.Samen.Verify.CatalogParity.check(TestRepo)

        ghost_vs = Enum.filter(violations, &(&1 =~ "ghost table"))
        assert length(ghost_vs) >= 1,
               "Expected at least one ghost table violation, got: #{inspect(violations)}"

        [v | _] = ghost_vs
        assert v =~ "com_contact", "Violation must name the table, got: #{inspect(v)}"

        assert v =~ "SamenCore.Support.Crm.Contact",
               "Violation must name the resource module, got: #{inspect(v)}"
      end)
    end

    @tag :exit_code
    test "mix task exits 1 when a resource's table is missing from tam_table" do
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "DELETE FROM tam_table WHERE tam_table_name = 'com_contact'",
          []
        )
      end)

      on_exit(fn ->
        with_direct_connection(fn conn ->
          Postgrex.query!(conn, """
          INSERT INTO tam_table (tam_table_name, tam_resource)
          VALUES ('com_contact', 'SamenCore.Support.Crm.Contact')
          ON CONFLICT (tam_table_name) DO NOTHING
          """, [])
        end)
      end)

      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.catalog_parity"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "Expected exit code 1 (ghost table), got #{exit_code}.\nOutput: #{output}"

      assert output =~ "ghost table",
             "Expected 'ghost table' in output, got: #{output}"
    end
  end

  # ============================================================
  # Allow-list: intentional shadow columns are not flagged
  # ============================================================

  describe "allow-list for intentional shadow columns" do
    test "an allow-listed column does not produce an uncatalogued violation" do
      # Put the allow-list in app config for this test.
      prev = Application.get_env(:samen_core, :catalog_parity_allow_list, [])

      Application.put_env(:samen_core, :catalog_parity_allow_list, [
        {"com_contact", "com_shadow_col"}
      ])

      on_exit(fn ->
        Application.put_env(:samen_core, :catalog_parity_allow_list, prev)

        with_direct_connection(fn conn ->
          Postgrex.query!(
            conn,
            "ALTER TABLE com_contact DROP COLUMN IF EXISTS com_shadow_col",
            []
          )
        end)
      end)

      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE com_contact ADD COLUMN IF NOT EXISTS com_shadow_col text",
          []
        )
      end)

      violations = Mix.Tasks.Samen.Verify.CatalogParity.check(TestRepo)

      assert violations == [] or
               not Enum.any?(violations, &(&1 =~ "com_shadow_col")),
             "Allow-listed column must not produce a violation, got: #{inspect(violations)}"
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  # Opens a direct (non-sandbox) Postgrex connection to the samen_core_test DB
  # so that DDL injected here is immediately visible to child mix processes.
  # The TestRepo is configured with pool: Ecto.Adapters.SQL.Sandbox in test —
  # we strip the pool config and connect directly to Postgrex instead.
  defp with_direct_connection(fun) do
    raw_config =
      TestRepo.config()
      |> Keyword.drop([:pool, :pool_size, :telemetry_prefix, :installed_extensions,
                        :otp_app, :migration_primary_key, :default_prefix])

    {:ok, conn} = Postgrex.start_link(raw_config)

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end
end
