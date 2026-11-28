defmodule Samen.Automation.EngineGuardsTest do
  @moduledoc """
  Engine guards of the E1 automation engine (ADR-039 §4.1, §4.5, §4.7, §7.3),
  each proven against a REAL Postgres DB through the `SamenCore.Support.AutomationFixture`
  mount. Every guarantee carries a positive control beside its refusal.

    * **Loop / depth guards (§4.7)** — a write made by a run carries `{depth, chain}`, so the
      event it captures inherits `depth + 1` and `chain ++ [workflow_id]`.
  """
  use ExUnit.Case, async: false

  require Ash.Query
  import Ash.Query

  alias SamenCore.TestRepo
  alias SamenCore.Support.AutomationFixture.{Run, Target, Workflow}

  @target_key "SamenCore.Support.AutomationFixture.Target"

  setup do
    Samen.TestSandbox.shared!(TestRepo)

    prev_auto = Application.get_env(:samen_core, Samen.Automation)
    Application.put_env(:samen_core, Samen.Automation, workflow_module: Workflow, run_module: Run, repo: TestRepo)

    on_exit(fn ->
      if prev_auto,
        do: Application.put_env(:samen_core, Samen.Automation, prev_auto),
        else: Application.delete_env(:samen_core, Samen.Automation)
    end)

    :ok
  end

  describe "loop and depth guards (ADR-039 §4.7)" do
    test "a workflow whose action writes a record that re-triggers it is refused as :loop" do
      org = Ash.UUID.generate()
      wf = create_workflow!(org, Ash.UUID.generate(), actions: [create_target_action()])

      create_target!(org, "seed", :normal)
      drain_rounds(6)

      # The seed fires one run, which writes ONE record; that record's own :created event
      # names this workflow again, so the dispatcher refuses it instead of cascading.
      assert Enum.count(targets(org)) == 2
      assert [%{state: :skipped, error_kind: :loop}] = Enum.filter(runs_for(org, wf.id), &(&1.state == :skipped))
      assert Enum.count(runs_for(org, wf.id), &(&1.state == :succeeded)) == 1
    end

    test "a chain of distinct workflows stops at the depth cap, not before it" do
      org = Ash.UUID.generate()
      prev = Application.get_env(:samen_core, :automation_max_depth)
      Application.put_env(:samen_core, :automation_max_depth, 1)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:samen_core, :automation_max_depth, prev),
          else: Application.delete_env(:samen_core, :automation_max_depth)
      end)

      # Each workflow reacts to one priority and writes the next: low -> normal -> high -> urgent.
      # Event depths: the seed 0, the normal record 1, the high record 2 (> cap 1 => refused).
      w1 = create_workflow!(org, Ash.UUID.generate(), when: "low", actions: [create_target_action("normal")])
      w2 = create_workflow!(org, Ash.UUID.generate(), when: "normal", actions: [create_target_action("high")])
      w3 = create_workflow!(org, Ash.UUID.generate(), when: "high", actions: [create_target_action("urgent")])

      create_target!(org, "seed", :low)
      drain_rounds(8)

      assert org |> targets() |> Enum.map(& &1.priority) |> Enum.sort() == [:high, :low, :normal]
      assert Enum.count(runs_for(org, w1.id), &(&1.state == :succeeded)) == 1
      assert Enum.count(runs_for(org, w2.id), &(&1.state == :succeeded)) == 1
      assert [%{depth: 2}] = Enum.filter(runs_for(org, w3.id), &(&1.error_kind == :depth_exceeded))
    end
  end

  # ---------------------------------------------------------------------------

  defp create_target_action(priority \\ "normal") do
    %{
      "kind" => "mutate_record",
      "mode" => "create",
      "resource_key" => @target_key,
      "attrs" => %{"title" => "made-by-run", "priority" => priority}
    }
  end

  defp create_workflow!(org, owner, opts) do
    conditions =
      case Keyword.get(opts, :when) do
        nil -> []
        priority -> [%{"attribute" => "priority", "op" => "eq", "values" => [priority]}]
      end

    attrs = %{
      org_id: org,
      name: "wf-#{System.unique_integer([:positive])}",
      status: :active,
      trigger_kind: :resource_event,
      resource_key: @target_key,
      event: :created,
      conditions: conditions,
      actions: Keyword.fetch!(opts, :actions),
      owner_id: owner
    }

    Workflow |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!(authorize?: false)
  end

  defp create_target!(org, title, priority) do
    Target
    |> Ash.Changeset.for_create(:create, %{org_id: org, title: title, priority: priority, email: "p@example.com"})
    |> Ash.create!(authorize?: false)
  end

  defp targets(org), do: Target |> filter(org_id == ^org) |> Ash.read!(authorize?: false)

  defp runs_for(org, workflow_id) do
    Run
    |> filter(org_id == ^org)
    |> filter(workflow_id == ^workflow_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  # A bounded drain: a cascade that the guards fail to stop must end the test, not hang it.
  defp drain_rounds(n), do: Enum.each(1..n, fn _ -> Oban.drain_queue(queue: :automation) end)
end
