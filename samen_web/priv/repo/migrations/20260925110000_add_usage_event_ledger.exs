defmodule Samen.WebTest.Repo.Migrations.AddUsageEventLedger do
  @moduledoc """
  T163 (ADR-051 P1): the insert-only usage-capture ledger — Samen.WebTest.Billing.UsageEvent, Samen.WebTest.Operator.UsageEvent. Catalogued in the
  SAME transaction (ADR-004 catalog-in-tx).

  Token-blind by construction: every column is a bounded id (uuid), an enum (metric as
  text), a positive integer or a timestamp — NO PII, and the caller's `source_ref` is
  hashed into `idempotency_key`, never stored. `subscription_id` is a soft ref with no
  foreign key: usage may be captured before, and must outlive, its subscription row.
  Written ONLY through `Samen.Billing.Meter.record/3`.
  """
  use Samen.Migration

  @resources [Samen.WebTest.Billing.UsageEvent, Samen.WebTest.Operator.UsageEvent]

  def up do
    create table(:wbx_usage_event, primary_key: false) do
      add(:wbx_metric, :text, null: false)
      add(:wbx_quantity, :integer, null: false)
      add(:wbx_subscription_id, :uuid)
      add(:wbx_idempotency_key, :uuid, null: false)
      add(:wbx_occurred_at, :utc_datetime_usec, null: false)
      add(:wbx_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wbx_org_id, :uuid, null: false)
      add(:wbx_inserted_at, :utc_datetime, null: false)
      add(:wbx_updated_at, :utc_datetime, null: false)
    end

    # The identity the Meter upserts on: a replayed capture is a no-op, never a
    # second row (ADR-051 R1).
    create(
      unique_index(:wbx_usage_event, [:wbx_org_id, :wbx_idempotency_key],
        name: "wbx_usage_event_unique_idempotency_key_index"
      )
    )

    # A capture is a positive quantity, enforced at the table too.
    create(constraint(:wbx_usage_event, :wbx_usage_event_quantity_positive, check: "wbx_quantity > 0"))

    create table(:wpx_usage_event, primary_key: false) do
      add(:wpx_metric, :text, null: false)
      add(:wpx_quantity, :integer, null: false)
      add(:wpx_subscription_id, :uuid)
      add(:wpx_idempotency_key, :uuid, null: false)
      add(:wpx_occurred_at, :utc_datetime_usec, null: false)
      add(:wpx_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wpx_org_id, :uuid, null: false)
      add(:wpx_inserted_at, :utc_datetime, null: false)
      add(:wpx_updated_at, :utc_datetime, null: false)
    end

    # The identity the Meter upserts on: a replayed capture is a no-op, never a
    # second row (ADR-051 R1).
    create(
      unique_index(:wpx_usage_event, [:wpx_org_id, :wpx_idempotency_key],
        name: "wpx_usage_event_unique_idempotency_key_index"
      )
    )

    # A capture is a positive quantity, enforced at the table too.
    create(constraint(:wpx_usage_event, :wpx_usage_event_quantity_positive, check: "wpx_quantity > 0"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:wbx_usage_event))
    drop(table(:wpx_usage_event))
  end
end
