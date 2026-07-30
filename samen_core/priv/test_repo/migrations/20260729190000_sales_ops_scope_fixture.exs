defmodule SamenCore.TestRepo.Migrations.SalesOpsScopeFixture do
  @moduledoc """
  Tables for the SalesOps scope (F6+F7, T48): `ssv_vendor` + `sls_lead`, mounted
  in `samen_core` tests via `test/support/sales_ops_fixture.ex`. Requires
  `20260729180000_crm_scope_fixture` (the `scp_person`/`sco_opportunity` FK
  targets `Lead.convert` links to) to have run first.

    * `ssv_vendor` — Vendor (F6): `name`/`website`/`status`/`notes`/`custom` +
      one embedded vendor contact (🔒 `ssv_contact_name`/`ssv_contact_emails`/
      `ssv_contact_phones` — composite routing, no `pii_` prefix). Archivable.
    * `sls_lead`   — Lead (F7): 🔒 `sls_full_name`/`sls_emails`/`sls_phones`
      (composite, no `pii_` prefix), `sls_value` typed `money_with_currency`
      (H1/T12), `sls_converted_person_id` → `scp_person`, `sls_converted_opportunity_id`
      → `sco_opportunity`. Archivable.

  Catalog rows are written by `catalog_sync/1` in the SAME transaction (ADR-004).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.SalesOpsFixture.Vendor,
    SamenCore.Support.SalesOpsFixture.Lead
  ]

  def up do
    create table(:ssv_vendor, primary_key: false) do
      add(:ssv_name, :text, null: false)
      add(:ssv_website, :text)
      add(:ssv_status, :text, default: "active")
      add(:ssv_notes, :text)
      add(:ssv_custom, :map, default: fragment("'{}'::jsonb"))
      add(:ssv_contact_name, :text)
      add(:ssv_contact_emails, :text)
      add(:ssv_contact_phones, :text)
      add(:ssv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ssv_org_id, :uuid, null: false)
      add(:ssv_inserted_at, :utc_datetime, null: false)
      add(:ssv_updated_at, :utc_datetime, null: false)
      add(:ssv_archived_at, :utc_datetime_usec)
    end

    create(index(:ssv_vendor, [:ssv_org_id]))

    create table(:sls_lead, primary_key: false) do
      add(:sls_full_name, :text)
      add(:sls_emails, :text)
      add(:sls_phones, :text)
      add(:sls_company_name, :text)
      add(:sls_source, :text, default: "other")
      add(:sls_status, :text, default: "new")
      add(:sls_value, :money_with_currency)
      add(:sls_notes, :text)
      add(:sls_custom, :map, default: fragment("'{}'::jsonb"))
      add(:sls_converted_at, :utc_datetime_usec)

      add(
        :sls_converted_person_id,
        references(:scp_person,
          column: :scp_id,
          name: "sls_lead_sls_converted_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :sls_converted_opportunity_id,
        references(:sco_opportunity,
          column: :sco_id,
          name: "sls_lead_sls_converted_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:sls_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sls_org_id, :uuid, null: false)
      add(:sls_inserted_at, :utc_datetime, null: false)
      add(:sls_updated_at, :utc_datetime, null: false)
      add(:sls_archived_at, :utc_datetime_usec)
    end

    create(index(:sls_lead, [:sls_org_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sls_lead))
    drop(table(:ssv_vendor))
  end
end
