defmodule Demo.Repo.Migrations.AddSubscriptionMovementLedger do
  @moduledoc """
  WS-B / Phase B1 (ADR-017): the append-only subscription-movement ledger (`mov`)
  — `Demo.BillingScope.SubscriptionEvent`. Catalogued in the SAME transaction
  (ADR-004 catalog-in-tx).

  Token-blind by construction: every column is a bounded id (uuid), an enum
  (kind/status/reason as text), a signed integer (MRR cents), or a timestamp — NO
  PII column. Soft id refs (subscription/customer/plan) carry NO foreign-key
  constraint: the immutable ledger row is a historical fact that outlives the mutable
  subscription/customer/plan rows it describes (and must survive their erasure).
  """
  use Samen.Migration

  @resources [Demo.BillingScope.SubscriptionEvent]

  def up do
    create table(:mov_subscription_event, primary_key: false) do
      add(:mov_subscription_id, :uuid, null: false)
      add(:mov_customer_id, :uuid)
      add(:mov_plan_id, :uuid)
      add(:mov_from_plan_id, :uuid)
      add(:mov_kind, :text, null: false)
      add(:mov_mrr_delta_cents, :integer, null: false, default: 0)
      add(:mov_mrr_before_cents, :integer, null: false, default: 0)
      add(:mov_mrr_after_cents, :integer, null: false, default: 0)
      add(:mov_from_status, :text)
      add(:mov_to_status, :text)
      add(:mov_reason, :text, default: "status_change")
      add(:mov_occurred_at, :utc_datetime, null: false)
      add(:mov_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:mov_org_id, :uuid, null: false)
      add(:mov_inserted_at, :utc_datetime, null: false)
      add(:mov_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:mov_subscription_event))
  end
end
