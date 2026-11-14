defmodule Samen.SingleNodeLeaseTest do
  @moduledoc """
  ADR-054 — the database half of the single-node guard: a second instance on the same database is detected.

  "Two instances" are two `Samen.SingleNode.Lease` processes, each with its OWN dedicated connection (exactly
  what two machines would have), against the real test database, on a key private to each test. Proven, each with
  a positive control:

    1. alone -> `:single`; a second instance -> BOTH see `:overlap`; it goes away -> `:single` again;
    2. the late instance is the one whose session started later (strict mode refuses only it);
    3. the grace period: nothing is reported or critical before it, exactly one report and CRITICAL from it on;
    4. fail-honest: a dead database, a lost lock and a pooled statement are UNKNOWN, never `:single`;
    5. a mix task / release `eval` / migration (anything that does not arm the guard) holds no lock.

  There are no sleeps: every state is read with `Lease.check_now/1` (one synchronous check), and "the other
  instance's session is gone" is made synchronous by `pg_terminate_backend(pid, timeout)`, which waits inside
  Postgres for the backend to exit.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.SingleNode
  alias Samen.SingleNode.Lease
  alias SamenCore.TestRepo

  @moduletag :capture_log

  setup do
    # A key private to this test (advisory locks are per database, not per test).
    key = {System.unique_integer([:positive]) + 1_000, System.unique_integer([:positive]) + 7}
    admin = start_supervised!({Postgrex, Keyword.take(TestRepo.config(), [:hostname, :username, :password, :database])})
    %{key: key, admin: admin}
  end

  defp start_lease(ctx, opts \\ []) do
    n = System.unique_integer([:positive])
    name = :"sn_lease_#{n}"
    table = :"sn_lease_t_#{n}"

    opts =
      Keyword.merge(
        [repo: TestRepo, name: name, table: table, lock_key: ctx.key, interval_ms: 3_600_000],
        opts
      )

    start_supervised!(Supervisor.child_spec({Lease, opts}, id: name))
    # `start_link` returns before the dedicated connection is up. The first check is served only once the session
    # exists (after_connect has taken the lock), so after it the instance is a real, visible holder.
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
    [b_pid] = other_pids -- [Postgrex.query!(lease_conn(a), "SELECT pg_backend_pid()", []).rows |> hd() |> hd()]
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

  test "the late instance is the one whose session started later; strict refuses only it", ctx do
    a = start_lease(ctx, strict: true, grace_ms: 0)
    assert %{state: :single} = Lease.check_now(a.name)
    b = start_lease(ctx, strict: true, grace_ms: 0)

    assert %{state: :overlap, late?: false} = Lease.check_now(a.name)
    assert %{state: :overlap, late?: true} = Lease.check_now(b.name)

    assert SingleNode.strict_check(table: a.table) == :ok
    assert SingleNode.strict_check(table: b.table) == {:error, :overlap}
  end

  test "strict off: the late instance is still ready (the advisory is the signal)", ctx do
    a = start_lease(ctx, grace_ms: 0)
    assert %{state: :single} = Lease.check_now(a.name)
    b = start_lease(ctx, grace_ms: 0)
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
      _b = start_lease(ctx)

      assert %{state: :overlap, exceeded?: false} = Lease.check_now(a.name)
      assert SingleNode.advisory(table: a.table, now: 0) == :ok

      Agent.update(ctx.clock, fn _ -> 59_999 end)
      assert %{state: :overlap, exceeded?: false} = Lease.check_now(a.name)
      refute_received {:telemetry, [:samen, :single_node, :overlap], _}
      refute_received {:telemetry, [:samen, :core, :write, :error], %{write: :single_node_overlap}}

      Agent.update(ctx.clock, fn _ -> 60_000 end)
      assert %{state: :overlap, exceeded?: true} = Lease.check_now(a.name)
      assert {:critical, detail} = SingleNode.advisory(table: a.table, now: 60_000)
      assert detail =~ "1 other instance(s)"
      assert_received {:telemetry, [:samen, :single_node, :overlap], _}
      assert_received {:telemetry, [:samen, :core, :write, :error], %{write: :single_node_overlap}}

      # one report per episode, not one per check
      Agent.update(ctx.clock, fn _ -> 90_000 end)
      assert %{exceeded?: true} = Lease.check_now(a.name)
      refute_received {:telemetry, [:samen, :single_node, :overlap], _}
    end
  end

  describe "fail-honest: unreadable is UNKNOWN, never single" do
    test "the database is unreachable", ctx do
      a = start_lease(ctx, repo: nil, connect_opts: [hostname: "127.0.0.1", port: 1, username: "x", database: "x"], query_timeout_ms: 300, pool_opts: [queue_target: 20, queue_interval: 50])

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
  end

  describe "interpret/1 (pure)" do
    defp res(rows), do: {:ok, %Postgrex.Result{rows: rows}}

    test "alone, overlap, ordering" do
      assert Lease.interpret(res([[10, 10, 5, "on"]])) == :single
      assert Lease.interpret(res([[10, 10, 5, "on"], [10, 11, 9, "on"]])) == {:overlap, 1, false}
      assert Lease.interpret(res([[10, 10, 9, "on"], [10, 11, 5, "on"]])) == {:overlap, 1, true}
      # equal start: the lower pid is older
      assert Lease.interpret(res([[10, 10, 5, "on"], [10, 9, 5, "on"]])) == {:overlap, 1, true}
      # a peer whose start is not visible cannot make us late
      assert Lease.interpret(res([[10, 10, 5, "on"], [10, 11, nil, "on"]])) == {:overlap, 1, false}
      # two rows for one peer pid count once
      assert Lease.interpret(res([[10, 10, 5, "on"], [10, 11, 6, "on"], [10, 11, 6, "on"]])) == {:overlap, 1, false}
    end

    test "unreadable shapes" do
      assert Lease.interpret(res([[10, nil, nil, nil]])) == {:unknown, :connection_pooler}
      assert Lease.interpret(res([[10, 10, 5, ""]])) == {:unknown, :connection_pooler}
      assert Lease.interpret(res([[10, nil, nil, "on"]])) == {:unknown, :lease_lost}
      assert Lease.interpret(res([[10, 11, 5, "on"]])) == {:unknown, :lease_lost}
      assert Lease.interpret({:error, %Postgrex.Error{message: "boom"}}) == {:unknown, :query_failed}
      assert Lease.interpret(res([])) == {:unknown, :query_failed}
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
      specs = SingleNode.child_specs(:samen_core, repo: TestRepo, serving?: true)
      assert [{Samen.SingleNode.Peers, []}, {Lease, [repo: TestRepo]}] = specs
    end

    test "capture: boot with the DB down logs the failure once and does not crash the lease", ctx do
      log =
        capture_log(fn ->
          a = start_lease(ctx, repo: nil, connect_opts: [hostname: "127.0.0.1", port: 1, username: "x", database: "x"], query_timeout_ms: 300, pool_opts: [queue_target: 20, queue_interval: 50])
          assert %{state: :unknown} = Lease.check_now(a.name)
        end)

      assert log =~ "single_node_state"
    end
  end
end
