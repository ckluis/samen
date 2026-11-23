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

    e = assert_raise RuntimeError, fn -> TestDb.reset!(config) end

    assert e.message =~ ~s(could not drop database "#{db}")
    assert e.message =~ "in use by other sessions"
    assert e.message =~ "Nothing was dropped and no session was terminated"
    assert e.message =~ "pid=#{holder_pid} "
    assert e.message =~ ~s(application_name="#{app}")
    assert e.message =~ "another checkout or worktree"
    refute e.message =~ "SELECT"
    refute e.message =~ inspect(Keyword.get(config, :password, "no-password-configured"))

    # nothing killed, nothing dropped: same backend, same data, database still on the server
    assert exists?(config, db)
    assert %{rows: [[^holder_pid]]} = Postgrex.query!(conn, "SELECT pg_backend_pid()", [])
    assert %{num_rows: 1} = Postgrex.query!(conn, "SELECT 1 FROM pg_tables WHERE tablename = 'marker'", [])

    # the holder leaves: the next reset! succeeds and the database is fresh
    GenServer.stop(conn)
    assert TestDb.reset!(config) == :ok
    fresh = hold_open!(config)
    assert %{num_rows: 0} = Postgrex.query!(fresh, "SELECT 1 FROM pg_tables WHERE tablename = 'marker'", [])
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
