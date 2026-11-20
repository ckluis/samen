defmodule Samen.SingleNodeLeaseTest.PoolDouble do
  @moduledoc """
  A transaction pooler in miniature, at the `Postgrex` boundary (`Lease`'s `:query_mod`).

  The lease "connects" to a handle instead of a socket; every STATEMENT it sends (including each one inside
  `after_connect`) is served by whatever real Postgres session `route.()` names at that moment, exactly as
  PgBouncer in transaction mode serves a client's statements on whichever server connection is free. Server
  sessions are plain `Postgrex` connections that outlive the "client" (a pooler keeps them), so the locks and
  session variable a lease left on one stay there.
  """

  def start_link(opts) do
    handle = %{route: Keyword.fetch!(opts, :route), after_connect: Keyword.fetch!(opts, :after_connect)}
    :ok = reconnect(handle)
    {:ok, handle}
  end

  @doc "A new client connection: `after_connect` runs again, on whichever server the route names now."
  def reconnect(%{after_connect: {m, f, a}} = handle), do: apply(m, f, [handle | a])

  def query(%{route: route}, sql, params, opts \\ []), do: Postgrex.query(route.(), sql, params, opts)
  def query!(%{route: route}, sql, params), do: Postgrex.query!(route.(), sql, params)
end

defmodule Samen.SingleNodeLeaseTest.SlowPostgrex do
  @moduledoc "Postgrex whose `query/4` takes 5 000 ms of a test clock (an `Agent` named in the app env)."
  defdelegate start_link(opts), to: Postgrex
  defdelegate query!(conn, sql, params), to: Postgrex

  def query(conn, sql, params, opts) do
    Agent.update(Application.fetch_env!(:samen_core, :sn_slow_clock), &(&1 + 5_000))
    Postgrex.query(conn, sql, params, opts)
  end
end

defmodule Samen.SingleNodeLeaseTest.TlsRepo do
  @moduledoc "A repo carrying the hardened `ssl:` list `Samen.Deploy.db_ssl_opts/2` produces (no network involved)."
  def config, do: [hostname: "pooled.example", database: "app", ssl: [verify: :verify_peer, cacertfile: "/ca.pem"], pool_size: 10]
end

defmodule Samen.SingleNodeLeaseTest.PlainRepo do
  @moduledoc "A dev/test-style repo with no `ssl:` list."
  def config, do: [hostname: "pooled.example", database: "app", ssl: false]
end

defmodule Samen.SingleNodeLeaseTest.DynRepo do
  @moduledoc "A repo whose config resolves its credentials at CONNECT time (`:configure`), like an IAM-token host."
  def config do
    Keyword.merge(SamenCore.TestRepo.config(), database: "samen_no_such_database", configure: {__MODULE__, :configure, []})
  end

  def configure(opts), do: Keyword.put(opts, :database, SamenCore.TestRepo.config()[:database])
end

defmodule Samen.SingleNodeLeaseTest.StaticRepo do
  @moduledoc "The control for DynRepo: the same wrong database and no `:configure`."
  def config, do: Keyword.delete(Samen.SingleNodeLeaseTest.DynRepo.config(), :configure)
end

