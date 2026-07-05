defmodule S06Verify.CatalogParityTest do
  @moduledoc """
  Acceptance tests for S0.6 — verifier harness + catalog_parity v0.

  Tests are split into two layers:

  1. **Unit-style** (`check/1` calls) — call the verifier's `check/1` helper
     directly. Fast; no child process. Used for the "passes on a correct DB"
     assertion and for verifying that violations are described with the right
     column names.

  2. **Exit-code layer** (`System.cmd/3` in child OS process) — drive the full
     `mix samen.verify.catalog_parity` task in a subprocess to assert that exit
     code = 1 on violations. This is the only way to test `:erlang.halt/1`
     without terminating the test VM.

  All tests run serially (async: false) because they share the `samen_spike_s06_test`
  database schema, which they manipulate by running real migrations.
  """
  use ExUnit.Case, async: false

  alias S06Verify.Repo

  alias S06Verify.Migrations.{
    Bootstrap,
    AddUncataloguedColumn,
    InsertOrphanCatalogRow
  }

  @v_bootstrap 1
  @v_add_uncatalogued 2
  @v_insert_orphan 3

  # Mix project root — used by the System.cmd exit-code tests.
  @spike_dir Path.expand("../", __DIR__)

  setup do
    reset_schema!()
    run(@v_bootstrap, Bootstrap)
    :ok
  end

  # --- migration helpers ---

  defp reset_schema! do
    for tbl <- ~w(com_contact fld_field tam_table schema_migrations) do
      Repo.query!("DROP TABLE IF EXISTS #{tbl} CASCADE")
    end
  end

  defp run(version, mod), do: Ecto.Migrator.up(Repo, version, mod, log: false)
  defp rollback(version, mod), do: Ecto.Migrator.down(Repo, version, mod, log: false)

  # ====================================================================
  # GREEN PATH: parity passes on a correctly-catalogued DB
  # ====================================================================

  test "parity passes when storage and catalog are in sync" do
    violations = Mix.Tasks.Samen.Verify.CatalogParity.check(Repo)
    assert violations == [],
           "Expected no violations, got: #{inspect(violations)}"
  end

  # ====================================================================
  # RED PATH 1: uncatalogued column
  # A physical column exists in the table but has no fld_field row.
  # ====================================================================

  test "RED PATH: uncatalogued column produces a violation naming the column" do
    run(@v_add_uncatalogued, AddUncataloguedColumn)

    violations = Mix.Tasks.Samen.Verify.CatalogParity.check(Repo)

    assert length(violations) == 1,
           "Expected exactly 1 violation, got: #{inspect(violations)}"

    [v] = violations
    assert v =~ "uncatalogued column",
           "Violation should say 'uncatalogued column', got: #{inspect(v)}"

    assert v =~ "com_contact",
           "Violation should name the table 'com_contact', got: #{inspect(v)}"

    assert v =~ "com_phone",
           "Violation should name the column 'com_phone', got: #{inspect(v)}"
  end

  # ====================================================================
  # RED PATH 2: orphan fld_field row
  # A fld_field row exists but the physical column does not.
  # ====================================================================

  test "RED PATH: orphan fld_field row produces a violation naming the row" do
    run(@v_insert_orphan, InsertOrphanCatalogRow)

    violations = Mix.Tasks.Samen.Verify.CatalogParity.check(Repo)

    assert length(violations) == 1,
           "Expected exactly 1 violation, got: #{inspect(violations)}"

    [v] = violations
    assert v =~ "orphan fld_field row",
           "Violation should say 'orphan fld_field row', got: #{inspect(v)}"

    assert v =~ "com_contact",
           "Violation should name the table 'com_contact', got: #{inspect(v)}"

    assert v =~ "com_old_field",
           "Violation should name the column 'com_old_field', got: #{inspect(v)}"
  end

  # ====================================================================
  # RED PATH 3: both violations simultaneously
  # ====================================================================

  test "RED PATH: both uncatalogued column and orphan row are reported together" do
    run(@v_add_uncatalogued, AddUncataloguedColumn)
    run(@v_insert_orphan, InsertOrphanCatalogRow)

    violations = Mix.Tasks.Samen.Verify.CatalogParity.check(Repo)

    assert length(violations) == 2,
           "Expected 2 violations, got: #{inspect(violations)}"

    assert Enum.any?(violations, &(&1 =~ "uncatalogued column"))
    assert Enum.any?(violations, &(&1 =~ "orphan fld_field row"))
  end

  # ====================================================================
  # EXIT-CODE LAYER: drive the full mix task in a child process.
  #
  # The child process connects to the same `samen_spike_s06_test` database.
  # We manipulate the schema before spawning so the child sees violations.
  #
  # NOTE: System.cmd/3 captures stdout/stderr; we check exit status.
  # The task writes to :stdio which flows through the child's stdout.
  # ====================================================================

  @tag :exit_code
  test "mix task exits 0 when catalog is in sync" do
    {output, exit_code} =
      System.cmd("mix", ["samen.verify.catalog_parity"],
        cd: @spike_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "Expected exit 0 (no violations), got #{exit_code}.\nOutput: #{output}"

    assert output =~ "OK",
           "Expected OK banner, got: #{output}"
  end

  @tag :exit_code
  test "mix task exits 1 with diagnostic when uncatalogued column present" do
    # Inject the violation before spawning the child.
    run(@v_add_uncatalogued, AddUncataloguedColumn)

    {output, exit_code} =
      System.cmd("mix", ["samen.verify.catalog_parity"],
        cd: @spike_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 1,
           "Expected exit 1 (violation), got #{exit_code}.\nOutput: #{output}"

    assert output =~ "uncatalogued column",
           "Output should say 'uncatalogued column', got: #{output}"

    assert output =~ "com_phone",
           "Output should name 'com_phone', got: #{output}"
  end

  @tag :exit_code
  test "mix task exits 1 with diagnostic when orphan fld_field row present" do
    run(@v_insert_orphan, InsertOrphanCatalogRow)

    {output, exit_code} =
      System.cmd("mix", ["samen.verify.catalog_parity"],
        cd: @spike_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 1,
           "Expected exit 1 (violation), got #{exit_code}.\nOutput: #{output}"

    assert output =~ "orphan fld_field row",
           "Output should say 'orphan fld_field row', got: #{output}"

    assert output =~ "com_old_field",
           "Output should name 'com_old_field', got: #{output}"
  end

  # ====================================================================
  # Rollback sanity: after rolling back the violation migrations the
  # verifier passes again (prove violations are not sticky).
  # ====================================================================

  test "parity passes again after rolling back the uncatalogued column" do
    run(@v_add_uncatalogued, AddUncataloguedColumn)

    violations_before = Mix.Tasks.Samen.Verify.CatalogParity.check(Repo)
    assert length(violations_before) == 1

    rollback(@v_add_uncatalogued, AddUncataloguedColumn)

    violations_after = Mix.Tasks.Samen.Verify.CatalogParity.check(Repo)
    assert violations_after == [],
           "Expected no violations after rollback, got: #{inspect(violations_after)}"
  end

  test "parity passes again after rolling back the orphan catalog row" do
    run(@v_insert_orphan, InsertOrphanCatalogRow)

    violations_before = Mix.Tasks.Samen.Verify.CatalogParity.check(Repo)
    assert length(violations_before) == 1

    rollback(@v_insert_orphan, InsertOrphanCatalogRow)

    violations_after = Mix.Tasks.Samen.Verify.CatalogParity.check(Repo)
    assert violations_after == [],
           "Expected no violations after rollback, got: #{inspect(violations_after)}"
  end
end
