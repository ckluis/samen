defmodule Driftwood.Repo.Migrations.AddCredentialTotpFields do
  @moduledoc """
  ADR-035 §5 A7 (T07) — mirrors
  `samen_web/priv/repo/migrations/20260722010000_add_credential_totp_fields.exs`
  exactly, adapted to driftwood operator's `doc_credential` abbrev. Four
  additive columns: `pii_doc_totp_secret` / `pii_doc_recovery_codes` (🔒
  vault-routed, `:pii_secret` — `text` columns holding a `vt_*` token only,
  INV-1; scalar `pii_attribute` storage carries the `pii_<abbrev>_<name>`
  prefix — `Samen.Transformers.MaterializePii.source_for/2`, the Webhook
  `pii_pwh_signing_secret` precedent) and `doc_totp_enabled_at` /
  `doc_totp_last_verified_at` (plain nullable timestamps, non-PII). Plain
  additive column add on an already-cataloged table — no `catalog_sync`
  needed (the `add_api_key_expiry_fields` precedent).
  """
  use Ecto.Migration

  def up do
    alter table(:doc_credential) do
      add(:pii_doc_totp_secret, :text)
      add(:pii_doc_recovery_codes, :text)
      add(:doc_totp_enabled_at, :utc_datetime)
      add(:doc_totp_last_verified_at, :utc_datetime)
    end
  end

  def down do
    alter table(:doc_credential) do
      remove(:doc_totp_last_verified_at)
      remove(:doc_totp_enabled_at)
      remove(:pii_doc_recovery_codes)
      remove(:pii_doc_totp_secret)
    end
  end
end