defmodule Samen.SingleNodeLeaseTest do
  @moduledoc """
  ADR-054 — the database half of the single-node guard: a second instance on the same database is detected.

  "Two instances" are two `Samen.SingleNode.Lease` processes, each with its OWN dedicated connection (exactly
  what two machines would have), against the real test database, on a key private to each test. Proven, each with
  a positive control:

    1. alone -> `:single`; a second instance -> BOTH see `:overlap`; it goes away -> `:single` again;
    2. the late instance is the one that BOOTED later (database clock, carried in `pg_locks`): a reconnect of the
       long-running instance does not make it late; ordering works across roles;
    3. the grace period: nothing is reported or critical before it, exactly one report and CRITICAL from it on;
       an unreadable moment in between does not restart the clock;
    4. fail-honest: a dead database, a lost lock, a pooled statement, a ghost lock and a dead or hung lease are
       UNKNOWN, never `:single` and never a strict 503;
    5. transaction pooling (`PoolDouble`): two instances on ONE server session, and locks left on a session the
       lease no longer owns, are UNKNOWN; a direct instance facing such a leftover is UNKNOWN, not overlap;
    6. a lease session whose client goes silent is released by the server (`idle_session_timeout`);
    7. a mix task / release `eval` / migration (anything that does not arm the guard) holds no lock.

  There are no sleeps: every state is read with `Lease.check_now/1` (one synchronous check), and "the other
  instance's session is gone" is made synchronous by `pg_terminate_backend(pid, timeout)`, which waits inside
  Postgres for the backend to exit.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.SingleNode
  alias Samen.SingleNode.Lease
  alias Samen.SingleNodeLeaseTest.PoolDouble
  alias SamenCore.TestRepo

  @moduletag :capture_log

  setup do
    # A key private to this test (advisory locks are per database, not per test).
    key = {System.unique_integer([:positive]) + 1_000, System.unique_integer([:positive]) + 7}
    admin = start_supervised!({Postgrex, Keyword.take(TestRepo.config(), [:hostname, :username, :password, :database])})
    %{key: key, admin: admin}
  end

  # `await_session: false` is for a lease that is MEANT to have no session (an unreachable database): there is no
  # `after_connect` to wait for.
  defp start_lease(ctx, opts \\ []) do
    {await_session?, opts} = Keyword.pop(opts, :await_session, true)
    n = System.unique_integer([:positive])
    name = Keyword.get(opts, :name, :"sn_lease_#{n}")
    table = :"sn_lease_t_#{n}"

    opts =
      Keyword.merge(
        [repo: TestRepo, name: name, table: table, lock_key: ctx.key, interval_ms: 3_600_000],
        opts
      )

    # `start_link` returns before the dedicated connection is up. The session exists once `after_connect` has taken
    # the lock and announced it, so wait for THAT event: a check issued earlier queues for a connection that is not
    # there yet, and a pool with a small queue (`queue_target` 20 ms, as the reconnect test uses) drops it as
    # `:connection_down` as soon as the handshake takes longer than the queue allows (it does under machine load).
    test_pid = self()
    handler = {__MODULE__, :session, make_ref()}
    :ok = :telemetry.attach(handler, [:samen, :single_node, :session], fn _e, m, _meta, _ -> send(test_pid, {:lease_session, m.backend_pid}) end, nil)

    try do
      start_supervised!(Supervisor.child_spec({Lease, opts}, id: name))
      if await_session?, do: assert_receive({:lease_session, _backend_pid}, 5_000)
    after
      :telemetry.detach(handler)
    end

    # The first check is served now that the session exists, so after it the instance is a real, visible holder.
    _ = Lease.check_now(name)
    %{name: name, table: table}
  end

  defp holders(%{admin: admin, key: {k1, k2}}) do
    %{rows: rows} =
      Postgrex.query!(
        admin,
        "SELECT pid FROM pg_locks WHERE locktype = 'advisory' AND classid = $1 AND objid = $2 AND objsubid = 2 AND granted",
        [k1, k2]
      )

    List.flatten(rows)
  end

  defp lease_conn(%{name: name}), do: :sys.get_state(name).conn
  defp backend_pid(lease), do: Postgrex.query!(lease_conn(lease), "SELECT pg_backend_pid()", []).rows |> hd() |> hd()

  # Both instances check, twice, so each has seen the other's beat CHANGE (a beat that never changes is a ghost).
  defp confirm(a, b) do
    for _ <- 1..2 do
      Lease.check_now(a.name)
      Lease.check_now(b.name)
    end

    :ok
  end

  defp server_session do
    start_supervised!(
      Supervisor.child_spec({Postgrex, Keyword.take(TestRepo.config(), [:hostname, :username, :password, :database])},
        id: :"sn_server_#{System.unique_integer([:positive])}"
      )
    )
  end

  # A pooled lease: its statements are served by whichever session `selector` (an Agent holding a server pid) names.
  defp start_pooled(ctx, selector, opts \\ []) do
    route = fn -> Agent.get(selector, & &1) end
    start_lease(ctx, Keyword.merge([repo: nil, connect_opts: [route: route], query_mod: PoolDouble], opts))
  end

  defp telemetry_to_self(event) do
    test = self()
    handler = "sn-lease-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, event, fn _e, m, _meta, _ -> send(test, {:telemetry, event, m}) end, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "alone on the database: single (and the lock really is held, on a dedicated session)", ctx do
    a = start_lease(ctx)
    assert %{state: :single} = Lease.check_now(a.name)
    assert %{state: :single} = SingleNode.status(table: a.table)
    assert SingleNode.advisory(table: a.table) == :ok
    assert [_one] = holders(ctx)
  end

  test "a second instance is detected by BOTH; when it goes away the first is single again", ctx do
    a = start_lease(ctx)
    assert %{state: :single} = Lease.check_now(a.name)

    b = start_lease(ctx)
    other_pids = holders(ctx)
    assert length(other_pids) == 2

    assert %{state: :overlap, peers: 1} = Lease.check_now(a.name)
    assert %{state: :overlap, peers: 1} = Lease.check_now(b.name)

    # B dies (stopped; its backend then exits). pg_terminate_backend(pid, ms) waits inside Postgres for the exit.
    [b_pid] = other_pids -- [backend_pid(a)]
    stop_supervised!(b.name)
    Postgrex.query!(ctx.admin, "SELECT pg_terminate_backend($1, 10000)", [b_pid])

    assert %{state: :single} = Lease.check_now(a.name)
  end

  test "a dropped connection is re-established WITH the lock (reconnect is by construction, not by retry)", ctx do
    a = start_lease(ctx, pool_opts: [queue_target: 20, queue_interval: 50])
    assert %{state: :single} = Lease.check_now(a.name)
    [my_pid] = holders(ctx)

    # Kill the session from the server side and wait (inside Postgres) until it is gone.
    Postgrex.query!(ctx.admin, "SELECT pg_terminate_backend($1, 10000)", [my_pid])
    assert holders(ctx) == []

    # The pool reconnects on its own; every answer on the way is either "connection down" or single. It must NEVER
    # be read as a pooler (the session variable is set by after_connect on the new session) or as a lost lease.
    # Each check is paced by the pool's own queue wait, not by a sleep.
    results =
      Enum.reduce_while(1..200, [], fn _, acc ->
        case Lease.check_now(a.name) do
          %{state: :single} = s -> {:halt, [s | acc]}
          %{state: :unknown, reason: :connection_down} = s -> {:cont, [s | acc]}
          other -> flunk("unexpected status after a reconnect: #{inspect(other)}")
        end
      end)

    assert %{state: :single} = hd(results)
    assert [new_pid] = holders(ctx)
    assert new_pid != my_pid
  end

  describe "who is late: the boot epoch, carried in pg_locks" do
    test "the later BOOT is late; strict refuses only it (and only once the other is confirmed alive)", ctx do
      a = start_lease(ctx, strict: true, grace_ms: 0)
      assert %{state: :single} = Lease.check_now(a.name)
      b = start_lease(ctx, strict: true, grace_ms: 0)

      # B has seen A once: A's beat has not been seen to change, so nothing is refused on that.
      assert %{state: :overlap, late?: true, verified?: false} = Lease.check_now(b.name)
      assert SingleNode.strict_check(table: b.table) == :ok
      assert {:unknown, _} = SingleNode.advisory(table: b.table)

      confirm(a, b)
      assert %{state: :overlap, late?: false, verified?: true} = Lease.check_now(a.name)
      assert %{state: :overlap, late?: true, verified?: true} = Lease.check_now(b.name)

      assert SingleNode.strict_check(table: a.table) == :ok
      assert SingleNode.strict_check(table: b.table) == {:error, :overlap}
    end

    test "a reconnect of the long-running instance does NOT make it the late one", ctx do
      a = start_lease(ctx, strict: true, grace_ms: 0, pool_opts: [queue_target: 20, queue_interval: 50])
      b = start_lease(ctx, strict: true, grace_ms: 0)
      confirm(a, b)
      assert %{late?: false} = Lease.check_now(a.name)

      # A's session is killed and re-established: a NEW backend pid (and backend_start), the SAME boot epoch.
      a_old = backend_pid(a)
      Postgrex.query!(ctx.admin, "SELECT pg_terminate_backend($1, 10000)", [a_old])

      Enum.reduce_while(1..200, nil, fn _, _ ->
        case Lease.check_now(a.name) do
          %{state: :unknown, reason: :connection_down} -> {:cont, nil}
          s -> {:halt, s}
        end
      end)

      assert backend_pid(a) != a_old
      confirm(a, b)
      assert %{state: :overlap, late?: false} = Lease.check_now(a.name)
      assert %{state: :overlap, late?: true} = Lease.check_now(b.name)
      assert SingleNode.strict_check(table: a.table) == :ok
      assert SingleNode.strict_check(table: b.table) == {:error, :overlap}
    end

    test "ordering works across roles (pg_stat_activity.backend_start is NULL there; pg_locks is not)", ctx do
      role = "sn_role_#{System.unique_integer([:positive])}"

      # needs a role that may CREATE ROLE (the local and CI roles are superusers); the error names it otherwise
      Postgrex.query!(ctx.admin, ~s(CREATE ROLE #{role} LOGIN PASSWORD 'sn_pw'), [])

      a_name = :"sn_role_a_#{System.unique_integer([:positive])}"
      b_name = :"sn_role_b_#{System.unique_integer([:positive])}"

      try do
        a = start_lease(ctx, strict: true, grace_ms: 0, name: a_name)

        other_role = Keyword.merge(Keyword.take(TestRepo.config(), [:hostname, :database]), username: role, password: "sn_pw")
        b = start_lease(ctx, strict: true, grace_ms: 0, repo: nil, connect_opts: other_role, name: b_name)

        # The premise: the other role cannot read A's session start. This is what made the old ordering blind.
        assert [[nil]] = Postgrex.query!(lease_conn(b), "SELECT backend_start FROM pg_stat_activity WHERE pid = $1", [backend_pid(a)]).rows

        confirm(a, b)
        assert %{state: :overlap, late?: false} = Lease.check_now(a.name)
        assert %{state: :overlap, late?: true} = Lease.check_now(b.name)
        assert SingleNode.strict_check(table: b.table) == {:error, :overlap}
        assert SingleNode.strict_check(table: a.table) == :ok
      after
        stop_supervised(a_name)
        stop_supervised(b_name)
        Postgrex.query!(ctx.admin, "SELECT pg_terminate_backend(pid, 10000) FROM pg_stat_activity WHERE usename = $1", [role])
        Postgrex.query!(ctx.admin, ~s(DROP ROLE IF EXISTS #{role}), [])
      end
    end
  end

  test "strict off: the late instance is still ready (the advisory is the signal)", ctx do
    a = start_lease(ctx, grace_ms: 0)
    assert %{state: :single} = Lease.check_now(a.name)
    b = start_lease(ctx, grace_ms: 0)
    confirm(a, b)
    assert %{state: :overlap, late?: true} = Lease.check_now(b.name)

    assert SingleNode.strict_check(table: b.table) == :not_armed
    assert {:critical, _} = SingleNode.advisory(table: b.table)
  end

  describe "grace period (deterministic clock)" do
    setup ctx do
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      test = self()
      handler = "sn-grace-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [[:samen, :single_node, :overlap], [:samen, :core, :write, :error]],
        fn event, _m, meta, _ -> send(test, {:telemetry, event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      Map.put(ctx, :clock, clock)
    end

    test "inside the grace nothing is reported or critical; at the boundary exactly one report and CRITICAL", ctx do
      now = fn -> Agent.get(ctx.clock, & &1) end
      a = start_lease(ctx, grace_ms: 60_000, clock: now)
      assert %{state: :single} = Lease.check_now(a.name)
      b = start_lease(ctx)

      # The clock starts at the first CONFIRMED sight (b's beat changed between two checks of a), here at t = 0.
      assert %{state: :overlap, verified?: false, exceeded?: false} = Lease.check_now(a.name)
      Lease.check_now(b.name)
      assert %{state: :overlap, verified?: true, exceeded?: false} = Lease.check_now(a.name)
      assert SingleNode.advisory(table: a.table, now: 0) == :ok

      Agent.update(ctx.clock, fn _ -> 59_999 end)
      Lease.check_now(b.name)
      assert %{state: :overlap, exceeded?: false} = Lease.check_now(a.name)
      refute_received {:telemetry, [:samen, :single_node, :overlap], _}
      refute_received {:telemetry, [:samen, :core, :write, :error], %{write: :single_node_overlap}}

      Agent.update(ctx.clock, fn _ -> 60_000 end)
      Lease.check_now(b.name)
      assert %{state: :overlap, exceeded?: true, verified?: true} = Lease.check_now(a.name)
      assert {:critical, detail} = SingleNode.advisory(table: a.table, now: 60_000)
      assert detail =~ "1 other instance(s)"
      assert_received {:telemetry, [:samen, :single_node, :overlap], _}
      assert_received {:telemetry, [:samen, :core, :write, :error], %{write: :single_node_overlap}}

      # one report per episode, not one per check
      Agent.update(ctx.clock, fn _ -> 90_000 end)
      Lease.check_now(b.name)
      assert %{exceeded?: true} = Lease.check_now(a.name)
      refute_received {:telemetry, [:samen, :single_node, :overlap], _}
    end

    test "an unreadable moment does not restart the overlap clock; only an observed single does", ctx do
      now = fn -> Agent.get(ctx.clock, & &1) end
      set = fn t -> Agent.update(ctx.clock, fn _ -> t end) end
      a = start_lease(ctx, grace_ms: 60_000, clock: now)
      b = start_lease(ctx)
      confirm(a, b)
      assert %{state: :overlap, exceeded?: false} = Lease.check_now(a.name)

      # A's reading becomes unreadable for a while (its presence lock is released: :lease_lost) ...
      {k1, k2} = ctx.key
      set.(30_000)
      Postgrex.query!(lease_conn(a), "SELECT pg_advisory_unlock_shared($1::int, $2::int)", [k1, k2])
      assert %{state: :unknown, reason: :lease_lost} = Lease.check_now(a.name)

      # ... and readable again after the grace period would have elapsed IF the overlap had been going on all along.
      set.(60_000)
      Postgrex.query!(lease_conn(a), "SELECT pg_advisory_lock_shared($1::int, $2::int)", [k1, k2])
      Lease.check_now(b.name)
      assert %{state: :overlap, since_ms: 60_000, exceeded?: true} = Lease.check_now(a.name)

      # Positive control: an OBSERVED single does reset it.
      b_pid = backend_pid(b)
      stop_supervised!(b.name)
      Postgrex.query!(ctx.admin, "SELECT pg_terminate_backend($1, 10000)", [b_pid])
      set.(70_000)
      assert %{state: :single} = Lease.check_now(a.name)
      b2 = start_lease(ctx)
      set.(80_000)
      Lease.check_now(a.name)
      Lease.check_now(b2.name)
      assert %{state: :overlap, verified?: true, since_ms: 0, exceeded?: false} = Lease.check_now(a.name)
    end
  end

  describe "fail-honest: unreadable is UNKNOWN, never single" do
    test "the database is unreachable", ctx do
      a = start_lease(ctx, await_session: false, repo: nil, connect_opts: [hostname: "127.0.0.1", port: 1, username: "x", database: "x"], query_timeout_ms: 300, pool_opts: [queue_target: 20, queue_interval: 50])

      assert %{state: :unknown, reason: :connection_down} = Lease.check_now(a.name)
      assert {:unknown, detail} = SingleNode.advisory(table: a.table)
      assert detail =~ "connection_down"
      refute SingleNode.advisory(table: a.table) == :ok
    end

    test "the lock is gone while the session lives (unlocked by someone else)", ctx do
      a = start_lease(ctx)
      assert %{state: :single} = Lease.check_now(a.name)

      {k1, k2} = ctx.key
      Postgrex.query!(lease_conn(a), "SELECT pg_advisory_unlock_all()", [])
      assert k1 > 0 and k2 > 0

      assert %{state: :unknown, reason: :lease_lost} = Lease.check_now(a.name)
    end

    test "a statement served by a session that never ran after_connect (what a transaction pooler produces)", ctx do
      a = start_lease(ctx)
      assert %{state: :single} = Lease.check_now(a.name)

      # What a pooled statement looks like: the session variable only after_connect sets is absent.
      Postgrex.query!(lease_conn(a), "SELECT set_config('samen.single_node_lease', '', false)", [])

      assert %{state: :unknown, reason: :connection_pooler} = Lease.check_now(a.name)
    end

    test "a dead lease is UNKNOWN (armed, no table) and a hung one goes stale; neither is single or a strict 503", ctx do
      clock_now = System.monotonic_time(:millisecond)
      a = start_lease(ctx, strict: true, stale_ms: 60_000)
      SingleNode.arm(a.table)
      on_exit(fn -> SingleNode.disarm(a.table) end)
      assert %{state: :single} = SingleNode.status(table: a.table)

      # hung: nothing refreshes the table; the last word expires
      assert %{state: :unknown, reason: :lease_stale} = SingleNode.status(table: a.table, now: clock_now + 3_600_000)
      assert {:unknown, detail} = SingleNode.advisory(table: a.table, now: clock_now + 3_600_000)
      assert detail =~ "lease_stale"
      assert SingleNode.strict_check(table: a.table, now: clock_now + 3_600_000) == :ok

      # dead: the process (and its ETS table) is gone, but this node is armed
      stop_supervised!(a.name)
      assert %{state: :unknown, reason: :lease_not_running} = SingleNode.status(table: a.table)
      assert {:unknown, _} = SingleNode.advisory(table: a.table)
      assert SingleNode.strict_check(table: a.table) in [:ok, :not_armed]

      # positive control: a node that was never armed is simply disarmed
      assert SingleNode.status(table: :"sn_never_armed_#{System.unique_integer([:positive])}") == :disarmed
    end
  end

  describe "a transaction pooler (PoolDouble: statements served by whichever server session is routed)" do
    setup do
      {:ok, selector} = Agent.start_link(fn -> nil end)
      %{selector: selector, x: server_session(), y: server_session()}
    end

    test "control: a pooler that pins this client to one server session is indistinguishable from direct, and right", ctx do
      Agent.update(ctx.selector, fn _ -> ctx.x end)
      a = start_pooled(ctx, ctx.selector)
      for _ <- 1..3, do: assert(%{state: :single} = Lease.check_now(a.name))
      refute :sys.get_state(a.name).pooled?
    end

    test "TWO instances sharing ONE server session are UNKNOWN, never single (the false negative)", ctx do
      Agent.update(ctx.selector, fn _ -> ctx.x end)
      a = start_pooled(ctx, ctx.selector)
      b = start_pooled(ctx, ctx.selector)

      # one pg_locks row for two instances: a plain holder count says "alone"
      assert [_one_row] = holders(ctx)

      for _ <- 1..3 do
        assert %{state: :unknown, reason: :connection_pooler} = Lease.check_now(a.name)
        assert %{state: :unknown, reason: :connection_pooler} = Lease.check_now(b.name)
      end

      for l <- [a, b] do
        refute SingleNode.advisory(table: l.table) == :ok
        assert {:unknown, _} = SingleNode.advisory(table: l.table)
        assert SingleNode.strict_check(table: l.table) in [:ok, :not_armed]
      end

      # a pooled lease takes nothing beyond what after_connect took: the beat (guarded in SQL) does not advance
      %{beat: beat_class} = Lease.classes(ctx.key)
      beats = fn -> Postgrex.query!(ctx.admin, "SELECT array_agg(objid::bigint ORDER BY objid) FROM pg_locks WHERE locktype = 'advisory' AND classid = $1 AND objsubid = 2", [beat_class]).rows end
      before = beats.()
      for _ <- 1..3, l <- [a, b], do: Lease.check_now(l.name)
      assert beats.() == before
    end

    test "a lock + variable left on a session the lease no longer owns is not read as its own", ctx do
      Agent.update(ctx.selector, fn _ -> ctx.x end)
      a = start_pooled(ctx, ctx.selector)
      assert %{state: :single} = Lease.check_now(a.name)

      # The client reconnects and its after_connect lands on Y. X keeps the lock AND this boot's token.
      Agent.update(ctx.selector, fn _ -> ctx.y end)
      :ok = PoolDouble.reconnect(lease_conn(a))
      assert length(holders(ctx)) == 2

      # Control: served by Y it is the lease's own session; the leftover on X carries MY epoch, so it is a ghost of
      # my own earlier session and not a second instance.
      Agent.update(ctx.selector, fn _ -> ctx.y end)
      assert %{state: :single} = Lease.check_now(a.name)
      refute :sys.get_state(a.name).pooled?

      # A statement served by X now: the token matches, the pid is not the one recorded, and no reconnect happened while
      # it ran: proof of a pooler. It latches.
      Agent.update(ctx.selector, fn _ -> ctx.x end)
      log = capture_log(fn -> assert %{state: :unknown, reason: :connection_pooler} = Lease.check_now(a.name) end)
      assert log =~ "DATABASE_DIRECT_URL"

      # Served by Y it is the lease's own session again, but it stays UNKNOWN: a pooler was PROVEN, and no later
      # check on the right server connection makes the lock on the others any less stranded. ONE error, not one per check.
      Agent.update(ctx.selector, fn _ -> ctx.y end)

      log =
        capture_log(fn ->
          assert %{state: :unknown, reason: :connection_pooler} = Lease.check_now(a.name)
          assert %{state: :unknown, reason: :connection_pooler} = Lease.check_now(a.name)
        end)

      refute log =~ "DATABASE_DIRECT_URL"
    end

    test "a route X -> Z -> X stays UNKNOWN after returning to the server connection that holds the locks", ctx do
      z = server_session()
      Agent.update(ctx.selector, fn _ -> ctx.x end)
      a = start_pooled(ctx, ctx.selector)

      # On X, its own session: reads single, as a direct connection would.
      assert %{state: :single} = Lease.check_now(a.name)

      # Z never ran after_connect: no session variable. Proof of a pooler.
      Agent.update(ctx.selector, fn _ -> z end)
      assert %{state: :unknown, reason: :connection_pooler} = Lease.check_now(a.name)

      # Back on X, where the locks and the token are: it would verify, but it must not read single.
      Agent.update(ctx.selector, fn _ -> ctx.x end)
      for _ <- 1..3, do: assert(%{state: :unknown, reason: :connection_pooler} = Lease.check_now(a.name))
      refute SingleNode.advisory(table: a.table) == :ok
    end

    test "control: a genuine reconnect on a direct connection is NOT a pooler and does not latch", ctx do
      a = start_lease(ctx, pool_opts: [queue_target: 20, queue_interval: 50])
      assert %{state: :single} = Lease.check_now(a.name)
      first = backend_pid(a)

      for _ <- 1..2 do
        pid = backend_pid(a)
        Postgrex.query!(ctx.admin, "SELECT pg_terminate_backend($1, 10000)", [pid])

        Enum.reduce_while(1..200, nil, fn _, _ ->
          case Lease.check_now(a.name) do
            %{state: :single} -> {:halt, nil}
            %{state: :unknown, reason: :connection_down} -> {:cont, nil}
            other -> flunk("a genuine reconnect must not latch: #{inspect(other)}")
          end
        end)
      end

      assert backend_pid(a) != first
      refute :sys.get_state(a.name).pooled?
      assert %{state: :single} = Lease.check_now(a.name)
    end

    test "pooler_proof?/2: a pid that changed DURING the statement is the reconnect race, not proof" do
      row = fn var, me -> {:ok, %Postgrex.Result{rows: [[me, var, nil, nil, nil, nil]]}} end
      ctx = %{token: "tok", pid: 10, pid_before: 10, epoch: 1}

      assert Lease.pooler_proof?(row.(nil, 10), ctx)
      assert Lease.pooler_proof?(row.("other", 10), ctx)
      assert Lease.pooler_proof?(row.("tok", 77), ctx)
      refute Lease.pooler_proof?(row.("tok", 10), ctx)
      # the recorded pid moved while the statement ran (after_connect re-ran): the statement was on the old session
      refute Lease.pooler_proof?(row.("tok", 77), %{ctx | pid_before: 77})
      refute Lease.pooler_proof?({:error, %DBConnection.ConnectionError{message: "x"}}, ctx)
    end

    test "a DIRECT instance facing a leftover from a pooled one is UNKNOWN, not overlap (never a strict 503)", ctx do
      Agent.update(ctx.selector, fn _ -> ctx.x end)
      p = start_pooled(ctx, ctx.selector)
      assert %{state: :single} = Lease.check_now(p.name)
      # the pooled instance is gone; the pooler keeps server session X, with its locks
      stop_supervised!(p.name)
      assert [_leftover] = holders(ctx)

      {:ok, clock} = Agent.start_link(fn -> 0 end)
      set = fn t -> Agent.update(clock, fn _ -> t end) end
      d = start_lease(ctx, strict: true, grace_ms: 30_000, stale_ms: 60_000, clock: fn -> Agent.get(clock, & &1) end)

      telemetry_to_self([:samen, :single_node, :overlap])

      # Seen for the first time: it counts as a holder, but nothing is confirmed alive, so no clock starts.
      assert %{state: :overlap, peers: 1, verified?: false, late?: true} = Lease.check_now(d.name)

      # Past the would-be grace period but before it is stale: not CRITICAL, no overlap report, no strict 503.
      set.(45_000)
      assert %{state: :overlap, exceeded?: false, verified?: false} = Lease.check_now(d.name)
      assert SingleNode.advisory(table: d.table, now: 45_000) == :ok
      assert SingleNode.strict_check(table: d.table, now: 45_000) == :ok

      # Its beat never changes: it stops counting.
      set.(60_000)
      assert %{state: :unknown, reason: :stale_holder} = Lease.check_now(d.name)
      assert {:unknown, _} = SingleNode.advisory(table: d.table, now: 60_000)
      assert SingleNode.strict_check(table: d.table, now: 60_000) == :ok
      refute_received {:telemetry, [:samen, :single_node, :overlap], _}

      # A legitimate rolling deploy an hour later gets its FULL grace: the ghost did not use any of it up.
      e = start_lease(ctx)
      set.(3_600_000)
      assert %{state: :overlap, verified?: false} = Lease.check_now(d.name)
      Lease.check_now(e.name)
      assert %{state: :overlap, verified?: true, exceeded?: false, since_ms: 0} = Lease.check_now(d.name)
      assert SingleNode.advisory(table: d.table, now: 3_600_000) == :ok
      refute_received {:telemetry, [:samen, :single_node, :overlap], _}

      # Only once the CONFIRMED overlap has lasted the grace period: CRITICAL, with exactly one report.
      set.(3_629_999)
      Lease.check_now(e.name)
      assert %{exceeded?: false} = Lease.check_now(d.name)
      set.(3_630_000)
      Lease.check_now(e.name)
      assert %{state: :overlap, verified?: true, exceeded?: true} = Lease.check_now(d.name)
      assert {:critical, _} = SingleNode.advisory(table: d.table, now: 3_630_000)
      assert_received {:telemetry, [:samen, :single_node, :overlap], _}
    end
  end

  describe "a lease whose client disappears does not hold the lock for the TCP keepalive" do
    test "the session carries idle_session_timeout and TCP keepalive settings (honest below Postgres 14)", ctx do
      a = start_lease(ctx, session_idle_ms: 4_000)
      conn = lease_conn(a)
      %{rows: [[version]]} = Postgrex.query!(conn, "SELECT current_setting('server_version_num')::int", [])

      %{rows: [[idle, ka_idle, ka_interval, ka_count]]} =
        Postgrex.query!(
          conn,
          "SELECT current_setting('idle_session_timeout', true), current_setting('tcp_keepalives_idle'), " <>
            "current_setting('tcp_keepalives_interval'), current_setting('tcp_keepalives_count')",
          []
        )

      if version >= 140_000 do
        assert idle == "4s"
      else
        assert idle in [nil, ""]
      end

      assert {ka_idle, ka_interval, ka_count} == {"10", "5", "3"}
    end

    test "a silent client's session is terminated by the server, releasing the lock, within the bound", ctx do
      %{rows: [[version]]} = Postgrex.query!(ctx.admin, "SELECT current_setting('server_version_num')::int", [])
      assert version >= 140_000, "this suite needs Postgres 14+ (idle_session_timeout); CI runs 16"

      telemetry_to_self([:samen, :single_node, :session])
      # The client says NOTHING after its first check (no tick: interval 1h; no pool ping), like a host that died
      # without a FIN. Only the server can end this session.
      a = start_lease(ctx, session_idle_ms: 500, pool_opts: [idle_interval: 3_600_000, queue_target: 50, queue_interval: 100])
      assert_received {:telemetry, _, %{backend_pid: first}}
      assert [^first] = holders(ctx)

      # Wait INSIDE Postgres until the lock is gone (bounded: it raises after 10 s), so the test sleeps nowhere.
      Postgrex.query!(
        ctx.admin,
        """
        DO $$
        DECLARE started timestamptz := clock_timestamp();
        BEGIN
          WHILE EXISTS (SELECT 1 FROM pg_locks WHERE pid = #{first} AND locktype = 'advisory') LOOP
            IF clock_timestamp() > started + interval '10 seconds' THEN
              RAISE EXCEPTION 'lease lock still held 10 s after a 500 ms idle_session_timeout';
            END IF;
            PERFORM pg_sleep(0.02);
          END LOOP;
        END $$
        """,
        [],
        timeout: 20_000
      )

      assert holders(ctx) == []

      # The next check notices, reconnects, and re-takes the lock on a NEW session (a second session event).
      Enum.reduce_while(1..200, nil, fn _, _ ->
        case Lease.check_now(a.name) do
          %{state: :single} -> {:halt, nil}
          %{state: :unknown, reason: :connection_down} -> {:cont, nil}
          other -> flunk("unexpected status after the server ended the session: #{inspect(other)}")
        end
      end)

      assert_received {:telemetry, _, %{backend_pid: second}}
      assert second != first
    end
  end

  describe "connection settings come from the repo's own runtime config" do
    test "a `:configure` function (dynamic credentials) applies to the lease; without it the same config is down", ctx do
      configured =
        start_lease(ctx,
          repo: Samen.SingleNodeLeaseTest.DynRepo,
          query_timeout_ms: 2_000,
          pool_opts: [queue_target: 50, queue_interval: 100]
        )

      assert %{state: :single} = Lease.check_now(configured.name)

      control =
        start_lease(ctx,
          await_session: false,
          repo: Samen.SingleNodeLeaseTest.StaticRepo,
          query_timeout_ms: 300,
          pool_opts: [queue_target: 20, queue_interval: 50]
        )

      assert %{state: :unknown, reason: :connection_down} = Lease.check_now(control.name)
    end
  end

  describe "the published time" do
    test "is the time of PUBLISHING, not of the start of the check (a slow database must not read as lease_stale)", ctx do
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      Application.put_env(:samen_core, :sn_slow_clock, clock)
      on_exit(fn -> Application.delete_env(:samen_core, :sn_slow_clock) end)
      tick = fn -> Agent.get_and_update(clock, fn t -> {t + 1, t + 1} end) end

      # every check and beat statement takes 5 000 ms of (test) clock
      a = start_lease(ctx, clock: tick, query_mod: Samen.SingleNodeLeaseTest.SlowPostgrex)
      started = Agent.get(clock, & &1)
      assert %{state: :single} = Lease.check_now(a.name)
      [{:status, %{at: at}}] = :ets.lookup(a.table, :status)

      # the check statement and the beat statement both ran before the state was published
      assert at >= started + 10_000
    end
  end

  describe "connect_opts/2: the direct URL never replaces the hardened ssl list" do
    alias Samen.SingleNodeLeaseTest.{PlainRepo, TlsRepo}

    defp lease_opts(repo, url), do: Lease.connect_opts([repo: repo, lease_url: url], %{lease_url: nil})

    test "RED: ?ssl=true on the direct URL keeps the repo's list (private CA / verify opt-out apply to the lease)" do
      opts = lease_opts(TlsRepo, "postgres://u:p@direct.example/app?ssl=true")
      assert opts[:ssl] == [verify: :verify_peer, cacertfile: "/ca.pem"]
      # the URL's other parts still win
      assert opts[:hostname] == "direct.example"
    end

    test "RED: fail-closed, a URL ssl=false or a non-canonical value can never replace the list either" do
      for q <- ["ssl=false", "ssl=FALSE", "ssl=0"] do
        assert lease_opts(TlsRepo, "postgres://u:p@direct.example/app?" <> q)[:ssl] == [verify: :verify_peer, cacertfile: "/ca.pem"]
      end
    end

    test "POSITIVE CONTROL: without an ssl: list in the repo config the URL's ssl still applies; no URL ssl inherits the list" do
      assert lease_opts(PlainRepo, "postgres://u:p@direct.example/app?ssl=true")[:ssl] == true
      assert lease_opts(TlsRepo, "postgres://u:p@direct.example/app?sslmode=require")[:ssl] == [verify: :verify_peer, cacertfile: "/ca.pem"]
      assert lease_opts(TlsRepo, "")[:ssl] == [verify: :verify_peer, cacertfile: "/ca.pem"]
    end
  end

  describe "an empty lease_url is unset" do
    test "DATABASE_DIRECT_URL=\"\" does not crash the lease (it uses the repo's own config)", ctx do
      a = start_lease(ctx, lease_url: "")
      assert %{state: :single} = Lease.check_now(a.name)
    end
  end

  describe "interpret/2 and decide/5 (pure)" do
    defp res(rows), do: {:ok, %Postgrex.Result{rows: rows}}
    @ctx %{token: "tok", pid: 10, epoch: 5_000_000}

    # [my_pid, var, holder_pid, secs, usec, beats]
    defp row(holder, epoch_us, beats, var \\ "tok", me \\ 10),
      do: [me, var, holder, [div(epoch_us, 1_000_000)], [rem(epoch_us, 1_000_000)], beats]

    test "alone, and peers are returned with their epoch and beats" do
      assert {:view, []} = Lease.interpret(res([row(10, 5_000_000, [1])]), @ctx)
      assert {:view, [%{pid: 11, epoch: 9_000_000, beats: [3]}]} = Lease.interpret(res([row(10, 5_000_000, [1]), row(11, 9_000_000, [3])]), @ctx)
      # two rows for one peer pid count once
      assert {:view, [_]} = Lease.interpret(res([row(10, 5_000_000, [1]), row(11, 9_000_000, [3]), row(11, 9_000_000, [3])]), @ctx)
    end

    test "a holder with MY epoch is a ghost of my own earlier session, not a peer" do
      assert {:view, []} = Lease.interpret(res([row(10, 5_000_000, [1]), row(12, 5_000_000, [0])]), @ctx)
    end

    test "a statement that is not on my own session is UNKNOWN :connection_pooler" do
      # variable absent / empty
      assert {:unknown, :connection_pooler} = Lease.interpret(res([[10, nil, nil, nil, nil, nil]]), @ctx)
      assert {:unknown, :connection_pooler} = Lease.interpret(res([row(10, 5_000_000, [1], "")]), @ctx)
      # someone else's token (the other instance wrote the variable last)
      assert {:unknown, :connection_pooler} = Lease.interpret(res([row(10, 5_000_000, [1], "other")]), @ctx)
      # right token, other backend than the one recorded
      assert {:unknown, :connection_pooler} = Lease.interpret(res([row(77, 5_000_000, [1], "tok", 77)]), @ctx)
      # my session carries two epochs, or two beats: another lease ran on it too
      two_epochs = [10, "tok", 10, [5, 6], [0, 0], [1]]
      assert {:unknown, :connection_pooler} = Lease.interpret(res([two_epochs]), @ctx)
      assert {:unknown, :connection_pooler} = Lease.interpret(res([row(10, 5_000_000, [1, 2])]), @ctx)
      # a foreign epoch on my session
      assert {:unknown, :connection_pooler} = Lease.interpret(res([row(10, 6_000_000, [1])]), @ctx)
    end

    test "other unreadable shapes" do
      assert {:unknown, :lease_lost} = Lease.interpret(res([[10, "tok", nil, nil, nil, nil]]), @ctx)
      assert {:unknown, :lease_lost} = Lease.interpret(res([row(11, 9_000_000, [3])]), @ctx)
      assert {:unknown, :query_failed} = Lease.interpret({:error, %Postgrex.Error{message: "boom"}}, @ctx)
      assert {:unknown, :query_failed} = Lease.interpret(res([]), @ctx)
      assert {:unknown, :connection_down} = Lease.interpret({:error, %DBConnection.ConnectionError{message: "x"}}, @ctx)
      # the server ended the session (restart, terminate_backend, idle_session_timeout): the FATAL is the connection
      for code <- [:admin_shutdown, :idle_session_timeout, :crash_shutdown, :cannot_connect_now] do
        assert {:unknown, :connection_down} = Lease.interpret({:error, %Postgrex.Error{postgres: %{code: code}}}, @ctx)
      end

      assert {:unknown, :query_failed} = Lease.interpret({:error, %Postgrex.Error{postgres: %{code: :syntax_error}}}, @ctx)
    end

    test "decide: ordering by (epoch, pid); an unreadable epoch never makes us late" do
      mk = fn pid, epoch, beats -> %{pid: pid, epoch: epoch, beats: beats, identities: 1} end
      me = {5_000_000, 10}

      assert {{:overlap, 1, true, false}, _} = Lease.decide([mk.(11, 4_000_000, [1])], %{}, 0, 100, me)
      assert {{:overlap, 1, false, false}, _} = Lease.decide([mk.(11, 9_000_000, [1])], %{}, 0, 100, me)
      assert {{:overlap, 1, false, false}, _} = Lease.decide([mk.(11, nil, [1])], %{}, 0, 100, me)
      # equal epoch cannot reach decide (it is a ghost), but equal micros with a lower pid orders by pid
      assert {{:overlap, 1, true, false}, _} = Lease.decide([mk.(9, 5_000_000, [1])], %{}, 0, 100, me)
      assert {:single, %{}} = Lease.decide([], %{}, 0, 100, me)
    end

    test "decide: a beat that changes confirms; one that never changes goes stale at exactly stale_ms" do
      mk = fn beats -> %{pid: 11, epoch: 9_000_000, beats: beats, identities: 1} end
      me = {5_000_000, 10}

      {v, seen} = Lease.decide([mk.([1])], %{}, 1_000, 100, me)
      assert {:overlap, 1, false, false} = v
      {v, seen} = Lease.decide([mk.([1])], seen, 1_099, 100, me)
      assert {:overlap, 1, false, false} = v
      {v, _} = Lease.decide([mk.([1])], seen, 1_100, 100, me)
      assert v == {:unknown, :stale_holder}

      # changed: confirmed alive, and the clock of staleness restarts
      {v, seen2} = Lease.decide([mk.([2])], seen, 1_050, 100, me)
      assert {:overlap, 1, false, true} = v
      {v, _} = Lease.decide([mk.([2])], seen2, 1_149, 100, me)
      assert {:overlap, 1, false, true} = v
      {v, _} = Lease.decide([mk.([2])], seen2, 1_150, 100, me)
      assert v == {:unknown, :stale_holder}
    end
  end

  describe "the alerts runbook names the lease's real lock" do
    # alerts.md §8 step 3 tells an operator which session holds the lease (and what to pg_terminate_backend for a
    # stale_holder). A wrong constant returns no rows during the incident, so the runbook is held to the code's key.
    test "the step-3 query filters on Lease.key/0 (classid, objid) and the int,int form (objsubid 2)" do
      {k1, k2} = Lease.key()
      runbook = File.read!(Path.expand("../../docs/runbooks/alerts.md", __DIR__))

      assert [[_, classid, objid, objsubid]] =
               Regex.scan(~r/locktype='advisory' AND classid=(\d+) AND objid=(\d+) AND objsubid=(\d+)/, runbook)

      assert {String.to_integer(classid), String.to_integer(objid), String.to_integer(objsubid)} == {k1, k2, 2}
    end

    test "control: the runbook's constants are really what a lease holds in pg_locks", ctx do
      a = start_lease(ctx)
      assert %{state: :single} = Lease.check_now(a.name)
      {k1, k2} = ctx.key

      # the same shape of query the runbook gives, with this test's private key standing in for Lease.key/0
      assert %{rows: [[1]]} =
               Postgrex.query!(
                 ctx.admin,
                 "SELECT count(*)::int FROM pg_locks WHERE locktype='advisory' AND classid=$1 AND objid=$2 AND objsubid=2 AND granted",
                 [k1, k2]
               )
    end
  end

  describe "what does NOT arm the guard holds no lock" do
    test "child_specs for a non-serving instance is empty, so a release eval / mix task / migration never takes it", ctx do
      a = start_lease(ctx)
      assert %{state: :single} = Lease.check_now(a.name)
      [_the_one] = holders(ctx)

      assert SingleNode.child_specs(:samen_core, repo: TestRepo, serving?: false) == []

      # the migrator path of `Release.migrate/0` (`Ecto.Migrator.with_repo`) starts only the repo: still one holder,
      # and the running instance still sees itself alone.
      {:ok, _, _} = Ecto.Migrator.with_repo(TestRepo, fn _repo -> :ok end, [])
      assert length(holders(ctx)) == 1
      assert %{state: :single} = Lease.check_now(a.name)
    end

    test "a serving instance's children are the only thing that creates the lock (positive control)", ctx do
      assert holders(ctx) == []
      table = :"sn_arm_#{System.unique_integer([:positive])}"
      on_exit(fn -> SingleNode.disarm(table) end)

      specs = SingleNode.child_specs(:samen_core, repo: TestRepo, serving?: true, table: table)
      assert [{Samen.SingleNode.Peers, []}, {Lease, [repo: TestRepo]}] = specs
      # serving + a repo arms the status: a lease that never shows up reads UNKNOWN, not "no guard here"
      assert %{state: :unknown, reason: :lease_not_running} = SingleNode.status(table: table)
    end

    test "capture: boot with the DB down logs the failure ONCE and does not crash the lease", ctx do
      log =
        capture_log(fn ->
          a = start_lease(ctx, await_session: false, repo: nil, connect_opts: [hostname: "127.0.0.1", port: 1, username: "x", database: "x"], query_timeout_ms: 300, pool_opts: [queue_target: 20, queue_interval: 50])
          assert %{state: :unknown} = Lease.check_now(a.name)
          assert %{state: :unknown} = Lease.check_now(a.name)
        end)

      assert length(Regex.scan(~r/single_node_state/, log)) == 1
    end
  end
end
