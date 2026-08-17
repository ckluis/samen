defmodule Samen.MultiNode.ObanMultiNodeTest do
  @moduledoc """
  L4 — the REAL two-node Oban proof (T90; roadmap Phase 7 / spec §L4).

  Two genuine BEAM peer nodes (`:peer`) on `127.0.0.1`, each with its OWN
  `Samen.MultiNode.Repo` pool and its OWN PRODUCING Oban supervisor, against ONE
  Postgres. This is the production coordination substrate — leadership and
  exactly-once are enforced by Postgres (`FOR UPDATE SKIP LOCKED`, the Oban unique
  index, `Oban.Peers.Database` DB leadership), not by anything in-VM. It is a
  distributed test, not a single-node simulation; local nodes satisfy the spec.

  OPT-IN (`@moduletag :multinode`), excluded from the default `mix test`. Run with
  `SAMEN_MULTINODE=1` (the ci tier does this) — it needs `epmd`, a dedicated
  non-sandbox DB, and real distribution, none of which belong in the fast suite.

  Every peer spawns and JOINS within the test's own lifecycle (`on_exit` stops
  them). Nothing is backgrounded and polled across the suite boundary.
  """
  use ExUnit.Case, async: false

  @moduletag :multinode
  # Distributed boot + failover leases take real wall-clock time.
  @moduletag timeout: 120_000

  alias Samen.MultiNode.Harness
  alias Samen.MultiNode.{CountWorker, UniqueWorker, NoUniqueWorker}

  setup_all do
    System.cmd("epmd", ["-daemon"])
    Harness.ensure_distribution!()
    Harness.create_and_migrate_db!()
    repo = Harness.start_primary_repo!()
    on_exit(fn -> Process.exit(repo, :normal) end)
    :ok
  end

  setup do
    Harness.reset_ledger!()
    :ok
  end

  # Start a fresh A/B peer pair for one test; stop both on exit. Unique node names
  # avoid epmd name collisions with a just-stopped peer.
  defp start_pair!(queues) do
    tag = System.unique_integer([:positive])
    {pa, na} = Harness.start_oban_peer!(:"mn_a_#{tag}", queues)
    {pb, nb} = Harness.start_oban_peer!(:"mn_b_#{tag}", queues)
    on_exit(fn ->
      Harness.stop_peer(pa)
      Harness.stop_peer(pb)
    end)

    {{pa, na}, {pb, nb}}
  end

  @tag :multinode
  test "exactly-once: 120 distinct jobs enqueued across BOTH nodes each execute exactly once" do
    {{_pa, na}, {_pb, nb}} = start_pair!(default: 8)

    changesets = for i <- 1..120, do: CountWorker.new(%{key: "distinct-#{i}"})
    {half_a, half_b} = Enum.split(changesets, 60)
    Harness.enqueue_on(na, half_a)
    Harness.enqueue_on(nb, half_b)

    assert :ok = Harness.wait_until(fn -> Harness.total_execs() >= 120 end, 60_000)
    # Give any stray double-grab a chance to also land before asserting no dupes.
    Process.sleep(500)

    assert Harness.distinct_key_count() == 120
    assert Harness.total_execs() == 120, "no job ran more than once (no double-grab)"
    assert Harness.duplicate_keys() == [], "SKIP LOCKED must give exactly-once fetch across nodes"

    # BOTH nodes actually did work — this is a two-node run, not one node idling.
    nodes = Harness.executing_nodes()
    assert length(nodes) == 2, "expected both peers to execute jobs, saw: #{inspect(nodes)}"
  end

  @tag :multinode
  test "uniqueness dedup: same unique job fanned out from both nodes fires ONCE (refutable control)" do
    {{_pa, na}, {_pb, nb}} = start_pair!(default: 8)

    # UNIQUE worker: enqueue the SAME key 80x split across both nodes → 1 execution.
    # MUST use `insert` (not `insert_all`, which bypasses `unique`).
    uniq = for _ <- 1..40, do: UniqueWorker.new(%{key: "dedup-key"})
    Harness.insert_each_on(na, uniq)
    Harness.insert_each_on(nb, uniq)

    # NEGATIVE CONTROL: identical fan-out, NO unique → many executions. Proves the
    # dedup assertion is refutable (unique is doing real work, not a tautology).
    ctrl = for _ <- 1..40, do: NoUniqueWorker.new(%{key: "control-key"})
    Harness.insert_each_on(na, ctrl)
    Harness.insert_each_on(nb, ctrl)

    assert :ok =
             Harness.wait_until(fn -> Harness.exec_count("control-key") >= 60 end, 60_000)

    Process.sleep(500)

    assert Harness.exec_count("dedup-key") == 1,
           "the unique job must collapse to exactly ONE execution cluster-wide"

    assert Harness.exec_count("control-key") > 1,
           "control (no unique) must fire many times — proves the dedup check can fail"
  end

  @tag :multinode
  test "reveal auto-revoke failover: node A dies, node B runs the scheduled revoke exactly once" do
    {{pa, na}, {_pb, _nb}} = start_pair!(reveal: 5)

    # Grant expires ~4s out; enqueue the REAL AutoRevokeWorker scheduled at expiry
    # on node A, then kill A BEFORE it can run. Only B survives to reconcile.
    {grant_id, expires} = Harness.insert_grant!(4_000)
    Harness.enqueue_auto_revoke_on(na, grant_id, expires)

    refute Harness.grant_revoked?(grant_id), "precondition: grant still live before expiry"

    Harness.stop_peer(pa)

    assert :ok = Harness.wait_until(fn -> Harness.grant_revoked?(grant_id) end, 60_000)
    # Let any (buggy) second execution also land before asserting exactly-once.
    Process.sleep(1_000)

    assert Harness.grant_revoked?(grant_id),
           "surviving node B must run the scheduled auto-revoke after A's death"

    assert Harness.expired_audit_count(grant_id) == 1,
           "exactly ONE 'expired' audit row — the revoke ran once, not twice (no double-side-effect)"
  end
end
