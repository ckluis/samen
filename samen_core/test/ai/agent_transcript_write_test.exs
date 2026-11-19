defmodule F3TestAgents do
  @moduledoc false

  defmodule Plain do
    @moduledoc false
    use Samen.AI.Agent,
      name: "f3.plain",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end

  defmodule Writer do
    @moduledoc false
    use Samen.AI.Agent,
      name: "f3.writer",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done.",
      tools: ["assign_record_owner"]
  end
end

defmodule F3FlakyKms do
  @moduledoc """
  A `Samen.Kms` adapter that delegates to the real one, COUNTS every REVEAL's `unwrap/1` per subject, and can fail ONE planned
  unwrap of one subject with `{:error, :unavailable}` (a transient KMS outage). The count is what proves how many times
  an operation read the vault; the plan is what makes a read fail at an exact point.
  """
  @behaviour Samen.Kms

  @plan {__MODULE__, :plan}
  @real {__MODULE__, :real}
  @table :f3_flaky_kms_counts

  def install! do
    :persistent_term.put(@real, Application.get_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked))
    :ets.new(@table, [:public, :named_table, :set])
    Application.put_env(:samen_core, :kms_adapter, __MODULE__)
    :ok
  end

  @doc """
  Fail the `k`th unwrap of `subject` counted from NOW (1 = the very next one), exactly once, with `reason`: the KMS
  adapters' own answers are `:unavailable` (an outage) and `:absent` (`Samen.Kms.InMemory`/`FileBacked`: no key).
  """
  def fail_next!(subject, k, reason \\ :unavailable) when k >= 1,
    do: :persistent_term.put(@plan, {subject, unwraps(subject) + k, reason})

  @doc "Whether a planned failure is still waiting (it was never reached)."
  def armed?, do: :persistent_term.get(@plan, nil) != nil

  def disarm!, do: :persistent_term.erase(@plan)

  def unwraps(subject) do
    case :ets.lookup(@table, subject) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  def uninstall! do
    case :persistent_term.get(@real, nil) do
      nil -> :ok
      real -> Application.put_env(:samen_core, :kms_adapter, real)
    end

    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :persistent_term.erase(@real)
    :persistent_term.erase(@plan)
    :ok
  end

  defp real, do: :persistent_term.get(@real)

  # Only REVEALS are counted and failed: `Samen.Vault.store_field(s)` also unwraps the subject's key (to encrypt), and
  # a write that fails is a different failure from the read this suite is about. The caller is told apart by its stack.
  @impl true
  def unwrap(subject) do
    if store?() do
      real().unwrap(subject)
    else
      n = :ets.update_counter(@table, subject, 1, {subject, 0})

      case :persistent_term.get(@plan, nil) do
        {^subject, ^n, reason} ->
          :persistent_term.erase(@plan)
          fire(reason, subject)

        _ ->
          real().unwrap(subject)
      end
    end
  end

  # An atom is the adapter's own failure answer; a function performs a REAL event (a shred) at that exact reveal, and
  # the reveal then answers whatever the real adapter says.
  defp fire(fun, subject) when is_function(fun, 0) do
    fun.()
    real().unwrap(subject)
  end

  defp fire(reason, _subject), do: {:error, reason}

  defp store? do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
    Enum.any?(stack, fn {mod, fun, _arity, _loc} -> mod == Samen.Vault and fun in [:store_field, :store_fields] end)
  end

  @impl true
  def generate_subject_key(s), do: real().generate_subject_key(s)
  @impl true
  def shred(s), do: real().shred(s)
  @impl true
  def attest(s), do: real().attest(s)
  @impl true
  def backups_disabled?, do: real().backups_disabled?()
  @impl true
  def key_material_present?(s), do: real().key_material_present?(s)
  @impl true
  def pseudonym(a, b), do: real().pseudonym(a, b)
  @impl true
  def list_active_subjects, do: real().list_active_subjects()
end

