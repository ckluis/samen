defmodule Driftwood.Repo.Migrations.AddConsentEventLedger do
  @moduledoc """
  F3 Unit 1: the append-only marketing-consent ledger (`consent_event`) —
  `Driftwood.Marketing.ConsentEvent`. Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  Token-blind by construction: every column is a bounded id (uuid), an enum
  (event/purpose as text), a bounded string (source), a keyed pseudonym
  (subject_hash), or a timestamp — NO vaulted PII column. The `fmv_subscriber_id`
  soft ref carries NO foreign-key constraint: the immutable ledger row is a historical
  fact that outlives (and must survive the crypto-shred of) the subscriber it describes.
  """
  use Samen.Migration

  @resources [Driftwood.Marketing.ConsentEvent]

  def up do
    create table(:fmv_consent_event, primary_key: false) do
      add(:fmv_subscriber_id, :uuid, null: false)
      add(:fmv_event, :text, null: false)
      add(:fmv_source, :text)
      add(:fmv_purpose, :text, default: "marketing")
      add(:fmv_subject_hash, :text)
      add(:fmv_occurred_at, :utc_datetime_usec, null: false)
      add(:fmv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fmv_org_id, :uuid, null: false)
      add(:fmv_inserted_at, :utc_datetime, null: false)
      add(:fmv_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:fmv_consent_event))
  end
end
