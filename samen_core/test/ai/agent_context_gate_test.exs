defmodule GC17CTestAgents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "gc17c.durable",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end
end

defmodule Samen.AI.AgentContextGateTest do
  @moduledoc """
  ADR-048 §6 — `Samen.AI.Agent.context_gate/6`'s **SECOND CONJUNCT**, the LEVEL 1 /
  LEVEL 3 boundary (coverage gap **CF-17(c)**).

  The gate is two conjuncts (`samen_core/lib/samen/ai/agent.ex`, `defp context_gate/6`):

      if context_tokens(definition, tools, goal, lines) > run.max_input_tokens and
           foldable(views, lines) == [] do
        {:error, :context_exhausted}

  The FIRST conjunct — over the hard input ceiling — is already pinned by
  `agent_compaction_test.exs`'s `P3` arms. The SECOND — **nothing eligible left to
  fold** — was pinned by NOTHING: `grep -rn context_gate samen_core/test` returned zero
  hits when this file was written (positive control in the same sweep:
  `grep -rn context_tokens samen_core/lib` = 4 hits). The comment shipped directly above
  the gate asserts "this gate cannot be satisfied by a constant"; that is a CLAIM about
  the gate, and this file is the test that converts it into a measurement.

  The unpinned property, stated as §6 states it: Level 3 is *"a context that does not fit
  under `max_input_tokens` **with NOTHING eligible left to fold**"*. A run that is over
  the ceiling but **still has a foldable span must NOT end `:context_exhausted`** — a
  later turn's watermark crossing is what folds it. Delete the `foldable(views, lines)
  == []` conjunct today and the gate fires PREMATURELY, ending runs a fold would have
  saved, and no shipped test notices.

  ## The two arms, and why they differ in exactly ONE byte position

  Both arms run the SAME agent, the SAME goal, the SAME three-entry script shape and the
  SAME `max_input_tokens: 500` ceiling under the SHIPPED default watermark
  (`context_cutoff_tokens` = 42_000, never crossed here — so no fold, no summarize call,
  and the gate is the only thing that decides either run's fate). The ONLY difference is
  **WHICH scripted turn carries the bulk text**:

    * **RESCUED arm** — the bulk lands on turn TWO. At turn 3's gate two turns are
      committed, so `foldable/2` (oldest-first, minus the `@protected_tail_turns` = 2
      protected tail of which the in-flight turn is one) yields turn 1: NON-EMPTY. Over
      the ceiling, something still foldable ⇒ the turn proceeds and the run reaches its
      real `FINAL:`.
    * **EXHAUSTED arm** — the bulk lands on turn ONE. At turn 2's gate exactly one turn
      is committed, the protected tail swallows it, and `foldable/2` is `[]`. Over the
      ceiling with nothing left to fold ⇒ `:context_exhausted`, the honest Level 3
      terminal.

  Neither arm assumes its own precondition. Each re-derives `est_tokens/1`
  (`agent.ex`'s ~4-bytes-per-token estimator) over the PERSISTED `llm_view` and asserts
  the history alone already exceeds the ceiling — so "the gate was consulted over the
  ceiling" is measured, not hoped for — and each asserts the committed turn COUNT that
  makes `foldable/2` non-empty (2) or empty (1).

  ## The shared, mutation-refutable binding (anti-tautology, MANDATORY)

  The two arms assert COMPLEMENTARY outcomes of the one conjunct, so no single mutation
  can flip both THROUGH it — moving the ceiling moves both runs the same way across it.
  The mutation must therefore hang on something else the two arms share and both assert
  **PRESENT, in the same direction**: `@cf17c_canary`, carried in both goals and read
  back from BOTH persisted transcripts through `goal_of/1` (never through the llm_view
  or the turn count — those ARE the property under test and must stay disjoint from the
  shared binding). Change that ONE literal at the assertion site and BOTH arms fail
  together; that non-disjointness is what makes the pair refutable rather than two
  independently constant-satisfiable halves.

  Sabotage twin: `scripts/sabotages/329-adr048-cf17c-context-gate-foldable-conjunct-dropped.patch`.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias GC17CTestAgents.Durable
  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Run
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

  # The HARD input ceiling both arms run under. Deliberately below the SHIPPED default
  # watermark (`context_cutoff_tokens` = 42_000, `agent.ex` `@default_budgets`) and left
  # there: lowering `max_input_tokens` as a cost control without touching the watermark is
  # an ordinary host configuration, and it is exactly the arrangement in which a context
  # can sit over the ceiling while spans are still foldable. Nothing exotic is needed to
  # reach the second conjunct.
  @ceiling 500

  # ~8 KB ⇒ ~2_000 estimator tokens, four times the ceiling and one twentieth of the
  # watermark: whichever turn carries it puts the NEXT turn's gate over the ceiling and
  # no turn anywhere near the watermark.
  @bulk String.duplicate("b", 8_000)

  # The ONE literal both arms assert PRESENT in their own persisted run artifact. See
  # the "shared, mutation-refutable binding" section of the moduledoc.
  @cf17c_canary "CF17C-SHARED-CANARY-4d91e2"

  test "CF-17(c) RESCUED: a run OVER max_input_tokens that STILL HAS a foldable span does NOT end :context_exhausted — the second conjunct of context_gate/6 keeps the turn alive" do
    s = new_scope()
    goal = "goal CANARY-cf17c-rescued #{@cf17c_canary}"

    # The bulk lands on turn TWO, so turn 3's gate sees TWO committed turns and
    # `foldable/2` yields turn 1 — over the ceiling, still foldable.
    script([
      {:continue, "turn one — the span that must stay eligible to fold"},
      {:continue, @bulk},
      {:final, "done"}
    ])

    result = run_scripted(Durable, s, goal, budgets: [max_input_tokens: @ceiling])

    # `match?/2` rather than a bare `=`: a pattern-match `assert` raises `MatchError` and
    # DISCARDS the message below, and the message is the whole diagnosis.
    assert match?({:ok, %{run: _}}, result),
           "a run over max_input_tokens with a FOLDABLE span must not be refused: " <>
             "ADR-048 §6 makes Level 3 the case where nothing is eligible to fold, and " <>
             "this run had turn 1 eligible. Got: #{inspect(result)}"

    {:ok, %{run: run}} = result
    run = reload(run)

    refute run.state == :context_exhausted,
           "context_gate/6 fired with a foldable span still present — its " <>
             "`foldable(views, lines) == []` conjunct is not being consulted, so the " <>
             "gate now ends runs a fold would have rescued (ADR-048 §6 Level 1/3 boundary)"

    assert run.state == :succeeded,
           "the rescued run must reach its real terminal, not merely avoid the context " <>
             "one; got #{inspect(run.state)}"

    lines = lines_of(run)

    # PRECONDITION 1, MEASURED (never assumed): at turn 3's gate the history was the
    # first two committed lines, and those ALONE already exceed the ceiling — so the
    # gate's FIRST conjunct was true and the second is what decided this run.
    at_gate = Enum.take(lines, 2)

    assert est_tokens(at_gate) > @ceiling,
           "this arm never reached the gate over the ceiling — the assembled history at " <>
             "turn 3 estimates #{est_tokens(at_gate)} tokens against a ceiling of " <>
             "#{@ceiling}, so the arm is vacuous"

    # PRECONDITION 2, MEASURED: TWO committed turns at that gate. `@protected_tail_turns`
    # is 2 and the in-flight turn is one of its slots, so two committed turns is exactly
    # the smallest history for which `foldable/2` is non-empty.
    assert length(at_gate) == 2,
           "the gate must have been consulted with two committed turns for `foldable/2` " <>
             "to be non-empty; got #{length(at_gate)} — got lines: #{inspect(at_gate)}"

    # THE SHARED BINDING, asserted PRESENT (never `refute`) — see the moduledoc.
    assert goal_of(run) =~ @cf17c_canary,
           "the persisted run's own goal field lost the CF-17(c) shared canary — got: " <>
             inspect(goal_of(run))
  end

  test "CF-17(c) EXHAUSTED CONTROL (anti-tautology, MANDATORY): the SAME ceiling with NOTHING eligible to fold DOES end :context_exhausted — so the rescued arm measures the foldable conjunct and not a gate that never fires" do
    s = new_scope()
    goal = "goal CANARY-cf17c-exhausted #{@cf17c_canary}"

    # Byte-identical script SHAPE to the rescued arm; the bulk simply moves to turn ONE.
    # Turn 2's gate therefore sees exactly ONE committed turn, the protected tail
    # swallows it, and `foldable/2` is `[]` — the honest Level 3 case.
    script([
      {:continue, @bulk},
      {:continue, "turn two — never reached"},
      {:final, "never reached"}
    ])

    result = run_scripted(Durable, s, goal, budgets: [max_input_tokens: @ceiling])

    assert match?({:error, :context_exhausted, _}, result),
           "over the hard ceiling with NOTHING eligible to fold is ADR-048 §6 Level 3 — " <>
             "the run must refuse fail-honestly rather than send a prompt that cannot " <>
             "fit — and the last assistant turn is NEVER promoted into an `{:ok, _}` " <>
             "(the floor, unweakened). Got: #{inspect(result)}"

    {:error, :context_exhausted, run} = result
    run = reload(run)
    assert run.state == :context_exhausted
    assert run.error_kind == "context_exhausted"

    lines = lines_of(run)

    # PRECONDITION 1, MEASURED, the SAME way the rescued arm measures it.
    assert est_tokens(lines) > @ceiling,
           "this control never reached the gate over the ceiling — the assembled " <>
             "history estimates #{est_tokens(lines)} tokens against a ceiling of " <>
             "#{@ceiling}, so the control is vacuous"

    # PRECONDITION 2, MEASURED: exactly ONE committed turn, which is what makes
    # `foldable/2` empty under the two-turn protected tail.
    assert length(lines) == 1,
           "the gate must have been consulted with ONE committed turn for `foldable/2` " <>
             "to be empty; got #{length(lines)} — got lines: #{inspect(lines)}"

    # THE SHARED BINDING, asserted PRESENT the SAME way and in the SAME direction as the
    # rescued arm above — the pair a single assertion-site mutation must flip together.
    assert goal_of(run) =~ @cf17c_canary,
           "the persisted run's own goal field lost the CF-17(c) shared canary — got: " <>
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

  defp transcript_json(run) do
    run = reload(run)
    %Samen.Masked{} = masked = run.transcript
    {:ok, json} = Samen.Vault.reveal(masked, TestRepo, subject_id: run.id)
    Jason.decode!(json)
  end

  # The loop's compactable working set — the exact list `context_gate/6` is handed as
  # `lines` and `foldable/2` segments (ADR-048 §4 non-negotiable 3).
  defp lines_of(run), do: Map.get(transcript_json(run), "llm_view", [])

  defp goal_of(run), do: Map.get(transcript_json(run), "goal", "")

  # The SAME deterministic estimator the gate itself uses (`est_tokens/1`, `agent.ex`):
  # ~4 bytes per token, summed per text. Re-derived here — not called, it is private —
  # so each arm can ASSERT its own over-the-ceiling precondition from the persisted
  # artifact instead of assuming it.
  defp est_tokens(texts) do
    Enum.reduce(texts, 0, fn text, acc -> acc + div(byte_size(text) + 3, 4) end)
  end
end
