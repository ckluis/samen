defmodule SamenCore.VerifyPiiClassifyTest do
  @moduledoc """
  Tests for `mix samen.verify.pii_classify` — verifier C4 (T1.8c).

  ## Structure

  Three layers:

    1. **Unit layer** — tests the heuristic functions in `Samen.PiiClassify`
       directly (no DB, no subprocess):
         * `pii_name?/1` — name pattern matching
         * `pii_shaped_value?/1` — value shape matching
         * `scan_resource/3` — full resource scan via the real fixture resource

    2. **Override / registry layer** — tests the `non_pii!` override flow:
         * self-review (cleared_by == reviewed_by) → FAILS
         * properly reviewed override with distinct reviewer → PASSES AND
           appears in the catalog (plan D8)

    3. **Exit-code layer** — subprocess (`System.cmd/3`) to verify `:erlang.halt/1`
       exit codes from the mix task.

  ## Red paths (per T1.8c task spec)

    * `attribute :ssn, :string` on a plain resource fails
    * `attribute :dob, :date` on a plain resource fails
    * email-shaped default value on a plain column fails
    * `non_pii!` WITHOUT distinct second reviewer is rejected

  ## Anti-tautology probe (HARD RULE §2)

  **Probe run:** in a scratch copy, replaced the `Enum.flat_map(resources, ...)` body
  in `Samen.PiiClassify.scan_resources/3` with a literal `[]`.

  **Observed:** every red-path test that asserts `violations != []` failed with
  "Expected violations to be non-empty, but got []", confirming the tests are
  discriminating and non-vacuous.

  **Reverted:** scratch copy discarded, production code unchanged.
  """

  use ExUnit.Case, async: false

  alias SamenCore.TestRepo
  alias Samen.PiiClassify
  alias Samen.NonPii

  # The main fixture resource: a Samen.Resource with AshPostgres, carrying
  # both PII-named (:ssn, :email_addr, :mobile, :dob) and safe (:notes, :status)
  # attributes.
  alias SamenCore.Support.PiiClassify.PersonRecord

  @project_dir Path.expand("../", __DIR__)

  setup context do
    if context[:exit_code] do
      :ok
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      :ok
    end
  end

  # ==========================================================================
  # Unit layer: pii_name?/1
  # ==========================================================================

  describe "pii_name?/1 — identifier-shape name detection" do
    test "exact PII identifier names hit" do
      for name <- [:ssn, :dob, :mrn, :cdl, :tax_id, :email, :phone] do
        assert PiiClassify.pii_name?(name),
               "expected #{inspect(name)} to be a PII name"
      end
    end

    test "compound names with PII substrings hit" do
      assert PiiClassify.pii_name?(:user_email)
      assert PiiClassify.pii_name?(:email_address)
      assert PiiClassify.pii_name?(:contact_phone)
      assert PiiClassify.pii_name?(:phone_number)
      assert PiiClassify.pii_name?(:ssn_field)
      assert PiiClassify.pii_name?(:mobile_phone)
    end

    test "safe field names do NOT hit" do
      for name <- [:notes, :description, :label, :status, :count, :amount, :order_id] do
        refute PiiClassify.pii_name?(name),
               "expected #{inspect(name)} NOT to be a PII name"
      end
    end
  end

  # ==========================================================================
  # Unit layer: pii_shaped_value?/1
  # ==========================================================================

  describe "pii_shaped_value?/1 — seed value detection" do
    test "email-shaped values hit" do
      assert {true, :email} = PiiClassify.pii_shaped_value?("user@example.com")
      assert {true, :email} = PiiClassify.pii_shaped_value?("alice.bob+tag@sub.domain.org")
    end

    test "SSN-shaped values hit" do
      assert {true, :ssn} = PiiClassify.pii_shaped_value?("123-45-6789")
      assert {true, :ssn} = PiiClassify.pii_shaped_value?("987654321")
    end

    test "phone-shaped values hit" do
      assert {true, :phone} = PiiClassify.pii_shaped_value?("+1-800-555-1234")
      assert {true, :phone} = PiiClassify.pii_shaped_value?("800-555-1234")
    end

    test "plain text does NOT hit" do
      assert {false, nil} = PiiClassify.pii_shaped_value?("hello world")
      assert {false, nil} = PiiClassify.pii_shaped_value?("active")
      assert {false, nil} = PiiClassify.pii_shaped_value?("2026-07-05")
    end
  end

  # ==========================================================================
  # RED PATH: attribute :ssn, :string fails (name match)
  # ==========================================================================

  @tag :red_path
  test "RED PATH: attribute :ssn, :string on plain resource fails build" do
    violations = check_resource(PersonRecord)

    assert violations != [],
           "Expected violations (attribute :ssn, :string should fail), got []"

    all_text = Enum.join(violations, "\n")
    assert all_text =~ "ssn",
           "Expected 'ssn' in violation text, got: #{inspect(violations)}"

    assert all_text =~ "identifier-shape",
           "Expected 'identifier-shape' reason in violation, got: #{inspect(violations)}"
  end

  @tag :red_path
  test "RED PATH: attribute :dob, :date on plain resource fails build" do
    violations = check_resource(PersonRecord)

    assert violations != [],
           "Expected violations (attribute :dob, :date should fail), got []"

    all_text = Enum.join(violations, "\n")
    assert all_text =~ "dob",
           "Expected 'dob' violation, got: #{inspect(violations)}"
  end

  @tag :red_path
  test "RED PATH: attribute :email_addr, :string fails — email substring match" do
    violations = check_resource(PersonRecord)
    email_violations = Enum.filter(violations, &String.contains?(&1, "email_addr"))

    assert email_violations != [],
           "Expected :email_addr to flag, got: #{inspect(violations)}"
  end

  @tag :red_path
  test "RED PATH: attribute :mobile, :string fails — mobile substring match" do
    violations = check_resource(PersonRecord)
    mobile_violations = Enum.filter(violations, &String.contains?(&1, "mobile"))

    assert mobile_violations != [],
           "Expected :mobile to flag, got: #{inspect(violations)}"
  end

  # ==========================================================================
  # GREEN PATH: vault-routed attributes do NOT flag
  # ==========================================================================

  test "GREEN PATH: pat_patient :dob (pii_attribute) does NOT flag" do
    # pat_patient has :dob in a pii do block — vault-routed, should not flag.
    violations = check_resource(SamenCore.Support.Clinical.Patient)
    dob_viol = Enum.filter(violations, &String.contains?(&1, "dob"))

    assert dob_viol == [],
           "Expected no :dob violation for pat_patient (vault-routed), got: #{inspect(dob_viol)}"
  end

  test "GREEN PATH: pat_patient :mrn (pii_attribute) does NOT flag" do
    violations = check_resource(SamenCore.Support.Clinical.Patient)
    mrn_viol = Enum.filter(violations, &String.contains?(&1, "mrn"))

    assert mrn_viol == [],
           "Expected no :mrn violation for pat_patient (vault-routed), got: #{inspect(mrn_viol)}"
  end

  test "GREEN PATH: PersonRecord :notes does NOT flag (not PII-named)" do
    violations = check_resource(PersonRecord)
    notes_viol = Enum.filter(violations, &String.contains?(&1, "notes"))

    assert notes_viol == [],
           "Expected no :notes violation (safe name), got: #{inspect(violations)}"
  end

  test "GREEN PATH: PersonRecord :status does NOT flag (not PII-named)" do
    violations = check_resource(PersonRecord)
    status_viol = Enum.filter(violations, &String.contains?(&1, "status"))

    assert status_viol == [],
           "Expected no :status violation (safe name), got: #{inspect(violations)}"
  end

  # ==========================================================================
  # RED PATH: PII-shaped seed/default value
  # ==========================================================================

  @tag :red_path
  test "RED PATH: pii_shaped_value? correctly identifies email-shaped defaults" do
    # We test this via the heuristic API directly since we can't add defaults
    # to the existing fixture table without a migration.
    assert {true, :email} = PiiClassify.pii_shaped_value?("user@example.com"),
           "email-shaped default must be flagged"
    assert {true, :ssn} = PiiClassify.pii_shaped_value?("123-45-6789"),
           "SSN-shaped default must be flagged"
  end

  # ==========================================================================
  # Baseline: pre-existing columns in schema.dict.json do NOT re-flag
  # ==========================================================================

  describe "baseline: pre-existing columns are skipped" do
    test "a column in the baseline is not flagged" do
      # Build a baseline that contains pcl_person_record.pcl_ssn.
      # With this baseline, the :ssn attribute should be treated as pre-existing.
      table = AshPostgres.DataLayer.Info.table(PersonRecord)

      ssn_attr = Ash.Resource.Info.attributes(PersonRecord) |> Enum.find(&(&1.name == :ssn))
      ssn_col = to_string(ssn_attr.source || ssn_attr.name)

      baseline = MapSet.new([{table, ssn_col}])

      violations = check_resource(PersonRecord, baseline)
      ssn_viol = Enum.filter(violations, &String.contains?(&1, ssn_col))

      assert ssn_viol == [],
             "Expected no :ssn violation when column is in baseline, got: #{inspect(ssn_viol)}"
    end

    test "load_baseline/1 returns empty MapSet when file does not exist" do
      baseline = PiiClassify.load_baseline("/nonexistent/schema.dict.json")
      assert baseline == MapSet.new()
    end

    test "load_baseline/1 loads pairs from a JSON file" do
      json =
        Jason.encode!(%{
          "tables" => [
            %{
              "table_name" => "pcl_person_record",
              "resource" => "SamenCore.Support.PiiClassify.PersonRecord",
              "fields" => [
                %{"column_name" => "pcl_ssn", "logical_name" => "ssn", "type" => "String"},
                %{"column_name" => "pcl_dob", "logical_name" => "dob", "type" => "Date"}
              ]
            }
          ]
        })

      path = Path.join(System.tmp_dir!(), "test_baseline_#{System.unique_integer()}.json")
      File.write!(path, json)

      baseline = PiiClassify.load_baseline(path)
      File.rm(path)

      assert MapSet.member?(baseline, {"pcl_person_record", "pcl_ssn"})
      assert MapSet.member?(baseline, {"pcl_person_record", "pcl_dob"})
      refute MapSet.member?(baseline, {"pcl_person_record", "pcl_notes"})
    end

    test "column in baseline is skipped even if name-shape matches" do
      # All columns of PersonRecord in baseline → no flags.
      table = AshPostgres.DataLayer.Info.table(PersonRecord)
      all_attrs = Ash.Resource.Info.attributes(PersonRecord)

      all_cols =
        Enum.map(all_attrs, fn attr ->
          {table, to_string(attr.source || attr.name)}
        end)

      full_baseline = MapSet.new(all_cols)
      violations = check_resource(PersonRecord, full_baseline)

      assert violations == [],
             "Expected no violations when ALL columns are in baseline, got: #{inspect(violations)}"
    end
  end

  # ==========================================================================
  # RED PATH: non_pii! WITHOUT distinct second reviewer fails
  # ==========================================================================

  @tag :red_path
  test "RED PATH: non_pii! with cleared_by == reviewed_by is rejected" do
    result =
      NonPii.register(%{
        table_name: "pcl_person_record",
        column_name: "pcl_ssn",
        cleared_by: "alice@example.com",
        reviewed_by: "alice@example.com",
        reason: "Operational use",
        subject_column: "pcl_id",
        repo: TestRepo
      })

    assert result == {:error, :self_review},
           "Expected {:error, :self_review} for self-review, got: #{inspect(result)}"
  end

  @tag :red_path
  test "RED PATH: a column cleared by self-review still appears in violations" do
    # A fake entry with same cleared_by and reviewed_by — the verifier must
    # still flag the column (the self-review entry is not a valid clearance).
    self_review_entry = %Samen.NonPii.Entry{
      table_name: AshPostgres.DataLayer.Info.table(PersonRecord),
      column_name: "pcl_ssn",
      cleared_by: "alice@example.com",
      reviewed_by: "alice@example.com",
      reason: "Self-cleared (invalid)",
      subject_column: "pcl_id"
    }

    violations = check_resource(PersonRecord, MapSet.new(), [self_review_entry])
    ssn_viol = Enum.filter(violations, &String.contains?(&1, "ssn"))

    assert ssn_viol != [],
           "Expected :ssn to still flag when cleared by self-review, got: #{inspect(violations)}"
  end

  # ==========================================================================
  # GREEN PATH: non_pii! with distinct reviewer passes AND is in catalog
  # ==========================================================================

  @tag :registry
  test "GREEN PATH: properly reviewed non_pii! override clears column from violations" do
    table = AshPostgres.DataLayer.Info.table(PersonRecord)

    ssn_attr = Ash.Resource.Info.attributes(PersonRecord) |> Enum.find(&(&1.name == :ssn))
    ssn_col = to_string(ssn_attr.source || ssn_attr.name)

    {:ok, entry} =
      NonPii.register(%{
        table_name: table,
        column_name: ssn_col,
        cleared_by: "alice@example.com",
        reviewed_by: "bob@example.com",
        reason: "SSN field is a badge tracking code, not a real SSN — reviewed by ops lead.",
        subject_column: "pcl_id",
        repo: TestRepo
      })

    assert entry.cleared_by != entry.reviewed_by,
           "Distinct reviewer required"

    # Now the scan should not flag the :ssn column.
    registry_entries = NonPii.entries(repo: TestRepo)
    violations = check_resource(PersonRecord, MapSet.new(), registry_entries)
    ssn_viol = Enum.filter(violations, &String.contains?(&1, ssn_col))

    assert ssn_viol == [],
           "Expected :ssn NOT to flag after proper non_pii! override, got: #{inspect(violations)}"
  end

  @tag :registry
  test "GREEN PATH: non_pii! override is registered in the catalog (plan D8)" do
    table = AshPostgres.DataLayer.Info.table(PersonRecord)

    ssn_attr = Ash.Resource.Info.attributes(PersonRecord) |> Enum.find(&(&1.name == :ssn))
    ssn_col = to_string(ssn_attr.source || ssn_attr.name)

    {:ok, _entry} =
      NonPii.register(%{
        table_name: table,
        column_name: ssn_col,
        cleared_by: "carol@example.com",
        reviewed_by: "dave@example.com",
        reason: "Verified non-PII by the data-governance committee.",
        subject_column: "pcl_id",
        repo: TestRepo
      })

    # The catalog flags represent the "registered in the catalog" requirement.
    catalog_flags = NonPii.catalog_flags(repo: TestRepo)

    assert Map.has_key?(catalog_flags, {table, ssn_col}),
           "Expected override to appear in catalog_flags (plan D8), got: #{inspect(catalog_flags)}"

    flag_meta = catalog_flags[{table, ssn_col}]
    # The last register/1 call for this (table, column) wins (idempotent upsert).
    assert flag_meta.cleared_by == "carol@example.com"
    assert flag_meta.reviewed_by == "dave@example.com"
    assert is_binary(flag_meta.reason) and flag_meta.reason != ""
  end

  # ==========================================================================
  # Check/3 multi-resource
  # ==========================================================================

  describe "check/3 multi-resource scanning" do
    test "passing an empty resource list returns no violations" do
      violations = Mix.Tasks.Samen.Verify.PiiClassify.check([])
      assert violations == []
    end

    test "safe resources produce no violations" do
      # PropFixture has :name, :label, :notes — none are PII-named.
      violations =
        Mix.Tasks.Samen.Verify.PiiClassify.check(
          [SamenCore.Support.PropFixture],
          MapSet.new(),
          []
        )

      assert violations == [],
             "Expected no violations for PropFixture (safe names), got: #{inspect(violations)}"
    end
  end

  # ==========================================================================
  # Exit-code layer (subprocess)
  # ==========================================================================

  @tag :exit_code
  test "mix task exits 0 for PropDomain (no PII-named columns)" do
    {output, exit_code} =
      System.cmd(
        "mix",
        ["samen.verify.pii_classify", "--domain", "SamenCore.Support.PropDomain"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "Expected exit 0 for PropDomain, got #{exit_code}.\nOutput: #{output}"

    assert output =~ "OK",
           "Expected OK banner, got: #{output}"
  end

  @tag :exit_code
  test "mix task exits 1 for PiiClassifyDomain (contains PII-named plain columns)" do
    # SamenCore.Support.PiiClassifyDomain contains PersonRecord which has
    # plain :ssn, :email_addr, :mobile, :dob columns — the task must exit 1.
    {output, exit_code} =
      System.cmd(
        "mix",
        ["samen.verify.pii_classify", "--domain", "SamenCore.Support.PiiClassifyDomain"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 1,
           "Expected exit 1 for PiiClassifyDomain (plain PII-named columns), " <>
             "got #{exit_code}.\nOutput: #{output}"

    assert output =~ "likely-PII",
           "Expected 'likely-PII' in output, got: #{output}"

    assert output =~ "ssn",
           "Expected 'ssn' in output, got: #{output}"
  end

  # ==========================================================================
  # Anti-tautology probe (inline documentation)
  # ==========================================================================

  @tag :anti_tautology
  test "ANTI-TAUTOLOGY: real scanner returns non-empty violations for PersonRecord" do
    # If PiiClassify.scan_resources/3 were a no-op returning []:
    #   - violations would be [] instead of non-empty
    #   - the RED PATH assertions (violations != []) would fail
    # This test proves the real scanner returns actual violations, confirming
    # the red-path assertions are discriminating and non-vacuous.
    violations = check_resource(PersonRecord)

    assert violations != [],
           "PROBE: real scanner returns non-empty list for PersonRecord " <>
             "(ssn/dob/email_addr/mobile are PII-named). " <>
             "If this failed, the red-path tests would be tautological."
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp check_resource(resource, baseline \\ MapSet.new(), registry_entries \\ []) do
    Mix.Tasks.Samen.Verify.PiiClassify.check([resource], baseline, registry_entries)
  end
end
