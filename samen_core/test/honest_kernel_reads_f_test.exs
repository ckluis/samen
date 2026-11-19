defmodule Samen.HonestKernelReadsFTest do
  @moduledoc """
  Honest reads, kernel phase F. A read that FAILED must not read as a harmless value. Every RED injects a real failure
  (a table the read depends on that is genuinely gone, an unreadable key) and pairs with a positive control through the
  same seam; every report is value-free (names and exception modules only).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.AI.Agent.Breaker
  alias Samen.Automation.RunWorker
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
end
