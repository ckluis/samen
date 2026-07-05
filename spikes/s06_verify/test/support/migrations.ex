defmodule S06Verify.Migrations do
  @moduledoc "Migration modules used by the S0.6 verifier test fixtures."

  # -------------------------------------------------------------------
  # Bootstrap: creates catalog tables + com_contact with all columns
  # catalogued correctly. After this the verifier should pass (no violations).
  # -------------------------------------------------------------------
  defmodule Bootstrap do
    use Samen.Migration

    def change do
      create_catalog_tables()

      create table(:com_contact, primary_key: false) do
        add(:com_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
        add(:com_name, :text)
        add(:com_org_id, :uuid, null: false)
        add(:com_email, :text)
      end

      catalog_sync([S06Verify.Crm.Contact])
    end
  end

  # -------------------------------------------------------------------
  # AddUncataloguedColumn: adds com_phone to the physical table WITHOUT
  # calling catalog_sync. Simulates a developer who forgot the catalog
  # step. The verifier must detect com_phone as an uncatalogued column
  # and exit 1.
  # -------------------------------------------------------------------
  defmodule AddUncataloguedColumn do
    use Samen.Migration

    def change do
      alter table(:com_contact) do
        add(:com_phone, :text)
      end

      # Deliberately NOT calling catalog_sync — this is the violation we test.
    end
  end

  # -------------------------------------------------------------------
  # InsertOrphanCatalogRow: inserts a fld_field row for a column that
  # does NOT exist in the physical table. Simulates a stale catalog row
  # left behind when a column was dropped without updating the catalog.
  # The verifier must detect the orphan and exit 1.
  # -------------------------------------------------------------------
  defmodule InsertOrphanCatalogRow do
    use Samen.Migration

    def change do
      execute(
        # up: insert orphan row
        "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) " <>
          "VALUES ('com_contact', 'com_old_field', 'old_field', 'String') " <>
          "ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING",
        # down: remove it
        "DELETE FROM fld_field WHERE fld_table_name = 'com_contact' AND fld_column_name = 'com_old_field'"
      )
    end
  end
end
