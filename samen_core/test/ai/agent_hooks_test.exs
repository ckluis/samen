defmodule T181Probe do
  @moduledoc """
  Cross-process scratch for the T181 hook probes (the `Provider.Scripted`
  `:persistent_term` convention — the loop may execute a turn in a worker process).

  `note/1` appends an invocation tag in order, which is how "the hook behind the
  decision was never consulted" becomes an assertion rather than a hope.
  """

  @calls {:t181, :calls}

  def reset do
    :persistent_term.put(@calls, [])
    :persistent_term.put({:t181, :edit_args}, nil)
    :persistent_term.put({:t181, :halt_point}, :before_tool_call)
    :ok
  end

  def note(tag), do: :persistent_term.put(@calls, :persistent_term.get(@calls, []) ++ [tag])
  def calls, do: :persistent_term.get(@calls, [])
  def put(key, value), do: :persistent_term.put({:t181, key}, value)
  def get(key, default \\ nil), do: :persistent_term.get({:t181, key}, default)
end

defmodule T181Hooks do
  @moduledoc "The probe hooks. Each notes itself, so ORDER of consultation is observable."

  defmodule Recorder do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(point, _ctx) do
      T181Probe.note({:recorder, point})
      :ok
    end
  end

  defmodule Blocker do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(:before_tool_call, _ctx) do
      T181Probe.note(:blocker)
      {:block, :policy_says_no}
    end

    def call(_point, _ctx), do: :ok
  end

  defmodule PreflightBlocker do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(:after_tool_request, _ctx) do
      T181Probe.note(:preflight_blocker)
      {:block, :not_this_turn}
    end

    def call(_point, _ctx), do: :ok
  end

  defmodule Editor do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(:before_tool_call, %{args: args}) do
      T181Probe.note(:editor)
      {:edit, %{args: Map.merge(args, T181Probe.get(:edit_args, %{}))}}
    end

    def call(_point, _ctx), do: :ok
  end

  defmodule IdentitySwapper do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(:before_tool_call, %{args: args}) do
      T181Probe.note(:identity_swapper)
      {:edit, %{kind: "search_records", args: args}}
    end

    def call(_point, _ctx), do: :ok
  end

  defmodule Raiser do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(:before_tool_call, _ctx) do
      T181Probe.note(:raiser)
      raise "the hook itself is broken"
    end

    def call(_point, _ctx), do: :ok
  end

  defmodule Halter do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(point, _ctx) do
      if point == T181Probe.get(:halt_point) do
        T181Probe.note({:halter, point})
        {:halt, :operator_stop}
      else
        :ok
      end
    end
  end

  defmodule Passive do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(_point, _ctx), do: :ok
  end

  defmodule Rogue do
    @moduledoc false
    @behaviour Samen.AI.Agent.Hook

    @impl true
    def call(:after_tool_execution, _ctx), do: {:edit, %{args: %{}}}
    def call(_point, _ctx), do: :ok
  end

  defmodule NotAHook do
    @moduledoc "A module that EXISTS and does not export call/2 — the configuration typo."
    def unrelated, do: :ok
  end
end

defmodule T181Agents do
  @moduledoc false

  defmodule Reader do
    @moduledoc false
    use Samen.AI.Agent,
      name: "t181.reader",
      goal_prompt: "Use your tools to answer. Reply FINAL: <answer> when done.",
      tools: ["fetch_record", "search_records"]
  end

  defmodule Writer do
    @moduledoc false
    use Samen.AI.Agent,
      name: "t181.writer",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done.",
      tools: ["fetch_record", "assign_record_owner"]
  end
end

