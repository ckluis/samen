defmodule Samen.Webhook.EventMigration do
  @moduledoc """
  Shared DDL + catalog rows for the `whk_event` webhook ingress store (ADR-038 §5.3;
  T19/B9). Encoded once here so every repo's migration is a two-line delegate and the
  five copies (samen_core test repo, samen_web scratch repo, demo, driftwood, pawchart)
  can NEVER drift — the aud_event precedent duplicated the DDL by hand; this does not.

  `whk_event` is kernel infrastructure backed by a plain `Ecto.Schema`
  (`Samen.Webhook.Event`), NOT a per-tenant Ash blueprint — so its catalog rows are
  written by direct `execute/2` SQL inside the migration's transaction (the same
  DDL + catalog atomicity guarantee `Samen.Migration` gives Ash resources), and it is
  exempt from the abbrev registry + `catalog_parity` resource→tam_table check (it is
  not `Ash.Resource.Info`-visible). Unlike `aud_event` the table is NOT append-only —
  the DLQ state machine UPDATEs `whk_status` — so there is no REVOKE/trigger.

  Usage in a repo migration:

      defmodule MyApp.Repo.Migrations.WebhookEvent do
        use Ecto.Migration
        def up, do: Samen.Webhook.EventMigration.up()
        def down, do: Samen.Webhook.EventMigration.down()
      end
  """

  import Ecto.Migration

  @table "whk_event"
  @resource "Samen.Webhook.Event"

  # {physical column, logical name, catalog type}
  @fields [
    {"whk_id", "id", "UUID"},
    {"whk_provider", "provider", "String"},
    {"whk_event_id", "event_id", "String"},
    {"whk_kind", "kind", "String"},
    {"whk_domain", "domain", "String"},
    {"whk_occurred_at", "occurred_at", "UTCDatetime"},
    {"whk_payload", "payload", "Map"},
    {"whk_status", "status", "String"},
    {"whk_attempt_count", "attempt_count", "Integer"},
    {"whk_last_error", "last_error", "String"},
    {"whk_processed_at", "processed_at", "UTCDatetime"},
    {"whk_org_id", "org_id", "UUID"},
    {"whk_inserted_at", "inserted_at", "UTCDatetime"}
  ]

  @doc "Create the `whk_event` table + indexes + catalog rows (in one transaction)."
  def up do
    execute(
      """
      CREATE TABLE #{@table} (
        whk_id            UUID        NOT NULL DEFAULT gen_random_uuid(),
        whk_provider      TEXT        NOT NULL,
        whk_event_id      TEXT        NOT NULL,
        whk_kind          TEXT        NOT NULL,
        whk_domain        TEXT        NOT NULL DEFAULT 'unknown',
        whk_occurred_at   TIMESTAMPTZ NOT NULL,
        whk_payload       JSONB       NOT NULL DEFAULT '{}'::jsonb,
        whk_status        TEXT        NOT NULL DEFAULT 'received',
        whk_attempt_count INTEGER     NOT NULL DEFAULT 0,
        whk_last_error    TEXT,
        whk_processed_at  TIMESTAMPTZ,
        whk_org_id        UUID,
        whk_inserted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (whk_id)
      )
      """,
      "DROP TABLE IF EXISTS #{@table}"
    )

    # The replay arbiter: {provider, event_id} is globally unique. A duplicate delivery
    # (even concurrent) collides here and the ingress treats it as a 200 no-op (§5.2).
    execute(
      """
      CREATE UNIQUE INDEX whk_event_provider_event_id_index
      ON #{@table} (whk_provider, whk_event_id)
      """,
      "DROP INDEX IF EXISTS whk_event_provider_event_id_index"
    )

    # The operator DLQ listing orders dead-first then recent — index the drive columns.
    execute(
      """
      CREATE INDEX whk_event_status_inserted_at_index
      ON #{@table} (whk_status, whk_inserted_at DESC)
      """,
      "DROP INDEX IF EXISTS whk_event_status_inserted_at_index"
    )

    # Catalog rows for the table (same-transaction as the DDL — atomic).
    execute(
      """
      INSERT INTO tam_table (tam_table_name, tam_resource)
      VALUES ('#{@table}', '#{@resource}')
      ON CONFLICT (tam_table_name) DO NOTHING
      """,
      "DELETE FROM tam_table WHERE tam_table_name = '#{@table}'"
    )

    for {col, logical, type} <- @fields do
      execute(
        """
        INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
        VALUES ('#{@table}', '#{col}', '#{logical}', '#{type}')
        ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
        """,
        """
        DELETE FROM fld_field
        WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'
        """
      )
    end
  end

  @doc "Drop the catalog rows, indexes, and table (reverse order)."
  def down do
    for {col, _logical, _type} <- Enum.reverse(@fields) do
      execute("""
      DELETE FROM fld_field
      WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{col}'
      """)
    end

    execute("DELETE FROM tam_table WHERE tam_table_name = '#{@table}'")
    execute("DROP INDEX IF EXISTS whk_event_status_inserted_at_index")
    execute("DROP INDEX IF EXISTS whk_event_provider_event_id_index")
    execute("DROP TABLE IF EXISTS #{@table}")
  end
end
