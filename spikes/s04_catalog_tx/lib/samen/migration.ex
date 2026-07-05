defmodule Samen.Migration do
  @moduledoc """
  `Samen.Migration` — the catalog-in-migration-transaction mechanism (task S0.4).

  ## Why a wrapper macro and not a codegen extension

  Ash's `mix ash.codegen` emits DDL operations (table/column create/drop) into an
  Ecto migration. It has no hook to emit *data* rows (the doc's
  `INSERT INTO fld_field`) alongside that DDL, and the AshPostgres migration
  generator's operation set is closed — extending it to interleave catalog INSERTs
  would mean forking `ash_postgres`'s migration generator (fragile, high-surface).

  A migration *wrapper macro* is far more tractable and gives the exact guarantee
  the doc asks for. Ecto already runs each migration's `up/0`/`down/0` inside ONE
  Postgres transaction (unless `@disable_ddl_transaction true`). So if the DDL and
  the catalog `INSERT`s are emitted from the *same* `up/0`, they are literally the
  doc's `BEGIN; ALTER TABLE ...; INSERT INTO fld_field ...; COMMIT` — atomic and
  fail-closed by construction. A crash between the DDL and the catalog write rolls
  back BOTH; nothing extra is required.

  ## Usage

      defmodule MyApp.Repo.Migrations.AddPhone do
        use Samen.Migration

        def change do
          alter table(:com_contact) do
            add :com_phone, :text
          end

          # In the SAME transaction: reconcile the catalog to the current
          # Ash.Resource.Info introspection for these resources.
          catalog_sync([S04CatalogTx.Crm.Contact])
        end
      end

  `use Samen.Migration` gives you everything `use Ecto.Migration` does, plus:

    * `catalog_sync/1` / `catalog_sync/2` — diff `Ash.Resource.Info` against the
      catalog and emit the INSERT/DELETE `execute` statements to reconcile it,
      inside the current migration transaction. Ecto runs `change/0` forward in
      `up` and reversed in `down`; `catalog_sync` is written to be reversible so a
      rollback removes exactly the catalog rows the forward direction added.

    * `create_catalog_tables/0` — for the bootstrap migration; creates
      `tam_table` / `fld_field`.

  ## Fail-closed contract (RED PATH)

  `catalog_sync` runs its INSERTs after the DDL in the same transaction. If any
  catalog write raises (or a deliberately-failing `execute` is injected between
  the DDL and the catalog insert), Ecto aborts the transaction and the DDL is
  rolled back too — the acceptance test proves that a crash leaves NEITHER the
  column NOR the catalog row.
  """

  defmacro __using__(opts) do
    quote do
      use Ecto.Migration, unquote(opts)
      import Samen.Migration, only: [catalog_sync: 1, catalog_sync: 2, create_catalog_tables: 0]
    end
  end

  @doc """
  Create the catalog storage tables. Call this from the bootstrap migration
  (before any resource tables exist).
  """
  defmacro create_catalog_tables do
    quote do
      create table(:tam_table, primary_key: false) do
        add(:tam_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
        add(:tam_table_name, :text, null: false)
        add(:tam_resource, :text, null: false)
      end

      create(unique_index(:tam_table, [:tam_table_name], name: "tam_table_name_index"))

      create table(:fld_field, primary_key: false) do
        add(:fld_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
        add(:fld_table_name, :text, null: false)
        add(:fld_column_name, :text, null: false)
        add(:fld_logical_name, :text, null: false)
        add(:fld_type, :text, null: false)
      end

      create(
        unique_index(:fld_field, [:fld_table_name, :fld_column_name],
          name: "fld_field_table_column_index"
        )
      )
    end
  end

  @doc "See `catalog_sync/2`."
  defmacro catalog_sync(resources) do
    quote do
      Samen.Migration.__catalog_sync__(unquote(resources), [])
    end
  end

  @doc """
  Reconcile the catalog to the current `Ash.Resource.Info` for `resources`, inside
  the current migration transaction.

  Emitted as reversible `execute(up_sql, down_sql)` statements: running the
  migration forward INSERTs the catalog rows for the resources' current columns;
  running it in reverse DELETEs exactly those rows. Because these `execute`
  statements share the migration transaction with the DDL above them, the catalog
  write and the schema change commit or abort together.
  """
  defmacro catalog_sync(resources, opts) do
    quote do
      Samen.Migration.__catalog_sync__(unquote(resources), unquote(opts))
    end
  end

  # Runtime side, invoked from within a migration's change/up. `Ecto.Migration`'s
  # `execute/2` and its aliases (`repo/0`) are available on the migration module;
  # we require them to be imported by `use Ecto.Migration`, so we call them via
  # the migration process's runner. To keep this module standalone we import the
  # needed functions dynamically from the calling context by requiring the caller
  # to `use Samen.Migration` (which does `use Ecto.Migration`).
  @doc false
  def __catalog_sync__(resources, opts) do
    resources
    |> List.wrap()
    |> Enum.each(&sync_resource(&1, opts))
  end

  # opts:
  #   :only  - list of LOGICAL attribute names (atoms) to sync. When given, only
  #            those columns' fld_field rows are written, and the tam_table row is
  #            treated as a create-only upsert (its reverse delete is suppressed)
  #            so a scoped column rollback does not orphan the whole table entry.
  #            This is what makes an additive "add one column" migration's `down`
  #            remove exactly that column's catalog row and nothing else.
  #   (no :only) - reconcile the resource's FULL column set (bootstrap / full-table
  #            migrations); reverse removes the whole resource's catalog rows.
  defp sync_resource(resource, opts) do
    only = Keyword.get(opts, :only)
    tam = Samen.Catalog.table(resource)

    flds =
      resource
      |> Samen.Catalog.fields()
      |> filter_fields(only)

    # tam_table row. When scoped to specific columns, keep the table entry on
    # rollback (its other columns may still exist) — reverse is a no-op.
    tam_down = if only, do: "SELECT 1", else: delete_tam_sql(tam)
    Ecto.Migration.execute(insert_tam_sql(tam), tam_down)

    # fld_field rows (reversible), one execute per column so a failure mid-way
    # still aborts the whole transaction.
    Enum.each(flds, fn fld ->
      Ecto.Migration.execute(
        insert_fld_sql(fld),
        delete_fld_sql(fld)
      )
    end)
  end

  defp filter_fields(fields, nil), do: fields

  defp filter_fields(fields, only) when is_list(only) do
    wanted = MapSet.new(Enum.map(only, &to_string/1))
    Enum.filter(fields, &(&1.logical_name in wanted))
  end

  # --- SQL builders. Values here come from module names / attribute names /
  # --- table names — all developer-controlled compile-time identifiers, not user
  # --- input — but we still single-quote-escape defensively.

  defp insert_tam_sql(%{table_name: t, resource: r}) do
    "INSERT INTO tam_table (tam_table_name, tam_resource) VALUES " <>
      "(#{q(t)}, #{q(r)}) ON CONFLICT (tam_table_name) DO NOTHING"
  end

  defp delete_tam_sql(%{table_name: t}) do
    "DELETE FROM tam_table WHERE tam_table_name = #{q(t)}"
  end

  defp insert_fld_sql(%{table_name: t, column_name: c, logical_name: l, type: ty}) do
    "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
      "(#{q(t)}, #{q(c)}, #{q(l)}, #{q(ty)}) ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
  end

  defp delete_fld_sql(%{table_name: t, column_name: c}) do
    "DELETE FROM fld_field WHERE fld_table_name = #{q(t)} AND fld_column_name = #{q(c)}"
  end

  defp q(value) do
    escaped = value |> to_string() |> String.replace("'", "''")
    "'" <> escaped <> "'"
  end
end
