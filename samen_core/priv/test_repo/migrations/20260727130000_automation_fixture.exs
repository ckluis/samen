defmodule SamenCore.TestRepo.Migrations.AutomationFixture do
  @moduledoc """
  T39 E1 automation-engine fixture tables (ADR-039): the Automation scope's `Workflow`
  resource (`awf`) + a `Subject` trigger source (`asj`) mounted in `samen_core` tests
  via `test/support/automation_fixture.ex`.

  Load-bearing:

    * `awf_workflow` — the E1 rule definition. No PII by schema; includes the §8.4
      kill columns (`awf_disabled_by_operator_at`/`awf_disabled_reason`) from day one.
    * `asj_subject` — a trigger source with condition-eligible enums
      (`asj_priority`/`asj_status`) and one 🔒 vault-routed field (`pii_asj_email`, the
      c2 red-path target — a condition on it is refused at write).

  `pii_asj_email` is allow-listed in `config/test.exs`
  (`:vault_declared_parity_allow_list`) because this fixture domain is not in
  `:ash_domains`.
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.AutomationFixture.Workflow,
    SamenCore.Support.AutomationFixture.Subject
  ]

  def up do
    # --- awf_workflow : the E1 rule definition (no PII by schema) ---
    create table(:awf_workflow, primary_key: false) do
      add(:awf_name, :text, null: false)
      add(:awf_status, :text, default: "draft")
      add(:awf_trigger_kind, :text, default: "resource_event")
      add(:awf_resource_key, :text)
      add(:awf_event, :text)
      add(:awf_schedule_cron, :text)
      add(:awf_next_fire_at, :utc_datetime)
      add(:awf_conditions, :map, default: fragment("'[]'::jsonb"))
      add(:awf_actions, :map, default: fragment("'[]'::jsonb"))
      add(:awf_owner_id, :uuid)
      add(:awf_disabled_by_operator_at, :utc_datetime)
      add(:awf_disabled_reason, :text)
      # T40 / ADR-039 §5.3 — the webhook action's per-workflow HMAC secret.
      add(:awf_webhook_secret, :text)
      add(:awf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:awf_org_id, :uuid, null: false)
      add(:awf_inserted_at, :utc_datetime, null: false)
      add(:awf_updated_at, :utc_datetime, null: false)
    end

    create(
      index(:awf_workflow, [:awf_org_id, :awf_resource_key, :awf_event],
        name: "awf_workflow_org_resource_event_idx"
      )
    )

    create(
      index(:awf_workflow, [:awf_status, :awf_trigger_kind, :awf_next_fire_at],
        name: "awf_workflow_schedule_scan_idx"
      )
    )

    # --- asj_subject : trigger source; pii_asj_email is 🔒 (condition-ineligible) ---
    create table(:asj_subject, primary_key: false) do
      add(:asj_title, :text, null: false)
      add(:asj_priority, :text, default: "normal")
      add(:asj_status, :text, default: "open")
      add(:pii_asj_email, :text)
      add(:asj_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:asj_org_id, :uuid, null: false)
      add(:asj_inserted_at, :utc_datetime, null: false)
      add(:asj_updated_at, :utc_datetime, null: false)
    end

    create(index(:asj_subject, [:asj_org_id], name: "asj_subject_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:asj_subject, [:asj_org_id], name: "asj_subject_org_idx"))
    drop(table(:asj_subject))

    drop(index(:awf_workflow, [:awf_status, :awf_trigger_kind, :awf_next_fire_at], name: "awf_workflow_schedule_scan_idx"))
    drop(index(:awf_workflow, [:awf_org_id, :awf_resource_key, :awf_event], name: "awf_workflow_org_resource_event_idx"))
    drop(table(:awf_workflow))
  end
end
