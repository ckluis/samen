defmodule GC17BTestAgents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "gc17b.durable",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end
end

defmodule Samen.AI.AgentFoldReuseCostTest do
  @moduledoc """
  ADR-048 §6 / ruling UXD-18 — the MEASURED COST of fold reuse on replay (coverage gap
  **CF-17(b)**).

  `agent_compaction_test.exs`'s `P6 CASE A` already proves a replay finds the
  `"proposed"` fold-ledger row and stamps it `meta: %{"replayed" => true}` with a
  byte-identical body. That stamp is **self-reported**: `reuse_fold!/5` is the path that
  writes `"replayed" => true`, and it writes it ABOUT ITSELF. A path that stamped
  `replayed=true` while silently re-deriving the fold — running the §5 summarize call
  again and billing the span again — satisfies every assertion `P6 CASE A` makes. The
  fold is a pure function of `{run_id, turn_index, view state}` (that is exactly why
  `agent.ex` says the stamp is what "makes reuse refutable"), so the BODY cannot tell a
  reuse from a re-derivation either.

  What distinguishes them is what they SPEND. This file pins reuse on cost, not on the
  claim:

    * **`input_tokens_used` / `output_tokens_used`** — `apply_fold!/4`'s `:advance`
      bills `est_tokens(span.folded)` in and `est_tokens([span.marker])` out (§6: "the
      tokens are real and are billed"); `reuse_fold!/5`'s `:advance` carries the
      transcript and NOTHING else. A reuse therefore moves neither counter.
    * **the provider's own recording** (`Samen.AI.Provider.Scripted.sent_payloads/0`) —
      a FOLDING turn makes TWO calls (§5#1's governed summarize, then the turn's own); a
      REUSING turn makes ONE. Re-derivation is visible as a second call on the replay.

  ## The two arms (complementary on the SAME measured quantity)

    * **REUSE arm** — `P6 CASE A`'s fixture: a crash inside the turn's own provider call,
      after checkpoint 1 committed the `"proposed"` entry. Across the replay the two
      counters are **byte-identical** and exactly **ONE** provider call rides it.
    * **DERIVE arm (the anti-tautology control, MANDATORY)** — `P6 CASE B`'s fixture: no
      ledger row exists, so the same fold is legitimately DERIVED. Both counters move
      **strictly up** and the summarize call is there in the recording.

  The control is what makes the reuse arm's zero a MEASUREMENT rather than a counter
  that never moves: the two arms assert opposite directions of one quantity read through
  one accessor (`cost/1`), so no single constant satisfies both.

  ## The shared, mutation-refutable binding (anti-tautology, MANDATORY)

  Because the arms are complementary on `cost/1`, no mutation can flip both THROUGH it.
  The mutation hangs instead on the ONE literal both arms assert **PRESENT, in the same
  direction**: `@cf17b_canary`, carried in both goals and read back from BOTH persisted
  transcripts through `goal_of/1` — never through `folds_of/1` or `cost/1`, which ARE
  the properties under test and must stay disjoint from the shared binding. Change that
  single literal at the assertion site and BOTH arms fail together.

  Sabotage twin: `scripts/sabotages/330-adr048-cf17b-fold-reuse-bills-for-reused-fold.patch`.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias GC17BTestAgents.Durable
  alias Samen.AI.Agent
  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.TurnWorker
  alias Samen.AI.Provider.Scripted
  alias SamenCore.TestRepo

  require Ash.Query

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Scripted.reset()
    Breaker.reset()

    on_exit(fn ->
      Scripted.reset()
      Breaker.reset()
    end)

    :ok
  end

  # The ONE literal both arms assert PRESENT in their own persisted run artifact. See
  # the "shared, mutation-refutable binding" section of the moduledoc.
  @cf17b_canary "CF17B-SHARED-CANARY-9a26f4"

  test "CF-17(b) REUSE COST: a replay that REUSES the :proposed fold ledger row SPENDS NOTHING for it — both token counters are byte-identical across the replay and exactly ONE provider call rides it" do
    scripted_worker_config()
    s = new_scope()
    goal = "goal CANARY-cf17b-reuse #{@cf17b_canary}"

    # `P6 CASE A`'s fixture, unchanged. `@protected_tail_turns` is 2 and the in-flight
    # turn is one of its slots, so TURN 3 is the earliest foldable turn; the folding turn
    # makes TWO provider calls (§5#1's summarize, then its own), and the crash is
    # evaluated INSIDE the worker process on that second call — after checkpoint 1's
    # `"proposed"` write, and after `apply_fold!/4` has already BILLED the fold.
    script([
      {:continue, "turn one — a long span destined to be folded"},
      {:continue, "turn two"},
      {:continue, "Summary: turns one and two were reviewed."},
      fn -> exit(:mid_fold_death) end,
      {:final, "done"}
    ])

    assert {:ok, run} = Agent.start(Durable, s, goal, budgets: [context_cutoff_tokens: 1])

    {pid, ref} = spawn_monitor(fn -> perform!(run) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :mid_fold_death}, 5_000

    assert [proposed] = folds_of(run)
    assert proposed["status"] == "proposed"

    {in_before, out_before} = cost(run)
    calls_before = provider_calls()

    # ANTI-VACUITY, on this arm's OWN fixture: the DERIVATION that is about to be reused
    # really did spend. Every scripted completion carries `usage: %{}` (`Scripted`'s
    # `scripted_completion/1`) and `usage_int/2` reads a missing key as 0, so turns 1-3
    # billed nothing at all — the whole of both counters is `apply_fold!/4`'s bill, and
    # the ledger row's own `input_tokens`/`output_tokens` say so to the byte.
    assert in_before > 0 and out_before > 0,
           "the fold billed nothing when it was DERIVED, so 'the replay bills nothing' " <>
             "would be vacuous; got #{inspect({in_before, out_before})}"

    assert {proposed["input_tokens"], proposed["output_tokens"]} == {in_before, out_before},
           "the run's counters must be exactly the fold's own recorded bill (§6: a " <>
             "fold's spend is real and is billed at checkpoint 1); ledger says " <>
             "#{inspect({proposed["input_tokens"], proposed["output_tokens"]})}, run says " <>
             "#{inspect({in_before, out_before})}"

    assert :ok = perform!(run)

    # The self-report P6 CASE A already owns, kept here so this arm cannot be satisfied
    # by a build that simply stopped CLAIMING reuse: the claim is still made, and the
    # measurements below are what make it true.
    assert [reused] = folds_of(run)
    assert reused["turn_index"] == proposed["turn_index"]
    assert reused["meta"]["replayed"] == true
    assert reused["body"] == proposed["body"]

    # THE GAP (CF-17(b)): the MEASURED cost of the reused fold is ZERO. `reuse_fold!/5`'s
    # `:advance` carries the transcript and nothing else — not `current_turn`, not
    # `tool_calls_used`, and neither token counter — so a path that re-derived the fold
    # while stamping `replayed=true` is caught HERE, by its bill, not by its claim.
    assert cost(run) == {in_before, out_before},
           "the replay BILLED for the fold it claims to have reused: counters moved " <>
             "#{inspect({in_before, out_before})} → #{inspect(cost(run))}. Reuse that " <>
             "spends is re-derivation wearing the `replayed` stamp (ADR-048 §6 / UXD-18)"

    # And the second, independent measurement: the provider's own recording. A folding
    # turn makes TWO calls; this replay must make exactly ONE — its own. A second call
    # here IS the §5#1 summarize call running again.
    assert provider_calls() - calls_before == 1,
           "the replay made #{provider_calls() - calls_before} provider calls; a REUSING " <>
             "turn makes exactly one (its own). A second call is the §5#1 summarize " <>
             "call re-running — the fold was re-derived, not reused"

    # THE SHARED BINDING, asserted PRESENT (never `refute`) — see the moduledoc.
    assert goal_of(run) =~ @cf17b_canary,
           "the persisted run's own goal field lost the CF-17(b) shared canary — got: " <>
             inspect(goal_of(run))
  end

  test "CF-17(b) DERIVE COST (anti-tautology control, MANDATORY): with NO ledger row to reuse the same fold is DERIVED — both counters move strictly UP and the summarize call is in the recording — so the reuse arm's zero is a measurement, not a counter that never moves" do
    scripted_worker_config()
    s = new_scope()
    goal = "goal CANARY-cf17b-derive #{@cf17b_canary}"

    # `P6 CASE B`'s fixture: the SAME span, the SAME watermark, the SAME summarize entry
    # — only the crash is gone, so nothing was ever checkpointed and the replay has
    # nothing to reuse. This is the half UXD-18 rules a LEGITIMATE re-derivation.
    script([
      {:continue, "turn one — a long span destined to be folded"},
      {:continue, "turn two"},
      {:continue, "Summary: turns one and two were reviewed."},
      {:final, "done"}
    ])

    assert {:ok, run} = Agent.start(Durable, s, goal, budgets: [context_cutoff_tokens: 1])

    assert folds_of(run) == [],
           "no turn has run yet, so there is no ledger row to reuse — that absence is " <>
             "what makes the derivation below legitimate"

    {in_before, out_before} = cost(run)
    calls_before = provider_calls()

    assert {in_before, out_before} == {0, 0},
           "a freshly started run has spent nothing; got #{inspect({in_before, out_before})}"

    assert :ok = perform!(run)

    assert [fresh] = folds_of(run)
    assert fresh["status"] == "done"

    refute fresh["meta"]["replayed"] == true,
           "no ledger row existed to reuse, so this fold must NOT claim it reused one"

    {in_after, out_after} = cost(run)

    # THE OTHER DIRECTION of the reuse arm's measurement, read through the SAME accessor:
    # deriving a fold COSTS. Without this the reuse arm's equality is satisfiable by a
    # build whose counters never move at all.
    assert in_after > in_before and out_after > out_before,
           "a DERIVED fold must bill its span in and its marker out (§6: the tokens are " <>
             "real); counters went #{inspect({in_before, out_before})} → " <>
             "#{inspect({in_after, out_after})}"

    assert {fresh["input_tokens"], fresh["output_tokens"]} == {in_after, out_after},
           "the derived fold's bill must be exactly what its ledger row records; ledger " <>
             "says #{inspect({fresh["input_tokens"], fresh["output_tokens"]})}, run says " <>
             "#{inspect({in_after, out_after})}"

    # The call-count half of the same control: three turns plus ONE §5#1 summarize call
    # on the folding turn. This is the extra call the reuse arm proves does NOT ride a
    # replay.
    assert provider_calls() - calls_before == 4,
           "a derivation runs three turns plus the folding turn's §5#1 summarize call; " <>
             "got #{provider_calls() - calls_before} calls"

    # THE SHARED BINDING, asserted PRESENT the SAME way and in the SAME direction as the
    # reuse arm — the pair a single assertion-site mutation must flip together.
    assert goal_of(run) =~ @cf17b_canary,
           "the persisted run's own goal field lost the CF-17(b) shared canary — got: " <>
             inspect(goal_of(run))
  end

  # --- helpers ---------------------------------------------------------------------------

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

  defp put_agent_config(kv) do
    previous = Application.get_env(:samen_core, Samen.AI.Agent, [])
    Application.put_env(:samen_core, Samen.AI.Agent, Keyword.merge(previous, kv))
    on_exit(fn -> Application.put_env(:samen_core, Samen.AI.Agent, previous) end)
  end

  defp scripted_worker_config, do: put_agent_config(provider: scripted_provider())

  defp perform!(run), do: TurnWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

  defp transcript_json(run) do
    run = reload(run)
    %Samen.Masked{} = masked = run.transcript
    {:ok, json} = Samen.Vault.reveal(masked, TestRepo, subject_id: run.id)
    Jason.decode!(json)
  end

  defp folds_of(run), do: Map.get(transcript_json(run), "folds", [])

  defp goal_of(run), do: Map.get(transcript_json(run), "goal", "")

  # THE MEASURED QUANTITY — both arms read it through this one accessor, in opposite
  # directions, which is what keeps them non-disjoint.
  defp cost(run) do
    row = reload(run)
    {row.input_tokens_used, row.output_tokens_used}
  end

  # The provider's OWN recording of how many completions it was asked for — the
  # measurement `P6 CASE A` deliberately does not take.
  defp provider_calls do
    Scripted.sent_payloads()
    |> Enum.count(fn {callback, _payload} -> callback == :complete end)
  end
end
