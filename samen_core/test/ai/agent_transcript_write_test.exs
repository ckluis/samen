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

defmodule F3Halter do
  @moduledoc false
  @behaviour Samen.AI.Agent.Hook

  @impl true
  def call(:before_completion, _ctx), do: {:halt, :operator_stop}
  def call(_point, _ctx), do: :ok
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
  @store_plan {__MODULE__, :store_plan}
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

  @doc """
  Fail the `k`th STORE-side unwrap (`Samen.Vault.store_field(s)`, reached by every `transcript:` write) of `subject`
  counted from NOW, exactly once, with `reason`. Stores and reveals are counted and planned apart.
  """
  def fail_store!(subject, k, reason \\ :unavailable) when k >= 1,
    do: :persistent_term.put(@store_plan, {subject, stores(subject) + k, reason})

  @doc "Whether a planned failure (reveal or store) is still waiting (it was never reached)."
  def armed?, do: :persistent_term.get(@plan, nil) != nil or :persistent_term.get(@store_plan, nil) != nil

  def disarm!, do: [@plan, @store_plan] |> Enum.each(&:persistent_term.erase/1)

  @doc "How many STORE-side unwraps of `subject` have been seen."
  def stores(subject), do: count({:store, subject})

  def unwraps(subject), do: count(subject)

  defp count(key) do
    case :ets.lookup(@table, key) do
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
    :persistent_term.erase(@store_plan)
    :ok
  end

  defp real, do: :persistent_term.get(@real)

  # REVEALS and STORES are counted and planned separately: `Samen.Vault.store_field(s)` also unwraps the subject's key
  # (to encrypt). The caller is told apart by its stack (the adapter is handed only the subject); the stores are counted
  # so that a refactor which hides the store frame shows up as a store count of zero where a test expects some.
  @impl true
  def unwrap(subject) do
    if store?() do
      n = :ets.update_counter(@table, {:store, subject}, 1, {{:store, subject}, 0})

      case :persistent_term.get(@store_plan, nil) do
        {^subject, ^n, reason} ->
          :persistent_term.erase(@store_plan)
          {:error, reason}

        _ ->
          real().unwrap(subject)
      end
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
    Membership.register("u:#{org_id}", org_id, :member)
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

    defp drain_sql(acc) do
      receive do
        {:sql, q} -> drain_sql([q | acc])
      after
        0 -> Enum.reverse(acc)
      end
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

    test "RED: an expiry reads the vault once, never a second time, and its line joins the views read" do
      {s, run, target, approval} = propose!()
      before_blob = decoded!(hd(runs_of(s)))

      # the second read of this expiry (the one the old second reveal made, after the approval was cancelled) is
      # planned to fail: it must never happen
      F3FlakyKms.fail_next!(run.id, 2)
      reads = F3FlakyKms.unwraps(run.id)
      assert {:ok, %{state: :expired}} = Agent.expire_parked(run.id)
      assert F3FlakyKms.unwraps(run.id) - reads == 1, "one read serves the withdrawal and the write"
      assert F3FlakyKms.armed?(), "the failure planned at a second read was never reached"
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

  describe "a failed transcript STORE never strands a pending approval on a failed run" do
    # Mechanism (read, then proved by the first test): `WriteProposal.open/1` and `stamp_proposal!/4` commit BEFORE
    # `park_run!/6`, each in its own transaction, so a store that fails inside `park_run!` (its `Vault.Change` unwraps the
    # run's KMS key) rolls back only the park. The approval stays `pending`, the turn row `:proposed`, the run `:running`.
    defp assert_no_stranded_proposal!(scope, run, approval) do
      assert pending_approvals(scope) == [], "a failed run left a pending approval"
      assert {:ok, %{state: :cancelled}} = Approvals.get(approval.id)

      # the retry's start cleared the proposal stamps off the reused row (it no longer names a cancelled approval)
      for turn <- turns_of(run) do
        refute Map.has_key?(turn.meta || %{}, "approval_id"), "a turn row still names the cancelled approval"
        refute Map.has_key?(turn.meta || %{}, "awaiting_approval"), "a turn row is still marked awaiting_approval"
      end
    end

    # A proposing turn whose transcript STORE (the park) fails: the exception escapes, the run is left `:running`
    # with the approval and the `:proposed` turn row already committed.
    defp strand!(scope) do
      target =
        Target
        |> Ash.Changeset.for_create(:create, %{org_id: scope.actor.org_id, title: "f3 target", priority: :high, email: "f3-store@leak.example"})
        |> Ash.create!(authorize?: false)

      propose = fn ->
        F3FlakyKms.fail_store!(current_run(scope).id, 1)

        {:tool_call, "assign_record_owner",
         %{"resource" => "SamenCore.Support.AutomationFixture.Target", "id" => target.id, "user_id" => Ash.UUID.generate()},
         %{input_tokens: 40, output_tokens: 10}}
      end

      script([propose, {:final, "assigned"}])

      assert_raise Ash.Error.Invalid, fn -> run_scripted(Writer, scope, "who should own it?") end
      refute F3FlakyKms.armed?(), "the planned store failure never fired"

      [run] = runs_of(scope)
      assert F3FlakyKms.stores(run.id) > 0
      assert run.state == :running, "the failed park left the run running"
      assert [approval] = pending_approvals(scope)
      assert [%{status: :proposed}] = turns_of(run)
      {run, approval}
    end

    test "control: a healthy proposing turn leaves exactly one pending approval on an :awaiting_approval run" do
      {s, run, _target, approval} = propose!()
      assert run.state == :awaiting_approval
      assert [pending] = pending_approvals(s)
      assert pending.id == approval.id
      assert [%{status: :proposed}] = turns_of(run)
      assert F3FlakyKms.stores(run.id) > 0, "the store counter sees the transcript writes"
    end

    test "RED: a failed park followed by a failed reveal at the retry leaves no pending approval on the failed run" do
      scope = new_scope()
      {run, approval} = strand!(scope)

      F3FlakyKms.fail_next!(run.id, 1)
      reads = F3FlakyKms.unwraps(run.id)
      {result, log} = with_log(fn -> Agent.execute_batch(run) end)

      assert {:error, :transcript_unavailable, failed} = result
      assert F3FlakyKms.unwraps(run.id) - reads == 1
      refute F3FlakyKms.armed?(), "the planned reveal failure never fired"
      assert log =~ "read failed read=agent_transcript_reveal"

      [row] = runs_of(scope)
      assert failed.id == row.id and row.state == :failed and row.error_kind == "transcript_unavailable"
      assert_no_stranded_proposal!(scope, row, approval)
    end

    test "RED: a failed park followed by the kill switch at the retry leaves no pending approval on the failed run" do
      scope = new_scope()
      {run, approval} = strand!(scope)

      Samen.AI.Agent.Breaker.kill(:operator)
      assert {:error, :killed, failed} = Agent.execute_batch(run)

      [row] = runs_of(scope)
      assert failed.id == row.id and row.state == :failed and row.error_kind == "killed"
      assert_no_stranded_proposal!(scope, row, approval)
    end
  end

  describe "a hook halt on a retried, parked-then-failed turn" do
    test "RED: a failed park followed by a hook halt at the retry leaves no pending approval on the failed run" do
      scope = new_scope()
      {run, approval} = strand!(scope)

      prior = Application.get_env(:samen_core, Samen.AI.Agent)
      Application.put_env(:samen_core, Samen.AI.Agent, Keyword.put(prior || [], :hooks, [F3Halter]))

      on_exit(fn ->
        if prior,
          do: Application.put_env(:samen_core, Samen.AI.Agent, prior),
          else: Application.delete_env(:samen_core, Samen.AI.Agent)
      end)

      assert {:error, :hook_halted, failed} = Agent.execute_batch(run)

      [row] = runs_of(scope)
      assert failed.id == row.id and row.state == :failed and row.error_kind == "hook_halted"
      assert_no_stranded_proposal!(scope, row, approval)
      assert [%{status: :failed, error_kind: "hook_halted", meta: %{"hook_reason" => "operator_stop"}}] = turns_of(row)
    end
  end

  describe "a retry after a failed park reclaims the stale approval at its start" do
    # The retried attempt REUSES the `:proposed` row that names the approval. `execute_batch/1` cancels that approval by
    # id and clears the row's proposal stamps BEFORE anything else the attempt does, so every later path (provider
    # error, cancel flag, a text answer, a new proposal) starts from a clean row.
    defp put_agent_env!(kv) do
      previous = Application.get_env(:samen_core, Samen.AI.Agent, [])
      Application.put_env(:samen_core, Samen.AI.Agent, Keyword.merge(previous, kv))
      on_exit(fn -> Application.put_env(:samen_core, Samen.AI.Agent, previous) end)
    end

    defp worker_provider!, do: put_agent_env!(provider: scripted_provider())

    defp target_of(scope),
      do: Target |> Ash.Query.filter(org_id == ^scope.actor.org_id) |> Ash.read!(authorize?: false) |> hd()

    defp propose_call(target),
      do:
        {:tool_call, "assign_record_owner",
         %{"resource" => "SamenCore.Support.AutomationFixture.Target", "id" => target.id, "user_id" => Ash.UUID.generate()},
         %{input_tokens: 40, output_tokens: 10}}

    # run `fun` with the approvals engine pointed at a store whose reads fail, restoring the wiring afterwards
    defp with_unreadable_approvals(fun) do
      previous = Application.get_env(:samen_core, Samen.Approvals)

      Application.put_env(:samen_core, Samen.Approvals,
        approval_resource: SamenCore.Support.UnreadableApproval,
        repo: SamenCore.TestRepo
      )

      try do
        capture_log(fn -> send(self(), {:result, fun.()}) end)
        assert_received {:result, result}
        result
      after
        Application.put_env(:samen_core, Samen.Approvals, previous)
      end
    end

    test "RED: a failed park followed by a PROVIDER ERROR at the retry leaves no pending approval, and the run keeps the provider's kind" do
      worker_provider!()
      scope = new_scope()
      {run, approval} = strand!(scope)

      script([{:error, :provider_error, %{input_tokens: 9, output_tokens: 2}}])
      assert {:error, :provider_error, failed} = Agent.execute_batch(run)
      assert Scripted.remaining() == [], "the planned provider error was never reached"

      [row] = runs_of(scope)
      assert failed.id == row.id and row.state == :failed and row.error_kind == "provider_error"
      assert_no_stranded_proposal!(scope, row, approval)
      assert [%{status: :failed, error_kind: "provider_error"}] = turns_of(row)
    end

    test "RED: a failed park followed by the CANCEL FLAG at the retry leaves no pending approval" do
      worker_provider!()
      scope = new_scope()
      {run, approval} = strand!(scope)

      assert {:ok, %{cancel_requested_at: at}} = Agent.cancel(scope, run.id)
      assert at != nil, "the cancel flag was never set"
      assert {:error, :cancelled, failed} = Agent.execute_batch(run)

      [row] = runs_of(scope)
      assert failed.id == row.id and row.state == :cancelled
      assert_no_stranded_proposal!(scope, row, approval)
    end

    test "RED: a failed park followed by a TEXT answer at the retry completes the run and cancels the old approval" do
      worker_provider!()
      scope = new_scope()
      {run, approval} = strand!(scope)

      script([{:final, "nothing to assign after all"}])
      assert {:ok, %{answer: _}} = Agent.execute_batch(run)
      assert Scripted.remaining() == [], "the retry never called the provider"

      [row] = runs_of(scope)
      assert row.state == :succeeded
      assert_no_stranded_proposal!(scope, row, approval)
      assert [%{status: :done}] = turns_of(row)
    end

    test "RED: a failed park followed by a NEW proposal at the retry leaves exactly one pending approval, and approving it runs the tool once", %{updates: updates} do
      worker_provider!()
      scope = new_scope()
      {run, old} = strand!(scope)
      target = target_of(scope)

      script([propose_call(target), {:final, "assigned"}])
      assert {:awaiting_approval, parked} = Agent.execute_batch(run)
      refute F3FlakyKms.armed?()

      [row] = runs_of(scope)
      assert parked.id == row.id and row.state == :awaiting_approval
      assert {:ok, %{state: :cancelled}} = Approvals.get(old.id)
      assert [fresh] = pending_approvals(scope)
      assert fresh.id != old.id
      assert [%{status: :proposed, meta: %{"approval_id" => id}}] = turns_of(row)
      assert id == to_string(fresh.id)

      before = updates(updates)
      assert {:ok, %{state: :approved}, %{executed: "assign_record_owner"}} = Approvals.approve(fresh.id, approver_id(scope.actor.org_id))
      assert updates(updates) - before >= 1
      assert owner_of(target) != nil
      # the cancelled one stays cancelled: it can never execute
      assert {:error, :not_pending} = Approvals.approve(old.id, approver_id(scope.actor.org_id))
    end

    test "control: an :awaiting_approval run's pending approval is untouched by an unrelated run and by a duplicate job in the same org" do
      worker_provider!()
      {s, parked, _target, approval} = propose!()

      script([{:final, "unrelated"}])
      assert {:ok, %{answer: "unrelated"}} = run_scripted(Plain, s, "something else")

      assert {:done, _} = Agent.execute_batch(parked)
      assert [pending] = pending_approvals(s)
      assert pending.id == approval.id
      assert {:ok, %{state: :pending}} = Approvals.get(approval.id)
      assert Enum.find(runs_of(s), &(&1.id == parked.id)).state == :awaiting_approval
      assert [%{status: :proposed, meta: %{"approval_id" => id}}] = turns_of(parked)
      assert id == to_string(approval.id)
    end

    test "RED: a failed cancellation raises before any provider call, reports by name, and the next attempt heals" do
      worker_provider!()
      scope = new_scope()
      {run, approval} = strand!(scope)
      script([{:final, "answer after the heal"}])

      log =
        capture_log(fn ->
          previous = Application.get_env(:samen_core, Samen.Approvals)

          Application.put_env(:samen_core, Samen.Approvals,
            approval_resource: SamenCore.Support.UnreadableApproval,
            repo: SamenCore.TestRepo
          )

          try do
            assert_raise RuntimeError, ~r/approval could not be cancelled/, fn -> Agent.execute_batch(run) end
          after
            Application.put_env(:samen_core, Samen.Approvals, previous)
          end
        end)

      assert log =~ "write failed write=agent_reclaim_failed_park"
      assert Scripted.remaining() != [], "a provider call happened before the cancellation"
      assert {:ok, %{state: :pending}} = Approvals.get(approval.id)
      assert [%{status: :proposed, meta: %{"approval_id" => _}}] = turns_of(run)

      # the retry (Oban's next attempt) finds the engine healthy and completes
      assert {:ok, %{answer: _}} = Agent.execute_batch(run)
      [row] = runs_of(scope)
      assert row.state == :succeeded
      assert_no_stranded_proposal!(scope, row, approval)
    end
  end

  describe "the reclaim's failure message is a bounded kind, never the engine's reason" do
    # Oban stores the exception message in `oban_jobs.errors`. The reason of a failed cancel is an Ash error whose
    # database message can carry row data (a trigger/CHECK detail), so the raise names a kind only.
    @leak "LEAKMARK-7c1e9f"

    defp install_cancel_trigger! do
      Ecto.Adapters.SQL.query!(SamenCore.TestRepo, """
      CREATE FUNCTION f3_leak_cancel() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION '#{@leak} row detail';
        RETURN NEW;
      END $$
      """)

      Ecto.Adapters.SQL.query!(
        SamenCore.TestRepo,
        "CREATE TRIGGER f3_leak_cancel BEFORE UPDATE ON apv_approval FOR EACH ROW EXECUTE FUNCTION f3_leak_cancel()"
      )
    end

    test "RED: a cancel that fails with row data in its database error raises a message without it" do
      worker_provider!()
      scope = new_scope()
      {run, approval} = strand!(scope)
      script([{:final, "never reached"}])
      install_cancel_trigger!()

      # positive control: the injected error really carries the marker
      assert {:error, direct} = Approvals.cancel(approval.id, Samen.AI.Agent.WriteProposal.requester_principal_id())
      assert inspect(direct) =~ @leak

      {error, _log} =
        with_log(fn ->
          assert_raise RuntimeError, ~r/approval could not be cancelled/, fn -> Agent.execute_batch(run) end
        end)

      refute error.message =~ @leak
      assert error.message =~ "Ash.Changeset"
    end
  end

  describe "cancelling a parked run withdraws its approval or does not cancel" do
    test "control: a healthy cancel withdraws the approval and terminates the run" do
      {s, run, _target, approval} = propose!()

      assert {:ok, %{state: :cancelled}} = Agent.cancel(s, run.id)
      assert {:ok, %{state: :cancelled}} = Approvals.get(approval.id)
      assert pending_approvals(s) == []
    end

    test "RED: a withdrawal that FAILS rolls the cancel back and answers :unavailable" do
      {s, run, _target, approval} = propose!()
      install_cancel_trigger!()

      {result, log} = with_log(fn -> Agent.cancel(s, run.id) end)

      assert {:error, :unavailable} = result
      assert log =~ "write failed write=agent_cancel_parked"
      assert Enum.find(runs_of(s), &(&1.id == run.id)).state == :awaiting_approval
      assert Enum.find(runs_of(s), &(&1.id == run.id)).cancel_requested_at == nil
      assert {:ok, %{state: :pending}} = Approvals.get(approval.id)
      assert [_] = pending_approvals(s)
    end

    test "RED: a FAILING run update inside the cancel rolls the withdrawal back and answers :unavailable, never raises" do
      {s, run, _target, approval} = propose!()

      Ecto.Adapters.SQL.query!(SamenCore.TestRepo, """
      CREATE FUNCTION cp_fail_run_cancel() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.cancel_requested_at IS NOT NULL THEN RAISE EXCEPTION 'cp run update refused'; END IF;
        RETURN NEW;
      END $$
      """)

      Ecto.Adapters.SQL.query!(
        SamenCore.TestRepo,
        "CREATE TRIGGER cp_fail_run_cancel BEFORE UPDATE ON ai_agent_run FOR EACH ROW EXECUTE FUNCTION cp_fail_run_cancel()"
      )

      {result, log} = with_log(fn -> Agent.cancel(s, run.id) end)

      assert {:error, :unavailable} = result
      assert log =~ "write failed write=agent_cancel_parked"
      assert Enum.find(runs_of(s), &(&1.id == run.id)).state == :awaiting_approval
      # the approval withdrawal ran BEFORE the failed update, in the same transaction: it is rolled back with it
      assert {:ok, %{state: :pending}} = Approvals.get(approval.id)
    end

    test "the cancel takes the RUN row lock before it touches the approval (the expiry sweep's order: no deadlock)" do
      {s, run, _target, _approval} = propose!()
      parent = self()
      handler = "cp-lock-order-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:samen_core, :test_repo, :query],
        fn _e, _m, %{query: q}, _ -> send(parent, {:sql, q}) end,
        nil
      )

      try do
        assert {:ok, %{state: :cancelled}} = Agent.cancel(s, run.id)
      after
        :telemetry.detach(handler)
      end

      queries = drain_sql([])
      run_lock = Enum.find_index(queries, &(&1 =~ ~s(FROM "ai_agent_run") and &1 =~ "FOR UPDATE"))
      first_approval = Enum.find_index(queries, &(&1 =~ "_approval" and &1 =~ ~r/UPDATE|FOR UPDATE/))

      assert is_integer(run_lock), "no FOR UPDATE on the run row was issued: #{inspect(queries)}"
      assert is_integer(first_approval), "no approval write was issued"
      assert run_lock < first_approval
    end

    test "control: an approval that is already decided is nothing to withdraw, the cancel still lands" do
      {s, run, _target, approval} = propose!()
      assert {:ok, %{state: :cancelled}} = Approvals.cancel(approval.id, Agent.WriteProposal.requester_principal_id())

      assert {:ok, %{state: :cancelled}} = Agent.cancel(s, run.id)
    end
  end

  describe "a halt never depends on the approvals engine (fail-closed, not fail-open)" do
    # Review 4: the end-of-run withdrawal made a halt scan the org's approvals; an unreadable approvals store then made
    # the halt RAISE and be lost. A halt or a kill on a turn with no prior proposal must land regardless.
    test "RED: a hook halt on a FRESH turn lands although the approvals store is unreadable" do
      scope = new_scope()
      put_agent_env!(hooks: [F3Halter])
      script([{:final, "never reached"}])

      assert {:error, :hook_halted, failed} = with_unreadable_approvals(fn -> run_scripted(Plain, scope, "goal") end)
      assert failed.state == :failed and failed.error_kind == "hook_halted"
      assert [%{status: :failed, error_kind: "hook_halted"}] = turns_of(failed)
    end

    test "RED: the kill switch lands on a run with an in-flight turn row although the approvals store is unreadable" do
      worker_provider!()
      scope = new_scope()
      assert {:ok, started} = Agent.start(Plain, scope, "goal", provider: scripted_provider())
      assert {:ok, run} = Agent.fetch_run(started.id)

      # a worker that died after creating its turn row, before the provider answered: the row is `:proposed`, with no approval
      Turn
      |> Ash.Changeset.for_create(:record, %{org_id: scope.actor.org_id, run_id: run.id, turn_index: 1, status: :proposed})
      |> Ash.create!(authorize?: false)

      Samen.AI.Agent.Breaker.kill(:operator)
      assert {:error, :killed, failed} = with_unreadable_approvals(fn -> Agent.execute_batch(run) end)
      assert failed.state == :failed and failed.error_kind == "killed"
    end
  end

  describe "the public reader transcript_views/1" do
    defp finished_run! do
      scope = new_scope()
      script([{:final, "done"}])
      assert {:ok, _} = run_scripted(Plain, scope, "goal #{@goal_marker}")
      hd(runs_of(scope))
    end

    test "control: a readable transcript answers its views and reports nothing" do
      run = finished_run!()
      log = capture_log(fn -> assert {:ok, %{goal: _, ui_view: [_ | _], llm_view: [_ | _]}} = Agent.transcript_views(run) end)
      refute log =~ "agent_transcript_views"
    end

    test "RED: a failed reveal is reported by name, and the reader still answers :transcript_unavailable" do
      run = finished_run!()

      F3FlakyKms.fail_next!(run.id, 1)
      log = capture_log(fn -> assert {:error, :transcript_unavailable} = Agent.transcript_views(run) end)
      refute F3FlakyKms.armed?(), "the planned reveal failure never fired"

      assert log =~ "read failed read=agent_transcript_views"
      assert log =~ "unavailable"
      refute log =~ @goal_marker
    end

    test "a SHREDDED run is still quiet: the sanctioned end of an erased run is not a failure" do
      run = finished_run!()

      F3FlakyKms.fail_next!(run.id, 1, :shredded)
      log = capture_log(fn -> assert {:error, :transcript_unavailable} = Agent.transcript_views(run) end)
      refute log =~ "agent_transcript_views"
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

    test "a key the KMS reports :absent is NOT gone: the run fails cleanly and the disaster is reported by name" do
      scope = new_scope()

      # the adapters answer {:error, :absent} for a subject with no wrapped key (in_memory.ex / file_backed.ex): a wrong
      # or wiped key directory, or an in-memory store after a restart. A sanctioned shred answers :shredded instead.
      vanish = fn ->
        F3FlakyKms.fail_next!(current_run(scope).id, 1, :absent)
        {:continue, "turn two"}
      end

      script([vanish, {:final, "done"}])
      {result, log} = with_log(fn -> run_scripted(Plain, scope, "goal #{@goal_marker}") end)

      # the same clean failure as an outage ...
      assert {:error, :transcript_unavailable, run} = result
      assert run.state == :failed and run.error_kind == "transcript_unavailable"
      refute F3FlakyKms.armed?(), "the planned :absent never fired"
      assert [_final] = Scripted.remaining(), "no provider call was made for the refused turn"

      # ... but not a quiet one
      assert log =~ "read failed read=agent_transcript_reveal"
      assert log =~ "absent"
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
