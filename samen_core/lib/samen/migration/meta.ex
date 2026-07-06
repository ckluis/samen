defmodule Samen.Migration.Meta do
  @moduledoc """
  `samen_migration_meta` — the bake-window ledger for expand/contract migrations (T2.4d).

  ## Why a table

  The doc's `contract_ready?` gate refuses to run the destructive contract phase
  "until the expand-phase code has been the only code in production for a full bake
  window." "Has been the only code" is a *time* property — the contract migration
  needs a durable record of *when the paired expand release landed*. That record is
  a row in `samen_migration_meta`, written by the expand migration, read by the
  contract gate.

  A migration file's own timestamp is NOT a substitute: migration files are
  generated at author time, but the bake window starts at *deploy* time (when the
  expand ran against production). Only a row written *by the expand's `up/0`* (via
  `now()` at run time) captures the real deploy instant.

  ## Schema

      samen_migration_meta
        smm_id            uuid  pk
        smm_change_key    text  unique  -- logical name pairing expand↔contract
        smm_phase         text          -- 'expand' | 'contract'
        smm_expanded_at   timestamptz   -- set by the expand; the bake clock start
        smm_contracted_at timestamptz   -- set by the contract when it runs
        smm_migration     text          -- the migration module that wrote the row

  One row per `change_key`. The expand `up/0` INSERTs it with `smm_phase='expand'`
  and `smm_expanded_at = now()`. The contract gate reads `smm_expanded_at` and
  compares `now() - smm_expanded_at` against the configured bake window.

  ## Bake window configuration

      config :samen_core, :contract_bake_window, {7, :day}   # default

  A `{amount, unit}` tuple where unit ∈ `:second | :minute | :hour | :day`. The
  default is 7 days. Tests override it to seconds to exercise the gate without
  waiting.
  """

  @table "samen_migration_meta"

  @default_bake_window {7, :day}

  @doc "The physical table name."
  def table, do: @table

  @doc """
  DDL to create `samen_migration_meta`. Call once from a bootstrap migration
  (like `create_catalog_tables/0`). Idempotent via `IF NOT EXISTS`.
  """
  def create_table_sql do
    """
    CREATE TABLE IF NOT EXISTS #{@table} (
      smm_id            UUID        NOT NULL DEFAULT gen_random_uuid(),
      smm_change_key    TEXT        NOT NULL,
      smm_phase         TEXT        NOT NULL,
      smm_expanded_at   TIMESTAMPTZ,
      smm_contracted_at TIMESTAMPTZ,
      smm_migration     TEXT        NOT NULL,
      PRIMARY KEY (smm_id),
      CONSTRAINT #{@table}_change_key_uidx UNIQUE (smm_change_key),
      CONSTRAINT #{@table}_phase_check CHECK (smm_phase IN ('expand', 'contract'))
    )
    """
  end

  @doc "Drop DDL (for a bootstrap migration's `down/0`)."
  def drop_table_sql, do: "DROP TABLE IF EXISTS #{@table}"

  @doc false
  def insert_expand_sql(change_key, migration) do
    """
    INSERT INTO #{@table} (smm_change_key, smm_phase, smm_expanded_at, smm_migration)
    VALUES (#{q(change_key)}, 'expand', now(), #{q(migration)})
    ON CONFLICT (smm_change_key)
    DO UPDATE SET smm_phase = 'expand', smm_expanded_at = now(),
                  smm_migration = EXCLUDED.smm_migration
    """
  end

  @doc false
  def delete_expand_sql(change_key) do
    "DELETE FROM #{@table} WHERE smm_change_key = #{q(change_key)}"
  end

  @doc false
  def mark_contracted_sql(change_key, migration) do
    """
    UPDATE #{@table}
    SET smm_phase = 'contract', smm_contracted_at = now(), smm_migration = #{q(migration)}
    WHERE smm_change_key = #{q(change_key)}
    """
  end

  @doc """
  The configured bake window as `{amount, unit}`.

  Defaults to `{7, :day}`; override with
  `config :samen_core, :contract_bake_window, {amount, unit}`.
  """
  def bake_window do
    Application.get_env(:samen_core, :contract_bake_window, @default_bake_window)
  end

  @doc "The bake window expressed in whole seconds."
  def bake_window_seconds do
    {amount, unit} = bake_window()
    amount * unit_seconds(unit)
  end

  defp unit_seconds(:second), do: 1
  defp unit_seconds(:minute), do: 60
  defp unit_seconds(:hour), do: 3600
  defp unit_seconds(:day), do: 86_400

  defp unit_seconds(other) do
    raise ArgumentError,
          "unknown bake-window unit #{inspect(other)}; use :second | :minute | :hour | :day"
  end

  # SQL literal escape — change_key/migration are developer-controlled compile-time
  # identifiers, never user input, but single-quote-escaped defensively (same policy
  # as Samen.Migration's `q/1`).
  defp q(value) do
    escaped = value |> to_string() |> String.replace("'", "''")
    "'" <> escaped <> "'"
  end
end
