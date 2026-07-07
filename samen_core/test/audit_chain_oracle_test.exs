defmodule Samen.AuditChainOracleTest do
  @moduledoc """
  T4.3: the destruction oracle covers the `aud_chain` tier — CI-mode token-only
  assertion (ADR-002 §2.4; doc *"the destruction oracle covers this tier too:
  mix samen.verify.no_plaintext_pii asserts the audit log holds tokens only"* :894).

  Covers:
    * clean `aud_chain` passes (no violation);
    * RED: a plaintext PII-named column FAILS (name gate);
    * RED: an unrecognised plaintext column FAILS (allow-list gate, fail closed);
    * the tier is wired into `default_tiers/0` and a full CI run stays clean;
    * the `bytea` ciphertext column does NOT trip the tier (it is not a plaintext type);
    * S3ObjectLock production skeleton fails closed (never a faked WORM pass).

  Anti-tautology: the "clean passes" positive control PLUS the two red paths together
  prove the tier is a real discriminator — a clean scan passes, a seeded PII column
  flips it to a violation.
  """

  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.NoPlaintextPii.Tiers.AuditChain, as: AuditChainTier
  alias Samen.NoPlaintextPii.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "Tiers.AuditChain — CI tier" do
    test "clean aud_chain table passes (no violations)" do
      context = Context.build(repo: Repo)
      findings = AuditChainTier.check(context)
      violations = Enum.filter(findings, &(&1.severity == :violation))
      assert violations == [], "expected no violations, got: #{inspect(violations)}"
    end

    test "the bytea ciphertext column does NOT trip the tier (non-plaintext type)" do
      # ach_subject_ciphertext is BYTEA — it cannot carry raw subject PII by shape, so
      # the type gate clears it. This is the crux: the shreddable ciphertext lives here.
      context = Context.build(repo: Repo)
      findings = AuditChainTier.check(context)

      ct_finding =
        Enum.find(findings, fn f -> f.subject =~ "subject_ciphertext" end)

      assert ct_finding == nil or ct_finding.severity != :violation
    end

    test "tier_name/0 is :aud_chain and mode/0 is :ci" do
      assert AuditChainTier.tier_name() == :aud_chain
      assert AuditChainTier.mode() == :ci
    end

    test "RED: plaintext PII-named column on aud_chain FAILS (name gate)" do
      Repo.query!("ALTER TABLE aud_chain ADD COLUMN ach_email TEXT")

      context = Context.build(repo: Repo)
      findings = AuditChainTier.check(context)
      violations = Enum.filter(findings, &(&1.severity == :violation))

      assert Enum.any?(violations, fn f -> f.subject =~ "email" end),
             "expected a violation for ach_email, got: #{inspect(violations)}"

      Repo.query!("ALTER TABLE aud_chain DROP COLUMN IF EXISTS ach_email")
    end

    test "RED: unrecognised plaintext column on aud_chain FAILS (allow-list gate)" do
      Repo.query!("ALTER TABLE aud_chain ADD COLUMN ach_extra_note TEXT")

      context = Context.build(repo: Repo)
      findings = AuditChainTier.check(context)
      violations = Enum.filter(findings, &(&1.severity == :violation))

      assert Enum.any?(violations, fn f -> f.subject =~ "extra_note" end),
             "expected allow-list violation for ach_extra_note, got: #{inspect(violations)}"

      Repo.query!("ALTER TABLE aud_chain DROP COLUMN IF EXISTS ach_extra_note")
    end

    test "aud_chain tier is in default_tiers/0" do
      assert AuditChainTier in Samen.NoPlaintextPii.default_tiers()
    end

    test "full CI run stays clean for the aud_chain tier" do
      {:ok, findings} =
        Samen.NoPlaintextPii.run(repo: Repo, deps: [:oban], non_pii_entries: [])

      violations = Samen.NoPlaintextPii.violations(findings)
      chain_violations = Enum.filter(violations, &(&1.tier == :aud_chain))

      assert chain_violations == [],
             "expected no aud_chain tier violations, got: #{inspect(chain_violations)}"
    end
  end

  describe "Anchor.S3ObjectLock — production skeleton fails closed (never faked)" do
    test "seal raises with a clear operator TODO when disabled" do
      Application.delete_env(:samen_core, :anchor_s3_enabled)

      assert_raise RuntimeError, ~r/anchor_s3_enabled is false/, fn ->
        Samen.Anchor.S3ObjectLock.seal(%{org_id: "o", seq: 0, hash: "h"})
      end
    end

    test "even ENABLED it raises (not implemented) rather than fake a WORM seal" do
      Application.put_env(:samen_core, :anchor_s3_enabled, true)

      on_exit(fn -> Application.delete_env(:samen_core, :anchor_s3_enabled) end)

      assert_raise RuntimeError, ~r/not implemented|Failing closed/, fn ->
        Samen.Anchor.S3ObjectLock.read_head("o")
      end
    end

    test "worm?/0 is true (compliance-mode retention)" do
      assert Samen.Anchor.S3ObjectLock.worm?() == true
    end
  end
end
