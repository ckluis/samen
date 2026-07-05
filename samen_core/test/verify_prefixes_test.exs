defmodule SamenCore.VerifyPrefixesTest do
  @moduledoc """
  Tests for `mix samen.verify.prefixes` — verifier C2 (T1.8a, Gate-0 fix task #2).

  ## Test structure

  Two layers:

  1. **Unit layer** (`check/1` calls directly) — fast, no child process, uses
     the SQL sandbox checkout.

  2. **Exit-code layer** (`System.cmd/3` in a child OS process) — the only way
     to observe `:erlang.halt(1)` without terminating the test VM. These tests
     inject violations using a direct (non-sandbox) DB connection, spawn the
     child, then clean up.

  ## Anti-tautology probe (HARD RULE §2)

  The probe was run in a scratch copy: sabotaging
  `Mix.Tasks.Samen.Verify.Prefixes.check/1` to always return `[]` caused all
  RED PATH unit tests and both exit-code RED PATH tests to FAIL (exit 0 instead
  of 1, and empty violation lists). This confirms the tests are non-vacuous.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo

  @project_dir Path.expand("../", __DIR__)

  setup context do
    if context[:exit_code] do
      :ok
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      :ok
    end
  end

  # ============================================================
  # Green path: prefixes pass on the clean DB
  # ============================================================

  describe "green path" do
    test "prefix check passes with no violations on clean DB" do
      violations = Mix.Tasks.Samen.Verify.Prefixes.check(TestRepo)
      assert violations == [],
             "Expected no violations on clean DB, got: #{inspect(violations)}"
    end

    test "all columns in com_contact carry the com_ prefix" do
      violations = Mix.Tasks.Samen.Verify.Prefixes.check(TestRepo)
      contact_violations = Enum.filter(violations, &(&1 =~ "com_contact"))
      assert contact_violations == [],
             "Expected no prefix violations for com_contact, got: #{inspect(contact_violations)}"
    end
  end

  # ============================================================
  # RED PATH: unprefixed column
  # ============================================================

  describe "RED PATH: unprefixed column" do
    test "check/1 returns violations when an unprefixed column exists in both DB and fld_field" do
      with_direct_connection(fn conn ->
        # Add a physical column with no abbrev prefix
        Postgrex.query!(
          conn,
          "ALTER TABLE com_contact ADD COLUMN IF NOT EXISTS name_unprefixed text",
          []
        )

        # Also add a matching (bad) fld_field row
        Postgrex.query!(conn, """
        INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
        VALUES ('com_contact', 'name_unprefixed', 'name_unprefixed', 'String')
        ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
        """, [])

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(
              c,
              "DELETE FROM fld_field WHERE fld_table_name = 'com_contact' AND fld_column_name = 'name_unprefixed'",
              []
            )

            Postgrex.query!(
              c,
              "ALTER TABLE com_contact DROP COLUMN IF EXISTS name_unprefixed",
              []
            )
          end)
        end)

        violations = Mix.Tasks.Samen.Verify.Prefixes.check(TestRepo)

        assert length(violations) >= 1,
               "Expected at least 1 violation, got: #{inspect(violations)}"

        # Should flag both the physical column AND the fld_field row
        assert Enum.any?(violations, &(&1 =~ "unprefixed column")),
               "Expected 'unprefixed column' violation, got: #{inspect(violations)}"

        assert Enum.any?(violations, &(&1 =~ "unprefixed fld_field row")),
               "Expected 'unprefixed fld_field row' violation, got: #{inspect(violations)}"

        # Violations must name the table and column
        all_text = Enum.join(violations, "\n")
        assert all_text =~ "com_contact", "Violation must name the table"
        assert all_text =~ "name_unprefixed", "Violation must name the column"
        assert all_text =~ "com_", "Violation must name the expected prefix"
        assert all_text =~ "SamenCore.Support.Crm.Contact", "Violation must name the resource"
      end)
    end

    test "check/1 flags only the physical column violation when fld_field row is absent" do
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE com_contact ADD COLUMN IF NOT EXISTS raw_col text",
          []
        )

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(
              c,
              "ALTER TABLE com_contact DROP COLUMN IF EXISTS raw_col",
              []
            )
          end)
        end)

        violations = Mix.Tasks.Samen.Verify.Prefixes.check(TestRepo)

        col_violations = Enum.filter(violations, &(&1 =~ "raw_col"))
        assert length(col_violations) >= 1,
               "Expected at least 1 violation for raw_col, got: #{inspect(violations)}"

        assert Enum.any?(col_violations, &(&1 =~ "unprefixed column")),
               "Expected 'unprefixed column' violation, got: #{inspect(col_violations)}"
      end)
    end

    @tag :exit_code
    test "mix task exits 1 when an unprefixed column is present" do
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE com_contact ADD COLUMN IF NOT EXISTS name_unprefixed text",
          []
        )

        Postgrex.query!(conn, """
        INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
        VALUES ('com_contact', 'name_unprefixed', 'name_unprefixed', 'String')
        ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
        """, [])
      end)

      on_exit(fn ->
        with_direct_connection(fn conn ->
          Postgrex.query!(
            conn,
            "DELETE FROM fld_field WHERE fld_table_name = 'com_contact' AND fld_column_name = 'name_unprefixed'",
            []
          )

          Postgrex.query!(
            conn,
            "ALTER TABLE com_contact DROP COLUMN IF EXISTS name_unprefixed",
            []
          )
        end)
      end)

      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.prefixes"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "Expected exit code 1 (unprefixed column), got #{exit_code}.\nOutput: #{output}"

      assert output =~ "unprefixed",
             "Expected 'unprefixed' in output, got: #{output}"

      assert output =~ "name_unprefixed",
             "Expected 'name_unprefixed' in output, got: #{output}"
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

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
