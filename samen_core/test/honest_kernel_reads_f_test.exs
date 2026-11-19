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

    defp run_job(workflow_id) do
      %Oban.Job{args: %{"workflow_id" => workflow_id, "org_id" => Ash.UUID.generate(), "event_id" => Ash.UUID.generate()}, attempt: 1, max_attempts: 3}
    end

    test "RED: an unreadable workflow errors the job for a retry (it finished :ok, silently dropped) and reports; a deleted one stays :ok" do
      # POSITIVE CONTROL: the read works and the workflow genuinely does not exist
      assert :ok = RunWorker.perform(run_job(Ash.UUID.generate()))

      hide_table!("awf_workflow")

      log = capture_log(fn -> assert {:error, :unavailable} = RunWorker.perform(run_job(Ash.UUID.generate())) end)

      assert log =~ "read=run_worker_load_workflow"
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

  describe "automation Breaker.check!/2: an uncountable run log is reported, not silently 'under the limit'" do
    test "RED: a run log that cannot be counted is reported by name, trips nothing and never raises; a readable count over the limit trips (control)" do
      prev = Application.get_env(:samen_core, :automation_rate_limit)
      Application.put_env(:samen_core, :automation_rate_limit, -1)
      on_exit(fn -> if prev, do: Application.put_env(:samen_core, :automation_rate_limit, prev), else: Application.delete_env(:samen_core, :automation_rate_limit) end)

      org = Ash.UUID.generate()

      wf = workflow!(org)

      opts = [run_module: SamenCore.Support.AutomationFixture.Run, repo: Repo]

      hide_table!("sar_run")

      log = capture_log(fn -> assert :ok = Samen.Automation.Breaker.check!(wf, opts) end)

      assert log =~ "read=automation_breaker_count"
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

    test "RED: a job span that cannot be started or ended is reported by name (write), never raised, never with the job data; a well-formed job is silent (control)" do
      good = %{id: System.unique_integer([:positive]), worker: "W", queue: "q", attempt: 1, meta: %{}}
      bad = "not a job #{@marker}"

      # POSITIVE CONTROL: a well-formed job starts and ends its span without a report
      log =
        capture_log(fn ->
          assert :ok = JobSpans.handle_event([:oban, :job, :start], %{}, %{job: good}, %{})
          assert :ok = JobSpans.handle_event([:oban, :job, :stop], %{}, %{job: good}, %{})
        end)

      refute log =~ "job_span_"

      assert_raise BadMapError, ~r/#{@marker}/, fn -> apply(Map, :get, [bad, :meta]) end

      log =
        capture_log(fn ->
          assert :ok = JobSpans.handle_event([:oban, :job, :start], %{}, %{job: bad}, %{})
          assert :ok = JobSpans.handle_event([:oban, :job, :stop], %{}, %{job: bad}, %{})
        end)

      assert log =~ "write=job_span_start"
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

    test "RED: an actor pseudonym that cannot be computed and a current span that cannot be read are each reported by name; the event still goes out" do
      event = [:phoenix, :live_view, :mount, :stop]
      meta = %{socket: %{view: __MODULE__, assigns: %{samen_tenant_principal: "u-#{System.unique_integer([:positive])}"}}}
      kms = :"Elixir.Kms#{@marker}"

      log = capture_log(fn -> assert :ok = LiveTelemetry.handle_event(event, %{}, meta, %{kms: kms}) end)
      assert log =~ "read=live_telemetry_pseudonym"
      refute log =~ @marker

      assert_raise Protocol.UndefinedError, ~r/#{@marker}/, fn -> to_string({:damaged, @marker}) end

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
    end
  end
end
