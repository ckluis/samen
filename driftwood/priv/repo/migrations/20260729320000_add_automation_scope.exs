defmodule Driftwood.Repo.Migrations.AddAutomationScope do
  @moduledoc """
  Mounts the Automation universal scope (ADR-039 §3.1; T39/T41/T42/T118) into the
  driftwood host's one Postgres, and catalogs all four resources in the SAME
  migration transaction (ADR-004 catalog-in-tx). Mirrors
  `20260728200000_add_calendar_scope.exs`. The FIRST vertical adoption of
  `Samen.Scopes.Automation` — see `lib/driftwood/automation.ex` moduledoc for why
  fresh (`dwf`/`drm`/`des`/`dru`) abbrevs were needed instead of the scope's
  built-in defaults.

    * `dwf_workflow` — E1 rule definition (trigger → conditions → actions), incl.
      the §8.4 kill columns. No PII by schema.
    * `drm_reminder` — E4 first-class reminder; 🔒 vaulted `note`
      (`vault: :pii_note`).
    * `des_escalation` — E5 generic escalation primitive (AshStateMachine). No PII
      by schema.
    * `dru_run` — E8 run log. No PII by schema.
  """
  use Samen.Migration

  @resources [
    Driftwood.Automation.Workflow,
    Driftwood.Automation.Reminder,
    Driftwood.Automation.Escalation,
    Driftwood.Automation.Run
  ]

  def up do
    create table(:dwf_workflow, primary_key: false) do
      add(:dwf_name, :text, null: false)
      add(:dwf_status, :text, default: "draft")
      add(:dwf_trigger_kind, :text, default: "resource_event")
      add(:dwf_resource_key, :text)
      add(:dwf_event, :text)
      add(:dwf_schedule_cron, :text)
      add(:dwf_next_fire_at, :utc_datetime)
      add(:dwf_conditions, :map, default: fragment("'[]'::jsonb"))
      add(:dwf_actions, :map, default: fragment("'[]'::jsonb"))
      add(:dwf_owner_id, :uuid)
      add(:dwf_disabled_by_operator_at, :utc_datetime)
      add(:dwf_disabled_reason, :text)
      add(:dwf_webhook_secret, :text)
      add(:dwf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dwf_org_id, :uuid, null: false)
      add(:dwf_inserted_at, :utc_datetime, null: false)
      add(:dwf_updated_at, :utc_datetime, null: false)
    end

    create(index(:dwf_workflow, [:dwf_org_id], name: "dwf_workflow_org_idx"))

    create table(:drm_reminder, primary_key: false) do
      add(:drm_recipient_id, :uuid, null: false)
      add(:drm_subject_ref, :text, null: false)
      add(:drm_remind_at, :utc_datetime, null: false)
      # Scalar PII vault token: `note` carries the `pii_` prefix (pii_drm_note),
      # the SAME convention Chat's `body` uses (a plain `pii_attribute(:note,
      # :string, ...)`, distinct from the structured FullName/Emails/Phones
      # types which keep a plain abbrev-prefixed column).
      add(:pii_drm_note, :text)
      add(:drm_source, :text, default: "user")
      add(:drm_state, :text, null: false, default: "scheduled")
      add(:drm_sent_at, :utc_datetime)
      add(:drm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:drm_org_id, :uuid, null: false)
      add(:drm_inserted_at, :utc_datetime, null: false)
      add(:drm_updated_at, :utc_datetime, null: false)
    end

    create(index(:drm_reminder, [:drm_org_id], name: "drm_reminder_org_idx"))
    create(index(:drm_reminder, [:drm_state, :drm_remind_at], name: "drm_reminder_due_scan_idx"))

    create table(:des_escalation, primary_key: false) do
      add(:des_kind, :text, null: false)
      add(:des_dedupe_key, :text, null: false)
      add(:des_subject_ref, :text, null: false)
      add(:des_deadline_at, :utc_datetime, null: false)
      add(:des_chain, :map, default: fragment("'[]'::jsonb"))
      add(:des_current_step, :integer, default: 0)
      add(:des_next_action_at, :utc_datetime)
      add(:des_resolved_at, :utc_datetime)
      add(:des_state, :text, null: false, default: "open")
      add(:des_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:des_org_id, :uuid, null: false)
      add(:des_inserted_at, :utc_datetime, null: false)
      add(:des_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:des_escalation, [:des_org_id, :des_kind, :des_dedupe_key],
        where: "des_state IN ('open', 'escalating')",
        name: "des_escalation_active_dedupe_idx"
      )
    )

    create(
      index(:des_escalation, [:des_state, :des_next_action_at], name: "des_escalation_due_scan_idx")
    )

    create(index(:des_escalation, [:des_org_id], name: "des_escalation_org_idx"))

    create table(:dru_run, primary_key: false) do
      add(:dru_workflow_id, :uuid, null: false)
      add(:dru_dispatch_key, :text, null: false)
      add(:dru_trigger_kind, :text)
      add(:dru_subject_ref, :text)
      add(:dru_depth, :integer, default: 0)
      add(:dru_outcome, :map, default: fragment("'[]'::jsonb"))
      add(:dru_started_at, :utc_datetime)
      add(:dru_finished_at, :utc_datetime)
      add(:dru_duration_ms, :integer)
      add(:dru_error_kind, :text)
      add(:dru_state, :text, null: false, default: "queued")
      add(:dru_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dru_org_id, :uuid, null: false)
      add(:dru_inserted_at, :utc_datetime, null: false)
      add(:dru_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:dru_run, [:dru_dispatch_key], name: "dru_run_dispatch_key_idx"))
    create(index(:dru_run, [:dru_org_id, :dru_workflow_id], name: "dru_run_org_workflow_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:dru_run, [:dru_org_id, :dru_workflow_id], name: "dru_run_org_workflow_idx"))
    drop(unique_index(:dru_run, [:dru_dispatch_key], name: "dru_run_dispatch_key_idx"))
    drop(table(:dru_run))

    drop(index(:des_escalation, [:des_org_id], name: "des_escalation_org_idx"))
    drop(index(:des_escalation, [:des_state, :des_next_action_at], name: "des_escalation_due_scan_idx"))

    drop(
      unique_index(:des_escalation, [:des_org_id, :des_kind, :des_dedupe_key],
        name: "des_escalation_active_dedupe_idx"
      )
    )

    drop(table(:des_escalation))

    drop(index(:drm_reminder, [:drm_state, :drm_remind_at], name: "drm_reminder_due_scan_idx"))
    drop(index(:drm_reminder, [:drm_org_id], name: "drm_reminder_org_idx"))
    drop(table(:drm_reminder))

    drop(index(:dwf_workflow, [:dwf_org_id], name: "dwf_workflow_org_idx"))
    drop(table(:dwf_workflow))
  end
end
