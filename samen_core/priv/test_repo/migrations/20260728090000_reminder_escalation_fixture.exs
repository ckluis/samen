defmodule SamenCore.TestRepo.Migrations.ReminderEscalationFixture do
  @moduledoc """
  T41 E4/E5 reminder + escalation fixture tables (ADR-039 §6/§7): the Automation
  scope's `Reminder` (`arm`) and `Escalation` (`aes`) resources, materialized
  alongside T39's `Workflow`/`Subject` by `Samen.Scopes.Automation` in
  `test/support/automation_fixture.ex` (the SAME `SamenCore.Support.AutomationFixture`
  domain — no new fixture file needed, framework-first ≈0-LOC per-host mount).

  Load-bearing:

    * `arm_reminder` — the E4 first-class reminder. `pii_arm_note` is 🔒
      vault-routed (the `Notification.rendered_body` precedent) — allow-listed in
      `config/test.exs` since this fixture domain is not in `:ash_domains`.
    * `aes_escalation` — the E5 generic escalation primitive (AshStateMachine).
      A PARTIAL unique index on `(aes_org_id, aes_kind, aes_dedupe_key)` scoped to
      NON-TERMINAL states (`open`/`escalating`) is the DB-level twin of
      `Samen.Automation.Escalate.open/2`'s idempotent-by-dedupe app-level check
      (the `apv_approval_pending_*_idx` precedent) — a genuinely NEW cycle for the
      same triple (after a prior one resolved/exhausted/cancelled) is a legitimate
      new row, never blocked.
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.AutomationFixture.Reminder,
    SamenCore.Support.AutomationFixture.Escalation
  ]

  def up do
    # --- arm_reminder : the E4 first-class reminder ---
    create table(:arm_reminder, primary_key: false) do
      add(:arm_recipient_id, :uuid, null: false)
      add(:arm_subject_ref, :text, null: false)
      add(:arm_remind_at, :utc_datetime, null: false)
      add(:arm_source, :text, default: "user")
      add(:arm_state, :text, default: "scheduled")
      add(:arm_sent_at, :utc_datetime)
      add(:pii_arm_note, :text)
      add(:arm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:arm_org_id, :uuid, null: false)
      add(:arm_inserted_at, :utc_datetime, null: false)
      add(:arm_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:arm_reminder, [:arm_state, :arm_remind_at], name: "arm_reminder_due_scan_idx")
    )

    create(index(:arm_reminder, [:arm_org_id], name: "arm_reminder_org_idx"))

    # --- aes_escalation : the E5 generic escalation primitive (state machine) ---
    create table(:aes_escalation, primary_key: false) do
      add(:aes_kind, :text, null: false)
      add(:aes_dedupe_key, :text, null: false)
      add(:aes_subject_ref, :text, null: false)
      add(:aes_deadline_at, :utc_datetime, null: false)
      add(:aes_chain, :map, default: fragment("'[]'::jsonb"))
      add(:aes_current_step, :integer, default: 0)
      add(:aes_next_action_at, :utc_datetime)
      add(:aes_resolved_at, :utc_datetime)
      # AshStateMachine state (abbrev-prefixed via the pre-declared attribute,
      # §5.8 C2 — the Approval precedent).
      add(:aes_state, :text, null: false, default: "open")
      add(:aes_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:aes_org_id, :uuid, null: false)
      add(:aes_inserted_at, :utc_datetime, null: false)
      add(:aes_updated_at, :utc_datetime, null: false)
    end

    # Idempotent-by-dedupe (§7.2) — the DB-level twin of Escalate.open/2's
    # app-level `existing_active/4` check. Scoped to non-terminal states so a
    # genuinely new cycle for the same triple is never blocked.
    create(
      unique_index(:aes_escalation, [:aes_org_id, :aes_kind, :aes_dedupe_key],
        where: "aes_state IN ('open', 'escalating')",
        name: "aes_escalation_active_dedupe_idx"
      )
    )

    create(
      index(:aes_escalation, [:aes_state, :aes_next_action_at], name: "aes_escalation_due_scan_idx")
    )

    create(index(:aes_escalation, [:aes_org_id], name: "aes_escalation_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:aes_escalation, [:aes_org_id], name: "aes_escalation_org_idx"))
    drop(index(:aes_escalation, [:aes_state, :aes_next_action_at], name: "aes_escalation_due_scan_idx"))

    drop(
      unique_index(:aes_escalation, [:aes_org_id, :aes_kind, :aes_dedupe_key],
        name: "aes_escalation_active_dedupe_idx"
      )
    )

    drop(table(:aes_escalation))

    drop(index(:arm_reminder, [:arm_org_id], name: "arm_reminder_org_idx"))
    drop(index(:arm_reminder, [:arm_state, :arm_remind_at], name: "arm_reminder_due_scan_idx"))
    drop(table(:arm_reminder))
  end
end
