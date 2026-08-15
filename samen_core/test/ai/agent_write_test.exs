defmodule A4TestAgents do
  @moduledoc false

  defmodule Triage do
    @moduledoc false
    use Samen.AI.Agent,
      name: "a4.triage",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done.",
      tools: ["fetch_record", "assign_record_owner"]
  end

  defmodule ReadOnly do
    @moduledoc false
    use Samen.AI.Agent,
      name: "a4.read-only",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done.",
      tools: ["fetch_record"]
  end
end

defmodule Samen.AI.AgentWriteTest do
  @moduledoc """
  ADR-047 batch A4 — the write surface: **propose-then-approve** (§5.3; ADR-043 §6.2
  ratified **unamended** at §9#1).

    * **RP-AG-5 (write-never-executes)** — no path from an agent turn to a mutating
      governed action without an approve event by a distinct human, with the
      approve-then-execute POSITIVE CONTROL. Sabotage 250 (the write executes inline with
      agent authority) flips the named red here.
    * **Execution authority is the APPROVER's** — never the agent's, never the AI service
      principal's. The AI principal is the requester, is refused as a decider at BOTH the
      policy layer and the `<abbrev>_distinct_party` DB CHECK, and holds no write path.
    * **Approval of proposal X executes exactly X** — the sha256 args digest committed on
      the token-only turn row BEFORE the approval opened binds the proposal stored in the
      run's DEK envelope. A mutated/substituted payload at execution time REFUSES and
      rolls the decision back. Sabotage 252 drops the binding.
    * **Provenance is token-only** — the approval row carries `{org, kind, subject_ref,
      requested_by, deadline}` and a NIL reason; arg values live only inside the vault.
      Sabotage 253 puts the raw args on the approval.
    * **The recursion guard is LIVE** — an approved execution (and an inline read tool)
      cannot start a nested agent run: `:depth_exceeded`, enforced by an AMBIENT marker so
      omitting a `:depth` argument does not route around it. Sabotage 254 drops the marker.
    * **The four-way intersection still narrows** for write tools, and is RE-RESOLVED at
      execution — a tool de-declared while the approval sat pending refuses.
    * **Fail-honest budgets** — a proposal bills no tool call (nothing executed); the
      approved execution bills exactly one.

  Anti-tautology: every red assertion is paired with a positive control.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias A4TestAgents.{ReadOnly, Triage}
  alias Samen.AI.Agent
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.WriteProposal
  alias Samen.AI.Provider.Scripted
  alias Samen.Approvals
  alias SamenCore.Support.AutomationFixture.Target
  alias SamenCore.TestRepo

  require Ash.Query

  @target_key "SamenCore.Support.AutomationFixture.Target"
  @email_canary "canary-a4-write-7q2x@leak.example"
  @vt_token "vt_" <> String.duplicate("c", 32)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Scripted.reset()
    Samen.AI.Agent.Breaker.reset()

    on_exit(fn ->
      Scripted.reset()
      Samen.AI.Agent.Breaker.reset()
    end)

    :ok
  end

  defp new_scope do
    org_id = Ash.UUID.generate()
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp create_target!(org_id, attrs \\ []) do
    Target
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      title: Keyword.get(attrs, :title, "late shipment 4471"),
      priority: :high,
      owner_id: Keyword.get(attrs, :owner_id),
      email: Keyword.get(attrs, :email, @email_canary)
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

  defp assign_call(target_id, user_id) do
    {:tool_call, "assign_record_owner",
     %{"resource" => @target_key, "id" => target_id, "user_id" => user_id}}
  end

  defp reload_run!(run) do
    Run
    |> Ash.Query.filter(id == ^run.id)
    |> Ash.Query.ensure_selected([:org_id, :transcript])
    |> Ash.read!(authorize?: false)
    |> hd()
  end

  defp pending_approvals(org_id) do
    {:ok, approvals} = Approvals.list_pending(org_id, WriteProposal.kind())
    approvals
  end

  defp only_pending!(org_id) do
    assert [approval] = pending_approvals(org_id)
    approval
  end

  # A distinct human approver — never the AI service principal, never the run owner.
  defp approver_id, do: "human:" <> Ash.UUID.generate()

  defp all_sent_text, do: sent_texts() |> Enum.join("\n")

  # Propose a write and return {scope, run, target, approval, new_owner_id}.
  defp propose!(opts \\ []) do
    s = new_scope()
    target = create_target!(s.actor.org_id)
    new_owner = Ash.UUID.generate()

    script([
      assign_call(target.id, new_owner),
      {:final, "assigned (should never be reached before approval)"}
    ])

    assert {:awaiting_approval, run} =
             run_scripted(Keyword.get(opts, :agent, Triage), s, "who should own 4471?")

    {s, run, target, only_pending!(s.actor.org_id), new_owner}
  end

  # The governance audit-chain event types written against an approval's subject_ref.
  defp audit_event_types(approval) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "SELECT ach_event_type FROM aud_chain WHERE ach_subject_id = $1",
        [approval.subject_ref]
      )

    List.flatten(rows)
  end

  # The parked run behind an approval (the approval hangs on the TURN; the turn knows its
  # run) — used by the reds that must show the run is still parked after a refusal.
  defp _run_placeholder(approval) do
    {:ok, turn_id} = WriteProposal.parse_subject_ref(approval.subject_ref)
    turn = Ash.get!(Samen.AI.Agent.Turn, turn_id, authorize?: false)
    %{id: turn.run_id}
  end

  defp revealed_transcript(run) do
    run = reload_run!(run)
    {:ok, json} = Samen.Vault.reveal(run.transcript, TestRepo, subject_id: run.id)
    Jason.decode!(json)
  end

  # Rewrite the pending proposal INSIDE the run's vault-routed transcript — the only place
  # a write's arg VALUES are ever persisted. This models a payload substituted between
  # proposal and approval by anything holding domain-row access. `:advance` is used (not
  # `:park`) because the run is ALREADY parked and the state machine refuses a second park
  # — which is itself a small proof that the park is a real machine transition.
  defp tamper_pending!(approval, fun) do
    {:ok, turn_id} = WriteProposal.parse_subject_ref(approval.subject_ref)
    turn = Ash.get!(Samen.AI.Agent.Turn, turn_id, authorize?: false)

    run =
      Run
      |> Ash.Query.filter(id == ^turn.run_id)
      |> Ash.Query.ensure_selected([:org_id, :transcript])
      |> Ash.read!(authorize?: false)
      |> hd()

    {:ok, json} = Samen.Vault.reveal(run.transcript, TestRepo, subject_id: run.id)
    decoded = Jason.decode!(json)
    tampered = Map.put(decoded, "pending", fun.(decoded["pending"]))

    run
    |> Ash.Changeset.for_update(:advance, %{transcript: Jason.encode!(tampered)})
    |> Ash.update!(authorize?: false)

    :ok
  end

  # ── RP-AG-5: the crown jewel ────────────────────────────────────────────────────────

  describe "RP-AG-5 — no path from an agent turn to a mutating action without an approve event" do
    test "RED (sabotage 250's target): a WRITE tool call does NOT execute — the record is UNCHANGED, the run PARKS, and only an approval exists" do
      {s, run, target, approval, _new_owner} = propose!()

      # 1. NOTHING WAS MUTATED. This is the assertion the whole batch exists for.
      assert reload_target!(target.id).owner_id == nil,
             "an agent turn mutated a governed record with NO approve event — ADR-043 §6.2"

      # 2. The run PARKED (non-terminal, watchdog armed to the deadline — never nil).
      run = reload_run!(run)
      assert run.state == :awaiting_approval
      assert run.next_turn_at != nil, "a parked run is NON-terminal: next_turn_at stays armed"
      assert run.error_kind == nil

      # 3. The turn row is still the :proposed decision checkpoint — NOT a completed turn.
      assert [turn] = turn_rows(run)
      assert turn.status == :proposed
      assert turn.tool_kind == "assign_record_owner"
      assert turn.arg_keys == ["id", "resource", "user_id"]
      assert turn.meta["awaiting_approval"] == true
      assert run.current_turn == 0, "a park must NOT advance the cursor"

      # 4. The proposal exists, requested by the AI service principal.
      assert approval.state == :pending
      assert approval.kind == "ai_agent_write"
      assert approval.subject_ref == "samen:atn:#{turn.id}"
      assert approval.requested_by == WriteProposal.requester_principal_id()
      assert approval.requested_by == Samen.AI.SupportOperator.principal_id()

      # 5. The transcript records the proposal HONESTLY — the call echo plus an explicit
      #    "awaiting_human_approval" line — and carries no evidence of an execution. (The
      #    lines re-enter the prompt as :history only when the run RESUMES, which is
      #    exactly the point: there is no turn N+1 until a human decides.)
      transcript = revealed_transcript(run)
      assert transcript["lines"] |> Enum.any?(&(&1 =~ "tool_call: assign_record_owner"))

      assert transcript["lines"]
             |> Enum.any?(&(&1 == "tool_proposed: assign_record_owner status=awaiting_human_approval"))

      refute Enum.join(transcript["lines"], "\n") =~ "assigned: true"
      refute all_sent_text() =~ "assigned: true"

      # 6. The run stopped: the scripted FINAL was never consumed.
      assert length(Scripted.remaining()) == 1

      # 7. Token-only at rest on the write path too (the args live in the DEK envelope).
      assert_no_text_at_rest!(run, [target.id, @email_canary])
      assert_transcript_vaulted_at_rest!(run, [@email_canary])
      assert_masked_only_payloads!()

      _ = s
    end

    test "POSITIVE CONTROL: a DISTINCT human's approve executes exactly that write, and the run resumes" do
      {s, run, target, approval, new_owner} = propose!()

      assert {:ok, decided, meta} = Approvals.approve(approval.id, approver_id())
      assert decided.state == :approved
      assert meta.executed == "assign_record_owner"
      assert meta.executed_by == "approver"

      # THE MUTATION HAPPENED — and only now.
      assert reload_target!(target.id).owner_id == new_owner

      run = reload_run!(run)
      assert run.state == :running
      assert run.current_turn == 1
      assert run.tool_calls_used == 1, "the approved EXECUTION bills the tool call"

      assert [turn] = turn_rows(run)
      assert turn.status == :done
      assert turn.error_kind == nil
      assert turn.meta["approved"] == true
      assert turn.meta["executed_by"] == "approver"

      # The pending proposal is CLEARED — an executed proposal is not re-bindable.
      assert {:error, :not_pending} = Approvals.approve(approval.id, approver_id())
      assert pending_approvals(s.actor.org_id) == []
    end

    test "the AI service principal can NEVER be the decider — refused at the policy layer, approval stays pending, nothing executes" do
      {_s, _run, target, approval, _new_owner} = propose!()

      assert {:error, :self_approval} =
               Approvals.approve(approval.id, WriteProposal.requester_principal_id())

      assert reload_target!(target.id).owner_id == nil
      assert Approvals.get(approval.id) |> elem(1) |> Map.get(:state) == :pending
    end

    test "the DB CHECK is the second layer: a decided row with decided_by == requested_by is rejected by the database itself" do
      {_s, _run, _target, approval, _new_owner} = propose!()

      # Bypass the engine's policy layer entirely and write the self-decision straight at
      # the table — the `apv_distinct_party` CHECK must refuse it (the constraint, not the
      # code, is what makes requester ≠ approver structural).
      {:ok, pk} = Ecto.UUID.dump(approval.id)

      assert_raise Postgrex.Error, ~r/apv_distinct_party/, fn ->
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "UPDATE apv_approval SET apv_decided_by = apv_requested_by, apv_state = 'approved' WHERE apv_id = $1",
          [pk]
        )
      end
    end

    test "a REJECT by a distinct human terminates the run :rejected and executes nothing" do
      {_s, run, target, approval, _new_owner} = propose!()

      assert {:ok, rejected} = Approvals.reject(approval.id, approver_id())
      assert rejected.state == :rejected

      assert reload_target!(target.id).owner_id == nil

      run = reload_run!(run)
      assert run.state == :rejected
      assert run.error_kind == "rejected"
      assert run.next_turn_at == nil, "a terminal run clears the watchdog exactly once"
      assert [%{status: :failed, error_kind: "rejected"}] = turn_rows(run)
    end
  end

  # ── execution authority ─────────────────────────────────────────────────────────────

  describe "execution authority is the APPROVER's, never the agent's" do
    test "RED: the AI service principal is refused as the executing actor even at the execute_approved/3 seam itself (the third layer)" do
      {_s, _run, target, approval, _new_owner} = propose!()
      {:ok, turn_id} = WriteProposal.parse_subject_ref(approval.subject_ref)

      # Call the execution seam DIRECTLY, past the engine's policy refusal and past the
      # DB CHECK, with the AI service principal as the deciding actor. It must still
      # refuse: the agent's own principal has no write authority anywhere on this path.
      assert {:error, :not_authorized} =
               Agent.execute_approved(turn_id, approval, %{
                 actor: WriteProposal.requester_principal_id()
               })

      assert reload_target!(target.id).owner_id == nil

      # ...and an actor-less decision context is refused too (fail-closed).
      assert {:error, :not_authorized} = Agent.execute_approved(turn_id, approval, %{actor: nil})
      assert reload_target!(target.id).owner_id == nil
    end

    test "POSITIVE CONTROL: approving through the REAL engine path executes AND lands an approval_approved audit event (the refusals above are authority, not breakage)" do
      {_s, _run, target, approval, new_owner} = propose!()
      human = approver_id()

      # Deliberately NOT `execute_approved/3` with a hand-made context: the only sanctioned
      # route is the engine, which transitions `pending -> approved` and writes the
      # governance audit inside the same transaction as the execution. An earlier version of
      # this control invoked the seam directly with a still-PENDING approval struct and
      # asserted it executed — which is precisely how a missing state check stayed invisible.
      assert {:ok, decided, meta} = Approvals.approve(approval.id, human)
      assert decided.state == :approved
      assert meta.executed_by == "approver"
      assert reload_target!(target.id).owner_id == new_owner

      assert "approval_approved" in audit_event_types(approval),
             "an executed write must leave the decision's audit event behind"
    end

    test "RED: a still-PENDING approval cannot execute the parked write at the seam — the state is read from the ROW, not the argument" do
      {_s, _run, target, approval, _new_owner} = propose!()
      {:ok, turn_id} = WriteProposal.parse_subject_ref(approval.subject_ref)

      # The approval struct here is genuine and its id is real — it is simply not decided.
      assert approval.state == :pending

      assert {:error, :approval_not_approved} =
               Agent.execute_approved(turn_id, approval, %{actor: approver_id()})

      assert reload_target!(target.id).owner_id == nil
      assert Approvals.get(approval.id) |> elem(1) |> Map.get(:state) == :pending
      assert reload_run!(_run_placeholder(approval)).state == :awaiting_approval
      refute "approval_approved" in audit_event_types(approval)
    end

    test "RED: a FORGED bare-map approval refuses — including one carrying the REAL id, which sits in the plain atn_meta column" do
      {_s, _run, target, approval, _new_owner} = propose!()
      {:ok, turn_id} = WriteProposal.parse_subject_ref(approval.subject_ref)
      turn = Ash.get!(Samen.AI.Agent.Turn, turn_id, authorize?: false)

      # The attacker's whole input: an id that is NOT a secret — it is stored verbatim in
      # the token-only `meta` jsonb of the turn row, in the clear.
      assert turn.meta["approval_id"] == to_string(approval.id)

      for forged <- [
            %{id: approval.id},
            %{id: Ash.UUID.generate()},
            %{id: "not-a-uuid"},
            %{id: nil},
            %{}
          ] do
        assert {:error, kind} =
                 Agent.execute_approved(turn_id, forged, %{actor: approver_id()}),
               "a forged approval must refuse: #{inspect(forged)}"

        assert kind in [:approval_not_approved, :approval_not_found],
               "unexpected refusal kind #{inspect(kind)} for #{inspect(forged)}"

        assert reload_target!(target.id).owner_id == nil
      end
    end

    test "RED: an APPROVED approval belonging to ANOTHER org cannot execute this org's parked write at the seam" do
      {_s, _run, target, approval, _new_owner} = propose!()
      {:ok, turn_id} = WriteProposal.parse_subject_ref(approval.subject_ref)
      human = approver_id()

      # A genuine, genuinely-:approved approval — of the right kind, pointing at the right
      # subject_ref — that simply belongs to a different org. Transitioned directly (not via
      # the engine) so no handler fires and it arrives here already decided.
      {:ok, foreign} =
        Approvals.request(%{
          org_id: Ash.UUID.generate(),
          kind: WriteProposal.kind(),
          subject_ref: approval.subject_ref,
          requested_by: WriteProposal.requester_principal_id(),
          reason: nil
        })

      foreign =
        foreign
        |> Ash.Changeset.for_update(:approve, %{decided_by: human}, authorize?: false)
        |> Ash.update!()

      assert foreign.state == :approved

      assert {:error, :approval_org_mismatch} =
               Agent.execute_approved(turn_id, foreign, %{actor: human})

      assert reload_target!(target.id).owner_id == nil
    end

    test "the executed write is attributable to the human: the turn row records executed_by=approver and the approver's id" do
      {_s, run, _target, approval, _new_owner} = propose!()
      human = approver_id()

      assert {:ok, _decided, _meta} = Approvals.approve(approval.id, human)

      assert [turn] = turn_rows(reload_run!(run))
      assert turn.meta["executed_by"] == "approver"
      assert turn.meta["approver_id"] == human

      refute turn.meta["approver_id"] == WriteProposal.requester_principal_id(),
             "the AI service principal must never be the executing authority"
    end
  end

  # ── the args-digest binding ─────────────────────────────────────────────────────────

  describe "approval of proposal X executes EXACTLY X (the args-digest binding)" do
    test "RED (sabotage 252's target): args MUTATED between proposal and approval REFUSE — nothing executes, the approval stays pending" do
      {_s, _run, target, approval, _new_owner} = propose!()
      hijacked_owner = Ash.UUID.generate()

      tamper_pending!(approval, fn pending ->
        put_in(pending, ["args", "user_id"], hijacked_owner)
      end)

      assert {:error, :proposal_mismatch} = Approvals.approve(approval.id, approver_id())

      # NOTHING executed, and the decision rolled back whole.
      assert reload_target!(target.id).owner_id == nil
      assert Approvals.get(approval.id) |> elem(1) |> Map.get(:state) == :pending
    end

    test "RED: a SUBSTITUTED tool kind, a re-stamped digest, and a swapped turn index each refuse" do
      for tamper <- [
            fn pending -> Map.put(pending, "kind", "fetch_record") end,
            fn pending -> Map.put(pending, "digest", String.duplicate("a", 64)) end,
            fn pending -> Map.put(pending, "turn_index", 99) end,
            fn pending -> Map.put(pending, "approval_id", Ash.UUID.generate()) end,
            fn pending -> Map.put(pending, "args", %{"resource" => "X"}) end,
            fn _pending -> nil end
          ] do
        {_s, _run, target, approval, _new_owner} = propose!()
        tamper_pending!(approval, tamper)

        assert {:error, :proposal_mismatch} = Approvals.approve(approval.id, approver_id()),
               "a tampered proposal must refuse: #{inspect(tamper)}"

        assert reload_target!(target.id).owner_id == nil
      end
    end

    test "POSITIVE CONTROL: an UNTAMPERED round-trip through the same code path executes (the refusals above are the binding, not breakage)" do
      {_s, _run, target, approval, new_owner} = propose!()

      # Rewrite the transcript with the IDENTICAL pending map — same encode/decode path,
      # same :park action — so the only difference from the reds above is the content.
      tamper_pending!(approval, & &1)

      assert {:ok, _decided, _meta} = Approvals.approve(approval.id, approver_id())
      assert reload_target!(target.id).owner_id == new_owner
    end

    test "the digest on the token-only turn row is the sha256 of the VALIDATED args, and the two stores agree" do
      {_s, run, target, approval, new_owner} = propose!()

      assert [turn] = turn_rows(reload_run!(run))

      expected =
        Agent.args_digest(%{
          "resource" => @target_key,
          "id" => target.id,
          "user_id" => new_owner
        })

      assert turn.meta["args_digest"] == expected
      assert String.match?(turn.meta["args_digest"], ~r/\A[0-9a-f]{64}\z/)
      assert turn.meta["approval_id"] == to_string(approval.id)
    end
  end

  # ── provenance ──────────────────────────────────────────────────────────────────────

  describe "proposal provenance is TOKEN-ONLY" do
    test "RED (sabotage 253's target): the approval row carries NO arg values, NO plaintext, NO vt_ — and a nil reason" do
      {_s, run, target, approval, new_owner} = propose!()

      approval_text =
        approval
        |> Map.from_struct()
        |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
        |> Enum.join(" ")

      refute approval_text =~ target.id, "the proposal leaked a raw arg VALUE (the record id)"
      refute approval_text =~ new_owner, "the proposal leaked a raw arg VALUE (the owner id)"
      refute approval_text =~ @email_canary
      refute approval_text =~ "vt_"
      assert approval.reason == nil, "a proposal reason is model-adjacent free text — always nil"

      # The bounded provenance view is re-derived from GOVERNED state, and is structurally
      # incapable of carrying a value: ids, an integer, a registry enum, key NAMES, a hex.
      assert {:ok, provenance} = WriteProposal.provenance(approval)
      assert provenance.run_id == run.id
      assert provenance.turn_index == 1
      assert provenance.tool_kind == "assign_record_owner"
      assert provenance.arg_keys == ["id", "resource", "user_id"]
      assert String.match?(provenance.args_digest, ~r/\A[0-9a-f]{64}\z/)

      provenance_text = inspect(provenance)
      refute provenance_text =~ new_owner
      refute provenance_text =~ @email_canary
    end

    test "the PHYSICAL approval row holds no arg value either (not an inference from the Ash read)" do
      {_s, _run, target, approval, new_owner} = propose!()

      %{columns: columns, rows: [row]} =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT * FROM apv_approval WHERE apv_id = $1",
          [Ecto.UUID.dump!(approval.id)]
        )

      for {col, value} <- Enum.zip(columns, row), is_binary(value) do
        refute String.contains?(value, target.id), "raw column #{col} carries an arg value"
        refute String.contains?(value, new_owner), "raw column #{col} carries an arg value"
        refute String.contains?(value, "vt_"), "raw column #{col} carries a vault token"
      end
    end
  end

  # ── the recursion guard ─────────────────────────────────────────────────────────────

  describe "the depth/chain recursion guard is LIVE (ADR-047 §5.1)" do
    test "RED (sabotage 254's target): a tool that tries to start a nested agent run is refused :depth_exceeded — WITHOUT passing any depth argument" do
      s = new_scope()
      target = create_target!(s.actor.org_id)

      # The nesting attempt runs from inside the read-tool execution: the probe action's
      # run/2 calls Agent.start/4 with NO :depth option at all, which is exactly the
      # bypass an explicit-argument-only guard would miss.
      with_probe_action(fn ->
        script([
          {:tool_call, "a4_nesting_probe", %{}},
          {:final, "declined to recurse"}
        ])

        assert {:ok, %{run: run}} = run_scripted(NestingAgent, s, "try to recurse")

        assert [turn, _] = turn_rows(run)
        assert turn.tool_kind == "a4_nesting_probe"
        assert turn.error_kind == "depth_exceeded"
        assert_history_accumulated!(2, ["tool_error: depth_exceeded"])

        # No child run was created — the refusal happens BEFORE anything persists.
        assert Run |> Ash.Query.filter(depth > 0) |> Ash.read!(authorize?: false) == []
      end)

      _ = target
    end

    test "POSITIVE CONTROL: the SAME start call outside any tool execution succeeds (the refusal is the guard, not breakage)" do
      s = new_scope()
      script(final: "top-level run is fine")

      assert {:ok, %{answer: "top-level run is fine", run: run}} =
               run_scripted(ReadOnly, s, "top level")

      assert run.depth == 0
      assert Agent.current_provenance() == nil, "no ambient marker outside a tool execution"
      assert Agent.max_agent_depth() == 0
    end

    test "the ambient marker is set during a tool execution and restored afterwards" do
      s = new_scope()
      target = create_target!(s.actor.org_id)

      with_probe_action(fn ->
        script([
          {:tool_call, "a4_nesting_probe", %{}},
          {:final, "done"}
        ])

        assert {:ok, %{run: run}} = run_scripted(NestingAgent, s, "observe the marker")

        # The probe records what it observed ambiently while executing.
        assert %{depth: 0, chain: [chain_run_id]} = :persistent_term.get({:a4_probe, :seen})
        assert chain_run_id == run.id
      end)

      # ...and it is gone again once the tool returned.
      assert Agent.current_provenance() == nil
      _ = target
    end

    test "an EXPLICIT depth/chain past the v1 ceiling is refused too (the opt path, not only the ambient one)" do
      s = new_scope()
      script(final: "never reached")

      assert {:error, :depth_exceeded} =
               Agent.run(ReadOnly, s, "nested", depth: 1, provider: scripted_provider())

      assert {:error, :depth_exceeded} =
               Agent.start(ReadOnly, s, "nested", chain: ["r1"], provider: scripted_provider())

      # A cycle is refused on its own terms, independent of depth accounting.
      assert {:error, :depth_exceeded} =
               Agent.run(ReadOnly, s, "cycle", chain: ["r1", "r1"], provider: scripted_provider())
    end
  end

  # ── the intersection still narrows for writes ───────────────────────────────────────

  describe "the four-way intersection binds write tools too" do
    test "an UNDECLARED write tool is refused, recorded, never proposed and never executed" do
      s = new_scope()
      target = create_target!(s.actor.org_id)

      script([
        assign_call(target.id, Ash.UUID.generate()),
        {:final, "declined"}
      ])

      assert {:ok, %{run: run}} = run_scripted(ReadOnly, s, "try to write")

      assert [%{error_kind: "tool_refused", tool_kind: "assign_record_owner"}, _] = turn_rows(run)
      assert pending_approvals(s.actor.org_id) == []
      assert reload_target!(target.id).owner_id == nil
    end

    test "the intersection is RE-RESOLVED at execution: a tool de-opted-in while the approval sat pending refuses" do
      {_s, _run, target, approval, _new_owner} = propose!()

      # The core registry wins over host extras by design, so a de-opt-in is modelled at
      # intersection ARM 3 instead: re-point the run row at an agent whose definition never
      # declared the write tool — i.e. the deployment changed while the approval sat
      # pending. The execution path re-resolves the intersection rather than trusting the
      # admission made at proposal time.
      {:ok, turn_id} = WriteProposal.parse_subject_ref(approval.subject_ref)
      turn = Ash.get!(Samen.AI.Agent.Turn, turn_id, authorize?: false)
      {:ok, pk} = Ecto.UUID.dump(turn.run_id)

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "UPDATE ai_agent_run SET arn_agent = $1, arn_agent_module = $2 WHERE arn_id = $3",
        ["a4.read-only", Atom.to_string(ReadOnly), pk]
      )

      assert {:error, :tool_refused} = Approvals.approve(approval.id, approver_id())
      assert reload_target!(target.id).owner_id == nil
    end
  end

  # ── fail-honest seam ────────────────────────────────────────────────────────────────

  describe "an approvals engine that cannot open the proposal is fail-honest" do
    test "an UNREGISTERED kind makes the write refuse :approval_unavailable — the run continues, NOTHING is executed" do
      previous = Application.get_env(:samen_core, Samen.Approvals.Registry, [])
      kinds = Keyword.get(previous, :kinds, %{}) |> Map.delete(WriteProposal.kind())
      Application.put_env(:samen_core, Samen.Approvals.Registry, Keyword.put(previous, :kinds, kinds))
      on_exit(fn -> Application.put_env(:samen_core, Samen.Approvals.Registry, previous) end)

      s = new_scope()
      target = create_target!(s.actor.org_id)

      script([
        assign_call(target.id, Ash.UUID.generate()),
        {:final, "could not propose"}
      ])

      assert {:ok, %{answer: "could not propose", run: run}} =
               run_scripted(Triage, s, "who should own it?")

      assert [%{error_kind: "approval_unavailable", tool_kind: "assign_record_owner"}, _] =
               turn_rows(run)

      assert_history_accumulated!(2, ["tool_error: approval_unavailable"])
      assert reload_target!(target.id).owner_id == nil
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 0
    end
  end

  # ── budgets + cancellation ──────────────────────────────────────────────────────────

  describe "budget + interrupt semantics on the write path" do
    test "a PROPOSAL bills no tool call; the approved EXECUTION bills exactly one" do
      {_s, run, _target, approval, _new_owner} = propose!()

      assert reload_run!(run).tool_calls_used == 0, "a proposal executed nothing"

      assert {:ok, _decided, _meta} = Approvals.approve(approval.id, approver_id())
      assert reload_run!(run).tool_calls_used == 1
    end

    test "cancelling a PARKED run withdraws the pending approval and terminates the run — the write can no longer be executed" do
      {s, run, target, approval, _new_owner} = propose!()

      assert {:ok, cancelled} = Agent.cancel(s, run.id)
      assert cancelled.state == :cancelled
      assert cancelled.next_turn_at == nil

      assert pending_approvals(s.actor.org_id) == []
      assert {:error, :not_pending} = Approvals.approve(approval.id, approver_id())
      assert reload_target!(target.id).owner_id == nil
    end
  end

  # ── the vt_ arg gate on the write path ──────────────────────────────────────────────

  describe "the vt_ sentinel gate binds the write path too" do
    test "a vt_-bearing write ARG is refused BEFORE any proposal is opened" do
      s = new_scope()
      target = create_target!(s.actor.org_id)

      script([
        {:tool_call, "assign_record_owner",
         %{"resource" => @target_key, "id" => target.id, "user_id" => @vt_token}},
        {:final, "declined the token"}
      ])

      assert {:ok, %{run: run}} = run_scripted(Triage, s, "goal")

      assert [%{error_kind: "invalid_args", tool_kind: "assign_record_owner"}, _] = turn_rows(run)
      assert pending_approvals(s.actor.org_id) == []
      refute all_sent_text() =~ "vt_"
      assert_no_text_at_rest!(run, [@vt_token])
    end
  end

  # --- the nesting probe seam ------------------------------------------------------------

  # A host-extra READ tool whose run/2 tries to start a nested agent run with NO depth
  # argument — registered through the sanctioned `extra:` seam only for the tests that
  # need it, and torn down after.
  defp with_probe_action(fun) do
    previous = Application.get_env(:samen_core, Samen.Automation.Action, [])
    extra = Keyword.get(previous, :extra, %{})

    Application.put_env(
      :samen_core,
      Samen.Automation.Action,
      Keyword.put(previous, :extra, Map.put(extra, "a4_nesting_probe", A4NestingProbe))
    )

    :persistent_term.erase({:a4_probe, :seen})

    try do
      fun.()
    after
      Application.put_env(:samen_core, Samen.Automation.Action, previous)
      :persistent_term.erase({:a4_probe, :seen})
    end
  end

end

defmodule A4NestingProbe do
  @moduledoc false
  @behaviour Samen.Automation.Action

  @tool_schema %{
    name: "a4_nesting_probe",
    description: "test-only probe that tries to start a nested agent run",
    params: []
  }

  @impl true
  def kind, do: :a4_nesting_probe

  @impl true
  def tool_schema, do: @tool_schema

  @impl true
  def effect, do: :read

  @impl true
  def validate(config, _resource_key) when is_map(config), do: {:ok, %{}}
  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(_config, ctx) do
    # Record what the AMBIENT guard exposed while this tool executes...
    :persistent_term.put({:a4_probe, :seen}, Samen.AI.Agent.current_provenance())

    # ...then try to recurse with NO :depth option whatsoever.
    case Samen.AI.Agent.start(NestingAgent, ctx.actor, "nested goal") do
      {:error, kind} when is_atom(kind) -> {:error, kind}
      {:ok, _run} -> {:ok, %{kind: :a4_nesting_probe, recursed: true}}
      _ -> {:error, :tool_failed}
    end
  end
end

defmodule NestingAgent do
  @moduledoc false
  use Samen.AI.Agent,
    name: "a4.nesting",
    goal_prompt: "Try the probe. Reply FINAL: <answer> when done.",
    tools: ["a4_nesting_probe"]
end
