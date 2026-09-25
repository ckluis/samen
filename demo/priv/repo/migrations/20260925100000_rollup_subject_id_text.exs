defmodule Demo.Repo.Migrations.RollupSubjectIdText do
  @moduledoc """
  Issue #47: `rol_subject_id` widens from `UUID` to `TEXT`.

  The column's documented domain is "bounded subject id (UUID / token)", and its source,
  `aud_event.aud_subject_id`, is a `:string` holding a subject UUID OR token
  (`Samen.AuditEvent.Schema`, `Samen.AuditChain`). Declared `UUID`, the rollup's rebuild
  had to cast the source to `uuid`, and the first token-subject row raised 22P02 and
  aborted the WHOLE rebuild transaction. `TEXT` holds both forms; every rollup consumer
  in lib already compares on `::text` (`Samen.Rollup` suppress arm). The unique
  dimension index is unaffected.

  The catalog row follows the column (`String`, matching `aud_subject_id`), in the same
  transaction.
  """

  use Ecto.Migration

  def up do
    execute "ALTER TABLE rol_daily_event_count ALTER COLUMN rol_subject_id TYPE TEXT USING rol_subject_id::text"

    execute """
    UPDATE fld_field SET fld_type = 'String'
    WHERE fld_table_name = 'rol_daily_event_count' AND fld_column_name = 'rol_subject_id'
    """
  end

  # Reversible only while every stored subject is UUID-shaped — which is exactly the
  # restriction this migration removes. A token row makes the cast fail loudly here,
  # rather than being dropped.
  def down do
    execute "ALTER TABLE rol_daily_event_count ALTER COLUMN rol_subject_id TYPE UUID USING rol_subject_id::uuid"

    execute """
    UPDATE fld_field SET fld_type = 'UUID'
    WHERE fld_table_name = 'rol_daily_event_count' AND fld_column_name = 'rol_subject_id'
    """
  end
end
