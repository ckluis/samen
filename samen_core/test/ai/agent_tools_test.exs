defmodule A3TestAgents do
  @moduledoc false

  defmodule Reader do
    @moduledoc false
    use Samen.AI.Agent,
      name: "a3.reader",
      goal_prompt: "Use your tools to answer. Reply FINAL: <answer> when done.",
      tools: ["search_records", "fetch_record"]
  end

  defmodule SearchOnly do
    @moduledoc false
    use Samen.AI.Agent,
      name: "a3.search-only",
      goal_prompt: "Use your tools to answer. Reply FINAL: <answer> when done.",
      tools: ["search_records"]
  end
end

defmodule Samen.AI.AgentToolsTest do
  @moduledoc """
  ADR-047 batch A3 — the tool surface: read tools + EG2 scrubbing.

    * **The four-way narrowing intersection (§5.1, RP-AG-4)** — registry ∩ per-action
      `tool_schema/0` opt-in (default `:not_a_tool`) ∩ the agent definition's declared
      list ∩ the owner actor's policy envelope. One red per arm, each with a positive
      control; NO shipped ADR-039 action is a tool (proven over all 8). Sabotage 249
      (allowlist escape) flips the arm-3 red here.
    * **EG2 half one — tool DEFS (§4.2, RP-AG-1)**: defs ride `%MaskedPayload{}.tools`,
      scrubbed by `safe_metadata?/1` AND membership-checked against the byte-exact
      static `tool_schema/0` constants — a runtime-composed or canary-bearing def
      REFUSES `{:error, :pii_egress_refused}`. Sabotage 246 flips the reds here.
    * **EG2 half two — call echo + result re-entry (§4.3, RP-AG-2/RP-AG-3)**: echo +
      results re-enter ONLY as `ToolResult`-rendered, PiiResolution-EGRESS-resolved
      binaries through `:history`; vault-routed fields render `••••` on the AI plane
      (refutable: the tenant-plane NON-egress control genuinely resolves plaintext);
      `safe_segment?/1` is the fail-closed last line (a raw structured history entry
      refuses). Sabotages 247 (raw re-entry) and 248 (egress-mode drop) flip the
      named tests here. Shipped sabotages 44/45 re-proven on the agent path: a
      model-emitted `vt_*` tool ARG is refused BEFORE execution.
    * **Governed execution**: the action runs AS the owner actor (arm 4 — OrgScope:
      a foreign org's record does not exist, RP-AG-10); every refusal is recorded
      honestly on the bounded turn row and fed back, never silently skipped.
    * **Live `max_tool_calls` exhaustion (§6, RP-AG-6)** — fail-honest terminal.
    * **The decision stamp (§4.1, RP-AG-7)** — tool_kind + arg key names + the
      validated-args sha256 digest committed on the `{run_id, turn_index}` row.

  Anti-tautology: every red assertion is paired with a positive control.
  """
  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias A3TestAgents.{Reader, SearchOnly}
  alias Samen.AI.Agent
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.ToolResult
  alias Samen.AI.Agent.Tools
  alias Samen.AI.Chokepoint
  alias Samen.AI.Completion
  alias Samen.AI.Embeddings
  alias Samen.AI.MaskedPayload
  alias Samen.AI.Provider.Scripted
  alias Samen.Api.PiiResolution
  alias Samen.Automation.Action
  alias SamenCore.Support.AutomationFixture.Subject
  alias SamenCore.Support.EmbeddingsDomain.Article
  alias SamenCore.TestRepo

  require Ash.Query

  @subject_key "SamenCore.Support.AutomationFixture.Subject"
  @email_canary "canary-agent-tool-3f9k@leak.example"
  @title_canary "TITLE-CANARY-plaintext-pii-a3"
  @vt_token "vt_" <> String.duplicate("b", 32)
  @mask Samen.Masked.mask()

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

  defp scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp new_scope, do: scope(Ash.UUID.generate())

  defp create_subject!(org_id, attrs \\ []) do
    Subject
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      title: Keyword.get(attrs, :title, @title_canary),
      priority: Keyword.get(attrs, :priority, :high),
      status: Keyword.get(attrs, :status, :open),
      email: Keyword.get(attrs, :email, @email_canary)
    })
    |> Ash.create!(authorize?: false)
  end

  defp fetch_call(subject_id) do
    {:tool_call, "fetch_record", %{"resource" => @subject_key, "id" => subject_id}}
  end

  defp all_sent_text, do: sent_texts() |> Enum.join("\n")

  # ── the four-way intersection (§5.1; RP-AG-4) ───────────────────────────────────────

  describe "the four-way intersection: registry ∩ opt-in ∩ declared ∩ policy envelope" do
    test "NO shipped ADR-039 action is a tool by accident — all 8 are :not_a_tool AND :write; only the two A3 read actions opt in" do
      legacy = [
        "notify",
        "send_email",
        "mutate_record",
        "assign_owner",
        "add_tag",
        "escalate",
        "webhook",
        "enqueue_reminder"
      ]

      for kind <- legacy do
        mod = Action.module_for(kind)
        assert mod != nil

        assert Action.tool_schema_for(mod) == :not_a_tool,
               "#{kind} must NOT be a tool without an explicit tool_schema/0 opt-in"

        assert Action.effect_for(mod) == :write,
               "#{kind} must default to :write (approval-gated) — fail-closed"
      end

      # The whole opted-in surface, exactly (arm 2 is an allowlist, not a heuristic).
      assert Action.tool_kinds() == ["fetch_record", "search_records"]
      assert length(Tools.static_defs()) == 2

      # And the two read actions declare BOTH faces explicitly.
      for kind <- ["search_records", "fetch_record"] do
        mod = Action.module_for(kind)
        assert is_map(Action.tool_schema_for(mod))
        assert Action.effect_for(mod) == :read
      end
    end

    test "RED (arm 3 — sabotage 249's target): a registered, opted-in tool OUTSIDE the agent's declared list is refused, recorded honestly, and NEVER executes" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      # fetch_record IS in the registry and IS opted in — but SearchOnly did not declare
      # it. The model calls it anyway (untrusted output): the per-call intersection
      # re-check must refuse, record, feed back — and continue the run.
      script([
        fetch_call(subject.id),
        {:final, "gave up on the undeclared tool"}
      ])

      assert {:ok, %{answer: "gave up on the undeclared tool", run: run}} =
               run_scripted(SearchOnly, s, "look at the record")

      # The HONEST refusal record (never a silent skip): bounded kind + the requested
      # registry kind on the turn row.
      assert [t1, _t2] = turn_rows(run)
      assert t1.status == :done
      assert t1.tool_kind == "fetch_record"
      assert t1.error_kind == "tool_refused"

      # The bounded feedback line reached the model on the next turn...
      assert_history_accumulated!(2, ["tool_error: tool_refused"])

      # ...and the tool NEVER executed: no record content in any payload, and the
      # refused call never counted against the tool budget.
      refute all_sent_text() =~ "record: "
      refute all_sent_text() =~ "priority:"
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 0
    end

    test "POSITIVE CONTROL (arms 1-3 green): the SAME call on an agent that DECLARED fetch_record executes and renders the record" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      script([fetch_call(subject.id), {:final, "found it"}])

      assert {:ok, %{answer: "found it", run: run}} = run_scripted(Reader, s, "look it up")

      assert [t1, _t2] = turn_rows(run)
      assert t1.tool_kind == "fetch_record"
      assert t1.error_kind == nil
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 1

      # The rendered result re-entered as history on turn 2 (the engaged EG2 path).
      text = all_sent_text()
      assert text =~ "record: SamenCore.Support.AutomationFixture.Subject##{subject.id}"
      assert text =~ "priority: high"
      assert text =~ "status: open"
    end

    test "RED (arm 4 — the actor's policy envelope): a FOREIGN org's record does not exist for the run's owner — honest :record_not_found, recorded and fed back" do
      s = new_scope()
      foreign = create_subject!(Ash.UUID.generate())

      script([fetch_call(foreign.id), {:final, "nothing there"}])

      assert {:ok, %{answer: "nothing there", run: run}} =
               run_scripted(Reader, s, "cross-org probe")

      assert [t1, _t2] = turn_rows(run)
      assert t1.tool_kind == "fetch_record"
      assert t1.error_kind == "record_not_found"
      assert_history_accumulated!(2, ["tool_error: record_not_found"])

      # RP-AG-10: nothing of the foreign RECORD — eligible values or masked shape —
      # ever reached the provider (the model's own arg ECHO legitimately round-trips;
      # the record's content does not exist for this scope).
      refute all_sent_text() =~ "record: "
      refute all_sent_text() =~ "priority:"
      refute all_sent_text() =~ "email:"
    end

    test "POSITIVE CONTROL (arm 4): the same-org record resolves for the same owner actor (the refusal above is OrgScope, not breakage)" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      script([fetch_call(subject.id), {:final, "ok"}])
      assert {:ok, %{run: run}} = run_scripted(Reader, s, "same-org read")
      assert [%{error_kind: nil}, _] = turn_rows(run)
      assert all_sent_text() =~ subject.id
    end

    test "RED (arm 1 at call time): an UNREGISTERED kind from the model is refused with tool_kind NOT persisted (an arbitrary model string never lands in a column)" do
      s = new_scope()

      script([
        {:tool_call, "drop_all_tables", %{}},
        {:final, "declined"}
      ])

      assert {:ok, %{run: run}} = run_scripted(Reader, s, "goal")

      assert [t1, _t2] = turn_rows(run)
      assert t1.error_kind == "tool_refused"
      assert t1.tool_kind == nil
      assert_no_text_at_rest!(run, ["drop_all_tables"])
    end
  end

  # ── EG2 half one: tool DEFS on %MaskedPayload{}.tools (§4.2; RP-AG-1) ───────────────

  describe "EG2 tool DEFS: compile-time static, chokepoint-scrubbed, count-only Inspect" do
    test "the loop offers EXACTLY the resolved static defs on EVERY turn's sealed payload" do
      s = new_scope()
      script(continue: "thinking", final: "done")

      assert {:ok, _} = run_scripted(SearchOnly, s, "goal")

      search_def = Action.tool_schema_for(Action.module_for("search_records"))

      assert sent_tool_defs() == [[search_def], [search_def]],
             "every turn's payload must carry the agent's resolved tool defs — no more, no fewer"
    end

    test "RED: a RUNTIME-COMPOSED tool def is REFUSED fail-closed — even a clean-looking one (the §4.2 static-schema rule)" do
      composed = %{
        name: "search_records",
        description: "looks legitimate but was assembled at runtime",
        params: [%{name: "query", type: "string", required: true, description: "q"}]
      }

      assert Chokepoint.seal(:complete, ["x"], tools: [composed]) ==
               {:error, :pii_egress_refused}
    end

    test "RED: a canary/vt_-bearing tool definition is REFUSED fail-closed, never egressed" do
      for poisoned <- [
            %{name: "evil", description: "live enum: #{@email_canary}", params: []},
            %{name: "evil", description: "token #{@vt_token}", params: []},
            # a def that is not even a map
            [:not, :a, :map],
            # a struct posing as a def
            DateTime.utc_now()
          ] do
        assert Chokepoint.seal(:complete, ["x"], tools: [poisoned]) ==
                 {:error, :pii_egress_refused},
               "a non-static/poisoned tool def must refuse: #{inspect(poisoned)}"
      end

      # And a non-list :tools opt refuses outright.
      assert Chokepoint.seal(:complete, ["x"], tools: %{sneaky: true}) ==
               {:error, :pii_egress_refused}

      assert Scripted.sent_payloads() == []
    end

    test "POSITIVE CONTROL: the registered byte-exact static defs seal (the refusals above are the membership check, not breakage)" do
      assert {:ok, %MaskedPayload{} = payload} =
               Chokepoint.seal(:complete, ["x"], tools: Tools.static_defs())

      assert payload.tools == Tools.static_defs()

      # EG6: the Inspect redaction renders only the tool COUNT — never names/descriptions.
      rendered = inspect(payload)
      assert rendered =~ "tools: 2"
      refute rendered =~ "search_records"
      refute rendered =~ "fetch_record"
    end
  end

  # ── EG2 half two: echo + result re-entry (§4.3; RP-AG-2/3; sabotages 44/45 re-proof) ─

  describe "EG2 re-entry: rendered binaries only, ••••-masked, safe_segment? last line" do
    test "a fetch_record turn re-enters ONLY as rendered binaries — echo + result survive the §3.2a re-scrub and the run completes" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      script([fetch_call(subject.id), {:continue, "reading the result"}, {:final, "done"}])

      assert {:ok, %{answer: "done", run: run}} = run_scripted(Reader, s, "look it up")
      assert run.current_turn == 3

      # Turn 2's payload carries the RENDERED echo + result lines as ordinary history
      # segments (each a plain binary — the §3.2a re-scrub + step-3/4 allowlist ran
      # over every one, every turn).
      echo = "tool_call: fetch_record id=#{subject.id} resource=#{@subject_key}"

      assert_history_accumulated!(2, [
        echo,
        "record: SamenCore.Support.AutomationFixture.Subject##{subject.id}",
        "priority: high",
        "status: open",
        "email: " <> @mask
      ])

      # RP-AG-3's property on the tool path: every segment of every payload is a plain
      # binary — no raw arg map, no record struct, no grant span, no vt_.
      assert_masked_only_payloads!()

      # And nothing of the result text is at rest outside the DEK envelope.
      assert_no_text_at_rest!(run, ["priority: high", @email_canary])
      assert_transcript_vaulted_at_rest!(run, [@email_canary])
    end

    test "RED (sabotage 248's target): a vault-routed field in a tool result renders •••• on the AI plane — never plaintext, never vt_ (refutable)" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      # REFUTABILITY CONTROL first: on the tenant plane the NON-egress resolution
      # genuinely resolves the canary plaintext (the tenant owns its org's PII) — so
      # the ONLY thing keeping it out of the payloads below is the renderer's
      # egress-mode resolution (egress: true, grant_egress?: false — §4.4).
      [loaded] =
        Subject
        |> Ash.Query.filter(id == ^subject.id)
        |> Ash.Query.ensure_selected([:email])
        |> Ash.read!(authorize?: false)

      [clear] = PiiResolution.resolve([loaded], Subject, %{plane: :tenant}, repo: TestRepo)

      assert clear.email == @email_canary

      script([fetch_call(subject.id), {:final, "answered"}])
      assert {:ok, %{run: run}} = run_scripted(Reader, s, "who is on this record?")

      text = all_sent_text()
      assert text =~ "email: " <> @mask, "the vault field must be present-but-masked"
      refute text =~ @email_canary, "EG2 leak: vault plaintext reached the provider"
      refute text =~ "vt_", "EG2 leak: a vault token reached the provider"

      # Mask-by-OMISSION for the plaintext-PII freeform column: `title` is not
      # condition-eligible, so it is not even present to render.
      refute text =~ @title_canary
      refute text =~ "title:"

      # ... and none of it is at rest outside the envelope either.
      assert_no_text_at_rest!(run, [@email_canary, @title_canary])
    end

    test "RED (§4.4 on tool results): even the grant_plaintext_egress host flag cannot admit plaintext into an agent tool result" do
      previous = Application.get_env(:samen_core, Samen.AI, [])

      Application.put_env(
        :samen_core,
        Samen.AI,
        Keyword.put(previous, :grant_plaintext_egress, true)
      )

      on_exit(fn -> Application.put_env(:samen_core, Samen.AI, previous) end)

      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      script([fetch_call(subject.id), {:final, "still masked"}])
      assert {:ok, _} = run_scripted(Reader, s, "goal")

      assert all_sent_text() =~ "email: " <> @mask
      refute all_sent_text() =~ @email_canary
    end

    test "RED (shipped sabotage 45 re-proven on the agent path): a model-emitted vt_* tool ARG is refused BEFORE execution — nothing egresses, nothing lands at rest" do
      s = new_scope()

      script([
        {:tool_call, "fetch_record", %{"resource" => @subject_key, "id" => @vt_token}},
        {:final, "declined the token"}
      ])

      assert {:ok, %{run: run}} = run_scripted(Reader, s, "goal")

      # Refused at the arg gate (bounded), recorded honestly, fed back bounded.
      assert [t1, _t2] = turn_rows(run)
      assert t1.error_kind == "invalid_args"
      assert t1.tool_kind == "fetch_record"
      assert_history_accumulated!(2, ["tool_error: invalid_args"])

      # The token itself never egressed on ANY turn and never landed at rest.
      refute all_sent_text() =~ "vt_"
      assert_no_text_at_rest!(run, [@vt_token])
      assert_transcript_vaulted_at_rest!(run, [String.slice(@vt_token, 3..-1//1)])
    end

    test "the last line (§4.3#5, shipped sabotage 44/45 substrate): a RAW structured history entry refuses at the chokepoint — the renderer is defense, the allowlist is the guarantee" do
      # What sabotage 247 models: a renderer regression re-entering raw shapes. The
      # chokepoint refuses them fail-closed — this is why the sabotaged loop FAILS
      # (:pii_egress_refused) instead of leaking.
      for raw <- [
            %{"contact_email" => @vt_token},
            {:tool_result, @vt_token},
            [{:record, "x"}],
            %Embeddings.Hit{source_resource: "R", source_id: "1", field: "f", distance: 0.0}
          ] do
        assert Chokepoint.seal(:complete, ["turn N+1"], history: [raw]) ==
                 {:error, :pii_egress_refused},
               "a raw structured history entry must refuse: #{inspect(raw)}"
      end
    end
  end

  # ── the TOOL: text-envelope fallback grammar (§5.2, §10 deferred spelling) ──────────

  describe "the bounded TOOL: JSON envelope + native tool_calls priority" do
    test "parse_next/1: FINAL unchanged; TOOL parses the closed shape; everything malformed is a bounded :invalid_tool_call" do
      assert Agent.parse_next("FINAL: done") == {:final, "done"}
      assert Agent.parse_next("just thinking") == {:continue, "just thinking"}

      assert Agent.parse_next(~s(TOOL: {"tool": "search_records", "args": {"query": "late"}})) ==
               {:tool, "search_records", %{"query" => "late"}}

      # args defaults to {}.
      assert Agent.parse_next(~s(TOOL: {"tool": "fetch_record"})) == {:tool, "fetch_record", %{}}

      for malformed <- [
            "TOOL: not json at all",
            ~s(TOOL: {"tool": 42}),
            ~s(TOOL: {"tool": "x", "args": "not-an-object"}),
            ~s(TOOL: {"tool": "x", "args": {}, "extra": true}),
            ~s(TOOL: {"args": {}})
          ] do
        assert Agent.parse_next(malformed) == {:tool_error, :invalid_tool_call},
               "must refuse bounded: #{malformed}"
      end
    end

    test "next_step/1: ONE native call wins over text; more than one is refused honestly; empty falls back to the text grammar" do
      native = %Completion{text: "commentary", tool_calls: [%{"name" => "fetch_record", "args" => %{"id" => "x"}}]}
      assert Agent.next_step(native) == {:tool, "fetch_record", %{"id" => "x"}}

      two = %Completion{text: "", tool_calls: [%{"name" => "a"}, %{"name" => "b"}]}
      assert Agent.next_step(two) == {:tool_error, :invalid_tool_call}

      malformed = %Completion{text: "", tool_calls: [%{"nom" => "a"}]}
      assert Agent.next_step(malformed) == {:tool_error, :invalid_tool_call}

      assert Agent.next_step(%Completion{text: "FINAL: x"}) == {:final, "x"}
    end

    test "integration: the TEXT envelope drives a real tool turn (the adapter-without-native-tool-use path)" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      envelope =
        ~s(TOOL: {"tool": "fetch_record", "args": {"resource": "#{@subject_key}", "id": "#{subject.id}"}})

      script([{:continue, envelope}, {:final, "done via text"}])

      assert {:ok, %{answer: "done via text", run: run}} = run_scripted(Reader, s, "goal")
      assert [%{tool_kind: "fetch_record", error_kind: nil}, _] = turn_rows(run)
      assert all_sent_text() =~ "record: SamenCore.Support.AutomationFixture.Subject#"
    end

    test "integration: a MALFORMED envelope is a fail-honest bounded feedback turn — never a raise, never a silent continue" do
      s = new_scope()

      script([{:continue, "TOOL: {broken"}, {:final, "recovered"}])

      assert {:ok, %{answer: "recovered", run: run}} = run_scripted(Reader, s, "goal")
      assert [%{error_kind: "invalid_tool_call", tool_kind: nil}, _] = turn_rows(run)
      assert_history_accumulated!(2, ["tool_error: invalid_tool_call"])
    end
  end

  # ── live max_tool_calls exhaustion (§6; RP-AG-6 on the tool budget) ─────────────────

  describe "max_tool_calls is live: exhaustion is fail-honest, refusals do not count" do
    test "RED: the run exhausts AT the tool-call budget — terminal :budget_exhausted, never a partial answer, turn 3's tool never fires" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      script([
        fetch_call(subject.id),
        fetch_call(subject.id),
        fetch_call(subject.id),
        {:final, "the real answer"}
      ])

      result = run_scripted(Reader, s, "hard goal", budgets: [max_tool_calls: 2])

      run = assert_honest_exhaustion!(result)
      assert run.error_kind == "max_tool_calls"
      assert run.tool_calls_used == 2
      assert run.current_turn == 2

      # Exactly two tool turns executed; the third call + the final are unconsumed.
      assert [_, _] = turn_rows(run)
      assert length(Scripted.remaining()) == 2
    end

    test "POSITIVE CONTROL: the SAME script under the default budget runs all three tools to the real answer" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      script([
        fetch_call(subject.id),
        fetch_call(subject.id),
        fetch_call(subject.id),
        {:final, "the real answer"}
      ])

      assert {:ok, %{answer: "the real answer", run: run}} = run_scripted(Reader, s, "hard goal")
      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 3
    end

    test "a REFUSED call never feeds the tool budget (the counter counts governed executions, not attempts)" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      # fetch_record is undeclared on SearchOnly ⇒ refused, not counted — so a budget
      # of 1 still admits the one real search-free final.
      script([fetch_call(subject.id), {:final, "done"}])

      assert {:ok, %{run: run}} =
               run_scripted(SearchOnly, s, "goal", budgets: [max_tool_calls: 1])

      assert Ash.get!(Run, run.id, authorize?: false).tool_calls_used == 0
    end
  end

  # ── the decision stamp: idempotency columns written for real (§4.1; RP-AG-7) ────────

  describe "the tool DECISION stamp on the {run_id, turn_index} row" do
    test "tool_kind + sorted arg key NAMES + the validated-args sha256 digest are stamped; values are NOT" do
      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      script([fetch_call(subject.id), {:final, "ok"}])
      assert {:ok, %{run: run}} = run_scripted(Reader, s, "goal")

      assert [t1, _t2] = turn_rows(run)
      assert t1.tool_kind == "fetch_record"
      assert t1.arg_keys == ["id", "resource"]

      expected_digest =
        Agent.args_digest(%{"resource" => @subject_key, "id" => subject.id})

      assert t1.meta["args_digest"] == expected_digest
      assert String.match?(t1.meta["args_digest"], ~r/\A[0-9a-f]{64}\z/)

      # Token-only stays token-only: the arg VALUES are not on the row.
      assert_no_text_at_rest!(run, [subject.id])
    end

    test "the worker path drives the SAME tool discipline cross-process (durable mode parity)" do
      previous = Application.get_env(:samen_core, Samen.AI.Agent, [])

      Application.put_env(
        :samen_core,
        Samen.AI.Agent,
        Keyword.merge(previous, provider: scripted_provider())
      )

      on_exit(fn -> Application.put_env(:samen_core, Samen.AI.Agent, previous) end)

      s = new_scope()
      subject = create_subject!(s.actor.org_id)

      script([fetch_call(subject.id), {:final, "durable done"}])

      assert {:ok, run} = Agent.start(Reader, s, "goal")

      assert :ok =
               Samen.AI.Agent.TurnWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

      run = assert_terminal!(run, :succeeded)
      assert run.tool_calls_used == 1
      assert [%{tool_kind: "fetch_record", status: :done}, _] = turn_rows(run)
      assert all_sent_text() =~ "record: SamenCore.Support.AutomationFixture.Subject#"
      assert_masked_only_payloads!()
    end
  end

  # ── search_records (the semantic + tsvector read tool) ──────────────────────────────

  describe "search_records: org-scoped, honest about each arm" do
    test "validate/2 is default-deny: unknown keys, empty/huge queries, and out-of-range limits refuse" do
      mod = Action.module_for("search_records")

      assert {:ok, %{"query" => "late shipment", "limit" => 5}} =
               mod.validate(%{"query" => "late shipment"}, nil)

      assert {:error, :invalid_args} = mod.validate(%{"query" => "x", "sneaky" => true}, nil)
      assert {:error, :invalid_query} = mod.validate(%{"query" => "   "}, nil)
      assert {:error, :invalid_query} = mod.validate(%{"query" => String.duplicate("q", 501)}, nil)
      assert {:error, :invalid_limit} = mod.validate(%{"query" => "x", "limit" => 0}, nil)
      assert {:error, :invalid_limit} = mod.validate(%{"query" => "x", "limit" => 21}, nil)
      assert {:error, :invalid_config} = mod.validate("not a map", nil)
    end

    test "an agent run searches its OWN org's vectors, renders bounded hit lines, and reports the unwired text arm honestly" do
      s = new_scope()
      other_org = Ash.UUID.generate()

      mine = struct(Article, id: Ash.UUID.generate(), body: "the quick brown fox jumps the lazy dog")
      foreign = struct(Article, id: Ash.UUID.generate(), body: "the quick brown fox jumps the lazy dog")

      assert {:ok, 1} = Embeddings.embed_record(s, mine, Article, repo: TestRepo)
      assert {:ok, 1} = Embeddings.embed_record(scope(other_org), foreign, Article, repo: TestRepo)

      script([
        {:tool_call, "search_records", %{"query" => "quick brown fox"}},
        {:final, "found the article"}
      ])

      assert {:ok, %{answer: "found the article", run: run}} =
               run_scripted(Reader, s, "find the fox article")

      assert [%{tool_kind: "search_records", error_kind: nil}, _] = turn_rows(run)

      text = all_sent_text()

      # The echo (of the VALIDATED, limit-defaulted args) + rendered hit lines
      # re-entered as history (bounded binaries).
      assert text =~ "tool_call: search_records limit=5 query=quick brown fox"
      assert text =~ "hit:"
      assert text =~ mine.id
      assert text =~ "semantic_search: ok"

      # The tsvector arm is UNWIRED in samen_core tests — reported honestly, never a
      # fabricated "searched" claim.
      assert text =~ "text_search: not_configured"

      # RP-AG-10 / §7.3: the foreign org's vector was never even ranked.
      refute text =~ foreign.id

      assert_masked_only_payloads!()
    end

    test "an org-less actor cannot search (fail-closed :no_org at the action layer)" do
      mod = Action.module_for("search_records")

      ctx = %Samen.Automation.Context{
        org_id: Ash.UUID.generate(),
        workflow_id: nil,
        subject_ref: "samen:test",
        actor: %Samen.Scope{actor: %{id: "u", role: :member}},
        origin: {:agent, "r"}
      }

      assert {:error, :no_org} = mod.run(%{"query" => "x", "limit" => 5}, ctx)
    end
  end

  # ── fetch_record unit gates ─────────────────────────────────────────────────────────

  describe "fetch_record: default-deny args + fail-closed resource resolution" do
    test "validate/2 refuses unknown keys, non-UUID ids, and oversized resource keys" do
      mod = Action.module_for("fetch_record")
      id = Ash.UUID.generate()

      assert {:ok, %{"resource" => @subject_key, "id" => ^id}} =
               mod.validate(%{"resource" => @subject_key, "id" => id}, nil)

      assert {:error, :invalid_args} =
               mod.validate(%{"resource" => @subject_key, "id" => id, "x" => 1}, nil)

      assert {:error, :invalid_id} = mod.validate(%{"resource" => @subject_key, "id" => "42"}, nil)
      assert {:error, :invalid_resource} = mod.validate(%{"resource" => "", "id" => id}, nil)

      assert {:error, :invalid_resource} =
               mod.validate(%{"resource" => String.duplicate("A", 201), "id" => id}, nil)
    end

    test "an UNRESOLVABLE resource key is an honest :unknown_resource fed back to the model (default-deny)" do
      s = new_scope()

      script([
        {:tool_call, "fetch_record", %{"resource" => "No.Such.Resource", "id" => Ash.UUID.generate()}},
        {:final, "cannot"}
      ])

      assert {:ok, %{run: run}} = run_scripted(Reader, s, "goal")
      assert [%{error_kind: "unknown_resource", tool_kind: "fetch_record"}, _] = turn_rows(run)
      assert_history_accumulated!(2, ["tool_error: unknown_resource"])
    end
  end

  # ── the agent-origin Automation.Context (§5.1) ──────────────────────────────────────

  describe "Samen.AI.Agent.Context.build/2: the ONE agent-origin constructor" do
    test "carries {:agent, run_id} provenance, a nil workflow_id, and the owner scope — additively (a workflow context is unaffected)" do
      s = new_scope()
      script(final: "x")
      assert {:ok, %{run: run}} = run_scripted(Reader, s, "goal")
      run = Ash.get!(Run, run.id, authorize?: false, load: [])

      run =
        Run
        |> Ash.Query.filter(id == ^run.id)
        |> Ash.Query.ensure_selected([:org_id])
        |> Ash.read!(authorize?: false)
        |> hd()

      ctx = Samen.AI.Agent.Context.build(run, s)

      assert ctx.origin == {:agent, run.id}
      assert ctx.workflow_id == nil
      assert ctx.run_id == run.id
      assert ctx.subject_ref == "samen:arn:#{run.id}"
      assert ctx.actor == s
      assert ctx.depth == 0 and ctx.chain == []

      # Additive: a workflow-shaped context still constructs with origin defaulting nil.
      wf_ctx = %Samen.Automation.Context{org_id: "o", workflow_id: "w", subject_ref: "s"}
      assert wf_ctx.origin == nil
    end
  end

  # ── ToolResult unit floor (never inspect; bounded error rendering) ──────────────────

  describe "ToolResult: bounded rendering, never inspect/1" do
    test "unrecognized values render the bounded [unrenderable:<key>] marker — never their contents" do
      lines =
        ToolResult.render(
          {:ok, %{kind: :fetch_record, weird: {:tuple, "SECRET-in-tuple"}, pid: self()}},
          actor: %{}
        )

      joined = Enum.join(lines, "\n")
      assert joined =~ "[unrenderable:weird]"
      assert joined =~ "[unrenderable:pid]"
      refute joined =~ "SECRET-in-tuple"
    end

    test "an {:error, kind} outcome renders ONE bounded tool_error line; a rich error degrades" do
      assert ToolResult.render({:error, :record_not_found}, []) == ["tool_error: record_not_found"]
      assert ToolResult.render({:error, {:rich, "SECRET"}}, []) == ["tool_error: tool_failed"]
      assert ToolResult.render(:garbage, []) == ["tool_error: tool_failed"]
    end

    test "render_call/2 renders kind + sorted scalar args as ONE binary — never the raw map" do
      line = ToolResult.render_call("fetch_record", %{"resource" => "R", "id" => "1"})
      assert line == "tool_call: fetch_record id=1 resource=R"
      assert is_binary(ToolResult.render_call("x", %{"nested" => %{"deep" => "v"}}))
      assert ToolResult.render_call("x", %{"nested" => %{}}) =~ "[unrenderable:nested]"
    end
  end
end
