defmodule Samen.Delivery.DeliverabilityMigration do
  @moduledoc """
  Shared DDL + catalog rows for the `dlv_email_event` + `dlv_suppression` C4/T30
  tables (ADR-038 §4.4). Encoded once here — the `Samen.Webhook.EventMigration`
  precedent — so every repo's migration is a two-line delegate and the copies
  (samen_core test repo, samen_web scratch repo, demo, driftwood, pawchart) can
  NEVER drift.

  Both tables are kernel infrastructure backed by plain `Ecto.Schema`s
  (`Samen.Delivery.EmailEvent` / `Samen.Delivery.Suppression`), NOT per-tenant Ash
  blueprints — so, like `whk_event`, they are exempt from the abbrev registry +
  `catalog_parity`'s resource->tam_table check (not `Ash.Resource.Info`-visible),
  but STILL get real `tam_table`/`fld_field` catalog rows (written by direct
  `execute/2` SQL in the SAME migration transaction as the DDL) so operator/doc
  tooling can see them.

  Usage in a repo migration:

      defmodule MyApp.Repo.Migrations.DeliverabilityTables do
        use Ecto.Migration
        def up, do: Samen.Delivery.DeliverabilityMigration.up()
        def down, do: Samen.Delivery.DeliverabilityMigration.down()
      end
  """

  import Ecto.Migration

  @email_event_table "dlv_email_event"
  @email_event_resource "Samen.Delivery.EmailEvent"

  @email_event_fields [
    {"dlv_id", "id", "UUID"},
    {"dlv_provider", "provider", "String"},
    {"dlv_provider_event_id", "provider_event_id", "String"},
    {"dlv_provider_message_id", "provider_message_id", "String"},
    {"dlv_kind", "kind", "String"},
    {"dlv_send_id", "send_id", "UUID"},
    {"dlv_org_id", "org_id", "UUID"},
    {"dlv_subscriber_id", "subscriber_id", "UUID"},
    {"dlv_occurred_at", "occurred_at", "UTCDatetime"},
    {"dlv_inserted_at", "inserted_at", "UTCDatetime"}
  ]

  @suppression_table "dlv_suppression"
  @suppression_resource "Samen.Delivery.Suppression"

  @suppression_fields [
    {"dlv_id", "id", "UUID"},
    {"dlv_org_id", "org_id", "UUID"},
    {"dlv_subscriber_id", "subscriber_id", "UUID"},
    {"dlv_reason", "reason", "String"},
    {"dlv_source_provider", "source_provider", "String"},
    {"dlv_inserted_at", "inserted_at", "UTCDatetime"}
  ]

  @doc "Create both tables + indexes + catalog rows (in one transaction)."
  def up do
    execute(
      """
      CREATE TABLE #{@email_event_table} (
        dlv_id                  UUID        NOT NULL DEFAULT gen_random_uuid(),
        dlv_provider             TEXT        NOT NULL,
        dlv_provider_event_id    TEXT        NOT NULL,
        dlv_provider_message_id  TEXT,
        dlv_kind                 TEXT        NOT NULL,
        dlv_send_id              UUID,
        dlv_org_id               UUID        NOT NULL,
        dlv_subscriber_id        UUID        NOT NULL,
        dlv_occurred_at          TIMESTAMPTZ NOT NULL,
        dlv_inserted_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (dlv_id)
      )
      """,
      "DROP TABLE IF EXISTS #{@email_event_table}"
    )

    # The replay arbiter: {provider, provider_event_id} is globally unique — a
    # webhook processing retry that re-dispatches the SAME vendor event is a
    # safe no-op here too (ADR-038 §4.4/§5.2 idempotency).
    execute(
      """
      CREATE UNIQUE INDEX dlv_email_event_provider_event_id_index
      ON #{@email_event_table} (dlv_provider, dlv_provider_event_id)
      """,
      "DROP INDEX IF EXISTS dlv_email_event_provider_event_id_index"
    )

    execute(
      """
      CREATE INDEX dlv_email_event_org_subscriber_index
      ON #{@email_event_table} (dlv_org_id, dlv_subscriber_id)
      """,
      "DROP INDEX IF EXISTS dlv_email_event_org_subscriber_index"
    )

    execute(
      """
      CREATE TABLE #{@suppression_table} (
        dlv_id               UUID        NOT NULL DEFAULT gen_random_uuid(),
        dlv_org_id           UUID        NOT NULL,
        dlv_subscriber_id    UUID        NOT NULL,
        dlv_reason           TEXT        NOT NULL,
        dlv_source_provider  TEXT,
        dlv_inserted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (dlv_id)
      )
      """,
      "DROP TABLE IF EXISTS #{@suppression_table}"
    )

    # The chokepoint's suppressed?/2 arbiter: one row per (org, subscriber).
    execute(
      """
      CREATE UNIQUE INDEX dlv_suppression_org_subscriber_index
      ON #{@suppression_table} (dlv_org_id, dlv_subscriber_id)
      """,
      "DROP INDEX IF EXISTS dlv_suppression_org_subscriber_index"
    )

    for {table, resource, fields} <- [
          {@email_event_table, @email_event_resource, @email_event_fields},
          {@suppression_table, @suppression_resource, @suppression_fields}
        ] do
      execute(
        """
        INSERT INTO tam_table (tam_table_name, tam_resource)
        VALUES ('#{table}', '#{resource}')
        ON CONFLICT (tam_table_name) DO NOTHING
        """,
        "DELETE FROM tam_table WHERE tam_table_name = '#{table}'"
      )

      for {col, logical, type} <- fields do
        execute(
          """
          INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
          VALUES ('#{table}', '#{col}', '#{logical}', '#{type}')
          ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
          """,
          """
          DELETE FROM fld_field
          WHERE fld_table_name = '#{table}' AND fld_column_name = '#{col}'
          """
        )
      end
    end
  end

  @doc "Drop the catalog rows, indexes, and tables (reverse order)."
  def down do
    for {table, fields} <- [
          {@suppression_table, @suppression_fields},
          {@email_event_table, @email_event_fields}
        ] do
      for {col, _logical, _type} <- Enum.reverse(fields) do
        execute("""
        DELETE FROM fld_field
        WHERE fld_table_name = '#{table}' AND fld_column_name = '#{col}'
        """)
      end

      execute("DELETE FROM tam_table WHERE tam_table_name = '#{table}'")
    end

    execute("DROP INDEX IF EXISTS dlv_suppression_org_subscriber_index")
    execute("DROP TABLE IF EXISTS #{@suppression_table}")
    execute("DROP INDEX IF EXISTS dlv_email_event_org_subscriber_index")
    execute("DROP INDEX IF EXISTS dlv_email_event_provider_event_id_index")
    execute("DROP TABLE IF EXISTS #{@email_event_table}")
  end
end
