defmodule Demo.Repo.Migrations.AddAnalyticsScope do
  @moduledoc """
  WS-B / Phase B7 (ADR-021): the governed, token-blind product-analytics event
  ledger (`pae`) — `Demo.Analytics.ProductEvent`. Catalogued in the SAME transaction
  (ADR-004 catalog-in-tx).

  Token-blind by construction: every column is a bounded id (uuid), a bounded enum
  (event_name/event_kind as text), a per-subject HMAC pseudonym token
  (pae_actor_ref), an opaque bounded ref (pae_entity_ref), a bounded map (pae_props),
  or a timestamp — NO PII column, no `pii_`-prefixed column, no `pii do` block.
  Rows are appended ONLY by `Samen.Analytics.track/1`, which refuses PII at capture.
  """
  use Samen.Migration

  @resources [Demo.Analytics.ProductEvent]

  def up do
    create table(:pae_product_event, primary_key: false) do
      add(:pae_actor_ref, :text)
      add(:pae_event_name, :text, null: false)
      add(:pae_entity_ref, :text)
      add(:pae_event_kind, :text)
      add(:pae_props, :map, null: false, default: "{}")
      add(:pae_occurred_at, :utc_datetime, null: false)
      add(:pae_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pae_org_id, :uuid, null: false)
      add(:pae_inserted_at, :utc_datetime, null: false)
      add(:pae_updated_at, :utc_datetime, null: false)
    end

    # Read paths filter by (org_id, event_name, occurred_at) for the seed funnel /
    # retention rollup (B8). A bounded, non-PII composite index.
    create index(:pae_product_event, [:pae_org_id, :pae_event_name, :pae_occurred_at])

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:pae_product_event))
  end
end
