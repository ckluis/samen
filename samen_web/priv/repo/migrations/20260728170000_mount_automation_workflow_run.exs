defmodule Samen.WebTest.Repo.Migrations.MountAutomationWorkflowRun do
  @moduledoc """
  Mounts the E1 Workflow + E8 Run resources (ADR-039 §3.1/§8.1; T42) into the
  samen_web test host's Postgres, directly via
  `Samen.Scopes.Automation.Blueprint.define_workflow/5` +
  `.define_run/5` (`test/support/automation.ex`). Needed by
  `automation_health_live_test.exs` — the operator health view + kill-switch +
  masking proofs, exercised against REAL rows (no full Oban dispatch pipeline
  needed at this layer; the engine itself is samen_core-tested,
  `observability_test.exs`).

    * `wwa_workflow` — the E1 rule definition, incl. the §8.4 kill columns.
    * `war_run` — the E8 run log. No PII by schema.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Automation.Workflow,
    Samen.WebTest.Automation.Run
  ]

  def up do
    create table(:wwa_workflow, primary_key: false) do
      add(:wwa_name, :text, null: false)
      add(:wwa_status, :text, default: "draft")
      add(:wwa_trigger_kind, :text, default: "resource_event")
      add(:wwa_resource_key, :text)
      add(:wwa_event, :text)
      add(:wwa_schedule_cron, :text)
      add(:wwa_next_fire_at, :utc_datetime)
      add(:wwa_conditions, :map, default: fragment("'[]'::jsonb"))
      add(:wwa_actions, :map, default: fragment("'[]'::jsonb"))
      add(:wwa_owner_id, :uuid)
      add(:wwa_disabled_by_operator_at, :utc_datetime)
      add(:wwa_disabled_reason, :text)
      add(:wwa_webhook_secret, :text)
      add(:wwa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wwa_org_id, :uuid, null: false)
      add(:wwa_inserted_at, :utc_datetime, null: false)
      add(:wwa_updated_at, :utc_datetime, null: false)
    end

    create(index(:wwa_workflow, [:wwa_org_id], name: "wwa_workflow_org_idx"))

    create table(:war_run, primary_key: false) do
      add(:war_workflow_id, :uuid, null: false)
      add(:war_dispatch_key, :text, null: false)
      add(:war_trigger_kind, :text)
      add(:war_subject_ref, :text)
      add(:war_depth, :integer, default: 0)
      add(:war_outcome, :map, default: fragment("'[]'::jsonb"))
      add(:war_started_at, :utc_datetime)
      add(:war_finished_at, :utc_datetime)
      add(:war_duration_ms, :integer)
      add(:war_error_kind, :text)
      add(:war_state, :text, null: false, default: "queued")
      add(:war_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:war_org_id, :uuid, null: false)
      add(:war_inserted_at, :utc_datetime, null: false)
      add(:war_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:war_run, [:war_dispatch_key], name: "war_run_dispatch_key_idx"))
    create(index(:war_run, [:war_org_id, :war_workflow_id], name: "war_run_org_workflow_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:war_run, [:war_org_id, :war_workflow_id], name: "war_run_org_workflow_idx"))
    drop(unique_index(:war_run, [:war_dispatch_key], name: "war_run_dispatch_key_idx"))
    drop(table(:war_run))

    drop(index(:wwa_workflow, [:wwa_org_id], name: "wwa_workflow_org_idx"))
    drop(table(:wwa_workflow))
  end
end
