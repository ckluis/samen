defmodule Samen.WebTest.Repo.Migrations.AddConsentEventLedger do
  @moduledoc """
  F3 Unit 1: the append-only marketing-consent ledger (`consent_event`) —
  `Samen.WebTest.Marketing.ConsentEvent`. Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  Token-blind by construction: every column is a bounded id (uuid), an enum
  (event/purpose as text), a bounded string (source), a keyed pseudonym
  (subject_hash), or a timestamp — NO vaulted PII column. The `wmv_subscriber_id`
  soft ref carries NO foreign-key constraint: the immutable ledger row is a historical
  fact that outlives (and must survive the crypto-shred of) the subscriber it describes.
  """
  use Samen.Migration

  @resources [Samen.WebTest.Marketing.ConsentEvent]

  def up do
    create table(:wmv_consent_event, primary_key: false) do
      add(:wmv_subscriber_id, :uuid, null: false)
      add(:wmv_event, :text, null: false)
      add(:wmv_source, :text)
      add(:wmv_purpose, :text, default: "marketing")
      add(:wmv_subject_hash, :text)
      add(:wmv_occurred_at, :utc_datetime_usec, null: false)
      add(:wmv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wmv_org_id, :uuid, null: false)
      add(:wmv_inserted_at, :utc_datetime, null: false)
      add(:wmv_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:wmv_consent_event))
  end
end
