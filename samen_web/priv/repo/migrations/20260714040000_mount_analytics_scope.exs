defmodule Samen.WebTest.Repo.Migrations.MountAnalyticsScope do
  @moduledoc """
  WS-B / Phase B7 (ADR-021) — mounts the Analytics scope table for the samen_web test
  host (`Samen.WebTest.Analytics.ProductEvent`, abbrev `wan`), and catalogs it in the
  SAME migration transaction (ADR-004 catalog-in-tx). Mirrors demo's `AddAnalyticsScope`.

  This gives `samen_web` a REAL `pae`-shaped ledger so the framework choke-point
  integration test (`analytics_choke_points_test.exs`) can drive a real flow (the CRM
  create path, the list-filter search path, the session controller) and assert the
  resulting row LANDS — best-effort, token-blind.

  Token-blind by construction: every column is a bounded id (uuid), a bounded enum
  (event_name/event_kind as text), a per-subject HMAC pseudonym token (wan_actor_ref),
  an opaque bounded ref (wan_entity_ref), a bounded map (wan_props), or a timestamp — NO
  PII column, no `pii_`-prefixed column.
  """
  use Samen.Migration

  @resources [Samen.WebTest.Analytics.ProductEvent]

  def up do
    create table(:wan_product_event, primary_key: false) do
      add(:wan_actor_ref, :text)
      add(:wan_event_name, :text, null: false)
      add(:wan_entity_ref, :text)
      add(:wan_event_kind, :text)
      add(:wan_props, :map, null: false, default: "{}")
      add(:wan_occurred_at, :utc_datetime, null: false)
      add(:wan_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wan_org_id, :uuid, null: false)
      add(:wan_inserted_at, :utc_datetime, null: false)
      add(:wan_updated_at, :utc_datetime, null: false)
    end

    create index(:wan_product_event, [:wan_org_id, :wan_event_name, :wan_occurred_at])

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:wan_product_event))
  end
end
