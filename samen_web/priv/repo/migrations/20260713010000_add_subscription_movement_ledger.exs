defmodule Samen.WebTest.Repo.Migrations.AddSubscriptionMovementLedger do
  @moduledoc """
  WS-B / Phase B1 (ADR-017): the append-only subscription-movement ledger (`mov`),
  mounted for BOTH samen_web test-support billing namespaces — the tenant mount
  (`Samen.WebTest.Billing.SubscriptionEvent`, abbrev `wbv`) and the operator mount
  (`Samen.WebTest.Operator.SubscriptionEvent`, abbrev `wpv`). Catalogued in the same
  transaction (ADR-004).

  Token-blind by construction (bounded ids/enums/ints/timestamps, no PII). Soft id
  refs carry no FK — the immutable ledger outlives the rows it describes.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Billing.SubscriptionEvent,
    Samen.WebTest.Operator.SubscriptionEvent
  ]

  defp create_ledger(prefix) do
    create table(:"#{prefix}_subscription_event", primary_key: false) do
      add(:"#{prefix}_subscription_id", :uuid, null: false)
      add(:"#{prefix}_customer_id", :uuid)
      add(:"#{prefix}_plan_id", :uuid)
      add(:"#{prefix}_from_plan_id", :uuid)
      add(:"#{prefix}_kind", :text, null: false)
      add(:"#{prefix}_mrr_delta_cents", :integer, null: false, default: 0)
      add(:"#{prefix}_mrr_before_cents", :integer, null: false, default: 0)
      add(:"#{prefix}_mrr_after_cents", :integer, null: false, default: 0)
      add(:"#{prefix}_from_status", :text)
      add(:"#{prefix}_to_status", :text)
      add(:"#{prefix}_reason", :text, default: "status_change")
      add(:"#{prefix}_occurred_at", :utc_datetime, null: false)

      add(:"#{prefix}_id", :uuid,
        null: false,
        default: fragment("gen_random_uuid()"),
        primary_key: true
      )

      add(:"#{prefix}_org_id", :uuid, null: false)
      add(:"#{prefix}_inserted_at", :utc_datetime, null: false)
      add(:"#{prefix}_updated_at", :utc_datetime, null: false)
    end
  end

  def up do
    create_ledger("wbv")
    create_ledger("wpv")
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:wbv_subscription_event))
    drop(table(:wpv_subscription_event))
  end
end
