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
  A `Samen.Kms` adapter that delegates to the real one and fails the Nth `unwrap/1` of ONE subject with
  `{:error, :unavailable}` (a transient KMS outage), recording how many unwraps that subject saw.
  """
  @behaviour Samen.Kms

  @plan {__MODULE__, :plan}
  @real {__MODULE__, :real}

  def install!(subject, nth) do
    ref = :atomics.new(1, [])
    :persistent_term.put(@real, Application.get_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked))
    :persistent_term.put(@plan, {subject, nth, ref})
    Application.put_env(:samen_core, :kms_adapter, __MODULE__)
    ref
  end

  def uninstall! do
    case :persistent_term.get(@real, nil) do
      nil -> :ok
      real -> Application.put_env(:samen_core, :kms_adapter, real)
    end

    :persistent_term.erase(@real)
    :persistent_term.erase(@plan)
    :ok
  end

  defp real, do: :persistent_term.get(@real)

  @impl true
  def unwrap(subject) do
    case :persistent_term.get(@plan, nil) do
      {^subject, nth, ref} ->
        if :atomics.add_get(ref, 1, 1) == nth, do: {:error, :unavailable}, else: real().unwrap(subject)

      _ ->
        real().unwrap(subject)
    end
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
  boundaries forward, so a vault reveal that FAILED at write time must abort the write: it used to read as "no prior
  views", and the write then replaced `ui_view` with the LLM view, erased the fold ledger and attributed the whole
  history to the current turn, overwriting the only copy. Every RED injects a REAL vault failure and pairs with a
  positive control through the same seam.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  import ExUnit.CaptureLog

  alias F3TestAgents.{Plain, Writer}
  alias Samen.AI.Agent
  alias Samen.AI.Agent.Run
  alias Samen.AI.Provider.Scripted
  alias Samen.Approvals
  alias SamenCore.Support.AgentMembershipFixture, as: Membership
  alias SamenCore.Support.AutomationFixture.Target
  alias SamenCore.TestRepo

  require Ash.Query

  @goal_marker "Goal-Marker-8842"

  setup do
    Samen.TestSandbox.shared!(TestRepo)
    Scripted.reset()
    Samen.AI.Agent.Breaker.reset()
    Membership.reset()
    prior = Membership.install!()

    on_exit(fn ->
      F3FlakyKms.uninstall!()
      Scripted.reset()
      Samen.AI.Agent.Breaker.reset()
      Membership.reset()
      Membership.restore!(prior)
      :persistent_term.erase({__MODULE__, :snapshot})
    end)

    :ok
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

  defp reveal(run), do: Samen.Vault.reveal(run.transcript, TestRepo, subject_id: run.id)

  defp corrupt!(token, ciphertext),
    do: Ecto.Adapters.SQL.query!(TestRepo, "UPDATE pii_vault SET ciphertext = $1 WHERE token = $2", [ciphertext, token])

  defp ciphertext_of(token) do
    %{rows: [[ct]]} = Ecto.Adapters.SQL.query!(TestRepo, "SELECT ciphertext FROM pii_vault WHERE token = $1", [token])
    ct
  end

  describe "the turn loop: a transcript write whose carried views cannot be revealed" do
    # Turn two's provider call is the moment between the turn-start reveal and the write-time reveal: damage the vault
    # row of the transcript THEN (the ciphertext is overwritten with garbage, so the reveal answers :decrypt_failed
    # while the vault still accepts the new blob).
    defp damage_at_turn_two(scope) do
      fn ->
        [run] = runs_of(scope)
        token = run.transcript.token
        {:ok, json} = reveal(run)
        :persistent_term.put({__MODULE__, :snapshot}, {run.id, token, ciphertext_of(token), json})
        corrupt!(token, <<0, 1, 2, 3>>)
        :persistent_term.put({__MODULE__, :damaged?}, reveal(run))
        {:continue, "turn two"}
      end
    end

    test "RED: an unreadable prior transcript at write time ends the run :transcript_unavailable and leaves the stored one untouched" do
      # POSITIVE CONTROL: the same three-turn script on a healthy vault completes, and its transcript keeps both views
      control_scope = new_scope()
      script(continue: "turn one", continue: "turn two", final: "done")
      assert {:ok, %{turns: 3}} = run_scripted(Plain, control_scope, "goal #{@goal_marker}")
      [control_run] = runs_of(control_scope)
      assert {:ok, json} = reveal(control_run)
      assert %{"ui_view" => [_ | _] = ui, "llm_view" => llm, "turn_lens" => lens} = Jason.decode!(json)
      assert ui == llm and Enum.sum(lens) == length(llm)

      scope = new_scope()
      script([{:continue, "turn one"}, damage_at_turn_two(scope), {:final, "done"}])

      {result, log} = with_log(fn -> run_scripted(Plain, scope, "goal #{@goal_marker}") end)
      assert {:error, :transcript_unavailable, failed} = result

      # the injected failure is real, and is the reveal alone: the vault row still accepted writes
      assert {run_id, token, original_ciphertext, snapshot_json} = :persistent_term.get({__MODULE__, :snapshot})
      assert {:error, :decrypt_failed} = :persistent_term.get({__MODULE__, :damaged?})

      assert log =~ "read failed read=agent_carried_views"
      refute log =~ @goal_marker
      refute log =~ "vt_"

      # the run failed fail-honest; the turn that could not be committed is closed, not left proposed
      [run] = runs_of(scope)
      assert run.id == run_id and failed.id == run_id
      assert run.state == :failed
      assert run.error_kind == "transcript_unavailable"
      assert run.current_turn == 1, "the turn whose write was refused must not advance the cursor"

      assert [%{status: :done}, %{status: :failed, error_kind: "transcript_unavailable"}] =
               Samen.AI.Agent.Turn
               |> Ash.Query.filter(run_id == ^run.id)
               |> Ash.Query.sort(turn_index: :asc)
               |> Ash.read!(authorize?: false)

      # the stored transcript is the one from before the failed write: same token, and (once the damage is undone)
      # byte-for-byte the same plaintext, ui_view and fold ledger included
      assert run.transcript.token == token
      corrupt!(token, original_ciphertext)
      assert {:ok, ^snapshot_json} = reveal(run)
    end

    test "control: a subject SHREDDED mid-turn has no views to carry and the write behaves as before" do
      scope = new_scope()

      shred = fn ->
        [run] = runs_of(scope)
        {:ok, _} = Samen.Erasure.shred(run.id, repo: TestRepo, org_id: scope.actor.org_id)
        {:continue, "turn two"}
      end

      script([{:continue, "turn one"}, shred, {:final, "done"}])

      # a shredded subject cannot take a new transcript blob either: the vault refuses the write exactly as it did
      # before this fix; what matters here is that the reveal's `:shredded` is NOT classed as a failed read
      log =
        capture_log(fn ->
          assert :raised == (try do
                               run_scripted(Plain, scope, "goal #{@goal_marker}")
                             rescue
                               _ -> :raised
                             end)
        end)

      refute log =~ "agent_carried_views"
    end
  end

  describe "the approval decision: a transcript write whose carried views cannot be revealed rolls the decision back" do
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

    test "RED: approve with unreadable carried views is refused and rolled back; healthy approve is the control" do
      # POSITIVE CONTROL (also proves the run's subject is unwrapped at least twice on the approve path: the state read
      # and the carried-views read)
      {s0, run0, target0, approval0} = propose!()
      ref = F3FlakyKms.install!(run0.id, 0)
      assert {:ok, %{state: :approved}, %{executed: "assign_record_owner"}} = Approvals.approve(approval0.id, approver_id(s0.actor.org_id))
      assert :atomics.get(ref, 1) >= 2
      assert owner_of(target0) != nil
      F3FlakyKms.uninstall!()

      {s, run, target, approval} = propose!()
      {state_before, json_before} = parked_transcript(run)
      assert state_before == :awaiting_approval
      F3FlakyKms.install!(run.id, 2)

      log = capture_log(fn -> assert {:error, _} = Approvals.approve(approval.id, approver_id(s.actor.org_id)) end)

      assert log =~ "read failed read=agent_carried_views"
      F3FlakyKms.uninstall!()
      assert {:ok, %{state: :pending}} = Approvals.get(approval.id)
      assert owner_of(target) == nil, "the write executed although its transcript could not be committed"
      assert {^state_before, ^json_before} = parked_transcript(run)
    end

    test "RED: reject with unreadable carried views is rolled back; healthy reject is the control" do
      {s0, run0, _target0, approval0} = propose!()
      F3FlakyKms.install!(run0.id, 0)
      assert {:ok, %{state: :rejected}} = Approvals.reject(approval0.id, approver_id(s0.actor.org_id))
      F3FlakyKms.uninstall!()
      assert {:rejected, _} = parked_transcript(run0)

      {s, run, _target, approval} = propose!()
      {state_before, json_before} = parked_transcript(run)
      F3FlakyKms.install!(run.id, 2)

      log = capture_log(fn -> assert {:error, _} = Approvals.reject(approval.id, approver_id(s.actor.org_id)) end)

      assert log =~ "read failed read=agent_carried_views"
      F3FlakyKms.uninstall!()
      assert {:ok, %{state: :pending}} = Approvals.get(approval.id)
      assert {^state_before, ^json_before} = parked_transcript(run)
    end
  end
end
