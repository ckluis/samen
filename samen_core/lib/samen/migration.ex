defmodule Samen.Migration do
  @moduledoc """
  `Samen.Migration` — the catalog-in-migration-transaction mechanism (T1.2 / S0.4).

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

  ## Fail-closed under `@disable_ddl_transaction true` (Gate-0 fix #4)

  Migrations that disable the DDL transaction (`CREATE INDEX CONCURRENTLY`, chunked
  backfills — plan K2 carve-outs) MUST NOT call `catalog_sync/1,2`. If they do,
  the catalog INSERT would run *outside* a transaction, and a crash after the DDL
  but before the catalog write would produce a real column with no catalog row —
  violating the fail-closed guarantee.

  `catalog_sync/1,2` detects `@disable_ddl_transaction true` at runtime (when the
  migration's `change/0` or `up/0` executes) via the caller module's `__migration__/0`
  callback injected by Ecto. It raises `RuntimeError` with a clear diagnostic naming
  the fix. There is no workaround: fix the migration to run inside a transaction, or
  use the C1 `catalog_parity` verifier to detect the drift post-migration (the plan's
  approved fallback for the carve-out cases).

  ### Why runtime, not compile-time

  `use Ecto.Migration` (called inside `Samen.Migration.__using__/1`) injects
  `@disable_ddl_transaction false` via its own `__using__/1` macro. If the user then
  writes `@disable_ddl_transaction true` AFTER `use Samen.Migration`, Elixir's module
  attribute semantics mean the last write wins — at `@before_compile` time Ecto
  captures the final value into `__migration__/0`. Because `catalog_sync` macros
  expand at function-clause compile time (interleaved with attribute writes), reading
  the attribute at macro-expansion time is NOT reliable. Reading `__migration__/0` at
  migration-run time (when `change/0`/`up/0` is actually called by `Ecto.Migrator`)
  is reliable and is the same value Ecto uses to decide whether to wrap a transaction.

  ## Parameterized inserts (spike note F4)

  SQL values come from developer-controlled compile-time identifiers (module names,
  attribute names, table names). We single-quote-escape them to defend against
  unexpected characters — proper parameterized inserts are not possible in DDL
  context migrations since Ecto's `execute/1,2` doesn't support `$1` style
  parameters in arbitrary SQL. The identifiers are never user input.

  ## Codegen scoping (spike note F2)

  `catalog_sync/1,2` accepts an `only:` option listing the *logical* attribute names
  that this migration added. When `only:` is given, the emitted reversible
  `execute` statements cover only those columns — the `down` step removes exactly
  those catalog rows without touching the rest of the table entry. Use `only:` for
  additive single-column migrations; omit it for bootstrap / full-table migrations.

  ## Usage

      defmodule MyApp.Repo.Migrations.CreateCatalog do
        use Samen.Migration

        def up do
          create_catalog_tables()
          # ... create resource tables ...
          catalog_sync([MyApp.Crm.Contact])
        end

        def down do
          catalog_sync_down([MyApp.Crm.Contact])
          drop(table(:my_table))
          drop(table(:fld_field))
          drop(table(:tam_table))
        end
      end

      defmodule MyApp.Repo.Migrations.AddPhone do
        use Samen.Migration

        def change do
          alter table(:com_contact) do
            add :com_phone, :text
          end

          # Scoped to the columns THIS migration changes — the `down` removes
          # exactly this column's catalog row.
          catalog_sync([MyApp.Crm.Contact], only: [:phone])
        end
      end

  """

  defmacro __using__(opts) do
    {phase, ecto_opts} = Keyword.pop(opts, :phase)

    if phase not in [nil, :expand, :contract] do
      raise ArgumentError,
            "use Samen.Migration, phase: must be :expand or :contract, got #{inspect(phase)}"
    end

    quote do
      use Ecto.Migration, unquote(ecto_opts)

      # A migration declares itself expand or contract. The down/0 CI check
      # (`Samen.Migration.DownCheck`) exercises every :expand migration's down/0
      # in a scratch DB; :contract migrations are covered by PITR (doc §runs 2b),
      # not down/0.
      @doc false
      def __samen_phase__, do: unquote(phase)

      import Samen.Migration,
        only: [
          catalog_sync: 1,
          catalog_sync: 2,
          catalog_sync_down: 1,
          catalog_sync_down: 2,
          create_catalog_tables: 0,
          create_migration_meta_table: 0,
          expand_setup: 0,
          expand_setup: 1,
          contract_setup: 1,
          contract_setup: 2,
          add_nullable_column: 3,
          add_nullable_column: 4,
          concurrent_index: 2,
          concurrent_index: 3,
          chunked_backfill: 3,
          chunked_backfill: 4
        ]
    end
  end

  # ---------------------------------------------------------------------------
  # Expand/contract macros (T2.4). These inject `caller:` so the underlying
  # `Samen.Migration.ExpandContract` functions can read `__migration__/0` on the
  # migration module (the same technique catalog_sync uses for the DDL-tx guard)
  # and label meta rows with the migration name.
  # ---------------------------------------------------------------------------

  @doc "Expand-phase DDL timeout posture (lock 5s / statement 15s). See `Samen.Migration.ExpandContract.expand_setup/1`."
  defmacro expand_setup do
    caller = __CALLER__.module

    quote do
      Samen.Migration.ExpandContract.expand_setup(caller: unquote(caller))
    end
  end

  @doc "See `expand_setup/0`. Pass `change_key:` to write the bake-window meta row."
  defmacro expand_setup(opts) do
    caller = __CALLER__.module

    quote do
      Samen.Migration.ExpandContract.expand_setup(
        Keyword.put(unquote(opts), :caller, unquote(caller))
      )
    end
  end

  @doc "Contract-phase gate + timeout posture. See `Samen.Migration.ExpandContract.contract_setup/2`."
  defmacro contract_setup(change_key) do
    caller = __CALLER__.module

    quote do
      Samen.Migration.ExpandContract.contract_setup(unquote(change_key), caller: unquote(caller))
    end
  end

  @doc "See `contract_setup/1`. Pass `bake_window: {n, unit}` to override the window (tests)."
  defmacro contract_setup(change_key, opts) do
    caller = __CALLER__.module

    quote do
      Samen.Migration.ExpandContract.contract_setup(
        unquote(change_key),
        Keyword.put(unquote(opts), :caller, unquote(caller))
      )
    end
  end

  @doc "Additive nullable column add. See `Samen.Migration.ExpandContract.add_nullable_column/4`."
  defmacro add_nullable_column(table, column, type) do
    quote do
      Samen.Migration.ExpandContract.add_nullable_column(
        unquote(table),
        unquote(column),
        unquote(type),
        []
      )
    end
  end

  @doc "See `add_nullable_column/3`."
  defmacro add_nullable_column(table, column, type, opts) do
    quote do
      Samen.Migration.ExpandContract.add_nullable_column(
        unquote(table),
        unquote(column),
        unquote(type),
        unquote(opts)
      )
    end
  end

  @doc "CREATE INDEX CONCURRENTLY carve-out (requires @disable_ddl_transaction true). See `Samen.Migration.ExpandContract.concurrent_index/3`."
  defmacro concurrent_index(table, columns) do
    caller = __CALLER__.module

    quote do
      Samen.Migration.ExpandContract.concurrent_index(
        unquote(table),
        unquote(columns),
        caller: unquote(caller)
      )
    end
  end

  @doc "See `concurrent_index/2`."
  defmacro concurrent_index(table, columns, opts) do
    caller = __CALLER__.module

    quote do
      Samen.Migration.ExpandContract.concurrent_index(
        unquote(table),
        unquote(columns),
        Keyword.put(unquote(opts), :caller, unquote(caller))
      )
    end
  end

  @doc "Chunked backfill carve-out (requires @disable_ddl_transaction true). See `Samen.Migration.ExpandContract.chunked_backfill/4`."
  defmacro chunked_backfill(repo, table, set_clause) do
    caller = __CALLER__.module

    quote do
      Samen.Migration.ExpandContract.chunked_backfill(
        unquote(repo),
        unquote(table),
        unquote(set_clause),
        caller: unquote(caller)
      )
    end
  end

  @doc "See `chunked_backfill/3`."
  defmacro chunked_backfill(repo, table, set_clause, opts) do
    caller = __CALLER__.module

    quote do
      Samen.Migration.ExpandContract.chunked_backfill(
        unquote(repo),
        unquote(table),
        unquote(set_clause),
        Keyword.put(unquote(opts), :caller, unquote(caller))
      )
    end
  end

  @doc "Create the samen_migration_meta bake-window table. See `Samen.Migration.ExpandContract.create_migration_meta_table/0`."
  defmacro create_migration_meta_table do
    quote do
      Samen.Migration.ExpandContract.create_migration_meta_table()
    end
  end

  @doc """
  Create the catalog storage tables. Call this from the bootstrap migration
  (before any resource tables exist).

  These tables are plain Ecto DDL — not Ash resources — to avoid the bootstrap
  chicken-and-egg (spike note F5).
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
    caller_module = __CALLER__.module

    quote do
      Samen.Migration.__catalog_sync__(unquote(caller_module), unquote(resources), [])
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

  ## Options

    * `:only` — list of logical attribute names (atoms) to sync. When given, only
      those columns' `fld_field` rows are written; the `tam_table` entry's reverse
      is a no-op so rolling back a scoped column migration doesn't orphan the table
      row. Use this for additive single-column migrations (F2 codegen scoping).

  ## Fail-closed guarantee (Gate-0 fix #4)

  `catalog_sync` REFUSES to run (raises `RuntimeError`) when the calling migration
  module has `@disable_ddl_transaction true`. The check reads `caller.__migration__()`
  (set by Ecto's `@before_compile`) at runtime — not at compile time — because the
  `@disable_ddl_transaction` attribute can be set after `use Samen.Migration` and
  Ecto captures it at `@before_compile`, making the runtime value authoritative.
  """
  defmacro catalog_sync(resources, opts) do
    caller_module = __CALLER__.module

    quote do
      Samen.Migration.__catalog_sync__(unquote(caller_module), unquote(resources), unquote(opts))
    end
  end

  @doc """
  The `down` counterpart for bootstrap / full-sync migrations that did not use
  `change/0`. Removes all catalog rows for the given resources.
  """
  defmacro catalog_sync_down(resources) do
    quote do
      Samen.Migration.__catalog_sync_down__(unquote(resources), [])
    end
  end

  @doc "See `catalog_sync_down/1`."
  defmacro catalog_sync_down(resources, opts) do
    quote do
      Samen.Migration.__catalog_sync_down__(unquote(resources), unquote(opts))
    end
  end

  # ---------------------------------------------------------------------------
  # Gate-0 fix #4: runtime guard against @disable_ddl_transaction true.
  #
  # Called from __catalog_sync__/3 with the CALLER module name captured at
  # macro-expansion time. Reads caller.__migration__() which Ecto injected via
  # @before_compile — this is the authoritative value (the same one the Ecto
  # Migrator uses to decide whether to wrap a transaction).
  # ---------------------------------------------------------------------------
  @doc false
  def __guard_ddl_transaction__!(caller_module) do
    disabled =
      try do
        caller_module.__migration__()[:disable_ddl_transaction]
      rescue
        UndefinedFunctionError -> false
      end

    if disabled == true do
      raise RuntimeError,
        message:
          "catalog_sync/1,2 REFUSES to run under @disable_ddl_transaction true in " <>
            "#{inspect(caller_module)}. " <>
            "The catalog INSERT must share the DDL transaction — outside a transaction, " <>
            "a crash between the DDL and the catalog write leaves a real column with no " <>
            "catalog row (fail-open). Either (a) remove @disable_ddl_transaction from " <>
            "this migration, or (b) do not call catalog_sync here and instead rely on " <>
            "the C1 catalog_parity verifier to detect the drift post-migration."
    end

    :ok
  end

  # Runtime side, invoked from within a migration's change/up. `Ecto.Migration`'s
  # `execute/2` is imported by `use Ecto.Migration`, so we delegate directly.
  @doc false
  def __catalog_sync__(caller_module, resources, opts) do
    __guard_ddl_transaction__!(caller_module)

    resources
    |> List.wrap()
    |> Enum.each(&sync_resource_up(&1, opts))
  end

  @doc false
  def __catalog_sync_down__(resources, opts) do
    resources
    |> List.wrap()
    |> Enum.each(&sync_resource_down(&1, opts))
  end

  # ---- up direction (forward): INSERT catalog rows ----

  defp sync_resource_up(resource, opts) do
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

  # ---- down direction (explicit down/0 migrations): DELETE catalog rows ----

  defp sync_resource_down(resource, opts) do
    only = Keyword.get(opts, :only)
    tam = Samen.Catalog.table(resource)

    flds =
      resource
      |> Samen.Catalog.fields()
      |> filter_fields(only)

    Enum.each(flds, fn fld ->
      Ecto.Migration.execute(delete_fld_sql(fld))
    end)

    unless only do
      Ecto.Migration.execute(delete_tam_sql(tam))
    end
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
