defmodule PawChart.Repo.Migrations.AddSubscriptionMovementLedger do
  @moduledoc """
  WS-B / Phase B1 (ADR-017): the append-only subscription-movement ledger (`mov`)
  for PawChart's billing mount (`PawChart.Billing.SubscriptionEvent`, abbrev `pbv`).
  Catalogued in the same transaction (ADR-004).

  Token-blind by construction (bounded ids/enums/ints/timestamps, no PII). Soft id
  refs carry no FK — the immutable ledger outlives the rows it describes.
  """
  use Samen.Migration

  @resources [PawChart.Billing.SubscriptionEvent]

  def up do
    create table(:pbv_subscription_event, primary_key: false) do
      add(:pbv_subscription_id, :uuid, null: false)
      add(:pbv_customer_id, :uuid)
      add(:pbv_plan_id, :uuid)
      add(:pbv_from_plan_id, :uuid)
      add(:pbv_kind, :text, null: false)
      add(:pbv_mrr_delta_cents, :integer, null: false, default: 0)
      add(:pbv_mrr_before_cents, :integer, null: false, default: 0)
      add(:pbv_mrr_after_cents, :integer, null: false, default: 0)
      add(:pbv_from_status, :text)
      add(:pbv_to_status, :text)
      add(:pbv_reason, :text, default: "status_change")
      add(:pbv_occurred_at, :utc_datetime, null: false)
      add(:pbv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pbv_org_id, :uuid, null: false)
      add(:pbv_inserted_at, :utc_datetime, null: false)
      add(:pbv_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:pbv_subscription_event))
  end
end
