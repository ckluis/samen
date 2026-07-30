defmodule PawChart.Repo.Migrations.AddSalesOpsScope do
  @moduledoc """
  Mounts the SalesOps universal scope (F6+F7, T48) into PawChart's Postgres,
  and catalogs the resources in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `20260729150000_add_locations_scope.exs`. Requires
  `20260708200000_pawchart_crm_support_scopes` (the `vcb_person`/
  `vcd_opportunity` FK targets `Lead.convert` links to) to have run first.

    * `psv_vendor` — Vendor: `name`/`website`/`status`/`notes`/`custom` + one
      embedded vendor contact (🔒 `psv_contact_name`/`psv_contact_emails`/
      `psv_contact_phones` — composite routing, no `pii_` prefix). Archivable.
    * `psl_lead`   — Lead: 🔒 `psl_full_name`/`psl_emails`/`psl_phones`
      (composite, no `pii_` prefix), `psl_value` typed `money_with_currency`
      (H1/T12), `psl_converted_person_id` → `vcb_person`,
      `psl_converted_opportunity_id` → `vcd_opportunity`. Archivable.
  """
  use Samen.Migration

  @resources [
    PawChart.SalesOps.Vendor,
    PawChart.SalesOps.Lead
  ]

  def up do
    create table(:psv_vendor, primary_key: false) do
      add(:psv_name, :text, null: false)
      add(:psv_website, :text)
      add(:psv_status, :text, default: "active")
      add(:psv_notes, :text)
      add(:psv_custom, :map, default: fragment("'{}'::jsonb"))
      add(:psv_contact_name, :text)
      add(:psv_contact_emails, :text)
      add(:psv_contact_phones, :text)
      add(:psv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:psv_org_id, :uuid, null: false)
      add(:psv_inserted_at, :utc_datetime, null: false)
      add(:psv_updated_at, :utc_datetime, null: false)
      add(:psv_archived_at, :utc_datetime_usec)
    end

    create(index(:psv_vendor, [:psv_org_id]))

    create table(:psl_lead, primary_key: false) do
      add(:psl_full_name, :text)
      add(:psl_emails, :text)
      add(:psl_phones, :text)
      add(:psl_company_name, :text)
      add(:psl_source, :text, default: "other")
      add(:psl_status, :text, default: "new")
      add(:psl_value, :money_with_currency)
      add(:psl_notes, :text)
      add(:psl_custom, :map, default: fragment("'{}'::jsonb"))
      add(:psl_converted_at, :utc_datetime_usec)

      add(
        :psl_converted_person_id,
        references(:vcb_person,
          column: :vcb_id,
          name: "psl_lead_psl_converted_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :psl_converted_opportunity_id,
        references(:vcd_opportunity,
          column: :vcd_id,
          name: "psl_lead_psl_converted_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:psl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:psl_org_id, :uuid, null: false)
      add(:psl_inserted_at, :utc_datetime, null: false)
      add(:psl_updated_at, :utc_datetime, null: false)
      add(:psl_archived_at, :utc_datetime_usec)
    end

    create(index(:psl_lead, [:psl_org_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:psl_lead))
    drop(table(:psv_vendor))
  end
end
