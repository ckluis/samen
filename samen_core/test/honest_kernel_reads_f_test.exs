defmodule Samen.HonestKernelReadsFTest do
  @moduledoc """
  Honest reads, kernel phase F. A read that FAILED must not read as a harmless value. Every RED injects a real failure
  (a table the read depends on that is genuinely gone, an unreadable key) and pairs with a positive control through the
  same seam; every report is value-free (names and exception modules only).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Record
  Record.defrecordp(:span_ctx, Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl"))

  alias Samen.AI.Agent.Breaker
  alias Samen.Automation.RunWorker
  alias Samen.Replay.{Buffer, Monitor}
  alias SamenCore.Support.AutomationFixture.Workflow
  alias SamenCore.TestRepo, as: Repo

  setup do
    Samen.TestSandbox.shared!(Repo)
    :ok
  end

  # The raw message of the error `fun` raises: proof that an injected failure is real, and what a report must NOT repeat.
  defp raw_message(fun) do
    fun.()
    flunk("the read was expected to fail")
  rescue
    e in ExUnit.AssertionError -> reraise e, __STACKTRACE__
    e -> Exception.message(e)
  end

  # Take a table away INSIDE the test's sandbox transaction (DDL is transactional in Postgres, rolled back at the
  # end of the test): every read of it then fails with a real `undefined_table` database error.
  defp hide_table!(table), do: Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_hidden_by_test")

  describe "agent Breaker.check_start/2: a run log that cannot be counted is not 'under the rate limit'" do
    test "RED: an uncountable run log refuses the start {:error, :unavailable}, trips nothing, reports by name; healthy control starts" do
      org = Ash.UUID.generate()

      # POSITIVE CONTROL: the count works and is under the limit
      assert :ok = Breaker.check_start(org, "f.agent")

      hide_table!("ai_agent_run")

      raw =
        try do
          Ash.count!(Samen.AI.Agent.Run, authorize?: false)
        rescue
          e -> Exception.message(e)
        end

      assert raw =~ "ai_agent_run", "the injected failure must be a real undefined_table error naming the table"

      log = capture_log(fn -> assert {:error, :unavailable} = Breaker.check_start(org, "f.agent") end)

      assert log =~ "read=breaker_rate_count"
      refute log =~ "ai_agent_run"
      assert Breaker.kills(org) == [], "an unreadable count must not trip the kill"
    end
  end

  describe "agent Agent.cancel/2: a run that cannot be READ is not 'no such run'" do
    test "RED: a run log that cannot be read answers {:error, :unavailable} and reports; an unknown run is still :not_found (control)" do
      org = Ash.UUID.generate()
      scope = %Samen.Scope{actor: %{id: "u:#{org}", org_id: org, role: :member, plane: :tenant}}

      # POSITIVE CONTROL: the read works and the run genuinely does not exist
      assert {:error, :not_found} = Samen.AI.Agent.cancel(scope, Ash.UUID.generate())

      hide_table!("ai_agent_run")
      assert raw_message(fn -> Ash.read!(Samen.AI.Agent.Run, authorize?: false) end) =~ "ai_agent_run", "the raw error must name the table"

      log =
        capture_log(fn -> assert {:error, :unavailable} = Samen.AI.Agent.cancel(scope, Ash.UUID.generate()) end)

      assert log =~ "read=agent_cancel_load"
      refute log =~ "ai_agent_run"
    end
  end

  describe "RunWorker unreadable workflow" do
    setup do
      prev = Application.get_env(:samen_core, Samen.Automation)
      Application.put_env(:samen_core, Samen.Automation, workflow_module: Workflow, repo: Repo)

      on_exit(fn ->
        if prev, do: Application.put_env(:samen_core, Samen.Automation, prev), else: Application.delete_env(:samen_core, Samen.Automation)
      end)

      :ok
    end

    defp run_job(workflow_id, org \\ Ash.UUID.generate()) do
      %Oban.Job{args: %{"workflow_id" => workflow_id, "org_id" => org, "event_id" => Ash.UUID.generate()}, attempt: 1, max_attempts: 3}
    end

    test "RED: an unreadable workflow errors the job for a retry (it finished :ok, silently dropped) and reports; a deleted one stays :ok" do
      # POSITIVE CONTROL: the read works and the workflow genuinely does not exist
      assert :ok = RunWorker.perform(run_job(Ash.UUID.generate()))

      hide_table!("awf_workflow")
      assert raw_message(fn -> Ash.read!(Workflow, authorize?: false) end) =~ "awf_workflow", "the raw error must name the table"

      org = Ash.UUID.generate()
      log = capture_log(fn -> assert {:error, :unavailable} = RunWorker.perform(run_job(Ash.UUID.generate(), org)) end)

      assert log =~ "read=run_worker_load_workflow org=#{org} "
      refute log =~ "awf_workflow"
    end
  end

  defp workflow!(org) do
    Workflow
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      name: "wf-#{System.unique_integer([:positive])}",
      status: :active,
      trigger_kind: :resource_event,
      resource_key: "SamenCore.Support.AutomationFixture.Subject",
      event: :created,
      conditions: [],
      actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}],
      owner_id: Ash.UUID.generate()
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload_with_org!(%{id: id}) do
    require Ash.Query

    Workflow
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> hd()
  end

  describe "automation Breaker.check!/2: an uncountable run log is reported, not silently 'under the limit'" do
    test "RED: a run log that cannot be counted is reported by name, trips nothing and never raises; a readable count over the limit trips (control)" do
      prev = Application.get_env(:samen_core, :automation_rate_limit)
      Application.put_env(:samen_core, :automation_rate_limit, -1)
      on_exit(fn -> if prev, do: Application.put_env(:samen_core, :automation_rate_limit, prev), else: Application.delete_env(:samen_core, :automation_rate_limit) end)

      org = Ash.UUID.generate()

      # as the RunWorker hands it over: the row read with `org_id` selected
      wf = org |> workflow!() |> reload_with_org!()

      opts = [run_module: SamenCore.Support.AutomationFixture.Run, repo: Repo]

      hide_table!("sar_run")
      assert raw_message(fn -> Ash.count!(SamenCore.Support.AutomationFixture.Run, authorize?: false) end) =~ "sar_run", "the raw error must name the table"

      log = capture_log(fn -> assert :ok = Samen.Automation.Breaker.check!(wf, opts) end)

      assert log =~ "read=automation_breaker_count org=#{org} "
      refute log =~ "sar_run"
      assert Ash.get!(Workflow, wf.id, authorize?: false).disabled_by_operator_at == nil
    end

    test "control: the readable count over the limit trips the workflow's kill-switch" do
      prev = Application.get_env(:samen_core, :automation_rate_limit)
      Application.put_env(:samen_core, :automation_rate_limit, -1)
      on_exit(fn -> if prev, do: Application.put_env(:samen_core, :automation_rate_limit, prev), else: Application.delete_env(:samen_core, :automation_rate_limit) end)

      org = Ash.UUID.generate()

      wf = workflow!(org)

      assert :ok = Samen.Automation.Breaker.check!(wf, run_module: SamenCore.Support.AutomationFixture.Run, repo: Repo)
      assert %DateTime{} = Ash.get!(Workflow, wf.id, authorize?: false).disabled_by_operator_at
    end
  end

  describe "replay Buffer: a buffer that FAILED is not 'no replay'" do
    @marker "Secret-7731"

    # The buffer table, owned by a process of this test (the Monitor owns it in production).
    defp with_buffer! do
      {:ok, owner} = Agent.start(fn -> Buffer.create_table() end)
      on_exit(fn -> if Process.alive?(owner), do: Agent.stop(owner) end)
      :ok
    end

    defp open_session! do
      assert {:ok, id} = Buffer.open(self(), %{org_id: Ash.UUID.generate(), view: "V"}, %{max_sessions: 10, max_frames: 10, max_bytes: 10_000})
      id
    end

    # What a damaged counter row does to a real read of it: the MatchError message prints the row.
    defp corrupt_counters!(id) do
      :ets.insert(Buffer.table(), {{:ctr, id}, "counter damaged #{@marker}"})

      msg =
        try do
          [{_, _, _, _, _}] = :ets.lookup(Buffer.table(), {:ctr, id})
        rescue
          e -> Exception.message(e)
        end

      assert msg =~ @marker, "the injected failure must carry the marker the report must not repeat"
    end

    test "control: with no buffer table every function answers its quiet default and reports nothing (capture is not running)" do
      refute Buffer.table_exists?()

      log =
        capture_log(fn ->
          assert Buffer.open(self(), %{}, %{max_sessions: 1, max_frames: 1, max_bytes: 1}) == :error
          assert Buffer.session(self()) == :error
          refute Buffer.accepting?(self())
          assert Buffer.record(self(), :render, %{}) == :error
          assert Buffer.stop(self()) == :ok
          assert Buffer.take("nope") == :error
          assert Buffer.sessions() == []
        end)

      refute log =~ "replay_buffer"
    end

    test "RED: a session whose counters are damaged is {:error, :unavailable} and reports; the monitor counts it :error, never :discarded" do
      with_buffer!()

      # POSITIVE CONTROLS through the same seam: an absent session is :error / :discarded; a healthy one is taken
      assert Buffer.take("no-such-session") == :error
      assert Monitor.finalize("no-such-session", :normal) == :discarded
      healthy = open_session!()
      assert {:ok, %{}, [], %{interactions: 0}} = Buffer.take(healthy)

      id = open_session!()
      corrupt_counters!(id)

      log =
        capture_log(fn ->
          assert Buffer.take(id) == {:error, :unavailable}
        end)

      assert log =~ "read=replay_buffer"
      refute log =~ @marker

      # a second damaged session, through the monitor's finalize
      Buffer.stop(self())
      id2 = open_session!()
      corrupt_counters!(id2)
      log = capture_log(fn -> assert Monitor.finalize(id2, :normal) == :error end)
      assert log =~ "read=replay_buffer"
    end

    test "RED: a take that fails releases the session slot and its frames; the next session can open" do
      with_buffer!()
      cfg = %{max_sessions: 1, max_frames: 10, max_bytes: 10_000}

      # positive control: a healthy take releases the slot (the cap of one admits the next session)
      assert {:ok, ok_id} = Buffer.open(self(), %{view: "V"}, cfg)
      assert :ok = Buffer.record(self(), :render, %{html: "x"})
      assert {:ok, _meta, [_frame], _counters} = Buffer.take(ok_id)
      assert :ets.lookup(Buffer.table(), :sessions) == [{:sessions, 0}]

      Buffer.stop(self())
      assert {:ok, id} = Buffer.open(self(), %{view: "V"}, cfg)
      assert :ok = Buffer.record(self(), :render, %{html: "y"})
      assert :ok = Buffer.record(self(), :render, %{html: "z"})
      corrupt_counters!(id)

      capture_log(fn -> assert Buffer.take(id) == {:error, :unavailable} end)

      assert :ets.lookup(Buffer.table(), :sessions) == [{:sessions, 0}], "the failed take leaked the session slot"
      assert :ets.match_object(Buffer.table(), {{:frame, id, :_}, :_}) == [], "the failed take orphaned the session's frames"
      assert {:ok, _next} = Buffer.open(self(), %{view: "V"}, cfg)
    end

    test "RED: a damaged process row is reported by name for session/1, accepting?/1 and record/4, each still total" do
      with_buffer!()
      :ets.insert(Buffer.table(), {{:proc, self()}, "process row damaged #{@marker}"})

      log =
        capture_log(fn ->
          assert Buffer.session(self()) == :error
          refute Buffer.accepting?(self())
          assert Buffer.record(self(), :render, %{}) == :error
        end)

      assert length(Regex.scan(~r/read failed read=replay_buffer /, log)) == 2
      assert length(Regex.scan(~r/write failed write=replay_buffer /, log)) == 1
      refute log =~ @marker
    end

    test "RED: an ETS ArgumentError with the table PRESENT (a damaged counter, a non-frame row) is reported and answers the failure value; only an ABSENT table is quiet" do
      with_buffer!()

      # POSITIVE CONTROL: the same calls on healthy rows answer their healthy values and report nothing
      healthy = open_session!()

      log =
        capture_log(fn ->
          assert Buffer.record(self(), :render, %{}, true) == :ok
          assert {:ok, ^healthy} = Buffer.session(self())
          assert Buffer.sessions() == [{healthy, self()}]
        end)

      refute log =~ "replay_buffer"
      assert {:ok, _, [_], %{interactions: 1}} = Buffer.take(healthy)
      Buffer.stop(self())

      # the damaged counter row: a non-integer counter element makes update_counter raise ArgumentError, table present
      id = open_session!()
      :ets.insert(Buffer.table(), {{:ctr, id}, 0, 0, :x, 0})
      assert_raise ArgumentError, fn -> :ets.update_counter(Buffer.table(), {:ctr, id}, {4, 1}) end

      log = capture_log(fn -> assert Buffer.record(self(), :event, %{}, true) == :error end)
      assert log =~ "write=replay_buffer"

      # the damaged sessions row (open's counter)
      :ets.insert(Buffer.table(), {:sessions, :x})
      assert_raise ArgumentError, fn -> :ets.update_counter(Buffer.table(), :sessions, {2, 1}) end
      log = capture_log(fn -> assert Buffer.open(self(), %{}, %{max_sessions: 10, max_frames: 1, max_bytes: 1}) == :error end)
      assert log =~ "write=replay_buffer"
      :ets.insert(Buffer.table(), {:sessions, 0})

      # a frame row that is not a frame: take's sort raises ArgumentError (elem/2), table present. No leak refute here:
      # an ETS/elem ArgumentError message carries no value, so no marker could reach the report and such a refute could
      # not fail. The reports above are the ones that prove names-only (their exceptions print the damaged row).
      Buffer.stop(self())
      id3 = open_session!()
      :ets.insert(Buffer.table(), {{:frame, id3, 1}, "not a frame"})
      assert_raise ArgumentError, fn -> Enum.sort_by(["not a frame"], &elem(&1, 0)) end

      log = capture_log(fn -> assert Buffer.take(id3) == {:error, :unavailable} end)
      assert log =~ "read=replay_buffer"
    end

    test "RED: a telemetry event whose capture raises stays total (:ok, the handler is not detached) and is reported by name, without the event data" do
      with_buffer!()
      event = [:phoenix, :live_view, :handle_event, :start]
      bad = %{socket: "not a socket #{@marker}", event: "save", params: %{}}

      # POSITIVE CONTROL: an unrecorded process pays one lookup and reports nothing
      log = capture_log(fn -> assert :ok = Samen.Replay.Capture.handle_event(event, %{}, bad, nil) end)
      refute log =~ "replay_capture_event"

      open_session!()

      assert_raise BadMapError, ~r/#{@marker}/, fn -> apply(Map, :get, [bad.socket, :view]) end

      log = capture_log(fn -> assert :ok = Samen.Replay.Capture.handle_event(event, %{}, bad, nil) end)

      assert log =~ "write=replay_capture_event"
      refute log =~ @marker
    end
  end

  describe "observability telemetry handlers: a handler failure is total AND on record" do
    alias Samen.Observability.{JobSpans, LiveTelemetry}

    defp job_span_probe! do
      good = %{id: System.unique_integer([:positive]), worker: "W", queue: "q", attempt: 1, meta: %{}}
      bad = "not a job #{@marker}"
      assert_raise BadMapError, ~r/#{@marker}/, fn -> apply(Map, :get, [bad, :meta]) end
      {good, bad}
    end

    test "RED: a job span that cannot be started is reported by name (write), never raised, never with the job data; a well-formed job is silent (control)" do
      {good, bad} = job_span_probe!()

      # POSITIVE CONTROL: a well-formed job starts its span without a report
      log = capture_log(fn -> assert :ok = JobSpans.handle_event([:oban, :job, :start], %{}, %{job: good}, %{}) end)
      refute log =~ "job_span_"
      JobSpans.handle_event([:oban, :job, :stop], %{}, %{job: good}, %{})

      log = capture_log(fn -> assert :ok = JobSpans.handle_event([:oban, :job, :start], %{}, %{job: bad}, %{}) end)

      assert log =~ "write=job_span_start"
      refute log =~ @marker
    end

    test "RED: a job span that cannot be ended is reported by name (write), never raised, never with the job data; a well-formed job is silent (control)" do
      {good, bad} = job_span_probe!()

      # POSITIVE CONTROL: a well-formed job ends its span without a report
      JobSpans.handle_event([:oban, :job, :start], %{}, %{job: good}, %{})
      log = capture_log(fn -> assert :ok = JobSpans.handle_event([:oban, :job, :stop], %{}, %{job: good}, %{}) end)
      refute log =~ "job_span_"

      log = capture_log(fn -> assert :ok = JobSpans.handle_event([:oban, :job, :stop], %{}, %{job: bad}, %{}) end)

      assert log =~ "write=job_span_end"
      refute log =~ @marker
    end

    test "RED: a wide event that cannot be built is reported by name (write), never raised, never with the metadata; a well-formed one is silent (control)" do
      event = [:phoenix, :live_view, :mount, :stop]

      log = capture_log(fn -> assert :ok = LiveTelemetry.handle_event(event, %{duration: 1}, %{socket: %{view: __MODULE__, assigns: %{}}}, %{}) end)
      refute log =~ "live_telemetry_event"

      bad = "not metadata #{@marker}"
      assert_raise BadMapError, ~r/#{@marker}/, fn -> apply(Map, :get, [bad, :socket]) end

      log = capture_log(fn -> assert :ok = LiveTelemetry.handle_event(event, %{}, bad, %{}) end)

      assert log =~ "write=live_telemetry_event"
      refute log =~ @marker
    end

    # The wide event goes out although its pseudonym or trace ids could not be computed: a telemetry handler on the
    # event the sinks listen on proves the emission itself. The handler is GLOBAL and `assert_received` takes the first
    # matching message, so this is sound only because the module is `async: false` and nothing else emits a wide event
    # while it runs.
    defp collect_wide_events! do
      ref = make_ref()
      test = self()
      id = {__MODULE__, ref}
      :telemetry.attach(id, Samen.WideEvent.telemetry_event(), fn _e, _m, meta, _c -> send(test, {ref, meta}) end, nil)
      on_exit(fn -> :telemetry.detach(id) end)
      ref
    end

    defmodule PseudonymKms do
      def pseudonym(_subject, _subject_again), do: {:ok, "pseudonym-f-0001"}
    end

    test "RED: an actor pseudonym that cannot be computed is reported by name and the event still goes out without an actor id" do
      event = [:phoenix, :live_view, :mount, :stop]
      kms = :"Elixir.Kms#{@marker}"

      # POSITIVE CONTROL: a working KMS puts the actor id on the very same event, silently
      control_ref = collect_wide_events!()
      principal = "u-#{System.unique_integer([:positive])}"
      meta = %{socket: %{view: __MODULE__, assigns: %{samen_tenant_principal: principal}}}

      log = capture_log(fn -> assert :ok = LiveTelemetry.handle_event(event, %{}, meta, %{kms: PseudonymKms}) end)

      refute log =~ "live_telemetry_pseudonym"
      assert_received {^control_ref, %{actor_id: "pseudonym-f-0001"}}

      assert_raise UndefinedFunctionError, ~r/#{@marker}/, fn -> kms.pseudonym("p", "p") end

      ref = collect_wide_events!()
      # a second principal: the first one's pseudonym is memoized in this process
      meta = put_in(meta.socket.assigns.samen_tenant_principal, "u-#{System.unique_integer([:positive])}")

      log = capture_log(fn -> assert :ok = LiveTelemetry.handle_event(event, %{}, meta, %{kms: kms}) end)

      assert log =~ "read=live_telemetry_pseudonym"
      refute log =~ @marker
      assert_received {^ref, emitted}
      refute Map.get(emitted, :actor_id)
    end

    test "RED: a current span that cannot be read is reported by name and the event still goes out without trace ids" do
      event = [:phoenix, :live_view, :mount, :stop]
      assert_raise Protocol.UndefinedError, ~r/#{@marker}/, fn -> to_string({:damaged, @marker}) end

      ref = collect_wide_events!()

      log =
        capture_log(fn ->
          Task.async(fn ->
            :otel_tracer.set_current_span(
              span_ctx(trace_id: 1, hex_trace_id: {:damaged, @marker}, span_id: 1, hex_span_id: "0000000000000001")
            )
            assert :ok = LiveTelemetry.handle_event(event, %{}, %{socket: %{view: __MODULE__, assigns: %{}}}, %{})
          end)
          |> Task.await()
        end)

      assert log =~ "read=live_telemetry_trace"
      refute log =~ @marker
      assert_received {^ref, emitted}
      refute Map.get(emitted, :trace_id)
    end
  end
end