defmodule Samen.AI.AgentTranscriptWriteTest do
  @moduledoc """
  Honest reads, kernel phase F (J-i). A transcript WRITE carries the prior blob's `ui_view`, fold ledger and turn
  boundaries forward. It used to reveal the vault a SECOND time to get them, between the turn's first reveal and the
  write: a failed second reveal either degraded to "no prior views" (overwriting the only copy), or, once it raised,
  fired after a proposal was opened, after a provider call was made, or after an approved write tool had run.

  Now every operation reveals ONCE, as its first step, before any provider call, proposal, tool execution or approval
  decision, and the write uses the views that reveal returned. Each test counts the real `unwrap/1` calls of the run's
  subject and injects a REAL KMS failure at an exact point; every RED pairs with a positive control through the same
  seam.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  import ExUnit.CaptureLog

  alias F3TestAgents.{Plain, Writer}
  alias Samen.AI.Agent
  alias Samen.AI.Agent.{Run, Turn}
  alias Samen.AI.Provider.Scripted
  alias Samen.Approvals
  alias SamenCore.Support.AgentMembershipFixture, as: Membership
  alias SamenCore.Support.AutomationFixture.Target
  alias SamenCore.TestRepo

  require Ash.Query

  @goal_marker "Goal-Marker-8842"
  @ecto_query_event [:samen_core, :test_repo, :query]

  setup do
    Samen.TestSandbox.shared!(TestRepo)
    Scripted.reset()
    Samen.AI.Agent.Breaker.reset()
    Membership.reset()
    prior = Membership.install!()
    F3FlakyKms.install!()

    # Counts the governed write tool's UPDATEs: a statement counts even when its transaction is rolled back, which is
    # exactly what "the tool was executed" means.
    updates = :atomics.new(1, [])
    handler = "f3-updates-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      @ecto_query_event,
      fn _event, _measurements, %{query: query}, ref ->
        if is_binary(query) and String.contains?(query, ~s(UPDATE "sat_target")), do: :atomics.add(ref, 1, 1)
      end,
      updates
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      F3FlakyKms.uninstall!()
      Scripted.reset()
      Samen.AI.Agent.Breaker.reset()
      Membership.reset()
      Membership.restore!(prior)
      :persistent_term.erase({__MODULE__, :snapshot})
    end)

    {:ok, updates: updates}
  end

  defp new_scope do
    org_id = Ash.UUID.generate()
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp runs_of(scope) do
    org = scope.actor.org_id

    Run
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.Query.ensure_selected([:org_id, :transcript])
    |> Ash.read!(authorize?: false)
  end

  defp turns_of(run),
    do: Turn |> Ash.Query.filter(run_id == ^run.id) |> Ash.Query.sort(turn_index: :asc) |> Ash.read!(authorize?: false)

  defp reveal(run), do: Samen.Vault.reveal(run.transcript, TestRepo, subject_id: run.id)

  defp decoded!(run) do
    {:ok, json} = reveal(run)
    Jason.decode!(json)
  end

  defp corrupt!(token, ciphertext),
    do: Ecto.Adapters.SQL.query!(TestRepo, "UPDATE pii_vault SET ciphertext = $1 WHERE token = $2", [ciphertext, token])

  defp ciphertext_of(token) do
    %{rows: [[ct]]} = Ecto.Adapters.SQL.query!(TestRepo, "SELECT ciphertext FROM pii_vault WHERE token = $1", [token])
    ct
  end

  defp pending_approvals(scope) do
    {:ok, pending} = Approvals.list_pending(scope.actor.org_id, Agent.WriteProposal.kind())
    pending
  end

  # The only run of `scope`, as the script function sees it mid-run.
  defp current_run(scope), do: scope |> runs_of() |> hd()

  describe "the turn loop: the transcript is revealed once per turn and the write reuses it" do
    # Scripted provider entries drive a run that folds on every turn (a tiny watermark): the summarize calls sit between
    # the turn calls. `three` is turn three's own call, which `mid_turn` replaces.
    defp folding_script(three) do
      script([
        {:continue, "one one one one one one one one one one"},
        {:continue, "two two two two two two two two two two"},
        {:continue, "Summary: s1."},
        three,
        {:continue, "Summary: s2."},
        {:continue, "four"},
        {:continue, "Summary: s3."},
        {:final, "done"}
      ])
    end

    defp folded_run!(three) do
      scope = new_scope()
      folding_script(three)
      result = run_scripted(Plain, scope, "goal #{@goal_marker}", budgets: [context_cutoff_tokens: 1])
      {scope, result}
    end

    # What a healthy run's stored transcript holds after folds: the append-only ui_view, the finalized fold ledger and
    # boundaries that reconcile with the model's view. A write that dropped the carried views fails every line of it.
    defp assert_views_carried!(blob) do
      assert [_ | _] = folds = blob["folds"]
      assert Enum.all?(folds, &(&1["status"] in ["done", "proposed"]))
      assert Enum.any?(folds, &(&1["status"] == "done")), "a committed turn finalizes its fold"
      assert length(blob["ui_view"]) > length(blob["llm_view"]), "ui_view keeps what a fold removed from the model's view"
      assert Enum.any?(blob["ui_view"], &String.contains?(&1, "were folded out of the model's working set"))
      assert Enum.sum(blob["turn_lens"]) == length(blob["llm_view"])
      assert length(blob["turn_shapes"]) == length(blob["turn_lens"])
    end

    test "control: a healthy folding run keeps ui_view, folds and boundaries and reveals once per turn" do
      {scope, result} = folded_run!({:continue, "three"})
      assert {:ok, %{turns: turns}} = result
      assert turns >= 4

      [run] = runs_of(scope)
      assert F3FlakyKms.unwraps(run.id) == length(turns_of(run)), "a turn reveals the transcript once, at its start"

      assert_views_carried!(decoded!(run))
    end

    test "RED: an unreadable transcript mid-turn changes nothing: the turn commits from the views it revealed" do
      {control_scope, {:ok, _}} = folded_run!({:continue, "three"})
      [control] = runs_of(control_scope)
      control_blob = decoded!(control)

      scope = new_scope()

      damage = fn ->
        run = current_run(scope)
        token = run.transcript.token
        :persistent_term.put({__MODULE__, :snapshot}, {run.id, token, ciphertext_of(token)})
        corrupt!(token, <<0, 1, 2, 3>>)
        {:continue, "three"}
      end

      folding_script(damage)
      assert {:ok, _} = run_scripted(Plain, scope, "goal #{@goal_marker}", budgets: [context_cutoff_tokens: 1])

      # the injected damage is real: the pre-turn blob really was unreadable while turn three was in flight
      assert {run_id, token, original_ciphertext} = :persistent_term.get({__MODULE__, :snapshot})
      [run] = runs_of(scope)
      assert run.id == run_id
      assert run.state == :succeeded
      assert Enum.all?(turns_of(run), &(&1.status == :done))

      # ... and it did not matter: the stored transcript is byte-for-byte what the undamaged control run stored
      assert decoded!(run) == control_blob
      assert_views_carried!(decoded!(run))
      assert is_binary(original_ciphertext) and original_ciphertext != <<0, 1, 2, 3>>
      assert token != run.transcript.token or ciphertext_of(token) != <<0, 1, 2, 3>>
    end

    test "RED: a vault failure during a proposing turn leaves no pending approval on a failed run, and the turn is billed" do
      scope = new_scope()

      target =
        Target
        |> Ash.Changeset.for_create(:create, %{org_id: scope.actor.org_id, title: "f3 target", priority: :high, email: "f3-park@leak.example"})
        |> Ash.create!(authorize?: false)

      propose = fn ->
        run = current_run(scope)
        :persistent_term.put({__MODULE__, :snapshot}, {run.id, run.transcript.token, nil})
        corrupt!(run.transcript.token, <<9, 9, 9>>)

        {:tool_call, "assign_record_owner",
         %{"resource" => "SamenCore.Support.AutomationFixture.Target", "id" => target.id, "user_id" => Ash.UUID.generate()},
         %{input_tokens: 40, output_tokens: 10}}
      end

      script([{:continue, "looking into it"}, propose, {:final, "assigned"}])

      assert {:awaiting_approval, parked} = run_scripted(Writer, scope, "who should own it?")
      assert {_run_id, damaged_token, nil} = :persistent_term.get({__MODULE__, :snapshot})
      assert damaged_token != nil

      [run] = runs_of(scope)
      assert run.id == parked.id
      assert run.state == :awaiting_approval
      assert run.input_tokens_used >= 40, "the provider turn happened, so its tokens are billed"

      # the invariant the old failure broke: a pending approval exists only for a run parked on it
      assert [approval] = pending_approvals(scope)
      assert run.state == :awaiting_approval
      assert %{"pending" => %{"approval_id" => approval_id}} = decoded!(run)
      assert approval_id == to_string(approval.id)

      assert [%{status: :done}, %{status: :proposed}] = turns_of(run)
    end

    test "RED: a reveal failing at the top of a proposing turn calls no provider and opens no approval" do
      scope = new_scope()

      target =
        Target
        |> Ash.Changeset.for_create(:create, %{org_id: scope.actor.org_id, title: "f3 target", priority: :high, email: "f3-top@leak.example"})
        |> Ash.create!(authorize?: false)

      # turn one is ordinary; during its provider call the next read of the run's transcript is planned to fail. Turn
      # one commits from the views it already holds, so that read is turn two's reveal, at the top of turn two.
      blip = fn ->
        F3FlakyKms.fail_next!(current_run(scope).id, 1)
        {:continue, "turn one", %{input_tokens: 5, output_tokens: 5}}
      end

      propose =
        {:tool_call, "assign_record_owner",
         %{"resource" => "SamenCore.Support.AutomationFixture.Target", "id" => target.id, "user_id" => Ash.UUID.generate()},
         %{input_tokens: 40, output_tokens: 10}}

      script([blip, propose, {:final, "assigned"}])

      {result, log} = with_log(fn -> run_scripted(Writer, scope, "who owns it?") end)
      assert {:error, :transcript_unavailable, failed} = result
      assert log =~ "read failed read=agent_transcript_reveal"

      [run] = runs_of(scope)
      assert run.state == :failed and run.error_kind == "transcript_unavailable"
      assert run.current_turn == 1, "turn one committed; turn two was refused before it began"
      assert failed.id == run.id

      assert [_propose, _final] = Scripted.remaining(), "the provider was called exactly once: turn two never reached it"
      assert pending_approvals(scope) == []
      assert [%{status: :done}] = turns_of(run), "turn two left no row"
      assert run.input_tokens_used == 5 and run.output_tokens_used == 5, "only the completed provider call is billed"
    end
  end

  describe "the approval decision: the transcript is revealed first, before the write tool runs" do
    defp approver_id(org_id) do
      id = "human:" <> Ash.UUID.generate()
      Membership.register(id, org_id, :member)
      id
    end

    defp propose! do
      s = new_scope()

      target =
        Target
        |> Ash.Changeset.for_create(:create, %{org_id: s.actor.org_id, title: "f3 target", priority: :high, email: "f3-write@leak.example"})
        |> Ash.create!(authorize?: false)

      script([
        {:tool_call, "assign_record_owner",
         %{"resource" => "SamenCore.Support.AutomationFixture.Target", "id" => target.id, "user_id" => Ash.UUID.generate()}},
        {:final, "assigned"}
      ])

      assert {:awaiting_approval, run} = run_scripted(Writer, s, "who should own it?")
      {:ok, [approval]} = Approvals.list_pending(s.actor.org_id, Agent.WriteProposal.kind())
      {s, run, target, approval}
    end

    defp owner_of(target) do
      Target
      |> Ash.Query.filter(id == ^target.id)
      |> Ash.Query.ensure_selected([:owner_id])
      |> Ash.read!(authorize?: false)
      |> hd()
      |> Map.fetch!(:owner_id)
    end

    defp parked_transcript(run) do
      id = run.id

      [row] =
        Run
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.ensure_selected([:org_id, :transcript])
        |> Ash.read!(authorize?: false)

      {:ok, json} = reveal(row)
      {row.state, json}
    end

    defp updates(ref), do: :atomics.get(ref, 1)

    test "RED: an unreadable transcript runs the tool ZERO times, keeps the approval pending, and a re-approve after healing runs it ONCE", %{updates: updates} do
      # POSITIVE CONTROL: a healthy approve of an identical proposal. It fixes how many UPDATEs one execution issues,
      # and proves the counter sees them.
      {s0, run0, target0, approval0} = propose!()
      before0 = updates(updates)
      assert {:ok, %{state: :approved}, %{executed: "assign_record_owner"}} = Approvals.approve(approval0.id, approver_id(s0.actor.org_id))
      per_execution = updates(updates) - before0
      assert per_execution >= 1, "the UPDATE counter must see the write tool"
      assert owner_of(target0) != nil
      assert run0.id != nil

      {s, run, target, approval} = propose!()
      {state_before, json_before} = parked_transcript(run)
      assert state_before == :awaiting_approval

      F3FlakyKms.fail_next!(run.id, 1)
      before = updates(updates)
      log = capture_log(fn -> assert {:error, _} = Approvals.approve(approval.id, approver_id(s.actor.org_id)) end)

      assert log =~ "read failed read=agent_transcript_reveal"
      assert updates(updates) == before, "the write tool was executed although the run's transcript could not be read"
      assert {:ok, %{state: :pending}} = Approvals.get(approval.id)
      assert owner_of(target) == nil
      assert {^state_before, ^json_before} = parked_transcript(run)

      # the outage was a single blip: the vault healed, the same approval is decidable and executes exactly once
      assert {:ok, %{state: :approved}, %{executed: "assign_record_owner"}} = Approvals.approve(approval.id, approver_id(s.actor.org_id))
      assert updates(updates) - before == per_execution, "the re-approve must execute the tool exactly once"
      assert owner_of(target) != nil
    end

    test "RED: an approve reads the vault once, so a failure planned at a second read is never reached", %{updates: updates} do
      {s, run, target, approval} = propose!()

      F3FlakyKms.fail_next!(run.id, 2)
      reads = F3FlakyKms.unwraps(run.id)
      before = updates(updates)

      assert {:ok, %{state: :approved}, %{executed: "assign_record_owner"}} = Approvals.approve(approval.id, approver_id(s.actor.org_id))

      assert F3FlakyKms.unwraps(run.id) - reads == 1, "the write must not reveal the vault a second time"
      assert F3FlakyKms.armed?(), "the failure planned at the second read was never reached"
      F3FlakyKms.disarm!()
      assert updates(updates) - before >= 1
      assert owner_of(target) != nil

      blob = decoded!(hd(runs_of(s)))
      assert blob["ui_view"] == blob["llm_view"] and Enum.sum(blob["turn_lens"]) == length(blob["llm_view"])
      assert Enum.any?(blob["llm_view"], &String.starts_with?(&1, "tool_approved: assign_record_owner"))
    end
  end

  describe "reject and expiry: one reveal, no write-time read" do
    test "RED: a reject reads the vault once and appends its line to the views it read" do
      {s, run, _target, approval} = propose!()
      before_blob = decoded!(hd(runs_of(s)))

      F3FlakyKms.fail_next!(run.id, 2)
      reads = F3FlakyKms.unwraps(run.id)
      assert {:ok, %{state: :rejected}} = Approvals.reject(approval.id, approver_id(s.actor.org_id))
      assert F3FlakyKms.unwraps(run.id) - reads == 1
      assert F3FlakyKms.armed?(), "the failure planned at the second read was never reached"
      F3FlakyKms.disarm!()

      assert {:rejected, json} = parked_transcript(run)
      blob = Jason.decode!(json)
      assert blob["ui_view"] == before_blob["ui_view"] ++ ["tool_rejected: assign_record_owner"]
      assert blob["llm_view"] == before_blob["llm_view"] ++ ["tool_rejected: assign_record_owner"]
    end

    test "control: a reject with an unreadable transcript still rejects and leaves it untouched" do
      {s, run, _target, approval} = propose!()
      {_, json_before} = parked_transcript(run)
      token = hd(runs_of(s)).transcript.token

      F3FlakyKms.fail_next!(run.id, 1)
      log = capture_log(fn -> assert {:ok, %{state: :rejected}} = Approvals.reject(approval.id, approver_id(s.actor.org_id)) end)
      assert log =~ "read failed read=agent_transcript_reveal"

      # no line was written (the unreadable blob was neither re-read nor overwritten): same token, same plaintext
      assert hd(runs_of(s)).transcript.token == token
      assert {:rejected, ^json_before} = parked_transcript(run)
    end

    test "RED: an expiry reads the vault twice, never a third time, and its line joins the views read" do
      {s, run, target, approval} = propose!()
      before_blob = decoded!(hd(runs_of(s)))

      # the third read of this expiry (the one the old second reveal made) is planned to fail: it must never happen
      F3FlakyKms.fail_next!(run.id, 3)
      reads = F3FlakyKms.unwraps(run.id)
      assert {:ok, %{state: :expired}} = Agent.expire_parked(run.id)
      assert F3FlakyKms.unwraps(run.id) - reads == 2, "one read to find the pending approval, one for the write"
      assert F3FlakyKms.armed?(), "the failure planned at a third read was never reached"
      F3FlakyKms.disarm!()

      assert pending_approvals(s) == []
      assert owner_of(target) == nil
      assert {:ok, %{state: :cancelled}} = Approvals.get(approval.id)

      assert {:expired, json} = parked_transcript(run)
      blob = Jason.decode!(json)
      assert blob["ui_view"] == before_blob["ui_view"] ++ ["tool_expired: assign_record_owner"]
      refute Map.has_key?(blob, "pending"), "an expired proposal is never re-bindable"
    end
  end

  describe "a key that is gone is not an outage" do
    test "control: a run SHREDDED between turns ends :transcript_unavailable, quiet" do
      scope = new_scope()

      # the real shred happens at turn two's own reveal, so it is the reveal's reason (:shredded) that ends the run
      shred = fn ->
        run = current_run(scope)
        :persistent_term.put({__MODULE__, :snapshot}, run.id)

        F3FlakyKms.fail_next!(run.id, 1, fn ->
          assert {:ok, _} = Samen.Erasure.shred(run.id, repo: TestRepo, org_id: scope.actor.org_id)
        end)

        {:continue, "turn one"}
      end

      script([shred, {:continue, "turn two"}, {:final, "done"}])

      {result, log} = with_log(fn -> run_scripted(Plain, scope, "goal #{@goal_marker}") end)
      assert {:error, :transcript_unavailable, failed} = result

      # the shred really happened (without this the quiet path below would be vacuous), and was the reveal's reason
      [run] = runs_of(scope)
      assert run.id == :persistent_term.get({__MODULE__, :snapshot}) and failed.id == run.id
      assert {:error, :shredded} = reveal(run)
      assert run.state == :failed and run.current_turn == 1
      assert [_turn_two, _final] = Scripted.remaining(), "no provider call was made for the refused turn"
      refute log =~ "agent_transcript_reveal"
    end

    test "a key the KMS reports :absent is gone too: :transcript_unavailable, quiet" do
      scope = new_scope()

      # the adapters answer {:error, :absent} for a subject with no wrapped key (in_memory.ex / file_backed.ex)
      vanish = fn ->
        F3FlakyKms.fail_next!(current_run(scope).id, 1, :absent)
        {:continue, "turn two"}
      end

      script([vanish, {:final, "done"}])
      {result, log} = with_log(fn -> run_scripted(Plain, scope, "goal #{@goal_marker}") end)

      assert {:error, :transcript_unavailable, run} = result
      assert run.state == :failed and run.error_kind == "transcript_unavailable"
      refute log =~ "agent_transcript_reveal"
    end

    test "control: a KMS outage (:unavailable) is NOT gone: it is reported by name" do
      scope = new_scope()
      blip = fn -> (F3FlakyKms.fail_next!(current_run(scope).id, 1); {:continue, "turn one"}) end
      script([blip, {:final, "done"}])

      log = capture_log(fn -> assert {:error, :transcript_unavailable, _} = run_scripted(Plain, scope, "goal #{@goal_marker}") end)
      assert log =~ "read failed read=agent_transcript_reveal"
      assert log =~ "unavailable"
    end
  end
end
