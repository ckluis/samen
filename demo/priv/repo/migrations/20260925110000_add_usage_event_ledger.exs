defmodule Demo.Repo.Migrations.AddUsageEventLedger do
  @moduledoc """
  T163 (ADR-051 P1): the insert-only usage-capture ledger — Demo.BillingScope.UsageEvent. Catalogued in the
  SAME transaction (ADR-004 catalog-in-tx).

  Token-blind by construction: every column is a bounded id (uuid), an enum (metric as
  text), a positive integer or a timestamp — NO PII, and the caller's `source_ref` is
  hashed into `idempotency_key`, never stored. `subscription_id` is a soft ref with no
  foreign key: usage may be captured before, and must outlive, its subscription row.
  Written ONLY through `Samen.Billing.Meter.record/3`.
  """
  use Samen.Migration

  @resources [Demo.BillingScope.UsageEvent]

  def up do
    create table(:bux_usage_event, primary_key: false) do
      add(:bux_metric, :text, null: false)
      add(:bux_quantity, :integer, null: false)
      add(:bux_subscription_id, :uuid)
      add(:bux_idempotency_key, :uuid, null: false)
      add(:bux_occurred_at, :utc_datetime_usec, null: false)
      add(:bux_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bux_org_id, :uuid, null: false)
      add(:bux_inserted_at, :utc_datetime, null: false)
      add(:bux_updated_at, :utc_datetime, null: false)
    end

    # The identity the Meter upserts on: a replayed capture is a no-op, never a
    # second row (ADR-051 R1).
    create(
      unique_index(:bux_usage_event, [:bux_org_id, :bux_idempotency_key],
        name: "bux_usage_event_unique_idempotency_key_index"
      )
    )

    # A capture is a positive quantity, enforced at the table too.
    create(constraint(:bux_usage_event, :bux_usage_event_quantity_positive, check: "bux_quantity > 0"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:bux_usage_event))
  end
end
