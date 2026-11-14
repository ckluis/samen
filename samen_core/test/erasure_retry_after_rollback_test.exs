defmodule Samen.ErasureRetryAfterRollbackTest do
  @moduledoc """
  `Samen.Erasure.shred/2` destroys the key (STEP 1) OUTSIDE the DB transaction that seals the tiers (STEPS 2-5). If
  that transaction fails once the key is gone, is a re-run safe?

    * `Kms.shred/1` itself is idempotent (the tombstone answers; no second destruction, no error);
    * the DB tiers (vault sealing, redaction, report) are idempotent and complete on the retry;
    * what a retry CANNOT do is the pseudonym-keyed derived-summary withdrawal (STEPS 3f/3g): the ref was captured at
      STEP 0 while the key was live and is uncomputable now, so the retry records those arms as no-ops and DISCLOSES
      it (`derived_summaries` tier: unavailable / `pseudonym_shredded`). Those rows are unlinkable (their key is
      gone) but not neutralized. This test pins exactly that, so it cannot change silently.
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

    # the disclosed loss: the pseudonym-keyed withdrawal could not run on the retry
    assert report.tiers["derived_summaries"]["reason"] == "pseudonym_shredded"
  end

  test "POSITIVE CONTROL: the uninterrupted erasure performs the derived-summary withdrawal" do
    subject = "retry-control-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.store_field(subject, :pii_email, :emails, "control@example.com", @repo)

    assert {:ok, %{report: report}} = Erasure.shred(subject, repo: @repo)
    refute report.tiers["derived_summaries"]["reason"] == "pseudonym_shredded"
  end
end
