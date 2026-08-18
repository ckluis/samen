defmodule Demo.Repo.Migrations.AddSalesOpsScope do
  @moduledoc """
  Mounts the SalesOps universal scope (F6+F7, T48) into the demo host's one
  Postgres, and catalogs the resources in the SAME migration transaction
  (ADR-004 catalog-in-tx). Mirrors `20260729150000_add_locations_scope.exs`.
  Requires `20260706010000_add_crm_scope` (the `per_person`/`opp_opportunity`
  FK targets `Lead.convert` links to) to have run first.

    * `dsv_vendor` — Vendor: `name`/`website`/`status`/`notes`/`custom` + one
      embedded vendor contact (🔒 `dsv_contact_name`/`dsv_contact_emails`/
      `dsv_contact_phones` — composite routing, no `pii_` prefix). Archivable.
    * `dsl_lead`   — Lead: 🔒 `dsl_full_name`/`dsl_emails`/`dsl_phones`
      (composite, no `pii_` prefix), `dsl_value` typed `money_with_currency`
      (H1/T12), `dsl_converted_person_id` → `per_person`,
      `dsl_converted_opportunity_id` → `opp_opportunity`. Archivable.
  """
  use Samen.Migration

  @resources [
    Demo.SalesOps.Vendor,
    Demo.SalesOps.Lead
  ]

  def up do
    create table(:dsv_vendor, primary_key: false) do
      add(:dsv_name, :text, null: false)
      add(:dsv_website, :text)
      add(:dsv_status, :text, default: "active")
      add(:dsv_notes, :text)
      add(:dsv_custom, :map, default: fragment("'{}'::jsonb"))
      add(:dsv_contact_name, :text)
      add(:dsv_contact_emails, :text)
      add(:dsv_contact_phones, :text)
      add(:dsv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dsv_org_id, :uuid, null: false)
      add(:dsv_inserted_at, :utc_datetime, null: false)
      add(:dsv_updated_at, :utc_datetime, null: false)
      add(:dsv_archived_at, :utc_datetime_usec)
    end

    create(index(:dsv_vendor, [:dsv_org_id]))

    create table(:dsl_lead, primary_key: false) do
      add(:dsl_full_name, :text)
      add(:dsl_emails, :text)
      add(:dsl_phones, :text)
      add(:dsl_company_name, :text)
      add(:dsl_source, :text, default: "other")
      add(:dsl_status, :text, default: "new")
      add(:dsl_value, :money_with_currency)
      add(:dsl_notes, :text)
      add(:dsl_custom, :map, default: fragment("'{}'::jsonb"))
      add(:dsl_converted_at, :utc_datetime_usec)

      add(
        :dsl_converted_person_id,
        references(:per_person,
          column: :per_id,
          name: "dsl_lead_dsl_converted_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :dsl_converted_opportunity_id,
        references(:opp_opportunity,
          column: :opp_id,
          name: "dsl_lead_dsl_converted_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dsl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dsl_org_id, :uuid, null: false)
      add(:dsl_inserted_at, :utc_datetime, null: false)
      add(:dsl_updated_at, :utc_datetime, null: false)
      add(:dsl_archived_at, :utc_datetime_usec)
    end

    create(index(:dsl_lead, [:dsl_org_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:dsl_lead))
    drop(table(:dsv_vendor))
  end
end
