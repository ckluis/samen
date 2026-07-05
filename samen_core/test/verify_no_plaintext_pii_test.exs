defmodule SamenCore.VerifyNoPlaintextPiiTest do
  @moduledoc """
  Tests for `mix samen.verify.no_plaintext_pii` — verifier C5, **CI MODE** (T1.8d).

  ## Structure

  Four layers:

    1. **Green path** — the CI-mode invariant passes on the correctly-bootstrapped
       kernel test app (`run/1` + the mix task exit-0 subprocess).

    2. **Red paths (unit)** — `check/1` returns a `:violation` finding for each
       seeded leak, driven through a DIRECT (non-sandbox) DB connection so the
       injected DDL is visible both to the unit `check/1` call and to the
       exit-code subprocess:

         * (RP-A) a seeded plaintext PII-typed column on an audit-row projection
           (`rvl_reveal_audit.rvl_ssn text`) — the task's mandated red path (b);
         * (RP-A2) an unrecognised plaintext column on an audit projection that
           does NOT hit the name heuristic — the fail-CLOSED allow-list half;
         * (RP-B) a vault field whose STORAGE TYPE leaks plaintext: the catalog
           advertises a vault-routed column as a plaintext PII type (`Date`) — the
           task's mandated red path (a) at the catalog surface;
         * (RP-B2) a vault-routed column whose PHYSICAL type is not a token string
           (a plaintext `date` column) — the DB-tier half of red path (a);
         * (RP-C) `opentelemetry_ecto` present with `db_statement` NOT `:disabled`
           — the config-level assertion (c).

    3. **Exemption (clause (d))** — a registered `non_pii!` plaintext column on an
       audit projection is LISTED as `:exempt`, NOT failed.

    4. **Exit-code layer** — `System.cmd/3` child process, the only way to observe
       `:erlang.halt(1)` without killing the test VM.

  ## Extensibility (tier registry)

  A dedicated test drives `run(tiers: [...])` with a custom tier module and
  asserts a `:post_shred`-mode tier is INERT in CI mode — proving the registry the
  Phase-2 oracle (T2.9) extends works as designed.

  ## Anti-tautology probe (HARD RULE §2)

  See the module-level `@anti_tautology` test and the report — the probe sabotaged
  the guard in a scratch copy and confirmed the red paths flip to green (fail).
  """

  use ExUnit.Case, async: false

  alias SamenCore.TestRepo
  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.{Finding, Context}
  alias Samen.NonPii

  @project_dir Path.expand("../", __DIR__)

  # Only the four domains that are known-clean under the CI-mode invariant. The
  # PiiClassifyDomain deliberately carries plain PII-named columns (C4 fixtures) —
  # but those are NOT vault-routed and NOT on audit projections, so they do not
  # concern C5. We scan the vault-carrying domains for the green path.
  @clean_domains [
    SamenCore.Support.Crm,
    SamenCore.Support.Clinical,
    SamenCore.Support.PropDomain
  ]

  setup context do
    if context[:exit_code] do
      :ok
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      :ok
    end
  end

  # ==========================================================================
  # Green path
  # ==========================================================================

  describe "green path" do
    test "CI-mode invariant passes with no violations on the clean kernel app" do
      findings = run_check(domains: @clean_domains)
      violations = NoPlaintextPii.violations(findings)

      assert violations == [],
             "Expected no violations on the clean kernel app, got:\n" <>
               Enum.map_join(violations, "\n", &Finding.format/1)
    end

    test "the default tier roster covers vault, audit, catalog, and log-telemetry" do
      names = Enum.map(NoPlaintextPii.default_tiers(), & &1.tier_name())
      assert :vault_declarations in names
      assert :audit_rows in names
      assert :catalog in names
      assert :log_telemetry in names
    end
  end

  # ==========================================================================
  # RED PATH A: seeded plaintext PII column on an audit-row projection
  # ==========================================================================

  describe "RED PATH (a/b): plaintext PII column on an audit-row projection" do
    @tag :red_path
    test "check/1 flags a PII-named plaintext column added to rvl_reveal_audit" do
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE rvl_reveal_audit ADD COLUMN IF NOT EXISTS rvl_ssn text",
          []
        )

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(c, "ALTER TABLE rvl_reveal_audit DROP COLUMN IF EXISTS rvl_ssn", [])
          end)
        end)

        findings = run_check(domains: @clean_domains)
        violations = NoPlaintextPii.violations(findings)

        audit_v = Enum.filter(violations, &(&1.tier == :audit_rows))

        assert audit_v != [],
               "Expected an audit_rows violation for the seeded rvl_ssn column, got: " <>
                 inspect(Enum.map(violations, &Finding.format/1))

        text = Enum.map_join(audit_v, "\n", &Finding.format/1)
        assert text =~ "rvl_reveal_audit.rvl_ssn", "Violation must name the offending column"
        assert text =~ "PII identifier", "Expected the name-gate reason"
      end)
    end

    @tag :red_path
    test "check/1 fail-CLOSES on an unrecognised plaintext audit column (allow-list gate)" do
      with_direct_connection(fn conn ->
        # A plaintext column whose name does NOT hit the PII heuristic — the
        # fail-closed allow-list half must still flag it (a new text column on an
        # audit surface is a leak until reviewed).
        Postgrex.query!(
          conn,
          "ALTER TABLE era_erasure_report ADD COLUMN IF NOT EXISTS era_freeform_note text",
          []
        )

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(
              c,
              "ALTER TABLE era_erasure_report DROP COLUMN IF EXISTS era_freeform_note",
              []
            )
          end)
        end)

        findings = run_check(domains: @clean_domains)
        violations = NoPlaintextPii.violations(findings)

        note_v =
          Enum.filter(violations, &(&1.tier == :audit_rows and &1.subject =~ "era_freeform_note"))

        assert note_v != [],
               "Expected a fail-closed allow-list violation for era_freeform_note, got: " <>
                 inspect(Enum.map(violations, &Finding.format/1))

        assert Enum.map_join(note_v, "\n", &Finding.format/1) =~ "allow-list"
      end)
    end
  end

  # ==========================================================================
  # RED PATH B: a vault field whose storage type leaks plaintext
  # ==========================================================================

  describe "RED PATH (a): a vault field whose storage type leaks plaintext" do
    @tag :red_path
    test "check/1 flags a vault column advertised in the catalog as a plaintext type" do
      # pat_full_name is a vault-routed column, correctly typed VaultField in
      # fld_field. Drift its catalog type to a plaintext PII type ("FullName") —
      # the catalog surface now advertises a vault column as plaintext.
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "UPDATE fld_field SET fld_type = 'FullName' " <>
            "WHERE fld_table_name = 'pat_patient' AND fld_column_name = 'pat_full_name'",
          []
        )

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(
              c,
              "UPDATE fld_field SET fld_type = 'Samen.Type.VaultField' " <>
                "WHERE fld_table_name = 'pat_patient' AND fld_column_name = 'pat_full_name'",
              []
            )
          end)
        end)

        findings = run_check(domains: @clean_domains)
        violations = NoPlaintextPii.violations(findings)

        cat_v =
          Enum.filter(violations, &(&1.tier == :catalog and &1.subject =~ "pat_full_name"))

        assert cat_v != [],
               "Expected a catalog violation for the plaintext-typed vault column, got: " <>
                 inspect(Enum.map(violations, &Finding.format/1))

        assert Enum.map_join(cat_v, "\n", &Finding.format/1) =~ "token type"
      end)
    end

    @tag :red_path
    test "check/1 flags a vault column whose PHYSICAL type is not a token string" do
      # Directly test the VaultDeclarations tier's physical-type gate: a vault
      # column materialized to VaultField but whose PHYSICAL column is a plaintext
      # `date` (not a varchar/text token column). We simulate by pointing the tier
      # at a repo where such a column exists: add a scratch date column and route
      # a fixture at it via an explicit column set.
      #
      # The honest way: the physical-type gate rejects a non-string udt. We add a
      # `date`-typed physical column to pat_patient with a vault-routed NAME shape
      # and assert the DB-tier scan would reject it. Since the transformer always
      # produces VaultField+text for real declarations, we exercise the gate via
      # the Context + a hand-built resource-column set is not available; instead we
      # assert the tier's physical-type predicate directly through a seeded column.
      with_direct_connection(fn conn ->
        # Change the physical type of an EXISTING vault column to `date` — now the
        # domain column is not a token string column.
        Postgrex.query!(
          conn,
          "ALTER TABLE pat_patient ALTER COLUMN pii_pat_dob TYPE date USING NULL",
          []
        )

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(
              c,
              "ALTER TABLE pat_patient ALTER COLUMN pii_pat_dob TYPE text USING pii_pat_dob::text",
              []
            )
          end)
        end)

        findings = run_check(domains: @clean_domains)
        violations = NoPlaintextPii.violations(findings)

        dob_v =
          Enum.filter(
            violations,
            &(&1.tier == :vault_declarations and &1.subject =~ "pii_pat_dob")
          )

        assert dob_v != [],
               "Expected a vault_declarations violation for the non-token physical type, got: " <>
                 inspect(Enum.map(violations, &Finding.format/1))

        assert Enum.map_join(dob_v, "\n", &Finding.format/1) =~ "token string column"
      end)
    end
  end

  # ==========================================================================
  # RED PATH C: opentelemetry_ecto present with db_statement not disabled
  # ==========================================================================

  describe "RED PATH (c): opentelemetry_ecto config assertion" do
    @tag :red_path
    test "flags when opentelemetry_ecto is present and db_statement is not disabled" do
      # Inject the dep via the Context :deps option (no real OTel install needed).
      findings =
        run_check(
          domains: @clean_domains,
          deps: [:opentelemetry_ecto],
          # No :samen_core :opentelemetry_ecto config set → db_statement is nil.
          tiers: [Samen.NoPlaintextPii.Tiers.LogTelemetry]
        )

      violations = NoPlaintextPii.violations(findings)

      assert violations != [],
             "Expected a log_telemetry violation when opentelemetry_ecto is present without " <>
               "db_statement: :disabled, got none"

      assert Enum.map_join(violations, "\n", &Finding.format/1) =~ "db_statement"
    end

    test "passes when opentelemetry_ecto is present WITH db_statement: :disabled" do
      prev = Application.get_env(:samen_core, :opentelemetry_ecto)
      Application.put_env(:samen_core, :opentelemetry_ecto, db_statement: :disabled)

      on_exit(fn ->
        if prev do
          Application.put_env(:samen_core, :opentelemetry_ecto, prev)
        else
          Application.delete_env(:samen_core, :opentelemetry_ecto)
        end
      end)

      findings =
        run_check(
          domains: @clean_domains,
          deps: [:opentelemetry_ecto],
          tiers: [Samen.NoPlaintextPii.Tiers.LogTelemetry]
        )

      assert NoPlaintextPii.violations(findings) == [],
             "Expected no violation when db_statement: :disabled is configured"
    end

    test "passes when opentelemetry_ecto is NOT a dependency (leak surface absent)" do
      findings =
        run_check(
          domains: @clean_domains,
          deps: [:ecto_sql, :ash],
          tiers: [Samen.NoPlaintextPii.Tiers.LogTelemetry]
        )

      assert NoPlaintextPii.violations(findings) == []
    end
  end

  # ==========================================================================
  # Clause (d): registered non_pii! columns are exempt-but-listed
  # ==========================================================================

  describe "clause (d): non_pii! exemption is listed, not failed" do
    test "a registered non_pii! plaintext audit column is :exempt, not :violation" do
      # Add a plaintext PII-named column to an audit projection AND register it as
      # a review-gated non_pii! override. It must be LISTED as :exempt, not failed.
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE rvl_reveal_audit ADD COLUMN IF NOT EXISTS rvl_legacy_email text",
          []
        )

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(
              c,
              "ALTER TABLE rvl_reveal_audit DROP COLUMN IF EXISTS rvl_legacy_email",
              []
            )
          end)
        end)

        entry = %NonPii.Entry{
          table_name: "rvl_reveal_audit",
          column_name: "rvl_legacy_email",
          cleared_by: "alice@example.com",
          reviewed_by: "bob@example.com",
          reason: "Legacy operator-contact column reviewed as non-subject-PII.",
          subject_column: "rvl_subject_id"
        }

        findings = run_check(domains: @clean_domains, non_pii_entries: [entry])

        violations = NoPlaintextPii.violations(findings)
        exempts = NoPlaintextPii.exemptions(findings)

        refute Enum.any?(violations, &(&1.subject =~ "rvl_legacy_email")),
               "A registered non_pii! column must NOT be a violation"

        assert Enum.any?(exempts, &(&1.subject =~ "rvl_legacy_email")),
               "A registered non_pii! column must be LISTED as :exempt, got exempts: " <>
                 inspect(Enum.map(exempts, &Finding.format/1))
      end)
    end

    test "a self-review non_pii! entry does NOT exempt (still a violation)" do
      with_direct_connection(fn conn ->
        Postgrex.query!(
          conn,
          "ALTER TABLE rvl_reveal_audit ADD COLUMN IF NOT EXISTS rvl_ssn2 text",
          []
        )

        on_exit(fn ->
          with_direct_connection(fn c ->
            Postgrex.query!(c, "ALTER TABLE rvl_reveal_audit DROP COLUMN IF EXISTS rvl_ssn2", [])
          end)
        end)

        # Same cleared_by and reviewed_by → invalid clearance (distinct-party rule).
        self_entry = %NonPii.Entry{
          table_name: "rvl_reveal_audit",
          column_name: "rvl_ssn2",
          cleared_by: "alice@example.com",
          reviewed_by: "alice@example.com",
          reason: "self-cleared (invalid)",
          subject_column: "rvl_subject_id"
        }

        findings = run_check(domains: @clean_domains, non_pii_entries: [self_entry])
        violations = NoPlaintextPii.violations(findings)

        assert Enum.any?(violations, &(&1.subject =~ "rvl_ssn2")),
               "A self-review non_pii! must NOT exempt — the column must still fail closed"
      end)
    end
  end

  # ==========================================================================
  # Extensibility: the tier registry the Phase-2 oracle (T2.9) extends
  # ==========================================================================

  defmodule PostShredOnlyTier do
    @moduledoc false
    @behaviour Samen.NoPlaintextPii.Tier
    alias Samen.NoPlaintextPii.Finding
    @impl true
    def tier_name, do: :fake_post_shred
    @impl true
    def mode, do: :post_shred
    @impl true
    def describe, do: "a post-shred tier (Phase 2) — inert in CI mode"
    @impl true
    def check(_context), do: [Finding.violation(:fake_post_shred, "x", "should not run in CI mode")]
  end

  defmodule ExtraCiTier do
    @moduledoc false
    @behaviour Samen.NoPlaintextPii.Tier
    alias Samen.NoPlaintextPii.Finding
    @impl true
    def tier_name, do: :extra_ci
    @impl true
    def mode, do: :ci
    @impl true
    def describe, do: "a custom CI tier registered via the registry"
    @impl true
    def check(_context), do: [Finding.violation(:extra_ci, "y", "custom tier ran")]
  end

  describe "extensible tier registry (Phase-2 T2.9 seam)" do
    test "a :post_shred tier is INERT in CI mode" do
      findings =
        run_check(domains: @clean_domains, tiers: [PostShredOnlyTier])

      assert findings == [],
             "A :post_shred tier must not run in CI mode, got: " <>
               inspect(Enum.map(findings, &Finding.format/1))
    end

    test "a custom :ci tier IS run (registry is open for extension)" do
      findings = run_check(domains: @clean_domains, tiers: [ExtraCiTier])

      assert Enum.any?(findings, &(&1.tier == :extra_ci)),
             "A registered custom :ci tier must run"
    end

    test "a tier that raises fails CLOSED (its crash is a violation)" do
      defmodule CrashTier do
        @behaviour Samen.NoPlaintextPii.Tier
        @impl true
        def tier_name, do: :crash
        @impl true
        def mode, do: :ci
        @impl true
        def describe, do: "crashes"
        @impl true
        def check(_), do: raise("boom")
      end

      findings = run_check(domains: @clean_domains, tiers: [CrashTier])
      violations = NoPlaintextPii.violations(findings)

      assert Enum.any?(violations, &(&1.tier == :crash)),
             "A raising tier must produce a fail-closed violation"
    end
  end

  # ==========================================================================
  # Fail-closed: no repo configured
  # ==========================================================================

  test "DB-tiers fail CLOSED when no repo is available" do
    # Hand-build a context with an explicitly nil repo and drive the DB tiers
    # directly (run/1 -> Context.build/1 would fall back to the configured repo).
    context = %Context{
      repo: nil,
      resources: [],
      vault_routed: MapSet.new([{"pat_patient", "pat_full_name"}]),
      non_pii_exempt: MapSet.new(),
      deps: []
    }

    findings =
      [Samen.NoPlaintextPii.Tiers.AuditRows, Samen.NoPlaintextPii.Tiers.Catalog]
      |> Enum.flat_map(fn tier -> tier.check(context) end)

    violations = NoPlaintextPii.violations(findings)

    assert violations != [], "DB tiers must fail closed with no repo"
    assert Enum.all?(violations, &(&1.detail =~ "fail closed" or &1.detail =~ "no repo"))
  end

  # ==========================================================================
  # Exit-code layer (subprocess)
  # ==========================================================================

  @tag :exit_code
  test "mix task exits 0 on the clean app" do
    {output, exit_code} =
      System.cmd(
        "mix",
        ["samen.verify.no_plaintext_pii", "--domain", "SamenCore.Support.Clinical"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 0, "Expected exit 0 on the clean app, got #{exit_code}.\nOutput: #{output}"
    assert output =~ "OK", "Expected OK banner, got: #{output}"
  end

  @tag :exit_code
  test "mix task exits 1 with a seeded plaintext PII column on an audit projection" do
    with_direct_connection(fn conn ->
      Postgrex.query!(
        conn,
        "ALTER TABLE rvl_reveal_audit ADD COLUMN IF NOT EXISTS rvl_ssn text",
        []
      )
    end)

    on_exit(fn ->
      with_direct_connection(fn conn ->
        Postgrex.query!(conn, "ALTER TABLE rvl_reveal_audit DROP COLUMN IF EXISTS rvl_ssn", [])
      end)
    end)

    {output, exit_code} =
      System.cmd(
        "mix",
        ["samen.verify.no_plaintext_pii", "--domain", "SamenCore.Support.Clinical"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 1,
           "Expected exit 1 (seeded plaintext PII column), got #{exit_code}.\nOutput: #{output}"

    assert output =~ "rvl_ssn", "Expected the offending column in output, got: #{output}"
    assert output =~ "audit_rows", "Expected the tier name in output, got: #{output}"
  end

  # ==========================================================================
  # Anti-tautology probe (inline)
  # ==========================================================================

  @tag :anti_tautology
  test "ANTI-TAUTOLOGY: the real check returns violations for a seeded audit leak" do
    with_direct_connection(fn conn ->
      Postgrex.query!(
        conn,
        "ALTER TABLE rvl_reveal_audit ADD COLUMN IF NOT EXISTS rvl_ssn text",
        []
      )

      on_exit(fn ->
        with_direct_connection(fn c ->
          Postgrex.query!(c, "ALTER TABLE rvl_reveal_audit DROP COLUMN IF EXISTS rvl_ssn", [])
        end)
      end)

      findings = run_check(domains: @clean_domains)

      assert NoPlaintextPii.violations(findings) != [],
             "PROBE: the real scanner returns violations for a seeded audit leak. " <>
               "If this were empty, every red-path assertion above would be tautological."
    end)
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  # Run the CI-mode check, pinning the repo to TestRepo (the sandbox connection
  # the unit tests hold) unless the caller supplies its own :repo.
  defp run_check(opts) do
    opts = Keyword.put_new(opts, :repo, TestRepo)
    NoPlaintextPii.run(opts) |> elem(1)
  end

  # Same direct-connection helper as the catalog_parity test: DDL injected here is
  # immediately visible to the child mix process (which connects to the same DB).
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
