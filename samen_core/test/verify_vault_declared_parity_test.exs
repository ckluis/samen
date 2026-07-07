defmodule SamenCore.VerifyVaultDeclaredParityTest do
  @moduledoc """
  Tests for `mix samen.verify.vault_declared_parity` — verifier C6 (Phase-3
  cross-scope review fix F3.1). Closes the free-text-🔒 de-vault gap: a `pii_*`
  column left in the DB while the resource dropped the vault route.

  ## Test structure

  Two layers, matching `verify_catalog_parity_test.exs`:

  1. **Unit layer** (`check/3` direct call) — fast, uses a direct DB connection so
     injected DDL is visible.
  2. **Exit-code layer** (`System.cmd/3` child process) — the only way to observe
     `:erlang.halt(1)` without terminating the test VM.

  ## Anti-tautology probe (HARD RULE §2)

  Stated + run in a scratch copy (see the task report `scope-review-fixes.md`):
  neutering `check/3` to always return `[]` made every RED-PATH test FAIL (empty
  violations / exit 0 instead of 1). Confirms the red paths are non-vacuous.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo
  alias Mix.Tasks.Samen.Verify.VaultDeclaredParity, as: Task

  @project_dir Path.expand("../", __DIR__)

  setup context do
    if context[:exit_code] do
      # Exit-code tests manage their own DB connection (outside sandbox) so the
      # child mix process can see the injected state.
      :ok
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      :ok
    end
  end

  # The set of routed vault columns, computed from the same domains the task uses.
  defp routed do
    domains = Application.get_env(:samen_core, :ash_domains, [])
    resources = Samen.Catalog.resource_modules(domains)
    Task.routed_vault_columns(resources)
  end

  # ============================================================
  # Green path: parity holds on the correctly-routed DB
  # ============================================================

  describe "green path" do
    test "clean DB: every pii_* column is declared-routed → no violations" do
      violations = Task.check(TestRepo, routed())

      assert violations == [],
             "Expected no violations on a clean DB, got: #{inspect(violations)}"
    end

    test "the known scalar vault columns are in the routed set (positive control)" do
      r = routed()

      assert MapSet.member?(r, {"pat_patient", "pii_pat_dob"}),
             "pii_pat_dob must be a declared vault route, got routed=#{inspect(r)}"

      assert MapSet.member?(r, {"pat_patient", "pii_pat_mrn"}),
             "pii_pat_mrn must be a declared vault route"
    end
  end

  # ============================================================
  # RED PATH 1: a pii_* column with NO matching route (the de-vault shape)
  #
  # This simulates de-vaulting: the DB still carries a `pii_<abbrev>_<name>`
  # column, but no resource routes it (dropped `pii do` route). Fail-closed.
  # ============================================================

  describe "RED PATH: de-vaulted / unrouted pii_* column" do
    test "check/3 flags a pii_* column with no declared route" do
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE pat_patient ADD COLUMN IF NOT EXISTS pii_pat_ghost text",
          []
        )

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(c, "ALTER TABLE pat_patient DROP COLUMN IF EXISTS pii_pat_ghost", [])
          end)
        end)

        violations = Task.check(TestRepo, routed())

        assert length(violations) >= 1,
               "Expected at least 1 de-vault violation, got: #{inspect(violations)}"

        [v | _] = Enum.filter(violations, &(&1 =~ "pii_pat_ghost"))
        assert v =~ "de-vaulted PII column", "Violation must name the class, got: #{inspect(v)}"
        assert v =~ "pat_patient", "Violation must name the table"
      end)
    end

    test "the de-vault MISMATCH (route dropped from routed set, column still in DB) is caught" do
      # This is the exact F3.1 scenario the T3.14 probe exploited: the resource
      # drops the `pii do` route (so the column leaves the routed set) while the
      # DB still carries the pii_ column. We model the "route dropped" side by
      # removing pii_pat_mrn from the routed set — the DB column is untouched.
      routed_without_mrn = MapSet.delete(routed(), {"pat_patient", "pii_pat_mrn"})

      violations = Task.check(TestRepo, routed_without_mrn)

      mrn_vs = Enum.filter(violations, &(&1 =~ "pii_pat_mrn"))

      assert length(mrn_vs) >= 1,
             "Dropping the mrn route while pii_pat_mrn stays in the DB must be caught, " <>
               "got: #{inspect(violations)}"
    end

    @tag :exit_code
    test "mix task exits 1 when a pii_* column is unrouted" do
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE pat_patient ADD COLUMN IF NOT EXISTS pii_pat_ghost text",
          []
        )
      end)

      on_exit(fn ->
        with_direct_connection(fn conn ->
          Postgrex.query!(conn, "ALTER TABLE pat_patient DROP COLUMN IF EXISTS pii_pat_ghost", [])
        end)
      end)

      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.vault_declared_parity"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "Expected exit 1 (unrouted pii_ column), got #{exit_code}.\nOutput: #{output}"

      assert output =~ "de-vaulted PII column",
             "Expected 'de-vaulted PII column' in output, got: #{output}"

      assert output =~ "pii_pat_ghost", "Expected the column name in output, got: #{output}"
    end
  end

  # ============================================================
  # RED PATH 2: fail-closed on empty resource discovery (vacuous check)
  # ============================================================

  describe "RED PATH: fail-closed on empty domains" do
    @tag :exit_code
    test "mix task exits 1 when ash_domains is empty (vacuous parity)" do
      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.vault_declared_parity"],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}, {"SAMEN_EMPTY_ASH_DOMAINS", "1"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "Expected exit 1 on empty domains (vacuous), got #{exit_code}.\nOutput: #{output}"

      assert output =~ "ZERO resources",
             "Expected the fail-closed diagnostic, got: #{output}"
    end
  end

  # ============================================================
  # Allow-list: an intentional non-Ash pii_* column is not flagged
  # ============================================================

  describe "allow-list" do
    test "an allow-listed pii_* column does not produce a violation" do
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE pat_patient ADD COLUMN IF NOT EXISTS pii_pat_shad text",
          []
        )
      end)

      on_exit(fn ->
        with_direct_connection(fn conn ->
          Postgrex.query!(conn, "ALTER TABLE pat_patient DROP COLUMN IF EXISTS pii_pat_shad", [])
        end)
      end)

      allow = MapSet.new([{"pat_patient", "pii_pat_shad"}])
      violations = Task.check(TestRepo, routed(), allow)

      refute Enum.any?(violations, &(&1 =~ "pii_pat_shad")),
             "Allow-listed column must not be flagged, got: #{inspect(violations)}"
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp with_direct_connection(fun) do
    raw_config =
      TestRepo.config()
      |> Keyword.drop([
        :pool,
        :pool_size,
        :telemetry_prefix,
        :installed_extensions,
        :otp_app,
        :migration_primary_key,
        :default_prefix
      ])

    {:ok, conn} = Postgrex.start_link(raw_config)

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end
end
