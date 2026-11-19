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

    drop_invalid_index(tname, name)

    Ecto.Migration.execute(
      "CREATE #{unique}INDEX CONCURRENTLY IF NOT EXISTS #{q_ident(name)} " <>
        "ON #{q_ident(tname)} (#{cols_sql})",
      # DROP INDEX CONCURRENTLY is also non-transactional — matches the disabled tx.
      "DROP INDEX CONCURRENTLY IF EXISTS #{q_ident(name)}"
    )
  end

  @doc """
  `CREATE UNIQUE INDEX CONCURRENTLY` on one column of a table that may already hold rows (same carve-out
  rules as `concurrent_index/3`: `@disable_ddl_transaction true`, a literal `:name`, a same-named INVALID
  leftover dropped first).

  Before the build it counts the values that already appear more than once and, if there are any, RAISES
  naming the table and column and how to list them. It deletes nothing and prints no value (a column of
  credential digests must not reach a log): removing duplicates is a decision for a person, and a unique
  build over them would only fail late and leave an INVALID index behind.
  """
  def concurrent_unique_index(table, column, opts) do
    name = Keyword.fetch!(opts, :name)
    caller = Keyword.fetch!(opts, :caller)
    __require_disabled_ddl_transaction__!(caller)
    tname = table_name(table)
    cname = to_string(column)

    Ecto.Migration.execute(
      fn ->
        repo = Ecto.Migration.repo()

        %{rows: [[values, rows]]} =
          repo.query!(
            "SELECT count(*), COALESCE(sum(n), 0) FROM " <>
              "(SELECT count(*) AS n FROM #{q_ident(tname)} WHERE #{q_ident(cname)} IS NOT NULL " <>
              "GROUP BY #{q_ident(cname)} HAVING count(*) > 1) d"
          )

        if values > 0 do
          raise RuntimeError,
                "cannot build the unique index #{name}: #{tname}.#{cname} holds #{values} value(s) that appear " <>
                  "more than once (#{rows} rows). Nothing was changed and nothing was deleted. List them with " <>
                  "SELECT #{cname}, count(*) FROM #{tname} GROUP BY #{cname} HAVING count(*) > 1, " <>
                  "resolve the duplicates deliberately, then run this migration again."
        end

        :ok
      end,
      fn -> :ok end
    )

    concurrent_index(table, [column], Keyword.merge(opts, unique: true, name: name))
  end

  @doc """
  Drop a same-named INVALID index on `table` before a `CREATE INDEX CONCURRENTLY IF NOT EXISTS`.

  A concurrent build that fails (a duplicate under `UNIQUE`, a deadlock, a cancel) leaves the
  index behind with `pg_index.indisvalid = false`; `IF NOT EXISTS` then sees the name and skips,
  so the migration "succeeds" and the table has no usable index — forever. This queues, ahead
  of the build, a step that drops the name if it is invalid and ABANDONED. A VALID index of that
  name is never touched, and neither is one another session is building right now (that build is
  `indisvalid = false` too): the step first takes the table's `SHARE UPDATE EXCLUSIVE` lock, which
  a running `CREATE INDEX CONCURRENTLY` holds until its last step, so it WAITS for the build to
  finish and then sees it valid. The build drops that lock just BEFORE it commits the valid flag, so
  an invalid row whose updater is still in progress in our snapshot is a build finishing, and is left
  alone too. Call it from a migration that disabled the DDL transaction; it is
  a no-op on `down`.
  """
  def drop_invalid_index(table, name) do
    tname = table_name(table)
    iname = to_string(name)

    Ecto.Migration.execute(
      fn ->
        repo = Ecto.Migration.repo()

        # Lock FIRST, then look: a check-then-drop without the lock is a race (the build can start,
        # or finish, between the look and the drop). Holding SHARE UPDATE EXCLUSIVE excludes every
        # concurrent build on the table, so an index invalid under it is genuinely abandoned, with ONE
        # exception: CREATE INDEX CONCURRENTLY releases its session lock BEFORE the transaction that flips
        # `indisvalid` commits. In that window we hold the lock and still read the old, invalid row, but a
        # build is finishing it: a DROP would wait on its uncommitted row update and then fail with
        # "tuple concurrently updated". An invalid row whose `xmax` is a transaction not yet visible in
        # our snapshot (still in progress) is that finishing build; an abandoned build's updater is aborted,
        # which a snapshot reports as visible, so it is still dropped. The xid8 epoch is taken from the
        # snapshot's xmin (an updater straddling an epoch boundary reads as visible: the old behaviour). The
        # drop is therefore a plain DROP INDEX inside this transaction (the CONCURRENTLY form
        # cannot run in one and would release the lock first); its brief ACCESS EXCLUSIVE upgrade
        # is bounded by lock_timeout and fails loudly rather than queueing every reader behind it.
        {:ok, :ok} =
          repo.transaction(
            fn ->
              if repo.query!("SELECT to_regclass($1)::text", [q_ident(tname)]).rows != [[nil]] do
                repo.query!("LOCK TABLE #{q_ident(tname)} IN SHARE UPDATE EXCLUSIVE MODE")

                %{rows: rows} =
                  repo.query!(
                    """
                    SELECT n.nspname::text
                      FROM pg_index i
                      JOIN pg_class c ON c.oid = i.indexrelid
                      JOIN pg_namespace n ON n.oid = c.relnamespace
                     WHERE c.relname = $1 AND i.indrelid = to_regclass($2) AND NOT i.indisvalid
                      AND (i.xmax::text = '0' OR pg_visible_in_snapshot(
                            (((pg_snapshot_xmin(pg_current_snapshot())::text::bigint >> 32) << 32)
                              | i.xmax::text::bigint)::text::xid8,
                            pg_current_snapshot()))
                    """,
                    [iname, q_ident(tname)]
                  )

                if rows != [], do: repo.query!("SET LOCAL lock_timeout = '10s'")

                for [schema] <- rows do
                  repo.query!("DROP INDEX #{q_ident(schema)}.#{q_ident(iname)}")
                end
              end

              :ok
            end,
            timeout: :infinity
          )

        :ok
      end,
      fn -> :ok end
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
      `:chunk_size` (default 5_000), `:sleep_ms` (throttle between chunks, default 0), `:where` (a LITERAL SQL
      predicate that REPLACES the `column IS NULL` guard, and then `:column` is not needed: the rows to touch, e.g. a
      value that is only filled in for the rows it can be derived for, or a status that moves on). It must stop
      matching a row once the `set_clause` has been applied to it, or the loop never ends; a row the set clause cannot
      answer for must be excluded by the predicate itself.

  Returns `{:ok, total_updated}`.
  """
  def chunked_backfill(repo, table, set_clause, opts \\ []) do
    caller = Keyword.fetch!(opts, :caller)
    __require_disabled_ddl_transaction__!(caller)

    tname = table_name(table)

    predicate =
      case Keyword.get(opts, :where) do
        nil -> "#{q_ident(opts |> Keyword.fetch!(:column) |> to_string())} IS NULL"
        where when is_binary(where) -> "(#{where})"
      end

    chunk_size = Keyword.get(opts, :chunk_size, 5_000)
    sleep_ms = Keyword.get(opts, :sleep_ms, 0)

    do_backfill_chunk(repo, tname, set_clause, predicate, chunk_size, sleep_ms, 0)
  end

  defp do_backfill_chunk(repo, tname, set_clause, predicate, chunk_size, sleep_ms, acc) do
    # Each chunk: its own committed statement (migration runs with
    # @disable_ddl_transaction true, so repo.query! autocommits). Bound the batch
    # with a subselect on ctid so a chunk is a small, short-lived write.
    sql =
      "UPDATE #{q_ident(tname)} SET #{set_clause} " <>
        "WHERE ctid IN (" <>
        "SELECT ctid FROM #{q_ident(tname)} " <>
        "WHERE #{predicate} LIMIT #{chunk_size})"

    %{num_rows: n} = repo.query!(sql, [])

    if n > 0 and sleep_ms > 0, do: Process.sleep(sleep_ms)

    if n < chunk_size or n == 0 do
      {:ok, acc + n}
    else
      do_backfill_chunk(repo, tname, set_clause, predicate, chunk_size, sleep_ms, acc + n)
    end
  end

  @doc """
  Make an existing nullable column `NOT NULL` without a long `ACCESS EXCLUSIVE` scan — the contract-phase counterpart of
  `add_nullable_column/4`, for a column whose resource says `allow_nil? false` (see `mix samen.verify.indexes`).

  Runs OUTSIDE the DDL transaction (`@disable_ddl_transaction true`, enforced like `chunked_backfill/4`): inside one, the
  `ACCESS EXCLUSIVE` lock the constraint add takes would be held through the validation scan, which is exactly what this
  avoids. The steps (every `ACCESS EXCLUSIVE` statement runs in its own short transaction under `lock_timeout`, so it
  fails loudly instead of queueing every reader and writer of the table behind a long-running transaction):

    1. `DROP CONSTRAINT IF EXISTS <t>_<c>_nn_chk`, then `ADD CONSTRAINT … CHECK (<c> IS NOT NULL) NOT VALID` (one short
       transaction, no scan). From here on the database refuses every NEW NULL (and any update that would leave a NULL row's
       NULL in place), so a writer cannot slip a NULL in between the count below and the validation;
    2. optional `:backfill` (see below), in short `chunk_size` batches, each a committed statement;
    3. a hard stop: count the NULLs left. If any remain the check is DROPPED again and the migration RAISES naming the table,
       column and count — a column with no correct value is never filled with an invented one, and the column's definition
       was not changed. Rows the `:backfill` expression could answer for HAVE been filled (those batches are committed) and
       stay filled;
    4. `VALIDATE CONSTRAINT` (scan under `SHARE UPDATE EXCLUSIVE`: reads and writes continue);
    5. `ALTER COLUMN <c> SET NOT NULL` (Postgres 12+ trusts the validated check and does not rescan) and `DROP CONSTRAINT`,
       in one short transaction (the column's own NOT NULL now says it, and an interruption cannot leave the check behind
       on a column that already carries the NOT NULL).

  A re-run after an interruption is safe: every step is repeatable, a leftover check is dropped and re-added by step 1, and a
  lock timeout costs only the re-run (a timed-out step raises naming what, if anything, it left on the table). A column that
  is already `NOT NULL` is re-validated (a scan) and the statements run again, harmlessly. `drop_not_null/3` is the reverse
  (it does not undo a backfill).

  ## Options

    * `:caller` — REQUIRED, the migration module (`__MODULE__`).
    * `:backfill` — a SQL expression (a LITERAL in the migration, never derived from a resource at run time) the NULL rows
      are set to, e.g. `"COALESCE(pmp_label, pmp_provider_plan_ref)"`. Only rows for which it is non-NULL are touched, so
      a row it cannot answer for stays NULL and trips step 3 instead of being papered over.
    * `:chunk_size` — backfill batch size, a positive integer (default 5_000).
    * `:lock_timeout` — how long each `ACCESS EXCLUSIVE` statement may wait for its lock, e.g. `"5s"` (the default is the
      module's shipped `lock_timeout`), `"500ms"`.
  """
  def set_not_null(repo, table, column, opts \\ []) do
    caller = Keyword.fetch!(opts, :caller)
    __require_disabled_ddl_transaction__!(caller)

    tname = table_name(table)
    cname = to_string(column)
    check = not_null_check_name(tname, cname)
    chunk_size = Keyword.get(opts, :chunk_size, 5_000)

    unless is_integer(chunk_size) and chunk_size > 0 do
      raise ArgumentError, "set_not_null/4: :chunk_size must be a positive integer, got #{inspect(chunk_size)}"
    end

    lock_sql = lock_timeout_sql(opts)
    qt = q_ident(tname)
    qc = q_ident(cname)
    qk = q_ident(check)

    # 1. the check FIRST: no new NULL can be written from here on
    with_short_lock(repo, lock_sql, tname, "nothing was changed (no constraint was added or removed)", fn ->
      repo.query!("ALTER TABLE #{qt} DROP CONSTRAINT IF EXISTS #{qk}")
      repo.query!("ALTER TABLE #{qt} ADD CONSTRAINT #{qk} CHECK (#{qc} IS NOT NULL) NOT VALID")
    end)

    # 2. backfill what the expression can answer for
    case Keyword.get(opts, :backfill) do
      nil -> :ok
      expr when is_binary(expr) -> backfill_nulls(repo, tname, cname, expr, chunk_size)
    end

    # 3. a NULL with no correct value stops the migration, and takes the check away with it
    %{rows: [[remaining]]} = repo.query!("SELECT count(*) FROM #{qt} WHERE #{qc} IS NULL")

    if remaining > 0 do
      left_behind =
        "the temporary check constraint #{check} is still on #{tname} (it refuses new NULLs; the next run drops it first)"

      with_short_lock(repo, lock_sql, tname, left_behind, fn ->
        repo.query!("ALTER TABLE #{qt} DROP CONSTRAINT IF EXISTS #{qk}")
      end)

      raise RuntimeError,
            "set_not_null/4: #{tname}.#{cname} still has #{remaining} NULL row(s) and no correct value to give them. " <>
              "The column's definition was NOT altered and the temporary check constraint was dropped again; rows the " <>
              "`backfill:` expression could answer for HAVE been filled and stay filled (those batches are committed). " <>
              "Find the rows with `SELECT * FROM #{qt} WHERE #{qc} IS NULL`, then fix or remove them (a data fix) and run " <>
              "the migration again; `backfill:` only helps while the migration is still being written."
    end

    # 4. validate (SHARE UPDATE EXCLUSIVE: reads and writes continue)
    repo.query!("ALTER TABLE #{qt} VALIDATE CONSTRAINT #{qk}")

    # 5. SET NOT NULL (no rescan: the validated check proves it) + drop the check, atomically
    left_behind =
      "the VALID check constraint #{check} is still on #{tname} (the column is not NOT NULL yet; the next run replaces it)"

    with_short_lock(repo, lock_sql, tname, left_behind, fn ->
      repo.query!("ALTER TABLE #{qt} ALTER COLUMN #{qc} SET NOT NULL")
      repo.query!("ALTER TABLE #{qt} DROP CONSTRAINT #{qk}")
    end)

    :ok
  end

  @doc "The reverse of `set_not_null/4`: `ALTER COLUMN … DROP NOT NULL` (a backfill is not undone). Needs the same `:caller`."
  def drop_not_null(repo, table, column, opts \\ []) do
    __require_disabled_ddl_transaction__!(Keyword.fetch!(opts, :caller))
    repo.query!("ALTER TABLE #{q_ident(table_name(table))} ALTER COLUMN #{q_ident(to_string(column))} DROP NOT NULL")
    :ok
  end

  # One short transaction under `lock_timeout` for statements that take ACCESS EXCLUSIVE: all of them or none. A lock that
  # cannot be had in time raises with `left_behind` (what the timed-out step leaves on the table) and "re-run".
  defp with_short_lock(repo, lock_sql, tname, left_behind, fun) do
    {:ok, :ok} =
      repo.transaction(
        fn ->
          repo.query!(lock_sql)
          fun.()
          :ok
        end,
        timeout: :infinity
      )

    :ok
  rescue
    e in Postgrex.Error ->
      case e do
        %Postgrex.Error{postgres: %{code: :lock_not_available}} ->
          raise RuntimeError,
                "set_not_null/4: could not get the lock on #{tname} within the lock timeout; this step was rolled back " <>
                  "as a whole: #{left_behind}. Run the migration again when the table is quiet."

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  @lock_timeout_format ~r/\A[1-9][0-9]*(ms|s|min)\z/

  defp lock_timeout_sql(opts) do
    case Keyword.get(opts, :lock_timeout) do
      nil ->
        {lock_sql, _stmt_sql} = __timeout_sql__()
        lock_sql

      lt when is_binary(lt) ->
        unless Regex.match?(@lock_timeout_format, lt),
          do: raise(ArgumentError, "set_not_null/4: :lock_timeout must look like \"5s\", \"500ms\" or \"1min\", got #{inspect(lt)}")

        "SET LOCAL lock_timeout = '#{lt}'"
    end
  end

  # Each batch is its own committed statement; the batch predicate excludes rows the expression cannot answer for, so a
  # row that stays NULL never makes the loop spin.
  defp backfill_nulls(repo, tname, cname, expr, chunk_size) do
    sql =
      "UPDATE #{q_ident(tname)} SET #{q_ident(cname)} = (#{expr}) WHERE ctid IN (" <>
        "SELECT ctid FROM #{q_ident(tname)} WHERE #{q_ident(cname)} IS NULL AND (#{expr}) IS NOT NULL LIMIT #{chunk_size})"

    %{num_rows: n} = repo.query!(sql, [])
    if n >= chunk_size, do: backfill_nulls(repo, tname, cname, expr, chunk_size), else: :ok
  end

  defp not_null_check_name(tname, cname), do: String.slice(tname <> "_" <> cname, 0, 56) <> "_nn_chk"

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
