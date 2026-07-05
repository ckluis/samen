defmodule Demo.VerifiersTest do
  @moduledoc """
  Verifier smoke tests for the demo app (T1.9): all 5 verifiers pass on the demo
  schema.

  Anti-tautology probe for each verifier is performed by the CI gate fail-closed
  matrix (see ci.sh and the T1.9 report). These tests confirm the verifiers are
  wired and GREEN on the clean demo DB.
  """
  use ExUnit.Case, async: false

  alias Demo.Repo

  @project_dir Path.expand("../", __DIR__)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  # =========================================================================
  # C1 — catalog_parity
  # =========================================================================

  describe "C1 catalog_parity" do
    test "passes on the clean demo DB" do
      violations = Mix.Tasks.Samen.Verify.CatalogParity.check(Repo)
      assert violations == [],
             "Expected no parity violations, got: #{inspect(violations)}"
    end
  end

  # =========================================================================
  # C2 — prefixes (checks physical DB columns via repo)
  # =========================================================================

  describe "C2 prefixes" do
    test "all demo columns have abbrev prefixes" do
      violations = Mix.Tasks.Samen.Verify.Prefixes.check(Repo)

      assert violations == [],
             "Expected no prefix violations, got: #{inspect(violations)}"
    end
  end

  # =========================================================================
  # C3 — pii_reads (structural: no direct leak in demo source)
  # =========================================================================

  describe "C3 pii_reads" do
    test "no pii_reads violations in demo lib/" do
      # Build registry from demo domains.
      registry = Samen.PiiReads.Registry.build(domains: [Demo.Crm])

      source_dir = Path.join(@project_dir, "lib")
      {code, findings} = Samen.PiiReads.Harness.check_dirs([source_dir], registry)

      failing = Samen.PiiReads.Harness.failing(findings)

      assert code == 0,
             "C3 pii_reads found leaks in demo lib/: #{inspect(failing)}"
    end
  end

  # =========================================================================
  # C4 — pii_classify
  # =========================================================================

  describe "C4 pii_classify" do
    test "no unclassified PII-shaped columns in demo resources" do
      resources = [Demo.Crm.Org, Demo.Crm.Membership, Demo.Crm.Contact]
      violations = Mix.Tasks.Samen.Verify.PiiClassify.check(resources)

      # The demo's Contact has dob declared as pii_attribute (cleared),
      # full_name and emails too. display_name and active are non-PII.
      assert violations == [],
             "C4 pii_classify found unclassified PII: #{inspect(violations)}"
    end
  end

  # =========================================================================
  # C5 — no_plaintext_pii (CI mode)
  # =========================================================================

  describe "C5 no_plaintext_pii (CI mode)" do
    test "passes CI mode on the demo schema" do
      resources = [Demo.Crm.Org, Demo.Crm.Membership, Demo.Crm.Contact]

      {:ok, findings} =
        Samen.NoPlaintextPii.run(
          resources: resources,
          repo: Repo,
          # Exclude opentelemetry_ecto from deps check (not installed in demo).
          deps: []
        )

      violations = Samen.NoPlaintextPii.violations(findings)

      assert violations == [],
             "C5 no_plaintext_pii CI mode found violations: #{inspect(violations)}"
    end
  end
end
