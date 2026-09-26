defmodule PawChart.Repo.Migrations.AddUsageEventLedger do
  @moduledoc """
  T163 (ADR-051 P1): the insert-only usage-capture ledger — PawChart.Billing.UsageEvent, PawChart.Operator.UsageEvent. Catalogued in the
  SAME transaction (ADR-004 catalog-in-tx).

  Token-blind by construction: every column is a bounded id (uuid), an enum (metric as
  text), a positive integer or a timestamp — NO PII, and the caller's `source_ref` is
  hashed into `idempotency_key`, never stored. `subscription_id` is a soft ref with no
  foreign key: usage may be captured before, and must outlive, its subscription row.
  Written ONLY through `Samen.Billing.Meter.record/3`.
  """
  use Samen.Migration

  @resources [PawChart.Billing.UsageEvent, PawChart.Operator.UsageEvent]

  def up do
    create table(:pbx_usage_event, primary_key: false) do
      add(:pbx_metric, :text, null: false)
      add(:pbx_quantity, :integer, null: false)
      add(:pbx_subscription_id, :uuid)
      add(:pbx_idempotency_key, :uuid, null: false)
      add(:pbx_occurred_at, :utc_datetime_usec, null: false)
      add(:pbx_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pbx_org_id, :uuid, null: false)
      add(:pbx_inserted_at, :utc_datetime, null: false)
      add(:pbx_updated_at, :utc_datetime, null: false)
    end

    # The identity the Meter upserts on: a replayed capture is a no-op, never a
    # second row (ADR-051 R1).
    create(
      unique_index(:pbx_usage_event, [:pbx_org_id, :pbx_idempotency_key],
        name: "pbx_usage_event_unique_idempotency_key_index"
      )
    )

    # A capture is a positive quantity, enforced at the table too.
    create(constraint(:pbx_usage_event, :pbx_usage_event_quantity_positive, check: "pbx_quantity > 0"))

    create table(:pmx_usage_event, primary_key: false) do
      add(:pmx_metric, :text, null: false)
      add(:pmx_quantity, :integer, null: false)
      add(:pmx_subscription_id, :uuid)
      add(:pmx_idempotency_key, :uuid, null: false)
      add(:pmx_occurred_at, :utc_datetime_usec, null: false)
      add(:pmx_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pmx_org_id, :uuid, null: false)
      add(:pmx_inserted_at, :utc_datetime, null: false)
      add(:pmx_updated_at, :utc_datetime, null: false)
    end

    # The identity the Meter upserts on: a replayed capture is a no-op, never a
    # second row (ADR-051 R1).
    create(
      unique_index(:pmx_usage_event, [:pmx_org_id, :pmx_idempotency_key],
        name: "pmx_usage_event_unique_idempotency_key_index"
      )
    )

    # A capture is a positive quantity, enforced at the table too.
    create(constraint(:pmx_usage_event, :pmx_usage_event_quantity_positive, check: "pmx_quantity > 0"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:pbx_usage_event))
    drop(table(:pmx_usage_event))
  end
end
