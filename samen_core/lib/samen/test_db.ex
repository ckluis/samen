defmodule Samen.TestDb do
  @moduledoc """
  The one way a test helper, CI bootstrap or verifier drops and re-creates a TEST or SCRATCH database. Sibling of
  `Samen.TestSandbox` / `Samen.Factory`: test infra shipped in lib so every app and every generated app uses it.

  ## Why not `storage_down` then `storage_up`

  Symptom (GitHub Actions, `ci (app_demo)`, step `mix test --only adversarial`): a bare `MatchError` on
  `{:error, :already_up}` from `storage_up/1` in the test helper. The old helpers ran
  `_ = Ecto.Adapters.Postgres.storage_down(config)` and threw the drop's result away, so the real error was never
  recorded and **the cause was never established**. Two mechanisms fit the symptom, and nothing in the failed log
  separates them:

    1. a live session still attached to the database (another run's, or a psql/iex session): the drop fails with
       SQLSTATE 55006 (`object_in_use`), and `CREATE DATABASE` then finds the database and answers `:already_up`;
    2. a slow `DROP DATABASE` (it checkpoints, which can take long on a busy disk): `storage_down/1` gives up on the
       server after a 15 s CLIENT timeout while the server is still dropping, and the following `CREATE DATABASE`
       sees the not-yet-removed catalog row and answers `:already_up`.

  The helper below tells them apart if the failure recurs.

  ## What this does

      Samen.TestDb.reset!(Repo.config())   # drop (if present) + create, or raise
      Samen.TestDb.drop!(config)           # cleanup of a scratch database, or raise

  The drop is a plain `DROP DATABASE IF EXISTS "<db>"` over the maintenance database (`:maintenance_database`,
  default `postgres`, as `storage_down/1` does). **There is no `WITH (FORCE)`, no session termination and no
  blind sleep-retry**: terminating sessions would silently kill ANOTHER run's sessions when two checkouts or worktrees
  share a database name (`demo_test`, ...), which used to fail loudly and must keep failing loudly.

    * The statement runs with an infinite client timeout, so the client never abandons a DROP the server is still
      executing (mechanism 2 is removed by construction). The wait is bounded by the caller's budget (ExUnit, the CI
      step timeout), not by this module.
    * Postgres itself waits about 5 s for other sessions to leave before answering 55006, which covers a predecessor
      that is genuinely still shutting down. During that wait Postgres SIGTERMs the AUTOVACUUM WORKERS in the target
      database (they are not clients); a worker slower than the 5 s makes the DROP give up with 55006 although nobody
      is attached (seen on GitHub Actions: `backend_type` `autovacuum worker`, no user, no client address). So when
      EVERY blocker has `backend_type = 'autovacuum worker'` (classified on that column only, never on an empty
      name) and `pg_prepared_xacts` has no row for the database, this module waits (bounded, by pid) for those pids
      to leave `pg_stat_activity` and re-issues the DROP exactly once. Any other blocker raises at once.
    * 55006 (matched on the SQLSTATE, not the message text) raises naming the database and listing the other sessions
      from `pg_stat_activity` (pid, role, `application_name`, client address, state, start time and age, `backend_type`, wait event; query
      text ONLY for autovacuum workers, whose text Postgres generates; and the count of prepared transactions), with the likely causes. Nothing was dropped or killed.
    * Any other failure raises with the database name and the real Postgres/driver error (code and message). A
      failed maintenance connection raises with the connect error itself (refused, unknown role, bad password, ...).
    * `{:error, :already_up}` from the create after a successful drop raises.
    * No raised message contains a password or URL.

  ## Safety

  Both functions REFUSE (`ArgumentError`, before any connection is made):

    * a database whose name is not a test/scratch name: `<words>_test` or `<words>_test<N>` (`demo_test`,
      `demo_test2` for `MIX_TEST_PARTITION`), optionally followed by `_lane<N>` suffixes and scratch tags
      `_scratch_<tag>_<N>[_<N>]` (`samen_core_test_lane2`, `samen_core_test_scratch_rvbackfill_42`), or
      `<anything>_downcheck_<8 hex>` (the `mix samen.verify.migrations` scratch name). The fixed word `scratch` is what
      makes a tag a scratch tag: a database that merely continues `test_` with a word and digits (`test_results_2`) is
      NOT one. `test_results_prod`, `prod_test_copy`, `contest`, `latest`, `postgres` and every dev/prod name are
      refused: `test` must be a whole word and nothing but those suffixes may follow it;
    * any call when `Mix` is not loaded. Every legitimate caller (test helpers, CI bootstrap scripts, `mix
      samen.verify.migrations`, `mix samen_web.test_setup`) runs under Mix; a release does not have Mix, so a stray
      `bin/app eval` can never drop a database through this module.
  """

  @maintenance_default "postgres"
  @test_name ~r/\A(?:[A-Za-z0-9]+_)*test\d*(?:_lane\d+)*(?:_scratch_[A-Za-z][A-Za-z0-9]*_\d+(?:_\d+)*)*\z|\A[A-Za-z0-9_]+_downcheck_[0-9a-f]{8}\z/
  @in_use "55006"
  @autovacuum_wait_ms 30_000
  @poll_ms 100

  @doc "Drop (if present) and create the database of `config`. Raises with the real error on any failure."
  @spec reset!(keyword()) :: :ok
  def reset!(config) do
    drop!(config)

    case Ecto.Adapters.Postgres.storage_up(config) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Samen.TestDb: could not create database #{inspect(db!(config))} after dropping it: #{format(reason)}"
    end
  end

  @doc """
  Drop the database of `config` if present. Raises on failure, listing the other sessions when it is in use; never
  terminates a session.
  """
  @spec drop!(keyword()) :: :ok
  def drop!(config) do
    db = db!(config)
    guard!(db)

    case run(config, drop_sql(db), :infinity) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{pg_code: @in_use}} = error} ->
        retry_or_raise!(config, db, error)

      {:error, error} ->
        raise "Samen.TestDb: could not drop database #{inspect(db)}: #{format(error)}"
    end
  end

  defp drop_sql(db), do: "DROP DATABASE IF EXISTS #{quote_ident(db)}"

  # 55006. Postgres 16 itself SIGTERMs autovacuum workers in the target database while DROP DATABASE waits (about 5 s);
  # a worker that takes longer makes the DROP give up although no client is attached. When EVERY blocker is such a
  # worker (and no prepared transaction pins the database) wait, by pid, for those workers to go and re-issue the DROP
  # exactly once. Anything else raises at once, terminating nothing.
  defp retry_or_raise!(config, db, error), do: resolve_in_use(config, db, error, &run/3, @autovacuum_wait_ms)

  @doc false
  # The 55006 policy with the statement runner and the wait bound injectable (`run.(config, sql, timeout)` returns
  # what `run/3` does). Returns :ok when the single re-issued DROP succeeded, raises otherwise.
  @spec resolve_in_use(keyword(), String.t(), term(), function(), non_neg_integer()) :: :ok
  def resolve_in_use(config, db, error, run, bound_ms) do
    {rows, prepared} = blockers(config, db, run)

    case classify(rows, prepared) do
      {:wait, pids} ->
        case await_gone(config, pids, bound_ms, run) do
          :gone ->
            case run.(config, drop_sql(db), :infinity) do
              {:ok, _} ->
                :ok

              {:error, %Postgrex.Error{postgres: %{pg_code: @in_use}} = second} ->
                {rows, prepared} = blockers(config, db, run)
                raise in_use_message(db, second, "the second DROP, after the autovacuum workers left, also failed", rows, prepared)

              {:error, second} ->
                raise "Samen.TestDb: could not drop database #{inspect(db)}: the second DROP, after the autovacuum workers left, failed: #{format(second)}"
            end

          {:still_there, left} ->
            {rows, prepared} = blockers(config, db, run)
            raise in_use_message(db, error, "autovacuum workers #{inspect(left)} did not leave within #{bound_ms} ms", rows, prepared)
        end

      :raise ->
        raise in_use_message(db, error, nil, rows, prepared)
    end
  end

  @doc false
  # Pure. `rows` are the maps `blockers/2` lists; `prepared` is the number of prepared transactions in the database
  # (they block the DROP and never appear in pg_stat_activity). Classified on `backend_type` ONLY: a client backend
  # with an empty application name, user or address is still a client.
  @spec classify([map()], non_neg_integer() | :unknown) :: {:wait, [integer()]} | :raise
  def classify(rows, prepared) do
    if rows != [] and prepared == 0 and Enum.all?(rows, &(Map.get(&1, :backend_type) == "autovacuum worker")) do
      {:wait, Enum.map(rows, & &1.pid)}
    else
      :raise
    end
  end

  @doc false
  # Waits (bounded) until none of `pids` is in pg_stat_activity. Terminates nothing: Postgres has already asked them to exit.
  @spec await_gone(keyword(), [integer()], non_neg_integer(), function()) :: :gone | {:still_there, [integer()]}
  def await_gone(config, pids, bound_ms, run \\ &run/3) do
    deadline = System.monotonic_time(:millisecond) + bound_ms
    do_await(config, pids, deadline, run)
  end

  defp do_await(config, pids, deadline, run) do
    list = Enum.map_join(pids, ",", &Integer.to_string(&1))

    left =
      case run.(config, "SELECT pid FROM pg_stat_activity WHERE pid IN (#{list})", 15_000) do
        {:ok, %{rows: rows}} -> Enum.map(rows, fn [pid] -> String.to_integer(pid) end)
        {:error, _} -> pids
      end

    cond do
      left == [] -> :gone
      System.monotonic_time(:millisecond) >= deadline -> {:still_there, left}
      true ->
        Process.sleep(@poll_ms)
        do_await(config, left, deadline, run)
    end
  end

  @doc "True when `name` is a database these helpers will drop."
  @spec test_database?(String.t()) :: boolean()
  def test_database?(name) when is_binary(name), do: Regex.match?(@test_name, name)

  defp guard!(db) do
    unless Code.ensure_loaded?(Mix) do
      raise ArgumentError,
            "Samen.TestDb refuses to drop #{inspect(db)}: Mix is not loaded (a release?). Test databases are only " <>
              "reset by test tooling running under Mix."
    end

    unless test_database?(db) do
      raise ArgumentError,
            "Samen.TestDb refuses to drop #{inspect(db)}: not a test/scratch database (the name must be " <>
              "`<words>_test[N]` with optional `_lane<N>` / `_<tag>_<N>` suffixes, or end in `_downcheck_<8 hex>`)."
    end
  end

  defp db!(config), do: Keyword.fetch!(config, :database)

  defp quote_ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

  defp format(%Postgrex.Error{} = e), do: Exception.message(e)
  defp format(%{__exception__: true} = e), do: Exception.message(e)
  defp format(other) when is_binary(other), do: other
  defp format(other), do: inspect(other)

  defp activity_sql(db) do
    # simple protocol: the name is embedded as a (quote-doubled) literal. The query text is selected ONLY for autovacuum
    # workers (Postgres-generated, names a table); every other backend's query text is never read.
    """
    SELECT pid, usename, application_name, client_addr::text, state, backend_start::text,
           (now() - backend_start)::text AS age, backend_type, wait_event_type, wait_event,
           CASE WHEN backend_type = 'autovacuum worker' THEN query END AS query
      FROM pg_stat_activity
     WHERE datname = '#{String.replace(db, "'", "''")}' AND pid <> pg_backend_pid()
     ORDER BY backend_start
    """
  end

  defp prepared_sql(db), do: "SELECT count(*) FROM pg_prepared_xacts WHERE database = '#{String.replace(db, "'", "''")}'"

  @keys [:pid, :usename, :application_name, :client_addr, :state, :backend_start, :age, :backend_type, :wait_event_type, :wait_event, :query]

  # {rows | {:error, reason}, prepared | :unknown}
  defp blockers(config, db, run) do
    rows =
      case run.(config, activity_sql(db), 15_000) do
        {:ok, %{rows: rows}} -> Enum.map(rows, fn r -> @keys |> Enum.zip(r) |> Map.new() |> Map.update!(:pid, &String.to_integer/1) end)
        {:error, reason} -> {:error, reason}
      end

    prepared =
      case run.(config, prepared_sql(db), 15_000) do
        {:ok, %{rows: [[n]]}} -> String.to_integer(n)
        _ -> :unknown
      end

    case rows do
      {:error, reason} -> {{:error, reason}, prepared}
      rows -> {rows, prepared}
    end
  end

  defp in_use_message(db, error, note, rows, prepared) do
    sessions =
      case rows do
        [] ->
          "  (none visible in pg_stat_activity now: they may have just left, or belong to a role this user cannot see)"

        {:error, reason} ->
          "  (could not list them: #{format(reason)})"

        rows ->
          Enum.map_join(rows, "\n", fn r ->
            "  pid=#{r.pid} usename=#{inspect(r.usename)} application_name=#{inspect(r.application_name)} " <>
              "client_addr=#{inspect(r.client_addr)} state=#{inspect(r.state)} backend_start=#{r.backend_start} (#{r.age} ago) " <>
              "backend_type=#{inspect(r.backend_type)} wait_event=#{inspect({r.wait_event_type, r.wait_event})}" <>
              if(r.backend_type == "autovacuum worker", do: " query=#{inspect(r.query)}", else: "")
          end)
      end

    prepared_line =
      case prepared do
        n when is_integer(n) and n > 0 -> "\n  #{n} prepared transaction(s) in this database (they block DROP DATABASE and are not in pg_stat_activity)"
        :unknown -> "\n  (prepared transactions could not be counted)"
        _ -> ""
      end

    """
    Samen.TestDb: could not drop database #{inspect(db)}: it is in use by other sessions (#{format(error)}).#{if note, do: " " <> note <> ".", else: ""}
    Nothing was dropped and no session was terminated. Postgres had already waited about 5 s for them to leave.
    Other sessions on #{inspect(db)}:
    #{sessions}#{prepared_line}
    Likely causes: another checkout or worktree (or another CI/sabotage lane) running this app's tests against the
    same database name, or a psql/iex session left attached. Wait for that run to finish or stop it, or set
    SAMEN_TEST_DB_SUFFIX to give this run its own database.\
    """
  end

  # One short-lived connection to the maintenance database, in a supervised task so a failed connect cannot take the
  # caller down. `timeout` is the per-statement client timeout: `:infinity` for the DROP (the client must never give
  # up while the server is still dropping; the caller's budget, ExUnit or the CI step timeout, bounds it).
  #
  # Plain `Postgrex.start_link/1` cannot report why a connect failed (the error reaches only the log; the caller
  # sees a killed pool), so the connection is a `Postgrex.SimpleConnection` (public API): `start_link/3` connects
  # synchronously and returns `{:error, real_exception}` (refused, unknown role, bad password, ...). It applies the
  # same PG* environment defaults as `Postgrex.start_link/1`. A connection lost MID-statement exits the `call` with
  # the disconnect reason, which is carried into the error. Statements use the simple protocol (single statement, no
  # parameters), which is all a DROP and a catalog read need; `Samen.TestDb.Conn` is the callback module.
  defp run(config, sql, timeout) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    maintenance = Keyword.get(config, :maintenance_database, @maintenance_default)

    opts =
      config
      |> Keyword.drop([:name, :log, :pool, :pool_size])
      |> Keyword.put(:database, maintenance)

    {:ok, sup} = Task.Supervisor.start_link()
    wait = if timeout == :infinity, do: :infinity, else: timeout + Keyword.get(config, :connect_timeout, 15_000)

    try do
      task = Task.Supervisor.async_nolink(sup, fn -> statement(opts, sql, timeout) end)

      case Task.yield(task, wait) || Task.shutdown(task) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, "the maintenance task exited: #{Exception.format_exit(reason)}"}
        nil -> {:error, "timed out after #{wait} ms"}
      end
    after
      Supervisor.stop(sup)
    end
  end

  # The connection is linked to this task: it closes its socket when the task returns, so there is no explicit stop
  # (a stop of an already-dead connection would need a catch-all that swallows).
  defp statement(opts, sql, timeout) do
    # a failed synchronous connect also exits this (linked) process with the same reason; trap it
    Process.flag(:trap_exit, true)

    case Postgrex.SimpleConnection.start_link(Samen.TestDb.Conn, nil, opts) do
      {:ok, conn} ->
        try do
          case Postgrex.SimpleConnection.call(conn, {:query, sql}, timeout) do
            %Postgrex.Error{} = error -> {:error, error}
            results when is_list(results) -> {:ok, List.last(results)}
          end
        catch
          :exit, reason -> {:error, "the maintenance connection was lost: #{Exception.format_exit(reason)}"}
        end

      {:error, error} ->
        {:error, error}
    end
  end
end

defmodule Samen.TestDb.Conn do
  @moduledoc false
  # Callback module for the single-statement maintenance connection of `Samen.TestDb`.
  @behaviour Postgrex.SimpleConnection

  @impl true
  def init(_args), do: {:ok, %{from: nil}}

  @impl true
  def handle_call({:query, sql}, from, state), do: {:query, sql, %{state | from: from}}

  @impl true
  def notify(_channel, _payload, _state), do: :ok

  @impl true
  def handle_result(result, state) do
    Postgrex.SimpleConnection.reply(state.from, result)
    {:noreply, %{state | from: nil}}
  end
end
