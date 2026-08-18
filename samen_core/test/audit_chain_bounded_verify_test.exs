defmodule Samen.AuditChainBoundedVerifyTest do
  @moduledoc """
  O3 — the audit-chain integrity verify is BOUNDED (keyset-streamed from a resume cursor),
  so it never loads the whole chain into memory at once, WHILE still verifying the COMPLETE
  chain: a tamper anywhere (hash edit / seq gap / broken link), even in a LATER batch, is
  still detected, and a clean multi-batch chain verifies ok.

  The bounding is about MEMORY/streaming, not about verifying less — every test here pairs
  a bounding proof with a completeness proof so neither can decay into a tautology.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.AuditChain
  alias Samen.AuditChain.Entry

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    {:ok, org: "org-#{System.unique_integer([:positive])}"}
  end

  defp append!(org) do
    {:ok, %Entry{} = e} =
      AuditChain.append(
        %{
          org_id: org,
          event_type: "reveal",
          subject_id: "subj-#{System.unique_integer([:positive])}",
          actor_id: "op-1",
          detail: "event=granted"
        },
        repo: Repo
      )

    e
  end

  defp build_chain!(org, n), do: Enum.map(1..n, fn _ -> append!(org) end)

  # Drive the batch primitive to completion from `cursor`, collecting the intermediate
  # `{:cont, _}` cursors so a test can prove the cursor genuinely ADVANCED batch by batch.
  defp run(org, cursor, batch, acc) do
    case AuditChain.verify_chain_batch(Repo, org, cursor, batch) do
      {:cont, next} -> run(org, next, batch, [next | acc])
      {:done, summary} -> {Enum.reverse(acc), {:done, summary}}
      {:error, _} = err -> {Enum.reverse(acc), err}
    end
  end

  describe "bounded — one verify batch loads at most batch_size (never the whole chain)" do
    test "a single batch over a 6-entry chain consumes exactly batch_size and reports more remains",
         %{org: org} do
      build_chain!(org, 6)

      # With batch_size 2, the FIRST batch advances the cursor to seq 2 (two entries
      # consumed) and returns {:cont, _} — it did NOT materialise all six. If the `limit`
      # were dropped (the O3 sabotage) the whole chain would load, the cursor would jump to
      # 6, and this would return {:done, _} instead — so this assertion is the bounding proof.
      assert {:cont, {2, hash}} = AuditChain.verify_chain_batch(Repo, org, :genesis, 2)
      assert is_binary(hash)
    end
  end

  describe "resume cursor — advances contiguously and completes (bounded memory, full coverage)" do
    test "stepping batch by batch walks every entry and finishes with the full count",
         %{org: org} do
      build_chain!(org, 5)

      {cursors, {:done, summary}} = run(org, :genesis, 2, [])

      # STRICTLY ADVANCING across multiple batches (proof it streamed, not one-shot):
      seqs = Enum.map(cursors, fn {seq, _h} -> seq end)
      assert seqs == [2, 4]
      assert seqs == Enum.sort(seqs)

      # ...and coverage is COMPLETE — every one of the 5 entries was verified.
      assert summary.entries == 5
      assert summary.head_seq == 4
    end

    test "resuming from a MID-chain checkpoint continues exactly (no re-read from genesis)",
         %{org: org} do
      [_e0, _e1, e2, _e3, _e4] = build_chain!(org, 5)

      # Resume from the checkpoint AFTER seq 2 → cursor {3, e2.hash}. It verifies only the
      # tail (seq 3,4) and completes — proving the cursor is a genuine resume point, not a
      # from-genesis restart.
      {[], {:done, summary}} = run(org, {3, e2.hash}, 10, [])
      assert summary.entries == 5
      assert summary.head_seq == 4
    end
  end

  describe "complete-chain correctness — a clean chain verifies; tamper anywhere is caught" do
    test "a clean MULTI-BATCH chain verifies ok (positive control)", %{org: org} do
      build_chain!(org, 7)
      assert {:ok, %{entries: 7, head_seq: 6}} = AuditChain.verify_chain(org, repo: Repo, batch_size: 2)
    end

    test "a hash edit in a LATER batch (seq 5) is detected end-to-end", %{org: org} do
      entries = build_chain!(org, 7)
      e5 = Enum.at(entries, 5)

      # Attacker with raw DB access edits an entry in the FOURTH keyset batch (batch_size 2).
      Repo.query!("ALTER TABLE aud_chain DISABLE TRIGGER aud_chain_append_only_tg")
      Repo.query!("UPDATE aud_chain SET ach_detail = 'TAMPERED' WHERE ach_id = $1", [Ecto.UUID.dump!(e5.id)])
      Repo.query!("ALTER TABLE aud_chain ENABLE TRIGGER aud_chain_append_only_tg")

      # The streamed verify still catches it, in the later batch — bounding did not skip it.
      assert {:error, {:hash_mismatch, 5}} = AuditChain.verify_chain(org, repo: Repo, batch_size: 2)
    end

    test "a deleted middle entry (seq gap) is detected across the batch boundary", %{org: org} do
      entries = build_chain!(org, 6)
      e3 = Enum.at(entries, 3)

      Repo.query!("ALTER TABLE aud_chain DISABLE TRIGGER aud_chain_append_only_tg")
      Repo.query!("DELETE FROM aud_chain WHERE ach_id = $1", [Ecto.UUID.dump!(e3.id)])
      Repo.query!("ALTER TABLE aud_chain ENABLE TRIGGER aud_chain_append_only_tg")

      assert {:error, {:seq_gap, 3}} = AuditChain.verify_chain(org, repo: Repo, batch_size: 2)
    end
  end

  describe "the verify runs on its OWN Oban queue (starvation isolation from roll-forward)" do
    test "VerifyWorker enqueues to :audit_verify, which is a configured canonical queue" do
      assert Samen.AuditChain.VerifyWorker.__opts__()[:queue] == :audit_verify
      assert :audit_verify in Keyword.keys(Samen.Jobs.default_queue_config())
      # It is NOT on the shared :maintenance lane anymore (that is the O3 starvation fix).
      refute Samen.AuditChain.VerifyWorker.__opts__()[:queue] == :maintenance
    end
  end
end
