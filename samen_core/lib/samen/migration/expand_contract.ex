defmodule Samen.Migration.ExpandContract do
  @moduledoc """
  Expand/contract migration conventions + the timeout posture (T2.4, doc §runs 2/2b).

  This module is imported by `use Samen.Migration` (which also imports the catalog
  helpers from `Samen.Migration`). It provides:

    * **`expand_setup/0` / `contract_setup/1`** — the DDL-transaction timeout posture:
      `lock_timeout = 5s`, `statement_timeout = 15s`, set up front so a transactional
      migration that would take a blocking lock **fails fast and aborts** rather than
      freezing live OLTP behind it (doc §runs 2b, "the classic single-substrate stall").

    * **Additive expand helpers** — `add_nullable_column/3`, `add_nullable_columns/2`.
      Expand phase must be additive/backward-compatible so the old binary keeps running
      against the new schema (doc §runs 2): a nullable column add is safe.

    * **Carve-outs that run OUTSIDE the DDL transaction** — `concurrent_index/3`
      (`CREATE INDEX CONCURRENTLY`, non-transactional by definition) and
      `chunked_backfill/4` (each chunk its own short committed tx off the critical
      path). These require `@disable_ddl_transaction true` and DO NOT set the 15s
      statement ceiling — precisely so it can't abort the maintenance work (doc §runs
      2b, "run with the statement timeout disabled or set per-statement to a long bound").

    * **`contract_ready?/1,2`** — the contract-phase gate: refuses to run until the
      paired expand release has baked for the configured window (tracked via a
      `samen_migration_meta` row the expand wrote). See `Samen.Migration.Meta`.

  ## The DDL timeout posture

  `expand_setup/0` and `contract_setup/1` emit, as the FIRST statements of the
  migration transaction:

      SET LOCAL lock_timeout = '5s';
      SET LOCAL statement_timeout = '15s';

  `SET LOCAL` scopes the change to the current transaction — it reverts on COMMIT,
  so it never leaks into the connection pool. `lock_timeout` bounds how long any
  single statement waits to *acquire* a lock (the blocking-lock stall); once acquired,
  `statement_timeout` bounds total execution. Both live INSIDE the tx (they only make
  sense transactionally), which is why the concurrent-index / backfill carve-outs —
  which run outside a tx — must NOT use them.

  ## Carve-out composition with T1.2 catalog_sync (the paired-migration pattern)

  `catalog_sync/1,2` (from `Samen.Migration`) REFUSES to run under
  `@disable_ddl_transaction true` (Gate-0 fix #4): outside a transaction, a crash
  between the DDL and the catalog INSERT would leave a real column with no catalog row
  (fail-open). `concurrent_index/3` requires `@disable_ddl_transaction true`. The two
  are therefore mutually exclusive within one migration BY CONSTRUCTION — you cannot
  write `catalog_sync` and `concurrent_index` in the same module and have both run.

  The resolution the doc's atomicity guarantee needs is the **paired-migration
  pattern**: a `CREATE INDEX CONCURRENTLY` migration is non-transactional and does
  NOT carry catalog rows; the catalog row for the *column the index covers* is written
  by the transactional expand migration that ADDED that column (via `catalog_sync`).
  An index is not itself a catalogued object (the catalog names tables and columns,
  not indexes), so a concurrent index needs no paired catalog write at all — but if a
  future need arises to record index metadata, it goes in a *separate transactional*
  migration, never in the `@disable_ddl_transaction true` one. `concurrent_index/3`
  enforces this: it raises if called from a migration whose DDL transaction is NOT
  disabled (so you can't accidentally run a CONCURRENTLY build inside a tx, which
  Postgres would reject anyway), and the guard message documents the pattern.
  """

  @lock_timeout "5s"
  @statement_timeout "15s"

  @doc """
  Emit the expand-phase DDL timeout posture: `lock_timeout=5s`, `statement_timeout=15s`.

  Call as the FIRST line of an expand migration's `up/0`. Also records that this
  migration is an expand (so the down/0 CI check and the CONCURRENTLY guard can
  reason about it). Optionally pass a `change_key` to write the bake-window meta row.

  ## Options

    * `:change_key` — when given, writes a `samen_migration_meta` row (phase=expand,
      expanded_at=now()) so a paired contract migration can gate on the bake window.
      Requires that `samen_migration_meta` exists (call
      `Samen.Migration.Meta.create_table_sql/0` in a bootstrap migration first, or
      use `create_migration_meta_table/0` here).
  """
  def expand_setup(opts \\ []) do
    __set_ddl_timeouts__()

    case Keyword.get(opts, :change_key) do
      nil ->
        :ok

      change_key ->
        migration = migration_name(opts)

        Ecto.Migration.execute(
          Samen.Migration.Meta.insert_expand_sql(change_key, migration),
          Samen.Migration.Meta.delete_expand_sql(change_key)
        )
    end

    :ok
  end

  @doc """
  Emit the contract-phase DDL timeout posture AND assert the bake window.

  Call as the FIRST line of a contract migration's `up/0`. It:

    1. Refuses (raises) unless `contract_ready?/1` is true for `change_key` — i.e.
       the paired expand's `samen_migration_meta` row exists AND has baked for the
       configured window.
    2. Sets the same `lock_timeout=5s` / `statement_timeout=15s` posture (the
       destructive DROP/ADD-CONSTRAINT is transactional and must also fail fast on a
       blocking lock).
    3. Marks the meta row contracted.

  ## Options

    * `:bake_window` — override the configured window as `{amount, unit}` (tests use
      seconds). Defaults to `Samen.Migration.Meta.bake_window/0`.
  """
  def contract_setup(change_key, opts \\ []) when is_binary(change_key) do
    repo = Ecto.Migration.repo()

    case contract_ready?(repo, change_key, opts) do
      {:ready, _elapsed} ->
        :ok

      {:not_ready, reason} ->
        raise RuntimeError, message: contract_refusal_message(change_key, reason)
    end

    __set_ddl_timeouts__()

    Ecto.Migration.execute(
      Samen.Migration.Meta.mark_contracted_sql(change_key, migration_name(opts)),
      # down: revert to expand phase (leave the bake row intact so a re-run re-gates)
      "UPDATE #{Samen.Migration.Meta.table()} SET smm_phase = 'expand', smm_contracted_at = NULL " <>
        "WHERE smm_change_key = '#{String.replace(change_key, "'", "''")}'"
    )

    :ok
  end

  @doc """
  The contract-phase gate. Returns `{:ready, elapsed_seconds}` when the paired
  expand has baked for the configured window, else `{:not_ready, reason}`.

  `reason` is one of:

    * `{:no_expand_row, change_key}` — the expand never ran (no meta row). The
      contract MUST NOT run: there is no bake clock at all → fail closed.
    * `{:baking, elapsed_seconds, window_seconds}` — the expand ran but the window
      has not elapsed.

  Reads `samen_migration_meta` via the given repo. This is a pure query — safe to
  call from CI, tests, or a runbook to check whether a contract may proceed.
  """
  def contract_ready?(repo, change_key, opts \\ []) when is_binary(change_key) do
    window_seconds =
      case Keyword.get(opts, :bake_window) do
        nil -> Samen.Migration.Meta.bake_window_seconds()
        {amount, unit} -> amount * unit_seconds(unit)
      end

    sql =
      "SELECT EXTRACT(EPOCH FROM (now() - smm_expanded_at))::bigint " <>
        "FROM #{Samen.Migration.Meta.table()} " <>
        "WHERE smm_change_key = $1 AND smm_expanded_at IS NOT NULL"

    case repo.query!(sql, [change_key]) do
      %{rows: [[elapsed]]} when is_integer(elapsed) ->
        if elapsed >= window_seconds do
          {:ready, elapsed}
        else
          {:not_ready, {:baking, elapsed, window_seconds}}
        end

      %{rows: []} ->
        {:not_ready, {:no_expand_row, change_key}}
    end
  end

  @doc """
  Additive nullable column add (expand-safe). A nullable column with no default (or
  a constant default) is backward-compatible: the old binary keeps working, so
  rollback-by-redeploy stays safe (doc §runs 2).

  Emits a reversible `ALTER TABLE ... ADD COLUMN`. `null: false` is REJECTED — a
  NOT NULL add on a populated table is a destructive/blocking op that belongs in the
  contract phase (behind a backfill), not expand.
  """
  def add_nullable_column(table, column, type, opts \\ []) do
    if Keyword.get(opts, :null) == false do
      raise ArgumentError,
            "add_nullable_column/#{4}: `null: false` is not additive — a NOT NULL add is a " <>
              "contract-phase op (add nullable in expand, backfill, then add the constraint in " <>
              "contract). Table #{inspect(table)}, column #{inspect(column)}."
    end

    # Emit the add via raw execute so we can attach a precise reversible down
    # without macro block gymnastics (Ecto.Migration.alter/2 needs a block form).
    tname = table_name(table)
    cname = to_string(column)
    pg_type = ecto_type_to_sql(type)
    default = Keyword.get(opts, :default)

    default_clause =
      case default do
        nil -> ""
        value -> " DEFAULT #{sql_default(value)}"
      end

    Ecto.Migration.execute(
      "ALTER TABLE #{q_ident(tname)} ADD COLUMN #{q_ident(cname)} #{pg_type}#{default_clause}",
      "ALTER TABLE #{q_ident(tname)} DROP COLUMN IF EXISTS #{q_ident(cname)}"
    )
  end

  @doc """
  A `CREATE INDEX CONCURRENTLY` shell — the expand-phase carve-out that runs OUTSIDE
  the DDL transaction (doc §runs 2b).

  REQUIRES the migration to declare `@disable_ddl_transaction true` (a CONCURRENTLY
  build cannot run inside a transaction — Postgres rejects it). This helper raises
  with the paired-migration pattern documented if the DDL transaction is NOT disabled.

  It does NOT set `statement_timeout` — the 15s ceiling would abort a large index
  build. The build is intentionally unbounded (or bounded per-deployment by the
  operator's session default), off the critical path.

  ## Composition with catalog_sync (T1.2)

  A concurrent-index migration carries NO catalog rows: `catalog_sync` refuses under
  `@disable_ddl_transaction true`, and an index is not a catalogued object anyway.
  The catalog row for the underlying column was written by the transactional expand
  migration that ADDED the column. See the moduledoc "paired-migration pattern".
  """
  def concurrent_index(table, columns, opts \\ []) do
    caller = Keyword.fetch!(opts, :caller)
    __require_disabled_ddl_transaction__!(caller)

    tname = table_name(table)
    cols = columns |> List.wrap() |> Enum.map(&to_string/1)
    name = Keyword.get(opts, :name) || default_index_name(tname, cols)
    unique = if Keyword.get(opts, :unique, false), do: "UNIQUE ", else: ""
    cols_sql = cols |> Enum.map(&q_ident/1) |> Enum.join(", ")

    Ecto.Migration.execute(
      "CREATE #{unique}INDEX CONCURRENTLY IF NOT EXISTS #{q_ident(name)} " <>
        "ON #{q_ident(tname)} (#{cols_sql})",
      # DROP INDEX CONCURRENTLY is also non-transactional — matches the disabled tx.
      "DROP INDEX CONCURRENTLY IF EXISTS #{q_ident(name)}"
    )
  end

  @doc """
  Chunked backfill — the second expand-phase carve-out that runs OUTSIDE the DDL
  transaction (doc §runs 2b). Each chunk is its own short, committed transaction off
  the critical path, so no single long transaction holds locks or trips the 15s
  ceiling.

  REQUIRES `@disable_ddl_transaction true` (so the outer migration is not one big
  transaction). Iterates the key space in `chunk_size` batches, running `update_sql`
  (which must be idempotent and bounded by the batch predicate) per chunk, each in its
  own `repo.query!` (autocommit).

  ## Arguments

    * `repo` — the migration's repo (`Ecto.Migration.repo()`).
    * `table` — the table to backfill.
    * `set_clause` — the `SET ...` fragment (e.g. `"col = other_col"`); the WHERE is
      supplied by the helper (`col IS NULL AND ctid range`), so the backfill only
      touches unset rows and is safe to re-run.
    * `opts` — `:column` (the column being backfilled, used in the WHERE null-guard),
      `:chunk_size` (default 5_000), `:sleep_ms` (throttle between chunks, default 0).

  Returns `{:ok, total_updated}`.
  """
  def chunked_backfill(repo, table, set_clause, opts \\ []) do
    caller = Keyword.fetch!(opts, :caller)
    __require_disabled_ddl_transaction__!(caller)

    tname = table_name(table)
    column = opts |> Keyword.fetch!(:column) |> to_string()
    chunk_size = Keyword.get(opts, :chunk_size, 5_000)
    sleep_ms = Keyword.get(opts, :sleep_ms, 0)

    do_backfill_chunk(repo, tname, set_clause, column, chunk_size, sleep_ms, 0)
  end

  defp do_backfill_chunk(repo, tname, set_clause, column, chunk_size, sleep_ms, acc) do
    # Each chunk: its own committed statement (migration runs with
    # @disable_ddl_transaction true, so repo.query! autocommits). Bound the batch
    # with a subselect on ctid so a chunk is a small, short-lived write.
    sql =
      "UPDATE #{q_ident(tname)} SET #{set_clause} " <>
        "WHERE ctid IN (" <>
        "SELECT ctid FROM #{q_ident(tname)} " <>
        "WHERE #{q_ident(column)} IS NULL LIMIT #{chunk_size})"

    %{num_rows: n} = repo.query!(sql, [])

    if n > 0 and sleep_ms > 0, do: Process.sleep(sleep_ms)

    if n < chunk_size or n == 0 do
      {:ok, acc + n}
    else
      do_backfill_chunk(repo, tname, set_clause, column, chunk_size, sleep_ms, acc + n)
    end
  end

  @doc """
  Create the `samen_migration_meta` table (idempotent). Call from a bootstrap
  migration alongside `create_catalog_tables/0`.
  """
  def create_migration_meta_table do
    Ecto.Migration.execute(
      Samen.Migration.Meta.create_table_sql(),
      Samen.Migration.Meta.drop_table_sql()
    )
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  @doc false
  def __set_ddl_timeouts__ do
    # Emit reversible executes (same SET on up and down) so the posture composes
    # with a `change/0`-style migration: the down direction sets the SAME protective
    # timeouts for the reverse DDL (a DROP COLUMN can also take a blocking lock).
    {lock, stmt} = __timeout_sql__()
    Ecto.Migration.execute(lock, lock)
    Ecto.Migration.execute(stmt, stmt)
    :ok
  end

  @doc """
  The two SQL statements the DDL timeout posture emits: `{lock_timeout_sql,
  statement_timeout_sql}`. Single source of truth for the doc-mandated values
  (§runs 2b: lock 5s, statement 15s). Exposed so tests can assert the values
  without a migration context.
  """
  def __timeout_sql__ do
    {"SET LOCAL lock_timeout = '#{@lock_timeout}'",
     "SET LOCAL statement_timeout = '#{@statement_timeout}'"}
  end

  @doc false
  def __require_disabled_ddl_transaction__!(caller_module) do
    disabled =
      try do
        caller_module.__migration__()[:disable_ddl_transaction]
      rescue
        UndefinedFunctionError -> false
      end

    unless disabled == true do
      raise RuntimeError,
        message:
          "concurrent_index/3 and chunked_backfill/4 REQUIRE `@disable_ddl_transaction true` " <>
            "in #{inspect(caller_module)}. A CREATE INDEX CONCURRENTLY build and chunked " <>
            "backfills run OUTSIDE the DDL transaction precisely so the 15s statement_timeout " <>
            "cannot abort them (doc §runs 2b). Add `@disable_ddl_transaction true` to this " <>
            "migration. Note the paired-migration pattern: this migration must NOT call " <>
            "catalog_sync (which refuses under a disabled DDL tx — Gate-0 fix #4); the catalog " <>
            "row for the underlying column belongs to the transactional expand migration that " <>
            "added it."
    end

    :ok
  end

  @doc false
  def contract_refusal_message(change_key, {:no_expand_row, _}) do
    "contract_setup refused: no `samen_migration_meta` row for change_key " <>
      "#{inspect(change_key)}. The paired expand migration must have run in production " <>
      "(writing the bake-clock row via `expand_setup(change_key: #{inspect(change_key)})`) " <>
      "before the contract phase may run. Fail-closed: without a bake clock the contract " <>
      "cannot know the expand code has been the only code in production."
  end

  def contract_refusal_message(change_key, {:baking, elapsed, window}) do
    "contract_setup refused: change_key #{inspect(change_key)} has baked for #{elapsed}s " <>
      "but the configured bake window is #{window}s. The destructive contract phase refuses " <>
      "to run until the expand release has been the only code in production for the full bake " <>
      "window (doc §runs 2). Wait #{window - elapsed}s, or (test-only) shorten " <>
      "`config :samen_core, :contract_bake_window`."
  end

  defp migration_name(opts) do
    case Keyword.get(opts, :caller) do
      nil -> "unknown"
      mod -> inspect(mod)
    end
  end

  defp unit_seconds(:second), do: 1
  defp unit_seconds(:minute), do: 60
  defp unit_seconds(:hour), do: 3600
  defp unit_seconds(:day), do: 86_400

  defp table_name(%Ecto.Migration.Table{name: name}), do: to_string(name)
  defp table_name(name) when is_atom(name) or is_binary(name), do: to_string(name)

  defp default_index_name(table, cols), do: "#{table}_#{Enum.join(cols, "_")}_index"

  # Minimal Ecto-type → SQL-type mapping for the additive helper. Covers the common
  # additive-column types; unknown atoms pass through uppercased (developer-controlled).
  defp ecto_type_to_sql(:text), do: "TEXT"
  defp ecto_type_to_sql(:string), do: "TEXT"
  defp ecto_type_to_sql(:integer), do: "INTEGER"
  defp ecto_type_to_sql(:bigint), do: "BIGINT"
  defp ecto_type_to_sql(:boolean), do: "BOOLEAN"
  defp ecto_type_to_sql(:uuid), do: "UUID"
  defp ecto_type_to_sql(:binary), do: "BYTEA"
  defp ecto_type_to_sql(:date), do: "DATE"
  defp ecto_type_to_sql(:utc_datetime), do: "TIMESTAMPTZ"
  defp ecto_type_to_sql(:naive_datetime), do: "TIMESTAMP"
  defp ecto_type_to_sql(:map), do: "JSONB"
  defp ecto_type_to_sql(:jsonb), do: "JSONB"
  defp ecto_type_to_sql(:float), do: "DOUBLE PRECISION"
  defp ecto_type_to_sql(other) when is_atom(other), do: other |> to_string() |> String.upcase()

  defp sql_default(v) when is_binary(v), do: "'#{String.replace(v, "'", "''")}'"
  defp sql_default(v) when is_boolean(v), do: to_string(v)
  defp sql_default(v) when is_number(v), do: to_string(v)

  defp q_ident(name) do
    # Quote an SQL identifier. Identifiers are developer-controlled compile-time
    # names; double-quote-escape defensively.
    escaped = name |> to_string() |> String.replace("\"", "\"\"")
    "\"" <> escaped <> "\""
  end
end
