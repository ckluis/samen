defmodule C4RTestAgents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "c4r.durable",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end
end

defmodule Samen.AI.AgentWithdrawalTest do
  @moduledoc """
  ADR-048 batch C4 (`T221`) — RED-FIRST tests for WITHDRAWAL PROPAGATION, written against the
  UNBUILT feature. This file implements NOTHING under `samen_core/lib` (`C4R`'s criterion #20).

  The four obligations, each tagged so its own red can be captured in isolation
  (`mix test <this file> --only p7|p8|p12|p14 --trace`):

    * **P7** (`:p7`, ADR-048 §8 `:500`) — withdrawal reaches folds. Shred a subject; EVERY fold
      citing it must be marked with §7.3 step 3's neutralizing marker. Anti-tautology positive
      control: a **non**-erased subject's fold SURVIVES the same shred, unmarked.
    * **P8** (`:p8`, ADR-048 §8 `:501`) — the pseudonym-keyed provenance index is unlinkable
      after shred, asserted **ON THE PSEUDONYM**, never on absence of rows. §7.3 is explicit that
      the rows are NOT deleted: the key dies and they go permanently inert.
    * **P12** (`:p12`, ADR-048 §8, D3) — compaction output is **refused at write time** toward
      `pgvector`, via the new bounded atom `:cross_run_write_refused`. This is a CATEGORICAL
      WRITE-TIME REFUSAL, not a cleanup rule: a build that embeds every fold summary into
      pgvector and dutifully marks them on shred passes P7 AND P8 and violates D3 outright
      (P12's own text says so). The red therefore fails because the write was NOT REFUSED, never
      because a cleanup marker was missing. Mandatory positive control: a **non**-compaction
      artifact's legitimate write to the SAME store still succeeds.
    * **P14** (`:p14`, ADR-048 §8, D6) — a **live run** holding a walk-invalidated fold
      terminates on its **OWN NEXT TURN** with the literal three-tuple
      `{:error, :source_withdrawn, run}`. Checked on the next turn, NOT on whether the fold was
      marked (that is P7's claim). Mandatory positive control: a run whose fold is **not**
      invalidated completes its next turn normally and does not return that tuple.

  **Why each of these is a red today** (measured at HEAD `1c3c388`, `--include`-before-`--` form):
  `:source_withdrawn` = 0 hits and `:cross_run_write_refused` = 0 hits across `samen_core` +
  `samen_web`. There is no `Samen.AI.Agent.Compaction.withdraw/2` walk, no pseudonym-keyed
  provenance index, and no `derived_summary` discovery class. Each test below is expected to FAIL
  by name at the assertion that names the missing behaviour — never at a stubbed feature, because
  this node stubs nothing.

  **The fold ledger is written by a TEST-ONLY driver**, through the SAME accepted `:advance`
  persistence path the shipped compactor uses (`Samen.AI.Agent.Run`'s `update :advance`,
  `run.ex:245`) — the precedent set by `agent_dual_view_test.exs`'s P2 driver. It is never a
  compactor and never an implementation.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias C4RTestAgents.Durable
  alias Samen.AI.Agent
  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Run
  alias Samen.AI.CrossRunWriteGuard
  alias Samen.AI.Embedder
  alias Samen.AI.Embeddings
  alias Samen.AI.Provider.Scripted
  alias Samen.Erasure
  alias Samen.Vault
  alias SamenCore.Support.EmbeddingsDomain.Article
  alias SamenCore.TestRepo

  require Ash.Query

  # The fold summary body a fold ledger entry carries before any withdrawal walk runs. Shared by
  # P7's obligation and its positive control, by P12's obligation, and by P14's setup — the
  # single literal every one of them measures against (CF-15: an obligation and its control must
  # not be variable-disjoint).
  @fold_summary "[fold #1] the earlier turns, summarized"

  # ADR-048 §7.3 step 3 — invalidate by NEUTRALIZING, never by deleting. The marker is fixed,
  # bounded and uniform, so the transform is many-to-one and carries no residual signal.
  defp withdrawn_marker(n), do: "[withdrawn: fold ##{n}, source withdrawn]"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    previous_kms = Application.get_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    Scripted.reset()
    Breaker.reset()

    on_exit(fn ->
      Scripted.reset()
      Breaker.reset()
      Samen.Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, previous_kms)
    end)

    :ok
  end

  # ======================================================================
  # helpers — none of these implement anything; they read the shipped surfaces
  # ======================================================================

  defp scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp new_scope, do: scope(Ash.UUID.generate())

  defp reload(run) do
    [row] =
      Run
      |> Ash.Query.filter(id == ^run.id)
      |> Ash.Query.ensure_selected([:org_id, :transcript])
      |> Ash.read!(authorize?: false)

    row
  end

  defp reveal_transcript(run) do
    run = reload(run)
    %Samen.Masked{} = masked = run.transcript
    Vault.reveal(masked, TestRepo, subject_id: run.id)
  end

  # The ADR-048 §4 compaction LEDGER, read out of the ONE sealed transcript blob (C1's
  # `encode_transcript/2` writes `"folds" => []`; C2 first makes it non-empty).
  defp folds_of(run) do
    {:ok, json} = reveal_transcript(run)
    Map.get(Jason.decode!(json), "folds", [])
  end

  # A subject with a LIVE DEK, so `Samen.Vault.pseudonym/1` (vault.ex:276) is computable before
  # the shred and `{:error, :shredded}` after it. Same seed shape as `erasure_test.exs`.
  defp seed_subject! do
    sid = "c4r-subject-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.store_field(sid, :pii_email, :emails, "c4r-#{sid}@example.com", TestRepo)
    sid
  end

  # The `subject_ref` ADR-048 §7.3 stores in the provenance index: the DEK-keyed pseudonym
  # `HMAC(psk_S, subject_id)`, hex-encoded so it is a token, never a value.
  defp subject_ref(pseudonym), do: Base.encode16(pseudonym, case: :lower)

  # One §7.3 fold-ledger entry: token-only provenance (`{run_id, seq}`, a content digest, and a
  # `{resource, record_id, subject_ref}` source marker). NO VALUES, EVER — `bounded_outcomes/1`'s
  # default-deny posture.
  defp fold_entry(run_id, n, pseudonym) do
    %{
      "n" => n,
      "summary" => @fold_summary,
      "sources" => [
        %{
          "run_id" => run_id,
          "seq" => n,
          "digest" => :crypto.hash(:sha256, @fold_summary) |> Base.encode16(case: :lower),
          "markers" => [
            %{
              "resource" => "Samen.Vault",
              "record_id" => "c4r-record-#{n}",
              "subject_ref" => subject_ref(pseudonym)
            }
          ]
        }
      ]
    }
  end

  # TEST-ONLY fold driver — never a compactor, never an `:after_compaction` call site. Persists
  # the ledger through the SAME accepted `:advance` path the shipped compactor writes through
  # (`run.ex:245`), exactly as `agent_dual_view_test.exs`'s P2 driver does.
  defp put_folds!(run, entries) do
    {:ok, json} = reveal_transcript(run)
    folded = Map.put(Jason.decode!(json), "folds", entries)

    run
    |> reload()
    |> Ash.Changeset.for_update(:advance, %{transcript: Jason.encode!(folded)})
    |> Ash.update!(authorize?: false)

    :ok
  end

  # Every ledger entry whose source markers cite `subject_ref` — the walk's own match predicate,
  # applied by the test with the pseudonym it captured BEFORE the shred (after it, the key is
  # gone and the pseudonym can never be recomputed — which is the whole point of P8).
  defp folds_citing(run, pseudonym) do
    ref = subject_ref(pseudonym)

    Enum.filter(folds_of(run), fn fold ->
      fold
      |> Map.get("sources", [])
      |> Enum.flat_map(&Map.get(&1, "markers", []))
      |> Enum.any?(&(Map.get(&1, "subject_ref") == ref))
    end)
  end

  # The ADR-048 §7.3 pseudonym-keyed provenance index, which lives OUTSIDE the sealed transcript
  # body. It does not exist at HEAD 1c3c388, so this returns `:no_provenance_index` today — the
  # red P8 measures. Never a stub: nothing here creates the table.
  defp provenance_rows(ref) do
    {:ok, %{rows: rows}} =
      TestRepo.query(
        "SELECT afs_run_id, afs_fold_n, afs_subject_ref FROM ai_agent_fold_source WHERE afs_subject_ref = $1",
        [ref]
      )

    rows
  rescue
    e -> {:no_provenance_index, Exception.message(e)}
  end

  defp embed_opts, do: [repo: TestRepo]

  defp row_count(org_id) do
    {:ok, %{rows: [[n]]}} =
      TestRepo.query("SELECT count(*) FROM aie_embedding WHERE aie_org_id = $1::text::uuid", [
        org_id
      ])

    n
  end

  defp put_agent_config(kv) do
    previous = Application.get_env(:samen_core, Samen.AI.Agent, [])
    Application.put_env(:samen_core, Samen.AI.Agent, Keyword.merge(previous, kv))
    on_exit(fn -> Application.put_env(:samen_core, Samen.AI.Agent, previous) end)
  end

  defp scripted_worker_config, do: put_agent_config(provider: scripted_provider())

  # A LIVE (`:queued`) run holding one fold that cites `pseudonym` — P14's subject. `start/4`
  # creates the `:queued` cursor; `execute_batch/1` is its OWN NEXT TURN.
  defp live_run_with_fold!(s, pseudonym, goal) do
    scripted_worker_config()
    script(final: "the #{goal} answer")

    {:ok, run} = Agent.start(Durable, s, goal)
    :ok = put_folds!(run, [fold_entry(run.id, 1, pseudonym)])
    run
  end

  # ======================================================================
  # P7 — withdrawal reaches folds (ADR-048 §8 `:500`; §7.3 steps 1-3)
  # ======================================================================

  @tag :p7
  test "P7: RED — shredding a subject marks EVERY fold citing it with the §7.3 neutralizing withdrawn marker" do
    s = new_scope()
    sid = seed_subject!()
    assert {:ok, pseudonym} = Vault.pseudonym(sid)

    script(final: "the CANARY-p7 answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-p7")
    :ok = put_folds!(run, [fold_entry(run.id, 1, pseudonym)])

    # NON-VACUITY precondition: the ledger really carries a fold citing this subject, and its
    # body really is the unmarked summary. Without this the post-shred assertion could pass on
    # an empty ledger.
    assert [%{"n" => 1, "summary" => @fold_summary}] = folds_citing(run, pseudonym)

    assert {:ok, _} = Erasure.shred(sid, repo: TestRepo, org_id: s.actor.org_id)

    # THE RED — ADR-048 §7.3 step 3. The withdrawal walk does not exist at HEAD 1c3c388
    # (`Samen.AI.Agent.Compaction.withdraw/2`: zero grep hits), so nothing marks the fold and
    # this assertion fails with the untouched summary still in the ledger.
    for fold <- folds_citing(run, pseudonym) do
      assert fold["summary"] == withdrawn_marker(fold["n"]),
             "ADR-048 §7.3 step 3: shredding the subject must NEUTRALIZE every citing fold with " <>
               "the fixed bounded marker #{inspect(withdrawn_marker(fold["n"]))}, never leave its " <>
               "summary standing — got #{inspect(fold["summary"])}. The withdrawal walk " <>
               "(Samen.AI.Agent.Compaction.withdraw/2) is not built."
    end
  end

  @tag :p7
  test "P7 POSITIVE CONTROL: a NON-erased subject's fold SURVIVES the shred of a different subject, unmarked" do
    s = new_scope()
    erased = seed_subject!()
    kept = seed_subject!()
    assert {:ok, erased_pseudonym} = Vault.pseudonym(erased)
    assert {:ok, kept_pseudonym} = Vault.pseudonym(kept)
    refute erased_pseudonym == kept_pseudonym

    script(final: "the CANARY-p7-control answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-p7-control")

    :ok =
      put_folds!(run, [
        fold_entry(run.id, 1, erased_pseudonym),
        fold_entry(run.id, 2, kept_pseudonym)
      ])

    assert [%{"n" => 2, "summary" => @fold_summary}] = folds_citing(run, kept_pseudonym)

    assert {:ok, _} = Erasure.shred(erased, repo: TestRepo, org_id: s.actor.org_id)

    # ANTI-TAUTOLOGY: the walk must be a MATCH, not a sweep. A build that marks every fold in the
    # run (or drops the ledger) would satisfy the obligation test above and fail here.
    for fold <- folds_citing(run, kept_pseudonym) do
      assert fold["summary"] == @fold_summary,
             "a NON-erased subject's fold must survive another subject's shred byte-unchanged — " <>
               "got #{inspect(fold["summary"])}"

      refute fold["summary"] == withdrawn_marker(fold["n"])
    end

    assert {:ok, ^kept_pseudonym} = Vault.pseudonym(kept)
  end

  # ======================================================================
  # P8 — the provenance index is unlinkable after shred (ADR-048 §8 `:501`; §7.3)
  # ======================================================================

  @tag :p8
  test "P8: RED — after shred NO provenance index row resolves to the subject, asserted ON THE PSEUDONYM (never on absence of rows)" do
    s = new_scope()
    sid = seed_subject!()
    assert {:ok, pseudonym} = Vault.pseudonym(sid)
    ref = subject_ref(pseudonym)

    script(final: "the CANARY-p8 answer")
    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-p8")
    :ok = put_folds!(run, [fold_entry(run.id, 1, pseudonym)])

    # NON-VACUITY, ASSERTED ON THE PSEUDONYM: before the shred the index must carry at least one
    # row keyed by HMAC(psk_S, subject_id). This is the assertion that makes the post-shred claim
    # mean something — an index that never had a row is not unlinkable, it is empty.
    rows = provenance_rows(ref)

    assert is_list(rows) and rows != [],
           "ADR-048 §7.3's pseudonym-keyed provenance index does not exist at HEAD 1c3c388 — " <>
             "`ai_agent_fold_source` keyed on `afs_subject_ref` is a forward reference. " <>
             "provenance_rows/1 returned #{inspect(rows)}. Until it exists there is no index " <>
             "row to prove unlinkable, so P8 is vacuous."

    assert {:ok, _} = Erasure.shred(sid, repo: TestRepo, org_id: s.actor.org_id)

    # After the shred the DEK is gone, so the pseudonym — the ONLY key that resolves an index row
    # back to the subject — can never be recomputed. The rows are NOT deleted (§7.3: the index
    # self-erases with the subject, for free); they go permanently inert.
    assert {:error, :shredded} = Vault.pseudonym(sid),
           "the index must self-erase WITH the subject: after shred the pseudonym must be " <>
             "uncomputable, which is what makes every remaining row unlinkable"

    surviving = provenance_rows(ref)

    assert is_list(surviving) and surviving != [],
           "P8 is asserted ON THE PSEUDONYM, not on absence of rows — §7.3 keeps the rows and " <>
             "kills the key. A build that DELETES the index rows would satisfy a naive " <>
             "'no rows remain' check while proving nothing about unlinkability. Got " <>
             "#{inspect(surviving)}."
  end

  # ======================================================================
  # P12 — D3: compaction output is REFUSED AT WRITE TIME toward pgvector (ADR-048 §8)
  #
  # A CATEGORICAL WRITE-TIME REFUSAL, not a cleanup rule. The red below fails because the write
  # is NOT REFUSED and the row LANDS — never because a cleanup marker is missing.
  # ======================================================================

  @tag :p12
  test "P12: RED — a fold summary's embedding write toward pgvector is REJECTED BEFORE IT LANDS with {:error, :cross_run_write_refused}" do
    org = Ash.UUID.generate()
    s = scope(org)
    id = Ash.UUID.generate()
    before = row_count(org)

    # The D3 violation shape, exactly: compaction output routed at a LEGITIMATELY EMBEDDABLE
    # surface (`Article.body`), declaring its own provenance as a fold summary. The refusal is
    # CATEGORICAL — it keys off the artifact being compaction output, not off the field being
    # ineligible — so it must fire even though this very field/resource pair embeds fine for
    # ordinary content (proven by the positive control below, which shares this call shape).
    result =
      Embeddings.embed_field(
        s,
        Article,
        id,
        :body,
        @fold_summary,
        embed_opts() ++ [source_kind: :fold_summary]
      )

    assert result == {:error, :cross_run_write_refused},
           "ADR-048 §8 P12 / D3: compaction output must be REFUSED AT WRITE TIME toward pgvector " <>
             "or any cross-run store, via the new bounded atom :cross_run_write_refused " <>
             "(zero grep hits at HEAD 1c3c388). Got #{inspect(result)} — the call-site refusal " <>
             "is not built, so the fold summary reached the store unblocked."

    assert row_count(org) == before,
           "REJECTED BEFORE IT LANDS: no aie_embedding row may be written for a compaction " <>
             "artifact. A build that writes the vector and cleans it up later passes P7 and P8 " <>
             "and violates D3 outright."
  end

  @tag :p12
  test "P12 POSITIVE CONTROL: a NON-compaction artifact's legitimate write to the SAME pgvector store still succeeds" do
    org = Ash.UUID.generate()
    s = scope(org)
    id = Ash.UUID.generate()
    before = row_count(org)

    # Same store, same resource, same field, same opts helper as the obligation above — only the
    # declared provenance differs. This is what proves the red is not satisfied by a store that
    # accepts nothing.
    result =
      Embeddings.embed_field(
        s,
        Article,
        id,
        :body,
        "quarterly billing invoices and payment reconciliation reports",
        embed_opts() ++ [source_kind: :record_field]
      )

    assert {:ok, vector} = result
    assert length(vector) > 0, "a real embedding vector, never an empty one"

    assert row_count(org) == before + 1,
           "the refusal must be CATEGORICAL to compaction output, not a blanket store failure — " <>
             "an ordinary non-compaction write must still land exactly one row"
  end

  @tag :p12
  test "P12 CATEGORICAL: a fold summary is REFUSED at EVERY cross-run store and through EVERY samen_core/lib call site that reaches one — embed_field/6, embed_record/4 and reembed_stale/1" do
    org = Ash.UUID.generate()
    s = scope(org)
    before = row_count(org)

    # --- (1) CATEGORICAL OVER DESTINATIONS ---------------------------------------------
    # ADR-048 §7.1: compaction output is ineligible for "pgvector ... or any cross-run
    # memory store, fact table, or cache". So the refusal may NOT be conditional on the
    # destination being enumerated — a store nobody has written yet must refuse too, or a
    # future fact table ships a hole simply by not being on the list.
    stores = CrossRunWriteGuard.cross_run_stores()

    assert :pgvector in stores,
           "pgvector is a cross-run store and must be enumerated; got #{inspect(stores)}"

    for store <- stores ++ [:a_cross_run_fact_table_no_one_has_written_yet] do
      assert CrossRunWriteGuard.check(store, source_kind: :fold_summary) ==
               {:error, :cross_run_write_refused},
             "D3 is CATEGORICAL: a fold summary must be refused toward #{inspect(store)} too, " <>
               "not only toward the stores that happen to exist today"

      assert CrossRunWriteGuard.check(store, source_kind: :record_field) == :ok,
             "…and it must stay a refusal of COMPACTION OUTPUT specifically — a guard that " <>
               "refuses every write toward #{inspect(store)} proves nothing"
    end

    # Every compaction artifact §7.1 itself enumerates, not just the fold summary the
    # obligation above drives: "fold summaries, extracted durable facts, memos, working
    # notes, any text a summarizer produced from a run's history".
    kinds = CrossRunWriteGuard.compaction_source_kinds()

    assert length(kinds) >= 3, "§7.1 enumerates more than one compaction artifact"
    assert :fold_summary in kinds

    for kind <- kinds do
      assert CrossRunWriteGuard.check(:pgvector, source_kind: kind) ==
               {:error, :cross_run_write_refused},
             "#{inspect(kind)} is compaction output and may not enter a cross-run store"
    end

    # --- (2) CATEGORICAL OVER CALL SITES -----------------------------------------------
    # The write-reaching call sites `grep -rn 'store_vector\|embed_field' samen_core/lib`
    # reports are exactly three: `embed_field/6` → `store_vector/8` (the only INSERT into
    # the pgvector table), `embed_record/4` → `embed_field/6`, and `reembed_stale/1` →
    # `reembed_row/3` → `embed_field/6`. Each is driven below with fold-summary provenance
    # and each must refuse — a refusal wired into one entry point and not the others is a
    # cleanup rule wearing a refusal's clothes.

    # (a) `embed_field/6`, direct.
    assert Embeddings.embed_field(
             s,
             Article,
             Ash.UUID.generate(),
             :body,
             @fold_summary,
             embed_opts() ++ [source_kind: :fold_summary]
           ) == {:error, :cross_run_write_refused}

    # (b) `embed_record/4` — the whole-record fan-out over declared embeddable fields.
    record = struct!(Article, id: Ash.UUID.generate(), body: @fold_summary)

    assert Embeddings.embed_record(
             s,
             record,
             Article,
             embed_opts() ++ [source_kind: :fold_summary]
           ) == {:error, :cross_run_write_refused}

    assert row_count(org) == before,
           "REJECTED BEFORE IT LANDS: neither call site may write a row and clean it up later"

    # (c) `reembed_stale/1` → `reembed_row/3` — the T186 backfill, which re-runs
    # `embed_field/6` for rows the store already holds. Seed ONE legitimate row (it must
    # succeed — the same anti-tautology control as above, on this path), move the model
    # identifier so the row is stale, then re-run the backfill with fold-summary
    # provenance: the refusal must reach here too and rewrite nothing.
    assert {:ok, _vector} =
             Embeddings.embed_field(
               s,
               Article,
               Ash.UUID.generate(),
               :body,
               "ordinary non-compaction content, embedded through the backfill's own path",
               embed_opts() ++ [source_kind: :record_field]
             )

    seeded = row_count(org)

    assert seeded == before + 1,
           "the control write must LAND, or the backfill has no stale row to find and the " <>
             "assertion below is vacuous"

    assert {:ok, %{reembedded: 0, errors: errors}} =
             Embeddings.reembed_stale(
               embed_opts() ++
                 [
                   embedder: {Embedder.Deterministic, %{model: "v2-embedder"}},
                   source_kind: :fold_summary,
                   record_loader: fn _resource, id ->
                     {:ok, struct!(Article, id: id, body: @fold_summary)}
                   end
                 ]
             )

    assert errors != [], "the stale row must have been visited, not skipped"

    assert Enum.all?(errors, fn {_row, reason} -> reason == :cross_run_write_refused end),
           "the backfill path must surface the SAME bounded refusal, never a generic error; " <>
             "got #{inspect(errors)}"

    assert row_count(org) == seeded,
           "REJECTED BEFORE IT LANDS on the backfill path too: nothing was rewritten"
  end

  # ======================================================================
  # P14 — D6: a LIVE run holding a walk-invalidated fold terminates on its OWN NEXT TURN
  # (ADR-048 §8; §7.3 step 5). Checked on the NEXT TURN, not on whether the fold was marked.
  # ======================================================================

  @tag :p14
  test "P14: RED — a live run whose fold's source was withdrawn returns the literal three-tuple {:error, :source_withdrawn, run} on its OWN NEXT TURN" do
    s = new_scope()
    sid = seed_subject!()
    assert {:ok, pseudonym} = Vault.pseudonym(sid)

    run = live_run_with_fold!(s, pseudonym, "goal CANARY-p14")

    # NON-VACUITY: the live run really is holding a fold citing this subject before the shred.
    assert [%{"n" => 1, "summary" => @fold_summary}] = folds_citing(run, pseudonym)

    assert {:ok, _} = Erasure.shred(sid, repo: TestRepo, org_id: s.actor.org_id)

    # THE ASSERTION IS ON THE RUN'S OWN NEXT TURN — deliberately NOT on whether the fold was
    # marked (that is P7's claim, `:500`), and deliberately not `:context_exhausted` (that is
    # P3's terminal, `:496`). A run that keeps executing on the neutralized context is the
    # defect D6 exists to make impossible.
    result = Agent.execute_batch(reload(run))

    assert match?({:error, :source_withdrawn, %Run{}}, result),
           "ADR-048 §7.3 step 5 / §8 P14: the live run holding a withdrawn fold must terminate " <>
             "fail-honest on its NEXT TURN with the literal three-tuple " <>
             "{:error, :source_withdrawn, run}. Got #{inspect(result)} — `:source_withdrawn` has " <>
             "zero grep hits at HEAD 1c3c388, so the run continued on cached text instead."
  end

  @tag :p14
  test "P14 POSITIVE CONTROL: a run whose fold is NOT invalidated completes its next turn normally and does NOT return {:error, :source_withdrawn, run}" do
    s = new_scope()
    cited = seed_subject!()
    unrelated = seed_subject!()
    assert {:ok, cited_pseudonym} = Vault.pseudonym(cited)

    run = live_run_with_fold!(s, cited_pseudonym, "goal CANARY-p14-control")

    assert [%{"n" => 1, "summary" => @fold_summary}] = folds_citing(run, cited_pseudonym)

    # Shred a DIFFERENT subject: this run's fold source is untouched, so nothing may invalidate
    # it. Same execute_batch/1 next-turn probe as the obligation above.
    assert {:ok, _} = Erasure.shred(unrelated, repo: TestRepo, org_id: s.actor.org_id)

    result = Agent.execute_batch(reload(run))

    refute match?({:error, :source_withdrawn, _}, result),
           "ANTI-TAUTOLOGY: a run whose fold was never invalidated must complete its next turn " <>
             "normally. A build that returns {:error, :source_withdrawn, run} unconditionally " <>
             "would satisfy the obligation test above and fail here. Got #{inspect(result)}."

    assert {:ok, ^cited_pseudonym} = Vault.pseudonym(cited),
           "the cited subject's DEK must still be live — only `unrelated` was shredded"
  end
end
