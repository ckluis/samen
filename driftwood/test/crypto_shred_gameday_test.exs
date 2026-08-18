defmodule Driftwood.CryptoShredGamedayTest do
  @moduledoc """
  T5.4 — the crypto-shred game-day guarantee, guarded IN the default `mix test` suite
  (sandbox, fast, in-process). It drives the SAME `Driftwood.CryptoShredGameday` seed
  used by the standalone auditor script `priv/gameday/crypto_shred_gameday.exs`, then
  runs the post-shred oracle TIERS in-process (not the subprocess CLI — that exit-code
  contract is exercised by `driftwood/ci.sh` step 19 against the committed DB).

  Structure (HARD RULE 2: every guarantee ships a red path + an anti-tautology probe):

    * GREEN — seed a driver across every tier, shred, run the post-shred oracle tiers:
      ZERO violations, positive :pass attestations from every check; the CDL, name,
      email, phone unrecoverable; both rollup arms exercised; the audit chain still
      verifies.

    * RED PATHS — a decryptable copy in each tier makes the oracle FAIL that tier:
      live (un-shredded), registered_non_pii (un-redacted), kms (:absent never-keyed),
      rollup (un-governed → resurrection). The CDL specifically is unrecoverable across
      all tiers post-shred; a pre-shred rollup does not resurrect the driver.

    * ANTI-TAUTOLOGY — the green shred PASSES the exact tiers the red paths FAIL
      (a real discriminating pair, not a check that never fires / always fires). The
      keystore-file sabotage (resurrect the key → oracle catches it → re-shred →
      oracle green) is driven by the standalone script (a project-local scratch
      keystore); this suite is the in-code discriminating-pair evidence.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.CryptoShredGameday, as: GD
  alias Samen.{Erasure, Vault}
  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.Context
  alias Samen.NoPlaintextPii.Tiers.PostShred

  import Ecto.Query, only: [from: 2]

  @repo Driftwood.Repo

  defp post_ctx(subject, overrides \\ []) do
    Context.build(
      Keyword.merge([repo: @repo, subject_id: subject, resources: [], replica: :none], overrides)
    )
  end

  defp violation(findings, subj),
    do: Enum.find(findings, &(&1.subject == subj and &1.severity == :violation))

  defp all_tiers(ctx),
    do: Enum.flat_map(NoPlaintextPii.post_shred_tiers(), fn t -> t.check(ctx) end)

  # ==========================================================================
  # GREEN PATH — the driver is spread across every tier, shredded, oracle clean
  # ==========================================================================

  describe "GREEN PATH — a real driver erased across every tier" do
    test "the post-shred oracle tiers pass with zero violations; the driver is unrecoverable" do
      s = GD.seed_driver_across_tiers(repo: @repo)
      d = s.driver_id

      # Pre-shred proof-of-life: the CDL decrypts.
      assert {:ok, cdl} = Driftwood.OperatorReveal.reveal_cdl(s.operator, d)
      assert cdl == s.cdl_plaintext

      {:ok, %{report: report}} = Erasure.shred(d, repo: @repo, org_id: s.org_id, actor_id: "operator:dpo")

      findings = all_tiers(post_ctx(d))
      violations = NoPlaintextPii.violations(findings)

      assert violations == [],
             "GREEN PATH must have zero violations, got:\n" <>
               Enum.map_join(violations, "\n", &Samen.NoPlaintextPii.Finding.format/1)

      passes = NoPlaintextPii.passes(findings)
      tiers = passes |> Enum.map(& &1.tier) |> Enum.uniq()
      assert :db_content in tiers
      assert :backup_pitr in tiers
      assert :kms_attestation in tiers
      assert :trace_sink in tiers
      assert :cdc_mirror in tiers

      # Every db_content sub-tier attested (live/rollup/audit/registered_non_pii/wrong_key).
      db_subjects = passes |> Enum.filter(&(&1.tier == :db_content)) |> Enum.map(& &1.subject)
      assert "live" in db_subjects
      assert "rollup" in db_subjects
      assert "audit" in db_subjects
      assert "registered_non_pii" in db_subjects
      assert "wrong_key" in db_subjects

      # The CDL / name / email / phone are unrecoverable.
      assert {:error, _} = Driftwood.OperatorReveal.reveal_cdl(s.operator, d)
      assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(d, @repo)

      %{rows: [[raw]]} =
        Ecto.Adapters.SQL.query!(@repo, "SELECT drv_driver::text FROM drv_driver WHERE drv_id = $1", [
          Ecto.UUID.dump!(d)
        ])

      refute raw =~ "CDL-GAMEDAY"
      refute raw =~ s.name_last

      # The REBUILD arm ran and the rollup no longer counts the driver.
      assert %{"arm" => "rebuild"} = Enum.find(report.tiers["rollups"], &(&1["arm"] == "rebuild"))

      %{rows: [[post_count]]} =
        Ecto.Adapters.SQL.query!(
          @repo,
          "SELECT COALESCE(SUM(drl_load_count),0) FROM drl_driver_load_count WHERE drl_subject_id = $1",
          [Ecto.UUID.dump!(d)]
        )

      assert post_count == 0, "a pre-shred rollup must not resurrect the driver"
    end

    test "the SUPPRESS arm (archived window, simulated) flags the derived rows" do
      s = GD.seed_driver_across_tiers(repo: @repo)
      d = s.driver_id

      {:ok, %{report: report}} =
        Erasure.shred(d, repo: @repo, org_id: s.org_id, raw_retained?: false)

      assert %{"arm" => "suppress"} = Enum.find(report.tiers["rollups"], &(&1["arm"] == "suppress"))

      %{rows: [[suppressed]]} =
        Ecto.Adapters.SQL.query!(
          @repo,
          "SELECT bool_and(drl_suppressed) FROM drl_driver_load_count WHERE drl_subject_id = $1",
          [Ecto.UUID.dump!(d)]
        )

      assert suppressed == true
      # Still unrecoverable regardless of arm.
      assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(d, @repo)
    end

    test "the audit/impersonation chain still VERIFIES post-shred (immutable AND crypto-shreddable)" do
      s = GD.seed_driver_across_tiers(repo: @repo)
      d = s.driver_id

      {:ok, _} = Erasure.shred(d, repo: @repo, org_id: s.org_id)

      # Org chain (carries the erasure event AND — post PP-11/T150 — the TENANT-attributed
      # reveal lifecycle) + the global operator chain both verify — the hashes are over
      # tokens, not plaintext.
      assert {:ok, %{entries: n_org}} = Samen.AuditChain.verify_chain(s.org_id, repo: @repo)
      assert n_org >= 1
      assert {:ok, %{entries: _n_glob}} = Samen.AuditChain.verify_chain(Samen.AuditChain.global_org(), repo: @repo)

      # PP-11 (T150): the reveal lifecycle is now TENANT-attributed — it rides the driver's
      # OWN org chain (visible on that tenant's SecurityLive ledger), NOT the __global__
      # operator chain where it used to land when the vertical wiring dropped org_id.
      reveal_events = Samen.AuditChain.reveal_events_for_org(s.org_id, repo: @repo)
      assert reveal_events != [], "the reveal lifecycle must be visible on the tenant's org chain"

      refute [] ==
               Enum.filter(
                 Samen.AuditChain.reveal_events_for_org(s.org_id, repo: @repo),
                 &(&1.subject_id == d)
               )

      # The erasure event survives on the WORM aud_event tier.
      %{rows: [[erasures]]} =
        Ecto.Adapters.SQL.query!(
          @repo,
          "SELECT count(*) FROM aud_event WHERE aud_subject_id = $1 AND aud_event_type = 'erasure'",
          [d]
        )

      assert erasures >= 1

      # Chain entries carry NO plaintext driver PII.
      %{rows: [[dump]]} =
        Ecto.Adapters.SQL.query!(
          @repo,
          "SELECT COALESCE(string_agg(COALESCE(ach_detail,'') || ' ' || COALESCE(ach_subject_id,''),' '),'') FROM aud_chain WHERE ach_subject_id = $1",
          [d]
        )

      refute dump =~ "CDL-GAMEDAY"
      refute dump =~ s.name_last
    end
  end

  # ==========================================================================
  # RED PATHS — a decryptable copy in each tier fails the oracle
  # ==========================================================================

  describe "RED PATHS — the oracle fails a leak per tier" do
    @tag :red_path
    test "live tier: an un-shredded driver's vault STILL DECRYPTS is a violation" do
      s = GD.seed_driver_across_tiers(repo: @repo)
      # No shred → live tier still decrypts.
      findings = PostShred.DbContent.check(post_ctx(s.driver_id))
      v = violation(findings, "live")
      assert v != nil
      assert v.detail =~ "STILL DECRYPT"
    end

    @tag :red_path
    test "registered_non_pii tier: an un-redacted non_pii! residue is a violation" do
      s = GD.seed_driver_across_tiers(repo: @repo)
      {:ok, _} = Erasure.shred(s.driver_id, repo: @repo)

      # Put plaintext back into the non_pii! column (redaction arm did not run).
      Ecto.Adapters.SQL.query!(@repo, "UPDATE drv_driver SET drv_cdl_state = 'TX' WHERE drv_id = $1", [
        Ecto.UUID.dump!(s.driver_id)
      ])

      findings = PostShred.DbContent.check(post_ctx(s.driver_id))
      v = violation(findings, "registered_non_pii")
      assert v != nil
      assert v.detail =~ "non-redacted"
    end

    @tag :red_path
    test "kms tier: a never-keyed subject attests :absent is a violation (positive tombstone required)" do
      findings = PostShred.KmsAttestation.check(post_ctx(Ecto.UUID.generate()))
      assert Enum.any?(findings, &(&1.severity == :violation))
      assert Enum.map_join(findings, "\n", &Samen.NoPlaintextPii.Finding.format/1) =~ ":absent == FAIL"
    end

    @tag :red_path
    test "rollup tier: a registered rollup ABSENT from the erasure report is a violation (no resurrection)" do
      s = GD.seed_driver_across_tiers(repo: @repo)
      {:ok, %{report: report}} = Erasure.shred(s.driver_id, repo: @repo)

      @repo.update_all(
        from(r in Samen.Erasure.Report, where: r.id == ^report.id),
        set: [tiers: Map.put(report.tiers, "rollups", [])]
      )

      findings = PostShred.DbContent.check(post_ctx(s.driver_id))
      v = violation(findings, "rollup")
      assert v != nil
      assert v.detail =~ "ABSENT from the erasure report"
    end

    @tag :red_path
    test "the CDL number is unrecoverable across ALL tiers post-shred" do
      s = GD.seed_driver_across_tiers(repo: @repo)
      d = s.driver_id
      {:ok, _} = Erasure.shred(d, repo: @repo)

      # domain row: no plaintext CDL.
      %{rows: [[raw]]} =
        Ecto.Adapters.SQL.query!(@repo, "SELECT pii_drv_cdl_number FROM drv_driver WHERE drv_id = $1", [
          Ecto.UUID.dump!(d)
        ])

      assert String.starts_with?(raw, "vt_")
      refute raw =~ "CDL-GAMEDAY"

      # vault: no decrypt under own key; no cross-decrypt under a foreign live key.
      assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(d, @repo)

      assert Vault.scan_no_wrong_key(d, @repo) in [
               {:ok, :no_cross_decrypt},
               {:error, :unsupported}
             ]

      # reveal path: shredded.
      assert {:error, :shredded} = Driftwood.OperatorReveal.reveal_cdl(s.operator, d)
    end
  end

  # ==========================================================================
  # ANTI-TAUTOLOGY — the green shred PASSES the exact tiers the red paths FAIL
  # ==========================================================================

  @tag :anti_tautology
  test "ANTI-TAUTOLOGY: a real shred PASSES the very tiers the red paths drive to violation" do
    s = GD.seed_driver_across_tiers(repo: @repo)
    d = s.driver_id
    {:ok, _} = Erasure.shred(d, repo: @repo, org_id: s.org_id)

    ctx = post_ctx(d)

    db = PostShred.DbContent.check(ctx)
    assert NoPlaintextPii.violations(db) == []
    assert Enum.any?(db, &(&1.subject == "live" and &1.severity == :pass))
    assert Enum.any?(db, &(&1.subject == "registered_non_pii" and &1.severity == :pass))
    assert Enum.any?(db, &(&1.subject == "rollup" and &1.severity == :pass))
    assert Enum.any?(db, &(&1.subject == "wrong_key" and &1.severity == :pass))

    kms = PostShred.KmsAttestation.check(ctx)
    assert NoPlaintextPii.violations(kms) == []
    assert Enum.any?(kms, &(&1.severity == :pass and &1.detail =~ "POSITIVE :shredded"))
  end
end