defmodule Samen.AI.AgentHooksTest do
  @moduledoc """
  T181 (ADR-047 §10a row 25) — the loop's ONE declared policy seam: `Samen.AI.Agent.Hook`'s
  seven-point ordered chain and `Samen.AI.Agent.Hooks`' dispatch.

  The four contract properties the done-criterion names:

    * **first-decision-wins** — the first hook to return a decision ends the chain, and a
      hook behind it is not consulted AT ALL (proven by the invocation trace, with the
      order-swapped positive control that proves the trace is not vacuous);
    * **`{:block, reason}` stops the tool call** — nothing executes, nothing proposes, the
      refusal is recorded fail-honestly and the run continues under its budgets;
    * **`{:edit, call}` mutates the call ACTUALLY EXECUTED** — the edited record is the one
      fetched and rendered back, and the model's own id never reaches the action or the
      provider; the committed decision stamp binds the EDITED args, not the requested ones;
    * **a hook that RAISES fails the call closed** — `:hook_error`, nothing executed. The
      positive control (same script, empty chain) executes, so "nothing happened" is a
      property of the raise and not of the fixture.

  Plus the narrowing invariants the seam exists to keep: a hook cannot change WHICH tool
  runs, cannot inject a `vt_` vault token to unmask a field, cannot reach `egress_opts/3`,
  and cannot auto-approve a write. And `{:halt, reason}` is a real terminal, never a
  promoted answer.

  Anti-tautology: every red assertion ships with its positive control.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias Samen.AI.Agent
  alias Samen.AI.Agent.Hook
  alias Samen.AI.Agent.Hooks
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.WriteProposal
  alias Samen.AI.Provider.Scripted
  alias Samen.Approvals
  alias SamenCore.Support.AgentMembershipFixture, as: Membership
  alias SamenCore.Support.AutomationFixture.Subject
  alias SamenCore.Support.AutomationFixture.Target
  alias SamenCore.TestRepo
  alias T181Agents.Reader
  alias T181Agents.Writer

  require Ash.Query

  @subject_key "SamenCore.Support.AutomationFixture.Subject"
  @target_key "SamenCore.Support.AutomationFixture.Target"
  @original_title "T181-ORIGINAL-not-the-edited-one"
  @edited_title "T181-EDITED-TARGET-record"
  @email_canary "canary-t181-hooks-4b8m@leak.example"
  @vt_token "vt_" <> String.duplicate("d", 32)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Scripted.reset()
    Agent.Breaker.reset()
    T181Probe.reset()
    Membership.reset()
    prior_agent_config = Membership.install!()

    on_exit(fn ->
      Scripted.reset()
      Agent.Breaker.reset()
      T181Probe.reset()
      Membership.reset()
      Membership.restore!(prior_agent_config)
    end)

    :ok
  end

  defp new_scope do
    org_id = Ash.UUID.generate()
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp create_subject!(org_id, title) do
    Subject
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      title: title,
      priority: :high,
      status: :open,
      email: @email_canary
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_target!(org_id) do
    Target
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      title: "t181 target",
      priority: :high,
      email: @email_canary
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload_target!(id) do
    Target
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:owner_id])
    |> Ash.read!(authorize?: false)
    |> hd()
  end

  defp fetch_call(subject_id, key \\ @subject_key),
    do: {:tool_call, "fetch_record", %{"resource" => key, "id" => subject_id}}

  defp assign_call(target_id, user_id) do
    {:tool_call, "assign_record_owner",
     %{"resource" => @target_key, "id" => target_id, "user_id" => user_id}}
  end

  defp all_sent_text, do: sent_texts() |> Enum.join("\n")

  # ── 1 · first-decision-wins ─────────────────────────────────────────────────────────

  describe "first-decision-wins: the chain is ordered and the first decision ends it" do
    test "RED: a hook BEHIND the deciding hook is never consulted — the trailing :edit cannot override the leading :block" do
      s = new_scope()
      original = create_subject!(s.actor.org_id, @original_title)
      edited = create_subject!(s.actor.org_id, @edited_title)
      T181Probe.put(:edit_args, %{"id" => edited.id})

      script([fetch_call(original.id), {:final, "declined"}])

      assert {:ok, %{run: run}} =
               run_scripted(Reader, s, "look it up",
                 hooks: [T181Hooks.Blocker, T181Hooks.Editor, T181Hooks.Recorder]
               )

      calls = T181Probe.calls()

      # The blocker decided at :before_tool_call, so NOTHING behind it in the chain was
      # consulted AT THAT POINT — not the editor, not the recorder.
      assert :blocker in calls
      refute :editor in calls
      refute {:recorder, :before_tool_call} in calls

      # ...and the trace is not vacuous: the recorder WAS consulted at the point just
      # BEFORE the decision, and again at :on_error when the loop absorbed the block.
      assert {:recorder, :after_tool_request} in calls
      assert {:recorder, :on_error} in calls

      # And the decision that STOOD is the block: nothing executed, nothing edited.
      assert [t1, _t2] = turn_rows(run)
      assert t1.error_kind == "hook_blocked"
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 0
      refute all_sent_text() =~ edited.id
      refute all_sent_text() =~ "priority:"
    end

    test "POSITIVE CONTROL: the same two hooks in the OPPOSITE order — the leading :edit stands and the trailing :block is never consulted" do
      s = new_scope()
      original = create_subject!(s.actor.org_id, @original_title)
      edited = create_subject!(s.actor.org_id, @edited_title)
      T181Probe.put(:edit_args, %{"id" => edited.id})

      script([fetch_call(original.id), {:final, "edited"}])

      assert {:ok, %{answer: "edited", run: run}} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Editor, T181Hooks.Blocker])

      assert T181Probe.calls() == [:editor]
      assert [%{error_kind: nil}, _] = turn_rows(run)
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 1
      assert all_sent_text() =~ edited.id
      refute all_sent_text() =~ original.id
    end

    test "POSITIVE CONTROL: a deferring hook IN FRONT is consulted, then the decision behind it is taken (the trace is not vacuous)" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)

      script([fetch_call(subject.id), {:final, "declined"}])

      assert {:ok, %{run: run}} =
               run_scripted(Reader, s, "look it up",
                 hooks: [T181Hooks.Recorder, T181Hooks.Blocker]
               )

      assert {:recorder, :before_tool_call} in T181Probe.calls()
      assert :blocker in T181Probe.calls()
      assert Enum.find_index(T181Probe.calls(), &(&1 == :blocker)) > 0
      assert [%{error_kind: "hook_blocked"}, _] = turn_rows(run)
    end
  end

  # ── 2 · {:block, reason} stops the tool call ────────────────────────────────────────

  describe "{:block, reason} stops the tool call" do
    test "RED: the governed action never runs, the refusal is recorded fail-honestly, and the run continues under its budgets" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)

      script([fetch_call(subject.id), {:final, "moved on"}])

      assert {:ok, %{answer: "moved on", run: run}} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Blocker])

      assert [t1, _t2] = turn_rows(run)
      assert t1.error_kind == "hook_blocked"
      assert t1.tool_kind == "fetch_record"
      assert t1.meta["hook_reason"] == "policy_says_no"
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 0

      # Never a silent skip: the model was told, honestly and boundedly.
      assert_history_accumulated!(2, ["tool_error: hook_blocked"])

      # And nothing OF THE RECORD — not even the id the model named — crossed the
      # provider boundary: a blocked call has no echo and no result.
      refute all_sent_text() =~ "priority:"
      refute all_sent_text() =~ subject.id
    end

    test "POSITIVE CONTROL: the identical script with an EMPTY chain executes the tool and renders the record" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)

      script([fetch_call(subject.id), {:final, "moved on"}])

      assert {:ok, %{run: run}} = run_scripted(Reader, s, "look it up")

      assert [%{error_kind: nil, tool_kind: "fetch_record"}, _] = turn_rows(run)
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 1
      assert all_sent_text() =~ subject.id
      assert all_sent_text() =~ "priority: high"
    end

    test "a block at :after_tool_request refuses BEFORE the intersection resolves the kind — and an unregistered kind still never lands in a column" do
      s = new_scope()

      script([{:tool_call, "drop_all_tables", %{}}, {:final, "declined"}])

      assert {:ok, %{run: run}} =
               run_scripted(Reader, s, "goal", hooks: [T181Hooks.PreflightBlocker])

      assert [t1, _t2] = turn_rows(run)
      assert t1.error_kind == "hook_blocked"
      assert t1.tool_kind == nil
      assert t1.meta["hook_reason"] == "not_this_turn"
      assert T181Probe.calls() == [:preflight_blocker]
    end
  end

  # ── 3 · {:edit, call} mutates the call actually executed ────────────────────────────

  describe "{:edit, call} mutates the call ACTUALLY EXECUTED" do
    test "RED: the EDITED record is fetched and rendered; the model's own id never reaches the action or the provider" do
      s = new_scope()
      original = create_subject!(s.actor.org_id, @original_title)
      edited = create_subject!(s.actor.org_id, @edited_title)
      T181Probe.put(:edit_args, %{"id" => edited.id})

      script([fetch_call(original.id), {:final, "done"}])

      assert {:ok, %{answer: "done", run: run}} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Editor])

      assert [t1, _t2] = turn_rows(run)
      assert t1.error_kind == nil
      assert t1.tool_kind == "fetch_record"

      # Not a logged copy: the EXECUTED call is the edited one — the rendered result that
      # re-entered as history is the edited record, and the requested id is nowhere.
      text = all_sent_text()
      assert text =~ "record: #{@subject_key}##{edited.id}"
      assert text =~ "priority: high"
      refute text =~ original.id

      # And the committed DECISION STAMP binds the EDITED args, not the requested ones.
      assert t1.meta["args_digest"] ==
               Agent.args_digest(%{"resource" => @subject_key, "id" => edited.id})

      refute t1.meta["args_digest"] ==
               Agent.args_digest(%{"resource" => @subject_key, "id" => original.id})
    end

    test "POSITIVE CONTROL: without the hook the SAME script fetches the record the model asked for" do
      s = new_scope()
      original = create_subject!(s.actor.org_id, @original_title)
      edited = create_subject!(s.actor.org_id, @edited_title)

      script([fetch_call(original.id), {:final, "done"}])

      assert {:ok, %{run: run}} = run_scripted(Reader, s, "look it up")

      assert [t1, _t2] = turn_rows(run)
      assert all_sent_text() =~ original.id
      refute all_sent_text() =~ edited.id

      assert t1.meta["args_digest"] ==
               Agent.args_digest(%{"resource" => @subject_key, "id" => original.id})
    end
  end

  # ── 4 · a raising hook fails the call CLOSED ────────────────────────────────────────

  describe "a hook that RAISES fails the tool call closed" do
    test "RED: :hook_error — the tool never executes UNHOOKED, and nothing of the record crosses the boundary" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)

      script([fetch_call(subject.id), {:final, "moved on"}])

      assert {:ok, %{answer: "moved on", run: run}} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Raiser])

      assert T181Probe.calls() == [:raiser]
      assert [t1, _t2] = turn_rows(run)
      assert t1.error_kind == "hook_error"
      assert t1.tool_kind == "fetch_record"
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 0
      refute all_sent_text() =~ subject.id
      refute all_sent_text() =~ "priority:"

      # The raise's message is never an egress (EG6) — not at rest, not to the provider.
      assert_no_text_at_rest!(run, ["the hook itself is broken"])
      refute all_sent_text() =~ "the hook itself is broken"
    end

    test "RED: a module that does not export call/2 is not silently DROPPED — it stops the run at the first point it reaches" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)

      script([fetch_call(subject.id), {:final, "moved on"}])

      assert {:error, :hook_error, run} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.NotAHook])

      # `:session_start` is the first point it reaches, and that point cannot block — so
      # the fail-closed answer is to stop the run, BEFORE any provider byte leaves.
      assert sent_texts() == []
      run = Ash.get!(Run, run.id, authorize?: false)
      assert run.state == :failed
      assert run.error_kind == "hook_error"
      assert run.tool_calls_used == 0
      refute all_sent_text() =~ subject.id
    end

    test "POSITIVE CONTROL: a PASSIVE hook in the same position lets the identical call through" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)

      script([fetch_call(subject.id), {:final, "moved on"}])

      assert {:ok, %{run: run}} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Passive])

      assert [%{error_kind: nil}, _] = turn_rows(run)
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 1
      assert all_sent_text() =~ subject.id
    end
  end

  # ── 5 · {:halt, reason} ends the run fail-honestly ──────────────────────────────────

  describe "{:halt, reason} ends the run fail-honestly" do
    test "a halt at :before_tool_call is a REAL terminal with a bounded kind — never a promoted answer" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)
      T181Probe.put(:halt_point, :before_tool_call)

      script([fetch_call(subject.id), {:final, "never reached"}])

      assert {:error, :hook_halted, run} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Halter])

      run = Ash.get!(Run, run.id, authorize?: false)
      assert run.state == :failed
      assert run.error_kind == "hook_halted"
      assert run.tool_calls_used == 0
      assert [%{status: :failed, error_kind: "hook_halted"} = t1] = turn_rows(run)
      assert t1.meta["hook_reason"] == "operator_stop"
    end

    test "a halt at :session_start stops the run before ANY provider byte leaves" do
      s = new_scope()
      T181Probe.put(:halt_point, :session_start)

      script([{:final, "never reached"}])

      assert {:error, :hook_halted, run} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Halter])

      assert sent_texts() == []
      run = Ash.get!(Run, run.id, authorize?: false)
      assert run.state == :failed
      assert run.error_kind == "hook_halted"
      assert run.current_turn == 0
      assert turn_rows(run) == []
    end

    test "a halt at :before_completion finalizes the turn row it landed on — no dangling :proposed row" do
      s = new_scope()
      T181Probe.put(:halt_point, :before_completion)

      script([{:final, "never reached"}])

      assert {:error, :hook_halted, run} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Halter])

      assert sent_texts() == []
      assert [%{turn_index: 1, status: :failed, error_kind: "hook_halted"}] = turn_rows(run)
    end

    test "POSITIVE CONTROL: the identical scripts with an empty chain reach their FINAL answer" do
      s = new_scope()
      script([{:final, "reached"}])
      assert {:ok, %{answer: "reached"}} = run_scripted(Reader, s, "look it up")
    end
  end

  # ── 6 · hooks may only NARROW ───────────────────────────────────────────────────────

  describe "narrowing only: a hook can make the loop do less, never more" do
    test "RED: an edit cannot change WHICH tool runs — tool identity is immutable, and the swap fails closed" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)

      script([fetch_call(subject.id), {:final, "declined"}])

      assert {:ok, %{run: run}} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.IdentitySwapper])

      assert T181Probe.calls() == [:identity_swapper]
      assert [%{error_kind: "hook_error", tool_kind: "fetch_record"}, _] = turn_rows(run)
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 0
      refute all_sent_text() =~ "hits:"
    end

    test "RED: an edit cannot UNMASK — a `vt_` vault token in the edited args is refused before anything executes" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)
      T181Probe.put(:edit_args, %{"resource" => @vt_token})

      script([fetch_call(subject.id), {:final, "declined"}])

      assert {:ok, %{run: run}} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Editor])

      assert [%{error_kind: "invalid_args"}, _] = turn_rows(run)
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 0
      assert_no_text_at_rest!(run, [@vt_token])
    end

    test "RED: an edit cannot hand the action a payload its OWN validate/2 rejects" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id, @original_title)
      T181Probe.put(:edit_args, %{"id" => "not-a-uuid"})

      script([fetch_call(subject.id), {:final, "declined"}])

      assert {:ok, %{run: run}} =
               run_scripted(Reader, s, "look it up", hooks: [T181Hooks.Editor])

      assert [%{error_kind: "invalid_args"}, _] = turn_rows(run)
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 0
    end

    test "hooks are STRUCTURALLY invisible to egress_opts/3 — no hook can re-enable grant plaintext" do
      opts = [
        provider: {Scripted, %{}},
        hooks: [T181Hooks.Editor],
        resolved_hooks: [T181Hooks.Editor],
        grant_egress?: true,
        history: ["smuggled"]
      ]

      egress = Agent.egress_opts(opts, ["real history"], [])

      assert Keyword.fetch!(egress, :grant_egress?) == false
      refute Keyword.has_key?(egress, :hooks)
      refute Keyword.has_key?(egress, :resolved_hooks)
      assert Keyword.fetch!(egress, :history) == ["real history"]
    end

    test "RED: no hook return AUTO-APPROVES a write — an :ok chain and an :edit chain both still PARK for a distinct human" do
      for chain <- [[T181Hooks.Passive], [T181Hooks.Editor]] do
        T181Probe.reset()
        s = new_scope()
        target = create_target!(s.actor.org_id)
        new_owner = Ash.UUID.generate()
        T181Probe.put(:edit_args, %{"user_id" => new_owner})

        script([assign_call(target.id, new_owner), {:final, "never reached"}])

        assert {:awaiting_approval, run} =
                 run_scripted(Writer, s, "who should own it?", hooks: chain)

        run = Ash.get!(Run, run.id, authorize?: false)
        assert run.state == :awaiting_approval
        assert run.tool_calls_used == 0
        assert reload_target!(target.id).owner_id == nil
        assert {:ok, [_approval]} = Approvals.list_pending(s.actor.org_id, WriteProposal.kind())
      end
    end

    test "POSITIVE CONTROL (the narrowing direction IS available): a hook may BLOCK the write — no approval is even opened" do
      s = new_scope()
      target = create_target!(s.actor.org_id)

      script([assign_call(target.id, Ash.UUID.generate()), {:final, "declined"}])

      assert {:ok, %{run: run}} =
               run_scripted(Writer, s, "who should own it?", hooks: [T181Hooks.Blocker])

      assert [%{error_kind: "hook_blocked", tool_kind: "assign_record_owner"}, _] =
               turn_rows(run)

      assert reload_target!(target.id).owner_id == nil
      assert {:ok, []} = Approvals.list_pending(s.actor.org_id, WriteProposal.kind())
    end
  end

  # ── 7 · the declared contract itself ────────────────────────────────────────────────

  describe "the declared seven-point contract" do
    test "exactly seven points, in loop order, each with a CLOSED set of honourable decisions" do
      assert Hook.points() == [
               :session_start,
               :before_completion,
               :after_compaction,
               :after_tool_request,
               :before_tool_call,
               :after_tool_execution,
               :on_error
             ]

      assert length(Hook.points()) == 7
      assert Hook.accepts(:before_tool_call) == [:block, :edit, :halt]
      assert Hook.accepts(:after_tool_request) == [:block, :halt]
      assert Hook.accepts(:session_start) == [:halt]
      assert Hook.accepts(:after_compaction) == [:halt]
      assert Hook.accepts(:after_tool_execution) == [:halt]
      assert Hook.accepts(:on_error) == [:halt]

      # Fail closed: an undeclared point honours nothing.
      assert Hook.accepts(:not_a_point) == []
      refute Hook.accepts?(:session_start, :edit)
    end

    test ":after_compaction is DECLARED and dispatchable even though v1's loop has no compactor" do
      assert :after_compaction in Hook.points()
      T181Probe.put(:halt_point, :after_compaction)

      assert Hooks.dispatch([T181Hooks.Halter], :after_compaction, %{}) ==
               {:halt, :hook_halted, "operator_stop"}

      # Honestly recorded as having no in-loop caller in v1: the loop dispatches the
      # other six points and never this one.
      loop_source = File.read!("lib/samen/ai/agent.ex")
      refute loop_source =~ "Hooks.dispatch(hooks, :after_compaction"
      assert loop_source =~ "Hooks.dispatch(hooks, :before_tool_call"
    end

    test "a decision the point cannot honour fails CLOSED — an :edit at :after_tool_execution is a halt, not a shrug" do
      assert Hooks.dispatch([T181Hooks.Rogue], :after_tool_execution, %{}) ==
               {:halt, :hook_error, "hook_error"}

      # ...and the same rogue hook is inert at every point it does not decide at.
      assert Hooks.dispatch([T181Hooks.Rogue], :before_tool_call, %{kind: "x"}) == :ok
    end

    test "a raise fails closed to the STRONGEST refusal the point accepts — block where blocking exists, halt where it does not" do
      assert Hooks.dispatch([T181Hooks.Raiser], :before_tool_call, %{kind: "x"}) ==
               {:block, :hook_error, "hook_error"}

      assert Hooks.dispatch([Module.concat([:T181NeverCompiledHook])], :session_start, %{}) ==
               {:halt, :hook_error, "hook_error"}
    end

    test "an empty chain is always :ok (the seam costs nothing when nobody uses it)" do
      for point <- Hook.points(), do: assert(Hooks.dispatch([], point, %{}) == :ok)
    end

    test "resolve/1 puts HOST-configured hooks in front of per-run hooks — a caller cannot pre-empt host policy" do
      prior = Application.get_env(:samen_core, Agent, [])

      on_exit(fn -> Application.put_env(:samen_core, Agent, prior) end)

      Application.put_env(
        :samen_core,
        Agent,
        Keyword.put(prior, :hooks, [T181Hooks.Blocker])
      )

      assert Hooks.resolve(hooks: [T181Hooks.Editor]) == [T181Hooks.Blocker, T181Hooks.Editor]

      Application.put_env(:samen_core, Agent, Keyword.delete(prior, :hooks))
      assert Hooks.resolve(hooks: [T181Hooks.Editor]) == [T181Hooks.Editor]
      assert Hooks.resolve([]) == []
    end

    test "reasons are bounded and token-only before they ever reach the turn log" do
      assert Hooks.bounded_reason(:policy_says_no) == "policy_says_no"
      assert Hooks.bounded_reason("plain") == "plain"
      assert byte_size(Hooks.bounded_reason(String.duplicate("x", 500))) == 64

      # A vault token is not a reason, it is an egress.
      assert Hooks.bounded_reason(@vt_token) == "unbounded"
      assert Hooks.bounded_reason("blocked: " <> @vt_token) == "unbounded"

      # Rich terms degrade — never an inspect/1.
      assert Hooks.bounded_reason(%{secret: @email_canary}) == "unbounded"
      assert Hooks.bounded_reason({:tuple, @email_canary}) == "unbounded"
      assert Hooks.bounded_reason(nil) == "unbounded"
      refute Hooks.bounded_reason(%{secret: @email_canary}) =~ @email_canary
    end
  end
end
