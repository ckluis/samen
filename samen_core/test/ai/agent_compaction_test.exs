defmodule C2RTestAgents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "c2r.durable",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end

  # C2I2 — the UXD-17 arms need an agent that HAS tool defs (so "the fold never folds the
  # tool defs" has something to be true of) and whose turns append MORE THAN ONE line (so
  # "whole turns only" has a turn that can be split). A read tool executes inline and
  # appends both its call line and its result line in one turn — exactly that shape.
  defmodule Reader do
    @moduledoc false
    use Samen.AI.Agent,
      name: "c2i2.reader",
      goal_prompt: "Use your tools to answer. Reply FINAL: <answer> when done.",
      tools: ["search_records", "fetch_record"]
  end
end

defmodule Samen.AI.AgentCompactionTest do
  @moduledoc """
  ADR-048 batch C2 (`T218`) — RED-FIRST tests for Levels 1 + 3 of the three-level
  overflow ladder (§6) and the two new bounded `@error_kind`s. Written against the
  UNBUILT feature: `:context_overflow`, `:context_exhausted` and the Level-1 watermark
  `context_cutoff_tokens` are ADR-048 §6 forward references with ZERO `grep -rn` hits in
  `samen_core`/`samen_web` at the time this file was written (positive controls in the
  same sweep: `safe_segment?` = 25, `max_turns` = 27 — see
  `_orch-runs/adr048-c1-c4-20260907/nodes/C2R/work/counts.txt`).

  **This file implements NOTHING under `samen_core/lib` or `samen_web/lib`.** Every test
  below is expected to FAIL today, by name, at its FIRST assertion — the one that states
  the obligation's own precondition, never "a module is missing". Once C2 lands the
  deterministic (non-model, drop-with-marker) fold, the remainder of each body becomes
  the real gate.

    * **P3** (ADR-048 §8 `:496`) — the fail-honest floor survives recovery. The closed
      `@error_kinds` enum (`agent.ex:204`) has no `:context_exhausted` member today, so
      the new terminal degrades to the content-free `:unknown` and cannot be told apart
      from `:budget_exhausted` (`agent_case.ex:11-12`). The floor itself is unchanged and
      non-configurable: the last assistant turn is NEVER promoted.
    * **P4** (ADR-048 §8 `:497`, §10 row 5 RATIFIED (a)) — Level 2 retries EXACTLY once:
      one turn index, two provider attempts, and a second overflow is Level 3, never a
      second retry. In scope for C2 because `T218`'s own `Gate:` clause names P4 and its
      scope clause enumerates `:context_overflow`; the retry-boundary kill-switch/cancel
      re-check is **P5** and is deliberately NOT taken here. Reconciliation recorded in
      `nodes/C2R/work/spec-notes.md` §2.
    * **P6** (ADR-048 §8 `:499`, ruling UXD-18) — fold reuse on replay, TWO cases: a crash
      **after** the pre-call `:proposed` fold-ledger write (the replay must REUSE that row,
      `meta: %{"replayed" => true}`) and a crash **before** it (the replay legitimately
      re-derives, since no ledger row exists yet). The reuse claim is asserted on the
      **ledger row**, never on a provider-call count — C2's fold is deterministic and
      **no summarizer exists in this batch** (ADR-048 §9's C2 row).
    * **P13** (ADR-048 §8 `:509`, D4 / §10 row 4 RATIFIED (a)) — a fold spends tokens and
      deadline but NEVER decrements `max_turns` or `max_tool_calls`. Ships with BOTH
      mandatory anti-tautology positive controls, so a build whose counters never move at
      all cannot satisfy the assertion vacuously.

  The two-checkpoint shape P6 reuses is the one already shipped for turn rows
  (`find_or_reuse_turn/3` — documented at `agent.ex:97-104` (RP-AG-7), defined at
  `agent.ex:2320`, called at `agent.ex:848`; consistency recorded in `spec-notes.md` §1).
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias C2RTestAgents.Durable
  alias C2RTestAgents.Reader
  alias Samen.AI.Agent
  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.TurnWorker
  alias Samen.AI.Provider.Scripted
  alias SamenCore.Support.AutomationFixture.Subject
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

  # Merge agent-group config for one test, restoring the previous group on exit — the
  # A2 cross-process seam: the TurnWorker resolves its provider from host config.
  defp put_agent_config(kv) do
    previous = Application.get_env(:samen_core, Samen.AI.Agent, [])
    Application.put_env(:samen_core, Samen.AI.Agent, Keyword.merge(previous, kv))
    on_exit(fn -> Application.put_env(:samen_core, Samen.AI.Agent, previous) end)
  end

  defp scripted_worker_config, do: put_agent_config(provider: scripted_provider())

  defp perform!(run), do: TurnWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

  # The ADR-048 §4 compaction LEDGER, read out of the one sealed transcript blob C1
  # already ships (`encode_transcript/2` writes `"folds" => []`). C2 is the batch that
  # first makes it non-empty; today it is always `[]`, which is what every fold red below
  # ultimately measures.
  defp folds_of(run) do
    run = reload(run)
    %Samen.Masked{} = masked = run.transcript
    {:ok, json} = Samen.Vault.reveal(masked, TestRepo, subject_id: run.id)
    Map.get(Jason.decode!(json), "folds", [])
  end

  # ======================================================================
  # P3 — the fail-honest floor survives recovery (ADR-048 §8 `:496`)
  # ======================================================================

  test "P3: RED — the fail-honest floor survives context recovery; :context_exhausted is a BOUNDED terminal distinct from :budget_exhausted and the last assistant turn is NOT promoted" do
    s = new_scope()

    # THE RED (ADR-048 §6 Level 3 forward reference). The closed @error_kinds enum is
    # exhaustively matched by `safe_error_kind/1`, so an unlisted kind degrades to the
    # content-free `:unknown` — exactly the small dishonesty §6 forbids: "this run
    # outgrew its context window" and "this run spent its allowance" are different facts.
    # (Mapped rather than compared inline: an inline literal comparison lets the compiler
    # fold `safe_error_kind(:context_exhausted)` to `:unknown` and emit a distinct-types
    # warning, and CI builds with --warnings-as-errors. The claim is identical.)
    bounded = Enum.map([:context_exhausted], &Agent.safe_error_kind/1)

    assert bounded == [:context_exhausted],
           "ADR-048 §6 Level 3 not built — :context_exhausted is not a member of the " <>
             "closed @error_kinds enum (samen_core/lib/samen/ai/agent.ex:204), so it " <>
             "degrades to #{inspect(hd(bounded))} and the " <>
             "honest terminal cannot be told apart from :budget_exhausted"

    # Everything below is the real gate once Level 1 + Level 3 land. It is unreachable
    # today and is deliberately NOT stubbed into existence.
    script(
      continue: "step one",
      continue: "a plausible-looking partial answer that must NEVER be promoted",
      final: "never reached"
    )

    result =
      run_scripted(Durable, s, "goal CANARY-p3",
        budgets: [context_cutoff_tokens: 1, max_input_tokens: 1]
      )

    assert {:error, :context_exhausted, run} = result

    # Level 3 is a terminal of its own, NOT a re-labelled budget exhaustion.
    assert run.state == :context_exhausted
    refute run.state == :budget_exhausted
    assert run.error_kind == "context_exhausted"

    # THE FLOOR, unweakened (ADR-048 §6, sabotage 240's target extended to the new
    # terminal): the last assistant turn is not promoted, and its text is not at rest.
    refute match?({:ok, _}, result)

    assert_no_text_at_rest!(run, [
      "a plausible-looking partial answer that must NEVER be promoted",
      "never reached"
    ])
  end

  test "P3 DISTINCTNESS, the OTHER direction (anti-tautology): a run exhausted on BUDGET returns {:error, :budget_exhausted, run} and terminal :budget_exhausted — never the context terminal — so the two exhaustions cannot be the same code path" do
    s = new_scope()

    # Ample context ceiling, starved TURN budget: this run exhausts on the allowance, not
    # on the window. Its terminal must stay :budget_exhausted.
    script(
      continue: "step one",
      continue: "a plausible-looking partial answer that must NEVER be promoted",
      final: "never reached"
    )

    result = run_scripted(Durable, s, "goal CANARY-p3-distinct", budgets: [max_turns: 1])

    # The refutations are stated BEFORE the narrowing assert deliberately: once the
    # compiler has folded `result` to the budget tuple it emits a never-match type warning
    # on the context arm, and CI builds with --warnings-as-errors. The claim is identical.
    refute match?({:error, :context_exhausted, _}, result)
    refute match?({_, %{state: :context_exhausted}}, result)

    assert {:error, :budget_exhausted, budget_run} = result,
           "a starved max_turns must still exhaust on BUDGET — got: #{inspect(result)}"

    assert budget_run.state == :budget_exhausted
    assert budget_run.error_kind == "max_turns"

    # The two kinds are BOTH bounded members of the closed enum — neither degrades to the
    # content-free :unknown, which is the whole reason they can be told apart at all.
    assert Enum.map([:budget_exhausted, :context_exhausted, :context_overflow], fn kind ->
             Agent.safe_error_kind(kind)
           end) == [:unknown, :context_exhausted, :context_overflow],
           "the two CONTEXT kinds are bounded members of @error_kinds; :budget_exhausted " <>
             "is a run STATE, not an error kind, and is deliberately not one"

    # And the floor holds identically here (RP-AG-6 / sabotage 240), so the distinctness
    # above is a distinction between two HONEST terminals, never an excuse for a partial.
    assert_no_text_at_rest!(budget_run, [
      "a plausible-looking partial answer that must NEVER be promoted",
      "never reached"
    ])
  end

  # ======================================================================
  # P4 — Level 2 retries exactly once (ADR-048 §8 `:497`, §10 row 5)
  # ======================================================================

  test "P4: RED — Level 2 retries EXACTLY once; one turn index carries two provider attempts and a second overflow is Level 3, never a second retry" do
    s = new_scope()

    # THE RED (ADR-048 §6 Level 2 forward reference). A provider "prompt too long"
    # collapses into the content-free `:provider_error` today, so there is no bounded
    # kind for a retry counter to key off and "exactly once" is unassertable.
    # (Mapped, not compared inline — see P3's note; --warnings-as-errors.)
    bounded = Enum.map([:context_overflow], &Agent.safe_error_kind/1)

    assert bounded == [:context_overflow],
           "ADR-048 §6 Level 2 not built — :context_overflow is not a member of the " <>
             "closed @error_kinds enum (samen_core/lib/samen/ai/agent.ex:204), so a " <>
             "prompt-too-long response degrades to " <>
             "#{inspect(hd(bounded))} and the retry-once " <>
             "counter has nothing to trigger on"

    # The real gate once the counter lands: attempt 1 overflows, ONE inline fold +
    # retry happens on the SAME turn index, attempt 2 succeeds.
    script([
      {:error, :context_overflow},
      {:continue, "recovered after exactly one fold-and-retry"},
      {:final, "done"}
    ])

    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-p4")
    run = reload(run)

    rows = turn_rows(run)

    # ONE turn row for the overflowing index — two provider attempts, no loop.
    overflow_row = Enum.find(rows, &(&1.meta["context_retries"] not in [nil, 0]))

    assert overflow_row != nil,
           "no turn row recorded a Level 2 recovery attempt — the retry counter is absent"

    assert overflow_row.meta["context_retries"] == 1,
           "Level 2 must retry EXACTLY once (ADR-048 §10 row 5, RATIFIED (a)); got " <>
             "#{inspect(overflow_row.meta["context_retries"])}"

    # The counter lives on the turn ROW, so a retry can never mint a second index.
    assert length(rows) == length(Enum.uniq_by(rows, & &1.turn_index))
  end

  test "P4 CONTROL (anti-tautology, MANDATORY): the retried turn's SECOND overflow is LEVEL 3 :context_exhausted — EXACTLY TWO provider attempts on the one turn index, never a third, and the row still reads context_retries == 1" do
    s = new_scope()

    # One original + one retry, then a THIRD entry that a looping recovery would consume.
    script([
      {:error, :context_overflow},
      {:error, :context_overflow},
      {:continue, "a third attempt that must NEVER be made"}
    ])

    result = run_scripted(Durable, s, "goal CANARY-p4-control")

    # ADR-048 §6: "if the single retry also overflows, it is level 3, not a second retry."
    assert {:error, :context_exhausted, run} = result
    assert run.state == :context_exhausted
    assert run.error_kind == "context_exhausted"

    # EXACTLY two provider attempts. The UNCONSUMED third entry is what makes "never a
    # second retry" refutable — a Level 2 that looped would have eaten it.
    assert length(sent_segments()) == 2,
           "Level 2 is EXACTLY one recovery attempt (ADR-048 §10 row 5, RATIFIED (a)): " <>
             "one original + one retry = 2 provider calls, got #{length(sent_segments())}"

    assert Scripted.remaining() == [{:continue, "a third attempt that must NEVER be made"}]

    # ONE turn index, ONE row: the retry can never mint a second index.
    assert [row] = turn_rows(run)
    assert row.turn_index == 1
    assert row.status == :failed
    assert row.error_kind == "context_exhausted"
    assert row.meta["context_retries"] == 1

    # The floor, unweakened: nothing was promoted, no attempt text is at rest.
    refute match?({:ok, _}, result)
    assert_no_text_at_rest!(run, ["a third attempt that must NEVER be made"])
  end

  # ======================================================================
  # P6 — fold reuse on replay, TWO cases (ADR-048 §8 `:499`, ruling UXD-18)
  #
  # NOTE (ADR-048 §9, C2 row): C2's fold is DETERMINISTIC and non-model —
  # drop-with-marker, no summarizer. Both cases below therefore assert on the fold
  # LEDGER ROW, never on a model call. "re-summarize" in §8 P6 reads here as
  # "re-derive the fold body".
  # ======================================================================

  test "P6 CASE A: RED — a crash AFTER the pre-call :proposed fold write REUSES that ledger row on replay (meta replayed=true) and never re-derives the fold" do
    scripted_worker_config()
    s = new_scope()

    # C2I3 SCRIPT EXTENSION (no assertion changed). ADR-048 §6's protected recent tail is
    # the 2 most recent turns and the in-flight turn is one of them, so TURN 3 is the
    # earliest turn at which anything is eligible to fold at all (measured:
    # `nodes/C2I2/work/level1-seam.md` §1). The crash therefore has to land on turn 3 —
    # the first turn that HAS a pre-call :proposed fold entry to survive it — and the
    # replayed turn 3 is the run's final turn, so the ledger holds exactly the one entry
    # the assertions below name. The tail itself is untouched.
    script([
      {:continue, "turn one — a long span destined to be folded"},
      {:continue, "turn two"},
      # C3I1 SCRIPT EXTENSION (no assertion changed). ADR-048 §5#1's governed summarizer is
      # an ordinary `Samen.AI.complete/4`, so a FOLDING turn now makes TWO provider calls —
      # the summarize call first, then the turn's own — and `Samen.AI.Provider.Scripted`
      # serves one entry per call. One extra entry per fold keeps the script aligned with
      # the turns each assertion below names.
      {:continue, "Summary: turns one and two were reviewed."},
      # Evaluated INSIDE the worker process, AFTER the pre-call :proposed fold-entry
      # write committed: the narrow crash window UXD-18 names.
      fn -> exit(:mid_fold_death) end,
      {:final, "done"}
    ])

    start_result = Agent.start(Durable, s, "goal CANARY-p6a", budgets: [context_cutoff_tokens: 1])

    # THE RED (ADR-048 §6 Level 1 forward reference): the watermark that triggers a
    # Level 1 fold is not a recognised budget key, so the loop refuses the run outright
    # and NO fold can be driven at all — there is nothing yet for a replay to reuse.
    refute start_result == {:error, :invalid_budgets},
           "ADR-048 §6 Level 1 not built — `context_cutoff_tokens` is not a member of " <>
             "@budget_keys (samen_core/lib/samen/ai/agent.ex:196), so `resolve_budgets/2` " <>
             "refuses the watermark and no fold ledger entry can exist to be reused"

    assert {:ok, run} = start_result

    {pid, ref} = spawn_monitor(fn -> perform!(run) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :mid_fold_death}, 5_000

    # The pre-call checkpoint survived the death: a :proposed fold entry is on disk.
    assert [proposed] = folds_of(run)
    assert proposed["status"] == "proposed"

    # The replay FINDS that entry and REUSES it — one entry per turn index, stamped
    # replayed, body byte-identical (the fold is a pure function of
    # {run_id, turn_index, view state}, so a re-derivation would be invisible without
    # the marker; the marker is what makes reuse refutable).
    assert :ok = perform!(run)

    assert [reused] = folds_of(run)
    assert reused["turn_index"] == proposed["turn_index"]
    assert reused["meta"]["replayed"] == true
    assert reused["body"] == proposed["body"]
  end

  test "P6 CASE B: RED — a crash BEFORE the pre-call :proposed fold write leaves NO ledger row, so the replay legitimately re-derives the fold and is not marked replayed" do
    scripted_worker_config()
    s = new_scope()

    # C2I3 SCRIPT EXTENSION (no assertion changed) — same measured reason as CASE A: one
    # more `{:continue, …}` so the run reaches turn 3, the earliest foldable turn.
    script([
      {:continue, "turn one — a long span destined to be folded"},
      {:continue, "turn two"},
      # C3I1 SCRIPT EXTENSION (no assertion changed). ADR-048 §5#1's governed summarizer is
      # an ordinary `Samen.AI.complete/4`, so a FOLDING turn now makes TWO provider calls —
      # the summarize call first, then the turn's own — and `Samen.AI.Provider.Scripted`
      # serves one entry per call. One extra entry per fold keeps the script aligned with
      # the turns each assertion below names.
      {:continue, "Summary: turns one and two were reviewed."},
      {:final, "done"}
    ])

    start_result = Agent.start(Durable, s, "goal CANARY-p6b", budgets: [context_cutoff_tokens: 1])

    # THE RED — same Level 1 forward reference as CASE A.
    refute start_result == {:error, :invalid_budgets},
           "ADR-048 §6 Level 1 not built — `context_cutoff_tokens` is not a member of " <>
             "@budget_keys (samen_core/lib/samen/ai/agent.ex:196), so no fold ledger " <>
             "row can be written before the fold and CASE B's window does not exist"

    assert {:ok, run} = start_result

    # The crash landed BEFORE the pre-call write: nothing is committed to reconcile
    # against. This is the half UXD-18 rules is a LEGITIMATE re-derivation, not a bug.
    assert folds_of(run) == []

    assert :ok = perform!(run)

    assert [fresh] = folds_of(run)
    assert fresh["status"] == "done"

    refute fresh["meta"]["replayed"] == true,
           "no ledger row existed to reuse, so the replay must NOT claim it reused one"
  end

  test "P6 SAME-TRANSACTION: the fold finalize and the run-cursor advance are ONE transaction — a rollback loses BOTH, the control commits BOTH" do
    scripted_worker_config()
    s = new_scope()

    script([
      {:continue, "turn one — a long span destined to be folded"},
      {:continue, "turn two"},
      # C3I1 SCRIPT EXTENSION (no assertion changed). ADR-048 §5#1's governed summarizer is
      # an ordinary `Samen.AI.complete/4`, so a FOLDING turn now makes TWO provider calls —
      # the summarize call first, then the turn's own — and `Samen.AI.Provider.Scripted`
      # serves one entry per call. One extra entry per fold keeps the script aligned with
      # the turns each assertion below names.
      {:continue, "Summary: turns one and two were reviewed."},
      fn -> exit(:mid_fold_death) end,
      {:final, "rolled back"},
      {:final, "committed"}
    ])

    assert {:ok, run} =
             Agent.start(Durable, s, "goal CANARY-p6tx", budgets: [context_cutoff_tokens: 1])

    {pid, ref} = spawn_monitor(fn -> perform!(run) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :mid_fold_death}, 5_000

    # ARM 1 — the crash window itself, which is the arm that refutes a finalize done in
    # its own EARLIER write: the fold for turn 3 is on disk `proposed` while the cursor
    # is still at turn 2. A separately-committed finalize would read "done" here.
    assert [%{"status" => "proposed", "turn_index" => 3}] = folds_of(run)
    assert reload(run).current_turn == 2

    # ARM 2 — atomicity (the shipped EventCapture idiom): roll the replay's whole turn
    # back and BOTH the finalize and the cursor advance vanish together.
    {:error, :abort} =
      TestRepo.transaction(fn ->
        assert :ok = perform!(run)
        TestRepo.rollback(:abort)
      end)

    assert [%{"status" => "proposed", "turn_index" => 3}] = folds_of(run),
           "the fold finalize rode the rolled-back cursor-advance transaction, so it " <>
             "must have been discarded with it"

    assert reload(run).current_turn == 2

    # ARM 3 — the POSITIVE control: the same replay un-rolled-back moves BOTH, so ARM 2
    # measured the rollback and not a build that never finalizes at all.
    assert :ok = perform!(run)

    assert [%{"status" => "done", "turn_index" => 3}] = folds_of(run)
    assert reload(run).current_turn == 3
  end

  # ======================================================================
  # P13 — D4: a fold spends tokens + deadline, never max_turns/max_tool_calls
  # (ADR-048 §8 `:509`; §10 row 4 RATIFIED (a))
  # ======================================================================

  test "P13: RED — a fold NEVER decrements max_turns or max_tool_calls; the two ceilings and the two used-counters are all byte-identical across a fold" do
    s = new_scope()

    # C3I1 SCRIPT EXTENSION (no assertion changed) — one extra entry for the ADR-048 §5#1
    # summarize call the folding turn now makes ahead of its own call.
    script(
      continue: "turn one — a long span destined to be folded",
      continue: "turn two",
      continue: "Summary: turns one and two were reviewed.",
      final: "done"
    )

    result = run_scripted(Durable, s, "goal CANARY-p13", budgets: [context_cutoff_tokens: 1])

    # THE RED (ADR-048 §6 Level 1 forward reference): with no watermark key there is no
    # fold, so D4's claim has no window to hold across.
    refute result == {:error, :invalid_budgets},
           "ADR-048 §6 Level 1 not built — `context_cutoff_tokens` is not a member of " <>
             "@budget_keys (samen_core/lib/samen/ai/agent.ex:196), so no fold occurs and " <>
             "D4's before/after window does not exist"

    assert {:ok, %{run: run}} = result
    run = reload(run)

    # A fold genuinely happened in this run (otherwise D4 is vacuous here).
    folds = folds_of(run)

    assert folds != [],
           "ADR-048 §6 Level 1 fold never ran — the transcript's `folds` ledger is empty, " <>
             "so this test would pass against a build with no compactor at all"

    # D4, the whole claim, on all four counters. The CEILINGS are untouched...
    assert run.max_turns == Keyword.fetch!(Agent.default_budgets(), :max_turns)
    assert run.max_tool_calls == Keyword.fetch!(Agent.default_budgets(), :max_tool_calls)

    # ...and the USED counters that move against them (over_budget/2, agent.ex:587-588)
    # advanced by exactly the ORDINARY turns, never by the folds: three scripted turns
    # were taken, so the cursor reads 3 no matter how many folds happened in between.
    assert run.current_turn == 3,
           "a fold spent max_turns — the cursor reads #{run.current_turn} for 3 ordinary " <>
             "turns and #{length(folds)} fold(s) (D4 forbids charging a fold as a turn)"

    assert run.current_turn == length(turn_rows(run)),
           "a fold minted a cursor advance without a turn row — D4 violated"

    assert run.tool_calls_used == 0,
           "a fold spent max_tool_calls — no tool was ever called in this run"
  end

  test "P13 POSITIVE CONTROL 1 (anti-tautology, MANDATORY): an ORDINARY turn in the same run DOES spend max_turns, so counters that never move cannot satisfy P13" do
    s = new_scope()

    script(continue: "step one", continue: "step two", final: "done")

    assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal CANARY-p13-control-1")
    run = reload(run)

    # Three ORDINARY turns were taken and the used-counter moved by exactly three from a
    # measured zero. A build whose counters never move AT ALL — the vacuous build P13's
    # main red would otherwise pass against — FAILS here.
    assert run.current_turn == 3
    assert length(turn_rows(run)) == 3

    # And the counter is genuinely read against the ceiling, not merely stored.
    now = DateTime.utc_now()
    assert Agent.over_budget(%{run | current_turn: run.max_turns}, now) == :max_turns
    assert Agent.over_budget(%{run | current_turn: run.max_turns - 1}, now) == nil
  end

  test "P13 POSITIVE CONTROL 2 (anti-tautology, MANDATORY): the fold DID spend real tokens against max_input_tokens/max_output_tokens in the same window" do
    s = new_scope()

    usage = %{input_tokens: 100, output_tokens: 10}

    # C3I1 SCRIPT EXTENSION (no assertion changed): the third entry answers the ADR-048
    # §5#1 SUMMARIZE call, not an ordinary turn. Its scripted `usage` is deliberately
    # never billed — §6's fold bill is the DETERMINISTIC `est_tokens/1` of the bytes the
    # fold read and wrote, which is exactly what the two equalities below pin. The three
    # ORDINARY turns still bill 300 in / 30 out.
    script([
      {:continue, "turn one — a long span destined to be folded", usage},
      {:continue, "turn two", usage},
      {:continue, "Summary: turns one and two were reviewed.", usage},
      {:final, "done", usage}
    ])

    result =
      run_scripted(Durable, s, "goal CANARY-p13-control-2", budgets: [context_cutoff_tokens: 1])

    # THE RED — the same Level 1 forward reference.
    refute result == {:error, :invalid_budgets},
           "ADR-048 §6 Level 1 not built — `context_cutoff_tokens` is not a member of " <>
             "@budget_keys (samen_core/lib/samen/ai/agent.ex:196), so no fold spends " <>
             "anything and this control has no window to measure"

    assert {:ok, %{run: run}} = result
    run = reload(run)

    folds = folds_of(run)
    assert folds != [], "no fold ran, so there is no fold token spend to control for"

    # The ledger's OWN measured bill, not a bare inequality against the scripted
    # subtotal. `input_tokens_used > 300` and `output_tokens_used > 30` below are
    # variable-disjoint from each other (one reads only the input side, the other only
    # the output side), so a build that bills a FIXED CONSTANT on each side — instead of
    # `est_tokens/1` of the bytes it actually folded — satisfies both while satisfying
    # neither's intent. These equalities pin the run totals to the ledger's own recorded
    # per-fold bill:
    billed_in = Enum.sum(Enum.map(folds, & &1["input_tokens"]))
    billed_out = Enum.sum(Enum.map(folds, & &1["output_tokens"]))

    assert run.input_tokens_used == 300 + billed_in,
           "run.input_tokens_used must be EXACTLY the 3 ordinary turns' 300 plus the " <>
             "ledger's own recorded fold input bill (#{billed_in}), not merely > 300"

    assert run.output_tokens_used == 30 + billed_out,
           "run.output_tokens_used must be EXACTLY the 3 ordinary turns' 30 plus the " <>
             "ledger's own recorded fold output bill (#{billed_out}), not merely > 30"

    # ...and the ledger's own bill must be the FOLDED BYTES, not a constant. This is
    # what a build carrying `est_tokens(span.folded) -> 1` and separately
    # `est_tokens([span.marker]) -> 1` cannot pass — each such build still moves
    # `run.input_tokens_used`/`run.output_tokens_used` off zero (satisfying the two `>`
    # assertions below) and still keeps the ledger's own field equal to the run total
    # (satisfying the two equalities above), but a constant-1 bill can never equal
    # `est_tokens/1` of the actual bytes folded.
    assert billed_out == div(byte_size(hd(folds)["body"]) + 3, 4),
           "the fold's ledgered output bill must equal est_tokens/1 of its own marker " <>
             "body (#{div(byte_size(hd(folds)["body"]) + 3, 4)}), not a constant " <>
             "(#{billed_out})"

    assert billed_in >=
             div(byte_size("turn one — a long span destined to be folded") + 3, 4),
           "the fold's ledgered input bill (#{billed_in}) must be at least est_tokens/1 " <>
             "of the turn text it folded — a fixed constant of 1 cannot reach that floor"

    # Three ordinary turns billed 300 in / 30 out. D4 RATIFIED (a): the fold's own
    # tokens are REAL and ARE billed — so the totals must exceed the ordinary-turn
    # subtotal. A build whose token counters never move FAILS here.
    assert run.input_tokens_used > 300,
           "the fold spent no input tokens (#{run.input_tokens_used} == the 3 ordinary " <>
             "turns' 300) — D4 says a fold's tokens are real and ARE billed"

    assert run.output_tokens_used > 30,
           "the fold spent no output tokens (#{run.output_tokens_used} == the 3 ordinary " <>
             "turns' 30) — D4 says a fold's tokens are real and ARE billed"

    # ...while the turn/tool-call budgets stayed put: the other half of D4, restated here
    # so this control can never be satisfied by a fold that simply charges everything.
    assert run.current_turn == 3
    assert run.tool_calls_used == 0
  end

  # ======================================================================
  # UXD-17 + §6 SELECTION — what Level 1 may never fold, and how it chooses
  # (ADR-048 §6; C2I2's own arms, GREEN against the shipped fold)
  #
  # Every arm below first asserts `folds_of(run) != []`. That is not decoration: without
  # it each arm would pass against a build with NO COMPACTOR AT ALL, which is the exact
  # vacuity ADR-048 §8 P13 makes mandatory to rule out.
  # ======================================================================

  @uxd17_subject_key "SamenCore.Support.AutomationFixture.Subject"

  defp create_subject!(org_id) do
    Subject
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      title: "UXD-17 fold subject",
      priority: :high,
      status: :open,
      email: "canary-c2i2-uxd17@leak.example"
    })
    |> Ash.create!(authorize?: false)
  end

  # Four scripted turns under a watermark of 1 token: turns 3 and 4 each fold the OLDEST
  # eligible turn, so every arm below runs against a transcript with TWO folds in it.
  #
  # C3I1 SCRIPT EXTENSION (no assertion changed): each of those two folding turns now
  # makes the ADR-048 §5#1 SUMMARIZE call ahead of its own call, so the script carries one
  # extra entry per fold and the two summaries are deliberately DISTINCT — the
  # prior-fold arm counts each fold body in `llm_view` exactly once.
  defp folded_run!(goal) do
    s = new_scope()

    script(
      continue: "turn one — the oldest span, destined to be folded first",
      continue: "turn two — the second-oldest span",
      continue: "Summary: fold one covered the oldest span.",
      continue: "turn three — the most recent committed turn",
      continue: "Summary: fold two covered the second-oldest span.",
      final: "done"
    )

    assert {:ok, %{run: run}} = run_scripted(Durable, s, goal, budgets: [context_cutoff_tokens: 1])

    run = reload(run)
    assert {:ok, views} = Agent.transcript_views(run)
    {run, views, folds_of(run)}
  end

  test "UXD-17: the fold NEVER folds the GOAL — the goal is unchanged across two folds, is not a member of llm_view at all, and still reaches the provider on the post-fold turn" do
    goal = "goal CANARY-uxd17-goal"
    {_run, views, folds} = folded_run!(goal)

    assert folds != [],
           "no fold ran, so this arm would pass against a build with no compactor at all"

    # The goal is not a segment of the working set — it rides the sealed payload's own
    # field (§4.2) — so no span can reach it, and it reads back byte-identical.
    assert views.goal == goal
    refute goal in views.llm_view

    # POSITIVE CONTROL: the goal is genuinely carried, so "never folded" is not satisfied
    # by "never present". The LAST provider call is the post-fold turn.
    last_payload = List.last(sent_segments())
    assert goal in last_payload

    # ...and that same post-fold payload really is post-fold: it carries a fold marker.
    assert Enum.any?(last_payload, fn seg -> seg == hd(folds)["body"] end)
  end

  test "UXD-17: the fold NEVER folds the TOOL DEFS — the post-fold provider payload carries tool defs byte-identical to the pre-fold payload's" do
    s = new_scope()
    subject = create_subject!(s.actor.org_id)

    # C3I1 SCRIPT EXTENSION (no assertion changed): one extra entry per folding turn for
    # the ADR-048 §5#1 summarize call.
    script([
      {:tool_call, "fetch_record", %{"resource" => @uxd17_subject_key, "id" => subject.id}},
      {:continue, "turn two — after the tool turn"},
      {:continue, "Summary: fold one covered the tool turn."},
      {:continue, "turn three — the most recent committed turn"},
      {:continue, "Summary: fold two covered turn two."},
      {:final, "done"}
    ])

    assert {:ok, %{run: run}} =
             run_scripted(Reader, s, "goal CANARY-uxd17-tools",
               budgets: [context_cutoff_tokens: 1]
             )

    run = reload(run)
    folds = folds_of(run)

    assert folds != [],
           "no fold ran, so this arm would pass against a build with no compactor at all"

    defs = sent_tool_defs()

    # POSITIVE CONTROL: there were tool defs to lose in the first place.
    assert hd(defs) != [] and is_map(hd(hd(defs)))

    assert List.last(defs) == hd(defs),
           "the post-fold payload's tool defs differ from the pre-fold payload's — the " <>
             "fold reached the compile-time-static tool defs (§4.2), which UXD-17 forbids"
  end

  test "UXD-17: the fold NEVER folds the PROTECTED RECENT TAIL — the most recent committed turn survives every fold verbatim while the oldest turns are replaced by markers" do
    {_run, views, folds} = folded_run!("goal CANARY-uxd17-tail")

    assert folds != [],
           "no fold ran, so this arm would pass against a build with no compactor at all"

    assert "turn three — the most recent committed turn" in views.llm_view,
           "the fold ate the protected recent tail"

    # ...and it is genuinely a fold that spared it: the OLDEST turns are gone.
    refute "turn one — the oldest span, destined to be folded first" in views.llm_view
    refute "turn two — the second-oldest span" in views.llm_view

    # The append-only record kept every one of them (§4 non-negotiable 4).
    assert "turn one — the oldest span, destined to be folded first" in views.ui_view
    assert "turn two — the second-oldest span" in views.ui_view
  end

  test "UXD-17: the fold NEVER folds A PRIOR FOLD'S OWN SUMMARY SEGMENT — folds stay one level deep: every earlier marker is still present verbatim and no fold's covered range overlaps another's" do
    {_run, views, folds} = folded_run!("goal CANARY-uxd17-prior-fold")

    assert length(folds) >= 2,
           "fewer than two folds ran, so there was never a PRIOR fold's summary segment " <>
             "for a later fold to consume — this arm would be vacuous"

    # Every marker ever minted is still exactly one segment of the working set. A fold
    # that consumed another fold's summary would have replaced one of these.
    for fold <- folds do
      assert Enum.count(views.llm_view, &(&1 == fold["body"])) == 1,
             "fold ##{fold["seq"]}'s marker is not present exactly once in llm_view — a " <>
               "later fold consumed a prior fold's own summary segment (UXD-17)"
    end

    # ONE LEVEL DEEP, stated as arithmetic: the covered turn ranges are contiguous,
    # ascending and disjoint, so no fold ever cites another fold's provenance.
    ranges = Enum.map(folds, &{&1["first_turn"], &1["last_turn"]})

    assert ranges == Enum.sort(ranges)

    Enum.reduce(ranges, 0, fn {first, last}, previous_last ->
      assert first == previous_last + 1
      assert last >= first
      last
    end)
  end

  test "the fold selects the OLDEST ELIGIBLE SPAN and folds WHOLE TURNS ONLY — a tool turn's call line and its result line are folded together, never half a turn" do
    s = new_scope()
    subject = create_subject!(s.actor.org_id)

    # C3I1 SCRIPT EXTENSION (no assertion changed): one extra entry per folding turn for
    # the ADR-048 §5#1 summarize call.
    script([
      {:tool_call, "fetch_record", %{"resource" => @uxd17_subject_key, "id" => subject.id}},
      {:continue, "turn two — after the tool turn"},
      {:continue, "Summary: fold one covered the tool turn."},
      {:continue, "turn three — the most recent committed turn"},
      {:continue, "Summary: fold two covered turn two."},
      {:final, "done"}
    ])

    assert {:ok, %{run: run}} =
             run_scripted(Reader, s, "goal CANARY-uxd17-whole-turns",
               budgets: [context_cutoff_tokens: 1]
             )

    run = reload(run)
    folds = folds_of(run)
    assert {:ok, views} = Agent.transcript_views(run)

    assert folds != [],
           "no fold ran, so this arm would pass against a build with no compactor at all"

    # OLDEST FIRST: fold #1 covers turn 1, fold #2 covers turn 2 — ascending, never the
    # newest-first order a "drop whatever is biggest" selector would produce.
    assert Enum.map(folds, & &1["first_turn"]) == Enum.to_list(1..length(folds))

    # WHOLE TURNS ONLY, measured on the real bytes: turn 1 was a TOOL turn, so it appended
    # its call line AND every line of its result in ONE turn. The append-only ui_view
    # still holds all of them; the working set must have lost ALL of them — a fold that
    # took only part of that turn would leave a tool call in the ledger without its
    # result, which is the split §6 forbids.
    assert hd(folds)["covered"] == 1, "fold #1 covered more than the one oldest turn"

    turn_one_lines = Enum.take(views.ui_view, hd(folds)["lines"])

    # POSITIVE CONTROL for "whole turns": the turn really did append more than one line,
    # so there was something a line-wise fold could have split.
    assert length(turn_one_lines) > 1
    assert String.starts_with?(hd(turn_one_lines), "tool_call: fetch_record")

    for line <- turn_one_lines do
      refute line in views.llm_view,
             "a line of the folded TOOL turn survived in llm_view — the fold split one " <>
               "turn (#{inspect(line)})"
    end

    # ...and the newest committed turn is still there, which is what makes "oldest" mean
    # something: a selector that folded the newest span would have taken this one.
    assert "turn three — the most recent committed turn" in views.llm_view
  end
end
