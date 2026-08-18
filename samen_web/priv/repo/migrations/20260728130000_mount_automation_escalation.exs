defmodule Samen.WebTest.Repo.Migrations.MountAutomationEscalation do
  @moduledoc """
  Mounts the E5 generic escalation primitive (`Escalation`, ADR-039 §7; T41) into
  the samen_web test host's Postgres, directly via
  `Samen.Scopes.Automation.Blueprint.define_escalation/5`
  (`test/support/automation.ex` — NOT the full E1/E4 scope; see that module's
  moduledoc). Needed by `notifications_sources_test.exs`'s SLA-breach source
  proof: `SlaBreachWorker`'s attention path now routes through
  `Samen.Automation.Escalate.open/2` (ADR-039 §7.4), so the notification the test
  asserts is produced by the escalation's own `:escalation_due` chain walk, not a
  direct emit.

    * `wes_escalation` — the E5 escalation primitive (AshStateMachine). No PII by
      schema (ids/enums/bounded jsonb chain only).
  """
  use Samen.Migration

  @resources [Samen.WebTest.Automation.Escalation]

  def up do
    create table(:wes_escalation, primary_key: false) do
      add(:wes_kind, :text, null: false)
      add(:wes_dedupe_key, :text, null: false)
      add(:wes_subject_ref, :text, null: false)
      add(:wes_deadline_at, :utc_datetime, null: false)
      add(:wes_chain, :map, default: fragment("'[]'::jsonb"))
      add(:wes_current_step, :integer, default: 0)
      add(:wes_next_action_at, :utc_datetime)
      add(:wes_resolved_at, :utc_datetime)
      add(:wes_state, :text, null: false, default: "open")
      add(:wes_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wes_org_id, :uuid, null: false)
      add(:wes_inserted_at, :utc_datetime, null: false)
      add(:wes_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:wes_escalation, [:wes_org_id, :wes_kind, :wes_dedupe_key],
        where: "wes_state IN ('open', 'escalating')",
        name: "wes_escalation_active_dedupe_idx"
      )
    )

    create(
      index(:wes_escalation, [:wes_state, :wes_next_action_at], name: "wes_escalation_due_scan_idx")
    )

    create(index(:wes_escalation, [:wes_org_id], name: "wes_escalation_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:wes_escalation, [:wes_org_id], name: "wes_escalation_org_idx"))
    drop(index(:wes_escalation, [:wes_state, :wes_next_action_at], name: "wes_escalation_due_scan_idx"))

    drop(
      unique_index(:wes_escalation, [:wes_org_id, :wes_kind, :wes_dedupe_key],
        name: "wes_escalation_active_dedupe_idx"
      )
    )

    drop(table(:wes_escalation))
  end
end
