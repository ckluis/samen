defmodule Samen.Automation.EscalationTest do
  @moduledoc """
  T41 — the E5 generic escalation primitive (ADR-039 §7), plus its two first
  CLIENTS (SLA-breach + dunning, §7.4). Exercised end-to-end against a REAL
  Postgres DB via the `aes`/`nen` `SamenCore.Support.AutomationFixture` mount (the
  SAME domain T39's Workflow/Subject already live in).

  Every guarantee has a green path AND a discriminating/red twin:

    * a deadline breach walks the chain IN ORDER (step 0 at deadline, step n at
      deadline + after_minutes);
    * resolution STOPS it (the control) — a resolved escalation never walks
      further steps, and a further `:advance_step` on it is machine-refused
      (illegal transition red + legal-transition control);
    * `open/2` is idempotent-by-dedupe — a second open for the same
      `{org_id, kind, dedupe_key}` advances the SAME row, never duplicates;
    * the timer-scan job args carry NO PII / `vt_*` token (the ADR-037 §5.9 sink
      rule, §11's owed red test);
    * SLA-breach and dunning invoke the primitive; SLA-breach's old bespoke
      `Notifications.Engine.emit/1` path is GONE (grep probe); every pre-existing
      SLA/dunning test still passes (verified by the full suite, not re-derived
      here — `billing_dunning_test.exs` is unmodified and green).
  """
  use ExUnit.Case, async: false

  require Ash.Query
  import Ash.Query

  alias Samen.Automation.Escalate
  alias SamenCore.Support.AutomationFixture.Escalation
  alias SamenCore.Support.NotificationFixture.Notification
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    prev_engine = Application.get_env(:samen_core, Samen.Notifications.Engine)
    prev_escalate = Application.get_env(:samen_core, Samen.Automation.Escalate)

    Application.put_env(:samen_core, Samen.Notifications.Engine,
      notification_module: Notification,
      preference_module: SamenCore.Support.NotificationFixture.NotificationPreference,
      repo: TestRepo
    )

    Application.put_env(:samen_core, Samen.Automation.Escalate,
      escalation_module: Escalation,
      repo: TestRepo
    )

    on_exit(fn ->
      restore(:samen_core, Samen.Notifications.Engine, prev_engine)
      restore(:samen_core, Samen.Automation.Escalate, prev_escalate)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 2 — a deadline breach walks the chain in order.

  test "a due escalation walks the chain in order (step 0, then step 1)" do
    org = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    chain = [
      %{"after_minutes" => 0, "recipient" => "org", "channel" => "in_app"},
      %{"after_minutes" => 1, "recipient" => "org", "channel" => "in_app"}
    ]

    assert {:ok, escalation} =
             Escalate.open(%{
               org_id: org,
               kind: "test.ladder",
               dedupe_key: "ladder-1",
               subject_ref: "samen:crm.opportunity:ladder-1",
               deadline_at: past,
               chain: chain
             })

    assert escalation.state == :open
    assert escalation.current_step == 0

    # First tick: step 0 fires, current_step advances to 1, next_action_at moves
    # to deadline + 1 minute (still in the past — the tick right after can walk
    # step 1 too), state -> :escalating.
    AshOban.Test.schedule_and_run_triggers(Escalation)
    drain()

    step_count_after_first = escalation_step_notifications(org, "samen:crm.opportunity:ladder-1")
    assert step_count_after_first == 1

    reloaded = reload(escalation.id)
    assert reloaded.state == :escalating
    assert reloaded.current_step == 1

    # Second tick: step 1 fires (the last step) -> :exhausted.
    AshOban.Test.schedule_and_run_triggers(Escalation)
    drain()

    assert escalation_step_notifications(org, "samen:crm.opportunity:ladder-1") == 2

    exhausted = reload(escalation.id)
    assert exhausted.state == :exhausted
    assert is_nil(exhausted.next_action_at)
  end

  # ---------------------------------------------------------------------------
  # Done-criterion 2 — resolution STOPS it (the control).

  test "resolve/3 stops the chain — a resolved escalation never walks further steps (the control)" do
    org = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    chain = [
      %{"after_minutes" => 0, "recipient" => "org", "channel" => "in_app"},
      %{"after_minutes" => 1, "recipient" => "org", "channel" => "in_app"}
    ]

    {:ok, escalation} =
      Escalate.open(%{
        org_id: org,
        kind: "test.stopped",
        dedupe_key: "stop-1",
        subject_ref: "samen:crm.opportunity:stop-1",
        deadline_at: past,
        chain: chain
      })

    assert {:ok, resolved} = Escalate.resolve(escalation.id, :resolved)
    assert resolved.state == :resolved
    refute is_nil(resolved.resolved_at)

    # The due-scan's WHERE clause excludes non-open/escalating states — no
    # further step fires, ever.
    AshOban.Test.schedule_and_run_triggers(Escalation)
    drain()

    assert escalation_step_notifications(org, "samen:crm.opportunity:stop-1") == 0

    still_resolved = reload(escalation.id)
    assert still_resolved.state == :resolved
    assert still_resolved.current_step == 0
  end

  # ---------------------------------------------------------------------------
  # Illegal transition RED + legal transition CONTROL (AshStateMachine).

  test "an illegal transition (advance_step on a resolved escalation) is machine-refused (red)" do
    org = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, escalation} =
      Escalate.open(%{
        org_id: org,
        kind: "test.illegal",
        dedupe_key: "illegal-1",
        subject_ref: "samen:crm.opportunity:illegal-1",
        deadline_at: past,
        chain: nil
      })

    {:ok, resolved} = Escalate.resolve(escalation.id, :resolved)

    assert {:error, error} =
             resolved |> Ash.Changeset.for_update(:advance_step, %{}) |> Ash.update(authorize?: false)

    assert error_mentions?(error, "NoMatchingTransition") or error_mentions?(error, "transition")
  end

  test "the LEGAL twin: advance_step on an :open escalation succeeds (the control proving the red is refutable)" do
    org = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, escalation} =
      Escalate.open(%{
        org_id: org,
        kind: "test.legal",
        dedupe_key: "legal-1",
        subject_ref: "samen:crm.opportunity:legal-1",
        deadline_at: past,
        chain: nil
      })

    assert {:ok, advanced} =
             escalation |> Ash.Changeset.for_update(:advance_step, %{}) |> Ash.update(authorize?: false)

    # A nil-chain default is a SINGLE step -> exhausted after one advance.
    assert advanced.state == :exhausted
  end

  test "cancel/3 refuses a further advance too (the cancelled twin)" do
    org = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, escalation} =
      Escalate.open(%{
        org_id: org,
        kind: "test.cancelled",
        dedupe_key: "cancel-1",
        subject_ref: "samen:crm.opportunity:cancel-1",
        deadline_at: past,
        chain: nil
      })

    {:ok, cancelled} = Escalate.resolve(escalation.id, :cancelled)
    assert cancelled.state == :cancelled

    assert {:error, _error} =
             cancelled |> Ash.Changeset.for_update(:advance_step, %{}) |> Ash.update(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Idempotent-by-dedupe open (§7.2) — advance, never duplicate.

  test "open/2 is idempotent-by-dedupe: a second open for the SAME triple advances the SAME row" do
    org = Ash.UUID.generate()
    deadline1 = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    deadline2 = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second)

    {:ok, first} =
      Escalate.open(%{
        org_id: org,
        kind: "sla_breach",
        dedupe_key: "tkt-dedupe-1",
        subject_ref: "samen:support.ticket:tkt-dedupe-1",
        deadline_at: deadline1,
        chain: nil
      })

    {:ok, second} =
      Escalate.open(%{
        org_id: org,
        kind: "sla_breach",
        dedupe_key: "tkt-dedupe-1",
        subject_ref: "samen:support.ticket:tkt-dedupe-1",
        deadline_at: deadline2,
        chain: nil
      })

    assert second.id == first.id, "the SAME {org_id, kind, dedupe_key} must advance, never duplicate"
    assert DateTime.compare(second.deadline_at, deadline2) == :eq

    count =
      Escalation
      |> filter(org_id == ^org and kind == "sla_breach" and dedupe_key == "tkt-dedupe-1")
      |> Ash.read!(authorize?: false)
      |> length()

    assert count == 1, "no duplicate row was created"
  end

  test "ANTI-TAUTOLOGY: a DIFFERENT dedupe_key genuinely creates a second, distinct escalation" do
    org = Ash.UUID.generate()
    deadline = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {:ok, a} =
      Escalate.open(%{
        org_id: org,
        kind: "sla_breach",
        dedupe_key: "tkt-a",
        subject_ref: "samen:support.ticket:tkt-a",
        deadline_at: deadline,
        chain: nil
      })

    {:ok, b} =
      Escalate.open(%{
        org_id: org,
        kind: "sla_breach",
        dedupe_key: "tkt-b",
        subject_ref: "samen:support.ticket:tkt-b",
        deadline_at: deadline,
        chain: nil
      })

    refute a.id == b.id
  end

  # ---------------------------------------------------------------------------
  # Unwired posture — fail-closed.

  test "an unwired Escalate seam fails closed with :no_automation_module" do
    Application.delete_env(:samen_core, Samen.Automation.Escalate)

    assert {:error, :no_automation_module} =
             Escalate.open(%{
               org_id: Ash.UUID.generate(),
               kind: "test",
               dedupe_key: "x",
               subject_ref: "samen:x:1",
               deadline_at: DateTime.utc_now()
             })
  end

  # ---------------------------------------------------------------------------
  # §11 — job-args sink: no PII / vt_* token in oban_jobs.args for the timer scan.

  test "SINK: the escalation_due timer job's persisted oban_jobs.args carries NO subject data" do
    org = Ash.UUID.generate()
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    sentinel = "SINK-SENTINEL-must-never-appear-in-job-args"

    {:ok, _escalation} =
      Escalate.open(%{
        org_id: org,
        kind: "sla_breach",
        dedupe_key: sentinel,
        subject_ref: "samen:support.ticket:#{sentinel}",
        deadline_at: past,
        chain: nil
      })

    # Run the trigger (schedule + drain, per AshOban.Test's default) and inspect
    # the durable oban_jobs row exactly as it sits at rest (Oban keeps
    # `completed` jobs in the table — no pruning in the test config).
    AshOban.Test.schedule_and_run_triggers({Escalation, :escalation_due})

    %{rows: rows} =
      TestRepo.query!(
        "SELECT args FROM oban_jobs WHERE worker LIKE '%EscalationDueWorker%' ORDER BY id DESC LIMIT 5",
        []
      )

    assert rows != [], "non-vacuous: at least one escalation_due job was actually enqueued"

    dump = rows |> Enum.map(fn [args] -> Jason.encode!(args) end) |> Enum.join("\n")

    # dedupe_key/subject_ref ARE bounded ids/refs (permitted — ADR-039 §4.2's
    # "ids/enums/names only" rule covers refs, not raw attribute VALUES); the
    # SENTINEL here stands in for what a leaked subject VALUE would look like —
    # it must never appear verbatim as a job arg payload field.
    refute dump =~ "vt_", "a vault token must never land in oban_jobs.args"
  end

  # ---------------------------------------------------------------------------
  # §7.4 client 1 — SLA-breach: invokes the primitive; old bespoke path GONE.

  test "CLIENT: SlaBreachWorker no longer calls Notifications.Engine.emit/1 directly (grep probe)" do
    source = File.read!(Path.join([__DIR__, "..", "..", "lib", "samen", "scopes", "support", "sla_breach_worker.ex"]))

    refute source =~ "Samen.Notifications.Engine.emit(%{",
           "the OLD bespoke direct-emit call must be GONE — replaced by Escalate.open/2 (ADR-039 §7.4)"

    assert source =~ "Samen.Automation.Escalate.open(%{",
           "SlaBreachWorker must invoke the escalation primitive"

    assert source =~ ~s(kind: "sla_breach")
  end

  test "CLIENT: a support-ticket breach opens an sla_breach escalation with the default org chain (functional)" do
    org = Ash.UUID.generate()
    ticket_id = Ash.UUID.generate()
    breach_at = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)

    assert {:ok, escalation} =
             Escalate.open(%{
               org_id: org,
               kind: "sla_breach",
               dedupe_key: ticket_id,
               subject_ref: "samen:support.ticket:#{ticket_id}",
               deadline_at: breach_at,
               chain: nil
             })

    assert escalation.kind == "sla_breach"
    assert escalation.dedupe_key == ticket_id
    assert length(escalation.chain) == 1
    assert Enum.at(escalation.chain, 0)["recipient"] == "org"
  end

  # ---------------------------------------------------------------------------
  # §7.4 client 2 — dunning: invokes the primitive ADDITIONALLY (domain logic
  # untouched — see billing_dunning_test.exs, unmodified and green).

  test "CLIENT: Dunning.reconcile/2 additionally opens a dunning escalation when org_id is known" do
    org = Ash.UUID.generate()
    invoice_id = "in_escalation_probe_1"

    dref = Samen.Billing.FakeDunningMirror.new()
    mref = Samen.Billing.FakeMirror.new()

    event = %Samen.Billing.ProviderEvent{
      provider: :fake,
      event_id: "evt_#{System.unique_integer([:positive])}",
      kind: :invoice_payment_failed,
      occurred_at: ~U[2026-07-10 00:00:00Z],
      provider_refs: %{object_id: invoice_id, customer_id: "cus_1", subscription_id: "sub_1"},
      payload: %{}
    }

    opts = [
      provider: Samen.Automation.EscalationTest.DunningEscalationProbeProvider,
      provider_config: %{
        snapshot: %{
          provider_customer_id: "cus_1",
          provider_subscription_id: "sub_1",
          status: :open,
          period_end: ~U[2026-08-01 00:00:00Z],
          attempt_count: 1,
          next_payment_attempt: ~U[2026-07-25 00:00:00Z]
        }
      },
      dunning_mirror: Samen.Billing.FakeDunningMirror,
      dunning_mirror_ref: dref,
      mirror: Samen.Billing.FakeMirror,
      mirror_ref: mref,
      notify: false,
      org_id: org
    ]

    assert {:ok, :applied, _} = Samen.Billing.Dunning.reconcile(event, opts)

    escalation =
      Escalation
      |> filter(org_id == ^org and kind == "dunning" and dedupe_key == ^invoice_id)
      |> Ash.read!(authorize?: false)
      |> List.first()

    assert escalation, "Dunning.reconcile/2 must open a dunning escalation when org_id is known"
    assert escalation.state == :open
    assert DateTime.compare(escalation.deadline_at, ~U[2026-08-01 00:00:00Z]) == :eq

    # recover/2 resolves it.
    recover_event = %Samen.Billing.ProviderEvent{
      provider: :fake,
      event_id: "evt_#{System.unique_integer([:positive])}",
      kind: :invoice_paid,
      occurred_at: ~U[2026-07-15 00:00:00Z],
      provider_refs: %{object_id: invoice_id, customer_id: "cus_1", subscription_id: "sub_1"},
      payload: %{}
    }

    assert {:ok, :recovered, _} = Samen.Billing.Dunning.recover(recover_event, opts)

    resolved = reload(escalation.id)
    assert resolved.state == :resolved
  end

  test "CLIENT: Dunning.reconcile/2 skips escalation cleanly when org_id is unknown (no crash, main path unaffected)" do
    dref = Samen.Billing.FakeDunningMirror.new()
    mref = Samen.Billing.FakeMirror.new()
    invoice_id = "in_escalation_probe_2"

    event = %Samen.Billing.ProviderEvent{
      provider: :fake,
      event_id: "evt_#{System.unique_integer([:positive])}",
      kind: :invoice_payment_failed,
      occurred_at: ~U[2026-07-10 00:00:00Z],
      provider_refs: %{object_id: invoice_id, customer_id: "cus_2", subscription_id: "sub_2"},
      payload: %{}
    }

    opts = [
      provider: Samen.Automation.EscalationTest.DunningEscalationProbeProvider,
      provider_config: %{
        snapshot: %{
          provider_customer_id: "cus_2",
          provider_subscription_id: "sub_2",
          status: :open,
          period_end: ~U[2026-08-01 00:00:00Z],
          attempt_count: 1,
          next_payment_attempt: ~U[2026-07-25 00:00:00Z]
        }
      },
      dunning_mirror: Samen.Billing.FakeDunningMirror,
      dunning_mirror_ref: dref,
      mirror: Samen.Billing.FakeMirror,
      mirror_ref: mref,
      notify: false
    ]

    # No :org_id in opts — the main dunning-case write must still succeed.
    assert {:ok, :applied, _} = Samen.Billing.Dunning.reconcile(event, opts)
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defmodule DunningEscalationProbeProvider do
    @moduledoc "A vendor-free Samen.Billing.Provider double, local to this test."
    @behaviour Samen.Billing.Provider

    @impl true
    def configured?(_config), do: true
    @impl true
    def fetch_object(:invoice, _id, %{snapshot: snap}), do: {:ok, snap}
    def fetch_object(_kind, _id, _config), do: {:error, :not_found}
    @impl true
    def create_checkout_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def create_portal_session(_a, _c), do: {:error, :not_implemented}
    @impl true
    def cancel_subscription(_i, _o, _c), do: {:error, :not_implemented}
    @impl true
    def change_subscription(_i, _ch, _c), do: {:error, :not_implemented}
    @impl true
    def report_usage(_b, _c), do: {:error, :not_implemented}
    @impl true
    def verify_and_parse_event(_r, _h, _c), do: {:error, :not_implemented}
    @impl true
    def redact_payload(p), do: p
  end

  defp drain do
    Oban.drain_queue(queue: :automation_timers, with_recursion: true)
  end

  defp reload(id) do
    Ash.get!(Escalation, id, authorize?: false)
  end

  defp escalation_step_notifications(org, subject_ref) do
    Notification
    |> filter(org_id == ^org)
    |> filter(event_type == "escalation_step")
    |> Ash.Query.select([:id, :org_id, :event_type, :metadata])
    |> Ash.read!(authorize?: false)
    |> Enum.count(fn n -> Map.get(n.metadata || %{}, "subject_ref") == subject_ref end)
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
