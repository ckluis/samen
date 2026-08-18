defmodule Samen.WebTest.Repo.Migrations.RichTypesItem do
  @moduledoc """
  ADR-036 H7 (T15 done-criteria 3/4): `rti_item` — the samen_web round-trip
  matrix fixture table backing `Samen.WebTest.RichTypes.Item`. Mirrors the
  samen_core T13/T14 `sro_org_fixture`/`srp_personal_fixture` split in ONE
  table: plain (non-vaulted) columns for the non-PII-by-type family (money/
  percent/score/duration/priority/website) + vaulted `Samen.Type.VaultField`
  `:text` columns (holding an opaque `vt_*` token) for the PII-by-type family
  (email/phone — scalar, `pii_` prefix; address — composite, abbrev prefix,
  NO `pii_` prefix, per `Samen.Type.Address`'s routing convention).

  `money_with_currency` is already installed for `Samen.WebTest.Repo`
  (`20260721020000_install_ash_money_extension.exs`, T12) — no extension work
  needed here.
  """
  use Samen.Migration

  @resources [Samen.WebTest.RichTypes.Item]

  def up do
    create table(:rti_item, primary_key: false) do
      add(:rti_name, :text)
      add(:rti_money, :money_with_currency)
      add(:rti_percent, :decimal)
      add(:rti_score, :decimal)
      add(:rti_duration, :integer)
      add(:rti_priority, :integer)
      add(:rti_website, :text)
      add(:rti_contact_email, :text)
      add(:rti_contact_phone, :text)
      add(:rti_mailing_address, :map)
      add(:pii_rti_email, :text)
      add(:pii_rti_phone, :text)
      add(:rti_address, :text)
      add(:rti_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:rti_org_id, :uuid, null: false)
      add(:rti_inserted_at, :utc_datetime, null: false)
      add(:rti_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:rti_item))
  end
end
