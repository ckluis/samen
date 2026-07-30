defmodule Driftwood.Repo.Migrations.AddSalesOpsScope do
  @moduledoc """
  Mounts the SalesOps universal scope (F6+F7, T48) into Driftwood's Postgres,
  and catalogs the resources in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `20260729150000_add_locations_scope.exs`. Requires
  `20260707100000_driftwood_resources` (the `fpr_person`/`fop_opportunity` FK
  targets `Lead.convert` links to) to have run first.

    * `dvs_vendor` — Vendor: `name`/`website`/`status`/`notes`/`custom` + one
      embedded vendor contact (🔒 `dvs_contact_name`/`dvs_contact_emails`/
      `dvs_contact_phones` — composite routing, no `pii_` prefix). Archivable.
    * `dls_lead`   — Lead: 🔒 `dls_full_name`/`dls_emails`/`dls_phones`
      (composite, no `pii_` prefix), `dls_value` typed `money_with_currency`
      (H1/T12), `dls_converted_person_id` → `fpr_person`,
      `dls_converted_opportunity_id` → `fop_opportunity` (re-identified as
      **Load** under `Driftwood.Context`, DECISION L). Archivable.
  """
  use Samen.Migration

  @resources [
    Driftwood.SalesOps.Vendor,
    Driftwood.SalesOps.Lead
  ]

  def up do
    create table(:dvs_vendor, primary_key: false) do
      add(:dvs_name, :text, null: false)
      add(:dvs_website, :text)
      add(:dvs_status, :text, default: "active")
      add(:dvs_notes, :text)
      add(:dvs_custom, :map, default: fragment("'{}'::jsonb"))
      add(:dvs_contact_name, :text)
      add(:dvs_contact_emails, :text)
      add(:dvs_contact_phones, :text)
      add(:dvs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dvs_org_id, :uuid, null: false)
      add(:dvs_inserted_at, :utc_datetime, null: false)
      add(:dvs_updated_at, :utc_datetime, null: false)
      add(:dvs_archived_at, :utc_datetime_usec)
    end

    create(index(:dvs_vendor, [:dvs_org_id]))

    create table(:dls_lead, primary_key: false) do
      add(:dls_full_name, :text)
      add(:dls_emails, :text)
      add(:dls_phones, :text)
      add(:dls_company_name, :text)
      add(:dls_source, :text, default: "other")
      add(:dls_status, :text, default: "new")
      add(:dls_value, :money_with_currency)
      add(:dls_notes, :text)
      add(:dls_custom, :map, default: fragment("'{}'::jsonb"))
      add(:dls_converted_at, :utc_datetime_usec)

      add(
        :dls_converted_person_id,
        references(:fpr_person,
          column: :fpr_id,
          name: "dls_lead_dls_converted_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :dls_converted_opportunity_id,
        references(:fop_opportunity,
          column: :fop_id,
          name: "dls_lead_dls_converted_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dls_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dls_org_id, :uuid, null: false)
      add(:dls_inserted_at, :utc_datetime, null: false)
      add(:dls_updated_at, :utc_datetime, null: false)
      add(:dls_archived_at, :utc_datetime_usec)
    end

    create(index(:dls_lead, [:dls_org_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:dls_lead))
    drop(table(:dvs_vendor))
  end
end
