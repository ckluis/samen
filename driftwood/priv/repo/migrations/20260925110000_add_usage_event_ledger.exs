defmodule Driftwood.Repo.Migrations.AddUsageEventLedger do
  @moduledoc """
  T163 (ADR-051 P1): the insert-only usage-capture ledger — Driftwood.Billing.UsageEvent, Driftwood.Operator.UsageEvent. Catalogued in the
  SAME transaction (ADR-004 catalog-in-tx).

  Token-blind by construction: every column is a bounded id (uuid), an enum (metric as
  text), a positive integer or a timestamp — NO PII, and the caller's `source_ref` is
  hashed into `idempotency_key`, never stored. `subscription_id` is a soft ref with no
  foreign key: usage may be captured before, and must outlive, its subscription row.
  Written ONLY through `Samen.Billing.Meter.record/3`.
  """
  use Samen.Migration

  @resources [Driftwood.Billing.UsageEvent, Driftwood.Operator.UsageEvent]

  def up do
    create table(:fbx_usage_event, primary_key: false) do
      add(:fbx_metric, :text, null: false)
      add(:fbx_quantity, :integer, null: false)
      add(:fbx_subscription_id, :uuid)
      add(:fbx_idempotency_key, :uuid, null: false)
      add(:fbx_occurred_at, :utc_datetime_usec, null: false)
      add(:fbx_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fbx_org_id, :uuid, null: false)
      add(:fbx_inserted_at, :utc_datetime, null: false)
      add(:fbx_updated_at, :utc_datetime, null: false)
    end

    # The identity the Meter upserts on: a replayed capture is a no-op, never a
    # second row (ADR-051 R1).
    create(
      unique_index(:fbx_usage_event, [:fbx_org_id, :fbx_idempotency_key],
        name: "fbx_usage_event_unique_idempotency_key_index"
      )
    )

    # A capture is a positive quantity, enforced at the table too.
    create(constraint(:fbx_usage_event, :fbx_usage_event_quantity_positive, check: "fbx_quantity > 0"))

    create table(:dpx_usage_event, primary_key: false) do
      add(:dpx_metric, :text, null: false)
      add(:dpx_quantity, :integer, null: false)
      add(:dpx_subscription_id, :uuid)
      add(:dpx_idempotency_key, :uuid, null: false)
      add(:dpx_occurred_at, :utc_datetime_usec, null: false)
      add(:dpx_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dpx_org_id, :uuid, null: false)
      add(:dpx_inserted_at, :utc_datetime, null: false)
      add(:dpx_updated_at, :utc_datetime, null: false)
    end

    # The identity the Meter upserts on: a replayed capture is a no-op, never a
    # second row (ADR-051 R1).
    create(
      unique_index(:dpx_usage_event, [:dpx_org_id, :dpx_idempotency_key],
        name: "dpx_usage_event_unique_idempotency_key_index"
      )
    )

    # A capture is a positive quantity, enforced at the table too.
    create(constraint(:dpx_usage_event, :dpx_usage_event_quantity_positive, check: "dpx_quantity > 0"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fbx_usage_event))
    drop(table(:dpx_usage_event))
  end
end
