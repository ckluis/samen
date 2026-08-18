defmodule Samen.Automation.WorkflowTest do
  @moduledoc """
  T39 — the E1 automation engine (ADR-039 §3/§4/§8). Exercised end-to-end against a
  REAL Postgres DB via the `awf`/`asj` `SamenCore.Support.AutomationFixture` mount:
  capture → dispatch → run → condition AND-gate → the `notify` action (recorded as a
  `NotificationFixture.Notification`, the observable side-effect).

  Every guarantee has a green path AND a discriminating/red twin (`Samen.RedPath`
  anti-tautology discipline):

    * **resource-event trigger** fires on a matching create/update; a **non-matching
      condition** does NOT fire (the control).
    * **schedule trigger** fires via the AshOban `:schedule_scan` trigger at cron time
      (time-travel: `next_fire_at` in the past).
    * **INV-1 write-time refusal (c2)** — a condition keyed on a vault-routed field is
      refused at Workflow WRITE; the non-PII control saves cleanly.
    * **org isolation** — a cross-org event never fires another org's rule.
    * **catalog registration** — the new resource is catalogued (`tam_table`).
  """
  use ExUnit.Case, async: false

  require Ash.Query
  import Ash.Query

  alias SamenCore.TestRepo
  alias SamenCore.Support.AutomationFixture.{Subject, Workflow}
  alias SamenCore.Support.NotificationFixture.Notification

  @subject_key "SamenCore.Support.AutomationFixture.Subject"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    prev_engine = Application.get_env(:samen_core, Samen.Notifications.Engine)
    prev_auto = Application.get_env(:samen_core, Samen.Automation)

    Application.put_env(:samen_core, Samen.Notifications.Engine,
      notification_module: Notification,
      preference_module: SamenCore.Support.NotificationFixture.NotificationPreference,
      repo: TestRepo
    )

    Application.put_env(:samen_core, Samen.Automation,
      workflow_module: Workflow,
      repo: TestRepo
    )

    on_exit(fn ->
      restore(:samen_core, Samen.Notifications.Engine, prev_engine)
      restore(:samen_core, Samen.Automation, prev_auto)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — resource-event trigger fires on matching create/update.

  test "resource-event trigger fires the notify action on a matching create" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner,
      event: :created,
      conditions: [%{"attribute" => "priority", "op" => "gte", "values" => ["high"]}]
    )

    create_subject!(org, priority: :high)
    drain()

    assert notification_count(org, owner) == 1
  end

  test "resource-event trigger fires on a matching update" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner, event: :updated, conditions: [])

    subject = create_subject!(org, priority: :normal)
    drain()
    # No :updated fire from the create.
    assert notification_count(org, owner) == 0

    subject
    |> Ash.Changeset.for_update(:update, %{status: :closed})
    |> Ash.update!(authorize?: false)

    drain()
    assert notification_count(org, owner) == 1
  end

  test "a non-matching condition does NOT fire (the control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner,
      event: :created,
      conditions: [%{"attribute" => "priority", "op" => "eq", "values" => ["urgent"]}]
    )

    create_subject!(org, priority: :low)
    drain()

    assert notification_count(org, owner) == 0
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — schedule trigger fires via AshOban at cron time.

  test "schedule trigger fires via the AshOban schedule_scan trigger (time-travel)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    create_workflow!(org, owner,
      trigger_kind: :schedule,
      schedule_cron: "* * * * *",
      next_fire_at: past,
      conditions: []
    )

    # The scheduler selects workflows with next_fire_at <= now(), runs :dispatch_due,
    # which enqueues the schedule dispatch; drain runs dispatch → run → notify.
    AshOban.Test.schedule_and_run_triggers(Workflow)
    drain()

    assert notification_count(org, owner) == 1

    # next_fire_at was advanced past now (not re-fired immediately).
    wf = only_workflow(org)
    assert DateTime.compare(wf.next_fire_at, DateTime.utc_now()) in [:gt, :eq]
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 2 — INV-1: a condition on a vault field is refused at write.

  test "a condition keyed on a vault-routed (PII) field is refused at write (c2 red)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    assert {:error, error} =
             build_workflow(org, owner,
               event: :created,
               conditions: [%{"attribute" => "email", "op" => "eq", "values" => ["x@y.z"]}]
             )
             |> Ash.create(authorize?: false)

    assert error_mentions?(error, "email")
  end

  test "a condition on a non-PII field saves cleanly (c2 non-PII control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    assert {:ok, _wf} =
             build_workflow(org, owner,
               event: :created,
               conditions: [%{"attribute" => "priority", "op" => "eq", "values" => ["high"]}]
             )
             |> Ash.create(authorize?: false)
  end

  test "the pure refusal oracle blocks vault + unknown, allows enum (anti-tautology)" do
    # Direct check/3 assertion so the sabotage twin (flip the refusal) has a target.
    assert {:error, :condition, "email", _} =
             Samen.Automation.NonPiiPredicates.check(
               [%{"attribute" => "email", "op" => "eq", "values" => ["a"]}],
               [],
               @subject_key
             )

    assert {:error, :condition, "nope", _} =
             Samen.Automation.NonPiiPredicates.check(
               [%{"attribute" => "nope", "op" => "eq", "values" => ["a"]}],
               [],
               @subject_key
             )

    assert :ok ==
             Samen.Automation.NonPiiPredicates.check(
               [%{"attribute" => "priority", "op" => "eq", "values" => ["high"]}],
               [],
               @subject_key
             )
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 3 — org-scoped: a cross-org event never fires another org's rule.

  test "a cross-org event never fires another org's rule (red)" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    owner_a = Ash.UUID.generate()

    # Only org A has a workflow.
    create_workflow!(org_a, owner_a, event: :created, conditions: [])

    # An event in org B must not fire org A's rule.
    create_subject!(org_b, priority: :high)
    drain()
    assert notification_count(org_a, owner_a) == 0

    # Control: the same event in org A DOES fire.
    create_subject!(org_a, priority: :high)
    drain()
    assert notification_count(org_a, owner_a) == 1
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 4 (partial) — catalog registration for the new resource.

  test "the Workflow resource is catalogued (tam_table)" do
    %{rows: rows} =
      TestRepo.query!("SELECT tam_table_name FROM tam_table WHERE tam_table_name = $1", [
        "awf_workflow"
      ])

    assert rows == [["awf_workflow"]]
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp build_workflow(org, owner, opts) do
    attrs =
      %{
        org_id: org,
        name: "wf-#{System.unique_integer([:positive])}",
        status: :active,
        trigger_kind: Keyword.get(opts, :trigger_kind, :resource_event),
        resource_key: Keyword.get(opts, :resource_key, @subject_key),
        event: Keyword.get(opts, :event),
        schedule_cron: Keyword.get(opts, :schedule_cron),
        next_fire_at: Keyword.get(opts, :next_fire_at),
        conditions: Keyword.get(opts, :conditions, []),
        actions:
          Keyword.get(opts, :actions, [
            %{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}
          ]),
        owner_id: owner
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Ash.Changeset.for_create(Workflow, :create, attrs)
  end

  defp create_workflow!(org, owner, opts) do
    build_workflow(org, owner, opts) |> Ash.create!(authorize?: false)
  end

  defp create_subject!(org, opts) do
    Subject
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      title: "s-#{System.unique_integer([:positive])}",
      priority: Keyword.get(opts, :priority, :normal),
      status: Keyword.get(opts, :status, :open),
      email: Keyword.get(opts, :email, "person@example.com")
    })
    |> Ash.create!(authorize?: false)
  end

  defp drain do
    Oban.drain_queue(queue: :automation, with_recursion: true)
  end

  defp notification_count(org, recipient) do
    Notification
    |> filter(org_id == ^org)
    |> filter(recipient_id == ^recipient)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp only_workflow(org) do
    Workflow
    |> filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp error_mentions?(%Ash.Error.Invalid{errors: errors}, needle) do
    Enum.any?(errors, fn e -> error_mentions?(e, needle) end)
  end

  defp error_mentions?(error, needle) do
    error |> inspect() |> String.contains?(needle)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)
end
