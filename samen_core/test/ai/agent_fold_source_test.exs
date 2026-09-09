defmodule Samen.AI.AgentFoldSourceTest do
  @moduledoc """
  ADR-048 §7.3 batch C4 (`T221`) — the ENVELOPE properties of the pseudonym-keyed
  provenance index, asserted on `Samen.Erasure` itself.

  `agent_withdrawal_test.exs` owns `P8` (the index is unlinkable after shred, asserted ON
  THE PSEUDONYM). This file owns the two properties `P8` cannot see from outside, because
  both are about the SHAPE of the erasure envelope rather than its result:

    * **ORDER** — `Samen.Kms.shred/1` runs **BEFORE** and **OUTSIDE** the steps-2–5
      `Ecto.Multi` (ADR-046's load-bearing envelope). Proved by forcing the DB tier to
      roll back and showing the key is destroyed ANYWAY. A build that moved the shred
      inside the transaction would let the rollback resurrect the key, and this test would
      fail by name.
    * **FAIL-CLOSED** — the STEP 0 pseudonym read, taken while the DEK is still live, is
      fail-closed: a read that fails for any reason other than the two AUTHORITATIVE ones
      (`:absent`, `:shredded`) aborts the erasure with
      `{:error, {:pseudonym_unavailable, reason}}` and `Kms.shred/1` is NEVER called. An
      outage must never masquerade as a completed erasure: the pseudonym is the ONLY key
      that resolves an index row to a person, and once STEP 1 has run it can never be
      recomputed — so proceeding on an unreadable pseudonym would permanently ORPHAN the
      residue instead of withdrawing it.

  Every obligation is paired with a positive control on the SAME code path and the SAME
  literal subject shape (the anti-tautology rule: a test that cannot fail is a bug).
  """
  use ExUnit.Case, async: false

  alias Samen.AI.Agent.Compaction
  alias Samen.AI.Agent.FoldSource
  alias Samen.Erasure
  alias Samen.Kms.FileBacked
  alias Samen.Vault
  alias Samen.Vault.VaultRow

  import Ecto.Query, only: [from: 2]

  @repo SamenCore.TestRepo

  # ---------------------------------------------------------------------------
  # A KMS adapter that is honest about EVERYTHING except the pseudonym read, so the
  # fail-closed obligation is isolated to the STEP 0 call and cannot be satisfied by the
  # shred arm failing too. `pseudonym/2` returns the same `:unavailable` a real key-store
  # outage returns (`Samen.Kms.FileBacked.unwrap/1` under `simulate_outage(true)`).
  # ---------------------------------------------------------------------------
  defmodule PseudonymOutageKms do
    @moduledoc false
    @behaviour Samen.Kms

    @impl true
    def generate_subject_key(s), do: FileBacked.generate_subject_key(s)
    @impl true
    def unwrap(s), do: FileBacked.unwrap(s)
    @impl true
    def shred(s), do: FileBacked.shred(s)
    @impl true
    def attest(s), do: FileBacked.attest(s)
    @impl true
    def backups_disabled?, do: FileBacked.backups_disabled?()
    @impl true
    def key_material_present?(s), do: FileBacked.key_material_present?(s)
    @impl true
    def list_active_subjects, do: FileBacked.list_active_subjects()

    # THE ONE DISHONEST-STORE CALLBACK: the pseudonym is unreadable, everything else works.
    @impl true
    def pseudonym(_subject_id, _target_subject_id), do: {:error, :unavailable}
  end

  # ---------------------------------------------------------------------------
  # A repo façade that APPENDS a failing step to the steps-2–5 `Ecto.Multi`, so the whole
  # DB tier rolls back while every step above it still really ran. `Samen.Erasure` calls
  # exactly one function on the `:repo` option it is handed — `transaction/1` — so this is
  # the smallest possible seam and it does not stub any erasure behaviour.
  # ---------------------------------------------------------------------------
  defmodule RollbackRepo do
    @moduledoc false
    def transaction(multi) do
      SamenCore.TestRepo.transaction(
        Ecto.Multi.run(multi, :forced_tier_failure, fn _repo, _changes ->
          {:error, :forced_tier_failure}
        end)
      )
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, FileBacked)

    on_exit(fn ->
      FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, FileBacked)
    end)

    :ok
  end

  defp seed_subject! do
    sid = "c4i1-subject-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.store_field(sid, :pii_email, :emails, "c4i1-#{sid}@example.com", @repo)
    sid
  end

  defp active_rows(sid) do
    @repo.aggregate(
      from(v in VaultRow, where: v.subject_id == ^sid and v.state == "active"),
      :count
    )
  end

  defp state_of(sid) do
    {:ok, att} = Vault.attest(sid)
    att.state
  end

  # ===========================================================================
  # ORDER — Kms.shred/1 before and OUTSIDE the steps-2-5 transaction (ADR-046)
  # ===========================================================================

  test "C4I1 ORDER: Kms.shred/1 runs BEFORE and OUTSIDE the steps-2-5 DB transaction — a forced tier rollback leaves the key DESTROYED and the DB untouched" do
    sid = seed_subject!()

    # NON-VACUITY: the subject really has a live key and an unsealed vault row to lose.
    assert state_of(sid) == :active
    assert active_rows(sid) == 1
    assert {:ok, _} = Vault.pseudonym(sid)

    # The steps-2–5 `Ecto.Multi` is forced to fail, so EVERY DB-tier effect rolls back.
    assert {:error, {:erasure_tx_failed, :forced_tier_failure}} =
             Erasure.shred(sid, repo: RollbackRepo)

    # The transaction really did roll back — no sentinel, no report. (Without this the
    # assertion below would be satisfied by a build that never opened a transaction.)
    assert active_rows(sid) == 1
    assert Erasure.latest_report(sid, repo: @repo) == nil

    # AND YET THE KEY IS GONE. That is only possible if `Kms.shred/1` ran BEFORE the
    # transaction opened and OUTSIDE it — ADR-046's envelope. Move the shred inside the
    # `Ecto.Multi` and the rollback resurrects the key, and this assertion fails by name.
    assert state_of(sid) == :shredded
    assert {:error, :shredded} = Vault.pseudonym(sid)
  end

  test "C4I1 ORDER POSITIVE CONTROL: without the forced tier failure the SAME shred COMMITS the DB tier — sentinel and report both land" do
    sid = seed_subject!()
    assert active_rows(sid) == 1

    assert {:ok, %{attestation: att, report: report}} = Erasure.shred(sid, repo: @repo)
    assert att.state == :shredded
    assert report.outcome == "shredded"

    # The rollback above was a REAL rollback of a tier that otherwise commits: same call,
    # same subject shape, only the repo façade differs.
    assert active_rows(sid) == 0
    assert %{outcome: "shredded"} = Erasure.latest_report(sid, repo: @repo)
  end

  # ===========================================================================
  # FAIL-CLOSED — the STEP 0 pseudonym read (ADR-048 §7.3, the C4 ruling)
  # ===========================================================================

  test "C4I1 FAIL-CLOSED: a pre-step-1 pseudonym read that fails for a reason other than :absent ABORTS the erasure — Kms.shred/1 is never called, nothing is sealed, nothing is attested" do
    sid = seed_subject!()
    assert state_of(sid) == :active
    assert active_rows(sid) == 1

    Application.put_env(:samen_core, :kms_adapter, PseudonymOutageKms)

    # THE RULING: the erasure does not proceed, and it says WHY in its own error class —
    # `:pseudonym_unavailable`, never the `:kms_shred_failed` of a store that was actually
    # asked to destroy something. The distinct atom is what proves the abort happened at
    # STEP 0, before the key was touched.
    assert {:error, {:pseudonym_unavailable, :unavailable}} = Erasure.shred(sid, repo: @repo)

    Application.put_env(:samen_core, :kms_adapter, FileBacked)

    # NOTHING WAS DESTROYED: the DEK is still live and the pseudonym still computes, so a
    # retry when the store heals can still find and withdraw the index rows. A build that
    # proceeded here would have destroyed the key with no ref captured and ORPHANED the
    # residue permanently.
    assert state_of(sid) == :active
    assert {:ok, _} = Vault.pseudonym(sid)

    # Nothing sealed, nothing attested, no report.
    assert active_rows(sid) == 1
    assert Erasure.latest_report(sid, repo: @repo) == nil
  end

  test "C4I1 FAIL-CLOSED POSITIVE CONTROL: the SAME subject with a READABLE pseudonym proceeds through STEP 0 and is erased" do
    sid = seed_subject!()
    assert active_rows(sid) == 1

    # Identical call, identical subject shape — only the pseudonym read is honest. The
    # obligation above therefore fails because the read failed, never because `shred/2`
    # refuses this subject for some unrelated reason.
    assert {:ok, %{report: report}} = Erasure.shred(sid, repo: @repo)
    assert report.outcome == "shredded"
    assert state_of(sid) == :shredded
    assert active_rows(sid) == 0
  end

  test "C4I1 CARVE-OUT: {:error, :shredded} is AUTHORITATIVE, not an outage — the idempotent second shred still proceeds and writes its second report" do
    sid = seed_subject!()

    assert {:ok, _} = Erasure.shred(sid, repo: @repo)
    # The pseudonym is now UNCOMPUTABLE — the exact condition that makes every index row
    # inert, and the reason fail-closed has no residue left to protect here.
    assert {:error, :shredded} = Vault.pseudonym(sid)

    # The shipped idempotency contract (`erasure_test.exs` RED PATH C) is preserved: a
    # strict fail-closed on `:shredded` would turn this into
    # `{:error, {:pseudonym_unavailable, :shredded}}`.
    assert {:ok, %{attestation: att, report: report}} = Erasure.shred(sid, repo: @repo)
    assert att.state == :shredded
    assert att.destroyed_at
    assert report.outcome == "already_shredded"
  end

  test "C4I1 CARVE-OUT: a subject that never had a DEK reads {:error, :absent} and proceeds to the absent-outcome erasure" do
    # Seed (and discard) a real subject first, so the key store is demonstrably REACHABLE:
    # `:absent` must mean "this store has no key for this subject", never "no store".
    _reachable = seed_subject!()
    sid = "c4i1-never-keyed-#{System.unique_integer([:positive])}"
    assert {:error, :absent} = Vault.pseudonym(sid)

    assert {:ok, %{attestation: att, report: report}} = Erasure.shred(sid, repo: @repo)
    assert att.state == :absent
    assert report.outcome == "absent"
  end

  # ===========================================================================
  # The §7.3 step-3 arm and the keying decision it depends on
  # ===========================================================================

  test "C4I1: the §7.3 step-3 arm NEUTRALIZES index rows keyed by the PRE-SHRED pseudonym — stamped withdrawn, never deleted" do
    sid = seed_subject!()
    org_id = Ash.UUID.generate()
    run_id = Ash.UUID.generate()
    assert {:ok, pseudonym} = Vault.pseudonym(sid)
    ref = Compaction.encode_ref(pseudonym)

    {:ok, row} =
      FoldSource
      |> Ash.Changeset.for_create(:record, %{
        org_id: org_id,
        run_id: run_id,
        fold_n: 1,
        subject_ref: ref
      })
      |> Ash.create(authorize?: false)

    # NON-VACUITY: the row exists, is keyed on the pseudonym, and is NOT yet withdrawn.
    assert row.subject_ref == ref
    refute row.withdrawn_at

    assert {:ok, _} = Erasure.shred(sid, repo: @repo, org_id: org_id)

    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        @repo,
        "SELECT afs_withdrawn_at FROM ai_agent_fold_source WHERE afs_subject_ref = $1",
        [ref]
      )

    # KEPT, and STAMPED. §7.3 keeps the rows and kills the key; the arm could only have
    # matched this row by the ref captured at STEP 0, because the pseudonym is now gone.
    assert [[withdrawn_at]] = rows
    assert withdrawn_at
    assert {:error, :shredded} = Vault.pseudonym(sid)
  end

  test "C4I1: source_marker/3 keys a fold citation on the DEK pseudonym (never the subject id) and fails closed when the pseudonym cannot be read" do
    sid = seed_subject!()
    assert {:ok, pseudonym} = Vault.pseudonym(sid)

    assert {:ok, marker} = Compaction.source_marker(Samen.Vault, "rec-1", sid)

    # The ONE keying decision: the marker carries the hex pseudonym, and `encode_ref/1` —
    # the encoder `Samen.Erasure` uses on its own STEP 0 capture — agrees with it exactly.
    # If the two ever disagreed, the erasure arm would match nothing.
    assert marker["subject_ref"] == Compaction.encode_ref(pseudonym)
    refute marker["subject_ref"] == sid
    assert marker["record_id"] == "rec-1"

    Application.put_env(:samen_core, :kms_adapter, PseudonymOutageKms)

    assert {:error, {:pseudonym_unavailable, :unavailable}} =
             Compaction.source_marker(Samen.Vault, "rec-1", sid)
  end

  test "C4I1: the ledger projection reads ONLY {fold_n, subject_ref} out of a fold ledger, and indexes nothing from a malformed one" do
    ref = String.duplicate("ab", 16)

    ledger =
      Jason.encode!(%{
        "folds" => [
          %{
            "n" => 1,
            "summary" => "[fold #1] the earlier turns, summarized",
            "sources" => [
              %{
                "run_id" => "r1",
                "seq" => 1,
                "digest" => "d",
                "markers" => [
                  %{"resource" => "Samen.Vault", "record_id" => "rec-1", "subject_ref" => ref}
                ]
              }
            ]
          }
        ]
      })

    assert FoldSource.citations(ledger) == [{1, ref}]

    # Token-only and fail-quiet on shape: an empty ledger, a ledger with no markers, and a
    # non-JSON blob all index NOTHING rather than guessing a key.
    assert FoldSource.citations(Jason.encode!(%{"folds" => []})) == []
    assert FoldSource.citations(Jason.encode!(%{"folds" => [%{"n" => 1}]})) == []
    assert FoldSource.citations("not json at all") == []
  end
end
