defmodule PawChart.Repo.Migrations.AddAnalyticsScope do
  @moduledoc """
  WS-B / Phase B9 (AC-X1, ADR-021): the governed, token-blind product-analytics
  event ledger (`vae`) — `PawChart.Analytics.ProductEvent`, the vertical mount of
  the Analytics scope on demo's `AddAnalyticsScope` (pae) pattern. Catalogued in
  the SAME transaction (ADR-004 catalog-in-tx).

  Token-blind by construction: every column is a bounded id (uuid), a bounded enum
  (event_name/event_kind as text), a per-subject HMAC pseudonym token
  (vae_actor_ref), an opaque bounded ref (vae_entity_ref), a bounded map (vae_props),
  or a timestamp — NO PII column. Rows are appended ONLY by
  `Samen.Analytics.track/1`, which refuses PII at capture.
  """
  use Samen.Migration

  @resources [PawChart.Analytics.ProductEvent]

  def up do
    create table(:vae_product_event, primary_key: false) do
      add(:vae_actor_ref, :text)
      add(:vae_event_name, :text, null: false)
      add(:vae_entity_ref, :text)
      add(:vae_event_kind, :text)
      add(:vae_props, :map, null: false, default: "{}")
      add(:vae_occurred_at, :utc_datetime, null: false)
      add(:vae_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:vae_org_id, :uuid, null: false)
      add(:vae_inserted_at, :utc_datetime, null: false)
      add(:vae_updated_at, :utc_datetime, null: false)
    end

    # Read paths filter by (org_id, event_name, occurred_at) for the seed funnel /
    # retention rollup (B8). A bounded, non-PII composite index.
    create index(:vae_product_event, [:vae_org_id, :vae_event_name, :vae_occurred_at])

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:vae_product_event))
  end
end
