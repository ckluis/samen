defmodule Samen.ErasureRetryAfterRollbackTest do
  @moduledoc """
  `Samen.Erasure.shred/2` destroys the key (STEP 1) OUTSIDE the DB transaction that seals the tiers (STEPS 2-5). If
  that transaction fails once the key is gone, is a re-run safe?

    * `Kms.shred/1` itself is idempotent (the tombstone answers; no second destruction, no error);
    * the DB tiers (vault sealing, redaction, report) are idempotent and complete on the retry;
    * the pseudonym-keyed derived-summary withdrawal (STEPS 3f/3g) needs the `subject_ref`, which was derived from the
      LIVE key at STEP 0 and is uncomputable once the key is gone. `shred/2` therefore commits it as a resume marker
      BEFORE the shred and the retry takes it from there: the withdrawal runs and the report says `performed`
      (this test formerly pinned the loss as a disclosed `pseudonym_shredded`; the full per-step proof is
      `erasure_resumable_test.exs`).
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Samen.{Erasure, FaultRepo, Kms, Vault}
  alias Samen.Vault.VaultRow

  @repo SamenCore.TestRepo

  setup do
    Samen.TestSandbox.shared!(@repo)
    FaultRepo.heal()
    Kms.FileBacked.simulate_outage(false)
    prior = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, Kms.FileBacked)

    on_exit(fn ->
      FaultRepo.heal()
      Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, prior || Kms.FileBacked)
    end)

    :ok
  end

  test "a retry after a rolled-back seal transaction completes the DB tiers; the key stays destroyed once" do
    subject = "retry-subject-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.store_field(subject, :pii_email, :emails, "retry@example.com", @repo)

    # the seal transaction cannot start: STEP 1 (key destruction) already happened, STEPS 2-5 did not
    FaultRepo.fail([:transaction])

    capture_log(fn ->
      assert_raise DBConnection.ConnectionError, fn -> Erasure.shred(subject, repo: FaultRepo) end
    end)

    FaultRepo.heal()
    refute Kms.FileBacked.key_material_present?(subject)
    assert Enum.all?(@repo.all(from(v in VaultRow, where: v.subject_id == ^subject)), &(&1.state == "active"))
    refute Erasure.erased?(subject, repo: @repo)

    # the retry: Kms.shred is the idempotent tombstone answer, the DB tiers seal now
    assert {:ok, %{attestation: att, report: report}} = Erasure.shred(subject, repo: @repo)
    assert att.state == :shredded
    assert report.outcome == "shredded"
    assert report.vault_rows_sealed == 1
    assert Erasure.erased?(subject, repo: @repo)
    assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(subject, @repo)

    # the withdrawal ran on the retry: the reference survived the shred in the resume marker
    assert report.tiers["derived_summaries"] == %{"invalidation" => "performed", "reason" => nil}
  end

  test "POSITIVE CONTROL: the uninterrupted erasure performs the derived-summary withdrawal" do
    subject = "retry-control-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.store_field(subject, :pii_email, :emails, "control@example.com", @repo)

    assert {:ok, %{report: report}} = Erasure.shred(subject, repo: @repo)
    refute report.tiers["derived_summaries"]["reason"] == "pseudonym_shredded"
  end

  test "STEP 4a is strict: when only the lifecycle audit's chain write fails, the erasure aborts instead of committing without it" do
    FaultRepo.register_as_repo!()
    # how many chain writes (existence probes) a healthy erasure makes; 4a is the second to last, 4b the last
    healthy = "audit-healthy-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.store_field(healthy, :pii_email, :emails, "healthy@example.com", @repo)
    assert {:ok, _} = Erasure.shred(healthy, repo: FaultRepo)
    probes = FaultRepo.probe_count()
    assert probes >= 2
    FaultRepo.heal()

    subject = "audit-strict-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.store_field(subject, :pii_email, :emails, "strict@example.com", @repo)
    FaultRepo.fail([{:probe_nth, probes - 1}])

    capture_log(fn ->
      assert {:error, {:erasure_tx_failed, _}} = Erasure.shred(subject, repo: FaultRepo)
    end)

    FaultRepo.heal()
    # nothing of the seal transaction committed: no report, no lifecycle row, vault rows still active
    refute Erasure.erased?(subject, repo: @repo)
    assert Samen.Reveal.Grants.audit_for(subject, repo: @repo) == []
    assert Enum.all?(@repo.all(from(v in VaultRow, where: v.subject_id == ^subject)), &(&1.state == "active"))

    # the retry (chain healthy) completes, with the lifecycle row
    assert {:ok, _} = Erasure.shred(subject, repo: @repo)
    assert Enum.any?(Samen.Reveal.Grants.audit_for(subject, repo: @repo), &(&1.event == "erased"))
  end
end
