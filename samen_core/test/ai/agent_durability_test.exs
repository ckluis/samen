defmodule A2TestAgents do
  @moduledoc false

  defmodule Durable do
    @moduledoc false
    use Samen.AI.Agent,
      name: "a2.durable",
      goal_prompt: "Work the goal step by step. Reply FINAL: <answer> when done."
  end
end

defmodule Samen.AI.AgentDurabilityTest do
  @moduledoc """
  ADR-047 batch A2 — durability, idempotency, breakers, erasure:

    * `start/4` creates the `:queued` cursor and enqueues the FIRST TurnWorker job in
      the SAME transaction (the EventCapture idiom) — a rolled-back start leaves NO run
      row and NO job (proven by literal rollback); job args are token-only (F2.1);
    * the worker executes turn BATCHES (`turns_per_job/0`) and re-arms; a full drain
      runs a multi-turn goal to its terminal state with the SAME masked-only payloads;
    * **restart safety (RP-AG-7)**: a worker process KILLED mid-turn (after the
      `:proposed` decision checkpoint, inside the provider call) leaves a resumable
      cursor; the replay REUSES the `{run_id, turn_index}` row — exactly one row per
      index, stamped `meta: %{"replayed" => true}` — and never re-executes a completed
      turn (sabotage 242 flips the named tests here);
    * **never-nil `next_turn_at` watchdog**: a stalled run (dead job, elapsed window)
      is re-selected by the AshOban `:agent_turn_due` due-scan and driven to terminal;
      a run whose window has not elapsed is NOT selected (positive/negative pair;
      sabotage 243 flips the named test);
    * **kill-switch (fail-closed)**: switch on ⇒ new runs refuse honestly with NOTHING
      persisted, and an in-flight run stops at the NEXT turn boundary (sabotage 244);
      re-arming is explicit-operator-only;
    * **rate trip (§9#3 TAKEN)**: crossing the runs-per-org-hour threshold refuses the
      crossing run AND throws the same operator kill (reason `:rate_tripped`);
    * **provider trip**: consecutive normalized provider errors park the agent
      definition; a success resets the streak; re-arm restores;
    * **vault-routed transcript (§7.4; §9#2/#4 TAKEN)**: the transcript at rest is a
      `vt_*` token inside the DEK envelope (proven at the PHYSICAL row), revealed only
      through the one chokepoint; `Samen.Erasure.shred/2` reaches it (reveal
      `{:error, :shredded}`), a shredded mid-flight run refuses honestly, and the
      DERIVED 90-day retention `:shred` arm sweeps an expired run's DEK
      (sabotage 245 flips the erasure-arm tests);
    * **`AgentCase.leaks?/2` map/jsonb arm is non-vacuous**: a canary inside a
      persisted jsonb `meta` value IS detected (red-path), with clean controls.

  Anti-tautology: every red assertion is paired with a positive control.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias A2TestAgents.Durable
  alias Samen.AI.Agent
  alias Samen.AI.Agent.Breaker
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.Turn
  alias Samen.AI.Agent.TurnWorker
  alias Samen.AI.Provider.Scripted
  alias Samen.Erasure
  alias Samen.Retention
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

  # Merge agent-group config for one test, restoring the previous group on exit.
  defp put_agent_config(kv) do
    previous = Application.get_env(:samen_core, Samen.AI.Agent, [])
    Application.put_env(:samen_core, Samen.AI.Agent, Keyword.merge(previous, kv))
    on_exit(fn -> Application.put_env(:samen_core, Samen.AI.Agent, previous) end)
  end

  # The worker resolves its provider from host config — the A2 cross-process seam.
  defp scripted_worker_config, do: put_agent_config(provider: scripted_provider())

  defp reload(run) do
    [row] =
      Run
      |> Ash.Query.filter(id == ^run.id)
      |> Ash.Query.ensure_selected([:org_id, :transcript])
      |> Ash.read!(authorize?: false)

    row
  end

  defp turn_worker_jobs do
    Oban.Job
    |> TestRepo.all()
    |> Enum.filter(&(&1.worker == "Samen.AI.Agent.TurnWorker"))
  end

  defp perform!(run), do: TurnWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

  defp drain_agent_queues do
    Oban.drain_queue(queue: :automation_timers, with_recursion: true)
    Oban.drain_queue(queue: :automation, with_recursion: true)
  end

  defp reveal_transcript(run) do
    run = reload(run)
    %Samen.Masked{} = masked = run.transcript
    Samen.Vault.reveal(masked, TestRepo, subject_id: run.id)
  end

  # ── start/4: same-transaction launch enqueue (§4.1, the EventCapture idiom) ─────────

  describe "start/4: the durable launch" do
    test "creates a :queued cursor with an ARMED watchdog and a token-only TurnWorker job in the SAME transaction" do
      s = new_scope()

      assert {:ok, run} = Agent.start(Durable, s, "why is shipment 4471 late?")
      assert run.state == :queued
      assert run.next_turn_at != nil, "never-nil watchdog: a :queued run must be due-scannable"

      assert [job] = turn_worker_jobs()
      assert job.queue == "automation"
      # F2.1: job args carry ONLY the opaque run id — never goal text, org, or budgets.
      assert job.args == %{"run_id" => run.id}
    end

    test "RED: a rolled-back start leaves NO run row and NO job (the enqueue rides the create transaction)" do
      s = new_scope()
      org_id = s.actor.org_id

      {:error, :abort} =
        TestRepo.transaction(fn ->
          {:ok, _run} = Agent.start(Durable, s, "goal")
          TestRepo.rollback(:abort)
        end)

      assert [] =
               Run
               |> Ash.Query.filter(org_id == ^org_id)
               |> Ash.read!(authorize?: false)

      assert turn_worker_jobs() == []
    end

    test "POSITIVE CONTROL: the same start un-rolled-back leaves BOTH (the red above is the rollback, not breakage)" do
      s = new_scope()
      org_id = s.actor.org_id

      assert {:ok, _run} = Agent.start(Durable, s, "goal")

      assert [_] =
               Run
               |> Ash.Query.filter(org_id == ^org_id)
               |> Ash.read!(authorize?: false)

      assert [_] = turn_worker_jobs()
    end
  end

  # ── the worker: batches + drain-to-terminal ─────────────────────────────────────────

  describe "TurnWorker: batch execution over the durable cursor" do
    test "a multi-turn goal drains to :succeeded; payloads stay masked-only; the transcript accumulates" do
      scripted_worker_config()
      s = new_scope()

      script(
        continue: "looking at the shipment",
        continue: "checking the carrier",
        final: "the carrier missed the pickup window"
      )

      assert {:ok, run} = Agent.start(Durable, s, "why is shipment 4471 late?")
      drain_agent_queues()

      run = assert_terminal!(run, :succeeded)
      assert run.current_turn == 3

      # The worker path drove the SAME chokepoint discipline: history accumulated and
      # re-scrubbed, every segment a plain rendered binary (RP-AG-3's property).
      assert_history_accumulated!(3, ["looking at the shipment", "checking the carrier"])
      assert_masked_only_payloads!()

      # The durable transcript carries goal + every line (the A5 surface's source),
      # revealed ONLY through the one chokepoint bound to the run's own subject id.
      assert {:ok, json} = reveal_transcript(run)

      assert %{
               "goal" => "why is shipment 4471 late?",
               "lines" => [
                 "looking at the shipment",
                 "checking the carrier",
                 "FINAL: the carrier missed the pickup window"
               ]
             } = Jason.decode!(json)
    end

    test "batching: one job executes turns_per_job (4) turns, re-arms with a non-nil watchdog, and the next drain finishes" do
      scripted_worker_config()
      s = new_scope()

      script([
        {:continue, "one"},
        {:continue, "two"},
        {:continue, "three"},
        {:continue, "four"},
        {:continue, "five"},
        {:final, "six"}
      ])

      assert {:ok, run} = Agent.start(Durable, s, "goal")

      # First job: exactly 4 turns, then a batch boundary — still :running, watchdog
      # re-armed (never nil), a re-arm job enqueued.
      assert :ok = perform!(run)
      run = reload(run)
      assert run.state == :running
      assert run.current_turn == 4
      assert run.next_turn_at != nil, "never-nil watchdog at the batch boundary"
      assert length(Scripted.remaining()) == 2

      # The re-armed job finishes the run.
      drain_agent_queues()
      run = assert_terminal!(run, :succeeded)
      assert run.current_turn == 6
    end
  end

  # ── restart safety: worker death mid-turn + turn-row replay reuse (RP-AG-7) ─────────

  describe "restart safety: a worker death mid-turn resumes without duplicating work" do
    test "RED: a worker KILLED inside turn 2's provider call leaves the :proposed checkpoint; the replay REUSES the row and never re-executes turn 1" do
      scripted_worker_config()
      s = new_scope()

      script([
        {:continue, "turn one"},
        # Consumed as turn 2's entry, evaluated INSIDE the worker process AFTER the
        # :proposed decision checkpoint committed — the mid-turn death (exits are not
        # rescued by the chokepoint's error normalization; the process dies).
        fn -> exit(:mid_turn_death) end,
        {:continue, "turn two (replayed)"},
        {:final, "answer"}
      ])

      assert {:ok, run} = Agent.start(Durable, s, "goal")

      {pid, ref} = spawn_monitor(fn -> perform!(run) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :mid_turn_death}, 5_000

      # The durable cursor survived the death mid-turn: turn 1 committed, turn 2 is a
      # :proposed decision checkpoint, the run is :running with a non-nil watchdog.
      run = reload(run)
      assert run.state == :running
      assert run.current_turn == 1
      assert run.next_turn_at != nil, "never-nil watchdog after a mid-turn death"

      assert [%{turn_index: 1, status: :done}, %{turn_index: 2, status: :proposed}] =
               turn_rows(run)

      # The replay (what the watchdog/retry does): turn 2 REUSES its :proposed row —
      # exactly one row per index, stamped replayed — and turn 1 is NOT re-executed
      # (its script entry was consumed exactly once; the replay consumes entry 3).
      assert :ok = perform!(run)
      run = assert_terminal!(run, :succeeded)
      assert run.current_turn == 3

      assert [t1, t2, t3] = turn_rows(run)
      assert {1, :done, false} = {t1.turn_index, t1.status, t1.meta["replayed"]}
      assert {2, :done, true} = {t2.turn_index, t2.status, t2.meta["replayed"]}
      assert {3, :done, false} = {t3.turn_index, t3.status, t3.meta["replayed"]}

      # At-least-once, stated honestly: the provider saw 4 calls (turn 2 twice — the
      # died attempt + the replay); the turn ROW count is 3 (the dedupe unit).
      assert length(sent_segments()) == 4
      assert Scripted.remaining() == []

      assert {:ok, json} = reveal_transcript(run)
      assert %{"lines" => ["turn one", "turn two (replayed)", "FINAL: answer"]} = Jason.decode!(json)
    end

    test "POSITIVE CONTROL: the same script shape without the death runs straight through (3 rows, none replayed)" do
      scripted_worker_config()
      s = new_scope()

      script([{:continue, "turn one"}, {:continue, "turn two"}, {:final, "answer"}])

      assert {:ok, run} = Agent.start(Durable, s, "goal")
      assert :ok = perform!(run)

      run = assert_terminal!(run, :succeeded)
      assert [t1, t2, t3] = turn_rows(run)
      assert Enum.all?([t1, t2, t3], &(&1.status == :done and &1.meta["replayed"] == false))
      assert length(sent_segments()) == 3
    end

    test "a crash-after-decision replay (pre-seeded :proposed row) executes the turn AT MOST once more, reusing the row" do
      scripted_worker_config()
      s = new_scope()

      script([{:final, "answer"}])
      assert {:ok, run} = Agent.start(Durable, s, "goal")

      # Simulate the narrowest crash window: the decision checkpoint for turn 1 was
      # committed but the worker died before the provider call.
      Turn
      |> Ash.Changeset.for_create(:record, %{
        org_id: s.actor.org_id,
        run_id: run.id,
        turn_index: 1,
        status: :proposed
      })
      |> Ash.create!(authorize?: false)

      assert :ok = perform!(run)
      run = assert_terminal!(run, :succeeded)

      assert [%{turn_index: 1, status: :done} = t1] = turn_rows(run)
      assert t1.meta["replayed"] == true
      assert length(sent_segments()) == 1
    end
  end

  # ── the never-nil next_turn_at watchdog (§4.1; sabotage 243) ────────────────────────

  describe "the :agent_turn_due watchdog recovers a stalled run" do
    test "RED: a run whose job was LOST is re-selected once its watchdog window elapses and driven to terminal" do
      scripted_worker_config()
      s = new_scope()

      script(continue: "one", final: "two")
      assert {:ok, run} = Agent.start(Durable, s, "goal")

      # The job is lost (crashed queue, pruned row — the silent-stall class).
      TestRepo.delete_all(Oban.Job)
      assert turn_worker_jobs() == []

      # NEGATIVE CONTROL first: the watchdog window has NOT elapsed — the due-scan
      # selects nothing and the run stays exactly where it was.
      AshOban.Test.schedule_and_run_triggers(Run)
      drain_agent_queues()
      assert reload(run).state == :queued
      assert length(Scripted.remaining()) == 2

      # Time-travel the watchdog into the past (the AshOban reminder-test idiom) — the
      # due-scan MUST now re-select and resume the run to its terminal state.
      run
      |> Ash.Changeset.for_update(:advance, %{next_turn_at: DateTime.add(DateTime.utc_now(), -5)})
      |> Ash.update!(authorize?: false)

      AshOban.Test.schedule_and_run_triggers(Run)
      drain_agent_queues()

      run = assert_terminal!(run, :succeeded)
      assert run.current_turn == 2
      assert Scripted.remaining() == []
    end

    test "the never-nil invariant holds at every non-terminal point (queued, running, batch boundary); terminal clears it exactly once" do
      scripted_worker_config()
      s = new_scope()

      script([{:continue, "one"}, {:final, "two"}])
      assert {:ok, run} = Agent.start(Durable, s, "goal")
      assert reload(run).next_turn_at != nil

      assert :ok = perform!(run)
      # assert_terminal! itself asserts next_turn_at == nil on the terminal row (§4.1).
      assert_terminal!(run, :succeeded)
    end
  end

  # ── kill-switch: fail-closed, re-checked per turn (§6; sabotage 244) ────────────────

  describe "the host-level agent kill-switch" do
    test "RED: switch ON refuses new runs honestly — sync and durable alike, NOTHING persisted" do
      s = new_scope()
      org_id = s.actor.org_id
      script(final: "never")

      Breaker.kill(:operator)

      assert {:error, :killed} = run_scripted(Durable, s, "goal")
      assert {:error, :killed} = Agent.start(Durable, s, "goal")

      assert [] = Run |> Ash.Query.filter(org_id == ^org_id) |> Ash.read!(authorize?: false)
      assert turn_worker_jobs() == []
      assert sent_segments() == []

      # POSITIVE CONTROL: an explicit re-arm restores the path (the refusal above was
      # the switch, not breakage).
      Breaker.rearm()
      assert {:ok, %{answer: "never"}} = run_scripted(Durable, s, "goal")
    end

    test "RED: a kill flipped DURING turn 2 stops turn 3 — the in-flight turn completes and is recorded honestly" do
      s = new_scope()

      script([
        {:continue, "turn one"},
        fn ->
          Breaker.kill(:operator)
          {:continue, "turn two"}
        end,
        {:final, "never reached"}
      ])

      assert {:error, :killed, run} = run_scripted(Durable, s, "goal")

      run = assert_terminal!(run, :failed)
      assert run.error_kind == "killed"

      # "Stopping after the current step": turn 2 completed and was recorded; turn 3
      # never reached the provider.
      assert length(sent_segments()) == 2
      assert [%{turn_index: 1, status: :done}, %{turn_index: 2, status: :done}] = turn_rows(run)
      assert length(Scripted.remaining()) == 1
    end

    test "POSITIVE CONTROL: the same script WITHOUT the kill runs turn 3 to the final answer" do
      s = new_scope()

      script([{:continue, "turn one"}, {:continue, "turn two"}, {:final, "reached"}])

      assert {:ok, %{answer: "reached", turns: 3}} = run_scripted(Durable, s, "goal")
      assert length(sent_segments()) == 3
    end

    test "the config half (kill_switch: true) is honored fail-closed" do
      s = new_scope()
      put_agent_config(kill_switch: true)

      assert Breaker.killed?()
      assert {:error, :killed} = Agent.start(Durable, s, "goal")
    end
  end

  # ── rate trip: 60 runs/org/hour ratified; counted from the run log (§6, §9#3) ───────

  describe "the per-org rate trip" do
    test "RED: the crossing run is refused :rate_tripped and trips the DURABLE per-definition kill (reason rate_tripped); re-arm is explicit" do
      put_agent_config(rate_limit_per_org_hour: 3)
      s = new_scope()

      for _ <- 1..3 do
        script(final: "ok")
        assert {:ok, _} = run_scripted(Durable, s, "goal")
      end

      # The 4th run crosses 3-per-hour: refused, NOTHING persisted for it, and the
      # kill lands — idempotently — on THIS {org, definition} only.
      assert {:error, :rate_tripped} = run_scripted(Durable, s, "goal")
      org_id = s.actor.org_id
      agent_name = Durable.definition().name

      assert Breaker.definition_killed?(org_id, agent_name)
      assert Breaker.killed?(org_id, agent_name)
      assert [kill] = Breaker.kills(org_id)
      assert kill.agent == agent_name
      assert kill.reason == "rate_tripped"

      assert 3 = Run |> Ash.Query.filter(org_id == ^org_id) |> Ash.count!(authorize?: false)

      # Fail-closed for the TRIPPED tenant's definition: a further run refuses :killed.
      assert {:error, :killed} = run_scripted(Durable, s, "goal")

      # A5 — THE BLAST-RADIUS FOLD (the A2/A3 residual, closed). A2/A3 threw the
      # HOST-LEVEL switch here, so one org crossing its own threshold stopped agent runs
      # for EVERY org on the host. It no longer does: the host switch is untouched, and
      # ANOTHER org's run of the SAME definition still runs. Sabotage 260 re-widens this.
      refute Breaker.killed?(), "the rate trip must NOT throw the host-level kill switch"
      other = new_scope()
      script(final: "other org unaffected")

      assert {:ok, %{answer: "other org unaffected"}} =
               run_scripted(Durable, other, "goal"),
             "one org's rate trip halted another org's agent runs — the cross-tenant blast radius is back"

      # POSITIVE CONTROL: explicit per-definition re-arm + a raised limit runs again —
      # the refusal was the threshold, not breakage. Trips never self-heal.
      assert {:error, :killed} = run_scripted(Durable, s, "goal")
      :ok = Breaker.rearm_definition(org_id, agent_name, actor_id: "op:1")
      refute Breaker.definition_killed?(org_id, agent_name)
      put_agent_config(rate_limit_per_org_hour: 100)
      script(final: "ok again")
      assert {:ok, %{answer: "ok again"}} = run_scripted(Durable, s, "goal")
    end

    test "RED: a DURABLE per-definition kill stops an IN-FLIGHT run at its next turn boundary, and only that {org, definition}" do
      s = new_scope()
      agent_name = Durable.definition().name

      # Turn 1 runs and the DURABLE per-definition kill lands during it; turn 2 never
      # reaches the provider (the per-turn re-check, narrowed — sabotage 260's target).
      script([
        fn ->
          Breaker.kill_definition(s.actor.org_id, agent_name, :operator, actor_id: "op:1")
          {:continue, "turn one"}
        end,
        {:final, "never reached"}
      ])

      assert {:error, :killed, run} = run_scripted(Durable, s, "goal")
      run = assert_terminal!(run, :failed)
      assert run.error_kind == "killed"
      assert length(sent_segments()) == 1, "the in-flight turn completed and was recorded honestly"
      assert length(Scripted.remaining()) == 1

      # Another org running the same definition is unaffected (blast radius).
      script(final: "unaffected")
      assert {:ok, %{answer: "unaffected"}} = run_scripted(Durable, new_scope(), "goal")
    end
  end

  # ── provider trip: consecutive normalized provider errors park the definition ───────

  describe "the provider trip" do
    test "RED: consecutive provider errors past the threshold park the agent; a parked agent refuses BEFORE any provider call; re-arm restores" do
      put_agent_config(provider_trip_threshold: 2)
      s = new_scope()

      for _ <- 1..2 do
        script([{:error, {:boom, "outage"}}])
        assert {:error, {:provider_error, Scripted}, _run} = run_scripted(Durable, s, "goal")
      end

      Scripted.reset()
      script(final: "never")
      assert {:error, :provider_tripped} = run_scripted(Durable, s, "goal")
      # Parked means refused at run start — the provider never saw a call.
      assert sent_segments() == []

      # POSITIVE CONTROL: re-arm restores the path.
      Breaker.rearm()
      assert {:ok, %{answer: "never"}} = run_scripted(Durable, s, "goal")
    end

    test "POSITIVE CONTROL: a success between errors RESETS the streak — no park below consecutive threshold" do
      put_agent_config(provider_trip_threshold: 2)
      s = new_scope()

      script([{:error, :boom}])
      assert {:error, _, _} = run_scripted(Durable, s, "goal")

      script(final: "ok")
      assert {:ok, _} = run_scripted(Durable, s, "goal")

      script([{:error, :boom}])
      assert {:error, _, _} = run_scripted(Durable, s, "goal")

      refute Breaker.provider_tripped?("a2.durable")
      script(final: "still runs")
      assert {:ok, %{answer: "still runs"}} = run_scripted(Durable, s, "goal")
    end
  end

  # ── the vault-routed transcript + erasure reach (§7.4; RP-AG-11's live half) ────────

  describe "transcript at rest: DEK envelope in, plaintext never" do
    test "the PHYSICAL run row holds a vt_* token — no canary text in ANY raw column; reveal round-trips (control)" do
      s = new_scope()

      canaries = ["CANARY-goal-a2tr", "CANARY-line-a2tr", "CANARY-final-a2tr"]

      script(
        continue: "thinking about CANARY-line-a2tr",
        final: "CANARY-final-a2tr"
      )

      assert {:ok, %{run: run}} = run_scripted(Durable, s, "the goal is CANARY-goal-a2tr")

      # POSITIVE CONTROL half: the canaries genuinely flowed into the transcript —
      # the vault reveal (the ONE decrypt chokepoint) returns them.
      assert {:ok, json} = reveal_transcript(run)
      for canary <- canaries, do: assert(json =~ canary)

      # The red half, at the PHYSICAL layer: the raw row carries a vt_* token and no
      # canary anywhere; the Ash read presents %Masked{}; the turn rows stay token-only.
      assert_transcript_vaulted_at_rest!(run, canaries)
      assert_no_text_at_rest!(run, canaries)
    end

    test "RED: Samen.Erasure.shred(run.id) reaches the transcript — reveal flips to {:error, :shredded}" do
      s = new_scope()
      script(final: "the CANARY-shred-a2 answer")

      assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal")

      # POSITIVE CONTROL first: pre-shred the transcript reveals.
      assert {:ok, json} = reveal_transcript(run)
      assert json =~ "CANARY-shred-a2"

      assert {:ok, %{attestation: %{state: :shredded}}} =
               Erasure.shred(run.id, repo: TestRepo, org_id: s.actor.org_id)

      assert {:error, :shredded} = reveal_transcript(run)
    end

    test "RED (A3 fold — the F4.1 accountability bind): a cross-run transcript token SWAP is refused by the subject bind — the run terminates :transcript_unavailable, executing nothing" do
      scripted_worker_config()
      a = new_scope()
      b = new_scope()

      assert {:ok, run_a} = Agent.start(Durable, a, "goal A CANARY-bind-a3")
      assert {:ok, run_b} = Agent.start(Durable, b, "goal B CANARY-bind-b3")

      # The attack: launder run B's transcript TOKEN into run A's row (raw SQL — the
      # cross-subject confusion `Samen.Vault.reveal/3`'s subject bind exists to refuse).
      # WITHOUT the loop asserting `subject_id: run.id` at its reveal, B's token would
      # decrypt just fine under B's own subject DEK — and run A would keep executing on
      # a FOREIGN transcript while every audit line attributes the work to run A.
      {:ok, a_pk} = Ecto.UUID.dump(run_a.id)
      {:ok, b_pk} = Ecto.UUID.dump(run_b.id)

      %{rows: [[token_b]]} =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT pii_arn_transcript FROM ai_agent_run WHERE arn_id = $1",
          [b_pk]
        )

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "UPDATE ai_agent_run SET pii_arn_transcript = $1 WHERE arn_id = $2",
        [token_b, a_pk]
      )

      script(final: "never reached for A")
      assert :ok = perform!(run_a)

      run_a = assert_terminal!(run_a, :failed)
      assert run_a.error_kind == "transcript_unavailable"
      # Fail-closed BEFORE any decrypt: run B's goal never egressed under run A.
      assert sent_segments() == []

      # POSITIVE CONTROL: the untampered run B reveals + executes through the SAME
      # chokepoint (the refusal above is the bind catching the swap, not breakage).
      script(final: "answer B")
      assert :ok = perform!(run_b)
      run_b = assert_terminal!(run_b, :succeeded)

      assert {:ok, json} = reveal_transcript(run_b)
      assert json =~ "CANARY-bind-b3"
    end

    test "RED: a shredded run can NEVER keep executing — the worker refuses fail-honest (:transcript_unavailable)" do
      scripted_worker_config()
      s = new_scope()

      script(continue: "one", final: "two")
      assert {:ok, run} = Agent.start(Durable, s, "goal")

      assert {:ok, _} = Erasure.shred(run.id, repo: TestRepo, org_id: s.actor.org_id)

      assert :ok = perform!(run)
      run = assert_terminal!(run, :failed)
      assert run.error_kind == "transcript_unavailable"
      # Fail-closed: nothing egressed for the erased run.
      assert sent_segments() == []
    end
  end

  describe "the derived retention :shred arm (§7.4, §9#4 TAKEN — 90 days)" do
    test "default_specs/1 derives the ratified spec for the transcript-bearing run resource" do
      specs = Erasure.default_specs(resources: [Run])

      assert [spec] = specs.retention_specs
      assert spec.resource == Run
      assert spec.action == :shred
      assert spec.subject_field == :id
      assert spec.timestamp_field == :inserted_at
      assert spec.ttl_seconds == 90 * 86_400
    end

    test "RED: the sweep shreds an over-TTL run's DEK (reveal :shredded); an in-TTL run is NEVER touched (control)" do
      s = new_scope()

      script(final: "swept CANARY-retention-a2")
      assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal")

      [spec] = Erasure.default_specs(resources: [Run]).retention_specs

      # NEGATIVE CONTROL: at `now` nothing is expired — swept 0, reveal intact.
      report = Retention.sweep([spec], now: DateTime.utc_now(), repo: TestRepo)
      assert report.swept == 0
      assert {:ok, _} = reveal_transcript(run)

      # 91 days on: the run's own retention shred destroys its DEK.
      later = DateTime.add(DateTime.utc_now(), 91 * 86_400, :second)
      report = Retention.sweep([spec], now: later, repo: TestRepo)
      assert report.swept == 1
      assert {:error, :shredded} = reveal_transcript(run)
    end

    test "install_default_specs/1 merges the derived arm into :retention_specs without clobbering a host override" do
      previous = %{
        retention: Application.get_env(:samen_core, :retention_specs),
        bidx: Application.get_env(:samen_core, :blind_index_erasure_specs),
        files: Application.get_env(:samen_core, :file_erasure_specs)
      }

      on_exit(fn ->
        restore = fn key, value ->
          if value == nil,
            do: Application.delete_env(:samen_core, key),
            else: Application.put_env(:samen_core, key, value)
        end

        restore.(:retention_specs, previous.retention)
        restore.(:blind_index_erasure_specs, previous.bidx)
        restore.(:file_erasure_specs, previous.files)
      end)

      # No host entry: the derived 90d arm installs (gen.app complete by construction).
      Application.delete_env(:samen_core, :retention_specs)
      Erasure.install_default_specs(resources: [Run])
      assert [%{resource: Run, ttl_seconds: ttl}] = Application.get_env(:samen_core, :retention_specs)
      assert ttl == 90 * 86_400

      # Idempotent: a second install adds no duplicate.
      Erasure.install_default_specs(resources: [Run])
      assert [_] = Application.get_env(:samen_core, :retention_specs)

      # A host override (30d) WINS — never clobbered back to the default.
      host_spec = %{resource: Run, ttl_seconds: 30 * 86_400, action: :shred, subject_field: :id}
      Application.put_env(:samen_core, :retention_specs, [host_spec])
      Erasure.install_default_specs(resources: [Run])
      assert [%{ttl_seconds: host_ttl}] = Application.get_env(:samen_core, :retention_specs)
      assert host_ttl == 30 * 86_400
    end
  end

  # ── AgentCase.leaks?/2: the map/jsonb arm is load-bearing and non-vacuous ───────────

  describe "AgentCase.leaks?/2 scans map/jsonb values (A2 — the A1-vacuity fix)" do
    test "RED: a canary inside a map value / key / nested map IS detected; clean maps and structs are not (controls)" do
      assert Samen.AgentCase.leaks?(%{"note" => "has CANARY-map-a2 inside"}, "CANARY-map-a2")
      assert Samen.AgentCase.leaks?(%{"CANARY-key-a2" => true}, "CANARY-key-a2")
      assert Samen.AgentCase.leaks?(%{"outer" => %{"inner" => ["CANARY-deep-a2"]}}, "CANARY-deep-a2")

      refute Samen.AgentCase.leaks?(%{"note" => "clean"}, "CANARY-map-a2")
      refute Samen.AgentCase.leaks?(%Samen.Masked{token: "vt_x", label: :t}, "vt_x")
    end

    test "RED: a modeled jsonb leak on a persisted turn row is CAUGHT by assert_no_text_at_rest! (the sabotage-twin proof)" do
      s = new_scope()
      script(final: "done")
      assert {:ok, %{run: run}} = run_scripted(Durable, s, "goal")

      # POSITIVE CONTROL first: the clean run passes the scan.
      assert :ok = assert_no_text_at_rest!(run, ["CANARY-jsonb-a2"])

      # Model the leak the bounded_meta allowlist exists to prevent: a raw map value
      # carrying text lands in the jsonb column (writing AROUND the engine's filter).
      Turn
      |> Ash.Changeset.for_create(:record, %{
        org_id: s.actor.org_id,
        run_id: run.id,
        turn_index: 99,
        status: :done,
        meta: %{"note" => "leaked CANARY-jsonb-a2 text"}
      })
      |> Ash.create!(authorize?: false)

      assert_raise ExUnit.AssertionError, ~r/CANARY-jsonb-a2/, fn ->
        assert_no_text_at_rest!(run, ["CANARY-jsonb-a2"])
      end
    end

    test "bounded_meta/1 is default-deny: structs/nested/rich values are dropped, never inspect-ed (EG6)" do
      assert Agent.bounded_meta(%{"replayed" => true}) == %{"replayed" => true}
      assert Agent.bounded_meta(%{replayed: true}) == %{"replayed" => true}
      assert Agent.bounded_meta(%{"nested" => %{"deep" => "x"}}) == %{}
      assert Agent.bounded_meta(%{"exception" => %RuntimeError{message: "secret"}}) == %{}
      assert Agent.bounded_meta(%RuntimeError{message: "secret"}) == %{}
      assert Agent.bounded_meta(:not_a_map) == %{}
    end
  end

  # ── P5 (ADR-048 §8, ruling D-04): the kill-switch is RE-CHECKED at the RETRY boundary ──
  #
  # RED-FIRST. Sabotage 244 removes the TURN-boundary re-check in `Samen.AI.Agent`'s loop.
  # `P5` is that shape ONE LEVEL DOWN: inside `complete_with_recovery/10`, on the §6
  # LEVEL 2 branch (`attempt <= @max_context_retries and context_overflow?(result)`), the
  # kill-switch must be re-checked BEFORE any retry work — before `derive_fold/8` and
  # before the recursive call. The kill-switch is the emergency stop: a compaction retry
  # must not proceed, and must not spend a second provider call, after someone hit stop.
  # Today that re-check does not exist (the function's own comment says it "is P5 and is
  # deliberately NOT taken in this batch"), so the red below fails by RETRYING ANYWAY.
  describe "P5: the kill-switch re-check at the Level 2 retry boundary" do
    test "P5 RED: a kill flipped DURING the overflowing attempt stops the Level 2 retry — no second provider call, {:error, :killed, run}" do
      s = new_scope()

      # Attempt 1 overflows AND flips the operator kill in the same breath (the
      # between-turns seam sabotage 244's red uses, one level down). Entry 2 is the retry
      # that must NEVER be made.
      script([
        fn ->
          Breaker.kill(:operator)
          {:error, :context_overflow}
        end,
        {:final, "the Level 2 retry that must NEVER be made"}
      ])

      assert {:error, :killed, run} = run_scripted(Durable, s, "goal")

      run = assert_terminal!(run, :failed)
      assert run.error_kind == "killed"

      # EXACTLY ONE provider attempt: the retry never left. The UNCONSUMED entry is what
      # makes "no second provider call" refutable — a retry would have eaten it.
      assert length(sent_segments()) == 1
      assert Scripted.remaining() == [{:final, "the Level 2 retry that must NEVER be made"}]
    end

    test "P5 POSITIVE CONTROL: the SAME script WITHOUT the kill DOES retry — two provider attempts on one turn index and the run reaches its final answer" do
      s = new_scope()

      script([
        {:error, :context_overflow},
        {:final, "the Level 2 retry that must NEVER be made"}
      ])

      assert {:ok, %{answer: "the Level 2 retry that must NEVER be made", turns: 1}} =
               run_scripted(Durable, s, "goal")

      # C2's shipped Level 2 behaviour, unbroken: one original + one retry = 2 calls, on
      # ONE turn index. This is what proves the red above fails because the re-check is
      # MISSING, not because Level 2 is broken.
      assert length(sent_segments()) == 2
      assert Scripted.remaining() == []
    end
  end

  # ── D-05 (ADR-048 §8 `P8`, operator ruling D-05): the DURABLE cancel flag is re-read ──
  # ── immediately before the SUMMARIZING fold, at the LEVEL 2 INLINE `derive_fold/8` ────
  #
  # RED-FIRST. Sabotage 241 removes the TURN-boundary cancel re-check. D-05 is that shape
  # one MECHANISM over and one LEVEL down: inside `derive_fold/8`, on the `span ->` arm,
  # immediately BEFORE `summarize_span/3`. The harm the ruling names is the EGRESS, not the
  # turn — a cancelled tenant's conversation must not be shipped to the provider FOR
  # SUMMARIZATION — so RP-AG-8 is PRESERVED: the in-flight turn still completes and the run
  # still takes its terminal at the NEXT turn boundary (ARM 3 is that preservation control).
  #
  # WHY THE SCENARIO LOOKS LIKE THIS (CF-17(a)). The Level 2 INLINE fold can only SUMMARIZE
  # when the PRE-TURN fold on the same turn was REFUSED: `execute_turn/4` runs
  # `fold_context/8` first, and a pre-turn fold that SUCCEEDS either brings the context back
  # under the watermark (so the Level 2 gate is false) or folds the whole eligible span (so
  # `fold_span/6` selects nothing at Level 2). Turn 3's script therefore refuses the PRE-TURN
  # summarize call with a scripted provider error; the turn's own attempt 1 then overflows,
  # and the Level 2 branch re-derives the SAME span and DOES summarize. That refusal is also
  # how these arms tell the two `derive_fold/8` call sites apart: the turn row records the
  # PRE-TURN refusal under `compaction_refused`, so the ONE ledger entry on that turn cannot
  # have come through the pre-turn site.
  #
  # THE CHECK MUST READ DURABLE STATE. The turn boundary at `agent.ex:883` already read
  # `run.cancel_requested_at` off the struct threaded into the turn, and the cancel here is
  # issued DURING that turn's first provider call — so a Level 2 check written against the
  # in-memory `run` can never be true and would leave ARM 1 red. The flag has to be re-read
  # from the run row (`reload!/1`) at the moment of the check.

  # Turn 1's bulk segment: the only thing over the watermark, and the span both folds select.
  @d05_bulk String.duplicate("shipment manifest line. ", 100)
  @d05_short "acknowledged"
  # The model-written summary. Deliberately free of every `Ingress`/`Secrets` trigger so
  # §5#3's ingress path is the identity on it and the ledger body is byte-comparable.
  @d05_summary "Summary: the depot received seventeen crates on Tuesday."
  # Watermark: above turn 1's assembled context (~20 tokens) and above turn 4's post-fold
  # context (~51 tokens), below turns 2/3's (~620 tokens). Turn 3 is the ONLY folding turn.
  @d05_cutoff 200
  # Provider calls ARM 1 may make once D-05 ships: turn 1, turn 2, turn 3's PRE-TURN
  # summarize (refused), turn 3 attempt 1 (overflow + cancel), turn 3's retry. The SIXTH —
  # the Level 2 SUMMARIZE — is the one the check must stop.
  @d05_arm1_calls 5
  # ARM 2 adds that summarize call AND turn 4 (which does not fold: the summary shrank the
  # context back under the watermark).
  @d05_arm2_calls 7

  # The ADR-048 §4 compaction LEDGER, read out of the one sealed transcript blob.
  defp d05_folds(run) do
    run = reload(run)
    %Samen.Masked{} = masked = run.transcript
    {:ok, json} = Samen.Vault.reveal(masked, TestRepo, subject_id: run.id)
    Map.get(Jason.decode!(json), "folds", [])
  end

  # The LITERAL script. `cancel_entry` is the ONLY byte that differs between ARM 1 and
  # ARM 2 — entries 5 and 6 are identical on purpose, so whether the Level 2 summarize
  # consumes one of them cannot shift what the retry sees.
  defp d05_script(cancel_entry) do
    script([
      {:continue, @d05_bulk},
      {:continue, @d05_short},
      {:error, :provider_error},
      cancel_entry,
      {:continue, @d05_summary},
      {:continue, @d05_summary},
      {:continue, @d05_short}
    ])
  end

  defp d05_overflow, do: {:error, :context_overflow}

  # The `agent_loop_test.exs` cancel-from-inside-the-provider-callback idiom: issued while
  # turn 3's FIRST attempt is in flight, on the `state == :running` row, so the durable flag
  # lands AFTER the turn boundary loaded its struct.
  defp d05_cancelling_overflow(org_id) do
    fn ->
      [running] =
        Run
        |> Ash.Query.filter(org_id == ^org_id and state == :running)
        |> Ash.read!(authorize?: false)

      {:ok, _} = Agent.cancel(scope(org_id), running.id)
      d05_overflow()
    end
  end

  defp d05_run(s) do
    run_scripted(Durable, s, "goal", budgets: [max_turns: 4, context_cutoff_tokens: @d05_cutoff])
  end

  # The three arms' VERBATIM names, bound once so the name ExUnit registers and the name
  # the passing arms announce cannot drift apart. ExUnit's default formatter prints a name
  # only for a FAILING test, so ARM 2 and ARM 3 — which must be seen PASSING BY NAME in the
  # captured red — announce themselves, with the integers they measured, on their last line.
  @d05_arm1_name "D-05 ARM 1 RED: a cancel issued DURING the overflowing first attempt means the Level 2 SUMMARIZE call never leaves — no summarization egress and no new fold for that turn"
  @d05_arm2_name "D-05 ARM 2 POSITIVE CONTROL: the byte-identical script WITHOUT the cancel DOES summarize — a model-written fold is recorded at the LEVEL 2 INLINE site and the run makes strictly MORE provider calls"
  @d05_arm3_name "D-05 ARM 3 PRESERVATION CONTROL (RP-AG-8): the cancelled run's in-flight turn still COMPLETES and the run takes its terminal at the NEXT turn boundary"

  describe "D-05: the durable cancel flag is checked before the SUMMARIZING Level 2 fold" do
    test @d05_arm1_name do
      s = new_scope()
      org_id = s.actor.org_id
      d05_script(d05_cancelling_overflow(org_id))

      assert {:error, :cancelled, run} = d05_run(s)

      calls = length(sent_segments())

      # THE RED. Strictly fewer provider calls than ARM 2's #{@d05_arm2_calls}: the ONE the
      # cancelled run must not make is the Level 2 SUMMARIZE — the governed
      # `Samen.AI.complete/4` that ships this tenant's folded conversation to the provider.
      assert calls == @d05_arm1_calls,
             "the SUMMARIZING fold's provider call went out AFTER the tenant cancelled: " <>
               "#{calls} provider calls, expected #{@d05_arm1_calls}. D-05 requires the " <>
               "DURABLE cancel flag to be re-read immediately before summarize_span/3 at " <>
               "the LEVEL 2 INLINE derive_fold/8 site; a check on the in-memory run struct " <>
               "is vacuous here because the turn boundary already read it."

      assert calls < @d05_arm2_calls

      # And nothing was folded: `summarize_span/3` was not called, so `apply_fold!/4` was
      # not called and the ledger gains no entry for turn 3.
      assert d05_folds(run) == [],
             "a fold was recorded for a run that had already asked to stop — the Level 2 " <>
               "INLINE fold summarized after cancel"

      # The refusal is NAMED on the turn row, through the existing §5#5 machinery, with
      # D-05's bounded reason — never a new terminal and never a silent skip.
      [_t1, _t2, t3] = turn_rows(run)
      assert t3.meta["compaction_refused"] == "run_cancelled"

      # The unconsumed tail is what makes "the summarize call never left" refutable.
      assert Scripted.remaining() == [{:continue, @d05_summary}, {:continue, @d05_short}]
    end

    test @d05_arm2_name do
      s = new_scope()
      d05_script(d05_overflow())

      run = assert_honest_exhaustion!(d05_run(s))

      calls = length(sent_segments())

      # STRICTLY GREATER than ARM 1's. C2/C3's shipped Level 2 + summarizer behaviour,
      # unbroken — this is what proves ARM 1 fails because the CHECK is missing rather than
      # because nothing in this scenario ever summarizes (CF-17(a)).
      assert calls == @d05_arm2_calls
      assert calls > @d05_arm1_calls

      # The fold IS recorded, it is MODEL-WRITTEN, and its body is the summarizer's text.
      assert [fold] = d05_folds(run)
      refute fold["deterministic"] == true
      assert fold["body"] == @d05_summary
      assert fold["turn_index"] == 3

      # It came through the LEVEL 2 INLINE call site, not the PRE-TURN one: turn 3 carries
      # the Level 2 retry counter, and its PRE-TURN fold was REFUSED (named on the same row)
      # — so the one ledger entry on this turn cannot be the pre-turn fold's.
      [_t1, _t2, t3, t4] = turn_rows(run)
      assert t3.meta["context_retries"] == 1
      assert t3.status == :done
      # Turn 4 ran and did NOT fold — the summary shrank the context back under the
      # watermark — so the ONE ledger entry above is turn 3's Level 2 fold and nothing else.
      assert t4.status == :done
      refute Map.has_key?(t4.meta, "context_retries")

      IO.puts(
        "\nPASSED — " <>
          @d05_arm2_name <>
          " | ARM 2 provider calls MEASURED = #{calls}; ARM 1's asserted count = " <>
          "#{@d05_arm1_calls}; ARM 2 > ARM 1 = #{calls > @d05_arm1_calls}; " <>
          "fold body = #{inspect(fold["body"])}; deterministic = #{inspect(fold["deterministic"])}"
      )

      assert Scripted.remaining() == []
    end

    test @d05_arm3_name do
      s = new_scope()
      org_id = s.actor.org_id
      d05_script(d05_cancelling_overflow(org_id))

      assert {:error, :cancelled, run} = d05_run(s)

      run = assert_terminal!(run, :cancelled)
      assert run.error_kind == "cancelled"
      assert run.cancel_requested_at != nil

      # "Stopping after the current step", never "stopped": turn 3 — the turn the cancel
      # landed inside — is :done, and there is no turn 4. A build that "fixed" D-05 by
      # stopping the whole turn flips THIS arm from green to red.
      assert [
               %{turn_index: 1, status: :done},
               %{turn_index: 2, status: :done},
               %{turn_index: 3, status: :done}
             ] = turn_rows(run)

      IO.puts(
        "\nPASSED — " <>
          @d05_arm3_name <>
          " | terminal = {:error, :cancelled, run}; error_kind = #{inspect(run.error_kind)}; " <>
          "cancel_requested_at set = #{run.cancel_requested_at != nil}; turn rows = 3, all :done"
      )
    end
  end

  # ── D-13 (ADR-048 §8, operator ruling D-13): the BUDGET is re-checked at the LEVEL 2 ───
  # ── RETRY boundary — the last of the turn boundary's three guards to get there ────────
  #
  # RED-FIRST. The TURN boundary (`agent.ex:880` / `:904`) checks three things before every
  # turn: budget (`over_budget/2`), cancel, and the kill-switch. The RETRY boundary inside
  # `complete_with_recovery/10` checks the kill-switch (P5 / D-04, `agent.ex:1168`) and — one
  # level down, inside `derive_fold/8` — cancel (D-05, `agent.ex:1357`). BUDGET IS THE ONE
  # LEFT. So a run that has already exhausted its token budget still performs the Level 2
  # summarizing fold — since C3 a real governed `Samen.AI.complete/4` shipping this tenant's
  # conversation — and still spends the retry, noticing only at the NEXT turn boundary. That
  # is a knowing overrun of a budget the tenant set. Today that re-check does not exist, so
  # the RED below fails by FOLDING AND RETRYING ANYWAY.
  #
  # THE CHECK MUST READ DURABLE STATE — D-05's fact, one mechanism over. At the LEVEL 2 site
  # a provider call has ALREADY returned, so counters written to the run ROW during that call
  # are NOT on the `run` struct threaded into `complete_with_recovery/10`; a budget check
  # spelled against that struct can never be true and would leave this red red.
  #
  # THE TERMINAL. The retry boundary has no hand-built 3-tuple of its own: it returns
  # `{:error, reason}` in the result slot and `execute_turn/4`'s shared `{:error, reason}`
  # branch finalizes the turn row `:failed` and takes `terminal!(run, :fail, kind)` — exactly
  # what the shipped kill clause does. So the run state is `:failed` and the kind is the
  # BOUNDED atom `over_budget/2` itself returned (`:max_input_tokens` here), NEVER
  # `:budget_exhausted`: that is a run STATE, it is not an `@error_kinds` member, and it would
  # degrade to `:unknown` through `safe_error_kind/1`.
  #
  # WHY THE SCENARIO LOOKS LIKE D-05'S. The Level 2 INLINE fold can only SUMMARIZE when the
  # PRE-TURN fold on the same turn was REFUSED (CF-17(a)), so turn 3's script refuses the
  # pre-turn summarize with a scripted provider error; the turn's own attempt 1 then overflows
  # and the Level 2 branch re-derives the SAME span and DOES summarize. That is what makes
  # "no summarizing fold" a measurement rather than a vacuous truth.

  # Turn 1's bulk segment: the only thing over the watermark, and the span both folds select.
  @d13_bulk String.duplicate("shipment manifest line. ", 100)
  @d13_short "acknowledged"
  # The model-written summary, free of every `Ingress`/`Secrets` trigger.
  @d13_summary "Summary: the depot received seventeen crates on Tuesday."
  @d13_answer "the depot is clear"
  # Watermark: above turn 1's assembled context and above turn 4's post-fold context, below
  # turns 2/3's. Turn 3 is the ONLY folding turn.
  @d13_cutoff 200
  # Provider calls the RED may make once D-13 ships: turn 1, turn 2, turn 3's PRE-TURN
  # summarize (refused), turn 3 attempt 1 (overflow + the durable budget write). The FIFTH —
  # the Level 2 SUMMARIZE — and the SIXTH — the Level 2 RETRY — are the two the re-check must
  # stop. Unlike D-05's cancel, which stops only the EGRESS, an exhausted budget stops BOTH.
  @d13_red_calls 4
  # The CONTROL adds those two back AND turn 4, which does not fold (the summary shrank the
  # context back under the watermark) and carries the FINAL.
  @d13_control_calls 7

  # The LITERAL script. `overflow_entry` is the ONLY byte that differs between the RED and
  # the CONTROL.
  defp d13_script(overflow_entry) do
    script([
      {:continue, @d13_bulk},
      {:continue, @d13_short},
      {:error, :provider_error},
      overflow_entry,
      {:continue, @d13_summary},
      {:continue, @d13_short},
      {:final, @d13_answer}
    ])
  end

  defp d13_overflow, do: {:error, :context_overflow}

  # The budget is pushed DURABLY, onto the run ROW, from inside turn 3's FIRST provider call —
  # so it lands AFTER the turn boundary loaded its struct and BEFORE the retry boundary is
  # reached. `:advance` already accepts `:input_tokens_used` (`agent/run.ex:245`). No clock and
  # no `Process.sleep`: a wall-clock `deadline_seconds` race would be a flaky red.
  defp d13_exhausting_overflow(org_id) do
    fn ->
      [running] =
        Run
        |> Ash.Query.filter(org_id == ^org_id and state == :running)
        |> Ash.read!(authorize?: false)

      running
      |> Ash.Changeset.for_update(:advance, %{input_tokens_used: running.max_input_tokens + 1})
      |> Ash.update!(authorize?: false)

      d13_overflow()
    end
  end

  defp d13_run(s) do
    run_scripted(Durable, s, "goal", budgets: [max_turns: 4, context_cutoff_tokens: @d13_cutoff])
  end

  describe "D-13: the BUDGET is re-checked at the Level 2 retry boundary" do
    test "D-13 RED: a budget exhausted DURING the overflowing first attempt stops the Level 2 retry — no summarizing fold, no second provider call" do
      s = new_scope()
      org_id = s.actor.org_id
      d13_script(d13_exhausting_overflow(org_id))

      result = d13_run(s)
      calls = length(sent_segments())

      # THE RED, measured FIRST so that a failure here can never be read as a setup error:
      # the two provider calls an over-budget run must NOT make are the Level 2 SUMMARIZE
      # (the governed `Samen.AI.complete/4` shipping this tenant's folded conversation) and
      # the Level 2 RETRY itself.
      assert calls == @d13_red_calls,
             "the Level 2 summarizing fold and/or the Level 2 retry went out AFTER this " <>
               "run's token budget was exhausted: #{calls} provider calls, expected " <>
               "#{@d13_red_calls}. D-13 requires over_budget/2 to be RE-CHECKED as a cond " <>
               "arm at the retry boundary inside complete_with_recovery/10, beside the " <>
               "shipped kill-switch clause, against DURABLE run state — a check on the " <>
               "in-memory run struct is vacuous here because the turn boundary already " <>
               "read it."

      assert calls < @d13_control_calls

      # The unconsumed tail is what makes "neither call left" refutable: the summarize and
      # the retry would have eaten one scripted entry each.
      assert Scripted.remaining() == [
               {:continue, @d13_summary},
               {:continue, @d13_short},
               {:final, @d13_answer}
             ]

      # The BOUNDED kind over_budget/2 returned for this scenario, in the result slot —
      # never :budget_exhausted (a run STATE, not an @error_kinds member, and it would
      # degrade to :unknown through safe_error_kind/1).
      assert {:error, :max_input_tokens, run} = result

      # And nothing was folded: `summarize_span/3` was not called, so `apply_fold!/4` was not
      # called and the §4 ledger gains no entry for turn 3.
      assert d05_folds(run) == [],
             "a fold was recorded for a run that had already spent its token budget — the " <>
               "Level 2 INLINE fold summarized past the budget the tenant set"

      run = assert_terminal!(run, :failed)
      assert run.error_kind == "max_input_tokens"

      # The turn the overrun landed inside is finalized :failed by execute_turn/4's shared
      # {:error, reason} branch — the same path the shipped kill clause takes — and there is
      # no turn 4.
      assert [
               %{turn_index: 1, status: :done},
               %{turn_index: 2, status: :done},
               %{turn_index: 3, status: :failed}
             ] = turn_rows(run)
    end

    test "D-13 POSITIVE CONTROL: the byte-identical script WITHIN budget DOES fold and retry — two provider attempts on one turn index and the run reaches its final answer" do
      s = new_scope()
      d13_script(d13_overflow())

      # (b) THE RUN REACHES ITS FINAL ANSWER.
      assert {:ok, %{answer: @d13_answer, turns: 4, run: run}} = d13_run(s)

      calls = length(sent_segments())

      # (a) THE NUMBER OF PROVIDER ATTEMPTS — strictly greater than the RED's. C2/C3's
      # shipped Level 2 + summarizer behaviour, unbroken: this is what proves the red above
      # fails because the re-check is MISSING, not because nothing in this scenario ever
      # folds or retries.
      assert calls == @d13_control_calls
      assert calls > @d13_red_calls

      # The fold IS recorded and it is MODEL-WRITTEN (the summarizer's own text).
      assert [fold] = d05_folds(run)
      refute fold["deterministic"] == true
      assert fold["body"] == @d13_summary
      assert fold["turn_index"] == 3

      # TWO PROVIDER ATTEMPTS ON ONE TURN INDEX: turn 3 carries the Level 2 retry counter,
      # and its PRE-TURN fold was REFUSED (named on the same row), so the one ledger entry on
      # that turn came through the LEVEL 2 INLINE site and not the pre-turn one.
      [_t1, _t2, t3, t4] = turn_rows(run)
      assert t3.meta["context_retries"] == 1
      assert t3.status == :done
      assert t4.status == :done
      refute Map.has_key?(t4.meta, "context_retries")

      assert Scripted.remaining() == []
    end
  end
end
