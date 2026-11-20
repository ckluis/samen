defmodule Samen.TestDbTest do
  @moduledoc """
  `Samen.TestDb` drops a test/scratch database DETERMINISTICALLY even while another session is connected to it —
  the race that failed `ci (app_demo)` with `{:error, :already_up}` (a previous mix process's backend still alive).
  Every scratch database here has a unique name and is dropped in `on_exit`.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias SamenCore.TestRepo, as: Repo
  alias Samen.TestDb

  setup do
    base = Repo.config()
    db = "#{Keyword.fetch!(base, :database)}_testdb_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
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

  test "mechanism: the old storage_down -> storage_up pattern fails with :already_up while a session is connected",
       %{config: config, db: db} do
    :ok = TestDb.reset!(config)
    hold_open!(config) |> Postgrex.query!("SELECT 1", [])

    assert {:error, message} = Ecto.Adapters.Postgres.storage_down(config)
    assert message =~ "is being accessed by other users"
    assert message =~ db
    assert Ecto.Adapters.Postgres.storage_up(config) == {:error, :already_up}
  end

  test "reset! succeeds with a live second connection and the database is fresh", %{config: config} do
    :ok = TestDb.reset!(config)
    conn = hold_open!(config)
    Postgrex.query!(conn, "CREATE TABLE marker (id int)", [])
    assert %{num_rows: 1} = Postgrex.query!(conn, "SELECT 1 FROM pg_tables WHERE tablename = 'marker'", [])

    assert TestDb.reset!(config) == :ok

    fresh = hold_open!(config)
    assert %{num_rows: 0} = Postgrex.query!(fresh, "SELECT 1 FROM pg_tables WHERE tablename = 'marker'", [])
  end

  test "reset! creates a missing database and drop! of a missing database is a no-op", %{config: config} do
    assert TestDb.drop!(config) == :ok
    assert TestDb.reset!(config) == :ok
    assert TestDb.drop!(config) == :ok
    assert TestDb.drop!(config) == :ok
  end

  describe "safety" do
    @bad_port [username: "nobody", hostname: "127.0.0.1", port: 1]

    for name <- ["samen_prod", "demo_dev", "postgres", "contest", "latest_orders"] do
      test "refuses #{name} before connecting" do
        # the port is dead: only the guard can produce this message
        config = Keyword.put(@bad_port, :database, unquote(name))
        assert_raise ArgumentError, ~r/refuses to drop "#{unquote(name)}"/, fn -> TestDb.drop!(config) end
        assert_raise ArgumentError, ~r/refuses to drop/, fn -> TestDb.reset!(config) end
      end
    end

    test "accepts the test and scratch names the repo uses" do
      for name <- ~w(demo_test samen_core_test_lane2 samen_core_test_rvbackfill_42 demo_test_downcheck_ab12cd34) do
        assert TestDb.test_database?(name), name
      end
    end

    test "quotes the identifier (a name that needs it)", %{config: config} do
      odd = ~s(#{config[:database]}_q"x y)
      {:ok, maint} = Postgrex.start_link(Keyword.merge(config, database: "postgres"))
      on_exit(fn -> stop_quiet(maint) end)
      Postgrex.query!(maint, ~s(CREATE DATABASE "#{String.replace(odd, ~s("), ~s(""))}"), [])
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
