defmodule Samen.Jobs.StarvationIsolationTest do
  @moduledoc """
  T2.1 (d): Starvation isolation — per-queue concurrency isolation.

  Vision doc §limits: "Oban's SKIP LOCKED + separate queues with per-queue
  concurrency limits so a runaway worker class can't starve the others or the
  OLTP path."

  This test proves that saturating one queue with slow jobs does NOT prevent
  another queue's jobs from completing. It runs a real Oban instance (not
  `:manual` mode) with:

    - `:slow_queue` (limit 1): a slow job that HOLDS its slot until the test
      releases it, and another slow job waiting behind it
    - `:fast_queue` (limit 2): one fast job enqueued while that slot is held

  Assertion: the fast job completes while the slow job still holds the slot.
  The hold is a gate, not a duration: a slow job returns only when the test
  sends it `:release` (or the test process exits), so a fast job that had to
  wait for `:slow_queue` would never run before the assertion, whatever the
  machine's speed. (An earlier version slept the slow jobs for 800 ms and gave
  the fast job 3 s: a fast job on `:slow_queue` itself still finished in time,
  so the proof could not fail.) The timeouts here only bound how long a broken
  queue takes to fail the test.

  ## Red-path / anti-tautology probe

  The test also includes a concurrency-limit red path: it fills `:slow_queue`
  with held jobs and releases them one at a time, asserting at each start that
  exactly one is running — by the workers' own ETS counter and by the jobs'
  state in the database. Oban's fetch marks every job it takes `executing` in
  one UPDATE before it starts any of them, so a limit above 1 would show more
  than one `executing` row at the first start.

  ## Simulation seam

  There is NO physical replica or second Oban node in this environment. The
  starvation proof is single-node: two queues on the same Oban supervisor. The
  multi-node case (two Oban nodes, one queue each) would be proven by T3/T4
  game-days; registered as an operator TODO below.

  ## Operator TODO

  On a multi-node deploy (Fly, Kubernetes) verify that per-queue limits compose
  globally (Oban Pro's global limits, or `Oban.Pro.Queue.Global`). In the
  open-source Oban used here, limits are per-node; a two-node cluster doubles
  effective concurrency per queue — this is acceptable for most queues but the
  `:erasure` queue (limit 1) needs an advisory lock or Oban Pro global limits to
  guarantee true single-concurrency across nodes. Register this as a Phase-2 TODO.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  # How long a broken queue may take to fail a test. Never what makes a correct one pass: every wait below is for an
  # event the gate guarantees.
  @timeout_ms 5_000

  # -----------------------------------------------------------------------
  # Fixture workers (defined here so we don't need a full support module)
  # -----------------------------------------------------------------------

  defmodule SlowWorker do
    @moduledoc """
    Slow worker for starvation isolation test: it holds its queue slot until the test sends it `:release`, or until
    the test process exits (so a failed test never leaves Oban waiting on it).
    """
    use Oban.Worker, queue: :slow_queue, max_attempts: 1

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"test_pid" => pid_str}}) do
      test_pid = :erlang.list_to_pid(:erlang.binary_to_list(pid_str))
      ref = Process.monitor(test_pid)
      concurrent = :ets.update_counter(:starvation_counter, :concurrent, {2, 1})
      send(test_pid, {:slow_started, self(), concurrent})

      receive do
        :release -> :ok
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end

      :ets.update_counter(:starvation_counter, :concurrent, {2, -1})
      :ok
    end
  end

  defmodule FastWorker do
    @moduledoc "Fast worker for starvation isolation test."
    use Oban.Worker, queue: :fast_queue, max_attempts: 1

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"test_pid" => pid_str}}) do
      pid = :erlang.list_to_pid(:erlang.binary_to_list(pid_str))
      send(pid, {:fast_done, self()})
      :ok
    end
  end

  # -----------------------------------------------------------------------
  # Setup / teardown
  # -----------------------------------------------------------------------

  # The workers' concurrency counter, owned by the module process so it outlives each test: a slow job can still be
  # running when its test process exits (Oban, stopped after it, lets it finish).
  setup_all do
    case :ets.whereis(:starvation_counter) do
      :undefined -> :ets.new(:starvation_counter, [:named_table, :public, :set])
      _tid -> :ok
    end

    on_exit(fn -> if :ets.whereis(:starvation_counter) != :undefined, do: :ets.delete(:starvation_counter) end)
    :ok
  end

  setup do
    # A REAL Oban (not `testing: :manual`) runs these jobs, in its own producer and executor processes. They reach
    # the test's sandboxed connection through `Samen.TestSandbox.shared!/1`, so the jobs are rolled back with the
    # test and the pool is back in `:manual` afterwards. (This module used to switch the pool to `:auto` and never
    # switch it back: its jobs committed, and every later sync module ran on an unsandboxed pool — issue #103.)
    repo = SamenCore.TestRepo
    Samen.TestSandbox.shared!(repo)

    :ets.insert(:starvation_counter, {:concurrent, 0})

    # Started after `shared!/1`, so ExUnit stops it before that owner is released. The PG notifier relays insert
    # events in-process: the Postgres notifier's NOTIFY is delivered only on COMMIT, which a sandbox never does.
    # No peer: with no plugins there is nothing to lead.
    start_supervised!(
      {Oban,
       repo: repo,
       queues: [slow_queue: 1, fast_queue: 2],
       plugins: false,
       notifier: Oban.Notifiers.PG,
       peer: false,
       name: StarvationTestOban}
    )

    {:ok, oban_name: StarvationTestOban, repo: repo}
  end

  # -----------------------------------------------------------------------
  # Starvation isolation proof
  # -----------------------------------------------------------------------

  test "saturating slow_queue does not starve fast_queue", %{repo: repo} do
    test_pid = encode_pid(self())

    # 1. Saturate slow_queue (limit 1): one job holds the slot, the other waits behind it.
    Oban.insert_all(StarvationTestOban, for(_ <- 1..2, do: SlowWorker.new(%{test_pid: test_pid})))
    assert_receive {:slow_started, holder, 1}, @timeout_ms
    assert slow_queue_states(repo) == %{"executing" => 1, "available" => 1}

    # 2. Enqueue the fast job while the slot is held.
    {:ok, _} = Oban.insert(StarvationTestOban, FastWorker.new(%{test_pid: test_pid}))

    # 3. It completes, and slow_queue is still exactly as saturated as before: nothing there moved.
    assert_receive {:fast_done, _pid}, @timeout_ms,
                   "fast_queue job must complete while slow_queue's only slot is held"

    assert slow_queue_states(repo) == %{"executing" => 1, "available" => 1}

    # 4. Let slow_queue drain.
    send(holder, :release)
    assert_receive {:slow_started, next, 1}, @timeout_ms
    send(next, :release)
  end

  # -----------------------------------------------------------------------
  # Concurrency limit red-path: exactly one execution at a time at limit 1
  # -----------------------------------------------------------------------

  test "slow_queue never runs more than its concurrency limit concurrently", %{repo: repo} do
    test_pid = encode_pid(self())

    # Enough held jobs to exceed the limit IF there were no cap. One INSERT: any fetch sees all four or none.
    Oban.insert_all(StarvationTestOban, for(_ <- 1..4, do: SlowWorker.new(%{test_pid: test_pid})))

    for n <- 1..4 do
      assert_receive {:slow_started, holder, concurrent}, @timeout_ms

      assert concurrent == 1,
             "slow_queue limit=1: start #{n} found #{concurrent} jobs running concurrently"

      executing = Map.get(slow_queue_states(repo), "executing")

      assert executing == 1,
             "slow_queue limit=1: start #{n} found #{inspect(executing)} jobs fetched as executing"

      send(holder, :release)
    end
  end

  defp encode_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  # The slow_queue jobs' states as `%{state => count}`. Completed jobs are left out: a job is acked (marked
  # `completed`) before its producer fetches the next one, so they never blur the `executing` count.
  defp slow_queue_states(repo) do
    from(j in Oban.Job,
      where: j.queue == "slow_queue" and j.state != "completed",
      group_by: j.state,
      select: {j.state, count(j.id)}
    )
    |> repo.all()
    |> Map.new()
  end
end
