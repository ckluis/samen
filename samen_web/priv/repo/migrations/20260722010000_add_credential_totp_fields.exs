defmodule Samen.WebTest.Repo.Migrations.AddCredentialTotpFields do
  @moduledoc """
  ADR-035 §5 A7 (T07) — TOTP 2FA + vaulted recovery codes on the samen_web test
  host's Operator Identity mount (`woc_credential`). Four additive columns:

    * `pii_woc_totp_secret`         — 🔒 vault-routed (`:pii_secret`), holds a
      `vt_*` token only (never plaintext — INV-1). Base64-encoded raw secret.
    * `pii_woc_recovery_codes`      — 🔒 vault-routed (`:pii_secret`), holds a
      `vt_*` token only; the encrypted payload is a JSON array of
      `{digest, used_at}` — never the raw codes.
    * `woc_totp_enabled_at`         — plain nullable timestamp, non-PII.
    * `woc_totp_last_verified_at`   — plain nullable timestamp, non-PII (the
      anti-replay watermark).

  Mirrors the `add_org_max_concurrent_sessions` add-column precedent: a plain
  additive change on an already-cataloged table needs no `catalog_sync` (the
  two vaulted columns are `text` — the vault column type, same shape every
  other `pii_attribute` scalar column takes; see `webhook`'s
  `pii_pwh_signing_secret` precedent).
  """
  use Ecto.Migration

  def up do
    alter table(:woc_credential) do
      # Scalar pii_attribute storage carries the `pii_<abbrev>_<name>` prefix
      # (`Samen.Transformers.MaterializePii.source_for/2` — the Webhook
      # `pii_pwh_signing_secret` precedent), NOT the plain `woc_` prefix.
      add(:pii_woc_totp_secret, :text)
      add(:pii_woc_recovery_codes, :text)
      add(:woc_totp_enabled_at, :utc_datetime)
      add(:woc_totp_last_verified_at, :utc_datetime)
    end
  end

  def down do
    alter table(:woc_credential) do
      remove(:woc_totp_last_verified_at)
      remove(:woc_totp_enabled_at)
      remove(:pii_woc_recovery_codes)
      remove(:pii_woc_totp_secret)
    end
  end
end
