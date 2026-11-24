defmodule Samen.TestDbTest do
  @moduledoc """
  `Samen.TestDb` drops a test/scratch database, WAITS for the server's answer (no client timeout that abandons a DROP
  in flight), and when another session is attached RAISES naming that session instead of killing it or carrying on
  (the failure that surfaced as `{:error, :already_up}` in `ci (app_demo)` had its drop error discarded).
  Every scratch database here has a unique name and is dropped in `on_exit`.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias SamenCore.TestRepo, as: Repo
  alias Samen.TestDb

  setup do
    base = Repo.config()
    db = "#{Keyword.fetch!(base, :database)}_scratch_testdb_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
    config = base |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 1) |> Keyword.put(:database, db)
    on_exit(fn -> TestDb.drop!(config) end)
    %{config: config, db: db}
  end

  # the failed connect is also logged by Postgrex; keep the run output clean
  defp assert_raise_quiet(fun) do
    me = self()
    capture_log(fn -> send(me, {:raised, assert_raise(RuntimeError, fun)}) end)
    assert_received {:raised, e}
    e
  end

  defp stop_quiet(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # a plain second connection to the scratch database, as a previous mix process's backend would be
  defp hold_open!(config) do
    {:ok, conn} = Postgrex.start_link(Keyword.drop(config, [:name, :log, :pool, :pool_size]))
    on_exit(fn -> stop_quiet(conn) end)
    conn
  end

  # the database exists on the server
  defp exists?(config, db) do
    {:ok, maint} = Postgrex.start_link(Keyword.merge(config, database: "postgres"))

    try do
      %{rows: [[n]]} = Postgrex.query!(maint, "SELECT count(*) FROM pg_database WHERE datname = $1", [db])
      n == 1
    after
      stop_quiet(maint)
    end
  end

  # a holder with a recognisable application_name, as another run's (or a psql) session would be
  defp hold_named!(config, app) do
    {:ok, conn} =
      Postgrex.start_link(config |> Keyword.drop([:name, :log, :pool, :pool_size]) |> Keyword.put(:parameters, application_name: app))

    on_exit(fn -> stop_quiet(conn) end)
    %{rows: [[pid]]} = Postgrex.query!(conn, "SELECT pg_backend_pid()", [])
    {conn, pid}
  end

  # Postgres itself waits ~5 s for other sessions to leave before answering 55006, so this test takes ~5 s.
  test "reset! with another live session RAISES, lists the holder, and kills and drops nothing",
       %{config: config, db: db} do
    :ok = TestDb.reset!(config)
    app = "samen_test_db_holder_#{System.unique_integer([:positive])}"
    {conn, holder_pid} = hold_named!(config, app)
    Postgrex.query!(conn, "CREATE TABLE marker (id int)", [])
    # a SECOND, unnamed session (what a psql or another run's backend looks like; NOT an autovacuum worker, which has
    # backend_type 'autovacuum worker', no user and no client address): its empty application_name is listed as
    # application_name="" -- which is also what a blank configured password inspects to
    bystander = hold_open!(config)
    %{rows: [[bystander_pid]]} = Postgrex.query!(bystander, "SELECT pg_backend_pid()", [])

    e = assert_raise RuntimeError, fn -> TestDb.reset!(config) end

    assert e.message =~ ~s(could not drop database "#{db}")
    assert e.message =~ "in use by other sessions"
    assert e.message =~ "Nothing was dropped and no session was terminated"
    assert e.message =~ "pid=#{holder_pid} "
    # every blocking session is listed, the unnamed one included (the helper reports what blocks the drop, not just the holder)
    assert e.message =~ "pid=#{bystander_pid} "
    assert e.message =~ ~s(application_name="" )
    assert e.message =~ ~s(application_name="#{app}")
    assert e.message =~ "another checkout or worktree"
    refute e.message =~ "SELECT"
    # both are client backends (a Postgrex connection): neither is waited for, and no query text is printed for them
    assert e.message =~ ~s(backend_type="client backend")
    refute e.message =~ ~s(backend_type="autovacuum worker")
    refute e.message =~ "query="
    refute e.message =~ "pg_backend_pid"
    # no credential in the message: a configured password must not appear (a blank one, as here, is `""`, which a listed
    # session with an empty application_name legitimately contains -- so only a non-empty password is searched for), and
    # no URL / password word either way
    case Keyword.get(config, :password) do
      pw when is_binary(pw) and pw != "" -> refute e.message =~ pw
      _ -> :ok
    end

    refute e.message =~ ~r/password|postgres(ql)?:\/\//i

    # nothing killed, nothing dropped: same backend, same data, database still on the server
    assert exists?(config, db)
    assert %{rows: [[^holder_pid]]} = Postgrex.query!(conn, "SELECT pg_backend_pid()", [])
    assert %{num_rows: 1} = Postgrex.query!(conn, "SELECT 1 FROM pg_tables WHERE tablename = 'marker'", [])

    # the holder leaves: the next reset! succeeds and the database is fresh
    GenServer.stop(conn)
    GenServer.stop(bystander)
    assert TestDb.reset!(config) == :ok
    fresh = hold_open!(config)
    assert %{num_rows: 0} = Postgrex.query!(fresh, "SELECT 1 FROM pg_tables WHERE tablename = 'marker'", [])
  end

  describe "classify/2 (autovacuum worker versus foreign session)" do
    defp row(attrs) do
      Map.merge(
        %{pid: 1, usename: nil, application_name: "", client_addr: nil, state: "active", backend_type: "autovacuum worker"},
        Map.new(attrs)
      )
    end

    test "only autovacuum workers and no prepared transaction: wait for exactly those pids" do
      assert TestDb.classify([row(pid: 10), row(pid: 11)], 0) == {:wait, [10, 11]}
    end

    test "a client backend raises, however anonymous it looks (nil user, no address, empty application_name)" do
      assert TestDb.classify([row(backend_type: "client backend")], 0) == :raise
      # POSITIVE CONTROL: the same row as an autovacuum worker is waited for
      assert TestDb.classify([row([])], 0) == {:wait, [1]}
    end

    test "any mix raises; so does any other backend type or a missing one" do
      assert TestDb.classify([row(pid: 1), row(pid: 2, backend_type: "client backend")], 0) == :raise

      for type <- ["background worker", "walsender", "parallel worker", "logical replication worker", "autovacuum launcher", "", nil, "autovacuum worker "] do
        assert TestDb.classify([row(backend_type: type)], 0) == :raise, inspect(type)
      end

      assert TestDb.classify([%{pid: 1, usename: nil, application_name: ""}], 0) == :raise
    end

    test "a prepared transaction in the database raises (it never shows in pg_stat_activity); an unknown count raises" do
      assert TestDb.classify([row([])], 1) == :raise
      assert TestDb.classify([row([])], :unknown) == :raise
      assert TestDb.classify([], 0) == :raise
    end
  end

  describe "resolve_in_use/5 (the 55006 policy, scripted statement runner)" do
    @in_use_error %Postgrex.Error{postgres: %{code: :object_in_use, pg_code: "55006", message: "being accessed by other users", severity: "ERROR"}}

    # Postgres' simple protocol answers every cell as text
    defp activity_row(pid, type, query),
      do: [Integer.to_string(pid), nil, "", nil, "active", "t", "1s", type, "Activity", "AutoVacuumMain", query]

    # a runner scripted per statement kind; records every DROP and every poll
    defp scripted(opts) do
      {:ok, log} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(log), do: Agent.stop(log) end)

      run = fn _config, sql, _timeout ->
        kind =
          cond do
            sql =~ "DROP DATABASE" -> :drop
            sql =~ "pg_prepared_xacts" -> :prepared
            sql =~ "WHERE datname" -> :activity
            sql =~ "WHERE pid IN" -> :poll
          end

        Agent.update(log, &[kind | &1])
        n = Enum.count(Agent.get(log, & &1), &(&1 == kind))

        case kind do
          :drop -> opts.drops.(n)
          :prepared -> {:ok, %{rows: [[Integer.to_string(opts.prepared)]]}}
          :activity -> {:ok, %{rows: opts.rows}}
          :poll -> {:ok, %{rows: opts.poll.(n)}}
        end
      end

      {run, fn -> log |> Agent.get(& &1) |> Enum.reverse() end}
    end

    defp av, do: [activity_row(77, "autovacuum worker", "autovacuum: VACUUM public.t")]

    test "autovacuum-only: waits for that pid, re-issues the DROP exactly once, succeeds" do
      {run, calls} =
        scripted(%{rows: av(), prepared: 0, poll: fn n -> if n < 3, do: [["77"]], else: [] end, drops: fn _ -> {:ok, :dropped} end})

      assert TestDb.resolve_in_use([], "x_test", @in_use_error, run, 5_000) == :ok
      assert Enum.count(calls.(), &(&1 == :drop)) == 1
      assert Enum.count(calls.(), &(&1 == :poll)) == 3
    end

    test "the worker does not leave within the bound: raises with pid, type, wait event and the autovacuum query; no second DROP" do
      {run, calls} = scripted(%{rows: av(), prepared: 0, poll: fn _ -> [["77"]] end, drops: fn _ -> flunk("DROP must not be re-issued") end})

      e = assert_raise RuntimeError, fn -> TestDb.resolve_in_use([], "x_test", @in_use_error, run, 250) end
      assert e.message =~ "did not leave within 250 ms"
      assert e.message =~ "pid=77 "
      assert e.message =~ ~s(backend_type="autovacuum worker")
      assert e.message =~ ~s(wait_event={"Activity", "AutoVacuumMain"})
      assert e.message =~ ~s(query="autovacuum: VACUUM public.t")
      refute :drop in calls.()
    end

    test "the second DROP failing raises (and is not retried a third time)" do
      {run, calls} = scripted(%{rows: av(), prepared: 0, poll: fn _ -> [] end, drops: fn _ -> {:error, @in_use_error} end})

      e = assert_raise RuntimeError, fn -> TestDb.resolve_in_use([], "x_test", @in_use_error, run, 5_000) end
      assert e.message =~ "the second DROP"
      assert e.message =~ "pid=77 "
      assert Enum.count(calls.(), &(&1 == :drop)) == 1
    end

    test "a client backend among the blockers raises at once: no wait, no DROP, and its query text is not printed" do
      rows = [activity_row(5, "client backend", "SELECT secret FROM t") | av()]
      {run, calls} = scripted(%{rows: rows, prepared: 0, poll: fn _ -> flunk("must not wait") end, drops: fn _ -> flunk("must not DROP") end})

      e = assert_raise RuntimeError, fn -> TestDb.resolve_in_use([], "x_test", @in_use_error, run, 5_000) end
      assert e.message =~ "pid=5 "
      refute e.message =~ "SELECT secret"
      refute :poll in calls.()
      refute :drop in calls.()
    end

    test "a prepared transaction raises at once and is counted in the message" do
      {run, calls} = scripted(%{rows: av(), prepared: 2, poll: fn _ -> flunk("must not wait") end, drops: fn _ -> flunk("must not DROP") end})

      e = assert_raise RuntimeError, fn -> TestDb.resolve_in_use([], "x_test", @in_use_error, run, 5_000) end
      assert e.message =~ "2 prepared transaction(s)"
      refute :drop in calls.()
    end

    test "the statements read pg_stat_activity query text only for autovacuum workers and filter prepared xacts by database" do
      {:ok, seen} = Agent.start_link(fn -> [] end)

      run = fn _c, sql, _t ->
        Agent.update(seen, &[sql | &1])
        if sql =~ "pg_prepared_xacts", do: {:ok, %{rows: [["0"]]}}, else: {:ok, %{rows: []}}
      end

      assert_raise RuntimeError, fn -> TestDb.resolve_in_use([], "x_test", @in_use_error, run, 100) end
      sqls = Agent.get(seen, & &1)
      assert Enum.any?(sqls, &(&1 =~ "CASE WHEN backend_type = 'autovacuum worker' THEN query END"))
      refute Enum.any?(sqls, &(&1 =~ ~r/SELECT[^C]*\bquery\b[^C]*FROM/s))
      assert Enum.any?(sqls, &(&1 =~ "pg_prepared_xacts WHERE database = 'x_test'"))
    end
  end

  describe "await_gone/3 (bounded wait by pid; terminates nothing)" do
    test "returns :gone once the listed backends have left, and reports the ones that stay", %{config: config} do
      :ok = TestDb.reset!(config)
      {conn, pid} = hold_named!(config, "samen_test_db_await")

      # still attached: the bounded wait reports it and does NOT kill it
      assert TestDb.await_gone(config, [pid], 300) == {:still_there, [pid]}
      assert %{rows: [[^pid]]} = Postgrex.query!(conn, "SELECT pg_backend_pid()", [])

      parent = self()

      spawn_link(fn ->
        Process.sleep(300)
        stop_quiet(conn)
        send(parent, :left)
      end)

      assert TestDb.await_gone(config, [pid], 10_000) == :gone
      assert_received :left
    end
  end

  test "the drop waits for the server's answer: a holder that leaves after the first second does not time it out",
       %{config: config} do
    :ok = TestDb.reset!(config)
    {conn, _pid} = hold_named!(config, "samen_test_db_slow_leaver")
    parent = self()

    spawn_link(fn ->
      Process.sleep(1_500)
      stop_quiet(conn)
      send(parent, :holder_left)
    end)

    # a short client timeout (the old `storage_down` gave up after 15 s while the server was still dropping) would
    # raise "timed out" here; the server finishes as soon as the holder is gone (Postgres re-checks every 100 ms)
    assert TestDb.reset!(config) == :ok
    assert_received :holder_left
  end

  test "reset! creates a missing database and drop! of a missing database is a no-op", %{config: config} do
    assert TestDb.drop!(config) == :ok
    assert TestDb.reset!(config) == :ok
    assert TestDb.drop!(config) == :ok
    assert TestDb.drop!(config) == :ok
  end

  describe "safety" do
    @bad_port [username: "nobody", hostname: "127.0.0.1", port: 1]

    for name <- ~w(samen_prod demo_dev postgres contest latest latest_orders test_results_prod prod_test_copy demo_test_x
                  test_results_2 test_results_2_3 demo_test_akdgen_7 demo_test_rvbackfill_42 demo_test_scratch demo_test_scratch_x
                  demo_test_scratch_x_ demo_test_scratch_1_2 scratch_x_7) do
      test "refuses #{name} before connecting" do
        # the port is dead: only the guard can produce this message
        config = Keyword.put(@bad_port, :database, unquote(name))
        assert_raise ArgumentError, ~r/refuses to drop "#{unquote(name)}"/, fn -> TestDb.drop!(config) end
        assert_raise ArgumentError, ~r/refuses to drop/, fn -> TestDb.reset!(config) end
      end
    end

    test "refuses a production-looking database name without touching the server" do
      e = assert_raise ArgumentError, fn -> TestDb.drop!(@bad_port ++ [database: "app_production"]) end
      assert e.message =~ "not a test/scratch database"
      assert_raise ArgumentError, fn -> TestDb.reset!(@bad_port ++ [database: "app_production"]) end
    end

    test "accepts the test and scratch names the repo uses" do
      accepted =
        ~w(demo_test demo_test2 driftwood_test pawchart_test samen_web_test samen_core_multinode_test
           samen_core_test_lane2 samen_core_test_lane1_lane2 samen_core_test_scratch_rvbackfill_42
           samen_core_test_scratch_akdgen_7 samen_core_test_lane2_scratch_csatgen_7 samen_core_test_scratch_testdb_12_345
           samen_core_test_scratch_Quoted_9 demo_test_downcheck_ab12cd34 app_prod_downcheck_ab12cd34 test)

      for name <- accepted do
        assert TestDb.test_database?(name), name
      end
    end

    test "a word and digits after test is not a scratch tag; only the scratch marker makes one" do
      for name <- ~w(test_results_2 test_results_2_3 demo_test_results_9 demo_test_akdgen_7 demo_test_scratch_x) do
        refute TestDb.test_database?(name), name
      end

      # POSITIVE CONTROL: the same words behind the marker are scratch names
      for name <- ~w(test_scratch_results_2 demo_test_scratch_akdgen_7 demo_test_lane2_scratch_x_1_2) do
        assert TestDb.test_database?(name), name
      end
    end

    test "quotes the identifier (a name that needs it)", %{config: config} do
      # mixed case: accepted by the name rule, and only reachable if the identifier is quoted (unquoted it folds to lower)
      odd = "#{Repo.config()[:database]}_scratch_Quoted_#{:rand.uniform(1_000_000)}"
      {:ok, maint} = Postgrex.start_link(Keyword.merge(config, database: "postgres"))
      on_exit(fn -> stop_quiet(maint) end)
      Postgrex.query!(maint, ~s(CREATE DATABASE "#{String.replace(odd, ~s("), ~s(""))}"), [])
      on_exit(fn -> TestDb.drop!(Keyword.put(config, :database, odd)) end)
      count = "SELECT count(*) FROM pg_database WHERE datname = $1"
      assert %{rows: [[1]]} = Postgrex.query!(maint, count, [odd])

      assert TestDb.drop!(Keyword.put(config, :database, odd)) == :ok
      assert %{rows: [[0]]} = Postgrex.query!(maint, count, [odd])
      assert %{rows: [[1]]} = Postgrex.query!(maint, "SELECT count(*) FROM pg_database WHERE datname = 'postgres'", [])
    end
  end

  test "an unreachable server raises the real error and names the database" do
    config = [username: "nobody", hostname: "127.0.0.1", port: 1, database: "never_test"]
    e = assert_raise_quiet(fn -> TestDb.reset!(config) end)
    assert e.message =~ ~s(could not drop database "never_test")
    assert e.message =~ ~r/refused|econnrefused/i
  end

  test "bad credentials raise the real Postgres error", %{config: config} do
    bad = Keyword.put(config, :password, "definitely-not-the-password") |> Keyword.put(:username, "no_such_role_#{:rand.uniform(1_000_000)}")
    e = assert_raise_quiet(fn -> TestDb.reset!(bad) end)
    assert e.message =~ "could not drop database"
    assert e.message =~ ~r/role|authentication|password/i
  end
end
