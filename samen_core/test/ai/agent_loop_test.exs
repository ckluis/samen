defmodule A1TestAgents do
  @moduledoc false

  defmodule Basic do
    @moduledoc false
    use Samen.AI.Agent,
      name: "a1.basic",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end

  defmodule Tight do
    @moduledoc false
    use Samen.AI.Agent,
      name: "a1.tight",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done.",
      budgets: [max_turns: 2]
  end

  defmodule WithTools do
    @moduledoc false
    use Samen.AI.Agent,
      name: "a1.with-tools",
      goal_prompt: "Use your tools. Reply FINAL: <answer> when done.",
      tools: ["search_records"]
  end
end

defmodule Samen.AI.AgentLoopTest do
  @moduledoc """
  ADR-047 batch A1 — the agent loop core, keyless and tool-free:

    * N-turn history accumulates and re-scrubs through the chokepoint on EVERY turn
      (§3.2a engaged on the agent path; a `vt_*`-poisoned prior turn REFUSES fail-closed);
    * agent runs are masked-only categorically (`egress_opts/2` pins
      `grant_egress?: false` LAST — operator decision §9#2 TAKEN; RP-AG-3's property);
    * all budgets are fail-honest (RP-AG-6): exhaustion is a terminal `:budget_exhausted`
      with a bounded `error_kind`, NEVER a promotion of the last assistant turn —
      sabotage 240 flips the named red tests here;
    * `cancel/2` is durable and re-checked at EVERY turn boundary (RP-AG-8) — sabotage
      241 flips the named cancel tests here;
    * terminal-state honesty on provider error / unscripted (fail-honest, EG6-normalized);
    * NO text at rest: run + turn rows are token-only; the terminal log line is
      token-only (EG6);
    * org isolation on the run rows (RP-AG-10);
    * `Samen.AI.Provider.Scripted` honors the fail-honest adapter contract
      (ADR-014/024/026: unscripted work NEVER returns `{:ok, _}`).

  Anti-tautology: every red assertion is paired with a positive control in the same
  describe block.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase
  use Samen.MaskingCase

  import ExUnit.CaptureLog

  alias A1TestAgents.{Basic, Tight, WithTools}
  alias Samen.AI.Agent
  alias Samen.AI.Agent.Run
  alias Samen.AI.Chokepoint
  alias Samen.AI.Provider.Scripted
  alias SamenCore.TestRepo

  require Ash.Query

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Scripted.reset()
    # A2: the breaker's runtime state (kill-switch, provider-trip streaks) is global —
    # clear it so this suite's provider-error red paths can never park the agent
    # definition across tests.
    Samen.AI.Agent.Breaker.reset()

    on_exit(fn ->
      Scripted.reset()
      Samen.AI.Agent.Breaker.reset()
    end)

    :ok
  end

  defp scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp new_scope, do: scope(Ash.UUID.generate())

  # ── definition/0 + the `use` macro ──────────────────────────────────────────────────

  describe "use Samen.AI.Agent: the validated definition" do
    test "definition/0 returns the validated map with defaulted tools/budgets" do
      assert Basic.definition() == %{
               name: "a1.basic",
               goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done.",
               tools: [],
               budgets: []
             }

      assert Tight.definition().budgets == [max_turns: 2]
    end

    test "RED: a malformed name / vt_ goal prompt / bad budgets refuse at compile time" do
      # POSITIVE CONTROL first: a well-formed definition compiles (the refusals below
      # fail because of their specific violation, not because eval is broken).
      assert {_, _} =
               Code.eval_string("""
               defmodule A1CompileOk#{System.unique_integer([:positive])} do
                 use Samen.AI.Agent, name: "ok.agent", goal_prompt: "Reply FINAL: x"
               end
               """)

      assert_raise CompileError, ~r/requires `name:`/, fn ->
        Code.eval_string("""
        defmodule A1BadName#{System.unique_integer([:positive])} do
          use Samen.AI.Agent, name: "Not A Name", goal_prompt: "Reply FINAL: x"
        end
        """)
      end

      # EG5: an authored goal prompt must never embed a vt_ vault-token sentinel.
      assert_raise CompileError, ~r/vt_/, fn ->
        Code.eval_string("""
        defmodule A1VtPrompt#{System.unique_integer([:positive])} do
          use Samen.AI.Agent, name: "vt.agent",
            goal_prompt: "Reference token: vt_#{String.duplicate("a", 32)}"
        end
        """)
      end

      assert_raise CompileError, ~r/budgets/, fn ->
        Code.eval_string("""
        defmodule A1BadBudget#{System.unique_integer([:positive])} do
          use Samen.AI.Agent, name: "bad.budget", goal_prompt: "Reply FINAL: x",
            budgets: [max_turns: 0]
        end
        """)
      end

      assert_raise CompileError, ~r/tools/, fn ->
        Code.eval_string("""
        defmodule A1BadTools#{System.unique_integer([:positive])} do
          use Samen.AI.Agent, name: "bad.tools", goal_prompt: "Reply FINAL: x",
            tools: [:not_a_string]
        end
        """)
      end
    end
  end

  # ── the loop: goal-met + history accumulation + re-scrub ────────────────────────────

  describe "N-turn loop: goal-met terminal + :history accumulates through the chokepoint" do
    test "a 3-turn run succeeds; each turn's payload carries the accumulated history" do
      s = new_scope()

      script(
        continue: "looking at the shipment",
        continue: "checking the carrier",
        final: "the carrier missed the pickup window"
      )

      assert {:ok, %{answer: answer, run: run, turns: 3}} =
               run_scripted(Basic, s, "why is shipment 4471 late?")

      assert answer == "the carrier missed the pickup window"
      run = assert_terminal!(run, :succeeded)
      assert run.current_turn == 3
      assert run.error_kind == nil

      # Three sealed payloads reached the provider; the goal prompt + goal ride every one.
      [p1, _p2, p3] = sent_segments()
      assert Basic.definition().goal_prompt in p1
      assert "why is shipment 4471 late?" in p3

      # History accumulation: turn 1 has no history; turn 2 carries turn 1's line; turn 3
      # carries both prior lines — each re-entered through `:history`, so the §3.2a
      # re-scrub + step-3/4 allowlist scan ran over them (this is the engaged path).
      refute "looking at the shipment" in p1
      assert_history_accumulated!(2, ["looking at the shipment"])
      assert_history_accumulated!(3, ["looking at the shipment", "checking the carrier"])

      # RP-AG-3's asserted property: every segment is a plain rendered binary — no
      # {:grant_span, …} tag, no vt_*, nothing un-rendered (masked-only, §4.4).
      assert_masked_only_payloads!()

      # The bounded turn log: three :done rows, provider/simulated stamped honestly.
      rows = turn_rows(run)
      assert Enum.map(rows, & &1.turn_index) == [1, 2, 3]
      assert Enum.all?(rows, &(&1.status == :done))
      assert Enum.all?(rows, &(&1.provider == "scripted"))
      assert Enum.all?(rows, &(&1.simulated == true))
      assert Enum.all?(rows, &(&1.tool_kind == nil and &1.arg_keys == []))
    end

    test "RED: a vt_* token in a prior assistant turn REFUSES the next turn fail-closed (INV-7)" do
      s = new_scope()
      poisoned = "reference: vt_" <> String.duplicate("d", 32)

      script([{:continue, poisoned}, {:final, "never reached"}])

      assert {:error, :pii_egress_refused, run} = run_scripted(Basic, s, "goal")

      run = assert_terminal!(run, :failed)
      assert run.error_kind == "pii_egress_refused"

      # Turn 2's payload was REFUSED at the chokepoint BEFORE any provider dispatch:
      # exactly ONE payload ever reached the provider (turn 1), proving the scrub ran on
      # the re-entering history, not merely on fresh segments.
      assert length(sent_segments()) == 1

      # The refused turn is recorded honestly in the bounded log (status :failed, bounded
      # kind, no text).
      assert [%{turn_index: 1, status: :done}, %{turn_index: 2, status: :failed} = t2] =
               turn_rows(run)

      assert t2.error_kind == "pii_egress_refused"

      # ... and the poisoned line is NOT at rest anywhere (token-only rows).
      assert_no_text_at_rest!(run, [poisoned])
    end

    test "POSITIVE CONTROL: the same two-turn shape without the token egresses both turns" do
      s = new_scope()
      script(continue: "clean line", final: "done")

      assert {:ok, %{run: run}} = run_scripted(Basic, s, "goal")
      assert_terminal!(run, :succeeded)
      assert length(sent_segments()) == 2
      assert_history_accumulated!(2, ["clean line"])
    end

    test "egress_opts/2 pins grant_egress?: false LAST — a caller override cannot re-enable it (§4.4)" do
      opts = Agent.egress_opts([grant_egress?: true, history: [:forged], provider: {X, %{}}], ["h1"])

      assert Keyword.get(opts, :grant_egress?) == false
      assert Keyword.get(opts, :history) == ["h1"]
      assert Keyword.get(opts, :provider) == {X, %{}}
    end
  end

  # ── budget honesty (RP-AG-6; sabotage 240) ──────────────────────────────────────────

  describe "budgets are fail-honest: exhaustion is terminal, NEVER a partial answer" do
    test "RED: max_turns exhaustion returns {:error, :budget_exhausted, run} — the last turn is NOT promoted" do
      s = new_scope()

      # Four scripted turns, but the agent's budget is 2: the loop must STOP at the
      # boundary before turn 3 and must NOT dress turn 2's text up as an answer.
      script(
        continue: "step one",
        continue: "step two — a plausible-looking partial answer",
        continue: "step three",
        final: "the real answer"
      )

      result = run_scripted(Tight, s, "hard goal")

      run = assert_honest_exhaustion!(result)
      assert run.error_kind == "max_turns"
      assert run.current_turn == 2

      # Exactly two provider calls happened; the rest of the script is untouched.
      assert length(sent_segments()) == 2
      assert length(Scripted.remaining()) == 2

      # The would-be partial answer exists ONLY in the (dropped) in-memory history —
      # never in the result, never at rest.
      assert_no_text_at_rest!(run, ["plausible-looking partial answer", "the real answer"])
    end

    test "POSITIVE CONTROL: the SAME script under a sufficient budget succeeds with the real answer" do
      s = new_scope()

      script(
        continue: "step one",
        continue: "step two — a plausible-looking partial answer",
        continue: "step three",
        final: "the real answer"
      )

      assert {:ok, %{answer: "the real answer", turns: 4, run: run}} =
               run_scripted(Basic, s, "hard goal")

      assert_terminal!(run, :succeeded)
    end

    test "RED: input-token budget exhausts at the boundary after the crossing turn (summed from usage)" do
      s = new_scope()

      usage = %{input_tokens: 100, output_tokens: 10}

      script([
        {:continue, "one", usage},
        {:continue, "two", usage},
        {:continue, "three", usage},
        {:final, "never", usage}
      ])

      result = run_scripted(Basic, s, "goal", budgets: [max_input_tokens: 150])

      run = assert_honest_exhaustion!(result)
      assert run.error_kind == "max_input_tokens"
      assert run.input_tokens_used == 200
      assert length(sent_segments()) == 2
    end

    test "RED: output-token budget exhausts fail-honestly too" do
      s = new_scope()
      usage = %{input_tokens: 1, output_tokens: 500}

      script([{:continue, "one", usage}, {:continue, "two", usage}, {:final, "never", usage}])

      result = run_scripted(Basic, s, "goal", budgets: [max_output_tokens: 600])

      run = assert_honest_exhaustion!(result)
      assert run.error_kind == "max_output_tokens"
      assert run.output_tokens_used == 1000
    end

    test "POSITIVE CONTROL: the same token usage under the default 60k/8k budgets succeeds" do
      s = new_scope()
      usage = %{input_tokens: 100, output_tokens: 10}

      script([{:continue, "one", usage}, {:final, "fits", usage}])

      assert {:ok, %{answer: "fits", run: run}} = run_scripted(Basic, s, "goal")
      run = assert_terminal!(run, :succeeded)
      assert run.input_tokens_used == 200
      assert run.output_tokens_used == 20
    end

    test "over_budget/2 covers all five budgets (the pure boundary check, unit-proved)" do
      now = DateTime.utc_now()

      base = %Run{
        current_turn: 0,
        max_turns: 8,
        tool_calls_used: 0,
        max_tool_calls: 12,
        input_tokens_used: 0,
        max_input_tokens: 60_000,
        output_tokens_used: 0,
        max_output_tokens: 8_000,
        started_at: now,
        deadline_seconds: 600
      }

      assert Agent.over_budget(base, now) == nil
      assert Agent.over_budget(%{base | current_turn: 8}, now) == :max_turns
      assert Agent.over_budget(%{base | tool_calls_used: 12}, now) == :max_tool_calls
      assert Agent.over_budget(%{base | input_tokens_used: 60_001}, now) == :max_input_tokens
      assert Agent.over_budget(%{base | output_tokens_used: 8_001}, now) == :max_output_tokens

      assert Agent.over_budget(%{base | started_at: DateTime.add(now, -601)}, now) == :deadline
      assert Agent.over_budget(%{base | started_at: DateTime.add(now, -599)}, now) == nil
    end

    test "budget resolution honesty: malformed per-run budgets are refused, never silently defaulted" do
      s = new_scope()
      script(final: "x")

      assert {:error, :invalid_budgets} =
               run_scripted(Basic, s, "goal", budgets: [max_turns: -1])

      assert {:error, :invalid_budgets} =
               run_scripted(Basic, s, "goal", budgets: [surprise_key: 5])

      # POSITIVE CONTROL: well-formed overrides run.
      assert {:ok, _} = run_scripted(Basic, s, "goal", budgets: [max_turns: 3])
    end
  end

  # ── cancel: durable + per-turn re-check (RP-AG-8; sabotage 241) ─────────────────────

  describe "cancel/2 is durable and honored at EVERY turn boundary" do
    test "RED: a cancel issued DURING turn 2 stops turn 3 (the in-flight turn completes honestly)" do
      s = new_scope()
      org_id = s.actor.org_id

      script([
        {:continue, "turn one"},
        fn ->
          # Issued while turn 2 is in flight (inside the provider call): the durable flag
          # lands on the run row; the loop must see it at the NEXT boundary.
          [running] =
            Run
            |> Ash.Query.filter(org_id == ^org_id and state == :running)
            |> Ash.read!(authorize?: false)

          {:ok, _} = Agent.cancel(scope(org_id), running.id)
          {:continue, "turn two"}
        end,
        {:final, "never reached"}
      ])

      assert {:error, :cancelled, run} = run_scripted(Basic, s, "goal")

      run = assert_terminal!(run, :cancelled)
      assert run.cancel_requested_at != nil
      assert run.error_kind == "cancelled"

      # "Stopping after the current step": turn 2 completed and was recorded; turn 3
      # never reached the provider.
      assert length(sent_segments()) == 2
      assert [%{turn_index: 1, status: :done}, %{turn_index: 2, status: :done}] = turn_rows(run)
      assert length(Scripted.remaining()) == 1
    end

    test "POSITIVE CONTROL: the same script WITHOUT the cancel runs turn 3 to the final answer" do
      s = new_scope()

      script([
        {:continue, "turn one"},
        {:continue, "turn two"},
        {:final, "reached"}
      ])

      assert {:ok, %{answer: "reached", turns: 3, run: run}} = run_scripted(Basic, s, "goal")
      assert_terminal!(run, :succeeded)
      assert length(sent_segments()) == 3
    end

    test "cancel of a terminal run is refused honestly; cross-org cancel finds nothing (RP-AG-10)" do
      s = new_scope()
      script(final: "done")

      assert {:ok, %{run: run}} = run_scripted(Basic, s, "goal")

      assert {:error, :already_terminal} = Agent.cancel(s, run.id)

      # A foreign org's scope cannot even SEE the run, let alone cancel it (OrgScope:
      # foreign rows do not exist). Same-org control is the :already_terminal above
      # (the load succeeded there).
      assert {:error, :not_found} = Agent.cancel(new_scope(), run.id)
    end
  end

  # ── terminal-state honesty: provider error / unscripted / tools ─────────────────────

  describe "terminal-state honesty (fail-honest, EG6-normalized)" do
    test "RED: a rich provider error is EG6-normalized; nothing rich lands at rest or in the result" do
      s = new_scope()

      script([{:continue, "one"}, {:error, {:boom, "SECRET-adapter-detail"}}])

      assert {:error, {:provider_error, Scripted}, run} = run_scripted(Basic, s, "goal")

      run = assert_terminal!(run, :failed)
      assert run.error_kind == "provider_error"

      assert [%{status: :done}, %{turn_index: 2, status: :failed} = t2] = turn_rows(run)
      assert t2.error_kind == "provider_error"

      # EG6: the adapter's rich reason never survives — not in the row, not in the run.
      assert_no_text_at_rest!(run, ["SECRET-adapter-detail", "boom"])
    end

    test "RED: an UNSCRIPTED provider is fail-honest — {:error, :not_configured}, never a canned {:ok, _}" do
      s = new_scope()
      # No script at all: the double must refuse (work not scripted is work not done).
      assert {:error, :not_configured, run} = run_scripted(Basic, s, "goal")

      run = assert_terminal!(run, :failed)
      assert run.error_kind == "not_configured"
      assert [%{turn_index: 1, status: :failed}] = turn_rows(run)
    end

    test "RED: an A1 definition declaring tools: is refused honestly, before any provider call" do
      s = new_scope()
      script(final: "should never be consumed")

      assert {:error, :tools_not_supported, run} = run_scripted(WithTools, s, "goal")

      run = assert_terminal!(run, :failed)
      assert run.error_kind == "tools_not_supported"
      assert sent_segments() == []
      assert length(Scripted.remaining()) == 1
    end

    test "POSITIVE CONTROL: a tool-free definition with a script runs (the refusals above are specific)" do
      s = new_scope()
      script(final: "ran")
      assert {:ok, %{answer: "ran"}} = run_scripted(Basic, s, "goal")
    end

    test "state machine: a terminal run refuses further lifecycle transitions" do
      s = new_scope()
      script(final: "done")
      assert {:ok, %{run: run}} = run_scripted(Basic, s, "goal")

      # :succeed transitions only from :running — a second :succeed on the terminal row
      # is an AshStateMachine invalid-transition error, never a silent re-finalize.
      assert {:error, _} =
               run
               |> Ash.Changeset.for_update(:succeed, %{})
               |> Ash.update(authorize?: false)
    end
  end

  # ── no text at rest + token-only logs (EG6) ─────────────────────────────────────────

  describe "no plaintext in any persisted or logged artifact (ADR-047 §6)" do
    test "run + turn rows are token-only; the terminal log line is token-only" do
      s = new_scope()

      canaries = [
        "CANARY-goal-a1c3",
        "CANARY-assistant-one-a1c3",
        "CANARY-assistant-two-a1c3",
        "CANARY-final-a1c3"
      ]

      script(
        continue: "thinking about CANARY-assistant-one-a1c3",
        continue: "refining CANARY-assistant-two-a1c3",
        final: "CANARY-final-a1c3"
      )

      # The terminal line is :info (routine, token-only); the suite's primary level is
      # :warning, so raise it for this one capture (restored below; the suite is sync).
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, %{answer: "CANARY-final-a1c3", run: run}} =
                   run_scripted(Basic, s, "the goal is CANARY-goal-a1c3")

          # POSITIVE CONTROL half 1: the canaries genuinely flowed — the goal + both
          # intermediate assistant turns crossed the provider boundary (the final turn's
          # canary flowed OUT as the answer, asserted above), so the at-rest scan below
          # is scanning for text that really moved through the loop.
          texts = Enum.join(sent_texts(), "\n")
          for canary <- Enum.take(canaries, 3), do: assert(texts =~ canary)

          # The red half: none of it is at rest on the run row or ANY turn row.
          assert_no_text_at_rest!(run, canaries)
        end)

      # POSITIVE CONTROL half 2: the terminal line EXISTS (the capture genuinely observed
      # the loop's EG6 surface) ...
      assert log =~ "samen.ai.agent run="
      assert log =~ "state=succeeded"

      # ... and carries ids/enums/counts only — no goal text, no completion text.
      for canary <- canaries do
        refute log =~ canary, "EG6 leak: #{canary} appeared in the agent log line"
      end
    end
  end

  # ── org isolation (RP-AG-10) ────────────────────────────────────────────────────────

  describe "run rows are org-scoped (OrgScope: foreign rows do not exist)" do
    test "org B cannot read org A's runs; org A can (positive control)" do
      a = new_scope()
      b = new_scope()

      script(final: "done")
      assert {:ok, %{run: run}} = run_scripted(Basic, a, "goal")

      assert {:ok, [_]} = Ash.read(Ash.Query.filter(Run, id == ^run.id), scope: a)
      assert {:ok, []} = Ash.read(Ash.Query.filter(Run, id == ^run.id), scope: b)
    end
  end

  # ── the Scripted double's own contract ──────────────────────────────────────────────

  describe "Samen.AI.Provider.Scripted: deterministic + fail-honest + head-matched" do
    test "head-match: a raw (unsealed) payload refuses by FunctionClauseError" do
      # `apply/3` so the runtime clause refusal is what's proven (a direct literal call
      # would be flagged at compile time by the type checker — which is fine, but the
      # contract under test is the RUNTIME head-match).
      assert_raise FunctionClauseError, fn ->
        apply(Scripted, :complete, ["raw string that never went through seal/3", %{}])
      end
    end

    test "fail-honest: no script / exhausted script NEVER yields {:ok, _}; simulated? is true" do
      {:ok, payload} = Chokepoint.seal(:complete, ["x"], grounding: %{}, meta: %{})

      assert Scripted.complete(payload, %{}) == {:error, :not_configured}

      Scripted.script(continue: "only one")
      assert {:ok, _} = Scripted.complete(payload, %{})
      assert Scripted.complete(payload, %{}) == {:error, :not_configured}

      assert Scripted.simulated?() == true
      assert Scripted.embed(payload, %{}) == {:error, :not_implemented}
    end

    test "deterministic: the same script yields the same completions, and the chokepoint stamps simulated" do
      {:ok, payload} = Chokepoint.seal(:complete, ["x"], grounding: %{}, meta: %{})

      for _ <- 1..2 do
        Scripted.script(continue: "same", final: "answer")
        assert {:ok, %{text: "same"}} = Scripted.complete(payload, %{})
        assert {:ok, %{text: "FINAL: answer"}} = Scripted.complete(payload, %{})
      end

      # Through the ONE dispatch site, the completion is stamped simulated: true by
      # construction (T152) — the loop's turn rows persist exactly that stamp.
      Scripted.script(continue: "via chokepoint")

      assert {:ok, %{simulated: true}} =
               Chokepoint.complete(Scripted, %{}, :complete, ["x"], grounding: %{}, meta: %{})
    end
  end
end
