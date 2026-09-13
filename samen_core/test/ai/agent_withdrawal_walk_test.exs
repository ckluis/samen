defmodule C4I2WalkAgents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "c4i2.walk",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end
end

defmodule Samen.AI.AgentWithdrawalWalkTest do
  @moduledoc """
  ADR-048 §7.3 (`T221`, batch C4) — the WITHDRAWAL WALK is **BOUNDED**.

  `Samen.AI.Agent.Compaction.withdraw/2` withdraws the TRANSITIVE CLOSURE of a run's fold
  ledger: the folds citing the erased subject, plus every fold citing one of those. Derived
  provenance is a graph, and a graph a later edit can make cyclic — a fold that cites
  ITSELF (`seq == n`), or a pair that cite each other. **BOUNDED is a requirement, not an
  adjective**: an erasure job that loops on a cycle never completes, and an erasure job that
  never completes is a fail-open erasure job.

  Two independent guarantees are asserted here, each with its own anti-tautology control:

    * the closure is a FIXPOINT over a finite ledger — it halts `:fixpoint` on a cyclic
      chain and marks every reachable fold, in bounded rounds;
    * the hard `@withdraw_max_rounds` cap is REAL and consulted — `max_rounds: 0` halts
      `:round_bound` (control: the default bound halts `:fixpoint`, having done the work).

  These tests carry an explicit `timeout:` so a walk that LOOPS fails by name here instead
  of hanging the suite: the termination claim is asserted, never assumed.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias C4I2WalkAgents.Durable
  alias Samen.AI.Agent.Compaction
  alias Samen.AI.Agent.Run
  alias Samen.Erasure
  alias Samen.Vault
  alias SamenCore.TestRepo

  require Ash.Query

  @summary "[fold #1] the earlier turns, summarized"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    previous_kms = Application.get_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    Samen.AI.Provider.Scripted.reset()
    Samen.AI.Agent.Breaker.reset()

    on_exit(fn ->
      Samen.AI.Provider.Scripted.reset()
      Samen.AI.Agent.Breaker.reset()
      Samen.Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, previous_kms)
    end)

    :ok
  end

  defp scope, do: %Samen.Scope{actor: %{id: "u:#{Ash.UUID.generate()}", org_id: Ash.UUID.generate(), role: :member, plane: :tenant}}

  defp seed_subject! do
    sid = "c4i2-subject-#{System.unique_integer([:positive])}"
    {:ok, _} = Vault.store_field(sid, :pii_email, :emails, "c4i2-#{sid}@example.com", TestRepo)
    sid
  end

  defp reload(run) do
    [row] =
      Run
      |> Ash.Query.filter(id == ^run.id)
      |> Ash.Query.ensure_selected([:org_id, :transcript])
      |> Ash.read!(authorize?: false)

    row
  end

  defp folds_of(run) do
    run = reload(run)
    {:ok, json} = Vault.reveal(run.transcript, TestRepo, subject_id: run.id)
    Map.get(Jason.decode!(json), "folds", [])
  end

  defp put_folds!(run, entries) do
    run = reload(run)
    {:ok, json} = Vault.reveal(run.transcript, TestRepo, subject_id: run.id)
    folded = Map.put(Jason.decode!(json), "folds", entries)

    run
    |> Ash.Changeset.for_update(:advance, %{transcript: Jason.encode!(folded)})
    |> Ash.update!(authorize?: false)

    :ok
  end

  # One ledger entry. `cites` are SAME-RUN fold references (`{run_id, seq}` sources); `ref`
  # is the pseudonym token this entry cites, or nil for an entry that cites no subject.
  defp entry(run_id, n, cites, ref) do
    markers = if ref, do: [%{"resource" => "Samen.Vault", "record_id" => "r-#{n}", "subject_ref" => ref}], else: []

    %{
      "n" => n,
      "summary" => @summary,
      "sources" =>
        for seq <- cites do
          %{
            "run_id" => run_id,
            "seq" => seq,
            "digest" => :crypto.hash(:sha256, @summary) |> Base.encode16(case: :lower),
            "markers" => markers
          }
        end
    }
  end

  # A ledger whose provenance graph is CYCLIC and SELF-CITING:
  #   fold 1 — cites the erased subject AND cites fold 2
  #   fold 2 — cites fold 1        (1 <-> 2 is a two-cycle)
  #   fold 3 — cites fold 3        (a SELF-citing entry) and fold 2
  #   fold 4 — cites fold 4 only   (self-citing, and NOT reachable from the subject)
  # A naive "follow every citation" walk revisits 1 -> 2 -> 1 forever.
  defp cyclic_ledger(run_id, ref) do
    [
      entry(run_id, 1, [2], ref),
      entry(run_id, 2, [1], nil),
      entry(run_id, 3, [3, 2], nil),
      entry(run_id, 4, [4], nil)
    ]
  end

  defp start_run! do
    Application.put_env(:samen_core, Samen.AI.Agent, provider: scripted_provider())
    script(final: "the walk answer")
    s = scope()
    {:ok, run} = Samen.AI.Agent.start(Durable, s, "goal CANARY-walk")
    {s, run}
  end

  # ======================================================================

  @tag :p7
  @tag timeout: 30_000
  test "P7 BOUNDED: the §7.3 withdrawal walk TERMINATES on a cyclic, self-citing fold chain instead of looping" do
    {s, run} = start_run!()
    sid = seed_subject!()
    assert {:ok, pseudonym} = Vault.pseudonym(sid)
    ref = Compaction.encode_ref(pseudonym)

    :ok = put_folds!(run, cyclic_ledger(run.id, ref))

    # NON-VACUITY: the cycle really is in the ledger before the shred, and every summary
    # really is the unmarked body.
    before = folds_of(run)
    assert length(before) == 4
    assert Enum.all?(before, &(&1["summary"] == @summary))

    # THE TERMINATION CLAIM. A walk that loops on 1 <-> 2 never returns and this test fails
    # on its own `timeout:` rather than hanging the suite.
    assert {:ok, _} = Erasure.shred(sid, repo: TestRepo, org_id: s.actor.org_id)

    after_walk = Map.new(folds_of(run), fn f -> {f["n"], f["summary"]} end)

    # Folds 1, 2 and 3 are ALL reachable from the erased subject (1 directly; 2 cites 1;
    # 3 cites 2) and are every one of them neutralized with the fixed bounded marker.
    for n <- [1, 2, 3] do
      assert after_walk[n] == Compaction.withdrawn_marker(n),
             "fold ##{n} is reachable from the erased subject and must be NEUTRALIZED — got #{inspect(after_walk[n])}"
    end

    # ANTI-TAUTOLOGY: fold 4 is self-citing but NOT reachable from the subject. A walk that
    # simply marked every fold (or gave up and swept the ledger) would satisfy the arms
    # above and fail here.
    assert after_walk[4] == @summary,
           "an unreachable self-citing fold must survive byte-unchanged — the walk is a MATCH, not a sweep"
  end

  @tag :p7
  @tag timeout: 30_000
  test "P7 BOUNDED: the walk reports a FIXPOINT halt on the cyclic chain, and the hard round cap is real (max_rounds: 0 halts :round_bound)" do
    {_s, run} = start_run!()
    sid = seed_subject!()
    assert {:ok, pseudonym} = Vault.pseudonym(sid)
    ref = Compaction.encode_ref(pseudonym)

    :ok = put_folds!(run, cyclic_ledger(run.id, ref))

    # POSITIVE CONTROL: with the shipped bound the walk finishes by FIXPOINT — it halted
    # because it ran out of new folds, not because it hit the cap.
    report = Compaction.withdraw(ref, repo: TestRepo)

    assert report.halted == :fixpoint
    assert report.runs_walked == 1
    assert report.folds_withdrawn == 3
    assert report.rounds < 64, "a 4-entry ledger must reach its fixpoint in a handful of rounds"

    # THE BOUND IS CONSULTED, not decorative: starve it and the walk halts on the cap. A
    # build whose `@withdraw_max_rounds` were ignored would pass the control above and fail
    # here, so the boundedness claim is refutable rather than asserted.
    starved = Compaction.withdraw(ref, repo: TestRepo, max_rounds: 0)
    assert starved.halted == :round_bound
  end
end
