defmodule Driftwood.Repo.Migrations.FreightApiKey do
  @moduledoc """
  F1 (Gate-5 carry) — the two-key-class API credential the public `/api/v1` auth resolver
  reads. Creates `dak_api_key` (abbrev `dak`) and catalogs it in the SAME transaction
  (ADR-004 catalog-in-tx), so `catalog_parity` sees the new resource. Self-contained on
  the freight vertical (driftwood mounts no Identity scope) — the row carries the plane,
  declared scopes, minter role + user id, and a one-way `token_digest` (never the key).
  """
  use Samen.Migration

  @resources [Driftwood.Freight.ApiKey]

  def up do
    create table(:dak_api_key, primary_key: false) do
      # One-way SHA-256 digest of the key material. NEVER the raw key.
      add(:dak_token_digest, :text, null: false)
      add(:dak_plane, :text, null: false, default: "tenant")
      add(:dak_scopes, :map, default: fragment("'{}'::jsonb"))
      add(:dak_minter_role, :text)
      add(:dak_minter_user_id, :text)
      add(:dak_revoked_at, :utc_datetime)

      add(:dak_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dak_org_id, :uuid, null: false)
      add(:dak_inserted_at, :utc_datetime, null: false)
      add(:dak_updated_at, :utc_datetime, null: false)
    end

    # Look up keys by digest fast (the auth resolver's hot path).
    create(index(:dak_api_key, [:dak_token_digest]))

    # --- catalog the new resource in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:dak_api_key))
  end
end
