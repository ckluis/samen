defmodule Samen.Automation.ReminderTest do
  @moduledoc """
  T41 — the E4 reminder scheduler (ADR-039 §6). Exercised end-to-end against a REAL
  Postgres DB via the `arm`/`nen` `SamenCore.Support.AutomationFixture` mount (the
  SAME domain T39's Workflow/Subject already live in — framework-first, ≈0-LOC
  per-host mount, ADR-039 §12 file budget).

  Every guarantee has a green path AND a discriminating/red twin
  (`Samen.RedPath`/`Samen.MaskingCase` anti-tautology discipline):

    * a due reminder fires via AshOban time-travel and appears in the digest feed
      (`event_type: "reminder_due"` through `Notifications.Engine`);
    * `Reminder` is schema-distinct from `Notification` (a probe against the
      `tam_table` catalog — two separate tables, two separate lifecycles);
    * the idempotent state-guard (`Ash.Changeset.filter/2`, the SlaBreachWorker
      `breached = false` discipline) makes a second `:fire` on an already-sent
      reminder a genuine no-op (never a second notification);
    * `note` is vault-routed (INV-1) — the MaskingCase 3-proof (green/red/sabotage);
    * `snooze/3` + `cancel/3` are governed by the actor's own org policies.
  """
  use ExUnit.Case, async: false
  use Samen.MaskingCase

  require Ash.Query
  import Ash.Query

  alias Samen.Automation.Remind
  alias SamenCore.Support.AutomationFixture.Reminder
  alias SamenCore.Support.NotificationFixture.Notification
  alias SamenCore.TestRepo

  @note "REMIND-SENTINEL: call the customer back about renewal terms."

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    prev_engine = Application.get_env(:samen_core, Samen.Notifications.Engine)
    prev_remind = Application.get_env(:samen_core, Samen.Automation.Remind)

    Application.put_env(:samen_core, Samen.Notifications.Engine,
      notification_module: Notification,
      preference_module: SamenCore.Support.NotificationFixture.NotificationPreference,
      repo: TestRepo
    )

    Application.put_env(:samen_core, Samen.Automation.Remind,
      reminder_module: Reminder,
      repo: TestRepo
    )

    on_exit(fn ->
      restore(:samen_core, Samen.Notifications.Engine, prev_engine)
      restore(:samen_core, Samen.Automation.Remind, prev_remind)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — a due reminder notifies at T (time-travel); digest feed.

  test "a due reminder fires via the AshOban :reminder_due trigger and feeds the digest (reminder_due notification)" do
    org = Ash.UUID.generate()
    recipient = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    assert {:ok, reminder} =
             Remind.schedule(%{
               org_id: org,
               recipient_id: recipient,
               subject_ref: "samen:crm.opportunity:demo-1",
               remind_at: past,
               note: @note,
               source: :user
             })

    assert reminder.state == :scheduled

    AshOban.Test.schedule_and_run_triggers(Reminder)
    drain()

    assert notification_count(org, recipient) == 1

    fired = Ash.get!(Reminder, reminder.id, authorize?: false)
    assert fired.state == :sent
    refute is_nil(fired.sent_at)
  end

  test "a NOT-YET-due reminder does NOT fire (the control)" do
    org = Ash.UUID.generate()
    recipient = Ash.UUID.generate()
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {:ok, _reminder} =
      Remind.schedule(%{
        org_id: org,
        recipient_id: recipient,
        subject_ref: "samen:crm.opportunity:demo-2",
        remind_at: future,
        note: @note
      })

    AshOban.Test.schedule_and_run_triggers(Reminder)
    drain()

    assert notification_count(org, recipient) == 0
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 1 — schema distinct from Notification (probe).

  test "Reminder is schema-distinct from Notification (separate catalog tables)" do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT tam_table_name FROM tam_table WHERE tam_table_name IN ($1, $2) ORDER BY tam_table_name",
        ["arm_reminder", "nen_notification"]
      )

    assert rows == [["arm_reminder"], ["nen_notification"]]
  end

  # ---------------------------------------------------------------------------
  # Idempotency (INV-2) — a reminder must not double-fire.

  test "IDEMPOTENCY: a second :fire on an already-sent reminder is a no-op (the DB-level state-guard)" do
    org = Ash.UUID.generate()
    recipient = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, reminder} =
      Remind.schedule(%{
        org_id: org,
        recipient_id: recipient,
        subject_ref: "samen:crm.opportunity:demo-3",
        remind_at: past,
        note: @note
      })

    # First fire: succeeds, sends exactly one notification.
    assert {:ok, sent} = reminder |> Ash.Changeset.for_update(:fire, %{}) |> Ash.update(authorize?: false)
    assert sent.state == :sent
    assert notification_count(org, recipient) == 1

    # SECOND fire on the SAME (now :sent) row — the changeset filter
    # (`state = 'scheduled'`) no longer matches: refused, never a second send.
    assert {:error, _reason} = sent |> Ash.Changeset.for_update(:fire, %{}) |> Ash.update(authorize?: false)
    assert notification_count(org, recipient) == 1, "a duplicate fire must NEVER double-notify"
  end

  test "the AshOban :reminder_due WHERE clause excludes an already-sent reminder (the scan-level exclusion)" do
    org = Ash.UUID.generate()
    recipient = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, _reminder} =
      Remind.schedule(%{
        org_id: org,
        recipient_id: recipient,
        subject_ref: "samen:crm.opportunity:demo-4",
        remind_at: past,
        note: @note
      })

    AshOban.Test.schedule_and_run_triggers(Reminder)
    drain()
    assert notification_count(org, recipient) == 1

    # A SECOND scan tick: the row is now :sent, excluded by the trigger's own
    # `state == :scheduled` predicate — no second job is even enqueued.
    AshOban.Test.schedule_and_run_triggers(Reminder)
    drain()
    assert notification_count(org, recipient) == 1
  end

  # ---------------------------------------------------------------------------
  # snooze/3 + cancel/3 — governed by the actor's own org policies.

  test "snooze/3 updates remind_at in place (the SAME row, not a new one)" do
    org = Ash.UUID.generate()
    recipient = Ash.UUID.generate()
    later = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    much_later = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second)

    {:ok, reminder} =
      Remind.schedule(%{
        org_id: org,
        recipient_id: recipient,
        subject_ref: "samen:crm.opportunity:demo-5",
        remind_at: later,
        note: @note
      })

    actor = Samen.Scope.new(%{id: recipient, org_id: org, role: :member})

    assert {:ok, snoozed} = Remind.snooze(reminder.id, much_later, actor)
    assert DateTime.compare(snoozed.remind_at, much_later) == :eq
    assert snoozed.id == reminder.id
  end

  test "cancel/3 transitions the reminder to :cancelled — it never fires" do
    org = Ash.UUID.generate()
    recipient = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, reminder} =
      Remind.schedule(%{
        org_id: org,
        recipient_id: recipient,
        subject_ref: "samen:crm.opportunity:demo-6",
        remind_at: past,
        note: @note
      })

    actor = Samen.Scope.new(%{id: recipient, org_id: org, role: :member})
    assert {:ok, cancelled} = Remind.cancel(reminder.id, actor)
    assert cancelled.state == :cancelled

    AshOban.Test.schedule_and_run_triggers(Reminder)
    drain()
    assert notification_count(org, recipient) == 0, "a cancelled reminder must never fire"
  end

  test "a cross-org actor cannot snooze/cancel another org's reminder (red)" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    recipient = Ash.UUID.generate()
    later = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {:ok, reminder} =
      Remind.schedule(%{
        org_id: org_a,
        recipient_id: recipient,
        subject_ref: "samen:crm.opportunity:demo-7",
        remind_at: later,
        note: @note
      })

    intruder = Samen.Scope.new(%{id: Ash.UUID.generate(), org_id: org_b, role: :member})
    assert {:error, _reason} = Remind.snooze(reminder.id, later, intruder)
    assert {:error, _reason} = Remind.cancel(reminder.id, intruder)
  end

  # ---------------------------------------------------------------------------
  # Unwired posture — fail-closed, never a silent drop.

  test "an unwired Remind seam fails closed with :no_automation_module" do
    Application.delete_env(:samen_core, Samen.Automation.Remind)

    assert {:error, :no_automation_module} =
             Remind.schedule(%{
               org_id: Ash.UUID.generate(),
               recipient_id: Ash.UUID.generate(),
               subject_ref: "samen:crm.opportunity:demo-8",
               remind_at: DateTime.utc_now()
             })
  end

  # ---------------------------------------------------------------------------
  # INV-1 — note is vault-routed. The MaskingCase 3-proof (green/red/sabotage).

  describe "INV-1: Reminder.note is vault-routed (MaskingCase 3-proof)" do
    defmodule DenyAllGrant do
      @moduledoc "A grant checker that never approves — proves the operator RED path."
      @behaviour Samen.Reveal.Grant
      @impl true
      def granted?(_ctx), do: false
    end

    setup %{} do
      org = Ash.UUID.generate()
      recipient = Ash.UUID.generate()

      {:ok, created} =
        Remind.schedule(%{
          org_id: org,
          recipient_id: recipient,
          subject_ref: "samen:crm.opportunity:mask-1",
          remind_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
          note: @note
        })

      # `note` is `sensitive?: true` (the VaultField materialization) — NOT
      # included in the default select. Explicit select, the
      # notifications_engine_test.exs precedent ("a plain Ash.read... masks
      # rendered_body — select [:id, :rendered_body]").
      reminder =
        Reminder
        |> filter(id == ^created.id)
        |> Ash.Query.select([:id, :org_id, :recipient_id, :subject_ref, :note])
        |> Ash.read_one!(authorize?: false)

      %{reminder: reminder}
    end

    test "GREEN — the tenant plane resolves note CLEAR", %{reminder: reminder} do
      resolved = resolve_on_plane(reminder, Reminder, :tenant, repo: TestRepo)
      assert_plane_clear!(resolved.note, @note)
    end

    test "RED — the operator (impersonation, no grant) plane MASKS — ••••, never plaintext, never vt_",
         %{reminder: reminder} do
      resolved = resolve_on_plane(reminder, Reminder, :operator, repo: TestRepo, grant: DenyAllGrant)
      assert_plane_masked!(resolved.note, @note)
    end

    test "BOTH directions on the SAME reminder (anti-tautology)", %{reminder: reminder} do
      tenant = resolve_on_plane(reminder, Reminder, :tenant, repo: TestRepo)
      operator = resolve_on_plane(reminder, Reminder, :operator, repo: TestRepo, grant: DenyAllGrant)
      assert_two_plane!(tenant.note, operator.note, @note)
    end

    test "SABOTAGE TWIN — the operator mask is REFUTABLE (a tenant-plane render leaks and is caught)",
         %{reminder: reminder} do
      operator = resolve_on_plane(reminder, Reminder, :operator, repo: TestRepo, grant: DenyAllGrant)
      refute to_string(operator.note) == @note

      # SABOTAGE MODEL: the tenant-plane render of the SAME record is CLEAR — the
      # leak scan flips on it, proving the operator refutation above is refutable.
      leaked = resolve_on_plane(reminder, Reminder, :tenant, repo: TestRepo)
      assert_leak_detected!(leaked.note, @note)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp drain do
    Oban.drain_queue(queue: :automation_timers, with_recursion: true)
  end

  defp notification_count(org, recipient) do
    Notification
    |> filter(org_id == ^org)
    |> filter(recipient_id == ^recipient)
    |> filter(event_type == "reminder_due")
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)
end
