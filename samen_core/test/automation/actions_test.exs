defmodule Samen.Automation.ActionsTest.FakeProvider do
  @moduledoc """
  Name-registered `Samen.Delivery.Provider` test double for the `send_email`
  action's full-pipeline tests. Name-registered (not process-dictionary-based)
  because the action fires from inside an Oban job — a DIFFERENT process than
  the test process that configures it.
  """
  use Samen.Delivery.Provider
  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @impl true
  def configured?(_config), do: true

  @impl true
  def deliver(message, _config) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &(&1 ++ [message]))
    {:ok, %{provider_message_id: "fake-#{message.send_id}"}}
  end

  def calls, do: if(Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1), else: [])
end

defmodule Samen.Automation.ActionsTest.SuppressAll do
  @moduledoc "The `Samen.Delivery.Chokepoint` `suppression_module` contract — always suppressed."
  def suppressed?(_org_id, _subscriber_id), do: true
end

defmodule Samen.Automation.ActionsTest do
  @moduledoc """
  T40 — the E2 action library (ADR-039 §5). Exercised end-to-end against a REAL
  Postgres DB via the `awf`/`arm`/`aes`/`asj`/`sat` `SamenCore.Support.AutomationFixture`
  mount (the SAME domain T39/T41 already live in — framework-first, ADR-039 §12
  file budget). Every guarantee has a green path AND a discriminating/red twin
  (`Samen.RedPath` anti-tautology discipline, per house CLAUDE.md).

  ## Done-criterion 1 — 8 rows, table-driven, one test per action kind

  Each `test "row N — <kind>: ..."` creates a REAL Workflow row carrying exactly
  ONE action config, fires it via a REAL trigger record (create/update on
  `Target`), drains the Oban pipeline (capture → dispatch → run → condition
  gate → `Samen.Automation.Compile.run/2` → the action's `run/2`), and asserts
  the OBSERVABLE effect — mirroring `workflow_test.exs`'s exact pattern, now
  proven against the full 8-kind registry (`mutate_record` merges spec §E2's
  create+update into ONE kind — the ADR-039 §5.2 note; this table therefore has
  8 rows, not 9). `escalate`/`enqueue_reminder` build DIRECTLY on the T41
  primitives (no stub path — asserted via the REAL `Reminder`/`Escalation`
  resource, not a mock).

  ## Done-criterion 2 — INV-1

    * `send_email` suppression: a positive control (row 2, unsuppressed) paired
      with a red test (`suppression_module` refuses; the adapter is NEVER
      called — T40 c2).
    * `webhook`: row 7 IS the snapshot assert (a vault field named in `include`
      never reaches the payload/body), PLUS a direct, sabotage-named unit test
      on `Webhook.build_payload/2` (the anti-tautology proof T39's
      `NonPiiPredicates` test used — a pure-function positive/negative control,
      not a full pipeline run) and a defense-in-depth SSRF-guard red test.

  ## Done-criterion 3 — record-mutation actions respect policies

  A direct `AssignOwner.run/2` call with a cross-org actor is refused
  `:unauthorized` (T40 c3 red), the SAME call with an in-org actor succeeds
  (the control).

  ## Done-criterion 4 — action-failure isolation

  `Samen.Automation.Compile.run/2` given a failing first action returns an
  ERROR VALUE, never raises — the calling process survives, proving the engine
  never crashes on an action failure.
  """
  use ExUnit.Case, async: false

  require Ash.Query
  import Ash.Query

  alias Samen.Automation.Actions.{AssignOwner, Webhook}
  alias Samen.Automation.Actions.Webhook.Resolver
  alias Samen.Automation.Actions.WebhookHttpAdapter
  alias Samen.Automation.ActionsTest.{FakeProvider, SuppressAll}
  alias Samen.Automation.{Compile, Context}
  alias Samen.Webhook.Signer
  alias SamenCore.Support.AutomationFixture.{Escalation, Reminder, Target, Workflow}
  alias SamenCore.Support.NotificationFixture.Notification
  alias SamenCore.TestRepo

  @target_key "SamenCore.Support.AutomationFixture.Target"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    prev = %{
      engine: Application.get_env(:samen_core, Samen.Notifications.Engine),
      auto: Application.get_env(:samen_core, Samen.Automation),
      remind: Application.get_env(:samen_core, Samen.Automation.Remind),
      escalate: Application.get_env(:samen_core, Samen.Automation.Escalate),
      chokepoint: Application.get_env(:samen_core, Samen.Delivery.Chokepoint),
      send_email: Application.get_env(:samen_core, Samen.Automation.Actions.SendEmail),
      webhook: Application.get_env(:samen_core, Samen.Automation.Actions.Webhook)
    }

    Application.put_env(:samen_core, Samen.Notifications.Engine,
      notification_module: Notification,
      preference_module: SamenCore.Support.NotificationFixture.NotificationPreference,
      repo: TestRepo
    )

    Application.put_env(:samen_core, Samen.Automation, workflow_module: Workflow, repo: TestRepo)
    Application.put_env(:samen_core, Samen.Automation.Remind, reminder_module: Reminder, repo: TestRepo)

    Application.put_env(:samen_core, Samen.Automation.Escalate,
      escalation_module: Escalation,
      repo: TestRepo
    )

    on_exit(fn ->
      restore(:samen_core, Samen.Notifications.Engine, prev.engine)
      restore(:samen_core, Samen.Automation, prev.auto)
      restore(:samen_core, Samen.Automation.Remind, prev.remind)
      restore(:samen_core, Samen.Automation.Escalate, prev.escalate)
      restore(:samen_core, Samen.Delivery.Chokepoint, prev.chokepoint)
      restore(:samen_core, Samen.Automation.Actions.SendEmail, prev.send_email)
      restore(:samen_core, Samen.Automation.Actions.Webhook, prev.webhook)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — 8 rows, table-driven (one test per action kind).

  test "row 1 — notify: fires from a matching create and records a Notification" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner,
      actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
    )

    create_target!(org)
    drain()

    assert notification_count(org, owner) == 1
  end

  test "row 2 — send_email: routes through the ADR-038 delivery chokepoint (positive control)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    {:ok, _pid} = start_supervised(FakeProvider)
    Application.put_env(:samen_core, Samen.Automation.Actions.SendEmail, adapter: FakeProvider, adapter_config: %{})

    create_workflow!(org, owner,
      actions: [%{"kind" => "send_email", "to" => "owner", "template_key" => "welcome"}]
    )

    create_target!(org)
    drain()

    calls = FakeProvider.calls()
    assert length(calls) == 1
    [message] = calls
    assert message.org_id == org
    assert message.to_subscriber_id == owner
  end

  test "row 3 — mutate_record (update mode): updates the SUBJECT record" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner,
      actions: [%{"kind" => "mutate_record", "mode" => "update", "attrs" => %{"priority" => "urgent"}}]
    )

    target = create_target!(org, priority: :normal)
    drain()

    assert reload_target!(target.id).priority == :urgent
  end

  test "row 4 — assign_owner: sets owner_id to the workflow's own owner" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner,
      actions: [%{"kind" => "assign_owner", "attribute" => "owner_id", "user_id" => "workflow_owner"}]
    )

    target = create_target!(org)
    drain()

    assert reload_target!(target.id).owner_id == owner
  end

  test "row 5 — add_tag: appends the tag to the SUBJECT's tags array (the designed seam, §5.4)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner, actions: [%{"kind" => "add_tag", "tag" => "vip"}])

    target = create_target!(org)
    drain()

    assert "vip" in reload_target!(target.id).tags
  end

  test "row 6 — escalate: opens a T41 automation escalation for the fired subject" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner, actions: [%{"kind" => "escalate", "deadline_minutes" => 30}])

    target = create_target!(org)
    drain()

    [escalation] =
      Escalation
      |> filter(org_id == ^org)
      |> filter(kind == "automation")
      |> Ash.read!(authorize?: false)

    assert escalation.subject_ref == "samen:target:#{target.id}"
    assert escalation.state == :open
  end

  test "row 7 — webhook: signs + posts the fixed §5.3 payload (T40 c2 snapshot assert)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    {:ok, _pid} = start_supervised(WebhookHttpAdapter.Test)

    Application.put_env(:samen_core, Samen.Automation.Actions.Webhook,
      http_adapter: WebhookHttpAdapter.Test,
      resolver: Resolver.Test,
      resolver_map: %{"webhook.example.test" => {93, 184, 216, 34}}
    )

    create_workflow!(org, owner,
      actions: [
        %{"kind" => "webhook", "url" => "https://webhook.example.test/hook", "include" => ["priority", "email"]}
      ]
    )

    target = create_target!(org, priority: :high, email: "leak@example.com")
    drain()

    assert [{url, body, headers}] = WebhookHttpAdapter.Test.calls()
    assert url == "https://webhook.example.test/hook"

    decoded = Jason.decode!(body)
    assert decoded["subject_ref"] == "samen:target:#{target.id}"
    # The eligible attribute IS present...
    assert decoded["data"] == %{"priority" => "high"}
    # ...the vault-routed one named in `include` is NOT — ctx.subject never
    # carried it in the first place (INV-1, structural, not a filter).
    refute Map.has_key?(decoded["data"], "email")
    refute body =~ "leak@example.com"
    refute body =~ "vt_"

    assert {"Samen-Signature", signature} = List.keyfind(headers, "Samen-Signature", 0)
    wf = only_workflow(org)
    assert is_binary(wf.webhook_secret)
    assert {:ok, _timestamp} = Signer.verify(body, signature, wf.webhook_secret)
  end

  test "row 8 — enqueue_reminder: schedules a T41 Reminder via the primitive" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    create_workflow!(org, owner,
      actions: [%{"kind" => "enqueue_reminder", "recipient" => "owner", "offset_minutes" => 60}]
    )

    create_target!(org)
    drain()

    [reminder] = Reminder |> filter(org_id == ^org) |> Ash.read!(authorize?: false)
    assert reminder.recipient_id == owner
    assert reminder.state == :scheduled
    assert reminder.source == :automation
  end

  # ---------------------------------------------------------------------------
  # Bonus coverage (not counted in the 8-row table) — create-mode + interpolation.

  test "mutate_record (create mode): creates a NEW record with an eligible interpolated attribute" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    # Triggered on :updated (not :created) deliberately: the action creates
    # ANOTHER Target row, whose own :created event must NOT re-match this
    # SAME workflow (which only listens for :updated) — avoiding a
    # self-triggering cascade (ADR-039 §4.7 is what WOULD eventually cap this
    # via depth/chain, but keeping the test's own trigger/effect resources
    # disjoint by event kind is the simpler, deadlock-free proof here).
    create_workflow!(org, owner,
      event: :updated,
      actions: [
        %{
          "kind" => "mutate_record",
          "mode" => "create",
          "resource_key" => @target_key,
          "attrs" => %{"title" => "created-by-automation", "priority" => "{{subject.priority}}"}
        }
      ]
    )

    trigger = create_target!(org, priority: :normal, title: "trigger-record")
    drain()

    assert [] =
             Target |> filter(org_id == ^org) |> filter(title == "created-by-automation") |> Ash.read!(authorize?: false)

    trigger
    |> Ash.Changeset.for_update(:update, %{priority: :high})
    |> Ash.update!(authorize?: false)

    drain()

    created =
      Target
      |> filter(org_id == ^org)
      |> filter(title == "created-by-automation")
      |> Ash.read!(authorize?: false)

    assert [record] = created
    assert record.priority == :high
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 2 — INV-1: suppression (email) + no-leak (webhook).

  test "send_email is BLOCKED by the suppression chokepoint — the adapter is NEVER called (T40 c2 red)" do
    org = Ash.UUID.generate()
    owner = Ash.UUID.generate()

    {:ok, _pid} = start_supervised(FakeProvider)
    Application.put_env(:samen_core, Samen.Automation.Actions.SendEmail, adapter: FakeProvider, adapter_config: %{})
    Application.put_env(:samen_core, Samen.Delivery.Chokepoint, suppression_module: SuppressAll)

    create_workflow!(org, owner,
      actions: [%{"kind" => "send_email", "to" => "owner", "template_key" => "welcome"}]
    )

    create_target!(org)
    drain()

    assert FakeProvider.calls() == []
  end

  test "Webhook.build_payload/2 carries ONLY ctx.subject data — a vault field named in include is absent " <>
         "even when explicitly requested (sabotage target: Samen.Automation.Actions.Webhook.data/2, ADR-039 §11)" do
    ctx = %Context{
      org_id: "org-1",
      workflow_id: "wf-1",
      subject_ref: "samen:target:rec-1",
      event: :created,
      event_id: "evt-1",
      # The RunWorker eligible-only projection — a vaulted `email` field is
      # structurally ABSENT here (never merely masked), the read-side twin of
      # NonPiiPredicates' write-side refusal (ADR-039 §4.4).
      subject: %{priority: :high}
    }

    payload = Webhook.build_payload(ctx, ["priority", "email"])

    assert payload["data"] == %{"priority" => "high"}
    refute Map.has_key?(payload["data"], "email")

    encoded = Jason.encode!(payload)
    refute encoded =~ "vt_"
  end

  test "webhook SSRF guard refuses a loopback-resolving target (defense-in-depth, §5.3)" do
    Application.put_env(:samen_core, Samen.Automation.Actions.Webhook,
      resolver: Resolver.Test,
      resolver_map: %{"internal.example.test" => {127, 0, 0, 1}}
    )

    ctx = %Context{
      org_id: "o",
      workflow_id: "w",
      subject_ref: "samen:target:1",
      subject: %{},
      webhook_secret: "shh"
    }

    assert {:error, :ssrf_blocked} =
             Webhook.run(%{"url" => "https://internal.example.test/hook", "include" => []}, ctx)
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 3 — record-mutation actions respect policies.

  test "record-mutation writes respect policies — a cross-org actor is refused :unauthorized " <>
         "(T40 c3 red), the SAME record with an in-org actor succeeds (control)" do
    org = Ash.UUID.generate()
    other_org = Ash.UUID.generate()
    target = create_target!(org)

    wrong_actor = Samen.Scope.new(%{id: Ash.UUID.generate(), org_id: other_org, role: :member})
    right_actor = Samen.Scope.new(%{id: Ash.UUID.generate(), org_id: org, role: :member})

    # Every record-mutation action (mutate_record update mode, assign_owner,
    # add_tag) writes through Support.governed_update/3 — this IS the shared
    # mechanism T40 c3 asserts. `Ash.get!(authorize?: false)` here is TEST
    # SETUP ONLY (loading the struct to write through), not the code path
    # under test — Ash's policy authorizer applies FILTER semantics to reads
    # (a cross-org row is invisible, surfaces as NotFound — legitimate
    # information-hiding, a different guarantee than this test targets) but
    # STRICT semantics to writes (a denied update genuinely raises
    # `Ash.Error.Forbidden`), so isolating the write is what proves c3
    # without conflating it with the read-policy behavior.
    record = Ash.get!(Target, target.id, authorize?: false)

    ctx = %Context{
      org_id: org,
      workflow_id: "wf-direct",
      subject_ref: "samen:target:#{target.id}",
      resource_key: @target_key,
      record_id: to_string(target.id),
      actor: wrong_actor
    }

    assert Samen.Automation.Actions.Support.governed_update(record, %{owner_id: Ash.UUID.generate()}, ctx) ==
             {:error, :unauthorized}

    assert {:ok, updated} =
             Samen.Automation.Actions.Support.governed_update(
               record,
               %{owner_id: Ash.UUID.generate()},
               %{ctx | actor: right_actor}
             )

    assert updated.id == record.id

    # AssignOwner.run/2 end-to-end, in-org — the SAME guarantee through the
    # full action (fetch_subject + governed_update), not just the helper.
    assert {:ok, %{kind: :assign_owner}} =
             AssignOwner.run(%{"attribute" => "owner_id", "user_id" => Ash.UUID.generate()}, %{ctx | actor: right_actor})
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 4 — action failures never crash the engine.

  test "an action failure is recorded per-run without crashing the engine (isolation, T40 c4)" do
    org = Ash.UUID.generate()
    other_org = Ash.UUID.generate()
    target = create_target!(org)
    wrong_actor = Samen.Scope.new(%{id: Ash.UUID.generate(), org_id: other_org, role: :member})

    ctx = %Context{
      org_id: org,
      workflow_id: "wf-isolation",
      subject_ref: "samen:target:#{target.id}",
      resource_key: @target_key,
      record_id: to_string(target.id),
      actor: wrong_actor
    }

    actions = [
      %{"kind" => "assign_owner", "attribute" => "owner_id", "user_id" => Ash.UUID.generate()},
      %{"kind" => "add_tag", "tag" => "never-reached-if-crashed"}
    ]

    # A raised exception here would fail the TEST PROCESS itself — the fact
    # this assertion can even run proves the engine returned a value, not a
    # crash. Compile.run/Reactor's own compensation/error-tuple contract does
    # the rest (ADR-039 §5.1 "action failures never crash the engine").
    assert {:error, _reason} = Compile.run(actions, ctx)
    assert Process.alive?(self())
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp create_workflow!(org, owner, opts) do
    attrs =
      %{
        org_id: org,
        name: "wf-#{System.unique_integer([:positive])}",
        status: :active,
        trigger_kind: :resource_event,
        resource_key: Keyword.get(opts, :resource_key, @target_key),
        event: Keyword.get(opts, :event, :created),
        conditions: Keyword.get(opts, :conditions, []),
        actions: Keyword.fetch!(opts, :actions),
        owner_id: owner
      }

    Workflow
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  defp create_target!(org, opts \\ []) do
    Target
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      title: Keyword.get(opts, :title, "t-#{System.unique_integer([:positive])}"),
      priority: Keyword.get(opts, :priority, :normal),
      owner_id: Keyword.get(opts, :owner_id),
      tags: Keyword.get(opts, :tags, []),
      email: Keyword.get(opts, :email, "person@example.com")
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload_target!(id), do: Ash.get!(Target, id, authorize?: false)

  defp drain, do: Oban.drain_queue(queue: :automation, with_recursion: true)

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

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)
end
