defmodule SamenCore.TestRepo.Migrations.RunFixture do
  @moduledoc """
  T42 E8 run-log fixture table (ADR-039 §8.1): the Automation scope's `Run`
  resource (`sar`), materialized alongside T39-T41's Workflow/Reminder/
  Escalation by `Samen.Scopes.Automation` in `test/support/automation_fixture.ex`
  (the SAME `SamenCore.Support.AutomationFixture` domain — no new fixture file
  needed, framework-first ≈0-LOC per-host mount).

  Load-bearing:

    * `sar_run` — the E8 run log. No PII by schema — every column is a bounded
      id/enum/timestamp/number or a bounded jsonb outcome list (asserted
      directly against `information_schema` in `observability_test.exs`; see
      `Samen.Scopes.Automation.Blueprint.define_run/5` moduledoc for why this
      is NOT `Samen.Aggregate.Resource` despite the "no PII column" bar).
    * A UNIQUE index on `sar_dispatch_key` is the tier-2 durable dedupe
      (ADR-039 §4.6) — the `Automation.Run`'s `:record` action is
      `upsert?(true)` against this identity; a concurrent duplicate dispatch
      lands on the same row instead of violating the index.
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.AutomationFixture.Run
  ]

  def up do
    create table(:sar_run, primary_key: false) do
      add(:sar_workflow_id, :uuid, null: false)
      add(:sar_dispatch_key, :text, null: false)
      add(:sar_trigger_kind, :text)
      add(:sar_subject_ref, :text)
      add(:sar_depth, :integer, default: 0)
      add(:sar_outcome, :map, default: fragment("'[]'::jsonb"))
      add(:sar_started_at, :utc_datetime)
      add(:sar_finished_at, :utc_datetime)
      add(:sar_duration_ms, :integer)
      add(:sar_error_kind, :text)
      # AshStateMachine state (abbrev-prefixed via the pre-declared attribute,
      # ADR-037 §5.8 C2 — the Escalation precedent).
      add(:sar_state, :text, null: false, default: "queued")
      add(:sar_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sar_org_id, :uuid, null: false)
      add(:sar_inserted_at, :utc_datetime, null: false)
      add(:sar_updated_at, :utc_datetime, null: false)
    end

    # Tier-2 dedupe (§4.6) — a second insert for the same (workflow, event) is a
    # no-op conflict (the Run `:record` action upserts onto this identity).
    create(unique_index(:sar_run, [:sar_dispatch_key], name: "sar_run_dispatch_key_idx"))

    create(index(:sar_run, [:sar_org_id, :sar_workflow_id], name: "sar_run_org_workflow_idx"))

    create(
      index(:sar_run, [:sar_workflow_id, :sar_inserted_at], name: "sar_run_workflow_rate_idx")
    )

    create(index(:sar_run, [:sar_org_id, :sar_state], name: "sar_run_org_state_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:sar_run, [:sar_org_id, :sar_state], name: "sar_run_org_state_idx"))
    drop(index(:sar_run, [:sar_workflow_id, :sar_inserted_at], name: "sar_run_workflow_rate_idx"))
    drop(index(:sar_run, [:sar_org_id, :sar_workflow_id], name: "sar_run_org_workflow_idx"))
    drop(unique_index(:sar_run, [:sar_dispatch_key], name: "sar_run_dispatch_key_idx"))
    drop(table(:sar_run))
  end
end
